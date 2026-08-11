(** Ethereum Target - Common utilities and shared functions *)

open Lang

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
  let builtins = Builtin_eth.builtins
  let handler f = f ()
  let is_impure_func _ = false
  let is_impure_rel _ = false
  let state_version = ref 0
end

(* Build type definition environment from spec *)
let build_tdenv spec =
  List.fold_left
    (fun tdenv (def : Il.def) ->
      match def.it with
      | Il.TypD (id, tparams, deftyp) ->
          Envs.Il.TDEnv.add id (tparams, deftyp) tdenv
      | _ -> tdenv)
    Envs.Il.TDEnv.empty spec

(* Shared JSON parsing function *)
let parse_json ~spec filename input_type =
  let tdenv = build_tdenv spec in
  let json_data = Yojson.Safe.from_file filename in
  let provenance =
    match String.lowercase_ascii input_type with
    | "beaconstate" -> Some (Il.JsonState, [])
    | "signedbeaconblock" -> Some (Il.JsonBlock, [])
    | _ -> None
  in
  Interface.JSON.Parse.json_to_value ~provenance tdenv
    (Il.Typ.var input_type []) json_data
  |> Result.map_error (fun err ->
         let msg = Interface.JSON.Parse.string_of_error err in
         Runner.Error.TaskParseError (Common.Source.no_region, msg))

(* Shared parse_string: parse a JSON string given a type name.
   Requires the caller to provide type context via the spec. *)
let parse_string ~spec ~filename:_ content =
  let tdenv = build_tdenv spec in
  (* We need a type name to parse against — extract from JSON if possible,
     otherwise this is a stub for now *)
  let json = Yojson.Safe.from_string content in
  (* Try parsing as beaconState by default; callers should use parse_json
     directly when they know the type *)
  Interface.JSON.Parse.json_to_value
    ~provenance:(Some (Il.JsonState, []))
    tdenv
    (Il.Typ.var "beaconState" [])
    json
  |> Result.map (fun v -> [ v ])
  |> Result.map_error (fun err ->
         let msg = Interface.JSON.Parse.string_of_error err in
         Runner.Error.TaskParseError (Common.Source.no_region, msg))

let check_beacon_state_output ~spec ~pre_file values =
  let ( let* ) = Result.bind in
  let post_file = Filename.concat (Filename.dirname pre_file) "post.json" in
  if not (file_exists post_file) then
    Error
      (Runner.Error.OutputMismatchError
         ( Common.Source.no_region,
           Printf.sprintf "expected output file is missing: %s" post_file ))
  else
    let* expected =
      try parse_json ~spec post_file "beaconState"
      with exception_value ->
        Error
          (Runner.Error.OutputMismatchError
             ( Common.Source.no_region,
               Printf.sprintf "cannot read expected output %s: %s" post_file
                 (Printexc.to_string exception_value) ))
    in
    if Lang.Il.Eq.eq_values values [ expected ] then Ok ()
    else
      Error
        (Runner.Error.OutputMismatchError
           ( Common.Source.no_region,
             Printf.sprintf "interpreter output differs from %s" post_file ))

(* Shared unparse: convert IL values back to JSON string *)
let unparse ~spec:_ values =
  match values with
  | [ v ] -> (
      match Interface.JSON.Print.value_to_json v with
      | Ok json -> Yojson.Safe.pretty_to_string json
      | Error e ->
          "<json print error: " ^ Interface.JSON.Print.string_of_error e ^ ">")
  | _ -> "<multiple values>"

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

(* JsonParse task - minimal task for the parse command *)
module JsonParse = struct
  let name = "json_parse"

  module Target = Target

  type input = {
    json_file : string;
    input_type : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~json_file ~input_type () =
    { json_file; input_type; expect }

  let parse_input ~spec input =
    let ( let* ) = Result.bind in
    let* value = parse_json ~spec input.json_file input.input_type in
    Ok ("", [ value ])

  let parse_string = parse_string
  let unparse = unparse
  let source { json_file; _ } = json_file
  let expectation { expect; _ } = expect
  let check_output = Runner.Task.accept_output
  let collect ?dir:_ () = []
  let format_output values = unparse ~spec:[] values
  let save_output _filename _values = ()
end
