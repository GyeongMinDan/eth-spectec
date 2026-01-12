(* Dependency analysis for test mutation guidance.

   Tracks source paths (provenance) of variables and analyzes
   if-premises to extract field dependencies.

   Key components:
   - Source environment: maps var_name -> source_path
   - Expression analysis: strip negation, find comparison
   - Path condition stack: accumulate conditions for backtracking
*)

open Common.Source
module Il = Lang.Il

(* Verbosity levels *)
type level = Summary | Full

(* Handler configuration *)
type config = { level : level; output : Instrumentation_core.Output.t }

let default_config =
  { level = Summary; output = Instrumentation_core.Output.stdout }

let config = ref default_config
let fmt = ref Format.std_formatter

(* === Types === *)

(* Source path: e.g., ["state", "SLOT"] for state.SLOT *)
type source_path = string list

(* Source environment: maps variable names to their source paths *)
type source_env = (string, source_path) Hashtbl.t

(* Comparison operators *)
type cmp_op = Eq | Ne | Lt | Le | Gt | Ge

(* Analyzed comparison *)
type comparison = {
  lhs : source_path option;
  rhs : source_path option;
  op : cmp_op;
  raw_exp : Il.exp; (* Original expression for display *)
}

(* Analyzed expression result *)
type analyzed_expr =
  | Comparison of comparison
  | BoolCall of string * source_path list (* function name, arg paths *)
  | Unknown of Il.exp

(* Path condition frame (for backtracking) *)
type condition_frame = analyzed_expr list

(* === Source Environment === *)

let create_env () : source_env = Hashtbl.create 100

let bind_source (env : source_env) (var : string) (path : source_path) : unit =
  Hashtbl.replace env var path

let lookup_source (env : source_env) (var : string) : source_path option =
  Hashtbl.find_opt env var

let clear_env (env : source_env) : unit = Hashtbl.clear env

(* === Expression Analysis Helpers === *)

(* Strip outermost negation: ¬e -> e *)
let rec strip_negation (exp : Il.exp) : Il.exp * bool =
  match exp.it with
  | Il.UnE (`NotOp, _, inner) ->
      let stripped, was_negated = strip_negation inner in
      (stripped, not was_negated)
  | _ -> (exp, false)

(* Strip = true / = false wrappers *)
let strip_bool_eq (exp : Il.exp) : Il.exp * bool =
  match exp.it with
  | Il.CmpE (`EqOp, _, inner, { it = Il.BoolE true; _ }) -> (inner, false)
  | Il.CmpE (`EqOp, _, inner, { it = Il.BoolE false; _ }) -> (inner, true)
  | Il.CmpE (`EqOp, _, { it = Il.BoolE true; _ }, inner) -> (inner, false)
  | Il.CmpE (`EqOp, _, { it = Il.BoolE false; _ }, inner) -> (inner, true)
  | _ -> (exp, false)

(* Convert IL cmpop to our type *)
let convert_cmpop (op : Il.cmpop) : cmp_op =
  match op with
  | `EqOp -> Eq
  | `NeOp -> Ne
  | `LtOp -> Lt
  | `LeOp -> Le
  | `GtOp -> Gt
  | `GeOp -> Ge

(* Resolve an expression to a readable string representation *)
let rec resolve_to_path (env : source_env) (exp : Il.exp) : source_path option =
  match exp.it with
  (* Variables: look up in environment or use as-is *)
  | Il.VarE id -> (
      match lookup_source env id.it with
      | Some path -> Some path
      | None -> Some [ id.it ])
  (* Field access: base.field *)
  | Il.DotE (base, atom) -> (
      match resolve_to_path env base with
      | Some base_path ->
          Some (base_path @ [ Lang.Xl.Atom.string_of_atom atom.it ])
      | None -> None)
  (* Array indexing: base[idx] *)
  | Il.IdxE (base, idx) -> (
      match (resolve_to_path env base, resolve_to_path env idx) with
      | Some base_path, Some idx_path ->
          Some (base_path @ [ "[" ^ String.concat "." idx_path ^ "]" ])
      | Some base_path, None -> Some (base_path @ [ "[?]" ])
      | _ -> None)
  (* Length: |base| *)
  | Il.LenE base -> (
      match resolve_to_path env base with
      | Some path -> Some [ "|" ^ String.concat "." path ^ "|" ]
      | None -> None)
  (* Constants *)
  | Il.NumE n -> Some [ Lang.Xl.Num.string_of_num n ]
  | Il.BoolE b -> Some [ string_of_bool b ]
  | Il.TextE s -> Some [ "\"" ^ s ^ "\"" ]
  (* Unary operations: ~e, -e *)
  | Il.UnE (op, _, inner) -> (
      let op_str =
        match op with `NotOp -> "~" | `PlusOp -> "+" | `MinusOp -> "-"
      in
      match resolve_to_path env inner with
      | Some path -> Some [ op_str ^ "(" ^ String.concat "." path ^ ")" ]
      | None -> None)
  (* Binary operations: e1 + e2, e1 - e2, etc *)
  | Il.BinE (op, _, lhs, rhs) -> (
      let op_str =
        match op with
        (* Num.binop *)
        | `AddOp -> "+"
        | `SubOp -> "-"
        | `MulOp -> "*"
        | `DivOp -> "/"
        | `ModOp -> "%"
        | `PowOp -> "^"
        (* Bool.binop *)
        | `AndOp -> "/\\"
        | `OrOp -> "\\/"
        | `ImplOp -> "=>"
        | `EquivOp -> "<=>"
      in
      match (resolve_to_path env lhs, resolve_to_path env rhs) with
      | Some l, Some r ->
          Some
            [ String.concat "." l ^ " " ^ op_str ^ " " ^ String.concat "." r ]
      | _ -> None)
  (* Subtype cast: just unwrap *)
  | Il.SubE (inner, _) -> resolve_to_path env inner
  | Il.UpCastE (_, inner) -> resolve_to_path env inner
  | Il.DownCastE (_, inner) -> resolve_to_path env inner
  (* Membership: x <- xs *)
  | Il.MemE (elem, container) -> (
      match (resolve_to_path env elem, resolve_to_path env container) with
      | Some e, Some c ->
          Some [ String.concat "." e ^ " <- " ^ String.concat "." c ]
      | _ -> None)
  (* Iteration: e* or e+ *)
  | Il.IterE (inner, _) -> resolve_to_path env inner
  (* Optional: e? *)
  | Il.OptE (Some inner) -> resolve_to_path env inner
  | Il.OptE None -> Some [ "?" ]
  (* Function calls: expand arguments *)
  | Il.CallE (id, _, args) ->
      let resolve_arg arg =
        match arg.it with
        | Il.ExpA exp -> (
            match resolve_to_path env exp with
            | Some path -> String.concat "." path
            | None -> "?")
        | Il.DefA def_id -> "$" ^ def_id.it
      in
      let arg_strs = List.map resolve_arg args in
      Some [ "$" ^ id.it ^ "(" ^ String.concat ", " arg_strs ^ ")" ]
  (* Match expressions *)
  | Il.MatchE (inner, _) -> (
      match resolve_to_path env inner with
      | Some path -> Some [ String.concat "." path ^ " matches ..." ]
      | None -> None)
  (* Fallback: use IL printer *)
  | _ -> Some [ Il.Print.string_of_exp exp ]

(* Analyze a comparison expression *)
let analyze_cmp (env : source_env) (op : Il.cmpop) (lhs : Il.exp) (rhs : Il.exp)
    (raw : Il.exp) : comparison =
  {
    lhs = resolve_to_path env lhs;
    rhs = resolve_to_path env rhs;
    op = convert_cmpop op;
    raw_exp = raw;
  }

(* Main expression analysis *)
let analyze_expression (env : source_env) (exp : Il.exp) : analyzed_expr =
  (* Strip outer negation and bool comparisons *)
  let exp1, _neg1 = strip_negation exp in
  let exp2, _neg2 = strip_bool_eq exp1 in

  match exp2.it with
  | Il.CmpE (op, _, lhs, rhs) -> Comparison (analyze_cmp env op lhs rhs exp)
  | Il.CallE (id, _, args) ->
      let resolve_arg arg =
        match arg.it with
        | Il.ExpA exp -> resolve_to_path env exp
        | Il.DefA def_id -> Some [ "$" ^ def_id.it ]
      in
      let arg_paths = List.filter_map resolve_arg args in
      BoolCall (id.it, arg_paths)
  | _ -> Unknown exp

(* === Premise Checking === *)

(* Check if premise is an if-premise (including nested iter) *)
let rec is_if_prem (prem : Il.prem) : bool =
  match prem.it with
  | Il.IfPr _ -> true
  | Il.IterPr (inner, _) -> is_if_prem inner
  | _ -> false

(* === String Formatting === *)

let string_of_path (path : source_path) : string = String.concat "." path

let string_of_cmp_op = function
  | Eq -> "=="
  | Ne -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="

let string_of_comparison (cmp : comparison) : string =
  let lhs_str = match cmp.lhs with Some p -> string_of_path p | None -> "?" in
  let rhs_str = match cmp.rhs with Some p -> string_of_path p | None -> "?" in
  Printf.sprintf "%s %s %s" lhs_str (string_of_cmp_op cmp.op) rhs_str

let string_of_analyzed (expr : analyzed_expr) : string =
  match expr with
  | Comparison cmp -> string_of_comparison cmp
  | BoolCall (name, arg_paths) ->
      let arg_strs = List.map (fun path -> String.concat "." path) arg_paths in
      Printf.sprintf "$%s(%s)" name (String.concat ", " arg_strs)
  | Unknown exp -> Il.Print.string_of_exp exp

(* === Handler State === *)
module State = struct
  let output_file : string option ref = ref None

  (* Whitelist: if non-empty, only analyze these relations *)
  let whitelist : string list ref = ref []

  (* Source environment for variable provenance *)
  let env : source_env = create_env ()

  (* Already-analyzed premises (by location string) *)
  let seen_prems : (string, unit) Hashtbl.t = Hashtbl.create 1000

  (* Current context *)
  let current_relation : string ref = ref ""
  let current_rule : string ref = ref ""

  (* Path condition stack: list of frames, each frame is list of conditions *)
  let path_stack : condition_frame list ref = ref []

  (* Collected results: relation -> rule -> analyzed_expr list *)
  let results : (string, (string, analyzed_expr list) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 100

  (* Progress tracking *)
  let premise_count = ref 0
  let if_prem_count = ref 0
  let skipped_count = ref 0

  (* Function depth: > 0 means we're inside a helper function call *)
  let func_depth = ref 0

  let reset () =
    clear_env env;
    Hashtbl.clear seen_prems;
    current_relation := "";
    current_rule := "";
    path_stack := [];
    Hashtbl.clear results;
    premise_count := 0;
    if_prem_count := 0;
    skipped_count := 0;
    func_depth := 0

  let in_helper_function () = !func_depth > 0

  let is_whitelisted rel =
    match !whitelist with
    | [] -> true (* empty whitelist = analyze all *)
    | wl -> List.mem rel wl

  let already_seen loc = Hashtbl.mem seen_prems loc
  let mark_seen loc = Hashtbl.replace seen_prems loc ()
  let push_frame () = path_stack := [] :: !path_stack

  let pop_frame () =
    match !path_stack with _ :: rest -> path_stack := rest | [] -> ()

  let add_condition (cond : analyzed_expr) =
    match !path_stack with
    | frame :: rest -> path_stack := (cond :: frame) :: rest
    | [] -> path_stack := [ [ cond ] ]

  let add_result (expr : analyzed_expr) =
    let rel = !current_relation in
    let rule = !current_rule in
    if rel = "" then ()
    else
      let rules =
        match Hashtbl.find_opt results rel with
        | Some r -> r
        | None ->
            let r = Hashtbl.create 20 in
            Hashtbl.add results rel r;
            r
      in
      let exprs =
        match Hashtbl.find_opt rules rule with Some e -> e | None -> []
      in
      Hashtbl.replace rules rule (exprs @ [ expr ])
end

(* === Handler Implementation === *)

module M : Instrumentation_core.Handler.S = struct
  let init ~spec:_ = State.reset ()

  (* Track relation/rule context and manage source env *)
  let on_rel_enter ~id ~at:_ ~values:_ =
    State.current_relation := id;
    State.push_frame ()

  let on_rel_exit ~id:_ ~at:_ ~success:_ =
    State.pop_frame ();
    State.current_relation := "";
    State.current_rule := "";
    clear_env State.env

  let on_rule_enter ~id:_ ~rule_id ~at:_ =
    State.current_rule := rule_id;
    State.push_frame ()

  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success:_ =
    State.pop_frame ();
    State.current_rule := ""

  (* Track function calls to skip premises inside helper functions *)
  let on_func_enter ~id:_ ~at:_ ~values:_ =
    State.func_depth := !State.func_depth + 1

  let on_func_exit ~id:_ ~at:_ = State.func_depth := !State.func_depth - 1

  (* Forward unused hooks to Noop *)
  let on_clause_enter = Instrumentation_core.Noop.on_clause_enter
  let on_clause_exit = Instrumentation_core.Noop.on_clause_exit
  let on_iter_prem_enter = Instrumentation_core.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit
  let on_prem_enter = Instrumentation_core.Noop.on_prem_enter
  let on_instr = Instrumentation_core.Noop.on_instr

  (* Track let-premise bindings for source env *)
  let on_prem_exit ~prem ~at:_ ~success =
    if success then
      match prem.it with
      | Il.LetPr ({ it = Il.VarE id; _ }, rhs) -> (
          (* Bind LHS var to RHS path *)
          match resolve_to_path State.env rhs with
          | Some path -> bind_source State.env id.it path
          | None -> ())
      | _ -> ()

  (* Main hook: analyze if-premises *)
  let on_prem_fields ~prem ~fields:_ ~lookup:_ ~at =
    State.premise_count := !State.premise_count + 1;
    (* Print progress every 1000 premises *)
    if !State.premise_count mod 1000 = 0 then
      Format.eprintf "\r[Dependency] %d premises, %d if-prems, %d skipped...%!"
        !State.premise_count !State.if_prem_count !State.skipped_count;

    (* Skip if inside helper function (not direct rule body) *)
    if State.in_helper_function () then () (* Skip if not in whitelist *)
    else if not (State.is_whitelisted !State.current_relation) then ()
    (* Skip if already analyzed this premise *)
      else
      let loc = string_of_region at in
      if State.already_seen loc then
        State.skipped_count := !State.skipped_count + 1
      else if not (is_if_prem prem) then ()
      else (
        State.mark_seen loc;
        State.if_prem_count := !State.if_prem_count + 1;
        match prem.it with
        | Il.IfPr exp ->
            let analyzed = analyze_expression State.env exp in
            State.add_result analyzed;
            State.add_condition analyzed
        | Il.IterPr ({ it = Il.IfPr exp; _ }, _) ->
            let analyzed = analyze_expression State.env exp in
            State.add_result analyzed;
            State.add_condition analyzed
        | _ -> ())

  (* Output *)
  let finish () =
    Format.fprintf !fmt "\n=== Field Dependencies ===\n\n";
    Hashtbl.iter
      (fun rel rules ->
        Format.fprintf !fmt "relation %s\n" rel;
        Hashtbl.iter
          (fun rule exprs ->
            Format.fprintf !fmt "  rule %s\n" rule;
            List.iter
              (fun expr ->
                Format.fprintf !fmt "    %s\n" (string_of_analyzed expr))
              exprs)
          rules;
        Format.fprintf !fmt "\n")
      State.results
end

(* Result type for programmatic access and checkpoint restoration *)
type result = {
  results : (string * (string * analyzed_expr list) list) list;
      (* relation -> (rule * analyzed_expr list) list *)
}

let get_result () =
  {
    results =
      Hashtbl.fold
        (fun rel rules acc ->
          let rule_exprs =
            Hashtbl.fold (fun rule exprs acc -> (rule, exprs) :: acc) rules []
          in
          (rel, rule_exprs) :: acc)
        State.results [];
  }

(* Restore state from a previous result (for checkpoint resume) *)
let restore result =
  Hashtbl.clear State.results;
  List.iter
    (fun (rel, rule_exprs) ->
      let rules = Hashtbl.create 20 in
      List.iter
        (fun (rule, exprs) -> Hashtbl.replace rules rule exprs)
        rule_exprs;
      Hashtbl.replace State.results rel rules)
    result.results

(* Handler with data access - implements S_with_data signature *)
module HandlerWithData :
  Instrumentation_core.Handler.S_with_data with type result = result = struct
  include M

  type nonrec result = result

  let get_result = get_result
  let restore = restore
end

let whitelist_default =
  [
    "State_transition";
    (* Block Processing *)
    "ProcessBlockHeader";
    "ProcessWithdrawals";
    "ProcessExecutionPayload";
    "ProcessRandao";
    "ProcessEth1Data";
    "ProcessSyncAggregate";
    (* Operations *)
    "ProcessProposerSlashing";
    "ProcessAttesterSlashing";
    "ProcessAttestation";
    "ProcessDeposit";
    "ProcessVoluntaryExit";
    "ProcessBlsToExecutionChange";
    (* Slot *)
    "ProcessSlot";
    (* Epoch *)
    "ProcessJustificationAndFinalization";
    "ProcessInactivityUpdates";
    "ProcessRewardsAndPenalties";
    "ProcessRegistryUpdates";
    "ProcessSlashings";
    "ProcessEth1DataReset";
    "ProcessEffectiveBalanceUpdates";
    "ProcessSlashingsReset";
    "ProcessRandaoMixesReset";
    "ProcessHistoricalSummariesUpdate";
    "ProcessParticipationFlagUpdates";
    "ProcessSyncCommitteeUpdates";
  ]

let make cfg : (module Instrumentation_core.Handler.S) =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  State.whitelist := whitelist_default;
  (module M)

(* Create handler with data getter for programmatic access.
   Usage:
     let handler, get_dependency = Dependency.make_with_data cfg in
     Hooks.set_handlers [handler];
     (* ... run interpreter ... *)
     let data = get_dependency () in
*)
let make_with_data cfg =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  State.whitelist := whitelist_default;
  ( (module HandlerWithData : Instrumentation_core.Handler.S_with_data
      with type result = result),
    get_result )
