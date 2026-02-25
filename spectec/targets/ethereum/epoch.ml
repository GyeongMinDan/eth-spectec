(** Ethereum Epoch Processing Tasks *)

open Eth_common

let epoch_dir = "eth-tests/epoch_processing"

(* Collect epoch tests: only pre.json required *)
let collect_epoch_tests ~epoch_type ?dir () =
  let base_dir =
    Option.value dir ~default:(Filename.concat epoch_dir epoch_type)
  in
  let file_checker case_dir =
    let pre_file = Filename.concat case_dir "pre.json" in
    if file_exists pre_file then Some pre_file else None
  in
  collect_tests_from_dir ~base_dir ~file_checker ()

(* Helper functor for simple epoch tasks *)
module Make_Epoch_Task (M : sig
  val name : string
  val relation_name : string
  val format_msg : string
end) =
struct
  let name = M.name

  module Target = Target

  type input = { pre_file : string; expect : Runner.Task.expectation }

  let make ?(expect = Runner.Task.Positive) ~pre_file () = { pre_file; expect }

  let collect ?dir () =
    collect_epoch_tests ~epoch_type:M.name ?dir ()
    |> List.map (fun (pre_file, expect) -> { pre_file; expect })

  let parse_input ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    Ok (M.relation_name, [ beaconState_il ])

  let parse_string = parse_string
  let unparse = unparse
  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = M.format_msg
  let save_output _filename _values = ()
end

(* Tasks *)

module JustificationAndFinalization = Make_Epoch_Task (struct
  let name = "justification_and_finalization"
  let relation_name = "ProcessJustificationAndFinalization"
  let format_msg = "Justification and finalization processed"
end)

module InactivityUpdates = Make_Epoch_Task (struct
  let name = "inactivity_updates"
  let relation_name = "ProcessInactivityUpdates"
  let format_msg = "Inactivity updates processed"
end)

module RewardsAndPenalties = Make_Epoch_Task (struct
  let name = "rewards_and_penalties"
  let relation_name = "ProcessRewardsAndPenalties"
  let format_msg = "Rewards and penalties processed"
end)

module RegistryUpdates = Make_Epoch_Task (struct
  let name = "registry_updates"
  let relation_name = "ProcessRegistryUpdates"
  let format_msg = "Registry updates processed"
end)

module Slashings = Make_Epoch_Task (struct
  let name = "slashings"
  let relation_name = "ProcessSlashings"
  let format_msg = "Slashings processed"
end)

module Eth1DataReset = Make_Epoch_Task (struct
  let name = "eth1_data_reset"
  let relation_name = "ProcessEth1DataReset"
  let format_msg = "Eth1 data reset processed"
end)

module EffectiveBalanceUpdates = Make_Epoch_Task (struct
  let name = "effective_balance_updates"
  let relation_name = "ProcessEffectiveBalanceUpdates"
  let format_msg = "Effective balance updates processed"
end)

module SlashingsReset = Make_Epoch_Task (struct
  let name = "slashings_reset"
  let relation_name = "ProcessSlashingsReset"
  let format_msg = "Slashings reset processed"
end)

module RandaoMixesReset = Make_Epoch_Task (struct
  let name = "randao_mixes_reset"
  let relation_name = "ProcessRandaoMixesReset"
  let format_msg = "Randao mixes reset processed"
end)

module HistoricalSummariesUpdate = Make_Epoch_Task (struct
  let name = "historical_summaries_update"
  let relation_name = "ProcessHistoricalSummariesUpdate"
  let format_msg = "Historical summaries updated"
end)

module ParticipationFlagUpdates = Make_Epoch_Task (struct
  let name = "participation_flag_updates"
  let relation_name = "ProcessParticipationFlagUpdates"
  let format_msg = "Participation flag updates processed"
end)
