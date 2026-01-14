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

(* Types *)
type premise_uid = int
type test_case_id = string
type field_path = string list (* e.g., ["state", "SLOT"] *)

(* Mutation constraint - what field to mutate and to what values *)
type mutation_constraint = {
  field_path : field_path;
  target_values : Il.Value.t list;
      (* Skeleton - user will fill in inference logic *)
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
  let checkpoint = Checkpoint.load ~file:checkpoint_file in
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
          0 dep.per_test_mutations
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
let get_mutation_suggestions_for_premise (premise_uid : premise_uid)
    (_coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option) :
    Instrumentation.Dependency.Positive.mutation_suggestion list =
  match dependency with
  | None -> []
  | Some dep -> (
      (* Find mutations for this premise UID *)
      match List.assoc_opt premise_uid dep.per_test_mutations with
      | None -> []
      | Some test_muts ->
          (* Collect all mutations across all test cases *)
          List.fold_left (fun acc (_, muts) -> acc @ muts) [] test_muts)

(* Infer mutation constraints from dependency analysis. *)
let infer_mutation_constraints (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option) :
    mutation_constraint list =
  let suggestions =
    get_mutation_suggestions_for_premise premise_uid coverage dependency
  in
  (* Convert mutation suggestions to mutation constraints using new types *)
  let module Pos = Instrumentation.Dependency.Positive in
  let module Dep = Instrumentation.Dependency.Dep_common in
  List.filter_map
    (fun (suggestion : Pos.mutation_suggestion) ->
      (* Convert field_path to string list *)
      let rec steps_to_strings steps =
        match steps with
        | [] -> []
        | Dep.FieldAccess f :: rest -> f :: steps_to_strings rest
        | Dep.IndexAccess (Dep.ConstInt i) :: rest ->
            Printf.sprintf "[%d]" i :: steps_to_strings rest
        | Dep.IndexAccess (Dep.PathRef _) :: rest ->
            "[...]" :: steps_to_strings rest (* Dynamic index - placeholder *)
      in
      let source_prefix =
        match suggestion.field.Dep.source with
        | Dep.State -> [ "state" ]
        | Dep.Block -> [ "block" ]
        | Dep.Unknown -> []
      in
      let field_path =
        source_prefix @ steps_to_strings suggestion.field.Dep.steps
      in
      if field_path = [] then None
      else
        let target_values =
          match suggestion.hint with
          | Dep.Concrete (Dep.ToLiteral v) -> [ v ]
          | Dep.Concrete Dep.ToZero ->
              [ Il.Value.Make.num Il.Typ.nat (`Nat Bigint.zero) ]
          | Dep.Concrete Dep.ToOne ->
              [ Il.Value.Make.num Il.Typ.nat (`Nat Bigint.one) ]
          | Dep.Concrete Dep.ToMax | Dep.Concrete Dep.ToMin -> []
          | Dep.Symbolic _ -> [] (* Symbolic hints need runtime resolution *)
          | Dep.Unresolved _ -> []
        in
        Some { field_path; target_values })
    suggestions

(* Check if a test case ID corresponds to a state transition test.
   State transition tests are identified by having 'state_transition' in their path. *)
let is_state_transition_test (test_case_id : test_case_id) : bool =
  try
    let _ =
      Str.search_forward (Str.regexp_string "state_transition") test_case_id 0
    in
    true
  with Not_found -> false

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
              (* Filter to only state transition tests *)
              List.filter is_state_transition_test test_cases))

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

(* Convert Il.Value.t to JSON value for mutation *)
let value_to_json (v : Il.Value.t) : (Yojson.Safe.t, string) result =
  match Interface.JSON.Print.value_to_json v with
  | Ok json -> Ok json
  | Error err -> Error (Interface.JSON.Print.string_of_error err)

(* Check if a field path is blacklisted *)
let is_blacklisted (path : field_path) (blacklist : field_path list) : bool =
  (* Check if path starts with any blacklisted prefix *)
  List.exists
    (fun bl ->
      let rec is_prefix p bl =
        match (p, bl) with
        | [], _ -> true (* Blacklist is a prefix *)
        | _, [] -> false
        | x :: xs, y :: ys -> x = y && is_prefix xs ys
      in
      is_prefix bl path)
    blacklist

(* Mutate JSON input files based on mutation constraints.
   Returns paths to the mutated files (or originals if mutation failed). *)
let mutate_json_input ~(output_dir : string) (test_case_id : test_case_id)
    (constraints : mutation_constraint list) (blacklisted : field_path list)
    (pre_json_path : string) (block_json_path : string) : string * string =
  (* Ensure output directory exists *)
  (try Unix.mkdir output_dir 0o755
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
      (* Apply mutations, skipping blacklisted fields *)
      let apply_constraints json =
        List.fold_left
          (fun json_acc constraint_ ->
            if is_blacklisted constraint_.field_path blacklisted then json_acc
              (* Skip blacklisted fields *)
            else
              match constraint_.target_values with
              | [] -> json_acc
              | value :: _ -> (
                  match value_to_json value with
                  | Ok json_value ->
                      Json_mutator.set_field json_acc constraint_.field_path
                        json_value
                  | Error _ -> json_acc (* Skip if conversion fails *)))
          json constraints
      in
      let mutated_pre = apply_constraints pre in
      let mutated_block = apply_constraints block in

      (* Save mutated JSON files *)
      let output_pre_path =
        Filename.concat output_dir (Printf.sprintf "%s_pre.json" test_case_id)
      in
      let output_block_path =
        Filename.concat output_dir (Printf.sprintf "%s_block.json" test_case_id)
      in
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
          let module Dep = Instrumentation.Dependency.Dep_common in
          let rec steps_to_strings steps =
            match steps with
            | [] -> []
            | Dep.FieldAccess f :: rest -> f :: steps_to_strings rest
            | Dep.IndexAccess (Dep.ConstInt i) :: rest ->
                Printf.sprintf "[%d]" i :: steps_to_strings rest
            | Dep.IndexAccess (Dep.PathRef _) :: rest ->
                "[...]" :: steps_to_strings rest
          in
          List.flatten path_conditions
          |> List.map (fun field_path ->
                 let source_prefix =
                   match field_path.Dep.source with
                   | Dep.State -> [ "state" ]
                   | Dep.Block -> [ "block" ]
                   | Dep.Unknown -> []
                 in
                 source_prefix @ steps_to_strings field_path.Dep.steps)
          |> List.filter (fun path -> path <> []))

(* Generate test case for a selected premise.
   
   Parameters:
   - premise_uid: The UID of the premise to target
   - coverage: Coverage data for premise-to-test mapping
   - dependency: Positive analysis results for mutation suggestions
   - path_condition: Path condition results for blacklist
   - base_test_case_id: Optional specific test case to use as base
   - test_dir: Directory containing test case JSON files
   - output_dir: Directory to write mutated files
   
   Returns: Some (mutated_pre_path, mutated_block_path) or None if no test cases
*)
let generate_test_case ~(test_dir : string) ~(output_dir : string)
    (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option)
    (base_test_case_id : test_case_id option) : (string * string) option =
  (* Get mutation constraints *)
  let constraints =
    infer_mutation_constraints premise_uid coverage dependency
  in
  (* Get blacklisted fields from path condition *)
  let blacklisted =
    get_blacklisted_fields premise_uid coverage path_condition
  in
  (* Find a base test case to mutate *)
  let test_case_id =
    match base_test_case_id with
    | Some id -> Some id
    | None -> (
        match get_test_cases_for_premise premise_uid coverage with
        | [] -> None (* No test cases - skip this premise *)
        | first :: _ -> Some first)
  in

  match test_case_id with
  | None -> None (* Skip when no test cases available *)
  | Some test_id ->
      (* Construct paths to base test case JSON files *)
      let pre_path = Filename.concat test_dir (test_id ^ "/pre.json") in
      let block_path = Filename.concat test_dir (test_id ^ "/block.json") in

      (* Create premise-specific output directory *)
      let premise_output_dir =
        Filename.concat output_dir (Printf.sprintf "premise_%d" premise_uid)
      in

      (* Mutate and save *)
      let result =
        mutate_json_input ~output_dir:premise_output_dir test_id constraints
          blacklisted pre_path block_path
      in
      Some result

(* Generate test cases for multiple premises *)
let generate_test_cases ~(test_dir : string) ~(output_dir : string)
    (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option) :
    (premise_uid * (string * string)) list =
  List.filter_map
    (fun uid ->
      match
        generate_test_case ~test_dir ~output_dir uid coverage dependency
          path_condition None
      with
      | Some paths -> Some (uid, paths)
      | None -> None)
    premise_uids
