open Ssz_schema

let uint8 = Uint 1
let uint64 = Uint 8
let uint256 = Uint 32
let bytes4 = Byte_vector 4
let bytes20 = Byte_vector 20
let bytes32 = Byte_vector 32
let bytes48 = Byte_vector 48
let bytes96 = Byte_vector 96
let bytes256 = Byte_vector 256
let root = bytes32

let transaction = Byte_list 1_073_741_824
let transactions = List (transaction, 1_048_576)
let roots length = Vector (root, length)

let beacon_block_header =
  Container
    [
      field "SLOT" uint64;
      field "PROPOSER_INDEX" uint64;
      field "PARENT_ROOT" root;
      field "STATE_ROOT" root;
      field "BODY_ROOT" root;
    ]

let deposit_data =
  Container
    [
      field "PUBKEY" bytes48;
      field "WITHDRAWAL_CREDENTIALS" bytes32;
      field "AMOUNT" uint64;
      field "SIGNATURE" bytes96;
    ]

let fork_data =
  Container
    [ field "CURRENT_VERSION" bytes4; field "GENESIS_VALIDATORS_ROOT" root ]

let withdrawal =
  Container
    [
      field "INDEX" uint64;
      field "VALIDATOR_INDEX" uint64;
      field "ADDRESS" bytes20;
      field "AMOUNT" uint64;
    ]

let withdrawals = List (withdrawal, 16)

let eth1_data =
  Container
    [
      field "DEPOSIT_ROOT" root;
      field "DEPOSIT_COUNT" uint64;
      field "BLOCK_HASH" bytes32;
    ]

let execution_payload_common =
  [
    field "PARENT_HASH" bytes32;
    field "FEE_RECIPIENT" bytes20;
    field "STATE_ROOT" bytes32;
    field "RECEIPTS_ROOT" bytes32;
    field "LOGS_BLOOM" bytes256;
    field "PREV_RANDAO" bytes32;
    field "BLOCK_NUMBER" uint64;
    field "GAS_LIMIT" uint64;
    field "GAS_USED" uint64;
    field "TIMESTAMP" uint64;
    field "EXTRA_DATA" (Byte_list 32);
    field "BASE_FEE_PER_GAS" uint256;
    field "BLOCK_HASH" bytes32;
    field "TRANSACTIONS" transactions;
    field "WITHDRAWALS" withdrawals;
  ]

let execution_payload =
  Container_variants
    [
      execution_payload_common;
      execution_payload_common
      @ [ field "BLOB_GAS_USED" uint64; field "EXCESS_BLOB_GAS" uint64 ];
    ]

let bls_to_execution_change =
  Container
    [
      field "VALIDATOR_INDEX" uint64;
      field "FROM_BLS_PUBKEY" bytes48;
      field "TO_EXECUTION_ADDRESS" bytes20;
    ]

let signed_bls_to_execution_change =
  Container
    [
      field "MESSAGE" bls_to_execution_change;
      field "SIGNATURE" bytes96;
    ]

let sync_aggregate =
  Container
    [
      field "SYNC_COMMITTEE_BITS" (Bit_vector 512);
      field "SYNC_COMMITTEE_SIGNATURE" bytes96;
    ]

let voluntary_exit =
  Container [ field "EPOCH" uint64; field "VALIDATOR_INDEX" uint64 ]

let signed_voluntary_exit =
  Container
    [ field "MESSAGE" voluntary_exit; field "SIGNATURE" bytes96 ]

let deposit =
  Container
    [ field "PROOF" (Vector (root, 33)); field "DATA" deposit_data ]

let checkpoint =
  Container [ field "EPOCH" uint64; field "ROOT" root ]

let attestation_data =
  Container
    [
      field "SLOT" uint64;
      field "INDEX" uint64;
      field "BEACON_BLOCK_ROOT" root;
      field "SOURCE" checkpoint;
      field "TARGET" checkpoint;
    ]

let attestation =
  Container
    [
      field "AGGREGATION_BITS" (Bit_list 2_048);
      field "DATA" attestation_data;
      field "SIGNATURE" bytes96;
    ]

let indexed_attestation =
  Container
    [
      field "ATTESTING_INDICES" (List (uint64, 2_048));
      field "DATA" attestation_data;
      field "SIGNATURE" bytes96;
    ]

let attester_slashing =
  Container
    [
      field "ATTESTATION_1" indexed_attestation;
      field "ATTESTATION_2" indexed_attestation;
    ]

let signed_beacon_block_header =
  Container
    [ field "MESSAGE" beacon_block_header; field "SIGNATURE" bytes96 ]

let proposer_slashing =
  Container
    [
      field "SIGNED_HEADER_1" signed_beacon_block_header;
      field "SIGNED_HEADER_2" signed_beacon_block_header;
    ]

let fork =
  Container
    [
      field "PREVIOUS_VERSION" bytes4;
      field "CURRENT_VERSION" bytes4;
      field "EPOCH" uint64;
    ]

let validator =
  Container
    [
      field "PUBKEY" bytes48;
      field "WITHDRAWAL_CREDENTIALS" bytes32;
      field "EFFECTIVE_BALANCE" uint64;
      field "SLASHED" Bool;
      field "ACTIVATION_ELIGIBILITY_EPOCH" uint64;
      field "ACTIVATION_EPOCH" uint64;
      field "EXIT_EPOCH" uint64;
      field "WITHDRAWABLE_EPOCH" uint64;
    ]

let sync_committee =
  Container
    [
      field "PUBKEYS" (Vector (bytes48, 512));
      field "AGGREGATE_PUBKEY" bytes48;
    ]

let execution_payload_header_common =
  [
    field "PARENT_HASH" bytes32;
    field "FEE_RECIPIENT" bytes20;
    field "STATE_ROOT" bytes32;
    field "RECEIPTS_ROOT" bytes32;
    field "LOGS_BLOOM" bytes256;
    field "PREV_RANDAO" bytes32;
    field "BLOCK_NUMBER" uint64;
    field "GAS_LIMIT" uint64;
    field "GAS_USED" uint64;
    field "TIMESTAMP" uint64;
    field "EXTRA_DATA" (Byte_list 32);
    field "BASE_FEE_PER_GAS" uint256;
    field "BLOCK_HASH" bytes32;
    field "TRANSACTIONS_ROOT" root;
    field "WITHDRAWALS_ROOT" root;
  ]

let execution_payload_header =
  Container_variants
    [
      execution_payload_header_common;
      execution_payload_header_common
      @ [ field "BLOB_GAS_USED" uint64; field "EXCESS_BLOB_GAS" uint64 ];
    ]

let historical_summary =
  Container
    [ field "BLOCK_SUMMARY_ROOT" root; field "STATE_SUMMARY_ROOT" root ]

let beacon_block_body_common =
  [
    field "RANDAO_REVEAL" bytes96;
    field "ETH1_DATA" eth1_data;
    field "GRAFFITI" bytes32;
    field "PROPOSER_SLASHINGS" (List (proposer_slashing, 16));
    field "ATTESTER_SLASHINGS" (List (attester_slashing, 2));
    field "ATTESTATIONS" (List (attestation, 128));
    field "DEPOSITS" (List (deposit, 16));
    field "VOLUNTARY_EXITS" (List (signed_voluntary_exit, 16));
    field "SYNC_AGGREGATE" sync_aggregate;
    field "EXECUTION_PAYLOAD" execution_payload;
    field "BLS_TO_EXECUTION_CHANGES"
      (List (signed_bls_to_execution_change, 16));
  ]

let beacon_block_body =
  Container_variants
    [
      beacon_block_body_common;
      beacon_block_body_common
      @ [ field "BLOB_KZG_COMMITMENTS" (List (bytes48, 4_096)) ];
    ]

let beacon_state =
  Container
    [
      field "GENESIS_TIME" uint64;
      field "GENESIS_VALIDATORS_ROOT" bytes32;
      field "SLOT" uint64;
      field "FORK" fork;
      field "LATEST_BLOCK_HEADER" beacon_block_header;
      field "BLOCK_ROOTS" (Vector (root, 8_192));
      field "STATE_ROOTS" (Vector (root, 8_192));
      field "HISTORICAL_ROOTS" (List (root, 16_777_216));
      field "ETH1_DATA" eth1_data;
      field "ETH1_DATA_VOTES" (List (eth1_data, 2_048));
      field "ETH1_DEPOSIT_INDEX" uint64;
      field "VALIDATORS" (List (validator, 1_099_511_627_776));
      field "BALANCES" (List (uint64, 1_099_511_627_776));
      field "RANDAO_MIXES" (Vector (bytes32, 65_536));
      field "SLASHINGS" (Vector (uint64, 8_192));
      field "PREVIOUS_EPOCH_PARTICIPATION"
        (List (uint8, 1_099_511_627_776));
      field "CURRENT_EPOCH_PARTICIPATION"
        (List (uint8, 1_099_511_627_776));
      field "JUSTIFICATION_BITS" (Bit_vector 4);
      field "PREVIOUS_JUSTIFIED_CHECKPOINT" checkpoint;
      field "CURRENT_JUSTIFIED_CHECKPOINT" checkpoint;
      field "FINALIZED_CHECKPOINT" checkpoint;
      field "INACTIVITY_SCORES" (List (uint64, 1_099_511_627_776));
      field "CURRENT_SYNC_COMMITTEE" sync_committee;
      field "NEXT_SYNC_COMMITTEE" sync_committee;
      field "LATEST_EXECUTION_PAYLOAD_HEADER" execution_payload_header;
      field "NEXT_WITHDRAWAL_INDEX" uint64;
      field "NEXT_WITHDRAWAL_VALIDATOR_INDEX" uint64;
      field "HISTORICAL_SUMMARIES" (List (historical_summary, 16_777_216));
    ]

let deposit_message =
  Container
    [
      field "PUBKEY" bytes48;
      field "WITHDRAWAL_CREDENTIALS" bytes32;
      field "AMOUNT" uint64;
    ]

let beacon_block =
  Container
    [
      field "SLOT" uint64;
      field "PROPOSER_INDEX" uint64;
      field "PARENT_ROOT" root;
      field "STATE_ROOT" root;
      field "BODY" beacon_block_body;
    ]
