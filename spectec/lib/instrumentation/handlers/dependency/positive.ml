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
  | Constant of Il.Value.t
  | FieldPath of C.field_path
  | Unknown

(* Comparison - tracks full comparison context for accurate mutation *)
type comparison = {
  lhs : C.field_path option;
  rhs : comparison_rhs;
  op : cmp_op;
  raw_exp : Il.exp;
}

(* Mutation suggestion using field_path and mutation_hint *)
type mutation_suggestion = {
  field : C.field_path;
  target : C.mutation_target;
  hint : C.mutation_hint;
}

(* Analyzed expression result *)
type analyzed_expr =
  | Comparison of comparison
  | BoolCall of { name : string; args : C.field_path list }
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

(* Resolve expression to structured field_path.
   More restrictive than resolve_to_path - only returns paths that can be mutated.
   Complex expressions (BinE, UnE, LenE, etc.) return None.
*)
let rec resolve_to_field_path (env : source_env) (exp : Il.exp) :
    C.field_path option =
  match exp.it with
  (* Variables: look up in environment *)
  | Il.VarE id -> (
      match C.lookup_source env id.it with
      | Some path -> Some path
      | None -> Some (C.field_path_of_source Unknown))
  (* Field access: base.field *)
  | Il.DotE (base, atom) -> (
      match resolve_to_field_path env base with
      | Some base_path ->
          Some
            (C.append_step base_path
               (C.FieldAccess (Lang.Xl.Atom.string_of_atom atom.it)))
      | None -> None)
  (* Array indexing: base[idx] *)
  | Il.IdxE (base, idx) -> (
      match resolve_to_field_path env base with
      | None -> None
      | Some base_path -> (
          (* Try to resolve index *)
          match idx.it with
          | Il.NumE n -> (
              (* Constant index *)
              match n with
              | `Nat bi -> (
                  try
                    let i = Bigint.to_int_exn bi in
                    Some
                      (C.append_step base_path (C.IndexAccess (C.ConstInt i)))
                  with _ -> None (* Index too large *))
              | _ -> None (* Non-nat index *))
          | _ -> (
              (* Try to resolve as field path *)
              match resolve_to_field_path env idx with
              | Some idx_path ->
                  Some
                    (C.append_step base_path
                       (C.IndexAccess (C.PathRef idx_path)))
              | None -> None)))
  (* Subtype casts: unwrap *)
  | Il.SubE (inner, _) -> resolve_to_field_path env inner
  | Il.UpCastE (_, inner) -> resolve_to_field_path env inner
  | Il.DownCastE (_, inner) -> resolve_to_field_path env inner
  (* Iteration: unwrap *)
  | Il.IterE (inner, _) -> resolve_to_field_path env inner
  (* Optional: unwrap if Some *)
  | Il.OptE (Some inner) -> resolve_to_field_path env inner
  | Il.OptE None -> None
  (* Everything else: can't represent as mutable path *)
  | Il.NumE _ | Il.BoolE _ | Il.TextE _ -> None (* Constants *)
  | Il.LenE _ -> None (* Length is not a mutable field *)
  | Il.UnE _ -> None (* Unary operations *)
  | Il.BinE _ -> None (* Binary operations *)
  | Il.CallE _ -> None (* Function calls *)
  | Il.MemE _ -> None (* Membership *)
  | Il.MatchE _ -> None (* Match expressions *)
  | _ -> None (* Fallback *)

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
      match resolve_to_field_path env exp with
      | Some field -> FieldPath field
      | None -> Unknown)

(* Analyze a comparison expression *)
let analyze_cmp (env : source_env) (op : Il.cmpop) (lhs : Il.exp) (rhs : Il.exp)
    (raw : Il.exp) : comparison =
  {
    lhs = resolve_to_field_path env lhs;
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
        | Il.ExpA exp -> resolve_to_field_path env exp
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
  | FieldPath f -> C.string_of_field_path f
  | Unknown -> "?"

let string_of_comparison (cmp : comparison) : string =
  let lhs_str =
    match cmp.lhs with Some f -> C.string_of_field_path f | None -> "?"
  in
  let rhs_str = string_of_rhs cmp.rhs in
  Printf.sprintf "%s %s %s" lhs_str (string_of_cmp_op cmp.op) rhs_str

let string_of_analyzed (expr : analyzed_expr) : string =
  match expr with
  | Comparison cmp -> string_of_comparison cmp
  | BoolCall { name; args } ->
      let arg_strs = List.map C.string_of_field_path args in
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
          let target = C.Value in
          match cmp.op with
          | Eq ->
              (* For ==: mutate to exact value *)
              [ { field; target; hint = C.Concrete (C.ToLiteral v) } ]
          | Ne ->
              (* For !=: can't easily generate different value, use Unresolved *)
              [ { field; target; hint = C.Unresolved "!= constraint" } ]
          | Lt | Le ->
              (* For <, <=: try boundary below *)
              [ { field; target; hint = C.Concrete (C.ToLiteral v) } ]
          | Gt | Ge ->
              (* For >, >=: try boundary above *)
              [ { field; target; hint = C.Concrete (C.ToLiteral v) } ])
      | FieldPath target_field -> (
          let target = C.Value in
          match cmp.op with
          | Eq ->
              (* For ==: set to match other field *)
              [
                {
                  field;
                  target;
                  hint = C.Symbolic (C.ToFieldValue target_field);
                };
              ]
          | Ne ->
              (* For !=: unresolved *)
              [ { field; target; hint = C.Unresolved "!= field constraint" } ]
          | Lt ->
              (* For <: set to boundary below *)
              [
                {
                  field;
                  target;
                  hint = C.Symbolic (C.ToBoundaryOf (target_field, `Below));
                };
              ]
          | Le ->
              (* For <=: set to match or below *)
              [
                {
                  field;
                  target;
                  hint = C.Symbolic (C.ToFieldValue target_field);
                };
                {
                  field;
                  target;
                  hint = C.Symbolic (C.ToBoundaryOf (target_field, `Below));
                };
              ]
          | Gt ->
              (* For >: set to boundary above *)
              [
                {
                  field;
                  target;
                  hint = C.Symbolic (C.ToBoundaryOf (target_field, `Above));
                };
              ]
          | Ge ->
              (* For >=: set to match or above *)
              [
                {
                  field;
                  target;
                  hint = C.Symbolic (C.ToFieldValue target_field);
                };
                {
                  field;
                  target;
                  hint = C.Symbolic (C.ToBoundaryOf (target_field, `Above));
                };
              ]))

(* === Handler State === *)
module State = struct
  let output_file : string option ref = ref None

  (* Source environment for variable provenance *)
  let env : source_env = C.create_env ()

  (* Relation input variable names from spec *)
  let relation_inputs : (string, string list) Hashtbl.t = Hashtbl.create 50

  (* Already-analyzed premises (by location string) *)
  let seen_prems : (string, unit) Hashtbl.t = Hashtbl.create 1000

  (* Current context *)
  let current_relation : string ref = ref ""
  let current_rule : string ref = ref ""
  let current_test_id : string ref = ref ""

  (* Path condition stack *)
  let path_stack : condition_frame list ref = ref []

  (* Per-test results: premise_uid -> test_id -> mutation_suggestion list *)
  let per_test_results :
      (int, (string, mutation_suggestion list) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 1000

  (* Legacy results for output: relation -> rule -> analyzed_expr list *)
  let results : (string, (string, analyzed_expr list) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 100

  (* Progress tracking *)
  let premise_count = ref 0
  let if_prem_count = ref 0
  let skipped_count = ref 0
  let func_depth = ref 0

  let reset () =
    C.clear_env env;
    Hashtbl.clear relation_inputs;
    Hashtbl.clear seen_prems;
    current_relation := "";
    current_rule := "";
    current_test_id := "";
    path_stack := [];
    Hashtbl.clear per_test_results;
    Hashtbl.clear results;
    premise_count := 0;
    if_prem_count := 0;
    skipped_count := 0;
    func_depth := 0

  let in_helper_function () = !func_depth > 0
  let already_seen loc = Hashtbl.mem seen_prems loc
  let mark_seen loc = Hashtbl.replace seen_prems loc ()
  let push_frame () = path_stack := [] :: !path_stack

  let pop_frame () =
    match !path_stack with _ :: rest -> path_stack := rest | [] -> ()

  let add_condition (cond : analyzed_expr) =
    match !path_stack with
    | frame :: rest -> path_stack := (cond :: frame) :: rest
    | [] -> path_stack := [ [ cond ] ]

  (* Add per-test mutation result *)
  let add_per_test_mutation (premise_uid : int)
      (mutations : mutation_suggestion list) =
    if !current_test_id <> "" && mutations <> [] then
      let test_table =
        match Hashtbl.find_opt per_test_results premise_uid with
        | Some t -> t
        | None ->
            let t = Hashtbl.create 100 in
            Hashtbl.add per_test_results premise_uid t;
            t
      in
      let existing =
        match Hashtbl.find_opt test_table !current_test_id with
        | Some m -> m
        | None -> []
      in
      Hashtbl.replace test_table !current_test_id (existing @ mutations)

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
  let init ~spec =
    State.reset ();
    match spec with
    | Instrumentation_core.Handler.IlSpec il_spec ->
        let inputs = C.extract_relation_inputs il_spec in
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.relation_inputs k v)
          inputs
    | Instrumentation_core.Handler.SlSpec _ -> ()

  let on_test_start ~test_case_id = State.current_test_id := test_case_id
  let on_test_end ~test_case_id:_ = State.current_test_id := ""

  let on_rel_enter ~id ~at:_ ~values =
    State.current_relation := id;
    State.push_frame ();
    C.bind_state_transition_inputs State.env State.relation_inputs id values

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

  let on_func_enter ~id:_ ~at:_ ~values:_ =
    State.func_depth := !State.func_depth + 1

  let on_func_exit ~id:_ ~at:_ = State.func_depth := !State.func_depth - 1
  let on_clause_enter = Instrumentation_core.Noop.on_clause_enter
  let on_clause_exit = Instrumentation_core.Noop.on_clause_exit
  let on_iter_prem_enter = Instrumentation_core.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit
  let on_prem_enter = Instrumentation_core.Noop.on_prem_enter
  let on_instr = Instrumentation_core.Noop.on_instr

  let on_prem_exit ~prem ~at:_ ~success =
    if success then
      match prem.it with
      | Il.LetPr ({ it = Il.VarE id; _ }, rhs) -> (
          match resolve_to_field_path State.env rhs with
          | Some path -> C.bind_source State.env id.it path
          | None -> ())
      | _ -> ()

  let on_prem_fields ~prem ~fields:_ ~lookup:_ ~at =
    State.premise_count := !State.premise_count + 1;
    if !State.premise_count mod 1000 = 0 then
      Format.eprintf "\r[Positive] %d premises, %d if-prems, %d skipped...%!"
        !State.premise_count !State.if_prem_count !State.skipped_count;

    if State.in_helper_function () then ()
    else if not (C.is_whitelisted !State.current_relation) then ()
    else
      let loc = string_of_region at in
      if State.already_seen loc then
        State.skipped_count := !State.skipped_count + 1
      else if not (is_if_prem prem) then ()
      else (
        State.mark_seen loc;
        State.if_prem_count := !State.if_prem_count + 1;
        match prem.it with
        | Il.IfPr exp -> (
            let analyzed = analyze_expression State.env exp in
            State.add_result analyzed;
            State.add_condition analyzed;
            (* Extract mutations and add per-test result *)
            match analyzed with
            | Comparison cmp -> (
                let mutations = extract_mutation_suggestions cmp in
                let key = Premise_uid.prem_key prem in
                match Premise_uid.get_uid key with
                | Some uid -> State.add_per_test_mutation uid mutations
                | None -> ())
            | _ -> ())
        | Il.IterPr ({ it = Il.IfPr exp; _ }, _) -> (
            let analyzed = analyze_expression State.env exp in
            State.add_result analyzed;
            State.add_condition analyzed;
            match analyzed with
            | Comparison cmp -> (
                let mutations = extract_mutation_suggestions cmp in
                let key = Premise_uid.prem_key prem in
                match Premise_uid.get_uid key with
                | Some uid -> State.add_per_test_mutation uid mutations
                | None -> ())
            | _ -> ())
        | _ -> ())

  let finish () =
    Format.fprintf !fmt "\n=== Positive Dependencies ===\n\n";
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

(* Result type for programmatic access *)
type result = {
  per_test_mutations : (int * (string * mutation_suggestion list) list) list;
      (* premise_uid -> test_id -> mutations *)
}

let get_result () =
  let per_test_mutations =
    Hashtbl.fold
      (fun uid test_table acc ->
        let test_muts =
          Hashtbl.fold (fun tid muts acc -> (tid, muts) :: acc) test_table []
        in
        (uid, test_muts) :: acc)
      State.per_test_results []
  in
  { per_test_mutations }

let restore result =
  Hashtbl.clear State.per_test_results;
  List.iter
    (fun (uid, test_muts) ->
      let test_table = Hashtbl.create 100 in
      List.iter
        (fun (tid, muts) -> Hashtbl.replace test_table tid muts)
        test_muts;
      Hashtbl.replace State.per_test_results uid test_table)
    result.per_test_mutations

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
