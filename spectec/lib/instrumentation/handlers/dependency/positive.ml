(* Positive dependency analysis for test mutation guidance.

   Tracks source paths (provenance) of variables and analyzes if-premises
   to extract field dependencies and mutation suggestions.

   Key features:
   - Per-test mutation tracking: mutations are organized by (premise_uid, test_id)
   - Symbolic expression tracking: preserves full comparison context
   - Mutation strategy extraction: generates concrete mutation suggestions

   Uses Common module for shared types and utilities.
*)

open Common.Source
module Il = Lang.Il
module Premise_uid = Instrumentation_static.Premise_uid
module C = Dep_common

(* Re-export types from Common for convenience *)
type input_source = C.input_source = State | Block | Unknown

type field_access = C.field_access = {
  source : input_source;
  fields : string list;
}

type source_env = C.source_env

(* === Positive-Analysis Specific Types === *)

(* Verbosity levels *)
type level = Summary | Full

(* Handler configuration *)
type config = { level : level; output : Instrumentation_core.Output.t }

let default_config =
  { level = Summary; output = Instrumentation_core.Output.stdout }

let config = ref default_config
let fmt = ref Format.std_formatter

(* Comparison operators *)
type cmp_op = Eq | Ne | Lt | Le | Gt | Ge

(* RHS of comparison - what we're comparing against *)
type comparison_rhs =
  | Constant of Il.Value.t (* RHS is a constant value *)
  | Field of field_access (* RHS is another field *)
  | Unknown (* RHS couldn't be resolved *)

(* Comparison - tracks full comparison context for accurate mutation *)
type comparison = {
  lhs : field_access option; (* Field being compared (LHS) *)
  rhs : comparison_rhs; (* What it's compared to (RHS) *)
  op : cmp_op;
  raw_exp : Il.exp;
}

(* Mutation strategy - focused on HOW to mutate *)
type mutation_strategy =
  | ToExactValue of Il.Value.t (* For ==: mutate to this exact value *)
  | ToDifferentValue of Il.Value.t (* For !=: mutate to any value except this *)
  | ToBoundaryMinus of Il.Value.t (* For <, <=: try value-1, value *)
  | ToBoundaryPlus of Il.Value.t (* For >, >=: try value+1, value *)
  | ToMatchField of field_access (* Mutate to match another field's value *)
  | ToZero (* Special case: mutate to zero *)
  | ToOne (* Special case: mutate to one *)
  | ToMax (* Special case: mutate to max for type *)
  | ToMin (* Special case: mutate to min for type *)

(* Mutation suggestion - extracted from comparison *)
type mutation_suggestion = {
  field : field_access; (* Which field to mutate *)
  strategy : mutation_strategy; (* How to mutate it *)
}

(* Analyzed expression result *)
type analyzed_expr =
  | Comparison of comparison
  | BoolCall of { name : string; args : field_access list }
  | Unknown of Il.exp

(* Path condition frame (for backtracking) *)
type condition_frame = analyzed_expr list

(* === Expression Resolution (Positive-specific: detailed symbolic tracking) === *)

(* Convert IL cmpop to our type *)
let convert_cmpop (op : Il.cmpop) : cmp_op =
  match op with
  | `EqOp -> Eq
  | `NeOp -> Ne
  | `LtOp -> Lt
  | `LeOp -> Le
  | `GtOp -> Gt
  | `GeOp -> Ge

(* Resolve an expression to a field access.
 * Returns None if we can't determine the input source.
 * This version tracks symbolic expressions in detail.
 *)
let rec resolve_to_path (env : source_env) (exp : Il.exp) : field_access option
    =
  match exp.it with
  (* Variables: look up in environment or use as-is *)
  | Il.VarE id -> (
      match C.lookup_source env id.it with
      | Some access -> Some access
      | None -> Some { source = Unknown; fields = [ id.it ] })
  (* Field access: base.field *)
  | Il.DotE (base, atom) -> (
      match resolve_to_path env base with
      | Some base_path ->
          Some (C.append_field base_path (Lang.Xl.Atom.string_of_atom atom.it))
      | None -> (
          match base.it with
          | Il.VarE id ->
              Some
                {
                  source = Unknown;
                  fields = [ id.it; Lang.Xl.Atom.string_of_atom atom.it ];
                }
          | _ -> None))
  (* Array indexing: base[idx] *)
  | Il.IdxE (base, idx) -> (
      match (resolve_to_path env base, resolve_to_path env idx) with
      | Some base_path, Some idx_path ->
          let idx_str = String.concat "." idx_path.fields in
          Some (C.append_field base_path ("[" ^ idx_str ^ "]"))
      | Some base_path, None -> Some (C.append_field base_path "[?]")
      | _ -> None)
  (* Length: |base| *)
  | Il.LenE base -> (
      match resolve_to_path env base with
      | Some path -> Some (C.append_field path "|length|")
      | None -> None)
  (* Constants: these don't have an input source *)
  | Il.NumE _ -> None
  | Il.BoolE _ -> None
  | Il.TextE _ -> None
  (* Unary operations: ~e, -e *)
  | Il.UnE (op, _, inner) -> (
      let op_str =
        match op with `NotOp -> "~" | `PlusOp -> "+" | `MinusOp -> "-"
      in
      match resolve_to_path env inner with
      | Some access ->
          let path_str = String.concat "." access.fields in
          Some
            {
              source = access.source;
              fields = [ op_str ^ "(" ^ path_str ^ ")" ];
            }
      | None -> None)
  (* Binary operations: e1 + e2, e1 - e2, etc *)
  | Il.BinE (op, _, lhs, rhs) -> (
      let op_str =
        match op with
        | `AddOp -> "+"
        | `SubOp -> "-"
        | `MulOp -> "*"
        | `DivOp -> "/"
        | `ModOp -> "%"
        | `PowOp -> "^"
        | `AndOp -> "/\\"
        | `OrOp -> "\\/"
        | `ImplOp -> "=>"
        | `EquivOp -> "<=>"
      in
      match (resolve_to_path env lhs, resolve_to_path env rhs) with
      | Some l, Some r ->
          let source = if l.source = r.source then l.source else Unknown in
          let l_str = String.concat "." l.fields in
          let r_str = String.concat "." r.fields in
          Some { source; fields = [ l_str ^ " " ^ op_str ^ " " ^ r_str ] }
      | _ -> None)
  (* Subtype cast: just unwrap *)
  | Il.SubE (inner, _) -> resolve_to_path env inner
  | Il.UpCastE (_, inner) -> resolve_to_path env inner
  | Il.DownCastE (_, inner) -> resolve_to_path env inner
  (* Membership: x <- xs *)
  | Il.MemE (elem, container) -> (
      match (resolve_to_path env elem, resolve_to_path env container) with
      | Some e, Some c ->
          let source = if e.source = c.source then e.source else Unknown in
          let e_str = String.concat "." e.fields in
          let c_str = String.concat "." c.fields in
          Some { source; fields = [ e_str ^ " <- " ^ c_str ] }
      | _ -> None)
  (* Iteration: e* or e+ *)
  | Il.IterE (inner, _) -> resolve_to_path env inner
  (* Optional: e? *)
  | Il.OptE (Some inner) -> resolve_to_path env inner
  | Il.OptE None -> None
  (* Function calls: preserve function call info *)
  | Il.CallE (id, _, args) ->
      let resolve_arg arg =
        match arg.it with
        | Il.ExpA exp -> (
            match resolve_to_path env exp with
            | Some access -> String.concat "." access.fields
            | None -> "?")
        | Il.DefA def_id -> "$" ^ def_id.it
      in
      let arg_strs = List.map resolve_arg args in
      Some
        {
          source = Unknown;
          fields = [ "$" ^ id.it ^ "(" ^ String.concat ", " arg_strs ^ ")" ];
        }
  (* Match expressions *)
  | Il.MatchE (inner, _) -> (
      match resolve_to_path env inner with
      | Some access ->
          let path_str = String.concat "." access.fields in
          Some
            { source = access.source; fields = [ path_str ^ " matches ..." ] }
      | None -> None)
  (* Fallback *)
  | _ -> None

(* Check if expression is a constant value *)
let is_constant_exp (exp : Il.exp) : Il.Value.t option =
  match exp.it with
  | Il.NumE n -> (
      match exp.note with
      | Il.NumT typ -> Some (Il.Value.Make.num (Il.NumT typ) n)
      | _ -> Some (Il.Value.Make.num Il.Typ.nat n))
  | Il.BoolE b -> Some (Il.Value.Make.bool Il.Typ.bool b)
  | Il.TextE s -> Some (Il.Value.Make.text Il.Typ.text s)
  | _ -> None

(* Resolve RHS to comparison_rhs *)
let resolve_rhs (env : source_env) (exp : Il.exp) : comparison_rhs =
  match is_constant_exp exp with
  | Some v -> Constant v
  | None -> (
      match resolve_to_path env exp with
      | Some field -> Field field
      | None -> Unknown)

(* Analyze a comparison expression *)
let analyze_cmp (env : source_env) (op : Il.cmpop) (lhs : Il.exp) (rhs : Il.exp)
    (raw : Il.exp) : comparison =
  {
    lhs = resolve_to_path env lhs;
    rhs = resolve_rhs env rhs;
    op = convert_cmpop op;
    raw_exp = raw;
  }

(* Main expression analysis *)
let analyze_expression (env : source_env) (exp : Il.exp) : analyzed_expr =
  let exp1, _neg1 = C.strip_negation exp in
  let exp2, _neg2 = C.strip_bool_eq exp1 in

  match exp2.it with
  | Il.CmpE (op, _, lhs, rhs) -> Comparison (analyze_cmp env op lhs rhs exp)
  | Il.CallE (id, _, args) ->
      let resolve_arg arg =
        match arg.it with
        | Il.ExpA exp -> resolve_to_path env exp
        | Il.DefA _ -> None
      in
      let arg_paths = List.filter_map resolve_arg args in
      BoolCall { name = id.it; args = arg_paths }
  | _ -> Unknown exp

(* Check if premise is an if-premise *)
let rec is_if_prem (prem : Il.prem) : bool =
  match prem.it with
  | Il.IfPr _ -> true
  | Il.IterPr (inner, _) -> is_if_prem inner
  | _ -> false

(* === String Formatting === *)

let string_of_cmp_op = function
  | Eq -> "=="
  | Ne -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="

let string_of_rhs (rhs : comparison_rhs) : string =
  match rhs with
  | Constant v -> Il.Print.string_of_value v
  | Field f -> C.string_of_field_access f
  | Unknown -> "?"

let string_of_comparison (cmp : comparison) : string =
  let lhs_str =
    match cmp.lhs with Some f -> C.string_of_field_access f | None -> "?"
  in
  let rhs_str = string_of_rhs cmp.rhs in
  Printf.sprintf "%s %s %s" lhs_str (string_of_cmp_op cmp.op) rhs_str

let string_of_analyzed (expr : analyzed_expr) : string =
  match expr with
  | Comparison cmp -> string_of_comparison cmp
  | BoolCall { name; args } ->
      let arg_strs = List.map C.string_of_field_access args in
      Printf.sprintf "$%s(%s)" name (String.concat ", " arg_strs)
  | Unknown exp -> Il.Print.string_of_exp exp

(* Extract mutation suggestions from a comparison *)
let extract_mutation_suggestions (cmp : comparison) : mutation_suggestion list =
  match cmp.lhs with
  | None -> []
  | Some field -> (
      match cmp.rhs with
      | Unknown -> []
      | Constant v -> (
          match cmp.op with
          | Eq -> [ { field; strategy = ToExactValue v } ]
          | Ne -> [ { field; strategy = ToDifferentValue v } ]
          | Lt | Le ->
              [
                { field; strategy = ToBoundaryMinus v };
                { field; strategy = ToBoundaryPlus v };
              ]
          | Gt | Ge ->
              [
                { field; strategy = ToBoundaryPlus v };
                { field; strategy = ToBoundaryMinus v };
              ])
      | Field target_field -> (
          match cmp.op with
          | Eq -> [ { field; strategy = ToMatchField target_field } ]
          | Ne ->
              [
                {
                  field;
                  strategy =
                    ToDifferentValue
                      (Il.Value.Make.num Il.Typ.nat (`Nat Bigint.zero));
                };
              ]
          | _ -> []))

(* === Handler State === *)
module State = struct
  let output_file : string option ref = ref None

  (* Whitelist: if non-empty, only analyze these relations *)
  let whitelist : string list ref = ref []

  (* Source environment for variable provenance *)
  let env : source_env = C.create_env ()

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
    C.clear_env env;
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
  (* Store relation input variable names from spec *)
  let relation_inputs : (string, string list) Hashtbl.t = Hashtbl.create 50

  let init ~spec =
    State.reset ();
    Hashtbl.clear relation_inputs;
    (* Extract input variable names from State_transition relation *)
    match spec with
    | Instrumentation_core.Handler.IlSpec il_spec ->
        List.iter
          (fun def ->
            match def.it with
            | Il.RelD (id, _, input_hints, rules) ->
                if id.it = "State_transition" && rules <> [] then
                  (* Get input expressions from first rule's notexp *)
                  let rule = List.hd rules in
                  let _, notexp, _ = rule.it in
                  let _, exps = notexp in
                  (* Split expressions based on input_hints (indices) *)
                  let exps_input =
                    exps
                    |> List.mapi (fun idx exp -> (idx, exp))
                    |> List.filter (fun (idx, _) -> List.mem idx input_hints)
                    |> List.map snd
                  in
                  (* Extract variable names from input expressions *)
                  let input_vars =
                    List.filter_map
                      (fun exp ->
                        match exp.it with Il.VarE id -> Some id.it | _ -> None)
                      exps_input
                  in
                  Hashtbl.replace relation_inputs id.it input_vars
            | _ -> ())
          il_spec
    | Instrumentation_core.Handler.SlSpec _ -> ()

  let on_test_start = Instrumentation_core.Noop.on_test_start
  let on_test_end = Instrumentation_core.Noop.on_test_end

  (* Track relation/rule context and manage source env *)
  let on_rel_enter ~id ~at:_ ~values =
    State.current_relation := id;
    State.push_frame ();
    (* For State_transition, bind input variables to state and block *)
    if id = "State_transition" then
      match Hashtbl.find_opt relation_inputs id with
      | Some input_vars -> (
          match (input_vars, values) with
          | state_var :: block_var :: _, _state_val :: _block_val :: _ ->
              (* Bind state variable to state input *)
              C.bind_source State.env state_var { source = State; fields = [] };
              (* Bind block variable to block input *)
              C.bind_source State.env block_var { source = Block; fields = [] }
          | _ -> ())
      | None -> ()
    else
      (* For nested relations, we'll track input mappings when we see rule-premises *)
      ()

  let on_rel_exit ~id:_ ~at:_ ~success:_ =
    State.pop_frame ();
    State.current_relation := "";
    State.current_rule := "";
    C.clear_env State.env

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
          | Some path -> C.bind_source State.env id.it path
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
  mutations : (string * (string * mutation_suggestion list) list) list;
      (* relation -> (rule * mutation_suggestion list) list *)
}

let get_result () =
  let results =
    Hashtbl.fold
      (fun rel rules acc ->
        let rule_exprs =
          Hashtbl.fold (fun rule exprs acc -> (rule, exprs) :: acc) rules []
        in
        (rel, rule_exprs) :: acc)
      State.results []
  in
  (* Extract mutation suggestions from comparisons *)
  let mutations =
    List.map
      (fun (rel, rule_exprs) ->
        let rule_mutations =
          List.map
            (fun (rule, exprs) ->
              let muts =
                List.fold_left
                  (fun acc expr ->
                    match expr with
                    | Comparison cmp -> acc @ extract_mutation_suggestions cmp
                    | _ -> acc)
                  [] exprs
              in
              (rule, muts))
            rule_exprs
        in
        (rel, rule_mutations))
      results
  in
  { results; mutations }

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
(* Note: mutations are derived from results, so we don't need to restore them separately *)

(* Handler with data access - implements S_with_data signature *)
module HandlerWithData :
  Instrumentation_core.Handler.S_with_data with type result = result = struct
  include M

  type nonrec result = result

  let get_result = get_result
  let restore = restore
end

let make cfg : (module Instrumentation_core.Handler.S) =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  (module M)

let make_with_data cfg =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  ( (module HandlerWithData : Instrumentation_core.Handler.S_with_data
      with type result = result),
    get_result )
