(** Ethereum Operation Tasks - Processing individual operations *)

open Eth_common
module Engine = Builtin_eth.Engine

let operations_dir = "eth-tests/operations"

(* Collect operation tests: pre.json + operation.json required *)
let collect_operation_tests ~op_type ~op_file_name ?dir () =
  let base_dir =
    Option.value dir ~default:(Filename.concat operations_dir op_type)
  in
  let file_checker case_dir =
    let pre_file = Filename.concat case_dir "pre.json" in
    let operation_file = Filename.concat case_dir op_file_name in
    if file_exists pre_file && file_exists operation_file then
      Some (pre_file, operation_file)
    else None
  in
  collect_tests_from_dir ~base_dir ~file_checker ()

(* ProposerSlashing task *)
module ProposerSlashing = struct
  let name = "proposer_slashing"

  module Target = Target

  type input = {
    pre_file : string;
    proposer_slashing_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~proposer_slashing_file ()
      =
    { pre_file; proposer_slashing_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"proposer_slashing"
      ~op_file_name:"proposer_slashing.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; proposer_slashing_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* slashing_il =
      parse_json ~spec input.proposer_slashing_file "proposerSlashing"
    in
    Ok ("ProcessProposerSlashing", [ beaconState_il; slashing_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Proposer slashing processed"
  let save_output _filename _values = ()
end

(* AttesterSlashing task *)
module AttesterSlashing = struct
  let name = "attester_slashing"

  module Target = Target

  type input = {
    pre_file : string;
    attester_slashing_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~attester_slashing_file ()
      =
    { pre_file; attester_slashing_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"attester_slashing"
      ~op_file_name:"attester_slashing.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; attester_slashing_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* slashing_il =
      parse_json ~spec input.attester_slashing_file "attesterSlashing"
    in
    Ok ("ProcessAttesterSlashing", [ beaconState_il; slashing_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Attester slashing processed"
  let save_output _filename _values = ()
end

(* Attestation task *)
module Attestation = struct
  let name = "attestation"

  module Target = Target

  type input = {
    pre_file : string;
    attestation_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~attestation_file () =
    { pre_file; attestation_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"attestation"
      ~op_file_name:"attestation.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; attestation_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* attestation_il =
      parse_json ~spec input.attestation_file "attestation"
    in
    Ok ("ProcessAttestation", [ beaconState_il; attestation_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Attestation processed"
  let save_output _filename _values = ()
end

(* Deposit task *)
module Deposit = struct
  let name = "deposit"

  module Target = Target

  type input = {
    pre_file : string;
    deposit_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~deposit_file () =
    { pre_file; deposit_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"deposit" ~op_file_name:"deposit.json" ?dir
      ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; deposit_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* deposit_il = parse_json ~spec input.deposit_file "deposit" in
    Ok ("ProcessDeposit", [ beaconState_il; deposit_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Deposit processed"
  let save_output _filename _values = ()
end

(* VoluntaryExit task *)
module VoluntaryExit = struct
  let name = "voluntary_exit"

  module Target = Target

  type input = {
    pre_file : string;
    voluntary_exit_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~voluntary_exit_file () =
    { pre_file; voluntary_exit_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"voluntary_exit"
      ~op_file_name:"voluntary_exit.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; voluntary_exit_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* exit_il =
      parse_json ~spec input.voluntary_exit_file "signedVoluntaryExit"
    in
    Ok ("ProcessVoluntaryExit", [ beaconState_il; exit_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Voluntary exit processed"
  let save_output _filename _values = ()
end

(* BlsToExecutionChange task *)
module BlsToExecutionChange = struct
  let name = "bls_to_execution_change"

  module Target = Target

  type input = {
    pre_file : string;
    address_change_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~address_change_file () =
    { pre_file; address_change_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"bls_to_execution_change"
      ~op_file_name:"bls_to_execution_change.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; address_change_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* change_il =
      parse_json ~spec input.address_change_file "signedBLSToExecutionChange"
    in
    Ok ("ProcessBlsToExecutionChange", [ beaconState_il; change_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "BLS to execution change processed"
  let save_output _filename _values = ()
end

(* === Block Processing === *)

(* Execution Payload task *)
module ExecutionPayload = struct
  let name = "execution_payload"

  module Target = Target

  type input = {
    pre_file : string;
    execution_payload_file : string;
    execution_data_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~execution_payload_file
      ?execution_data_file () =
    let execution_data_file =
      match execution_data_file with
      | Some f -> f
      | None -> Filename.concat (Filename.dirname pre_file) "execution.json"
    in
    { pre_file; execution_payload_file; execution_data_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"execution_payload"
      ~op_file_name:"execution_payload.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           let execution_data_file =
             Filename.concat (Filename.dirname pre_file) "execution.json"
           in
           {
             pre_file;
             execution_payload_file = operation_file;
             execution_data_file;
             expect;
           })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    if Sys.file_exists input.execution_data_file then
      try
        let json = Yojson.Safe.from_file input.execution_data_file in
        let valid =
          Yojson.Safe.Util.(member "execution_valid" json |> to_bool)
        in
        Engine.set_validity valid
      with _ -> Engine.set_validity true
    else Engine.set_validity true;
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* payload_il =
      parse_json ~spec input.execution_payload_file "beaconBlockBody"
    in
    Ok ("ProcessExecutionPayload", [ beaconState_il; payload_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Execution payload processed"
  let save_output _filename _values = ()
end

(* Withdrawals task *)
module Withdrawals = struct
  let name = "withdrawals"

  module Target = Target

  type input = {
    pre_file : string;
    execution_payload_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~execution_payload_file ()
      =
    { pre_file; execution_payload_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"withdrawals"
      ~op_file_name:"withdrawals.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; execution_payload_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* payload_il =
      parse_json ~spec input.execution_payload_file "executionPayload"
    in
    Ok ("ProcessWithdrawals", [ beaconState_il; payload_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Withdrawals processed"
  let save_output _filename _values = ()
end

(* BlockHeader task *)
module BlockHeader = struct
  let name = "block_header"

  module Target = Target

  type input = {
    pre_file : string;
    block_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~block_file () =
    { pre_file; block_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"block_header"
      ~op_file_name:"block_header.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; block_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* block_il = parse_json ~spec input.block_file "beaconBlock" in
    Ok ("ProcessBlockHeader", [ beaconState_il; block_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Block header processed"
  let save_output _filename _values = ()
end

(* SyncAggregate task *)
module SyncAggregate = struct
  let name = "sync_aggregate"

  module Target = Target

  type input = {
    pre_file : string;
    sync_aggregate_file : string;
    expect : Runner.Task.expectation;
  }

  let make ?(expect = Runner.Task.Positive) ~pre_file ~sync_aggregate_file () =
    { pre_file; sync_aggregate_file; expect }

  let collect ?dir () =
    collect_operation_tests ~op_type:"sync_aggregate"
      ~op_file_name:"sync_aggregate.json" ?dir ()
    |> List.map (fun ((pre_file, operation_file), expect) ->
           { pre_file; sync_aggregate_file = operation_file; expect })

  let parse ~spec (input : input) =
    let ( let* ) = Result.bind in
    let* beaconState_il = parse_json ~spec input.pre_file "beaconState" in
    let* aggregate_il =
      parse_json ~spec input.sync_aggregate_file "syncAggregate"
    in
    Ok ("ProcessSyncAggregate", [ beaconState_il; aggregate_il ])

  let source { pre_file; _ } = pre_file
  let expectation { expect; _ } = expect
  let format_output _values = "Sync aggregate processed"
  let save_output _filename _values = ()
end
