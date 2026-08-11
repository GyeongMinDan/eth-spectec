(** Ethereum Sanity Tasks *)

open Eth_common

let sanity_dir = "eth-tests/sanity"

(* Parse YAML file containing just a number (slots) *)
let parse_slots_yaml filename =
  let ic = open_in filename in
  let line = input_line ic in
  close_in ic;
  (* Strip whitespace and YAML document markers *)
  let clean = String.trim line in
  int_of_string clean

(* Collect sanity slots tests: pre.json + slots.yaml required *)
let collect_sanity_slots_tests ?dir () =
  let base_dir =
    match dir with
    | None -> Filename.concat sanity_dir "slots"
    | Some root ->
        let candidates =
          [ Filename.concat root "sanity/slots"; Filename.concat root "slots"; root ]
        in
        Option.value (List.find_opt dir_exists candidates) ~default:root
  in
  let file_checker case_dir =
    let pre_file = Filename.concat case_dir "pre.json" in
    let slots_file = Filename.concat case_dir "slots.yaml" in
    if file_exists pre_file && file_exists slots_file then
      Some (pre_file, slots_file)
    else None
  in
  collect_tests_from_dir ~base_dir ~file_checker ()

(* Parse 'slot' from pre.json (BeaconState) *)
let get_current_slot filename =
  let json = Yojson.Safe.from_file filename in
  let open Yojson.Safe.Util in
  match json |> member "slot" with
  | `String s -> Bigint.of_string s
  | `Int i -> Bigint.of_int i
  | `Intlit s -> Bigint.of_string s
  | _ -> failwith "Slot field has unexpected JSON type"

(* Slots task - ProcessSlots relation *)
module Slots = struct
  let name = "slots"

  module Target = Target

  type input = {
    pre_file : string;
    slots_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~slots_file () =
    { pre_file; slots_file; expect }

  let collect ?dir () =
    collect_sanity_slots_tests ?dir ()
    |> List.map (fun ((pre_file, slots_file), expect) ->
           { pre_file; slots_file; expect })

  let parse_input ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    (* Read slots delta from YAML *)
    let slots_delta = parse_slots_yaml input.slots_file in
    (* Read current slot from pre JSON *)
    let current_slot = get_current_slot input.pre_file in
    (* Compute target slot: pre.slot + slots_delta *)
    let target_slot = Bigint.(current_slot + of_int slots_delta) in
    let slots_il = Lang.Il.Value.nat target_slot in
    (* ProcessSlots(state, target_slot) *)
    Ok ("ProcessSlots", [ beaconState_il; slots_il ])

  let parse_string = parse_string
  let unparse = unparse
  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let check_output ~spec (input : input) values =
    check_beacon_state_output ~spec ~pre_file:input.pre_file values
  let format_output _values = "Sanity slots processed"
  let save_output _filename _values = ()
end
