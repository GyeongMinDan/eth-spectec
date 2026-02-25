(* Testgen backend - Generates test cases by mutating input data to target uncovered premises.

   Pipeline overview:
   1. Run test suite with node-coverage-il to get premise-to-testid mapping
   2. Human inspects uncovered premises and selects premise UIDs to target
   3. For selected premises, query dependency and path_condition results from checkpoint
   4. Filter out negative dependencies (from path_condition) and use positive dependencies
      (from dependency) to generate mutation targets and strategies
   5. Mutate JSON input files based on mutation constraints

   Usage:
     - Load checkpoint: load_checkpoint "checkpoint.ckpt"
     - List uncovered: get_uncovered_premises coverage
     - Get test cases for premise: get_test_cases_for_premise uid coverage
     - Get mutation suggestions: get_mutation_suggestions_for_premise uid coverage dependency
     - Get blacklisted fields: get_blacklisted_fields uid coverage path_condition
     - Generate test case: generate_test_case uid coverage dependency path_condition None
*)

open Common.Source
module Il = Lang.Il
module Checkpoint = Checkpoint
module Instrumentation = Instrumentation
module Dep = Instrumentation.Dependency.Dep_common

(* Types *)
type premise_uid = int
type test_case_id = string
type field_path = Instrumentation.Dependency.Dep_common.field_path

(* === Slot-gap limiting ===
   The spec's main loop replays state changes from state.slot up to block.slot - 1.
   Large gaps (common in "random" seeds) cause extremely slow execution.
   A max gap of 32 (1 epoch) suffices to trigger Process_epoch. *)

(* Parse a JSON value as an integer (handles `Int, `Intlit, `String) *)
let json_to_int (json : Yojson.Safe.t) : int option =
  match json with
  | `Int n -> Some n
  | `Intlit s | `String s -> (
      try Some (int_of_string s) with Failure _ -> None)
  | _ -> None

(* Navigate a JSON value by a field_step path and parse as int *)
let json_get_int (json : Yojson.Safe.t) (path : Dep.field_step list) :
    int option =
  Option.bind (Json_mutator.get_field json path) json_to_int

(* Paths for slot fields *)
let state_slot_path = [ Dep.FieldAccess "slot" ]
let block_msg_slot_path = [ Dep.FieldAccess "message"; Dep.FieldAccess "slot" ]
let block_slot_path = [ Dep.FieldAccess "slot" ]

(* Extract slot from JSON, trying each path in order *)
let get_slot (json : Yojson.Safe.t) (paths : Dep.field_step list list) :
    int option =
  List.find_map (json_get_int json) paths

let get_state_slot json = get_slot json [ state_slot_path ]
let get_block_slot json = get_slot json [ block_msg_slot_path; block_slot_path ]

(* Compute block_slot - state_slot *)
let get_slot_gap (pre_json : Yojson.Safe.t) (block_json : Yojson.Safe.t) :
    int option =
  match (get_state_slot pre_json, get_block_slot block_json) with
  | Some s, Some b -> Some (b - s)
  | _ -> None

(* Strip /pre.json suffix from a test_id to get the test case directory *)
let test_id_to_dir (test_id : string) : string =
  if String.ends_with ~suffix:"/pre.json" test_id then
    String.sub test_id 0 (String.length test_id - 9)
  else test_id

(* Check if a seed test's slot gap is within the limit.
   Returns true (pass) when files can't be loaded or gap can't be determined. *)
let slot_gap_within_limit ~test_dir ~max_slot_gap (test_id : string) : bool =
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

(* Cap block slot so that block_slot - state_slot <= max_slot_gap.
   Sets the slot via whichever path the block slot was found at. *)
let cap_slot_gap ~max_slot_gap (pre_json : Yojson.Safe.t)
    (block_json : Yojson.Safe.t) : Yojson.Safe.t =
  match (get_slot_gap pre_json block_json, get_state_slot pre_json) with
  | Some gap, Some state_slot when gap > max_slot_gap ->
      let capped = `Intlit (string_of_int (state_slot + max_slot_gap)) in
      (* Use whichever path the block slot actually lives at *)
      let slot_path =
        if Option.is_some (json_get_int block_json block_msg_slot_path) then
          block_msg_slot_path
        else block_slot_path
      in
      Json_mutator.set_field block_json slot_path capped
  | _ -> block_json

(* Mutation constraint - what field to mutate and to what values *)
type mutation_constraint = {
  field_path : field_path;
  strategies : Json_mutator.mutation_strategy list;
      (* Strategies to try for this path *)
  suggestion_str : string option;
      (* Original mutation suggestion string for reporting *)
}

(* Premise information *)
type premise_info = {
  uid : premise_uid;
  key : region * string;
  relation : string;
  rule : string;
  content : string;
}

(* Load checkpoint and extract coverage, dependency, and path_condition data.
   
   The checkpoint should contain:
   - Coverage data (node_il): premise-to-testid mapping and uncovered premises
   - Positive results: mutation suggestions organized by relation/rule
   - Path condition results: negative dependencies (fields to avoid mutating)
   
   Note: If dependency/path_condition results are not in the checkpoint, you may
   need to re-run the test suite with those instrumentations enabled on the
   specific test cases that cover your selected premises. *)
let load_checkpoint (checkpoint_file : string) :
    Checkpoint.t
    * Instrumentation.Node_coverage_il.result option
    * Instrumentation.Dependency.Positive.result option
    * Instrumentation.Dependency.Negative.result option =
  let checkpoint =
    match Checkpoint.load_from_file ~file:checkpoint_file with
    | Ok checkpoint -> checkpoint
    | Error e ->
        failwith
          (Printf.sprintf "Failed to load checkpoint: %s"
             (Error.string_of_error e))
  in
  let coverage = checkpoint.Checkpoint.coverage.node_il in
  let dependency = checkpoint.Checkpoint.coverage.dependency in
  let path_condition = checkpoint.Checkpoint.coverage.path_condition in
  (checkpoint, coverage, dependency, path_condition)

(* Get summary of checkpoint contents for debugging *)
let checkpoint_summary (checkpoint_file : string) : string =
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
      Format.fprintf fmt "    Total premises: %d\n" cov.total_prems;
      Format.fprintf fmt "    Premises with UIDs: %d\n"
        (List.length cov.prem_to_uid);
      Format.fprintf fmt "    Premises succeeded: %d\n"
        (List.length cov.prems_succeeded);
      (* Compute uncovered count inline - premises with UIDs that never succeeded *)
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in
      let uncovered_count =
        List.fold_left
          (fun count ((region, content_str), _) ->
            let premise_key = (region, content_str) in
            if not (List.mem premise_key succeeded_keys) then count + 1
            else count)
          0 cov.prem_to_uid
      in
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

(* Get uncovered premises with UIDs from coverage data *)
let get_uncovered_premises
    (coverage : Instrumentation.Node_coverage_il.result option) :
    premise_info list =
  match coverage with
  | None -> []
  | Some cov ->
      (* Build a map from premise key to UID *)
      (* premise_uid_map is ((region * string) * int) list *)
      let key_to_uid = cov.prem_to_uid in

      (* Build a set of succeeded premise keys (as a list for membership check) *)
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in

      (* Find uncovered premises - those with UIDs but not in succeeded *)
      let uncovered = ref [] in
      List.iter
        (fun ((region, content_str), uid) ->
          let premise_key = (region, content_str) in
          if not (List.mem premise_key succeeded_keys) then
            (* Extract relation and rule from premise key if possible *)
            (* For now, we'll use placeholder values - this can be enhanced *)
            uncovered :=
              {
                uid;
                key = premise_key;
                relation = "unknown";
                rule = "unknown";
                content = content_str;
              }
              :: !uncovered)
        key_to_uid;
      !uncovered

(* Get mutation suggestions for a premise from dependency analysis.
   Since dependency results are now organized per-test, we collect all mutations
   for this premise across all test cases. *)
(* Get mutations for a single premise (for backward compatibility) *)
let get_mutation_suggestions_for_premise (premise_uid : premise_uid)
    (_coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option) :
    Instrumentation.Dependency.Positive.sym_mutation list =
  match dependency with
  | None -> []
  | Some dep -> (
      (* Find mutations for this premise UID *)
      match List.assoc_opt premise_uid dep.per_test_sym_mutations with
      | None -> []
      | Some test_muts ->
          (* Collect all mutations across all test cases *)
          let all_muts =
            List.fold_left (fun acc (_, muts) -> acc @ muts) [] test_muts
          in
          (* Filter invalid mutations *)
          let module Dep = Instrumentation.Dependency.Dep_common in
          let is_valid_mutation
              (mut : Instrumentation.Dependency.Positive.sym_mutation) : bool =
            match mut.target_path with
            | None -> false
            | Some path ->
                (* Filter out state as whole *)
                if path.source = Dep.State && path.steps = [] then false
                  (* Filter out Unknown source *)
                else if path.source = Dep.Unknown then false
                else true
          in
          let filtered_muts = List.filter is_valid_mutation all_muts in
          filtered_muts)

(* Get mutations for multiple premises, deduplicated across all of them *)
let get_mutation_suggestions_for_premises (premise_uids : premise_uid list)
    (_coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option)
    (test_id : test_case_id) :
    Instrumentation.Dependency.Positive.sym_mutation list =
  match dependency with
  | None -> []
  | Some dep ->
      (* Collect mutations from all premises for this test *)
      let all_muts =
        List.fold_left
          (fun acc premise_uid ->
            match List.assoc_opt premise_uid dep.per_test_sym_mutations with
            | None -> acc
            | Some test_muts -> (
                (* Get mutations for this specific test_id *)
                match List.assoc_opt test_id test_muts with
                | None -> acc
                | Some muts -> acc @ muts))
          [] premise_uids
      in
      (* Filter invalid mutations *)
      let module Dep = Instrumentation.Dependency.Dep_common in
      let module Pos = Instrumentation.Dependency.Positive in
      let is_valid_mutation
          (mut : Instrumentation.Dependency.Positive.sym_mutation) : bool =
        match mut.target_path with
        | None -> false
        | Some path ->
            (* Filter out state as whole *)
            if path.source = Dep.State && path.steps = [] then false
              (* Filter out Unknown source *)
            else if path.source = Dep.Unknown then false
            else true
      in
      let filtered_muts = List.filter is_valid_mutation all_muts in
      (* Deduplicate mutations across all premises using the same comparison logic as positive.ml *)
      let compare_sym_mutation (m1 : Pos.sym_mutation) (m2 : Pos.sym_mutation) =
        match (m1.target_path, m2.target_path) with
        | Some p1, Some p2 ->
            let path_cmp = compare p1 p2 in
            if path_cmp = 0 then
              (* Same path, compare suggestions *)
              match (m1.suggestion, m2.suggestion) with
              | Pos.ToConst (op1, v1), Pos.ToConst (op2, v2) ->
                  let op_cmp = compare op1 op2 in
                  if op_cmp = 0 then
                    (* Compare values by their string representation *)
                    compare
                      (Il.Print.string_of_value v1)
                      (Il.Print.string_of_value v2)
                  else op_cmp
              | Pos.ToLength (op1, v1), Pos.ToLength (op2, v2) ->
                  let op_cmp = compare op1 op2 in
                  if op_cmp = 0 then
                    compare
                      (Il.Print.string_of_value v1)
                      (Il.Print.string_of_value v2)
                  else op_cmp
              | Pos.Unknown _, Pos.Unknown _ ->
                  0 (* All Unknown are considered equal *)
              | Pos.ToConst _, _ -> -1
              | Pos.ToLength _, Pos.ToConst _ -> 1
              | Pos.ToLength _, _ -> -1
              | Pos.Unknown _, _ -> 1
            else path_cmp
        | None, None -> 0
        | Some _, None -> -1
        | None, Some _ -> 1
      in
      (* Debug: print all mutations before deduplication *)
      Format.printf
        "[DEBUG] Before deduplication: %d mutations for test %s from premises %s\n\
         %!"
        (List.length filtered_muts)
        test_id
        (String.concat ", " (List.map string_of_int premise_uids));
      List.iteri
        (fun i (mut : Pos.sym_mutation) ->
          let path_str =
            match mut.target_path with
            | None -> "None"
            | Some path -> Dep.string_of_field_path path
          in
          let suggestion_str = Pos.string_of_sym_mutation mut in
          Format.printf "[DEBUG]   Mutation %d: %s → %s\n%!" i path_str
            suggestion_str)
        filtered_muts;
      let sorted_muts = List.sort compare_sym_mutation filtered_muts in
      let deduplicated_muts = List.sort_uniq compare_sym_mutation sorted_muts in
      (* Debug: log if deduplication removed any mutations *)
      Format.printf
        "[DEBUG] After deduplication: %d mutations (removed %d duplicates)\n%!"
        (List.length deduplicated_muts)
        (List.length filtered_muts - List.length deduplicated_muts);
      deduplicated_muts

(* Convert Il.Value.t to JSON value for mutation *)
let value_to_json (v : Il.Value.t) : (Yojson.Safe.t, string) result =
  match Interface.JSON.Print.value_to_json v with
  | Ok json -> Ok json
  | Error err -> Error (Interface.JSON.Print.string_of_error err)

(* Extract numeric value from Il.Value.t as Bigint, returning None if not numeric *)
let extract_numeric_value (v : Il.Value.t) : Bigint.t option =
  match v.it with
  | Il.NumV (`Nat n) -> Some n
  | Il.NumV (`Int n) -> Some n
  | _ -> None

(* Convert Bigint to JSON intlit string *)
let bigint_to_intlit (n : Bigint.t) : string = Bigint.to_string n

(* Constants for MAX and MIN values *)
let max_uint64 = Bigint.of_string "18446744073709551615"
let min_value = Bigint.of_int 0

(* Generate mutation strategies for ToConst based on operator and value.
   For booleans, always flip the source value regardless of operator.
   source_value_opt is optional and used for boolean flipping. *)
let generate_toconst_strategies (op : Il.cmpop) (value : Il.Value.t)
    (source_value_opt : Yojson.Safe.t option) :
    Json_mutator.mutation_strategy list =
  (* Check if value is boolean *)
  match value.it with
  | Il.BoolV b -> (
      (* For booleans, always flip the source value if available, otherwise flip the target *)
      match source_value_opt with
      | Some (`Bool source_bool) ->
          (* Flip the source boolean value *)
          [ Json_mutator.SetValue (`Bool (not source_bool)) ]
      | _ ->
          (* No source value, flip the target value *)
          [ Json_mutator.SetValue (`Bool (not b)) ])
  | _ -> (
      (* Non-boolean: use numeric logic *)
      match extract_numeric_value value with
      | Some n -> (
          let n_str = bigint_to_intlit n in
          let max_str = bigint_to_intlit max_uint64 in
          let min_str = bigint_to_intlit min_value in
          match op with
          | `GeOp ->
              (* >= n: generate n and MAX *)
              [
                Json_mutator.SetValue (`Intlit n_str);
                Json_mutator.SetValue (`Intlit max_str);
              ]
          | `LeOp ->
              (* <= n: generate n and 0 (MIN) *)
              [
                Json_mutator.SetValue (`Intlit n_str);
                Json_mutator.SetValue (`Intlit min_str);
              ]
          | `GtOp -> (
              (* > n: generate n+1 and MAX *)
              match Bigint.to_int n with
              | Some n_int ->
                  let n_plus_one = Bigint.of_int (n_int + 1) in
                  let n_plus_one_str = bigint_to_intlit n_plus_one in
                  [
                    Json_mutator.SetValue (`Intlit n_plus_one_str);
                    Json_mutator.SetValue (`Intlit max_str);
                  ]
              | None ->
                  (* If n is too large for int, just use MAX *)
                  [ Json_mutator.SetValue (`Intlit max_str) ])
          | `LtOp -> (
              (* < n: generate n-1 and MAX *)
              match Bigint.to_int n with
              | Some n_int when n_int > 0 ->
                  let n_minus_one = Bigint.of_int (n_int - 1) in
                  let n_minus_one_str = bigint_to_intlit n_minus_one in
                  [
                    Json_mutator.SetValue (`Intlit n_minus_one_str);
                    Json_mutator.SetValue (`Intlit max_str);
                  ]
              | _ ->
                  (* If n <= 0 or too large, just use MAX *)
                  [ Json_mutator.SetValue (`Intlit max_str) ])
          | `EqOp ->
              (* = n: generate n *)
              [ Json_mutator.SetValue (`Intlit n_str) ]
          | `NeOp -> (
              (* != n: generate n-1 and n+1 *)
              match Bigint.to_int n with
              | Some n_int ->
                  let n_minus_one =
                    if n_int > 0 then Bigint.of_int (n_int - 1) else min_value
                  in
                  let n_plus_one = Bigint.of_int (n_int + 1) in
                  let n_minus_one_str = bigint_to_intlit n_minus_one in
                  let n_plus_one_str = bigint_to_intlit n_plus_one in
                  [
                    Json_mutator.SetValue (`Intlit n_minus_one_str);
                    Json_mutator.SetValue (`Intlit n_plus_one_str);
                  ]
              | None ->
                  (* If n is too large for int, just use n *)
                  [ Json_mutator.SetValue (`Intlit n_str) ]))
      | None -> (
          (* Non-numeric value: fallback to original behavior *)
          match value_to_json value with
          | Ok json -> [ Json_mutator.SetValue json ]
          | Error _ -> []))

(* Generate mutation strategies for ToLength based on operator and value.
   For ToLength, "MAX" means 2n list (use SetLength) and "MIN" means empty list (use SetLength 0).
   Otherwise, the algorithm is the same as ToConst but using SetLength for list operations. *)
let generate_tolength_strategies (op : Il.cmpop) (value : Il.Value.t) :
    Json_mutator.mutation_strategy list =
  match extract_numeric_value value with
  | Some n -> (
      match Bigint.to_int n with
      | Some n_int -> (
          match op with
          | `GeOp ->
              (* >= n: generate n and MAX (2n list) *)
              [
                Json_mutator.SetLength n_int; Json_mutator.SetLength (2 * n_int);
              ]
          | `LeOp ->
              (* <= n: generate n and MIN (empty list) *)
              [ Json_mutator.SetLength n_int; Json_mutator.SetLength 0 ]
          | `GtOp ->
              (* > n: generate n+1 and MAX (2n list) *)
              [
                Json_mutator.SetLength (n_int + 1);
                Json_mutator.SetLength (2 * n_int);
              ]
          | `LtOp ->
              (* < n: generate n-1 and MAX (2n list) *)
              if n_int > 0 then
                [
                  Json_mutator.SetLength (n_int - 1);
                  Json_mutator.SetLength (2 * n_int);
                ]
              else [ Json_mutator.SetLength (2 * n_int) ]
          | `EqOp ->
              (* = n: generate n *)
              [ Json_mutator.SetLength n_int ]
          | `NeOp ->
              (* != n: generate n-1 and n+1 *)
              if n_int > 0 then
                [
                  Json_mutator.SetLength (n_int - 1);
                  Json_mutator.SetLength (n_int + 1);
                ]
              else [ Json_mutator.SetLength (n_int + 1) ])
      | None ->
          (* n is too large for int, fallback to boundary values *)
          [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ])
  | None ->
      (* Fallback for non-numeric values *)
      [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ]

(* Infer mutation constraints from dependency analysis. *)
let infer_mutation_constraints (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option) :
    mutation_constraint list =
  let suggestions =
    get_mutation_suggestions_for_premise premise_uid coverage dependency
  in
  Format.printf
    "[DEBUG] infer_mutation_constraints: %d suggestions for premise %d\n%!"
    (List.length suggestions) premise_uid;
  (* Convert sym_mutation to mutation constraints using new types *)
  let module Pos = Instrumentation.Dependency.Positive in
  let module Dep = Instrumentation.Dependency.Dep_common in
  (* Helper to convert field_path to string list *)
  (* First, convert each sym_mutation to a constraint with its strategies *)
  let constraint_list =
    List.filter_map
      (fun (sym_mut : Pos.sym_mutation) ->
        (* Convert target_path to string list *)
        match sym_mut.target_path with
        | None -> None
        | Some target_path ->
            (* Check if path is a list by examining the last step *)
            let is_list_path =
              match target_path.steps with
              | [] -> false
              | steps -> (
                  let last_step = List.hd (List.rev steps) in
                  match last_step with
                  | Dep.FieldAccess field_name ->
                      (* Check if field name suggests it's a list/array *)
                      let name_lower = String.lowercase_ascii field_name in
                      List.mem name_lower
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
                      || String.ends_with ~suffix:"s" name_lower
                         && String.length name_lower > 1
                  | Dep.IndexAccess _ ->
                      true (* Index access suggests it's a list *))
            in

            let strategies =
              match sym_mut.suggestion with
              | Pos.ToConst (op, value) ->
                  (* For lists, ignore ToConst and use list strategies *)
                  if is_list_path then
                    (* Use double list and empty list for list paths *)
                    (* We'll need to get the actual length at mutation time, so use placeholder *)
                    (* Actually, we can't know the length here, so we'll handle this in the mutation generation *)
                    []
                  else
                    (* For non-lists, generate normally (source value will be checked later) *)
                    generate_toconst_strategies op value None
              | Pos.ToLength (op, value) ->
                  generate_tolength_strategies op value
              | Pos.Unknown hint -> (
                  if
                    (* For list paths, always use list strategies and ignore hints *)
                    is_list_path
                  then
                    (* Use double list and empty list - will be adjusted based on source length *)
                    (* We'll handle this when we have the source value *)
                    []
                  else
                    (* For non-lists, use hint-based strategies *)
                    (* Generate strategies based on value hint or type hint *)
                    let strategies_from_value value =
                      match value.it with
                      | Il.NumV (`Nat _) | Il.NumV (`Int _) ->
                          (* For numeric values, always generate MAX and MIN *)
                          [
                            Json_mutator.SetValue (`Intlit "0");
                            Json_mutator.SetValue
                              (`Intlit "18446744073709551615");
                          ]
                      | Il.BytesV { len; _ } ->
                          (* For bytes, generate all zeros and all ones of same size *)
                          let zeros_hex = String.make (len * 2) '0' in
                          let ones_hex = String.make (len * 2) 'f' in
                          [
                            Json_mutator.SetValue (`String ("0x" ^ zeros_hex));
                            Json_mutator.SetValue (`String ("0x" ^ ones_hex));
                          ]
                      | Il.BoolV _ ->
                          (* For booleans, try both values *)
                          [
                            Json_mutator.SetValue (`Bool true);
                            Json_mutator.SetValue (`Bool false);
                          ]
                      | Il.ListV items ->
                          (* For lists: double the list and empty list *)
                          let current_len = List.length items in
                          if current_len = 0 then
                            (* Can't mutate empty list *)
                            []
                          else
                            [
                              Json_mutator.SetLength (2 * current_len);
                              Json_mutator.SetLength 0;
                            ]
                      | Il.StructV _ ->
                          (* For structs, can't easily mutate - use fallback *)
                          []
                      | _ -> []
                    in
                    let strategies_from_type typ =
                      match typ with
                      | Il.NumT `NatT | Il.NumT `IntT ->
                          (* Numeric types: 0 and max *)
                          [
                            Json_mutator.SetValue (`Intlit "0");
                            Json_mutator.SetValue
                              (`Intlit "18446744073709551615");
                          ]
                      | Il.BoolT ->
                          [
                            Json_mutator.SetValue (`Bool true);
                            Json_mutator.SetValue (`Bool false);
                          ]
                      | Il.TextT ->
                          [
                            Json_mutator.SetValue (`String "");
                            Json_mutator.SetValue (`String "mutated_string");
                          ]
                      | Il.VarT (id, _) ->
                          (* Check type name for hints *)
                          let name = String.lowercase_ascii id.it in
                          if
                            String.length name >= 5
                            && String.sub name 0 5 = "bytes"
                          then
                            (* bytesN type - try to extract N *)
                            let len_str =
                              String.sub name 5 (String.length name - 5)
                            in
                            let len =
                              try int_of_string len_str with _ -> 32
                            in
                            let zeros_hex = String.make (len * 2) '0' in
                            let ones_hex = String.make (len * 2) 'f' in
                            [
                              Json_mutator.SetValue (`String ("0x" ^ zeros_hex));
                              Json_mutator.SetValue (`String ("0x" ^ ones_hex));
                            ]
                          else if name = "boolean" || name = "bool" then
                            [
                              Json_mutator.SetValue (`Bool true);
                              Json_mutator.SetValue (`Bool false);
                            ]
                          else if
                            List.mem name
                              [
                                "uint64";
                                "slot";
                                "epoch";
                                "validatorindex";
                                "nat";
                                "int";
                              ]
                          then
                            [
                              Json_mutator.SetValue (`Intlit "0");
                              Json_mutator.SetValue
                                (`Intlit "18446744073709551615");
                            ]
                          else if
                            List.mem name
                              [ "root"; "hash32"; "blspubkey"; "blssignature" ]
                          then
                            (* 32-byte or 48-byte hashes *)
                            let len =
                              if name = "blspubkey" || name = "blssignature"
                              then 48
                              else 32
                            in
                            let zeros_hex = String.make (len * 2) '0' in
                            let ones_hex = String.make (len * 2) 'f' in
                            [
                              Json_mutator.SetValue (`String ("0x" ^ zeros_hex));
                              Json_mutator.SetValue (`String ("0x" ^ ones_hex));
                            ]
                          else []
                      | Il.IterT (_, Il.List) ->
                          (* For list types: double the list and empty list *)
                          (* We don't know the current length, so we'll use a placeholder *)
                          (* Actually, we can't use SetLength without knowing current length *)
                          (* So we'll skip list type hints for now *)
                          []
                      | _ -> []
                    in
                    match hint with
                    | Pos.ValueHint v -> strategies_from_value v
                    | Pos.TypeHint t -> strategies_from_type t
                    | Pos.NoHint -> [])
            in
            (* Deduplicate strategies *)
            let deduplicated_strategies =
              List.sort_uniq
                (fun s1 s2 ->
                  match (s1, s2) with
                  | Json_mutator.SetValue v1, Json_mutator.SetValue v2 ->
                      compare (Yojson.Safe.to_string v1)
                        (Yojson.Safe.to_string v2)
                  | Json_mutator.SetLength l1, Json_mutator.SetLength l2 ->
                      compare l1 l2
                  | Json_mutator.Increment i1, Json_mutator.Increment i2 ->
                      compare i1 i2
                  | Json_mutator.Decrement i1, Json_mutator.Decrement i2 ->
                      compare i1 i2
                  | Json_mutator.SetBoundary, Json_mutator.SetBoundary -> 0
                  | Json_mutator.AppendItem, Json_mutator.AppendItem -> 0
                  | Json_mutator.RemoveItem, Json_mutator.RemoveItem -> 0
                  | _ -> compare s1 s2)
                strategies
            in
            (* Only include if we have strategies *)
            if deduplicated_strategies = [] then None
            else
              (* Use the original string_of_sym_mutation which includes the value *)
              let suggestion_str = Some (Pos.string_of_sym_mutation sym_mut) in
              Some
                {
                  field_path = target_path;
                  strategies = deduplicated_strategies;
                  suggestion_str;
                })
      suggestions
  in
  (* Each mutation is its own suggestion - no grouping *)
  let constraints = constraint_list in
  Format.printf
    "[DEBUG] infer_mutation_constraints: returning %d constraints\n%!"
    (List.length constraints);
  constraints

(* Check if a test case ID corresponds to a state transition test.
   State transition tests are identified by having 'state_transition' in their path. *)
let is_state_transition_test (test_case_id : test_case_id) : bool =
  try
    let _ =
      Str.search_forward (Str.regexp_string "state_transition") test_case_id 0
    in
    true
  with Not_found -> false

(* Reverse prem_to_test mapping: (test_id -> premise_uid list)
   Only includes premises from the supplied premise_uids list *)
let get_test_to_premises (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option) :
    (test_case_id * premise_uid list) list =
  match coverage with
  | None -> []
  | Some cov ->
      (* Build premise_key -> uid map *)
      let key_to_uid = Hashtbl.create 256 in
      List.iter
        (fun (key, uid) -> Hashtbl.add key_to_uid key uid)
        cov.prem_to_uid;

      (* Build test_id -> premise_uid list map *)
      let test_to_prems = Hashtbl.create 256 in
      List.iter
        (fun (prem_key, test_ids) ->
          match Hashtbl.find_opt key_to_uid prem_key with
          | Some uid when List.mem uid premise_uids ->
              (* This premise is in our target list *)
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

      (* Convert to list and sort *)
      Hashtbl.to_seq test_to_prems
      |> List.of_seq
      |> List.map (fun (test_id, uids) -> (test_id, List.sort compare uids))
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* Find test cases that covered a premise, filtered to only state transition tests *)
let get_test_cases_for_premise (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option) :
    test_case_id list =
  match coverage with
  | None -> []
  | Some cov -> (
      (* Find the premise key for this UID *)
      let uid_to_key =
        List.fold_left
          (fun acc (uid, key) -> (uid, key) :: acc)
          [] cov.uid_to_prem
        |> List.to_seq |> Hashtbl.of_seq
      in
      match Hashtbl.find_opt uid_to_key premise_uid with
      | None -> []
      | Some key -> (
          (* Find test cases for this premise key *)
          let key_to_test_cases =
            List.fold_left
              (fun acc (k, test_cases) -> (k, test_cases) :: acc)
              [] cov.prem_to_test
            |> List.to_seq |> Hashtbl.of_seq
          in
          match Hashtbl.find_opt key_to_test_cases key with
          | None -> []
          | Some test_cases ->
              (* Filter removed to allow all test cases *)
              test_cases))

(* Get premise information including test cases that covered it *)
let get_premise_info (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option) :
    (premise_info * test_case_id list) option =
  match coverage with
  | None -> None
  | Some cov -> (
      (* Find premise key for this UID *)
      let premise_key =
        List.find_map
          (fun (uid, key) -> if uid = premise_uid then Some key else None)
          cov.uid_to_prem
      in
      match premise_key with
      | None -> None
      | Some key ->
          let _region, content_str = key in
          let test_cases = get_test_cases_for_premise premise_uid coverage in
          Some
            ( {
                uid = premise_uid;
                key;
                relation = "unknown";
                (* TODO: extract from spec *)
                rule = "unknown";
                (* TODO: extract from spec *)
                content = content_str;
              },
              test_cases ))

(* Check if a field path is blacklisted *)
let is_blacklisted (path : field_path) (blacklist : field_path list) : bool =
  (* Check if path starts with any blacklisted prefix - logic simplified for structured paths if needed *)
  (* For now, exact match or simple containment *)
  List.mem path blacklist

(* Mutate JSON input files based on mutation constraints.
   Returns paths to the mutated files (or originals if mutation failed). *)
let mutate_json_input ~(output_dir : string) ?(max_slot_gap : int option)
    (test_case_id : test_case_id) (constraints : mutation_constraint list)
    (blacklisted : field_path list) (pre_json_path : string)
    (block_json_path : string) : string * string =
  (* Create mutation-specific directory within output_dir *)
  let flat_test_id =
    String.map (fun c -> if c = '/' then '_' else c) test_case_id
  in
  let mutation_dir = Filename.concat output_dir flat_test_id in
  (* Ensure mutation directory exists *)
  (try Unix.mkdir mutation_dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

  (* Load JSON files *)
  let pre_json =
    try Some (Json_mutator.load_json pre_json_path) with _ -> None
  in
  let block_json =
    try Some (Json_mutator.load_json block_json_path) with _ -> None
  in

  match (pre_json, block_json) with
  | None, _ | _, None ->
      (* Could not load files, return original paths *)
      (pre_json_path, block_json_path)
  | Some pre, Some block ->
      (* Apply mutations, skipping blacklisted fields and respecting source file *)
      let apply_constraints json target_source =
        List.fold_left
          (fun json_acc constraint_ ->
            if is_blacklisted constraint_.field_path blacklisted then json_acc
            else
              match constraint_.field_path.source with
              | Dep.State when target_source = "state" -> (
                  (* Path matches target source, apply mutation to rest of path *)
                  match constraint_.strategies with
                  | [] -> json_acc
                  | strategy :: _ ->
                      Json_mutator.mutate_json_file json_acc
                        constraint_.field_path strategy)
              | Dep.Block when target_source = "block" -> (
                  (* Path matches target source, apply mutation to rest of path *)
                  match constraint_.strategies with
                  | [] -> json_acc
                  | strategy :: _ ->
                      Json_mutator.mutate_json_file json_acc
                        constraint_.field_path strategy)
              | _ -> json_acc (* Constraint is for other file, skip *))
          json constraints
      in
      let mutated_pre = apply_constraints pre "state" in
      let mutated_block_raw = apply_constraints block "block" in

      (* Cap slot gap if max_slot_gap is set *)
      let mutated_block =
        match max_slot_gap with
        | Some max_gap ->
            cap_slot_gap ~max_slot_gap:max_gap mutated_pre mutated_block_raw
        | None -> mutated_block_raw
      in

      (* Save mutated JSON files as pre.json and block.json in the mutation directory *)
      let output_pre_path = Filename.concat mutation_dir "pre.json" in
      let output_block_path = Filename.concat mutation_dir "block.json" in
      Json_mutator.save_json output_pre_path mutated_pre;
      Json_mutator.save_json output_block_path mutated_block;
      (output_pre_path, output_block_path)

(* Get blacklisted fields from path condition for a premise.
   Path condition results are now organized per-premise with blacklists. *)
let get_blacklisted_fields (premise_uid : premise_uid)
    (_coverage : Instrumentation.Node_coverage_il.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option) :
    field_path list =
  match path_condition with
  | None -> []
  | Some pc -> (
      (* Find blacklists for this premise UID *)
      match List.assoc_opt premise_uid pc.blacklists with
      | None -> []
      | Some path_conditions ->
          (* Flatten all path conditions and convert field_paths to string lists *)
          List.flatten path_conditions)

(* Generate test case for a selected premise.
   
   Parameters:
   - premise_uid: The UID of the premise to target
   - coverage: Coverage data for premise-to-test mapping
   - dependency: Positive analysis results for mutation suggestions
   - path_condition: Path condition results for blacklist
   - base_test_case_id: Optional specific test case to use as base
   - test_dir: Directory containing test case JSON files
   - output_dir: Directory to write mutated files
   
   Returns: List of (mutation_id, mutated_pre_path, mutated_block_path)
*)
let generate_test_case ~(test_dir : string) ~(output_dir : string)
    (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option)
    (_path_condition : Instrumentation.Dependency.Negative.result option)
    (base_test_case_id : test_case_id option) : (string * string * string) list
    =
  (* Get mutation constraints *)
  let constraints =
    infer_mutation_constraints premise_uid coverage dependency
  in
  (* Negative analysis disabled as per plan *)
  let blacklisted =
    []
    (* get_blacklisted_fields premise_uid coverage path_condition *)
  in
  (* Find a base test case to mutate *)
  let test_case_id_opt =
    match base_test_case_id with
    | Some id -> Some id
    | None -> (
        match get_test_cases_for_premise premise_uid coverage with
        | [] -> None (* No test cases - skip this premise *)
        | first :: _ -> Some first)
  in

  match test_case_id_opt with
  | None -> [] (* Skip when no test cases available *)
  | Some test_id_raw ->
      (* Sanitize test_id: remove /pre.json suffix if present *)
      let test_id =
        if String.ends_with ~suffix:"/pre.json" test_id_raw then
          String.sub test_id_raw 0 (String.length test_id_raw - 9)
        else test_id_raw
      in

      (* test_id is the full path like "eth-tests-sanity/.../pre.json"
         We need to construct paths to pre.json and block.json *)
      let base_path =
        if Filename.check_suffix test_id ".json" then
          Filename.chop_extension test_id
        else test_id
      in
      let base_path =
        if Filename.check_suffix base_path "_pre" then
          Filename.chop_suffix base_path "_pre"
        else if Filename.check_suffix base_path "_block" then
          Filename.chop_suffix base_path "_block"
        else base_path
      in

      let pre_path = Filename.concat test_dir (base_path ^ "_pre.json") in
      let block_path = Filename.concat test_dir (base_path ^ "_block.json") in

      (* Create premise-specific output directory *)
      let premise_output_dir =
        Filename.concat output_dir (Printf.sprintf "premise_%d" premise_uid)
      in
      (try Unix.mkdir premise_output_dir 0o755
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

      (* Prepare report file *)
      let report_path = Filename.concat premise_output_dir "report.txt" in
      let report_channel = open_out report_path in
      Printf.fprintf report_channel "Mutation Report for Premise UID %d\n"
        premise_uid;
      Printf.fprintf report_channel "Base Test Case: %s\n\n" test_id;

      (* Iterate over constraints and strategies *)
      let generated_files = ref [] in
      List.iteri
        (fun c_idx constraint_ ->
          List.iteri
            (fun s_idx strategy ->
              let mut_id =
                Printf.sprintf "%s_mut%d_%d"
                  (String.map (fun c -> if c = '/' then '_' else c) test_id)
                  c_idx s_idx
              in
              let single_constraint =
                { constraint_ with strategies = [ strategy ] }
              in

              (* Mutate and save *)
              let out_pre, out_block =
                mutate_json_input ~output_dir:premise_output_dir mut_id
                  [ single_constraint ] blacklisted pre_path block_path
              in

              (* Record generated files if successful (paths different from input) *)
              if out_pre <> pre_path then (
                generated_files :=
                  (mut_id, out_pre, out_block) :: !generated_files;

                (* Write to report *)
                Printf.fprintf report_channel "Mutation ID: %s\n" mut_id;
                Printf.fprintf report_channel "  Field Path: %s\n"
                  (Instrumentation.Dependency.Dep_common.string_of_field_path
                     constraint_.field_path);
                Printf.fprintf report_channel "  Strategy: %s\n"
                  (match strategy with
                  | Json_mutator.SetValue _ -> "SetValue"
                  | Json_mutator.Increment i -> Printf.sprintf "Increment %d" i
                  | Json_mutator.Decrement i -> Printf.sprintf "Decrement %d" i
                  | Json_mutator.SetBoundary -> "SetBoundary"
                  | Json_mutator.AppendItem -> "AppendItem"
                  | Json_mutator.RemoveItem -> "RemoveItem"
                  | Json_mutator.SetLength len ->
                      Printf.sprintf "SetLength %d" len);
                Printf.fprintf report_channel "\n"))
            constraint_.strategies)
        constraints;

      close_out report_channel;
      List.rev !generated_files

(* Generate test cases for multiple premises *)
let generate_test_cases ~(test_dir : string) ~(output_dir : string)
    (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option) :
    (premise_uid * (string * string * string) list) list =
  List.map
    (fun uid ->
      let results =
        generate_test_case ~test_dir ~output_dir uid coverage dependency
          path_condition None
      in
      (uid, results))
    premise_uids

(* Generate tests organized by test case (new test-case-centric approach).
   
   For each test case:
   1. Run on-demand positive dependency analysis with premise filtering
   2. Extract mutations per premise
   3. Generate mutated files in test_case directory
   4. Write enhanced report: [field, from_value, to_value]
   
   Returns: (test_case_id * (premise_uid * mutation_info list) list) list
*)
(* === Checkpoint Support for Testgen === *)

(* Load testgen checkpoint if resuming *)
let load_testgen_checkpoint (file : string) : Testgen_data.t =
  match Checkpoint.load_from_file ~file with
  | Ok checkpoint -> (
      match checkpoint.Checkpoint.coverage.testgen with
      | Some data -> data
      | None -> Testgen_data.empty)
  | Error _ -> Testgen_data.empty

(* Save testgen checkpoint *)
let save_testgen_checkpoint ~(file : string option) ~(analyzed : string list)
    ~(positive_result : Instrumentation.Dependency.Positive.result) : unit =
  match file with
  | None -> ()
  | Some checkpoint_file ->
      (* Create testgen data *)
      let testgen_data =
        Testgen_data.of_positive_result ~analyzed positive_result
      in

      (* Create coverage with testgen data *)
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

      (* Create checkpoint manually *)
      let checkpoint =
        {
          Checkpoint.spec_hash = "";
          (* Empty hash for testgen-only checkpoint *)
          completed_inputs = analyzed;
          coverage;
          timestamp = Unix.gettimeofday ();
        }
      in

      (* Save to file *)
      Checkpoint.save_to_file ~file:checkpoint_file checkpoint;
      Format.printf "Saved testgen checkpoint: %s (%d tests analyzed)\n%!"
        checkpoint_file (List.length analyzed)

(* Filter test cases by seed type *)
let filter_by_seed_type (seed_filter : string option)
    (test_ids : (string * 'a) list) : (string * 'a) list =
  match seed_filter with
  | None -> test_ids
  | Some filter_type ->
      List.filter
        (fun (test_id, _) ->
          let lower_id = String.lowercase_ascii test_id in
          let lower_filter = String.lowercase_ascii filter_type in
          try
            let _ =
              Str.search_forward (Str.regexp_string lower_filter) lower_id 0
            in
            true
          with Not_found -> false)
        test_ids

(* === Test Generation === *)

let generate_tests_by_test_case ~(test_dir : string) ~(output_dir : string)
    (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (analyze_test_case :
      test_case_id ->
      premise_uid list ->
      Instrumentation.Dependency.Positive.result option) :
    (test_case_id * (premise_uid * (string * string * string) list) list) list =
  (* Get test_id -> premise_uids mapping *)
  let test_to_prems = get_test_to_premises premise_uids coverage in

  (* Process each test case *)
  List.filter_map
    (fun (test_id, prem_uids) ->
      Format.printf "Processing test case: %s (premises: %s)\n%!" test_id
        (String.concat ", " (List.map string_of_int prem_uids));

      (* Run on-demand analysis for this test case *)
      match analyze_test_case test_id prem_uids with
      | None ->
          Format.printf "  Skipped: analysis failed\n%!";
          None
      | Some dependency_result ->
          (* Create test case output directory *)
          let test_case_sanitized =
            String.map (fun c -> if c = '/' then '_' else c) test_id
          in
          let test_case_output_dir =
            Filename.concat output_dir test_case_sanitized
          in
          (try Unix.mkdir test_case_output_dir 0o755
           with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

          (* Construct paths to base test case JSON files *)
          (* test_id includes /pre.json suffix, strip it to get the directory *)
          let test_case_dir =
            if String.ends_with ~suffix:"/pre.json" test_id then
              String.sub test_id 0 (String.length test_id - 9)
              (* Remove "/pre.json" *)
            else test_id
          in
          let pre_path =
            Filename.concat test_dir (test_case_dir ^ "/pre.json")
          in
          let block_path =
            Filename.concat test_dir (test_case_dir ^ "/block.json")
          in

          (* Load JSON for value extraction *)
          let pre_json_opt =
            try Some (Json_mutator.load_json pre_path) with _ -> None
          in
          let block_json_opt =
            try Some (Json_mutator.load_json block_path) with _ -> None
          in

          (* Open report file *)
          let report_path = Filename.concat test_case_output_dir "report.txt" in
          let report_channel = open_out report_path in
          Printf.fprintf report_channel "Test Case: %s\n\n" test_id;

          (* Get mutations for all premises of this test, deduplicated across premises *)
          let all_mutations =
            get_mutation_suggestions_for_premises prem_uids coverage
              (Some dependency_result) test_id
          in
          (* Convert deduplicated mutations directly to constraints *)
          let module Pos = Instrumentation.Dependency.Positive in
          let module Dep = Instrumentation.Dependency.Dep_common in
          let all_constraints =
            List.filter_map
              (fun (sym_mut : Pos.sym_mutation) ->
                match sym_mut.target_path with
                | None -> None
                | Some target_path ->
                    let strategies =
                      match sym_mut.suggestion with
                      | Pos.ToConst (op, value) ->
                          generate_toconst_strategies op value None
                      | Pos.ToLength (op, value) ->
                          generate_tolength_strategies op value
                      | Pos.Unknown hint -> (
                          (* Check if path is a list *)
                          let is_list_path =
                            match target_path.steps with
                            | [] -> false
                            | steps -> (
                                let last_step = List.hd (List.rev steps) in
                                match last_step with
                                | Dep.FieldAccess field_name ->
                                    let name_lower =
                                      String.lowercase_ascii field_name
                                    in
                                    List.mem name_lower
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
                                    || String.ends_with ~suffix:"s" name_lower
                                       && String.length name_lower > 1
                                | Dep.IndexAccess _ -> true)
                          in
                          if is_list_path then
                            (* Will be handled when we have source value *)
                            []
                          else
                            (* Generate strategies based on value hint or type hint *)
                            let strategies_from_value value =
                              match value.it with
                              | Il.NumV (`Nat _) | Il.NumV (`Int _) ->
                                  [
                                    Json_mutator.SetValue (`Intlit "0");
                                    Json_mutator.SetValue
                                      (`Intlit "18446744073709551615");
                                  ]
                              | Il.BytesV { len; _ } ->
                                  let zeros_hex = String.make (len * 2) '0' in
                                  let ones_hex = String.make (len * 2) 'f' in
                                  [
                                    Json_mutator.SetValue
                                      (`String ("0x" ^ zeros_hex));
                                    Json_mutator.SetValue
                                      (`String ("0x" ^ ones_hex));
                                  ]
                              | Il.BoolV _ ->
                                  [
                                    Json_mutator.SetValue (`Bool true);
                                    Json_mutator.SetValue (`Bool false);
                                  ]
                              | Il.ListV items ->
                                  let current_len = List.length items in
                                  if current_len = 0 then []
                                  else
                                    [
                                      Json_mutator.SetLength (2 * current_len);
                                      Json_mutator.SetLength 0;
                                    ]
                              | Il.StructV _ -> []
                              | _ -> []
                            in
                            let strategies_from_type typ =
                              match typ with
                              | Il.NumT `NatT | Il.NumT `IntT ->
                                  [
                                    Json_mutator.SetValue (`Intlit "0");
                                    Json_mutator.SetValue
                                      (`Intlit "18446744073709551615");
                                  ]
                              | Il.BoolT ->
                                  [
                                    Json_mutator.SetValue (`Bool true);
                                    Json_mutator.SetValue (`Bool false);
                                  ]
                              | Il.TextT ->
                                  [
                                    Json_mutator.SetValue (`String "");
                                    Json_mutator.SetValue
                                      (`String "mutated_string");
                                  ]
                              | Il.VarT (id, _) ->
                                  let name = String.lowercase_ascii id.it in
                                  if
                                    String.length name >= 5
                                    && String.sub name 0 5 = "bytes"
                                  then
                                    let len_str =
                                      String.sub name 5 (String.length name - 5)
                                    in
                                    let len =
                                      try int_of_string len_str with _ -> 32
                                    in
                                    let zeros_hex = String.make (len * 2) '0' in
                                    let ones_hex = String.make (len * 2) 'f' in
                                    [
                                      Json_mutator.SetValue
                                        (`String ("0x" ^ zeros_hex));
                                      Json_mutator.SetValue
                                        (`String ("0x" ^ ones_hex));
                                    ]
                                  else if name = "boolean" || name = "bool" then
                                    [
                                      Json_mutator.SetValue (`Bool true);
                                      Json_mutator.SetValue (`Bool false);
                                    ]
                                  else if
                                    List.mem name
                                      [
                                        "uint64";
                                        "slot";
                                        "epoch";
                                        "validatorindex";
                                        "nat";
                                        "int";
                                      ]
                                  then
                                    [
                                      Json_mutator.SetValue (`Intlit "0");
                                      Json_mutator.SetValue
                                        (`Intlit "18446744073709551615");
                                    ]
                                  else if
                                    List.mem name
                                      [
                                        "root";
                                        "hash32";
                                        "blspubkey";
                                        "blssignature";
                                      ]
                                  then
                                    let len =
                                      if
                                        name = "blspubkey"
                                        || name = "blssignature"
                                      then 48
                                      else 32
                                    in
                                    let zeros_hex = String.make (len * 2) '0' in
                                    let ones_hex = String.make (len * 2) 'f' in
                                    [
                                      Json_mutator.SetValue
                                        (`String ("0x" ^ zeros_hex));
                                      Json_mutator.SetValue
                                        (`String ("0x" ^ ones_hex));
                                    ]
                                  else []
                              | Il.IterT (_, Il.List) -> []
                              | _ -> []
                            in
                            match hint with
                            | Pos.ValueHint v -> strategies_from_value v
                            | Pos.TypeHint t -> strategies_from_type t
                            | Pos.NoHint -> [])
                    in
                    (* Deduplicate strategies *)
                    let deduplicated_strategies =
                      List.sort_uniq
                        (fun s1 s2 ->
                          match (s1, s2) with
                          | Json_mutator.SetValue v1, Json_mutator.SetValue v2
                            ->
                              compare (Yojson.Safe.to_string v1)
                                (Yojson.Safe.to_string v2)
                          | Json_mutator.SetLength l1, Json_mutator.SetLength l2
                            ->
                              compare l1 l2
                          | Json_mutator.Increment i1, Json_mutator.Increment i2
                            ->
                              compare i1 i2
                          | Json_mutator.Decrement i1, Json_mutator.Decrement i2
                            ->
                              compare i1 i2
                          | Json_mutator.SetBoundary, Json_mutator.SetBoundary
                            ->
                              0
                          | Json_mutator.AppendItem, Json_mutator.AppendItem ->
                              0
                          | Json_mutator.RemoveItem, Json_mutator.RemoveItem ->
                              0
                          | _ -> compare s1 s2)
                        strategies
                    in
                    if deduplicated_strategies = [] then None
                    else
                      let suggestion_str =
                        Some (Pos.string_of_sym_mutation sym_mut)
                      in
                      Some
                        {
                          field_path = target_path;
                          strategies = deduplicated_strategies;
                          suggestion_str;
                        })
              all_mutations
          in
          (* Deduplicate constraints across all premises for this test *)
          let constraint_key constraint_ =
            let path_str = Dep.string_of_field_path constraint_.field_path in
            let strategies_str =
              String.concat ","
                (List.map
                   (function
                     | Json_mutator.SetValue v ->
                         "SetValue:" ^ Yojson.Safe.to_string v
                     | Json_mutator.SetLength len ->
                         "SetLength:" ^ string_of_int len
                     | Json_mutator.Increment i ->
                         "Increment:" ^ string_of_int i
                     | Json_mutator.Decrement i ->
                         "Decrement:" ^ string_of_int i
                     | Json_mutator.SetBoundary -> "SetBoundary"
                     | Json_mutator.AppendItem -> "AppendItem"
                     | Json_mutator.RemoveItem -> "RemoveItem")
                   constraint_.strategies)
            in
            Printf.sprintf "%s|%s" path_str strategies_str
          in
          let seen_constraints = Hashtbl.create (List.length all_constraints) in
          let deduplicated_constraints =
            List.filter
              (fun constraint_ ->
                let key = constraint_key constraint_ in
                if Hashtbl.mem seen_constraints key then false
                else (
                  Hashtbl.replace seen_constraints key ();
                  true))
              all_constraints
          in
          (* Process all deduplicated constraints together (not per premise) *)
          if deduplicated_constraints = [] then (
            Printf.fprintf report_channel
              "No mutations found for any premise\n\n";
            None)
          else (
            Printf.fprintf report_channel "Mutations for premises: %s\n"
              (String.concat ", " (List.map string_of_int prem_uids));

            (* Generate mutations *)
            let generated_files = ref [] in
            List.iteri
              (fun c_idx constraint_ ->
                (* Check source value first - if not found, skip mutations *)
                let source_value_opt =
                  match
                    (constraint_.field_path.source, pre_json_opt, block_json_opt)
                  with
                  | Dep.State, Some pre_json, _ ->
                      Json_mutator.get_value_at_path pre_json
                        constraint_.field_path
                  | Dep.Block, _, Some block_json ->
                      Json_mutator.get_value_at_path block_json
                        constraint_.field_path
                  | Dep.Local _, Some pre_json, _ -> (
                      (* Try state JSON first for local variables *)
                      match
                        Json_mutator.get_value_at_path pre_json
                          constraint_.field_path
                      with
                      | Some v -> Some v
                      | None -> (
                          (* Fallback to block JSON *)
                          match block_json_opt with
                          | Some block_json ->
                              Json_mutator.get_value_at_path block_json
                                constraint_.field_path
                          | None -> None))
                  | _ -> None
                in

                match source_value_opt with
                | None -> (
                    (* Source not found - just report and skip mutations *)
                    Printf.fprintf report_channel "  - Field: %s\n"
                      (Instrumentation.Dependency.Dep_common
                       .string_of_field_path constraint_.field_path);
                    (match constraint_.suggestion_str with
                    | Some suggestion ->
                        Printf.fprintf report_channel "    Suggestion: %s\n"
                          suggestion
                    | None -> ());
                    match constraint_.field_path.source with
                    | Dep.State ->
                        Printf.fprintf report_channel
                          "    From: <not found in state>\n"
                    | Dep.Block ->
                        Printf.fprintf report_channel
                          "    From: <not found in block>\n"
                    | _ ->
                        Printf.fprintf report_channel "    From: <not found>\n")
                | Some source_value ->
                    (* Source found - check if we should skip mutations *)
                    (* Skip if source is empty list *)
                    let is_empty_list =
                      match source_value with `List [] -> true | _ -> false
                    in
                    (* Skip if from = to (check for each strategy) *)
                    let should_skip_strategy strategy =
                      match (source_value, strategy) with
                      | `Bool source_b, Json_mutator.SetValue (`Bool target_b)
                        when source_b = target_b ->
                          true
                      | `Int source_i, Json_mutator.SetValue (`Int target_i)
                        when source_i = target_i ->
                          true
                      | ( `Intlit source_s,
                          Json_mutator.SetValue (`Intlit target_s) )
                        when source_s = target_s ->
                          true
                      | ( `String source_s,
                          Json_mutator.SetValue (`String target_s) )
                        when source_s = target_s ->
                          true
                      | `List source_list, Json_mutator.SetLength target_len
                        when List.length source_list = target_len ->
                          true
                      | _ -> false
                    in
                    (* Check if this is a list path that needs special handling *)
                    let is_list_path =
                      match constraint_.field_path.steps with
                      | [] -> false
                      | steps -> (
                          let last_step = List.hd (List.rev steps) in
                          match last_step with
                          | Dep.FieldAccess field_name ->
                              let name_lower =
                                String.lowercase_ascii field_name
                              in
                              List.mem name_lower
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
                              || String.ends_with ~suffix:"s" name_lower
                                 && String.length name_lower > 1
                          | Dep.IndexAccess _ -> true)
                    in
                    (* For list paths with Unknown or ToConst, generate double/nothing strategies *)
                    let list_strategies =
                      if is_list_path && constraint_.strategies = [] then
                        match source_value with
                        | `List source_list ->
                            let current_len = List.length source_list in
                            if current_len = 0 then
                              (* Can't mutate empty list *)
                              []
                            else
                              [
                                Json_mutator.SetLength (2 * current_len);
                                Json_mutator.SetLength 0;
                              ]
                        | _ -> []
                      else []
                    in
                    (* Filter out strategies that would result in no change or empty list *)
                    let base_strategies =
                      if is_empty_list then
                        (* Skip all mutations for empty lists *)
                        []
                      else
                        List.filter
                          (fun s -> not (should_skip_strategy s))
                          constraint_.strategies
                    in
                    (* Combine base strategies with list strategies *)
                    let valid_strategies = base_strategies @ list_strategies in
                    if valid_strategies = [] then
                      (* No valid mutations - skip *)
                      ()
                    else
                      (* Adjust boolean strategies to flip source value *)
                      let adjusted_strategies =
                        List.map
                          (fun strategy ->
                            match (source_value, strategy) with
                            | `Bool source_bool, Json_mutator.SetValue (`Bool _)
                              ->
                                (* For booleans, always flip the source value *)
                                Json_mutator.SetValue (`Bool (not source_bool))
                            | _ -> strategy)
                          valid_strategies
                      in
                      let source_value_str =
                        Yojson.Safe.to_string source_value
                      in
                      List.iteri
                        (fun s_idx strategy ->
                          let mut_id = Printf.sprintf "mut_%d_%d" c_idx s_idx in
                          let single_constraint =
                            { constraint_ with strategies = [ strategy ] }
                          in

                          (* Get destination value from strategy *)
                          let dest_value_str =
                            match strategy with
                            | Json_mutator.SetValue v -> Yojson.Safe.to_string v
                            | Json_mutator.Increment i -> Printf.sprintf "+%d" i
                            | Json_mutator.Decrement i -> Printf.sprintf "-%d" i
                            | Json_mutator.SetBoundary -> "<boundary>"
                            | Json_mutator.AppendItem -> "<append>"
                            | Json_mutator.RemoveItem -> "<remove>"
                            | Json_mutator.SetLength len ->
                                Printf.sprintf "<length %d>" len
                          in

                          (* Mutate and save *)
                          let out_pre, out_block =
                            mutate_json_input ~output_dir:test_case_output_dir
                              mut_id [ single_constraint ] [] pre_path
                              block_path
                          in

                          (* Record if successful *)
                          if out_pre <> pre_path then (
                            generated_files :=
                              (mut_id, out_pre, out_block) :: !generated_files;

                            (* Write to report *)
                            Printf.fprintf report_channel "  - Field: %s\n"
                              (Instrumentation.Dependency.Dep_common
                               .string_of_field_path constraint_.field_path);
                            (match constraint_.suggestion_str with
                            | Some suggestion ->
                                Printf.fprintf report_channel
                                  "    Suggestion: %s\n" suggestion
                            | None -> ());
                            Printf.fprintf report_channel "    From: %s\n"
                              source_value_str;
                            Printf.fprintf report_channel "    To: %s\n"
                              dest_value_str))
                        adjusted_strategies)
              deduplicated_constraints;

            Printf.fprintf report_channel "\n";

            close_out report_channel;

            if !generated_files = [] then None
            else
              (* Return with first premise UID for tracking *)
              Some (test_id, [ (List.hd prem_uids, List.rev !generated_files) ])))
    test_to_prems

(* Generate tests with checkpoint support - resumable with progress tracking *)
let generate_tests_with_checkpoint ~(test_dir : string) ~(output_dir : string)
    ~(checkpoint_file : string option) ~(resume_file : string option)
    ~(save_interval : int) ~(filter_seeds : string option)
    ~(select_minimal : bool) ?(max_slot_gap : int = 32)
    (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (analyze_test_case :
      test_case_id ->
      premise_uid list ->
      Instrumentation.Dependency.Positive.result option) :
    (test_case_id * (premise_uid * (string * string * string) list) list) list =
  (* Load checkpoint if resuming *)
  let testgen_data =
    match resume_file with
    | Some file ->
        Format.printf "Resuming from checkpoint: %s\n%!" file;
        load_testgen_checkpoint file
    | None -> Testgen_data.empty
  in

  (* Get test_id -> premise_uids mapping *)
  let all_test_to_prems = get_test_to_premises premise_uids coverage in

  (* Filter by seed type if requested *)
  let seed_filtered_test_to_prems =
    filter_by_seed_type filter_seeds all_test_to_prems
  in

  (* Filter by slot gap *)
  let filtered_test_to_prems =
    let before_count = List.length seed_filtered_test_to_prems in
    let result =
      List.filter
        (fun (test_id, _) ->
          slot_gap_within_limit ~test_dir ~max_slot_gap test_id)
        seed_filtered_test_to_prems
    in
    let after_count = List.length result in
    if before_count <> after_count then
      Format.printf "Slot-gap filter (max %d): %d → %d tests\n%!" max_slot_gap
        before_count after_count;
    result
  in

  (* Apply minimal selection if requested *)
  let test_to_prems =
    if select_minimal then (
      Format.printf "Selecting minimal set of tests (greedy set cover)...\n%!";
      (* Build premise -> tests and test -> prems hashtables *)
      let prem_to_tests = Hashtbl.create 256 in
      let test_to_prems_tbl = Hashtbl.create 256 in
      List.iter
        (fun (test_id, prems) ->
          Hashtbl.replace test_to_prems_tbl test_id prems;
          List.iter
            (fun prem ->
              let existing =
                Hashtbl.find_opt prem_to_tests prem |> Option.value ~default:[]
              in
              if not (List.mem test_id existing) then
                Hashtbl.replace prem_to_tests prem (test_id :: existing))
            prems)
        filtered_test_to_prems;
      (* Run greedy set cover *)
      let selected =
        Source_selector.select_minimal_tests premise_uids prem_to_tests
          test_to_prems_tbl
      in
      Format.printf
        "Selected %d tests (from %d candidates) covering %d premises\n%!"
        (List.length selected)
        (List.length filtered_test_to_prems)
        (List.length premise_uids);
      (* Sort tests: sanity tests first, random tests last *)
      let test_priority (test_id, _) =
        let test_id_lower = String.lowercase_ascii test_id in
        (* Check if test_id contains "sanity" or "random" as substrings *)
        let has_sanity =
          try
            let _ =
              Str.search_forward (Str.regexp_string "sanity") test_id_lower 0
            in
            true
          with Not_found -> false
        in
        let has_random =
          try
            let _ =
              Str.search_forward (Str.regexp_string "random") test_id_lower 0
            in
            true
          with Not_found -> false
        in
        if has_sanity then 0 (* sanity tests first *)
        else if has_random then 2 (* random tests last *)
        else 1 (* other tests in between *)
      in
      List.sort
        (fun t1 t2 ->
          let p1 = test_priority t1 in
          let p2 = test_priority t2 in
          if p1 <> p2 then compare p1 p2 else compare (fst t1) (fst t2))
          (* Stable sort by test_id within same priority *)
        selected)
    else filtered_test_to_prems
  in

  (* Filter out already-analyzed tests *)
  let test_ids = List.map fst test_to_prems in
  let remaining_test_ids =
    Testgen_data.filter_remaining testgen_data test_ids
  in
  let remaining_test_to_prems =
    List.filter
      (fun (test_id, _) -> List.mem test_id remaining_test_ids)
      test_to_prems
  in

  Format.printf "Total tests: %d, Already analyzed: %d, Remaining: %d\n%!"
    (List.length test_ids)
    (List.length test_ids - List.length remaining_test_ids)
    (List.length remaining_test_ids);

  (* Track analyzed tests for checkpoint *)
  let analyzed = ref (Testgen_data.analyzed_tests testgen_data) in
  let last_dep_result = ref None in

  (* Track previously generated mutations across test cases to avoid duplicates *)
  let module Dep = Instrumentation.Dependency.Dep_common in
  let previously_generated_mutations = Hashtbl.create 1000 in

  (* Calculate starting position for progress display *)
  let already_completed =
    List.length test_ids - List.length remaining_test_ids
  in
  let total_tests = List.length test_ids in

  (* Process each test case with periodic checkpointing *)
  let results =
    List.mapi
      (fun idx (test_id, prem_uids) ->
        (* Show absolute progress: already_completed + current position *)
        Format.printf "[%d/%d] Processing test case: %s\n%!"
          (already_completed + idx + 1)
          total_tests test_id;

        (* Run analysis *)
        let result_opt = analyze_test_case test_id prem_uids in
        (match result_opt with
        | Some dep_result -> last_dep_result := Some dep_result
        | None -> ());

        (* Track as analyzed *)
        analyzed := test_id :: !analyzed;

        (* Periodic checkpoint save *)
        if (idx + 1) mod save_interval = 0 then (
          Format.printf "Saving checkpoint at test %d/%d...\n%!" (idx + 1)
            (List.length remaining_test_to_prems);
          match result_opt with
          | Some dep_result ->
              save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
                ~positive_result:dep_result;
              Instrumentation.Dependency.Positive.clear_memory ()
          | None -> ());

        (* Generate mutations if analysis succeeded *)
        match result_opt with
        | None ->
            Format.printf "  Skipped: analysis failed\n%!";
            None
        | Some dependency_result ->
            let test_case_sanitized =
              String.map (fun c -> if c = '/' then '_' else c) test_id
            in
            let test_case_output_dir =
              Filename.concat output_dir test_case_sanitized
            in
            Unix.mkdir test_case_output_dir 0o755;

            (* test_id is like "eth-tests-sanity/.../full_random_operations_3/pre.json"
               The actual files are pre.json and block.json in the same directory.
               We need to replace /pre.json with /pre.json or /block.json *)
            let pre_path = Filename.concat test_dir test_id in
            let block_path =
              if Filename.check_suffix test_id "/pre.json" then
                Filename.concat test_dir
                  (Filename.chop_suffix test_id "/pre.json" ^ "/block.json")
              else if Filename.check_suffix test_id "/block.json" then
                Filename.concat test_dir
                  (Filename.chop_suffix test_id "/block.json" ^ "/pre.json")
              else
                (* Fallback: assume test_id is the directory, append /block.json *)
                Filename.concat test_dir (test_id ^ "/block.json")
            in

            let pre_json_opt =
              try Some (Json_mutator.load_json pre_path)
              with e ->
                Format.printf "[DEBUG] Failed to load pre_path: %s\n%!"
                  (Printexc.to_string e);
                None
            in
            let block_json_opt =
              try Some (Json_mutator.load_json block_path)
              with e ->
                Format.printf "[DEBUG] Failed to load block_path: %s\n%!"
                  (Printexc.to_string e);
                None
            in

            let report_path =
              Filename.concat test_case_output_dir "report.txt"
            in
            let report_channel = open_out report_path in
            Printf.fprintf report_channel "Test Case: %s\n\n" test_id;

            (* Collect all constraints from all premises first, then deduplicate *)
            let module Dep = Instrumentation.Dependency.Dep_common in
            (* Track which premises each constraint came from *)
            let all_constraints_with_prems =
              List.fold_left
                (fun acc prem_uid ->
                  let constraints =
                    infer_mutation_constraints prem_uid coverage
                      (Some dependency_result)
                  in
                  (* Tag each constraint with its premise UID *)
                  List.map (fun c -> (c, prem_uid)) constraints @ acc)
                [] prem_uids
            in
            (* Deduplicate constraints across all premises for this test *)
            let constraint_key constraint_ =
              let path_str = Dep.string_of_field_path constraint_.field_path in
              let strategies_str =
                String.concat ","
                  (List.map
                     (function
                       | Json_mutator.SetValue v ->
                           "SetValue:" ^ Yojson.Safe.to_string v
                       | Json_mutator.SetLength len ->
                           "SetLength:" ^ string_of_int len
                       | Json_mutator.Increment i ->
                           "Increment:" ^ string_of_int i
                       | Json_mutator.Decrement i ->
                           "Decrement:" ^ string_of_int i
                       | Json_mutator.SetBoundary -> "SetBoundary"
                       | Json_mutator.AppendItem -> "AppendItem"
                       | Json_mutator.RemoveItem -> "RemoveItem")
                     constraint_.strategies)
              in
              Printf.sprintf "%s|%s" path_str strategies_str
            in
            (* Deduplicate but keep track of all premise UIDs for each constraint *)
            let constraint_map =
              Hashtbl.create (List.length all_constraints_with_prems)
            in
            List.iter
              (fun (constraint_, prem_uid) ->
                let key = constraint_key constraint_ in
                match Hashtbl.find_opt constraint_map key with
                | None ->
                    Hashtbl.replace constraint_map key
                      (constraint_, [ prem_uid ])
                | Some (_, prems) ->
                    if not (List.mem prem_uid prems) then
                      Hashtbl.replace constraint_map key
                        (constraint_, prem_uid :: prems))
              all_constraints_with_prems;
            (* Convert back to list with premise UIDs, filtering out previously generated mutations *)
            let deduplicated_constraints =
              Hashtbl.fold
                (fun key (constraint_, prems) acc ->
                  (* Check if this mutation was already generated for a previous test case *)
                  if Hashtbl.mem previously_generated_mutations key then acc
                    (* Skip - already generated *)
                  else (
                    (* Mark as generated for future test cases *)
                    Hashtbl.replace previously_generated_mutations key ();
                    (constraint_, List.sort_uniq compare prems) :: acc))
                constraint_map []
            in

            (* Process all deduplicated constraints together (not per premise) *)
            if deduplicated_constraints = [] then (
              Printf.fprintf report_channel
                "No mutations found for any premise\n\n";
              close_out report_channel;
              None)
            else (
              Printf.fprintf report_channel "Mutations for premises: %s\n"
                (String.concat ", " (List.map string_of_int prem_uids));

              let generated_files = ref [] in
              List.iteri
                (fun c_idx (constraint_, premise_uids_for_constraint) ->
                  (* Check source value first - if not found, skip mutations *)
                  let source_value_opt =
                    match
                      ( constraint_.field_path.source,
                        pre_json_opt,
                        block_json_opt )
                    with
                    | Dep.State, Some pre_json, _ ->
                        Json_mutator.get_value_at_path pre_json
                          constraint_.field_path
                    | Dep.Block, _, Some block_json ->
                        Json_mutator.get_value_at_path block_json
                          constraint_.field_path
                    | Dep.Local _, Some pre_json, _ -> (
                        (* Try state JSON first for local variables *)
                        match
                          Json_mutator.get_value_at_path pre_json
                            constraint_.field_path
                        with
                        | Some v -> Some v
                        | None -> (
                            (* Fallback to block JSON *)
                            match block_json_opt with
                            | Some block_json ->
                                Json_mutator.get_value_at_path block_json
                                  constraint_.field_path
                            | None -> None))
                    | _ -> None
                  in

                  match source_value_opt with
                  | None -> (
                      (* Source not found - just report and skip mutations *)
                      Printf.fprintf report_channel "  - Field: %s\n"
                        (Instrumentation.Dependency.Dep_common
                         .string_of_field_path constraint_.field_path);
                      Printf.fprintf report_channel "    Premises: %s\n"
                        (String.concat ", "
                           (List.map (Printf.sprintf "%d")
                              premise_uids_for_constraint));
                      (match constraint_.suggestion_str with
                      | Some suggestion ->
                          Printf.fprintf report_channel "    Suggestion: %s\n"
                            suggestion
                      | None -> ());
                      match constraint_.field_path.source with
                      | Dep.State ->
                          Printf.fprintf report_channel
                            "    From: <not found in state>\n"
                      | Dep.Block ->
                          Printf.fprintf report_channel
                            "    From: <not found in block>\n"
                      | _ ->
                          Printf.fprintf report_channel
                            "    From: <not found>\n")
                  | Some source_value ->
                      (* Source found - check if we should skip mutations *)
                      (* Skip if source is empty list *)
                      let is_empty_list =
                        match source_value with `List [] -> true | _ -> false
                      in
                      (* Skip if from = to (check for each strategy) *)
                      let should_skip_strategy strategy =
                        match (source_value, strategy) with
                        | `Bool source_b, Json_mutator.SetValue (`Bool target_b)
                          when source_b = target_b ->
                            true
                        | `Int source_i, Json_mutator.SetValue (`Int target_i)
                          when source_i = target_i ->
                            true
                        | ( `Intlit source_s,
                            Json_mutator.SetValue (`Intlit target_s) )
                          when source_s = target_s ->
                            true
                        | ( `String source_s,
                            Json_mutator.SetValue (`String target_s) )
                          when source_s = target_s ->
                            true
                        | `List source_list, Json_mutator.SetLength target_len
                          when List.length source_list = target_len ->
                            true
                        | _ -> false
                      in
                      (* Check if this is a list path that needs special handling *)
                      let is_list_path =
                        match constraint_.field_path.steps with
                        | [] -> false
                        | steps -> (
                            let last_step = List.hd (List.rev steps) in
                            match last_step with
                            | Dep.FieldAccess field_name ->
                                let name_lower =
                                  String.lowercase_ascii field_name
                                in
                                List.mem name_lower
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
                                || String.ends_with ~suffix:"s" name_lower
                                   && String.length name_lower > 1
                            | Dep.IndexAccess _ -> true)
                      in
                      (* For list paths with Unknown or ToConst, generate double/nothing strategies *)
                      let list_strategies =
                        if is_list_path && constraint_.strategies = [] then
                          match source_value with
                          | `List source_list ->
                              let current_len = List.length source_list in
                              if current_len = 0 then
                                (* Can't mutate empty list *)
                                []
                              else
                                [
                                  Json_mutator.SetLength (2 * current_len);
                                  Json_mutator.SetLength 0;
                                ]
                          | _ -> []
                        else []
                      in
                      (* Filter out strategies that would result in no change or empty list *)
                      let base_strategies =
                        if is_empty_list then
                          (* Skip all mutations for empty lists *)
                          []
                        else
                          List.filter
                            (fun s -> not (should_skip_strategy s))
                            constraint_.strategies
                      in
                      (* Combine base strategies with list strategies *)
                      let valid_strategies =
                        base_strategies @ list_strategies
                      in
                      if valid_strategies = [] then
                        (* No valid mutations - skip *)
                        ()
                      else
                        (* Adjust boolean strategies to flip source value *)
                        let adjusted_strategies =
                          List.map
                            (fun strategy ->
                              match (source_value, strategy) with
                              | ( `Bool source_bool,
                                  Json_mutator.SetValue (`Bool _) ) ->
                                  (* For booleans, always flip the source value *)
                                  Json_mutator.SetValue
                                    (`Bool (not source_bool))
                              | _ -> strategy)
                            valid_strategies
                        in
                        let source_value_str =
                          Yojson.Safe.to_string source_value
                        in
                        List.iteri
                          (fun s_idx strategy ->
                            (* Include premise UIDs in file name *)
                            let prem_str =
                              String.concat "_"
                                (List.map (Printf.sprintf "prem%d")
                                   premise_uids_for_constraint)
                            in
                            let mut_id =
                              Printf.sprintf "mut_%s_%d_%d" prem_str c_idx s_idx
                            in
                            let single_constraint =
                              { constraint_ with strategies = [ strategy ] }
                            in

                            (* Get destination value from strategy *)
                            let dest_value_str =
                              match strategy with
                              | Json_mutator.SetValue v ->
                                  Yojson.Safe.to_string v
                              | Json_mutator.Increment i ->
                                  Printf.sprintf "+%d" i
                              | Json_mutator.Decrement i ->
                                  Printf.sprintf "-%d" i
                              | Json_mutator.SetBoundary -> "<boundary>"
                              | Json_mutator.AppendItem -> "<append>"
                              | Json_mutator.RemoveItem -> "<remove>"
                              | Json_mutator.SetLength len ->
                                  Printf.sprintf "<length %d>" len
                            in

                            (* Mutate and save *)
                            let out_pre, out_block =
                              mutate_json_input ~output_dir:test_case_output_dir
                                mut_id [ single_constraint ] [] pre_path
                                block_path
                            in

                            (* Record if successful *)
                            if out_pre <> pre_path then (
                              generated_files :=
                                (mut_id, out_pre, out_block) :: !generated_files;

                              (* Write to report *)
                              Printf.fprintf report_channel "  - Field: %s\n"
                                (Instrumentation.Dependency.Dep_common
                                 .string_of_field_path constraint_.field_path);
                              Printf.fprintf report_channel "    Premises: %s\n"
                                (String.concat ", "
                                   (List.map (Printf.sprintf "%d")
                                      premise_uids_for_constraint));
                              (match constraint_.suggestion_str with
                              | Some suggestion ->
                                  Printf.fprintf report_channel
                                    "    Suggestion: %s\n" suggestion
                              | None -> ());
                              Printf.fprintf report_channel "    From: %s\n"
                                source_value_str;
                              Printf.fprintf report_channel "    To: %s\n"
                                dest_value_str))
                          adjusted_strategies)
                deduplicated_constraints;

              Printf.fprintf report_channel "\n";

              close_out report_channel;

              if !generated_files = [] then None
              else
                (* Return with first premise UID for tracking *)
                Some
                  (test_id, [ (List.hd prem_uids, List.rev !generated_files) ])))
      remaining_test_to_prems
    |> List.filter_map Fun.id
  in

  (* Final checkpoint save *)
  (match checkpoint_file with
  | Some _ when results <> [] -> (
      Format.printf "Saving final checkpoint...\n%!";
      match !last_dep_result with
      | Some dep_result ->
          save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
            ~positive_result:dep_result
      | None -> ())
  | _ -> ());

  results
