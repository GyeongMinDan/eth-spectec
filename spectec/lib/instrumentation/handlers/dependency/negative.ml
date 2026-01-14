(* Negative dependency analysis for test mutation guidance.

   Collects path conditions (conjunctions of if-premises) leading to each
   premise. This provides "negative dependencies" - fields that should NOT
   be mutated because they're part of the path condition.

   Key features:
   - Per-premise blacklist: aggregates field paths that must not change
   - Over-approximation: captures all involved fields (simpler than positive)
   - Could use Il.path in future for more precise tracking

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

(* === Negative-Analysis Specific Types === *)

(* Path condition: a list of fields involved in if-premises leading to target *)
type path_condition = field_access list

(* Handler configuration *)
type level = Summary | Full
type config = { level : level; output : Instrumentation_core.Output.t }

let default_config =
  { level = Summary; output = Instrumentation_core.Output.stdout }

let config = ref default_config
let fmt = ref Format.std_formatter

(* === Expression Resolution (Negative-specific: simpler over-approximation) === *)

(* Resolve an expression to a field access - simpler than positive analysis.
 * We only need to track fields involved, not full symbolic expressions.
 *)
let rec resolve_to_path (env : source_env) (exp : Il.exp) : field_access option
    =
  match exp.it with
  | Il.VarE id -> (
      match C.lookup_source env id.it with
      | Some access -> Some access
      | None -> Some { source = Unknown; fields = [ id.it ] })
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
  | Il.IdxE (base, idx) -> (
      match (resolve_to_path env base, resolve_to_path env idx) with
      | Some base_path, Some idx_path ->
          let idx_str = String.concat "." idx_path.fields in
          Some (C.append_field base_path ("[" ^ idx_str ^ "]"))
      | Some base_path, None -> Some (C.append_field base_path "[?]")
      | _ -> None)
  | Il.LenE base -> (
      match resolve_to_path env base with
      | Some path -> Some (C.append_field path "|length|")
      | None -> None)
  | Il.NumE _ -> None
  | Il.BoolE _ -> None
  | Il.TextE _ -> None
  | Il.SubE (inner, _) -> resolve_to_path env inner
  | Il.UpCastE (_, inner) -> resolve_to_path env inner
  | Il.DownCastE (_, inner) -> resolve_to_path env inner
  | Il.IterE (inner, _) -> resolve_to_path env inner
  | Il.OptE (Some inner) -> resolve_to_path env inner
  | Il.OptE None -> None
  | Il.CallE _ -> None (* Function calls: return None for simplicity *)
  | Il.MatchE (inner, _) -> (
      match resolve_to_path env inner with
      | Some access ->
          let path_str = String.concat "." access.fields in
          Some
            { source = access.source; fields = [ path_str ^ " matches ..." ] }
      | None -> None)
  | _ -> None

(* Extract all fields from a comparison expression *)
let extract_fields_from_cmp (env : source_env) (exp : Il.exp) :
    field_access list =
  let exp1, _ = C.strip_negation exp in
  let exp2, _ = C.strip_bool_eq exp1 in

  match exp2.it with
  | Il.CmpE (_, _, lhs, rhs) ->
      let fields = ref [] in
      (match resolve_to_path env lhs with
      | Some f -> fields := f :: !fields
      | None -> ());
      (match resolve_to_path env rhs with
      | Some f -> fields := f :: !fields
      | None -> ());
      !fields
  | _ -> []

(* === Handler State === *)
module State = struct
  let env : source_env = C.create_env ()
  let relation_inputs : (string, string list) Hashtbl.t = Hashtbl.create 50
  let current_relation : string ref = ref ""

  (* Track if we're in a selected premise *)
  let in_selected_premise : bool ref = ref false
  let current_premise_uid : int option ref = ref None

  (* Per-premise blacklist: premise_uid -> path_condition list *)
  let blacklists : (int, path_condition list) Hashtbl.t = Hashtbl.create 1000

  let reset () =
    C.clear_env env;
    Hashtbl.clear relation_inputs;
    current_relation := "";
    in_selected_premise := false;
    current_premise_uid := None;
    Hashtbl.clear blacklists

  let add_blacklist (premise_uid : int) (fields : field_access list) =
    if fields <> [] then
      let existing =
        match Hashtbl.find_opt blacklists premise_uid with
        | Some bl -> bl
        | None -> []
      in
      (* Only add if not already present *)
      if not (List.mem fields existing) then
        Hashtbl.replace blacklists premise_uid (fields :: existing)
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

  let on_test_start = Instrumentation_core.Noop.on_test_start
  let on_test_end = Instrumentation_core.Noop.on_test_end

  let on_rel_enter ~id ~at:_ ~values =
    State.current_relation := id;
    C.bind_state_transition_inputs State.env State.relation_inputs id values

  let on_rel_exit ~id:_ ~at:_ ~success:_ =
    State.current_relation := "";
    C.clear_env State.env

  let on_rule_enter ~id:_ ~rule_id:_ ~at:_ = ()
  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success:_ = ()
  let on_func_enter = Instrumentation_core.Noop.on_func_enter
  let on_func_exit = Instrumentation_core.Noop.on_func_exit
  let on_clause_enter = Instrumentation_core.Noop.on_clause_enter
  let on_clause_exit = Instrumentation_core.Noop.on_clause_exit
  let on_iter_prem_enter = Instrumentation_core.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit

  let on_prem_enter ~prem ~at:_ =
    if C.is_whitelisted !State.current_relation then
      match prem.it with
      | Il.IfPr _ -> (
          let key = Premise_uid.prem_key prem in
          match Premise_uid.get_uid key with
          | Some uid ->
              State.in_selected_premise := true;
              State.current_premise_uid := Some uid
          | None -> ())
      | _ -> ()

  let on_prem_exit ~prem ~at:_ ~success =
    if !State.in_selected_premise then
      match prem.it with
      | Il.IfPr exp ->
          (* Extract fields and record as blacklist *)
          let fields = extract_fields_from_cmp State.env exp in
          (* Only record fields that resolve to state/block *)
          let resolved_fields =
            List.filter
              (fun f -> match f.source with Unknown -> false | _ -> true)
              fields
          in
          (if success && resolved_fields <> [] then
             match !State.current_premise_uid with
             | Some uid -> State.add_blacklist uid resolved_fields
             | None -> ());
          State.in_selected_premise := false;
          State.current_premise_uid := None
      | _ -> ()

  (* Track let bindings to update source environment *)
  let on_prem_fields ~prem ~fields:_ ~lookup:_ ~at:_ =
    match prem.it with
    | Il.LetPr ({ it = Il.VarE id; _ }, rhs) -> (
        match resolve_to_path State.env rhs with
        | Some path -> C.bind_source State.env id.it path
        | None -> ())
    | _ -> ()

  let on_instr = Instrumentation_core.Noop.on_instr

  let finish () =
    Format.fprintf !fmt "\n=== Negative Dependencies (Blacklists) ===\n\n";
    Hashtbl.iter
      (fun uid paths ->
        Format.fprintf !fmt "premise %d:\n" uid;
        List.iter
          (fun path ->
            let path_str =
              String.concat ", " (List.map C.string_of_field_access path)
            in
            Format.fprintf !fmt "  [%s]\n" path_str)
          paths;
        Format.fprintf !fmt "\n")
      State.blacklists
end

(* Result type for programmatic access *)
type result = {
  blacklists : (int * path_condition list) list;
      (* premise_uid -> list of field_access lists *)
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
