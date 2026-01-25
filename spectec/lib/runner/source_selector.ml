(* Source test selector - selects minimal set of tests covering target premises.
   
   Uses greedy set cover algorithm with priority ordering:
   - Sanity tests preferred over finality over random
   - Tests covering more uncovered premises preferred
   
   This minimizes analysis overhead by selecting only necessary tests. *)

type test_source_type = Sanity | Finality | Random | Other

(* Classify test by name pattern *)
let classify_test_id (test_id : string) : test_source_type =
  let lower = String.lowercase_ascii test_id in
  (* Use Str for substring matching *)
  let contains s substr =
    try
      let _ = Str.search_forward (Str.regexp_string substr) s 0 in
      true
    with Not_found -> false
  in
  if contains lower "sanity" then Sanity
  else if contains lower "finality" then Finality
  else if contains lower "random" then Random
  else Other

(* Priority: lower is better *)
let priority_of = function
  | Sanity -> 0
  | Finality -> 1
  | Random -> 2
  | Other -> 3

(* Score a test based on priority and coverage of uncovered premises.
   Returns (priority, -coverage) so lower score is better. *)
let score_test (test_id : string) (test_prems : int list) (uncovered : int list)
    : int * int =
  let priority = priority_of (classify_test_id test_id) in
  let new_coverage = List.filter (fun p -> List.mem p uncovered) test_prems in
  (* Lower priority = better, more coverage = better (hence negative) *)
  (priority, -List.length new_coverage)

(* Greedy set cover: select minimal tests covering all target premises.
   
   Algorithm:
   1. Iterate over target premises
   2. For each uncovered premise, find best test that covers it
   3. Best = lowest priority (sanity > finality > random) + most coverage
   4. Add test to selected set, mark all its premises as covered
   
   Returns: list of (test_id, premises_covered) pairs *)
let select_minimal_tests (target_premises : int list)
    (prem_to_tests : (int, string list) Hashtbl.t)
    (test_to_prems : (string, int list) Hashtbl.t) : (string * int list) list =
  let covered = Hashtbl.create 256 in
  let selected = ref [] in

  List.iter
    (fun prem ->
      if not (Hashtbl.mem covered prem) then
        (* Find candidate tests that cover this premise *)
        let candidates =
          Hashtbl.find_opt prem_to_tests prem |> Option.value ~default:[]
        in
        (* Get list of still-uncovered premises *)
        let uncovered =
          List.filter (fun p -> not (Hashtbl.mem covered p)) target_premises
        in
        (* Score each candidate *)
        let scored =
          List.map
            (fun t ->
              let t_prems =
                Hashtbl.find_opt test_to_prems t |> Option.value ~default:[]
              in
              (t, score_test t t_prems uncovered, t_prems))
            candidates
        in
        (* Select best (lowest score) *)
        match List.sort (fun (_, s1, _) (_, s2, _) -> compare s1 s2) scored with
        | (best_test, _, best_prems) :: _ ->
            selected := (best_test, best_prems) :: !selected;
            (* Mark all premises covered by this test *)
            List.iter (fun p -> Hashtbl.replace covered p ()) best_prems
        | [] -> ())
    target_premises;

  List.rev !selected
