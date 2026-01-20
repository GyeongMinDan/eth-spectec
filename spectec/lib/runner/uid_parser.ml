(* Parse premise UID files for test generation.

   UID files format:
   - One UID per line
   - Lines starting with # are comments
   - Empty lines are ignored
*)

(* Parse a file containing premise UIDs *)
let parse_uid_file (filename : string) : int list =
  let channel = open_in filename in
  let rec read_lines acc =
    match input_line channel with
    | line -> (
        let trimmed = String.trim line in
        if String.length trimmed = 0 || String.get trimmed 0 = '#' then
          read_lines acc
        else
          match int_of_string_opt trimmed with
          | Some uid -> read_lines (uid :: acc)
          | None ->
              Printf.eprintf "Warning: invalid UID '%s', skipping\n" trimmed;
              read_lines acc)
    | exception End_of_file ->
        close_in channel;
        List.rev acc
  in
  read_lines []

(* Validate UIDs against coverage data, returning only valid ones *)
let validate_uids (uids : int list)
    (coverage : Instrumentation.Node_coverage_il.result option) :
    (int * (Common.Source.region * string)) list =
  match coverage with
  | None -> []
  | Some cov ->
      let uid_to_key =
        List.fold_left
          (fun acc (uid, key) -> (uid, key) :: acc)
          [] cov.uid_to_prem
        |> List.to_seq |> Hashtbl.of_seq
      in
      List.filter_map
        (fun uid ->
          match Hashtbl.find_opt uid_to_key uid with
          | Some key -> Some (uid, key)
          | None ->
              Printf.eprintf "Warning: UID %d not found in coverage data\n" uid;
              None)
        uids
