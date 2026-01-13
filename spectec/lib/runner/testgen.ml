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
   - Dependency results: mutation suggestions organized by relation/rule
   - Path condition results: negative dependencies (fields to avoid mutating)
   
   Note: If dependency/path_condition results are not in the checkpoint, you may
   need to re-run the test suite with those instrumentations enabled on the
   specific test cases that cover your selected premises. *)
let load_checkpoint (checkpoint_file : string) :
    Checkpoint.t
    * Instrumentation.Node_coverage_il.result option
    * Instrumentation.Dependency.result option
    * Instrumentation.Path_condition.result option =
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
  Format.fprintf fmt "  Dependency data: %s\n"
    (if Option.is_some dependency then "present" else "missing");
  (match dependency with
  | Some dep ->
      Format.fprintf fmt "    Relations analyzed: %d\n"
        (List.length dep.results);
      let total_mutations =
        List.fold_left
          (fun acc (_, rule_muts) ->
            List.fold_left
              (fun acc (_, muts) -> acc + List.length muts)
              acc rule_muts)
          0 dep.mutations
      in
      Format.fprintf fmt "    Total mutation suggestions: %d\n" total_mutations
  | None -> ());
  Format.fprintf fmt "  Path condition data: %s\n"
    (if Option.is_some path_condition then "present" else "missing");
  (match path_condition with
  | Some pc ->
      Format.fprintf fmt "    Premises with path conditions: %d\n"
        (List.length pc.path_conditions)
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
   Since dependency results are organized by relation/rule, we search through
   all relations/rules to find mutations that might apply to this premise.
   In the future, we could store relation/rule info with each premise UID. *)
let get_mutation_suggestions_for_premise (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.result option) :
    Instrumentation.Dependency.mutation_suggestion list =
  match (coverage, dependency) with
  | None, _ | _, None -> []
  | Some cov, Some dep -> (
      (* Find premise key for this UID *)
      let premise_key =
        List.find_map
          (fun (uid, key) -> if uid = premise_uid then Some key else None)
          cov.uid_to_prem
      in
      match premise_key with
      | None -> []
      | Some (_region, _) ->
          (* Search through all dependency results for mutations.
             Since we don't have direct mapping from premise to relation/rule,
             we collect all mutations from all relations/rules.
             In practice, the user should run dependency analysis on specific
             test cases that cover the premise, which will give more targeted results. *)
          List.fold_left
            (fun acc (_, rule_mutations) ->
              List.fold_left
                (fun acc (_, mutations) -> acc @ mutations)
                acc rule_mutations)
            [] dep.mutations)

(* Infer mutation constraints from dependency analysis. *)
let infer_mutation_constraints (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.result option) :
    mutation_constraint list =
  let suggestions =
    get_mutation_suggestions_for_premise premise_uid coverage dependency
  in
  (* Convert mutation suggestions to mutation constraints *)
  List.fold_left
    (fun acc (suggestion : Instrumentation.Dependency.mutation_suggestion) ->
      let field_path =
        match suggestion.field.Instrumentation.Dependency.source with
        | Instrumentation.Dependency.State -> "state" :: suggestion.field.fields
        | Instrumentation.Dependency.Block -> "block" :: suggestion.field.fields
        | Instrumentation.Dependency.Unknown -> []
      in
      if field_path = [] then acc
      else
        let target_values =
          match suggestion.strategy with
          | Instrumentation.Dependency.ToExactValue v -> [ v ]
          | Instrumentation.Dependency.ToDifferentValue v ->
              [ v ] (* User will need to generate different value *)
          | Instrumentation.Dependency.ToBoundaryMinus v ->
              [ v ] (* User will need to compute v-1 *)
          | Instrumentation.Dependency.ToBoundaryPlus v ->
              [ v ] (* User will need to compute v+1 *)
          | Instrumentation.Dependency.ToMatchField _ ->
              [] (* Need to resolve field value *)
          | Instrumentation.Dependency.ToZero ->
              [ Il.Value.Make.num Il.Typ.nat (`Nat Bigint.zero) ]
          | Instrumentation.Dependency.ToOne ->
              [ Il.Value.Make.num Il.Typ.nat (`Nat Bigint.one) ]
          | Instrumentation.Dependency.ToMax | Instrumentation.Dependency.ToMin
            ->
              [] (* Need type info to determine max/min *)
        in
        { field_path; target_values } :: acc)
    [] suggestions

(* Find test cases that covered a premise *)
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
          | Some test_cases -> test_cases))

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

(* TODO: Mutate JSON input files based on mutation constraints. *)
let mutate_json_input (_test_case_id : test_case_id)
    (_constraints : mutation_constraint list) (_blacklisted : field_path list)
    (pre_json_path : string) (block_json_path : string) : string * string =
  (* Skeleton: return original paths for now *)
  (* In full implementation, blacklisted fields would be excluded from mutation *)
  (pre_json_path, block_json_path)

(* Get blacklisted fields from path condition for a premise.
   Path condition results use string UIDs (like "relation:line-line"), so we
   try to match by premise location. *)
let get_blacklisted_fields (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (path_condition : Instrumentation.Path_condition.result option) :
    field_path list =
  match (coverage, path_condition) with
  | None, _ | _, None -> []
  | Some cov, Some pc -> (
      (* Find premise key (region) for this UID *)
      let premise_key =
        List.find_map
          (fun (uid, key) -> if uid = premise_uid then Some key else None)
          cov.uid_to_prem
      in
      match premise_key with
      | None -> []
      | Some (region, _) ->
          (* Try to match path condition entries by location.
             Path condition UIDs are strings like "relation:line-line".
             We'll try to match by line number from the region. *)
          let matching_paths =
            List.fold_left
              (fun acc (uid_str, paths) ->
                (* Check if the string UID matches our premise location *)
                let region_str =
                  Printf.sprintf "%d-%d" region.left.line region.right.line
                in
                (* Check if region_str appears as a substring in uid_str *)
                let is_match =
                  try
                    let len = String.length region_str in
                    let uid_len = String.length uid_str in
                    let rec check pos =
                      if pos + len > uid_len then false
                      else if String.sub uid_str pos len = region_str then true
                      else check (pos + 1)
                    in
                    check 0
                  with _ -> false
                in
                if is_match then
                  (* This might be our premise - collect the paths *)
                  acc @ paths
                else acc)
              [] pc.path_conditions
          in
          (* Flatten all matching path conditions and extract field paths *)
          List.flatten matching_paths
          |> List.map (fun field_access ->
                 match field_access with
                 | {
                  Instrumentation.Path_condition.source =
                    Instrumentation.Path_condition.State;
                  fields;
                 } ->
                     "state" :: fields
                 | {
                  Instrumentation.Path_condition.source =
                    Instrumentation.Path_condition.Block;
                  fields;
                 } ->
                     "block" :: fields
                 | _ -> [])
          |> List.filter (fun path -> path <> []))

(* Generate test case for a selected premise *)
let generate_test_case (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.result option)
    (path_condition : Instrumentation.Path_condition.result option)
    (base_test_case_id : test_case_id option) : string * string =
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
    | Some id -> id
    | None -> (
        (* Use first test case that covered this premise, if any *)
        match get_test_cases_for_premise premise_uid coverage with
        | [] -> "default_test_case"
        | first :: _ -> first)
  in
  (* For now, return placeholder paths - actual implementation will
     load JSON files, mutate them, and save to new locations *)
  let pre_path = Printf.sprintf "pre_%d.json" premise_uid in
  let block_path = Printf.sprintf "block_%d.json" premise_uid in
  mutate_json_input test_case_id constraints blacklisted pre_path block_path
