(** Ethereum Target - Common utilities and shared functions *)

(* Paths are relative to the repo root (where the binary runs from) *)
let spec_dir = "spec/spec_capella"
let test_base_dir = "eth-tests"

(* Helper functions for file discovery *)
let dir_exists path = Sys.file_exists path && Sys.is_directory path
let file_exists path = Sys.file_exists path && not (Sys.is_directory path)

(* Ethereum target specification *)
module Target : Runner.Target.S = struct
  let name = "ethereum"
  let spec_dir = spec_dir
  let test_dir = test_base_dir
end

(* Shared JSON parsing function *)
let parse_json ~spec filename input_type =
  let ctx_init = Interp.Eval_Il.Ctx.empty filename in
  let ctx = Interp.Eval_Il.Interp.load_spec ctx_init spec in
  let json_data = Yojson.Safe.from_file filename in
  Interface.JSON.Parse.json_to_value
    (Interp.Eval_Il.Ctx.tdenv_to_map ctx)
    (Lang.Il.Typ.var input_type [])
    json_data
  |> Result.map_error (fun err ->
         let msg = Interface.JSON.Parse.string_of_error err in
         Runner.Error.JsonParseError (Common.Source.no_region, msg))

(* Expectation filter for collecting tests *)
type expectation_filter = All | PositiveOnly | NegativeOnly

(* Helper to collect tests from flat structure:
   base_dir/test_name/ where expectation is determined by file presence *)
let collect_tests_from_dir ~base_dir ~file_checker ?(filter = All) () =
  if not (dir_exists base_dir) then []
  else
    let subdirs =
      Sys.readdir base_dir |> Array.to_list
      |> List.filter (fun name -> dir_exists (Filename.concat base_dir name))
      |> List.sort String.compare
    in
    List.filter_map
      (fun name ->
        let case_dir = Filename.concat base_dir name in
        match file_checker case_dir with
        | Some files ->
            (* Determine expectation: post.json exists = Positive, error.txt exists = Negative *)
            let error_file = Filename.concat case_dir "error.txt" in
            let expect =
              if file_exists error_file then Runner.Task.Negative
              else Runner.Task.Positive
            in
            (* Apply filter *)
            let include_test =
              match filter with
              | All -> true
              | PositiveOnly -> expect = Runner.Task.Positive
              | NegativeOnly -> expect = Runner.Task.Negative
            in
            if include_test then Some (files, expect) else None
        | None -> None)
      subdirs

(* Helper to collect tests recursively:
   walks all subdirectories and returns any directory that passes file_checker. *)
let collect_tests_from_dir_recursive ~base_dir ~file_checker ?(filter = All) ()
    =
  let rec collect_dirs dir acc =
    let acc =
      match file_checker dir with
      | Some files ->
          let error_file = Filename.concat dir "error.txt" in
          let expect =
            if file_exists error_file then Runner.Task.Negative
            else Runner.Task.Positive
          in
          let include_test =
            match filter with
            | All -> true
            | PositiveOnly -> expect = Runner.Task.Positive
            | NegativeOnly -> expect = Runner.Task.Negative
          in
          if include_test then (files, expect) :: acc else acc
      | None -> acc
    in
    let subdirs =
      Sys.readdir dir |> Array.to_list
      |> List.map (Filename.concat dir)
      |> List.filter dir_exists
    in
    List.fold_left (fun acc sub -> collect_dirs sub acc) acc subdirs
  in
  if not (dir_exists base_dir) then [] else collect_dirs base_dir [] |> List.rev
