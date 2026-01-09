(** Ethereum CLI commands - Extends Targets_eth with CLI flags *)
open Targets_eth.Eth

(** CLI_TASK for Ethereum state transition *)
module StateTransition_Cli :
  Cli.Command.CLI_TASK with type input = StateTransition.input = struct
  include StateTransition

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and block =
      flag "--block" (optional_with_default "" string) ~doc:"FILE block JSON"
    in
    make ~pre_file:pre ~block_file:block ()
end

(* ========================================================================== *)
(* Operations                                                                 *)
(* ========================================================================== *)

(** CLI_TASK for ProposerSlashing *)
module ProposerSlashing_Cli :
  Cli.Command.CLI_TASK with type input = Operations.ProposerSlashing.input =
struct
  include Operations.ProposerSlashing

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and slashing =
      flag "--slashing"
        (optional_with_default "" string)
        ~doc:"FILE proposer slashing JSON"
    in
    make ~pre_file:pre ~proposer_slashing_file:slashing ()
end

(** CLI_TASK for AttesterSlashing *)
module AttesterSlashing_Cli :
  Cli.Command.CLI_TASK with type input = Operations.AttesterSlashing.input =
struct
  include Operations.AttesterSlashing

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and slashing =
      flag "--slashing"
        (optional_with_default "" string)
        ~doc:"FILE attester slashing JSON"
    in
    make ~pre_file:pre ~attester_slashing_file:slashing ()
end

(** CLI_TASK for Attestation *)
module Attestation_Cli :
  Cli.Command.CLI_TASK with type input = Operations.Attestation.input = struct
  include Operations.Attestation

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and attestation =
      flag "--attestation"
        (optional_with_default "" string)
        ~doc:"FILE attestation JSON"
    in
    make ~pre_file:pre ~attestation_file:attestation ()
end

(** CLI_TASK for Deposit *)
module Deposit_Cli :
  Cli.Command.CLI_TASK with type input = Operations.Deposit.input = struct
  include Operations.Deposit

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and deposit =
      flag "--deposit"
        (optional_with_default "" string)
        ~doc:"FILE deposit JSON"
    in
    make ~pre_file:pre ~deposit_file:deposit ()
end

(** CLI_TASK for VoluntaryExit *)
module VoluntaryExit_Cli :
  Cli.Command.CLI_TASK with type input = Operations.VoluntaryExit.input = struct
  include Operations.VoluntaryExit

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and exit =
      flag "--exit"
        (optional_with_default "" string)
        ~doc:"FILE voluntary exit JSON"
    in
    make ~pre_file:pre ~voluntary_exit_file:exit ()
end

(** CLI_TASK for BlsToExecutionChange *)
module BlsToExecutionChange_Cli :
  Cli.Command.CLI_TASK with type input = Operations.BlsToExecutionChange.input =
struct
  include Operations.BlsToExecutionChange

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and change =
      flag "--change"
        (optional_with_default "" string)
        ~doc:"FILE address change JSON"
    in
    make ~pre_file:pre ~address_change_file:change ()
end

(* Operation - Block processing *)

(** CLI_TASK for ExecutionPayload *)
module ExecutionPayload_Cli :
  Cli.Command.CLI_TASK with type input = Operations.ExecutionPayload.input =
struct
  include Operations.ExecutionPayload

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and payload =
      flag "--payload"
        (optional_with_default "" string)
        ~doc:"FILE execution payload JSON"
    and execution =
      flag "--execution" (optional string) ~doc:"FILE execution data JSON"
    in
    make ~pre_file:pre ~execution_payload_file:payload
      ?execution_data_file:execution ()
end

(** CLI_TASK for Withdrawals *)
module Withdrawals_Cli :
  Cli.Command.CLI_TASK with type input = Operations.Withdrawals.input = struct
  include Operations.Withdrawals

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and payload =
      flag "--payload"
        (optional_with_default "" string)
        ~doc:"FILE execution payload JSON"
    in
    make ~pre_file:pre ~execution_payload_file:payload ()
end

(** CLI_TASK for BlockHeader *)
module BlockHeader_Cli :
  Cli.Command.CLI_TASK with type input = Operations.BlockHeader.input = struct
  include Operations.BlockHeader

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and block =
      flag "--block" (optional_with_default "" string) ~doc:"FILE block JSON"
    in
    make ~pre_file:pre ~block_file:block ()
end

(** CLI_TASK for SyncAggregate *)
module SyncAggregate_Cli :
  Cli.Command.CLI_TASK with type input = Operations.SyncAggregate.input = struct
  include Operations.SyncAggregate

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and aggregate =
      flag "--aggregate"
        (optional_with_default "" string)
        ~doc:"FILE sync aggregate JSON"
    in
    make ~pre_file:pre ~sync_aggregate_file:aggregate ()
end

(* ========================================================================== *)
(* Epoch Processing                                                           *)
(* ========================================================================== *)

(** Helper signature for epoch tasks *)
module type EPOCH_TASK = sig
  include Runner.Task.S

  val make : ?expect:Runner.Task.expectation -> pre_file:string -> unit -> input
end

(** Helper functor for simple epoch CLI tasks *)
module Make_Epoch_Cli (T : EPOCH_TASK) = struct
  include T

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    in
    make ~pre_file:pre ()
end

(** CLI_TASK for JustificationAndFinalization *)
module JustificationAndFinalization_Cli =
  Make_Epoch_Cli (Epoch.JustificationAndFinalization)

(** CLI_TASK for InactivityUpdates *)
module InactivityUpdates_Cli = Make_Epoch_Cli (Epoch.InactivityUpdates)

(** CLI_TASK for RewardsAndPenalties *)
module RewardsAndPenalties_Cli = Make_Epoch_Cli (Epoch.RewardsAndPenalties)

(** CLI_TASK for RegistryUpdates *)
module RegistryUpdates_Cli = Make_Epoch_Cli (Epoch.RegistryUpdates)

(** CLI_TASK for Slashings *)
module Slashings_Cli = Make_Epoch_Cli (Epoch.Slashings)

(** CLI_TASK for Eth1DataReset *)
module Eth1DataReset_Cli = Make_Epoch_Cli (Epoch.Eth1DataReset)

(** CLI_TASK for EffectiveBalanceUpdates *)
module EffectiveBalanceUpdates_Cli =
  Make_Epoch_Cli (Epoch.EffectiveBalanceUpdates)

(** CLI_TASK for SlashingsReset *)
module SlashingsReset_Cli = Make_Epoch_Cli (Epoch.SlashingsReset)

(** CLI_TASK for RandaoMixesReset *)
module RandaoMixesReset_Cli = Make_Epoch_Cli (Epoch.RandaoMixesReset)

(** CLI_TASK for HistoricalSummariesUpdate *)
module HistoricalSummariesUpdate_Cli =
  Make_Epoch_Cli (Epoch.HistoricalSummariesUpdate)

(** CLI_TASK for ParticipationFlagUpdates *)
module ParticipationFlagUpdates_Cli =
  Make_Epoch_Cli (Epoch.ParticipationFlagUpdates)

(* ========================================================================== *)
(* Slots                                                                      *)
(* ========================================================================== *)

(** CLI_TASK for Slots *)
module Slots_Cli : Cli.Command.CLI_TASK with type input = Slots.input = struct
  include Slots

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre =
      flag "--pre" (optional_with_default "" string) ~doc:"FILE pre-state JSON"
    and slots =
      flag "--slots" (optional_with_default "" string) ~doc:"FILE slots YAML"
    in
    make ~pre_file:pre ~slots_file:slots ()
end

(* ========================================================================== *)
(* Commands                                                                   *)
(* ========================================================================== *)

let state_transition_command =
  Cli.Command.make ~summary:"Run Ethereum state transition"
    (module StateTransition_Cli)

let proposer_slashing_command =
  Cli.Command.make ~summary:"Process proposer slashing"
    (module ProposerSlashing_Cli)

let attester_slashing_command =
  Cli.Command.make ~summary:"Process attester slashing"
    (module AttesterSlashing_Cli)

let attestation_command =
  Cli.Command.make ~summary:"Process attestation" (module Attestation_Cli)

let deposit_command =
  Cli.Command.make ~summary:"Process deposit" (module Deposit_Cli)

let voluntary_exit_command =
  Cli.Command.make ~summary:"Process voluntary exit" (module VoluntaryExit_Cli)

let bls_to_execution_change_command =
  Cli.Command.make ~summary:"Process BLS to execution change"
    (module BlsToExecutionChange_Cli)

let execution_payload_command =
  Cli.Command.make ~summary:"Process execution payload"
    (module ExecutionPayload_Cli)

let withdrawals_command =
  Cli.Command.make ~summary:"Process withdrawals" (module Withdrawals_Cli)

let block_header_command =
  Cli.Command.make ~summary:"Process block header" (module BlockHeader_Cli)

let sync_aggregate_command =
  Cli.Command.make ~summary:"Process sync aggregate" (module SyncAggregate_Cli)

let justification_command =
  Cli.Command.make ~summary:"Process justification and finalization"
    (module JustificationAndFinalization_Cli)

let inactivity_updates_command =
  Cli.Command.make ~summary:"Process inactivity updates"
    (module InactivityUpdates_Cli)

let rewards_command =
  Cli.Command.make ~summary:"Process rewards and penalties"
    (module RewardsAndPenalties_Cli)

let registry_updates_command =
  Cli.Command.make ~summary:"Process registry updates"
    (module RegistryUpdates_Cli)

let slashings_command =
  Cli.Command.make ~summary:"Process slashings" (module Slashings_Cli)

let eth1_data_reset_command =
  Cli.Command.make ~summary:"Process eth1 data reset" (module Eth1DataReset_Cli)

let effective_balance_updates_command =
  Cli.Command.make ~summary:"Process effective balance updates"
    (module EffectiveBalanceUpdates_Cli)

let slashings_reset_command =
  Cli.Command.make ~summary:"Process slashings reset"
    (module SlashingsReset_Cli)

let randao_mixes_reset_command =
  Cli.Command.make ~summary:"Process randao mixes reset"
    (module RandaoMixesReset_Cli)

let historical_summaries_update_command =
  Cli.Command.make ~summary:"Process historical summaries update"
    (module HistoricalSummariesUpdate_Cli)

let participation_flag_updates_command =
  Cli.Command.make ~summary:"Process participation flag updates"
    (module ParticipationFlagUpdates_Cli)

let slots_command = Cli.Command.make ~summary:"Process slots" (module Slots_Cli)
