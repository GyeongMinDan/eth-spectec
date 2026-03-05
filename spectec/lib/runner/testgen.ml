(* Testgen backend - generates test cases by mutating JSON inputs to target uncovered premises.

   Pipeline:
   1. Run test suite with node-coverage-il to get premise-to-testid mapping
   2. Select uncovered premise UIDs to target
   3. Derive mutation constraints from positive dependency analysis
   4. Mutate JSON inputs; write results to output directory *)

open Common.Source
module Il = Lang.Il
module Checkpoint = Checkpoint
module Dep = Instrumentation.Dependency.Dep_common
module Pos = Instrumentation.Dependency.Positive
module Node_cov = Instrumentation.Node_coverage_il
module Type_tree = Instrumentation.Type_tree

(* ===== Types ===== *)

type premise_uid = int
type test_case_id = string
type field_path = Dep.field_path

type mutation_constraint = {
  field_path : field_path;
  strategies : Json_mutator.mutation_strategy list;
  suggestion_str : string option;
}

type premise_info = {
  uid : premise_uid;
  key : region * string;
  relation : string;
  rule : string;
  content : string;
}

(* Outcome of one (constraint × strategy) attempt, recorded for reporting only. *)
type constraint_outcome =
  | MutationOk of {
      field : field_path;
      prems : premise_uid list;
      suggestion : string option;
      from_val : string;
      to_val : string;
    }
  | FieldNotFound of {
      field : field_path;
      prems : premise_uid list;
      src_label : string;
    }
  | JsonLoadFailed of { field : field_path; prems : premise_uid list }

(* All diagnostic data produced by process_test_case.
   Never drives control flow — consumed only by the presentation layer. *)
type process_diag = {
  prems_no_muts : premise_uid list;
  prems_no_constraints : premise_uid list;
  constraint_outcomes : constraint_outcome list;
  covered_prems : premise_uid list;
}

(* ===== Slot-gap utilities ===== *)

let json_to_int = function
  | `Int n -> Some n
  | `Intlit s | `String s -> (
      try Some (int_of_string s) with Failure _ -> None)
  | _ -> None

let json_get_int (json : Yojson.Safe.t) (path : Dep.field_step list) :
    int option =
  Option.bind (Json_mutator.get_field json path) json_to_int

let state_slot_path = [ Dep.FieldAccess "slot" ]
let block_msg_slot_path = [ Dep.FieldAccess "message"; Dep.FieldAccess "slot" ]
let block_slot_path = [ Dep.FieldAccess "slot" ]
let get_state_slot (json : Yojson.Safe.t) = json_get_int json state_slot_path

(* Tries message.slot first (signed block envelope), then slot directly. *)
let get_block_slot (json : Yojson.Safe.t) =
  match json_get_int json block_msg_slot_path with
  | Some _ as r -> r
  | None -> json_get_int json block_slot_path

let get_slot_gap (pre_json : Yojson.Safe.t) (block_json : Yojson.Safe.t) :
    int option =
  match (get_state_slot pre_json, get_block_slot block_json) with
  | Some s, Some b -> Some (b - s)
  | _ -> None

(* Strip /pre.json suffix to get the test case directory path. *)
let test_id_to_dir (test_id : string) : string =
  if String.ends_with ~suffix:"/pre.json" test_id then
    String.sub test_id 0 (String.length test_id - 9)
  else test_id

(* The spec's main loop replays state transitions from state.slot up to block.slot - 1.
   Large gaps cause extremely slow execution; this checks whether a seed is within the limit. *)
let slot_gap_within_limit ~(test_dir : string) ~(max_slot_gap : int)
    (test_id : string) : bool =
  let dir = test_id_to_dir test_id in
  let load f = try Some (Json_mutator.load_json f) with _ -> None in
  match
    ( load (Filename.concat test_dir (dir ^ "/pre.json")),
      load (Filename.concat test_dir (dir ^ "/block.json")) )
  with
  | Some pre, Some block -> (
      match get_slot_gap pre block with
      | Some gap -> gap <= max_slot_gap
      | None -> true)
  | _ -> true

(* Cap block_slot so that block_slot - state_slot <= max_slot_gap. *)
let cap_slot_gap ~(max_slot_gap : int) (pre_json : Yojson.Safe.t)
    (block_json : Yojson.Safe.t) : Yojson.Safe.t =
  match (get_slot_gap pre_json block_json, get_state_slot pre_json) with
  | Some gap, Some state_slot when gap > max_slot_gap ->
      let capped = `Intlit (string_of_int (state_slot + max_slot_gap)) in
      let slot_path =
        if Option.is_some (json_get_int block_json block_msg_slot_path) then
          block_msg_slot_path
        else block_slot_path
      in
      Json_mutator.set_field block_json slot_path capped
  | _ -> block_json

(* ===== List-field utilities ===== *)

(* Ethereum beacon-chain fields that are known to be lists. *)
let known_list_fields =
  [
    "validators";
    "attestations";
    "attester_slashings";
    "proposer_slashings";
    "deposits";
    "voluntary_exits";
    "bls_to_execution_changes";
    "sync_committee";
    "historical_roots";
    "historical_summaries";
    "randao_mixes";
    "balances";
    "inactivity_scores";
    "previous_epoch_participation";
    "current_epoch_participation";
    "slashings";
  ]

let is_list_field_name (name : string) : bool =
  let lower = String.lowercase_ascii name in
  List.mem lower known_list_fields
  || (String.ends_with ~suffix:"s" lower && String.length lower > 1)

(* Returns true if the path's final step points at a list field or index. *)
let is_list_path (steps : Dep.field_step list) : bool =
  match List.rev steps with
  | Dep.FieldAccess name :: _ -> is_list_field_name name
  | Dep.IndexAccess _ :: _ -> true
  | [] -> false

(* Look up element type for a list field name.
   Tries singularizing (drop trailing 's'), then well-known aliases. *)
let lookup_list_elem_type (field_name : string) : Type_tree.typ option =
  let name = String.lowercase_ascii field_name in
  let singular =
    if String.length name > 1 && name.[String.length name - 1] = 's' then
      String.sub name 0 (String.length name - 1)
    else name
  in
  let well_known =
    [
      ("randao_mixes", "bytes32");
      ("historical_roots", "root");
      ("balances", "uint64");
      ("inactivity_scores", "uint64");
      ("previous_epoch_participation", "participationflags");
      ("current_epoch_participation", "participationflags");
      ("slashings", "gwei");
    ]
  in
  match List.assoc_opt name well_known with
  | Some type_name -> Type_tree.lookup_ci type_name
  | None -> (
      match Type_tree.lookup_ci singular with
      | Some _ as r -> r
      | None -> Type_tree.lookup_ci name)

(* Build an AppendRandom strategy using the type tree, templated from the first existing element. *)
let make_append_random_strategy (field_name : string)
    (source_value : Yojson.Safe.t) : Json_mutator.mutation_strategy option =
  match lookup_list_elem_type field_name with
  | None -> None
  | Some elem_typ ->
      let new_elem =
        match source_value with
        | `List (first :: _) -> Type_tree.template_fill elem_typ first
        | _ -> Type_tree.random_value elem_typ
      in
      Some (Json_mutator.AppendRandom new_elem)

(* ===== Strategy generation ===== *)

let max_uint64 = Bigint.of_string "18446744073709551615"
let min_value = Bigint.of_int 0

let extract_numeric_value (v : Il.Value.t) : Bigint.t option =
  match v.it with Il.NumV (`Nat n) | Il.NumV (`Int n) -> Some n | _ -> None

let bigint_to_intlit (n : Bigint.t) : string = Bigint.to_string n

let value_to_json (v : Il.Value.t) : (Yojson.Safe.t, string) result =
  match Interface.JSON.Print.value_to_json v with
  | Ok json -> Ok json
  | Error err -> Error (Interface.JSON.Print.string_of_error err)

(* Generate mutation strategies for a ToConst constraint.
   For each comparison operator, produces values that satisfy the constraint (e.g., >= n → [n, MAX]). *)
let generate_toconst_strategies (op : Il.cmpop) (value : Il.Value.t)
    (source_value_opt : Yojson.Safe.t option) :
    Json_mutator.mutation_strategy list =
  match value.it with
  | Il.BoolV b -> (
      match source_value_opt with
      | Some (`Bool src) -> [ Json_mutator.SetValue (`Bool (not src)) ]
      | _ -> [ Json_mutator.SetValue (`Bool (not b)) ])
  | _ -> (
      match extract_numeric_value value with
      | Some n -> (
          let n_str = bigint_to_intlit n in
          let max_str = bigint_to_intlit max_uint64 in
          let min_str = bigint_to_intlit min_value in
          match op with
          | `GeOp ->
              [
                Json_mutator.SetValue (`Intlit n_str);
                Json_mutator.SetValue (`Intlit max_str);
              ]
          | `LeOp ->
              [
                Json_mutator.SetValue (`Intlit n_str);
                Json_mutator.SetValue (`Intlit min_str);
              ]
          | `GtOp -> (
              match Bigint.to_int n with
              | Some i ->
                  [
                    Json_mutator.SetValue
                      (`Intlit (bigint_to_intlit (Bigint.of_int (i + 1))));
                    Json_mutator.SetValue (`Intlit max_str);
                  ]
              | None -> [ Json_mutator.SetValue (`Intlit max_str) ])
          | `LtOp -> (
              match Bigint.to_int n with
              | Some i when i > 0 ->
                  [
                    Json_mutator.SetValue
                      (`Intlit (bigint_to_intlit (Bigint.of_int (i - 1))));
                    Json_mutator.SetValue (`Intlit max_str);
                  ]
              | _ -> [ Json_mutator.SetValue (`Intlit max_str) ])
          | `EqOp -> [ Json_mutator.SetValue (`Intlit n_str) ]
          | `NeOp -> (
              match Bigint.to_int n with
              | Some i ->
                  let lo = if i > 0 then Bigint.of_int (i - 1) else min_value in
                  [
                    Json_mutator.SetValue (`Intlit (bigint_to_intlit lo));
                    Json_mutator.SetValue
                      (`Intlit (bigint_to_intlit (Bigint.of_int (i + 1))));
                  ]
              | None -> [ Json_mutator.SetValue (`Intlit n_str) ]))
      | None -> (
          match value_to_json value with
          | Ok json -> [ Json_mutator.SetValue json ]
          | Error _ -> []))

(* Generate mutation strategies for a ToLength constraint (list-length variant of ToConst). *)
let generate_tolength_strategies (op : Il.cmpop) (value : Il.Value.t) :
    Json_mutator.mutation_strategy list =
  match extract_numeric_value value with
  | None -> [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ]
  | Some n -> (
      match Bigint.to_int n with
      | None -> [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ]
      | Some n_int -> (
          match op with
          | `GeOp ->
              [
                Json_mutator.SetLength n_int; Json_mutator.SetLength (2 * n_int);
              ]
          | `LeOp -> [ Json_mutator.SetLength n_int; Json_mutator.SetLength 0 ]
          | `GtOp ->
              [
                Json_mutator.SetLength (n_int + 1);
                Json_mutator.SetLength (2 * n_int);
              ]
          | `LtOp ->
              if n_int > 0 then
                [
                  Json_mutator.SetLength (n_int - 1);
                  Json_mutator.SetLength (2 * n_int);
                ]
              else [ Json_mutator.SetLength (2 * n_int) ]
          | `EqOp -> [ Json_mutator.SetLength n_int ]
          | `NeOp ->
              if n_int > 0 then
                [
                  Json_mutator.SetLength (n_int - 1);
                  Json_mutator.SetLength (n_int + 1);
                ]
              else [ Json_mutator.SetLength (n_int + 1) ]))

(* Strategies for Unknown hints carrying a concrete IL value (boundary + complement). *)
let strategies_from_il_value (v : Il.Value.t) :
    Json_mutator.mutation_strategy list =
  match v.it with
  | Il.NumV (`Nat _) | Il.NumV (`Int _) ->
      [
        Json_mutator.SetValue (`Intlit "0");
        Json_mutator.SetValue (`Intlit "18446744073709551615");
      ]
  | Il.BytesV { len; _ } ->
      [
        Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) '0'));
        Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) 'f'));
      ]
  | Il.BoolV _ ->
      [
        Json_mutator.SetValue (`Bool true); Json_mutator.SetValue (`Bool false);
      ]
  | Il.ListV items ->
      let n = List.length items in
      if n = 0 then []
      else [ Json_mutator.SetLength (2 * n); Json_mutator.SetLength 0 ]
  | _ -> []

(* Strategies for Unknown hints carrying only a type name (boundary values per type). *)
let strategies_from_il_type (t : Il.typ') : Json_mutator.mutation_strategy list
    =
  match t with
  | Il.NumT (`NatT | `IntT) ->
      [
        Json_mutator.SetValue (`Intlit "0");
        Json_mutator.SetValue (`Intlit "18446744073709551615");
      ]
  | Il.BoolT ->
      [
        Json_mutator.SetValue (`Bool true); Json_mutator.SetValue (`Bool false);
      ]
  | Il.TextT ->
      [
        Json_mutator.SetValue (`String "");
        Json_mutator.SetValue (`String "mutated_string");
      ]
  | Il.VarT (id, _) ->
      let name = String.lowercase_ascii id.it in
      if String.length name >= 5 && String.sub name 0 5 = "bytes" then
        let len =
          try int_of_string (String.sub name 5 (String.length name - 5))
          with _ -> 32
        in
        [
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) '0'));
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) 'f'));
        ]
      else if name = "boolean" || name = "bool" then
        [
          Json_mutator.SetValue (`Bool true);
          Json_mutator.SetValue (`Bool false);
        ]
      else if
        List.mem name
          [ "uint64"; "slot"; "epoch"; "validatorindex"; "nat"; "int" ]
      then
        [
          Json_mutator.SetValue (`Intlit "0");
          Json_mutator.SetValue (`Intlit "18446744073709551615");
        ]
      else if List.mem name [ "root"; "hash32"; "blspubkey"; "blssignature" ]
      then
        let len =
          if name = "blspubkey" || name = "blssignature" then 48 else 32
        in
        [
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) '0'));
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) 'f'));
        ]
      else []
  | _ -> []

let strategies_from_hint (hint : Pos.unknown_hint) :
    Json_mutator.mutation_strategy list =
  match hint with
  | Pos.ValueHint v -> strategies_from_il_value v
  | Pos.TypeHint t -> strategies_from_il_type t
  | Pos.NoHint -> []

let deduplicate_strategies (strategies : Json_mutator.mutation_strategy list) :
    Json_mutator.mutation_strategy list =
  List.sort_uniq
    (fun s1 s2 ->
      match (s1, s2) with
      | Json_mutator.SetValue v1, Json_mutator.SetValue v2 ->
          String.compare (Yojson.Safe.to_string v1) (Yojson.Safe.to_string v2)
      | Json_mutator.SetLength l1, Json_mutator.SetLength l2 -> compare l1 l2
      | Json_mutator.Increment i1, Json_mutator.Increment i2 -> compare i1 i2
      | Json_mutator.Decrement i1, Json_mutator.Decrement i2 -> compare i1 i2
      | _ -> compare s1 s2)
    strategies

(* ===== Building mutation constraints ===== *)

(* Generate mutation strategies for a sym_mutation target path and suggestion. *)
let strategies_for_sym_mutation (target_path : field_path)
    (suggestion : Pos.mutation_kind) =
  match suggestion with
  | Pos.ToConst (op, v) ->
      if is_list_path target_path.steps then []
      else generate_toconst_strategies op v None
  | Pos.ToLength (op, v) -> generate_tolength_strategies op v
  | Pos.Unknown hint ->
      if is_list_path target_path.steps then [] else strategies_from_hint hint

(* A target path is valid if it names a specific field rather than the whole state or an unknown source. *)
let is_valid_target (path : field_path) : bool =
  (not (path.source = Dep.Unknown))
  && not (path.source = Dep.State && path.steps = [])

(* Convert a symbolic mutation from the dependency analysis into a mutation constraint.
   Returns None if the target is invalid or no strategies apply. *)
let sym_mutation_to_constraint (sym_mut : Pos.sym_mutation) :
    mutation_constraint option =
  match sym_mut.target_path with
  | None -> None
  | Some target_path when not (is_valid_target target_path) -> None
  | Some target_path ->
      let strategies =
        strategies_for_sym_mutation target_path sym_mut.suggestion
        |> deduplicate_strategies
      in
      if strategies = [] then None
      else
        Some
          {
            field_path = target_path;
            strategies;
            suggestion_str = Some (Pos.string_of_sym_mutation sym_mut);
          }

(* ===== Strategy application ===== *)

(* True if applying this strategy to source_value would be a no-op. *)
let is_identity_strategy (source_value : Yojson.Safe.t)
    (strategy : Json_mutator.mutation_strategy) : bool =
  match (source_value, strategy) with
  | `Bool a, Json_mutator.SetValue (`Bool b) -> a = b
  | `Int a, Json_mutator.SetValue (`Int b) -> a = b
  | `Intlit a, Json_mutator.SetValue (`Intlit b) -> a = b
  | `String a, Json_mutator.SetValue (`String b) -> a = b
  | `List lst, Json_mutator.SetLength n -> List.length lst = n
  | _ -> false

(* For boolean fields, flip the actual source value rather than a predetermined one. *)
let adjust_bool_strategy (source_value : Yojson.Safe.t)
    (strategy : Json_mutator.mutation_strategy) : Json_mutator.mutation_strategy
    =
  match (source_value, strategy) with
  | `Bool src, Json_mutator.SetValue (`Bool _) ->
      Json_mutator.SetValue (`Bool (not src))
  | _ -> strategy

(* For list paths with no pre-computed strategies, derive strategies from the source length. *)
let list_strategies_from_source (fp : field_path) source_value =
  match source_value with
  | `List [] -> []
  | `List lst ->
      let n = List.length lst in
      let len_strats =
        [ Json_mutator.SetLength (2 * n); Json_mutator.SetLength 0 ]
      in
      let append_strat =
        match List.rev fp.steps with
        | Dep.FieldAccess name :: _ ->
            make_append_random_strategy name source_value
        | _ -> None
      in
      len_strats @ Option.to_list append_strat
  | _ -> []

(* Compute the valid, adjusted strategies for a constraint given the current source value. *)
let resolve_strategies (constraint_ : mutation_constraint)
    (source_value : Yojson.Safe.t) : Json_mutator.mutation_strategy list =
  let is_list = is_list_path constraint_.field_path.steps in
  let base =
    if source_value = `List [] then []
    else
      List.filter
        (fun s -> not (is_identity_strategy source_value s))
        constraint_.strategies
  in
  let extra =
    if is_list && constraint_.strategies = [] then
      list_strategies_from_source constraint_.field_path source_value
    else []
  in
  List.map (adjust_bool_strategy source_value) (base @ extra)

(* Look up the current value at the constraint's target path in the appropriate JSON. *)
let source_value_of_constraint (constraint_ : mutation_constraint)
    (pre_json_opt : Yojson.Safe.t option)
    (block_json_opt : Yojson.Safe.t option) : Yojson.Safe.t option =
  match (constraint_.field_path.source, pre_json_opt, block_json_opt) with
  | Dep.State, Some pre, _ ->
      Json_mutator.get_value_at_path pre constraint_.field_path
  | Dep.Block, _, Some blk ->
      Json_mutator.get_value_at_path blk constraint_.field_path
  | Dep.Local _, Some pre, _ -> (
      match Json_mutator.get_value_at_path pre constraint_.field_path with
      | Some _ as v -> v
      | None ->
          Option.bind block_json_opt (fun blk ->
              Json_mutator.get_value_at_path blk constraint_.field_path))
  | _ -> None

(* ===== Constraint deduplication helpers ===== *)

let strategy_to_display_string : Json_mutator.mutation_strategy -> string =
  function
  | Json_mutator.SetValue v -> Yojson.Safe.to_string v
  | Json_mutator.Increment i -> Printf.sprintf "+%d" i
  | Json_mutator.Decrement i -> Printf.sprintf "-%d" i
  | Json_mutator.SetBoundary -> "<boundary>"
  | Json_mutator.AppendItem -> "<append>"
  | Json_mutator.RemoveItem -> "<remove>"
  | Json_mutator.SetLength n -> Printf.sprintf "<length %d>" n
  | Json_mutator.AppendRandom _ -> "<append:random>"

(* Canonical string key for a strategy, used for deduplication. *)
let strategy_key : Json_mutator.mutation_strategy -> string = function
  | Json_mutator.SetValue v -> "SetValue:" ^ Yojson.Safe.to_string v
  | Json_mutator.SetLength n -> "SetLength:" ^ string_of_int n
  | Json_mutator.Increment i -> "Increment:" ^ string_of_int i
  | Json_mutator.Decrement i -> "Decrement:" ^ string_of_int i
  | Json_mutator.SetBoundary -> "SetBoundary"
  | Json_mutator.AppendItem -> "AppendItem"
  | Json_mutator.RemoveItem -> "RemoveItem"
  | Json_mutator.AppendRandom _ -> "AppendRandom"

let constraint_key (c : mutation_constraint) : string =
  Printf.sprintf "%s|%s"
    (Dep.string_of_field_path c.field_path)
    (String.concat "," (List.map strategy_key c.strategies))

let deduplicate_constraints (constraints : mutation_constraint list) :
    mutation_constraint list =
  let seen = Hashtbl.create (List.length constraints) in
  List.filter
    (fun c ->
      let k = constraint_key c in
      if Hashtbl.mem seen k then false
      else (
        Hashtbl.replace seen k ();
        true))
    constraints

(* ===== Coverage queries ===== *)

let get_uncovered_premises (coverage : Node_cov.result option) =
  match coverage with
  | None -> []
  | Some cov ->
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in
      List.filter_map
        (fun ((region, content_str), uid) ->
          let key = (region, content_str) in
          if List.mem key succeeded_keys then None
          else
            Some
              {
                uid;
                key;
                relation = "unknown";
                rule = "unknown";
                content = content_str;
              })
        cov.prem_to_uid

let get_test_cases_for_premise (puid : premise_uid)
    (coverage : Node_cov.result option) =
  match coverage with
  | None -> []
  | Some cov -> (
      let uid_to_key = List.to_seq cov.uid_to_prem |> Hashtbl.of_seq in
      match Hashtbl.find_opt uid_to_key puid with
      | None -> []
      | Some key ->
          let key_to_tests = List.to_seq cov.prem_to_test |> Hashtbl.of_seq in
          Hashtbl.find_opt key_to_tests key |> Option.value ~default:[])

let get_premise_info (puid : premise_uid) (coverage : Node_cov.result option) =
  match coverage with
  | None -> None
  | Some cov -> (
      let key =
        List.find_map
          (fun (uid, k) -> if uid = puid then Some k else None)
          cov.uid_to_prem
      in
      match key with
      | None -> None
      | Some ((_, content_str) as k) ->
          let test_cases = get_test_cases_for_premise puid coverage in
          Some
            ( {
                uid = puid;
                key = k;
                relation = "unknown";
                rule = "unknown";
                content = content_str;
              },
              test_cases ))

(* Build a mapping from test_id to the subset of target_uids that covered it. *)
let get_test_to_premises (target_uids : premise_uid list)
    (coverage : Node_cov.result option) =
  match coverage with
  | None -> []
  | Some cov ->
      let key_to_uid = Hashtbl.create 256 in
      List.iter
        (fun (key, uid) -> Hashtbl.add key_to_uid key uid)
        cov.prem_to_uid;
      let test_to_prems = Hashtbl.create 256 in
      List.iter
        (fun (prem_key, test_ids) ->
          match Hashtbl.find_opt key_to_uid prem_key with
          | Some uid when List.mem uid target_uids ->
              List.iter
                (fun test_id ->
                  let existing =
                    Hashtbl.find_opt test_to_prems test_id
                    |> Option.value ~default:[]
                  in
                  if not (List.mem uid existing) then
                    Hashtbl.replace test_to_prems test_id (uid :: existing))
                test_ids
          | _ -> ())
        cov.prem_to_test;
      Hashtbl.to_seq test_to_prems
      |> List.of_seq
      |> List.map (fun (test_id, uids) -> (test_id, List.sort compare uids))
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* Collect and filter sym_mutations for a single premise across all tests. *)
let get_mutation_suggestions_for_premise (puid : premise_uid)
    (dependency : Pos.result option) =
  match dependency with
  | None -> []
  | Some dep -> (
      match List.assoc_opt puid dep.per_test_sym_mutations with
      | None -> []
      | Some test_muts ->
          let all =
            List.fold_left (fun acc (_, muts) -> acc @ muts) [] test_muts
          in
          List.filter
            (fun (mut : Pos.sym_mutation) ->
              match mut.target_path with
              | None -> false
              | Some path -> is_valid_target path)
            all)

(* Collect and deduplicate sym_mutations for multiple premises filtered to a specific test_id. *)
let get_mutation_suggestions_for_premises (puids : premise_uid list)
    (_coverage : Node_cov.result option) (dependency : Pos.result option)
    (test_id : test_case_id) =
  match dependency with
  | None -> []
  | Some dep ->
      let all =
        List.fold_left
          (fun acc puid ->
            match List.assoc_opt puid dep.per_test_sym_mutations with
            | None -> acc
            | Some test_muts -> (
                match List.assoc_opt test_id test_muts with
                | None -> acc
                | Some muts -> acc @ muts))
          [] puids
      in
      let valid =
        List.filter
          (fun (mut : Pos.sym_mutation) ->
            match mut.target_path with
            | None -> false
            | Some path -> is_valid_target path)
          all
      in
      let compare_sym_mutation (m1 : Pos.sym_mutation) (m2 : Pos.sym_mutation) =
        match (m1.target_path, m2.target_path) with
        | Some p1, Some p2 -> (
            let path_cmp = compare p1 p2 in
            if path_cmp <> 0 then path_cmp
            else
              match (m1.suggestion, m2.suggestion) with
              | Pos.ToConst (op1, v1), Pos.ToConst (op2, v2) ->
                  let c = compare op1 op2 in
                  if c <> 0 then c
                  else
                    String.compare
                      (Il.Print.string_of_value v1)
                      (Il.Print.string_of_value v2)
              | Pos.ToLength (op1, v1), Pos.ToLength (op2, v2) ->
                  let c = compare op1 op2 in
                  if c <> 0 then c
                  else
                    String.compare
                      (Il.Print.string_of_value v1)
                      (Il.Print.string_of_value v2)
              | Pos.Unknown _, Pos.Unknown _ -> 0
              | Pos.ToConst _, _ -> -1
              | Pos.ToLength _, Pos.ToConst _ -> 1
              | Pos.ToLength _, _ -> -1
              | Pos.Unknown _, _ -> 1)
        | None, None -> 0
        | Some _, None -> -1
        | None, Some _ -> 1
      in
      List.sort_uniq compare_sym_mutation valid

let is_blacklisted (path : field_path) (blacklist : field_path list) : bool =
  List.mem path blacklist

let get_blacklisted_fields (puid : premise_uid)
    (_coverage : Node_cov.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option) =
  match path_condition with
  | None -> []
  | Some pc -> (
      match List.assoc_opt puid pc.blacklists with
      | None -> []
      | Some pcs -> List.flatten pcs)

(* ===== File I/O ===== *)

let mkdir_p (dir : string) : unit =
  try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let load_json_opt (path : string) : Yojson.Safe.t option =
  try Some (Json_mutator.load_json path) with _ -> None

(* Derive pre.json and block.json absolute paths from a test_id and base directory. *)
let test_case_paths ~(test_dir : string) (test_id : string) : string * string =
  let dir = test_id_to_dir test_id in
  ( Filename.concat test_dir (dir ^ "/pre.json"),
    Filename.concat test_dir (dir ^ "/block.json") )

(* Write mutated pre/block JSON files for a single mutation into a subdirectory.
   Returns output file paths, or input paths if mutation could not be applied. *)
let mutate_json_input ~output_dir ?(max_slot_gap : int option) (mut_id : string)
    (constraints : mutation_constraint list) (blacklisted : field_path list)
    (pre_path : string) (block_path : string) =
  let flat_id = String.map (fun c -> if c = '/' then '_' else c) mut_id in
  let mut_dir = Filename.concat output_dir flat_id in
  mkdir_p mut_dir;
  match (load_json_opt pre_path, load_json_opt block_path) with
  | None, _ | _, None -> (pre_path, block_path)
  | Some pre, Some block ->
      let apply_matching src_tag json =
        List.fold_left
          (fun acc c ->
            if is_blacklisted c.field_path blacklisted then acc
            else
              match (c.field_path.source, src_tag) with
              | Dep.State, "state" | Dep.Block, "block" -> (
                  match c.strategies with
                  | [] -> acc
                  | strategy :: _ ->
                      Json_mutator.mutate_json_file acc c.field_path strategy)
              | _ -> acc)
          json constraints
      in
      let mutated_pre = apply_matching "state" pre in
      let mutated_block_raw = apply_matching "block" block in
      let mutated_block =
        match max_slot_gap with
        | Some max_gap ->
            cap_slot_gap ~max_slot_gap:max_gap mutated_pre mutated_block_raw
        | None -> mutated_block_raw
      in
      let out_pre = Filename.concat mut_dir "pre.json" in
      let out_block = Filename.concat mut_dir "block.json" in
      Json_mutator.save_json out_pre mutated_pre;
      Json_mutator.save_json out_block mutated_block;
      (out_pre, out_block)

(* ===== Core test-case processing ===== *)

(* Apply constraints to a test case, writing mutation files.
   - constraints_with_prems: deduplicated constraints tagged with their premise UIDs
   Returns (result option, process_diag).
   result is Some (test_id, [...]) if any mutations were generated.
   process_diag holds all observability data; never drives control flow. *)
let process_test_case ~test_dir ~output_dir test_id prem_uids
    (dependency_result : Pos.result) =
  (* Collect and deduplicate constraints from all target premises.
     Track per-premise status for diagnostics. *)
  let constraint_map = Hashtbl.create 64 in
  let prem_no_muts = ref [] in
  let prem_no_constraints = ref [] in
  List.iter
    (fun puid ->
      let muts =
        get_mutation_suggestions_for_premise puid (Some dependency_result)
      in
      if muts = [] then prem_no_muts := puid :: !prem_no_muts
      else
        let any_constraint = ref false in
        List.iter
          (fun sym_mut ->
            match sym_mutation_to_constraint sym_mut with
            | None -> ()
            | Some c -> (
                any_constraint := true;
                let k = constraint_key c in
                match Hashtbl.find_opt constraint_map k with
                | None -> Hashtbl.replace constraint_map k (c, [ puid ])
                | Some (_, puids) when not (List.mem puid puids) ->
                    Hashtbl.replace constraint_map k (c, puid :: puids)
                | _ -> ()))
          muts;
        if not !any_constraint then
          prem_no_constraints := puid :: !prem_no_constraints)
    prem_uids;

  (* Collect all constraints for this seed. The same constraint key may appear
     across multiple seeds — that is intentional, since the same mutation applied
     to different base states can expose different implementation bugs. *)
  let all_constraints =
    Hashtbl.fold
      (fun _k (c, puids) acc -> (c, List.sort_uniq compare puids) :: acc)
      constraint_map []
  in

  let base_diag =
    {
      prems_no_muts = List.sort compare !prem_no_muts;
      prems_no_constraints = List.sort compare !prem_no_constraints;
      constraint_outcomes = [];
      covered_prems = [];
    }
  in

  if all_constraints = [] then (None, base_diag)
  else
    let test_case_sanitized =
      String.map (fun c -> if c = '/' then '_' else c) test_id
    in
    let out_dir = Filename.concat output_dir test_case_sanitized in
    mkdir_p out_dir;

    let pre_path, block_path = test_case_paths ~test_dir test_id in
    let pre_json_opt = load_json_opt pre_path in
    let block_json_opt = load_json_opt block_path in

    let outcomes = ref [] in
    let local_covered : (premise_uid, unit) Hashtbl.t = Hashtbl.create 16 in
    let generated = ref [] in
    List.iteri
      (fun c_idx (constraint_, puids_for_constraint) ->
        match
          source_value_of_constraint constraint_ pre_json_opt block_json_opt
        with
        | None ->
            let src_label =
              match constraint_.field_path.source with
              | Dep.State -> "<not found in state>"
              | Dep.Block -> "<not found in block>"
              | _ -> "<not found>"
            in
            outcomes :=
              FieldNotFound
                {
                  field = constraint_.field_path;
                  prems = puids_for_constraint;
                  src_label;
                }
              :: !outcomes
        | Some src ->
            let strats = resolve_strategies constraint_ src in
            List.iteri
              (fun s_idx strategy ->
                let prem_str =
                  String.concat "_"
                    (List.map (Printf.sprintf "prem%d") puids_for_constraint)
                in
                let mut_id =
                  Printf.sprintf "mut_%s_%d_%d" prem_str c_idx s_idx
                in
                let single = { constraint_ with strategies = [ strategy ] } in
                let out_pre, out_block =
                  mutate_json_input ~output_dir:out_dir mut_id [ single ] []
                    pre_path block_path
                in
                if out_pre <> pre_path then (
                  List.iter
                    (fun uid -> Hashtbl.replace local_covered uid ())
                    puids_for_constraint;
                  generated := (mut_id, out_pre, out_block) :: !generated;
                  outcomes :=
                    MutationOk
                      {
                        field = constraint_.field_path;
                        prems = puids_for_constraint;
                        suggestion = constraint_.suggestion_str;
                        from_val = Yojson.Safe.to_string src;
                        to_val = strategy_to_display_string strategy;
                      }
                    :: !outcomes)
                else
                  outcomes :=
                    JsonLoadFailed
                      {
                        field = constraint_.field_path;
                        prems = puids_for_constraint;
                      }
                    :: !outcomes)
              strats)
      all_constraints;

    let covered_prems_list =
      Hashtbl.fold (fun uid () acc -> uid :: acc) local_covered []
    in
    let diag =
      {
        prems_no_muts = List.sort compare !prem_no_muts;
        prems_no_constraints = List.sort compare !prem_no_constraints;
        constraint_outcomes = List.rev !outcomes;
        covered_prems = List.sort_uniq compare covered_prems_list;
      }
    in

    let result =
      if !generated = [] then None
      else Some (test_id, [ (List.hd prem_uids, List.rev !generated) ])
    in
    (result, diag)

(* Write a report.txt file for a processed seed.
   Pure presentation: reads only from diag, performs no branching on diag data. *)
let write_seed_report ~output_dir ~test_id ~prem_uids (diag : process_diag) =
  let test_case_sanitized =
    String.map (fun c -> if c = '/' then '_' else c) test_id
  in
  let out_dir = Filename.concat output_dir test_case_sanitized in
  let report_ch = open_out (Filename.concat out_dir "report.txt") in
  Printf.fprintf report_ch "Test Case: %s\n\nMutations for premises: %s\n"
    test_id
    (String.concat ", " (List.map string_of_int prem_uids));
  if diag.prems_no_muts <> [] then
    Printf.fprintf report_ch "  No suggestions: %s\n"
      (String.concat ", " (List.map string_of_int diag.prems_no_muts));
  if diag.prems_no_constraints <> [] then
    Printf.fprintf report_ch "  No valid constraints: %s\n"
      (String.concat ", " (List.map string_of_int diag.prems_no_constraints));
  Printf.fprintf report_ch "\n";
  List.iter
    (fun outcome ->
      match outcome with
      | FieldNotFound { field; prems; src_label } ->
          Printf.fprintf report_ch
            "  - Field: %s\n    Premises: %s\n    [FAILED: field %s]\n"
            (Dep.string_of_field_path field)
            (String.concat ", " (List.map string_of_int prems))
            src_label
      | MutationOk { field; prems; suggestion; from_val; to_val } ->
          Printf.fprintf report_ch "  - Field: %s\n    Premises: %s\n"
            (Dep.string_of_field_path field)
            (String.concat ", " (List.map string_of_int prems));
          Option.iter
            (Printf.fprintf report_ch "    Suggestion: %s\n")
            suggestion;
          Printf.fprintf report_ch "    From: %s\n    To: %s\n" from_val to_val
      | JsonLoadFailed { field; prems } ->
          Printf.fprintf report_ch
            "  - Field: %s\n\
            \    Premises: %s\n\
            \    [FAILED: could not load JSON]\n"
            (Dep.string_of_field_path field)
            (String.concat ", " (List.map string_of_int prems)))
    diag.constraint_outcomes;
  let mutation_count =
    List.length
      (List.filter
         (function MutationOk _ -> true | _ -> false)
         diag.constraint_outcomes)
  in
  let field_not_found_count =
    List.length
      (List.filter
         (function FieldNotFound _ -> true | _ -> false)
         diag.constraint_outcomes)
  in
  Printf.fprintf report_ch
    "\nResult: %d mutation(s) generated | %d field(s) not found\n"
    mutation_count field_not_found_count;
  close_out report_ch

(* ===== Legacy premise-centric generation ===== *)

(* Convert sym_mutations for a premise into a deduplicated mutation_constraint list. *)
let infer_mutation_constraints (puid : premise_uid)
    (_coverage : Node_cov.result option) (dependency : Pos.result option) :
    mutation_constraint list =
  get_mutation_suggestions_for_premise puid dependency
  |> List.filter_map sym_mutation_to_constraint
  |> deduplicate_constraints

(* Generate mutations for a single premise using one base test case.
   Returns list of (mut_id, out_pre_path, out_block_path). *)
let generate_test_case ~(test_dir : string) ~(output_dir : string)
    (puid : premise_uid) (coverage : Node_cov.result option)
    (dependency : Pos.result option)
    (_path_condition : Instrumentation.Dependency.Negative.result option)
    (base_test_case_id : test_case_id option) =
  let constraints = infer_mutation_constraints puid coverage dependency in
  let test_id_opt =
    match base_test_case_id with
    | Some id -> Some id
    | None -> (
        match get_test_cases_for_premise puid coverage with
        | [] -> None
        | first :: _ -> Some first)
  in
  match test_id_opt with
  | None -> []
  | Some test_id_raw ->
      let test_id = test_id_to_dir test_id_raw in
      let pre_path = Filename.concat test_dir (test_id ^ "_pre.json") in
      let block_path = Filename.concat test_dir (test_id ^ "_block.json") in
      let premise_output_dir =
        Filename.concat output_dir (Printf.sprintf "premise_%d" puid)
      in
      mkdir_p premise_output_dir;

      let report_ch =
        open_out (Filename.concat premise_output_dir "report.txt")
      in
      Printf.fprintf report_ch
        "Mutation Report for Premise UID %d\nBase Test Case: %s\n\n" puid
        test_id;

      let generated = ref [] in
      List.iteri
        (fun c_idx constraint_ ->
          List.iteri
            (fun s_idx strategy ->
              let mut_id =
                Printf.sprintf "%s_mut%d_%d"
                  (String.map (fun c -> if c = '/' then '_' else c) test_id)
                  c_idx s_idx
              in
              let single = { constraint_ with strategies = [ strategy ] } in
              let out_pre, out_block =
                mutate_json_input ~output_dir:premise_output_dir mut_id
                  [ single ] [] pre_path block_path
              in
              if out_pre <> pre_path then (
                generated := (mut_id, out_pre, out_block) :: !generated;
                Printf.fprintf report_ch
                  "Mutation ID: %s\n  Field Path: %s\n  Strategy: %s\n\n" mut_id
                  (Dep.string_of_field_path constraint_.field_path)
                  (strategy_to_display_string strategy)))
            constraint_.strategies)
        constraints;

      close_out report_ch;
      List.rev !generated

(* Run generate_test_case for each premise in puids. *)
let generate_test_cases ~(test_dir : string) ~(output_dir : string)
    (puids : premise_uid list) (coverage : Node_cov.result option)
    (dependency : Pos.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option) =
  List.map
    (fun uid ->
      let results =
        generate_test_case ~test_dir ~output_dir uid coverage dependency
          path_condition None
      in
      (uid, results))
    puids

(* ===== Checkpoint utilities ===== *)

(* Load a coverage checkpoint and extract its coverage, dependency, and path_condition fields. *)
let load_checkpoint (checkpoint_file : string) =
  let checkpoint =
    match Checkpoint.load_from_file ~file:checkpoint_file with
    | Ok cp -> cp
    | Error e ->
        failwith
          (Printf.sprintf "Failed to load checkpoint: %s"
             (Error.string_of_error e))
  in
  let coverage = checkpoint.Checkpoint.coverage.node_il in
  let dependency = checkpoint.Checkpoint.coverage.dependency in
  let path_condition = checkpoint.Checkpoint.coverage.path_condition in
  (checkpoint, coverage, dependency, path_condition)

let checkpoint_summary (checkpoint_file : string) =
  let checkpoint, coverage, dependency, path_condition =
    load_checkpoint checkpoint_file
  in
  let buf = Buffer.create 256 in
  let fmt = Format.formatter_of_buffer buf in
  Format.fprintf fmt "Checkpoint: %s\n" checkpoint_file;
  Format.fprintf fmt "  Completed tests: %d\n"
    (List.length checkpoint.Checkpoint.completed_inputs);
  Format.fprintf fmt "  Coverage data: %s\n"
    (if Option.is_some coverage then "present" else "missing");
  (match coverage with
  | Some cov ->
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in
      let uncovered_count =
        List.fold_left
          (fun count ((region, content_str), _) ->
            if not (List.mem (region, content_str) succeeded_keys) then
              count + 1
            else count)
          0 cov.prem_to_uid
      in
      Format.fprintf fmt "    Total premises: %d\n" cov.total_prems;
      Format.fprintf fmt "    Premises with UIDs: %d\n"
        (List.length cov.prem_to_uid);
      Format.fprintf fmt "    Premises succeeded: %d\n"
        (List.length cov.prems_succeeded);
      Format.fprintf fmt "    Uncovered premises: %d\n" uncovered_count
  | None -> ());
  Format.fprintf fmt "  Positive data: %s\n"
    (if Option.is_some dependency then "present" else "missing");
  (match dependency with
  | Some dep ->
      let total_mutations =
        List.fold_left
          (fun acc (_, test_muts) ->
            List.fold_left
              (fun acc (_, muts) -> acc + List.length muts)
              acc test_muts)
          0 dep.per_test_sym_mutations
      in
      Format.fprintf fmt "    Total mutation suggestions: %d\n" total_mutations
  | None -> ());
  Format.fprintf fmt "  Path condition data: %s\n"
    (if Option.is_some path_condition then "present" else "missing");
  (match path_condition with
  | Some pc ->
      Format.fprintf fmt "    Premises with blacklists: %d\n"
        (List.length pc.blacklists)
  | None -> ());
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let load_testgen_checkpoint (file : string) =
  match Checkpoint.load_from_file ~file with
  | Ok cp -> (
      match cp.Checkpoint.coverage.testgen with
      | Some data -> data
      | None -> Testgen_data.empty)
  | Error _ -> Testgen_data.empty

let save_testgen_checkpoint ~(file : string option) ~(analyzed : string list)
    ~(positive_result : Pos.result) =
  match file with
  | None -> ()
  | Some checkpoint_file ->
      let testgen_data =
        Testgen_data.of_positive_result ~analyzed positive_result
      in
      let coverage =
        {
          Checkpoint.branch = None;
          node_il = None;
          node_sl = None;
          dependency = Some positive_result;
          path_condition = None;
          testgen = Some testgen_data;
        }
      in
      let checkpoint =
        {
          Checkpoint.spec_hash = "";
          completed_inputs = analyzed;
          coverage;
          timestamp = Unix.gettimeofday ();
        }
      in
      Checkpoint.save_to_file ~file:checkpoint_file checkpoint;
      Format.printf "Saved testgen checkpoint: %s (%d tests analyzed)\n%!"
        checkpoint_file (List.length analyzed)

(* ===== Seed filtering ===== *)

let filter_by_seed_type (seed_filter : string option)
    (test_ids : (string * 'a) list) =
  match seed_filter with
  | None -> test_ids
  | Some filter_type ->
      let lower_filter = String.lowercase_ascii filter_type in
      List.filter
        (fun (test_id, _) ->
          let lower_id = String.lowercase_ascii test_id in
          try
            let _ =
              Str.search_forward (Str.regexp_string lower_filter) lower_id 0
            in
            true
          with Not_found -> false)
        test_ids

(* ===== Test-case-centric generation ===== *)

(* Generate mutations for each test case in test_to_prems using an on-demand
   dependency analysis callback. No checkpoint support or global dedup. *)
let generate_tests_by_test_case ~(test_dir : string) ~(output_dir : string)
    (premise_uids : premise_uid list) (coverage : Node_cov.result option)
    (analyze_test_case : test_case_id -> premise_uid list -> Pos.result option)
    =
  let test_to_prems = get_test_to_premises premise_uids coverage in
  List.filter_map
    (fun (test_id, prem_uids) ->
      Format.printf "Processing test case: %s (premises: %s)\n%!" test_id
        (String.concat ", " (List.map string_of_int prem_uids));
      match analyze_test_case test_id prem_uids with
      | None ->
          Format.printf "  Skipped: analysis failed\n%!";
          None
      | Some dependency_result ->
          let result_opt, diag =
            process_test_case ~test_dir ~output_dir test_id prem_uids
              dependency_result
          in
          (match result_opt with
          | Some _ -> write_seed_report ~output_dir ~test_id ~prem_uids diag
          | None -> ());
          result_opt)
    test_to_prems

(* Generate mutations for each test case with checkpoint support.
   Supports resuming from a prior run, seed-type filtering, slot-gap filtering,
   K-cover seed selection, and periodic checkpoint saves. *)
let generate_tests_with_checkpoint ~(test_dir : string) ~(output_dir : string)
    ~(checkpoint_file : string option) ~(resume_file : string option)
    ~(save_interval : int) ~(filter_seeds : string option)
    ~(coverage_level : int) ?(max_slot_gap : int = 32)
    (premise_uids : premise_uid list) (coverage : Node_cov.result option)
    (analyze_test_case : test_case_id -> premise_uid list -> Pos.result option)
    =
  let testgen_data =
    match resume_file with
    | Some file ->
        Format.printf "Resuming from checkpoint: %s\n%!" file;
        load_testgen_checkpoint file
    | None -> Testgen_data.empty
  in

  let all_test_to_prems = get_test_to_premises premise_uids coverage in
  let seed_filtered = filter_by_seed_type filter_seeds all_test_to_prems in

  let slot_filtered =
    let before = List.length seed_filtered in
    let result =
      List.filter
        (fun (tid, _) -> slot_gap_within_limit ~test_dir ~max_slot_gap tid)
        seed_filtered
    in
    let after = List.length result in
    if before <> after then
      Format.printf "Slot-gap filter (max %d): %d → %d tests\n%!" max_slot_gap
        before after;
    result
  in

  let test_to_prems =
    if coverage_level = 0 then slot_filtered
    else (
      Format.printf
        "Selecting seeds with K-cover (k=%d, greedy set cover)...\n%!"
        coverage_level;
      let prem_to_tests = Hashtbl.create 256 in
      let test_to_prems_tbl = Hashtbl.create 256 in
      List.iter
        (fun (tid, prems) ->
          Hashtbl.replace test_to_prems_tbl tid prems;
          List.iter
            (fun p ->
              let existing =
                Hashtbl.find_opt prem_to_tests p |> Option.value ~default:[]
              in
              if not (List.mem tid existing) then
                Hashtbl.replace prem_to_tests p (tid :: existing))
            prems)
        slot_filtered;
      let selected =
        Source_selector.select_k_cover_tests ~k:coverage_level premise_uids
          prem_to_tests test_to_prems_tbl
      in
      Format.printf
        "Selected %d tests (from %d candidates) covering %d premises (k=%d)\n%!"
        (List.length selected)
        (List.length slot_filtered)
        (List.length premise_uids) coverage_level;
      let test_priority (test_id, _) =
        let lower = String.lowercase_ascii test_id in
        let contains s =
          try
            let _ = Str.search_forward (Str.regexp_string s) lower 0 in
            true
          with Not_found -> false
        in
        if contains "sanity" then 0 else if contains "random" then 2 else 1
      in
      List.sort
        (fun t1 t2 ->
          let p1 = test_priority t1 and p2 = test_priority t2 in
          if p1 <> p2 then compare p1 p2 else String.compare (fst t1) (fst t2))
        selected)
  in

  let all_test_ids = List.map fst test_to_prems in
  let remaining_ids = Testgen_data.filter_remaining testgen_data all_test_ids in
  let remaining =
    List.filter (fun (tid, _) -> List.mem tid remaining_ids) test_to_prems
  in

  Format.printf "Total tests: %d, Already analyzed: %d, Remaining: %d\n%!"
    (List.length all_test_ids)
    (List.length all_test_ids - List.length remaining_ids)
    (List.length remaining_ids);

  let analyzed = ref (Testgen_data.analyzed_tests testgen_data) in
  let last_dep_result = ref None in
  let analysis_failed_count = ref 0 in
  let all_diags = ref [] in
  let already_completed =
    List.length all_test_ids - List.length remaining_ids
  in
  let total = List.length all_test_ids in

  let results =
    List.mapi
      (fun idx (test_id, prem_uids) ->
        Format.printf "[%d/%d] Processing test case: %s\n%!"
          (already_completed + idx + 1)
          total test_id;

        let result_opt = analyze_test_case test_id prem_uids in
        (match result_opt with
        | Some r -> last_dep_result := Some r
        | None -> ());
        analyzed := test_id :: !analyzed;

        (if (idx + 1) mod save_interval = 0 then
           match result_opt with
           | Some r ->
               save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
                 ~positive_result:r;
               Instrumentation.Dependency.Positive.clear_memory ()
           | None -> ());

        match result_opt with
        | None ->
            analysis_failed_count := !analysis_failed_count + 1;
            Format.printf "  Skipped: analysis failed\n%!";
            None
        | Some dep_result ->
            let tc_result, diag =
              process_test_case ~test_dir ~output_dir test_id prem_uids
                dep_result
            in
            all_diags := diag :: !all_diags;
            (match tc_result with
            | Some _ -> write_seed_report ~output_dir ~test_id ~prem_uids diag
            | None -> ());
            tc_result)
      remaining
    |> List.filter_map Fun.id
  in

  (match checkpoint_file with
  | Some _ when results <> [] -> (
      Format.printf "Saving final checkpoint...\n%!";
      match !last_dep_result with
      | Some r ->
          save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
            ~positive_result:r
      | None -> ())
  | _ -> ());

  (* ===== Comprehensive summary ===== *)
  let seeds_with_mutations =
    List.length (List.filter (fun d -> d.covered_prems <> []) !all_diags)
  in
  let all_covered_prems =
    List.sort_uniq compare
      (List.concat_map (fun d -> d.covered_prems) !all_diags)
  in
  let total_mutations =
    List.fold_left
      (fun acc d ->
        acc
        + List.length
            (List.filter
               (function MutationOk _ -> true | _ -> false)
               d.constraint_outcomes))
      0 !all_diags
  in
  (* Seed type breakdown *)
  let n_sanity, n_finality, n_random, n_other =
    List.fold_left
      (fun (s, f, r, o) (tid, _) ->
        let lower = String.lowercase_ascii tid in
        let contains str =
          try
            let _ = Str.search_forward (Str.regexp_string str) lower 0 in
            true
          with Not_found -> false
        in
        if contains "sanity" then (s + 1, f, r, o)
        else if contains "finality" then (s, f + 1, r, o)
        else if contains "random" then (s, f, r + 1, o)
        else (s, f, r, o + 1))
      (0, 0, 0, 0) test_to_prems
  in
  (* Premise coverage *)
  let covered_by_seeds =
    List.fold_left
      (fun acc (_, prems) ->
        List.fold_left (fun a p -> if List.mem p a then a else p :: a) acc prems)
      [] test_to_prems
  in
  let no_seed_coverage =
    List.filter (fun uid -> not (List.mem uid covered_by_seeds)) premise_uids
  in
  let no_mutations =
    List.filter
      (fun uid -> not (List.mem uid all_covered_prems))
      covered_by_seeds
  in
  let seeds_analyzed = List.length remaining in
  let seeds_no_mutations =
    seeds_analyzed - !analysis_failed_count - seeds_with_mutations
  in
  let summary_lines =
    let buf = Buffer.create 512 in
    let pr fmt = Printf.bprintf buf (fmt ^^ "\n") in
    pr "=== Test Generation Summary ===";
    pr "";
    pr "Seeds:";
    pr "  Selected: %d  (Sanity: %d | Finality: %d | Random: %d | Other: %d)"
      (List.length test_to_prems)
      n_sanity n_finality n_random n_other;
    if already_completed > 0 then
      pr "  Already analyzed (checkpoint): %d" already_completed;
    pr "  Analyzed this run: %d  (failed: %d)" seeds_analyzed
      !analysis_failed_count;
    pr "  Generated mutations: %d seeds  |  No new mutations: %d seeds"
      seeds_with_mutations seeds_no_mutations;
    pr "";
    pr "Mutations: %d total" total_mutations;
    if seeds_with_mutations > 0 then
      pr "  Avg per seed: %.1f"
        (float_of_int total_mutations /. float_of_int seeds_with_mutations);
    pr "";
    pr "Premise coverage (%d targeted):" (List.length premise_uids);
    pr "  Covered by seeds:  %d" (List.length covered_by_seeds);
    pr "  Got >=1 mutation:  %d" (List.length all_covered_prems);
    if no_seed_coverage <> [] then
      pr "  No seed coverage:  %d  (UIDs: %s)"
        (List.length no_seed_coverage)
        (String.concat ", "
           (List.map string_of_int (List.sort compare no_seed_coverage)));
    if no_mutations <> [] then
      pr "  No mutations:      %d  (UIDs: %s)" (List.length no_mutations)
        (String.concat ", "
           (List.map string_of_int (List.sort compare no_mutations)));
    Buffer.contents buf
  in
  Format.printf "\n%s%!" summary_lines;
  (let summary_path = Filename.concat output_dir "summary.txt" in
   let ch = open_out summary_path in
   output_string ch summary_lines;
   close_out ch;
   Format.printf "Summary written to: %s\n%!" summary_path);

  results
