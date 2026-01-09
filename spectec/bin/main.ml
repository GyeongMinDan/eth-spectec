open Runner

let version = "0.1"

let print_json ?output_file value_il =
  let json = Interface.JSON.Print.value_to_json value_il in
  match json with
  | Ok json -> (
      let json_string = Yojson.Safe.pretty_to_string json in
      match output_file with
      | Some filename ->
          let oc = open_out filename in
          output_string oc json_string;
          output_string oc "\n";
          close_out oc;
          Format.printf "JSON saved to: %s\n" filename
      | None -> print_endline json_string)
  | Error err ->
      Format.printf "JSON printing failed : %s"
        (Interface.JSON.Print.string_of_error err)

(* Commands *)

let elab_command =
  Core.Command.basic ~summary:"parse and elaborate a spec"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames = anon (sequence ("spec files" %: string)) in
     fun () ->
       let elaborate_result =
         let* spec = parse_spec_files filenames in
         let* spec_il = elaborate spec in
         Ok spec_il
       in
       match elaborate_result with
       | Ok spec_il ->
           Format.printf "%s\n" (Lang.Il.Print.string_of_spec spec_il)
       | Error e -> Format.printf "%s\n" (Runner.Error.string_of_error e))

let structure_command =
  Core.Command.basic ~summary:"structure a spec"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames = anon (sequence ("spec files" %: string)) in
     fun () ->
       let structure_result =
         let* spec = parse_spec_files filenames in
         let* spec_il = elaborate spec in
         let spec_sl = structure spec_il in
         Ok spec_sl
       in
       match structure_result with
       | Ok spec_sl ->
           Format.printf "%s\n" (Lang.Sl.Print.string_of_spec spec_sl)
       | Error e -> Format.printf "%s\n" (Runner.Error.string_of_error e))

let parse_json_command =
  Core.Command.basic ~summary:"parse a JSON into IL value"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map spec_files = anon (sequence ("spec files" %: string))
     (* and includes_target = flag "-i" (listed string) ~doc:"target include paths" *)
     and filename_target =
       flag "-p" (required string) ~doc:"target file to parse"
     and input_type = flag "-t" (required string) ~doc:"type of input JSON"
     and output_file =
       flag "-o" (optional string) ~doc:"output JSON file (default: stdout)"
     in
     fun () ->
       let spec = List.concat_map Frontend.Parse.parse_file spec_files in
       let parse_result =
         let* spec_il = elaborate spec in
         let* value_il = parse_json filename_target input_type spec_il in
         Ok (spec_il, value_il)
       in
       match parse_result with
       | Ok (_, value_il) -> print_json ?output_file value_il
       | Error e ->
           Format.printf "JSON parse failed:\n  %s\n"
             (Runner.Error.string_of_error e))

let p4parse_command =
  Core.Command.basic ~summary:"parse a P4 program"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames = anon (sequence ("spec files" %: string))
     and includes_target = flag "-i" (listed string) ~doc:"p4 include paths"
     and filename_target = flag "-p" (required string) ~doc:"p4 file to parse"
     and roundtrip =
       flag "-r" no_arg ~doc:"perform a round-trip parse/unparse"
     in
     fun () ->
       let do_roundtrip () =
         let* rountrip_result =
           Runner.parse_p4_file_with_roundtrip roundtrip filenames
             includes_target filename_target
         in
         Ok rountrip_result
       in
       match (roundtrip, Runner.Handlers.il do_roundtrip) with
       | false, Ok unparsed_string ->
           Format.printf "Parse succeeded:\n%s\n" unparsed_string
       | true, Ok unparsed_string ->
           Format.printf "Roundtrip succeeded:\n%s\n" unparsed_string
       | false, Error e ->
           Format.printf "Parse failed:\n  %s\n"
             (Runner.Error.string_of_error e)
       | true, Error e ->
           Format.printf "Roundtrip failed:\n  %s\n"
             (Runner.Error.string_of_error e))

(* Instantiate CLI commands for P4 *)
module P4_Cmd = Cli.Command.Make (Targets_p4.P4.Target)

let p4_command =
  let tasks = [ P4_Cmd.Pack (module Targets_p4.P4.Typecheck) ] in
  Core.Command.group ~summary:"P4 commands"
    [
      ("typecheck", Targets.P4.command); ("coverage", P4_Cmd.make_coverage tasks);
    ]

(* Instantiate CLI commands for Ethereum *)
module Eth_Cmd = Cli.Command.Make (Targets_eth.Eth.Target)

let eth_command =
  let tasks =
    [
      (* Operations *)
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.ProposerSlashing);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.AttesterSlashing);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.Attestation);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.Deposit);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.VoluntaryExit);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.BlsToExecutionChange);
      (* Operations - Block processing *)
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.ExecutionPayload);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.Withdrawals);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.BlockHeader);
      Eth_Cmd.Pack (module Targets_eth.Eth.Operations.SyncAggregate);
      (* Epoch processing *)
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.JustificationAndFinalization);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.InactivityUpdates);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.RewardsAndPenalties);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.RegistryUpdates);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.Slashings);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.Eth1DataReset);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.EffectiveBalanceUpdates);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.SlashingsReset);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.RandaoMixesReset);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.HistoricalSummariesUpdate);
      Eth_Cmd.Pack (module Targets_eth.Eth.Epoch.ParticipationFlagUpdates);
      (* Slots and State transition *)
      Eth_Cmd.Pack (module Targets_eth.Eth.Slots);
      Eth_Cmd.Pack (module Targets_eth.Eth.StateTransition);
    ]
  in
  (* Nested command groups for better organization *)
  let epoch_commands =
    Core.Command.group ~summary:"Epoch processing tasks"
      [
        ("justification", Targets.Eth.justification_command);
        ("inactivity-updates", Targets.Eth.inactivity_updates_command);
        ("rewards", Targets.Eth.rewards_command);
        ("registry-updates", Targets.Eth.registry_updates_command);
        ("slashings", Targets.Eth.slashings_command);
        ("eth1-data-reset", Targets.Eth.eth1_data_reset_command);
        ( "effective-balance-updates",
          Targets.Eth.effective_balance_updates_command );
        ("slashings-reset", Targets.Eth.slashings_reset_command);
        ("randao-mixes-reset", Targets.Eth.randao_mixes_reset_command);
        ( "historical-summaries-update",
          Targets.Eth.historical_summaries_update_command );
        ( "participation-flag-updates",
          Targets.Eth.participation_flag_updates_command );
      ]
  in
  let operations_commands =
    Core.Command.group ~summary:"Operation/Block processing tasks"
      [
        ("proposer-slashing", Targets.Eth.proposer_slashing_command);
        ("attester-slashing", Targets.Eth.attester_slashing_command);
        ("attestation", Targets.Eth.attestation_command);
        ("deposit", Targets.Eth.deposit_command);
        ("voluntary-exit", Targets.Eth.voluntary_exit_command);
        ("bls-to-execution-change", Targets.Eth.bls_to_execution_change_command);
        (* Block processing *)
        ("execution-payload", Targets.Eth.execution_payload_command);
        ("withdrawals", Targets.Eth.withdrawals_command);
        ("block-header", Targets.Eth.block_header_command);
        ("sync-aggregate", Targets.Eth.sync_aggregate_command);
      ]
  in
  let run_command =
    Core.Command.group ~summary:"Run ethereum test tasks"
      [
        ("epoch", epoch_commands);
        ("operations", operations_commands);
        ("slots", Targets.Eth.slots_command);
        ("state-transition", Targets.Eth.state_transition_command);
      ]
  in
  Core.Command.group ~summary:"Ethereum commands"
    [ ("run", run_command); ("coverage", Eth_Cmd.make_coverage tasks) ]

let command =
  Core.Command.group ~summary:"SpecTec command line tools"
    [
      ("elab", elab_command);
      ("struct", structure_command);
      ("p4parse", p4parse_command);
      ("parse-json", parse_json_command);
      ("p4", p4_command);
      ("eth", eth_command);
    ]

let () = Command_unix.run ~version command
