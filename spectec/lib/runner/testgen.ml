(* Testgen backend - Generates test cases by mutating input data to target uncovered premises.

   Uses coverage data to identify uncovered premises and dependency analysis to infer
   what fields need mutation. *)

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

(* Load checkpoint and extract coverage and dependency data *)
let load_checkpoint (checkpoint_file : string) :
    Checkpoint.t
    * Instrumentation.Node_coverage_il.result option
    * Instrumentation.Dependency.result option =
  let checkpoint = Checkpoint.load ~file:checkpoint_file in
  let coverage = checkpoint.Checkpoint.coverage.node_il in
  let dependency = checkpoint.Checkpoint.coverage.dependency in
  (checkpoint, coverage, dependency)

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

(* Infer mutation constraints from dependency analysis.
   This is a skeleton - user will fill in the inference logic. *)
let infer_mutation_constraints (_premise_uid : premise_uid)
    (dependency : Instrumentation.Dependency.result option) :
    mutation_constraint list =
  match dependency with
  | None -> []
  | Some _dep ->
      (* TODO:
         - Find the premise in dependency analysis results
         - Extract field paths from analyzed expressions
         - Determine target values for mutation *)
      []

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

(* TODO: Mutate JSON input files based on mutation constraints. *)
let mutate_json_input (_test_case_id : test_case_id)
    (_constraints : mutation_constraint list) (pre_json_path : string)
    (block_json_path : string) : string * string =
  (* Skeleton: return original paths for now *)
  (pre_json_path, block_json_path)

(* Generate test case for a selected premise *)
let generate_test_case (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.result option)
    (base_test_case_id : test_case_id option) : string * string =
  (* Get mutation constraints *)
  let constraints = infer_mutation_constraints premise_uid dependency in
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
  mutate_json_input test_case_id constraints pre_path block_path
