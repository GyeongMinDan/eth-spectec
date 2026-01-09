(** Ethereum State Transition Task *)

open Eth_common

(* Collect block tests: pre.json + block.json required *)
let collect_block_tests ?dir () =
  let base_dir = Option.value dir ~default:test_base_dir in
  let file_checker case_dir =
    let pre_file = Filename.concat case_dir "pre.json" in
    let block_file = Filename.concat case_dir "block.json" in
    if file_exists pre_file && file_exists block_file then
      Some (pre_file, block_file)
    else None
  in
  collect_tests_from_dir ~base_dir ~file_checker ()

(* State Transition task - full block processing *)
module StateTransition = struct
  let name = "state_transition"

  module Target = Target

  type input = {
    pre_file : string;
    block_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~block_file () =
    { pre_file; block_file; expect }

  let collect ?dir () =
    let root = Option.value dir ~default:test_base_dir in
    let categories = [ "finality"; "sanity/blocks"; "random" ] in
    List.concat_map
      (fun sub ->
        let sub_dir = Filename.concat root sub in
        if dir_exists sub_dir then collect_block_tests ~dir:sub_dir () else [])
      categories
    |> List.map (fun ((pre_file, block_file), expect) ->
           { pre_file; block_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* block_il = parse_json ~spec input.block_file "signedBeaconBlock" in
    Ok
      ("State_transition", [ beaconState_il; block_il; Lang.Il.Value.bool true ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "State transition succeeded"
  let save_output _filename _values = ()
end
