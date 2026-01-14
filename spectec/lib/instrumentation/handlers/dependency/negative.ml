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

type premise_path_conditions = {
  premise_uid : string; (* Premise UID as string *)
  path_conditions : path_condition list;
      (* Multiple paths can reach this premise *)
}

(* === Handler State === *)
module State = struct
  (* Source environment: maps variable names to their field accesses *)
  let env : source_env = C.create_env ()

  (* Relation input variable names (from spec) *)
  let relation_inputs : (string, string list) Hashtbl.t = Hashtbl.create 50

  (* Current relation being analyzed *)
  let current_relation : string ref = ref ""

  (* Path condition stack: not used in simplified version *)
  (* let path_stack : path_condition list ref = ref [] *)

  (* Collected path conditions: premise_uid -> path_condition list *)
  let collected : (string, path_condition list) Hashtbl.t = Hashtbl.create 1000

  (* Whitelist: if non-empty, only analyze these relations *)
  let whitelist : string list ref = ref []

  (* Track if we're in a selected premise *)
  let in_selected_premise : bool ref = ref false
  let current_premise_uid : string option ref = ref None

  let reset () =
    C.clear_env env;
    Hashtbl.clear relation_inputs;
    current_relation := "";
    (* path_stack := []; *)
    Hashtbl.clear collected;
    in_selected_premise := false;
    current_premise_uid := None

  (* Check if relation is whitelisted *)
  let is_whitelisted rel =
    match !whitelist with
    | [] -> true (* empty whitelist = analyze all *)
    | wl -> List.mem rel wl

  (* Simplified: no frame tracking needed *)
end

(* === Handler Implementation === *)

module M : Instrumentation_core.Handler.S = struct
  let init ~spec =
    State.reset ();
    Hashtbl.clear State.relation_inputs;
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
                  Hashtbl.replace State.relation_inputs id.it input_vars
            | _ -> ())
          il_spec
    | Instrumentation_core.Handler.SlSpec _ ->
        ();
        (* Use same whitelist as dependency *)
        State.whitelist :=
          [
            "State_transition";
            "ProcessBlockHeader";
            "ProcessWithdrawals";
            "ProcessExecutionPayload";
            "ProcessRandao";
            "ProcessEth1Data";
            "ProcessSyncAggregate";
            "ProcessProposerSlashing";
            "ProcessAttesterSlashing";
            "ProcessAttestation";
            "ProcessDeposit";
            "ProcessVoluntaryExit";
            "ProcessBlsToExecutionChange";
            "ProcessSlot";
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

  let on_test_start = Instrumentation_core.Noop.on_test_start
  let on_test_end = Instrumentation_core.Noop.on_test_end

  (* Track relation entry: bind input variables *)
  let on_rel_enter ~id ~at:_ ~values =
    State.current_relation := id;
    (* For State_transition, bind input variables to state and block *)
    if id = "State_transition" then
      match Hashtbl.find_opt State.relation_inputs id with
      | Some input_vars -> (
          match (input_vars, values) with
          | state_var :: block_var :: _, _state_val :: _block_val :: _ ->
              (* Bind state variable to state input *)
              C.bind_source State.env state_var { source = State; fields = [] };
              (* Bind block variable to block input *)
              C.bind_source State.env block_var { source = Block; fields = [] }
          | _ -> ())
      | None -> ()

  let on_rel_exit ~id:_ ~at:_ ~success:_ =
    State.current_relation := "";
    C.clear_env State.env

  let on_rule_enter ~id:_ ~rule_id:_ ~at:_ =
    () (* Simplified: no frame tracking *)

  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success:_ = () (* Simplified *)
  let on_func_enter = Instrumentation_core.Noop.on_func_enter
  let on_func_exit = Instrumentation_core.Noop.on_func_exit
  let on_clause_enter = Instrumentation_core.Noop.on_clause_enter
  let on_clause_exit = Instrumentation_core.Noop.on_clause_exit
  let on_iter_prem_enter = Instrumentation_core.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit

  (* Track premise entry: check if it's selected and start tracking *)
  let on_prem_enter ~prem ~at =
    (* Simplified: only track if-premises in whitelisted relations *)
    if State.is_whitelisted !State.current_relation then
      match prem.it with
      | Il.IfPr _ ->
          (* Create UID string from premise location *)
          let uid_str =
            Printf.sprintf "%s:%d-%d" !State.current_relation at.left.line
              at.right.line
          in
          State.in_selected_premise := true;
          State.current_premise_uid := Some uid_str
          (* Don't push frame - we'll collect fields directly *)
      | _ -> ()

  (* Track premise exit: record path condition if selected *)
  let on_prem_exit ~prem ~at:_ ~success =
    if !State.in_selected_premise then
      match prem.it with
      | Il.IfPr exp ->
          (* Simplified: just extract fields and record them directly *)
          let fields = extract_fields_from_cmp State.env exp in
          (* Only record fields that resolve to state/block (not Unknown) *)
          let resolved_fields =
            List.filter
              (fun f -> match f.source with Unknown -> false | _ -> true)
              fields
          in
          (if success && resolved_fields <> [] then
             match !State.current_premise_uid with
             | Some uid ->
                 let existing =
                   match Hashtbl.find_opt State.collected uid with
                   | Some paths -> paths
                   | None -> []
                 in
                 (* Only add if not already present *)
                 if not (List.mem resolved_fields existing) then
                   Hashtbl.replace State.collected uid
                     (resolved_fields :: existing)
             | None -> ());
          State.in_selected_premise := false;
          State.current_premise_uid := None
      | _ -> ()

  (* Track let bindings to update source environment *)
  let on_prem_fields ~prem ~fields:_ ~lookup:_ ~at:_ =
    match prem.it with
    | Il.LetPr ({ it = Il.VarE id; _ }, rhs) -> (
        (* Bind LHS var to RHS path *)
        match resolve_to_path State.env rhs with
        | Some path -> C.bind_source State.env id.it path
        | None -> ())
    | _ -> ()

  let on_instr = Instrumentation_core.Noop.on_instr

  let finish () =
    (* Output collected path conditions *)
    Format.printf "\n=== Path Conditions ===\n\n";
    Hashtbl.iter
      (fun uid paths ->
        Format.printf "premise %s:\n" uid;
        List.iter
          (fun path ->
            let string_of_field_access (access : field_access) : string =
              let string_of_input_source = function
                | State -> "state"
                | Block -> "block"
                | Unknown -> "?"
              in
              match (access.source, access.fields) with
              | Unknown, [] -> "?"
              | Unknown, fields -> (
                  match fields with
                  | "state" :: rest -> "state" ^ "." ^ String.concat "." rest
                  | "block" :: rest -> "block" ^ "." ^ String.concat "." rest
                  | _ -> "?." ^ String.concat "." fields)
              | source, [] -> string_of_input_source source
              | source, fields ->
                  string_of_input_source source ^ "." ^ String.concat "." fields
            in
            let path_str =
              String.concat ", " (List.map string_of_field_access path)
            in
            Format.printf "  [%s]\n" path_str)
          paths;
        Format.printf "\n")
      State.collected
end

let make cfg : (module Instrumentation_core.Handler.S) =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  (module M)

(* Result type for programmatic access *)
type result = {
  path_conditions : (string * path_condition list) list;
      (* premise_uid -> path_condition list *)
}

let get_result () =
  {
    path_conditions =
      Hashtbl.fold (fun uid paths acc -> (uid, paths) :: acc) State.collected [];
  }

(* Handler with data access *)
module HandlerWithData :
  Instrumentation_core.Handler.S_with_data with type result = result = struct
  include M

  type nonrec result = result

  let get_result = get_result
  let restore _result = () (* Path conditions are derived, not restored *)
end

let make_with_data cfg =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  ( (module HandlerWithData : Instrumentation_core.Handler.S_with_data
      with type result = result),
    get_result )
