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
  collect_tests_from_dir_recursive ~base_dir ~file_checker ()

(* Module-level override for validate_result (used by coverage command) *)
let default_validate_result = ref true
let set_default_validate_result v = default_validate_result := v

(* State Transition task - full block processing *)
module StateTransition = struct
  let name = "state_transition"

  module Target = Target

  type input = {
    pre_file : string;
    block_file : string;
    expect : Runner.Task.expectation;
    validate_result : bool;
  }

  let make ?(expect = Runner.Task.Positive) ?validate_result ~pre_file
      ~block_file () =
    let validate_result =
      match validate_result with
      | Some v -> v
      | None -> !default_validate_result
    in
    { pre_file; block_file; expect; validate_result }

  let collect ?dir () =
    let root = Option.value dir ~default:test_base_dir in
    let categories = [ "finality"; "sanity/blocks"; "random" ] in
    let existing_categories =
      List.filter (fun sub -> dir_exists (Filename.concat root sub)) categories
    in
    let missing_categories =
      List.filter
        (fun sub -> not (dir_exists (Filename.concat root sub)))
        categories
    in
    if missing_categories <> [] then
      Format.printf
        "Note: Expected subdirectories not found under %s: %s\n\
         (will use %s)\n\
         %!"
        root
        (String.concat ", " missing_categories)
        (if existing_categories <> [] then "found categories"
         else "recursive fallback scan");
    let collected =
      if existing_categories <> [] then
        List.concat_map
          (fun sub ->
            let sub_dir = Filename.concat root sub in
            collect_block_tests ~dir:sub_dir ())
          existing_categories
      else
        (* Fallback: recursively scan the root for any pre.json/block.json pairs *)
        collect_block_tests ~dir:root ()
    in
    if collected = [] then
      Format.printf
        "WARNING: No test cases found under %s. Verify directory structure.\n%!"
        root;
    collected
    |> List.map (fun ((pre_file, block_file), expect) ->
           {
             pre_file;
             block_file;
             expect;
             validate_result = !default_validate_result;
           })

  let parse_input ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* block_il = parse_json ~spec input.block_file "signedBeaconBlock" in
    Ok
      ( "State_transition",
        [ beaconState_il; block_il; Lang.Il.Value.bool input.validate_result ]
      )

  let parse_string = parse_string
  let unparse = unparse
  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "State transition succeeded"
  let save_output _filename _values = ()
end
