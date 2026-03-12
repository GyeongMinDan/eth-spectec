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

(* K-cover greedy selection: keep adding tests until every premise is covered
   by at least k distinct seeds.

   Algorithm:
   1. Initialize covered_count[prem] = 0 for all target premises
   2. Repeat:
      a. Find all premises with covered_count < k
      b. If none, stop
      c. Score each candidate test by priority then -new_under_covered_coverage
      d. Pick the best-scoring candidate not yet selected
      e. For each premise this test covers: covered_count[prem] += 1
      f. Add test to selected set
   3. Return selected tests

   k=1 produces the same result as select_minimal_tests (up to ordering).
   k=0 is not meaningful (use all seeds directly); callers should guard on k>0.

   Returns: list of (test_id, premises_covered) pairs *)
let select_k_cover_tests ~(k : int) (target_premises : int list)
    (_prem_to_tests : (int, string list) Hashtbl.t)
    (test_to_prems : (string, int list) Hashtbl.t) : (string * int list) list =
  (* covered_count.(prem) counts how many selected tests cover this premise *)
  let covered_count : (int, int) Hashtbl.t = Hashtbl.create 256 in
  List.iter (fun p -> Hashtbl.replace covered_count p 0) target_premises;

  (* Track which test ids are already selected (to avoid duplicates) *)
  let selected_set : (string, bool) Hashtbl.t = Hashtbl.create 256 in
  let selected = ref [] in

  (* Build a sorted candidate pool for deterministic tie-breaking *)
  let all_candidates =
    Hashtbl.fold (fun tid _ acc -> tid :: acc) test_to_prems []
    |> List.sort_uniq String.compare
  in

  let continue_loop = ref true in
  while !continue_loop do
    (* Find premises still under-covered (count < k) *)
    let under_covered =
      List.filter
        (fun p ->
          let cnt =
            Hashtbl.find_opt covered_count p |> Option.value ~default:0
          in
          cnt < k)
        target_premises
    in
    if under_covered = [] then continue_loop := false
    else
      (* Score each not-yet-selected candidate by how many under-covered
         premises it contributes *)
      let scored =
        List.filter_map
          (fun tid ->
            if Hashtbl.mem selected_set tid then None
            else
              let t_prems =
                Hashtbl.find_opt test_to_prems tid |> Option.value ~default:[]
              in
              let new_cov =
                List.length
                  (List.filter (fun p -> List.mem p under_covered) t_prems)
              in
              if new_cov = 0 then None
              else
                let priority = priority_of (classify_test_id tid) in
                Some (tid, (priority, -new_cov), t_prems))
          all_candidates
      in
      match List.sort (fun (_, s1, _) (_, s2, _) -> compare s1 s2) scored with
      | [] ->
          (* No candidate covers any under-covered premise — stop *)
          continue_loop := false
      | (best_tid, _, best_prems) :: _ ->
          Hashtbl.replace selected_set best_tid true;
          selected := (best_tid, best_prems) :: !selected;
          List.iter
            (fun p ->
              if Hashtbl.mem covered_count p then
                Hashtbl.replace covered_count p
                  (Hashtbl.find covered_count p + 1))
            best_prems
  done;

  List.rev !selected
