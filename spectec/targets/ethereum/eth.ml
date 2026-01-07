(** Ethereum Target - Implements TARGET and TASK for Ethereum state transitions
*)

(* Paths are relative to the repo root (where the binary runs from) *)
let spec_dir = "spec/spec_capella"
let test_base_dir = "eth-tests-all"

(* Helper functions for file discovery *)
let dir_exists path = Sys.file_exists path && Sys.is_directory path
let file_exists path = Sys.file_exists path && not (Sys.is_directory path)

(* Ethereum target specification *)
module Target : Runner.Target.S = struct
  let name = "ethereum"
  let spec_dir = spec_dir
  let test_dir = test_base_dir
end

(* Ethereum State Transition task - extends TASK for running state_transition *)
module StateTransition = struct
  let name = "state_transition"

  module Target = Target

  type input = {
    pre_file : string;
    block_file : string;
    expect : Runner.Task.expectation;
  }

  (* Create an input with optional expectation *)
  let make ?(expect = Runner.Task.Positive) ~pre_file ~block_file () =
    { pre_file; block_file; expect }

  (* Collect inputs from directory, uses Target.test_dir if not specified.
     Expects positive/ and negative/ subdirectories, each containing test case folders
     with pre.json and block.json files. *)
  let collect ?dir () =
    let test_dir = Option.value dir ~default:Target.test_dir in
    let positive_dir = Filename.concat test_dir "positive" in
    let negative_dir = Filename.concat test_dir "negative" in
    let collect_from_dir is_positive subdir =
      if not (dir_exists subdir) then []
      else
        let subdirs =
          Sys.readdir subdir |> Array.to_list
          |> List.filter (fun name -> dir_exists (Filename.concat subdir name))
          |> List.sort String.compare
        in
        List.filter_map
          (fun name ->
            let case_dir = Filename.concat subdir name in
            let pre_file = Filename.concat case_dir "pre.json" in
            let block_file = Filename.concat case_dir "block.json" in
            if file_exists pre_file && file_exists block_file then
              let expect =
                if is_positive then Runner.Task.Positive
                else Runner.Task.Negative
              in
              Some { pre_file; block_file; expect }
            else None)
          subdirs
    in
    let positive_tests = collect_from_dir true positive_dir in
    let negative_tests = collect_from_dir false negative_dir in
    positive_tests @ negative_tests

  (* Parse JSON files and return relation name + values for State_transition *)
  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let parse_json filename input_type =
      let ctx_init = Interp.Eval_Il.Ctx.empty filename in
      let ctx = Interp.Eval_Il.Interp.load_spec ctx_init spec in
      let json_data = Yojson.Safe.from_file filename in
      Interface.JSON.Parse.json_to_value ctx.global.tdenv
        (Lang.Il.Typ.var input_type [])
        json_data
      |> Result.map_error (fun err ->
             let msg = Interface.JSON.Parse.string_of_error err in
             Runner.Error.JsonParseError (Common.Source.no_region, msg))
    in
    let* beaconState_il = parse_json input.pre_file "beaconState" in
    let* block_il = parse_json input.block_file "signedBeaconBlock" in
    Ok
      ("State_transition", [ beaconState_il; block_il; Lang.Il.Value.bool true ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "State transition succeeded"
  let save_output _filename _values = ()
end
