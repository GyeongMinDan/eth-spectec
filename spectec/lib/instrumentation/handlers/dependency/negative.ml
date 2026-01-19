(* Negative dependency analysis for test mutation guidance.

   Collects path conditions (conjunctions of if-premises) leading to each
   premise. This provides "negative dependencies" - fields that should NOT
   be mutated because they're part of the path condition.

   Key features:
   - Per-premise blacklist: aggregates field paths that must not change
   - Over-approximation: captures all involved fields (simpler than positive)

   Uses Common module for shared types and utilities.
*)

open Common.Source
module Il = Lang.Il
module Premise_uid = Instrumentation_static.Premise_uid
open Dep_common

(* === Negative-Analysis Specific Types === *)

(* Path condition: a list of fields involved in if-premises leading to target *)
type path_condition = field_path list

(* Handler configuration *)
type level = Summary | Full
type config = { level : level; output : Instrumentation_core.Output.t }

let default_config =
  { level = Summary; output = Instrumentation_core.Output.stdout }

let config = ref default_config
let fmt = ref Format.std_formatter

(* === Field Path Set for Efficient Dependency Tracking === *)

module FieldPathSet = Set.Make (struct
  type t = field_path

  let compare = compare
end)

(* Frame for tracking field path dependencies in scope *)
type frame = {
  mutable field_env : (string, FieldPathSet.t) Hashtbl.t;
  mutable dependencies : FieldPathSet.t;
}

(* === Expression Resolution (Negative-specific: simpler over-approximation) === *)

(* Resolve an expression to a field_path - simpler than positive analysis.
 * We only need to track fields involved, not full symbolic expressions.
 *)
let rec resolve_to_path (env : source_env) (exp : Il.exp) : field_path option =
  match exp.it with
  (* Variables: look up in environment *)
  | Il.VarE id -> (
      match lookup_source env id.it with
      | Some path -> Some path
      | None -> Some { source = Unknown; steps = [ FieldAccess id.it ] })
  (* Field access: base.field *)
  | Il.DotE (base, atom) -> (
      match resolve_to_path env base with
      | Some base_path ->
          Some
            (append_step base_path
               (FieldAccess (Lang.Xl.Atom.string_of_atom atom.it)))
      | None -> None)
  (* Array indexing: base[idx] *)
  | Il.IdxE (base, idx) -> (
      match resolve_to_path env base with
      | None -> None
      | Some base_path -> (
          match idx.it with
          | Il.NumE n -> (
              match n with
              | `Nat bi -> (
                  try
                    let i = Bigint.to_int_exn bi in
                    Some (append_step base_path (IndexAccess (ConstInt i)))
                  with _ -> None)
              | _ -> None)
          | _ -> (
              match resolve_to_path env idx with
              | Some idx_path ->
                  Some (append_step base_path (IndexAccess (PathRef idx_path)))
              | None -> None)))
  (* Subtype casts: unwrap *)
  | Il.SubE (inner, _) -> resolve_to_path env inner
  | Il.UpCastE (_, inner) -> resolve_to_path env inner
  | Il.DownCastE (_, inner) -> resolve_to_path env inner
  (* Iteration: unwrap *)
  | Il.IterE (inner, _) -> resolve_to_path env inner
  (* Optional: unwrap if Some *)
  | Il.OptE (Some inner) -> resolve_to_path env inner
  | Il.OptE None -> None
  (* Everything else: can't represent as mutable path *)
  | Il.NumE _ | Il.BoolE _ | Il.TextE _ -> None
  | Il.LenE _ -> None
  | Il.CallE _ -> None
  | Il.MatchE _ -> None
  | _ -> None

(* Extract all fields from an expression recursively - returns a set *)
(* Will be defined after State module to use resolve_to_field_path_set *)

(* Check if premise is an if-premise *)
let rec is_if_prem (prem : Il.prem) : bool =
  match prem.it with
  | Il.IfPr _ -> true
  | Il.IterPr (inner, _) -> is_if_prem inner
  | _ -> false

(* Convert Mutator_analysis.field_path to Dep_common.field_path *)
let rec convert_ma_index_expr
    (idx : Instrumentation_static.Mutator_analysis.index_expr) : index_expr =
  match idx with
  | Instrumentation_static.Mutator_analysis.ConstInt i -> ConstInt i
  | Instrumentation_static.Mutator_analysis.PathRef p ->
      PathRef (convert_ma_field_path p)

and convert_ma_field_step
    (step : Instrumentation_static.Mutator_analysis.field_step) : field_step =
  match step with
  | Instrumentation_static.Mutator_analysis.FieldAccess s -> FieldAccess s
  | Instrumentation_static.Mutator_analysis.IndexAccess idx ->
      IndexAccess (convert_ma_index_expr idx)

and convert_ma_field_path
    (path : Instrumentation_static.Mutator_analysis.field_path) : field_path =
  let source =
    match path.source with
    | Instrumentation_static.Mutator_analysis.State -> State
    | Instrumentation_static.Mutator_analysis.Block -> Block
    | Instrumentation_static.Mutator_analysis.Unknown -> Unknown
  in
  { source; steps = List.map convert_ma_field_step path.steps }

(* === Handler State === *)
module State = struct
  let env : source_env = create_env ()
  let relation_inputs : (string, string list) Hashtbl.t = Hashtbl.create 50
  let current_relation : string ref = ref ""

  (* Already-analyzed premises (by location string) *)
  let seen_prems : (string, unit) Hashtbl.t = Hashtbl.create 1000

  (* Progress counters *)
  let premise_count : int ref = ref 0
  let if_prem_count : int ref = ref 0
  let blacklist_count : int ref = ref 0
  let skipped_count : int ref = ref 0

  (* Per-premise blacklist: premise_uid -> path_condition list *)
  let blacklists : (int, path_condition list) Hashtbl.t = Hashtbl.create 1000

  (* Global field_env: maps variable id to set of field paths *)
  let field_env : (string, FieldPathSet.t) Hashtbl.t = Hashtbl.create 100

  (* Global dependencies *)
  let dependencies : FieldPathSet.t ref = ref FieldPathSet.empty

  (* Frame stack for backtracking-aware dependency tracking *)
  let frames : frame list ref = ref []

  let reset () =
    clear_env env;
    Hashtbl.clear relation_inputs;
    Hashtbl.clear seen_prems;
    current_relation := "";
    premise_count := 0;
    if_prem_count := 0;
    blacklist_count := 0;
    skipped_count := 0;
    Hashtbl.clear blacklists;
    Hashtbl.clear field_env;
    dependencies := FieldPathSet.empty;
    frames := []

  let already_seen loc = Hashtbl.mem seen_prems loc
  let mark_seen loc = Hashtbl.replace seen_prems loc ()

  let add_blacklist (premise_uid : int) (fields : field_path list) =
    (* Always add, even if empty (for debugging) *)
    let existing =
      match Hashtbl.find_opt blacklists premise_uid with
      | Some bl -> bl
      | None -> []
    in
    (* Only add if not already present *)
    if not (List.mem fields existing) then (
      if fields <> [] then blacklist_count := !blacklist_count + 1;
      Hashtbl.replace blacklists premise_uid (fields :: existing))

  (* Frame management for backtracking *)
  let push_frame () =
    let new_frame =
      { field_env = Hashtbl.create 50; dependencies = FieldPathSet.empty }
    in
    frames := new_frame :: !frames

  let pop_frame_success () =
    match !frames with
    | frame :: rest ->
        frames := rest;
        (* Union each variable's set from frame into global env *)
        Hashtbl.iter
          (fun var_id frame_set ->
            let global_set =
              match Hashtbl.find_opt field_env var_id with
              | Some s -> s
              | None -> FieldPathSet.empty
            in
            Hashtbl.replace field_env var_id
              (FieldPathSet.union global_set frame_set))
          frame.field_env;
        (* Union frame dependencies into global dependencies *)
        dependencies := FieldPathSet.union !dependencies frame.dependencies
    | [] -> ()

  let pop_frame_failure () =
    match !frames with _frame :: rest -> frames := rest | [] -> ()

  (* Helper functions *)
  let get_current_field_env () =
    match !frames with frame :: _ -> frame.field_env | [] -> field_env

  let get_current_dependencies () =
    match !frames with frame :: _ -> frame.dependencies | [] -> !dependencies

  let bind_field_set (var_id : string) (paths : FieldPathSet.t) =
    match !frames with
    | frame :: _ -> Hashtbl.replace frame.field_env var_id paths
    | [] -> Hashtbl.replace field_env var_id paths

  let lookup_field_set (var_id : string) : FieldPathSet.t =
    let frame_set =
      match !frames with
      | frame :: _ -> (
          match Hashtbl.find_opt frame.field_env var_id with
          | Some s -> s
          | None -> FieldPathSet.empty)
      | [] -> FieldPathSet.empty
    in
    let global_set =
      match Hashtbl.find_opt field_env var_id with
      | Some s -> s
      | None -> FieldPathSet.empty
    in
    FieldPathSet.union frame_set global_set

  let add_to_dependencies (paths : FieldPathSet.t) =
    match !frames with
    | frame :: _ ->
        frame.dependencies <- FieldPathSet.union frame.dependencies paths
    | [] ->
        (* No frame, add directly to global dependencies *)
        dependencies := FieldPathSet.union !dependencies paths
end

(* Resolve expression to field path set - defined after State module *)
(* Uses both field_env (new) and env (old) for fallback resolution *)
let rec resolve_to_field_path_set (exp : Il.exp) : FieldPathSet.t =
  match exp.it with
  (* Variables: look up in field_env first, then fallback to old env *)
  | Il.VarE id -> (
      let field_set = State.lookup_field_set id.it in
      if not (FieldPathSet.is_empty field_set) then field_set
      else
        (* Fallback to old env for backward compatibility *)
        match resolve_to_path State.env exp with
        | Some path -> FieldPathSet.singleton path
        | None -> FieldPathSet.empty)
  (* Field access: base.field *)
  | Il.DotE (base, atom) ->
      let base_set = resolve_to_field_path_set base in
      let result =
        FieldPathSet.fold
          (fun base_path acc ->
            let new_path =
              append_step base_path
                (FieldAccess (Lang.Xl.Atom.string_of_atom atom.it))
            in
            FieldPathSet.add new_path acc)
          base_set FieldPathSet.empty
      in
      (* If base_set was empty, try old resolution method as fallback *)
      if FieldPathSet.is_empty base_set then
        match resolve_to_path State.env exp with
        | Some path -> FieldPathSet.singleton path
        | None -> result
      else result
  (* Array indexing: base[idx] *)
  | Il.IdxE (base, idx) ->
      let base_set = resolve_to_field_path_set base in
      let idx_set = resolve_to_field_path_set idx in
      let result =
        FieldPathSet.fold
          (fun base_path acc ->
            FieldPathSet.fold
              (fun idx_path sub_acc ->
                let new_path =
                  append_step base_path (IndexAccess (PathRef idx_path))
                in
                FieldPathSet.add new_path sub_acc)
              idx_set acc)
          base_set FieldPathSet.empty
      in
      (* If base_set was empty, try old resolution method as fallback *)
      if FieldPathSet.is_empty base_set then
        match resolve_to_path State.env exp with
        | Some path -> FieldPathSet.singleton path
        | None -> result
      else result
  (* Subtype casts: unwrap *)
  | Il.SubE (inner, _) | Il.UpCastE (_, inner) | Il.DownCastE (_, inner) ->
      resolve_to_field_path_set inner
  (* Iteration: unwrap *)
  | Il.IterE (inner, _) -> resolve_to_field_path_set inner
  (* Optional: unwrap if Some *)
  | Il.OptE (Some inner) -> resolve_to_field_path_set inner
  | Il.OptE None -> FieldPathSet.empty
  (* Everything else: extract all nested fields *)
  | Il.UnE (_, _, inner) -> resolve_to_field_path_set inner
  | Il.BinE (_, _, lhs, rhs) | Il.CmpE (_, _, lhs, rhs) | Il.MemE (lhs, rhs) ->
      FieldPathSet.union
        (resolve_to_field_path_set lhs)
        (resolve_to_field_path_set rhs)
  | Il.LenE inner -> resolve_to_field_path_set inner
  | Il.CallE (_, _, args) ->
      List.fold_left
        (fun acc arg ->
          match arg.it with
          | Il.ExpA e -> FieldPathSet.union acc (resolve_to_field_path_set e)
          | Il.DefA _ -> acc)
        FieldPathSet.empty args
  | Il.MatchE (cond, _cases) -> resolve_to_field_path_set cond
  | _ -> FieldPathSet.empty

(* Update extract_fields_from_expr to use resolve_to_field_path_set *)
let extract_fields_from_expr (_env : source_env) (exp : Il.exp) : FieldPathSet.t
    =
  resolve_to_field_path_set exp

(* === Handler Implementation === *)

module M : Instrumentation_core.Handler.S = struct
  let init ~spec =
    State.reset ();
    match spec with
    | Instrumentation_core.Handler.IlSpec il_spec ->
        let inputs = extract_relation_inputs il_spec in
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.relation_inputs k v)
          inputs
    | Instrumentation_core.Handler.SlSpec _ -> ()

  let on_test_start = Instrumentation_core.Noop.on_test_start
  let on_test_end = Instrumentation_core.Noop.on_test_end

  let on_rel_enter ~id ~at:_ ~values =
    State.current_relation := id;
    State.push_frame ();
    bind_state_transition_inputs State.env State.relation_inputs id values;
    (* Also bind state/block inputs to field_env *)
    if id = "State_transition" then
      match Hashtbl.find_opt State.relation_inputs id with
      | Some input_vars -> (
          match input_vars with
          | state_var :: block_var :: _ ->
              let state_path_set =
                FieldPathSet.singleton { source = State; steps = [] }
              in
              let block_path_set =
                FieldPathSet.singleton { source = Block; steps = [] }
              in
              State.bind_field_set state_var state_path_set;
              State.bind_field_set block_var block_path_set
          | _ -> ())
      | None -> ()

  let on_rel_exit ~id:_ ~at:_ ~success =
    if success then State.pop_frame_success () else State.pop_frame_failure ();
    State.current_relation := "";
    clear_env State.env

  let on_rule_enter ~id:_ ~rule_id:_ ~at:_ = State.push_frame ()

  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success =
    if success then State.pop_frame_success () else State.pop_frame_failure ()

  let on_func_enter = Instrumentation_core.Noop.on_func_enter
  let on_func_exit = Instrumentation_core.Noop.on_func_exit
  let on_clause_enter ~id:_ ~clause_idx:_ ~at:_ = State.push_frame ()

  let on_clause_exit ~id:_ ~clause_idx:_ ~at:_ ~success =
    if success then State.pop_frame_success () else State.pop_frame_failure ()

  let on_iter_prem_enter = Instrumentation_core.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit

  let on_prem_enter ~prem ~at =
    State.premise_count := !State.premise_count + 1;
    if !State.premise_count mod 500 = 0 then
      Format.eprintf
        "\r[Negative] %d premises, %d if-prems, %d blacklists, %d skipped...%!"
        !State.premise_count !State.if_prem_count !State.blacklist_count
        !State.skipped_count;

    (* Process IfPr premises in whitelisted relations *)
    if not (is_whitelisted !State.current_relation) then ()
    else
      let loc = string_of_region at in
      if State.already_seen loc then
        State.skipped_count := !State.skipped_count + 1
      else if not (is_if_prem prem) then ()
      else (
        State.mark_seen loc;
        State.if_prem_count := !State.if_prem_count + 1;
        (* Extract fields from condition and add to current frame's dependencies *)
        (* This ensures condition fields are included in the accumulated dependencies *)
        match prem.it with
        | Il.IfPr exp ->
            let fields = resolve_to_field_path_set exp in
            State.add_to_dependencies fields
        | Il.IterPr ({ it = Il.IfPr exp; _ }, _) ->
            let fields = resolve_to_field_path_set exp in
            State.add_to_dependencies fields
        | _ -> ())

  let on_prem_exit ~prem ~at:_ ~success =
    (if success then
       match prem.it with
       | Il.LetPr ({ it = Il.VarE id; _ }, rhs) -> (
           (* Resolve RHS to FieldPathSet and bind to variable *)
           let path_set = resolve_to_field_path_set rhs in
           State.bind_field_set id.it path_set;
           (* Also update source_env for backward compatibility *)
           match resolve_to_path State.env rhs with
           | Some path -> bind_source State.env id.it path
           | None -> ())
       | Il.IterPr ({ it = Il.LetPr ({ it = Il.VarE id; _ }, rhs); _ }, _) -> (
           (* Handle IterPr(LetPr) - nested let bindings in iterations *)
           let path_set = resolve_to_field_path_set rhs in
           State.bind_field_set id.it path_set;
           (* Also update source_env for backward compatibility *)
           match resolve_to_path State.env rhs with
           | Some path -> bind_source State.env id.it path
           | None -> ())
       | Il.RulePr (id, (_, args)) -> (
           (* Handle rule premises with mutator detection *)
           match
             Instrumentation_static.Mutator_analysis.get_mutator_info id.it
           with
           | Some mutator_info -> (
               (* Mutator: extract mutated paths and bind to result variable *)
               let converted_paths =
                 List.map convert_ma_field_path mutator_info.mutated_paths
               in
               let path_set =
                 List.fold_left
                   (fun acc p -> FieldPathSet.add p acc)
                   FieldPathSet.empty converted_paths
               in
               (* For mutators, the result is the first argument with mutations *)
               match args with
               | arg :: _ ->
                   let arg_set = resolve_to_field_path_set arg in
                   (* Union with mutated paths *)
                   State.bind_field_set "_result"
                     (FieldPathSet.union arg_set path_set)
               | [] -> ())
           | None ->
               (* Getter: extract field paths from arguments *)
               let arg_paths =
                 List.fold_left
                   (fun acc arg ->
                     FieldPathSet.union acc (resolve_to_field_path_set arg))
                   FieldPathSet.empty args
               in
               (* Bind result to union of argument paths *)
               State.bind_field_set "_result" arg_paths)
       | _ -> ());
    (* On if-premise exit, accumulate dependencies and record blacklist *)
    if success && is_if_prem prem then (
      (* Lookup all variables from current field_env, union their field path sets, add to dependencies *)
      let current_env = State.get_current_field_env () in
      let all_paths = ref FieldPathSet.empty in
      Hashtbl.iter
        (fun _var_id path_set ->
          all_paths := FieldPathSet.union !all_paths path_set)
        current_env;
      State.add_to_dependencies !all_paths;
      (* Record accumulated dependencies as blacklist for this premise *)
      (* This includes both the condition fields (added in on_prem_enter) and variable dependencies *)
      let final_deps = State.get_current_dependencies () in
      let dep_list = FieldPathSet.elements final_deps in
      if dep_list <> [] then
        let key = Premise_uid.prem_key prem in
        match Premise_uid.get_uid key with
        | Some uid -> State.add_blacklist uid dep_list
        | None -> ())

  (* Noop - logic moved to on_prem_enter/on_prem_exit *)
  let on_prem_fields = Instrumentation_core.Noop.on_prem_fields
  let on_instr = Instrumentation_core.Noop.on_instr

  let finish () =
    Format.fprintf !fmt "\n=== Negative Dependencies (Blacklists) ===\n\n%!";
    (* Collect and sort by premise UID for stable, readable output *)
    let entries =
      Hashtbl.fold
        (fun uid paths acc -> (uid, paths) :: acc)
        State.blacklists []
    in
    let sorted =
      List.sort (fun (uid1, _) (uid2, _) -> compare uid1 uid2) entries
    in
    List.iter
      (fun (uid, paths) ->
        Format.fprintf !fmt "premise %d:\n" uid;
        List.iter
          (fun path ->
            let path_str =
              String.concat ", " (List.map string_of_field_path path)
            in
            Format.fprintf !fmt "  [%s]\n" path_str)
          paths;
        Format.fprintf !fmt "\n")
      sorted;
    Format.pp_print_flush !fmt ()
end

(* Result type for programmatic access *)
type result = {
  blacklists : (int * path_condition list) list;
      (* premise_uid -> list of field_path lists *)
}

let get_result () =
  {
    blacklists =
      Hashtbl.fold
        (fun uid paths acc -> (uid, paths) :: acc)
        State.blacklists [];
  }

let restore result =
  Hashtbl.clear State.blacklists;
  List.iter
    (fun (uid, paths) -> Hashtbl.replace State.blacklists uid paths)
    result.blacklists

module HandlerWithData :
  Instrumentation_core.Handler.S_with_data with type result = result = struct
  include M

  type nonrec result = result

  let get_result = get_result
  let restore = restore
end

(* Declare static analysis dependencies *)
let static_dependencies () =
  [
    (module Instrumentation_static.Premise_uid.Premise_uid
    : Instrumentation_static.Static.S);
    (module Instrumentation_static.Mutator_analysis.Mutator_analysis
    : Instrumentation_static.Static.S);
  ]

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
