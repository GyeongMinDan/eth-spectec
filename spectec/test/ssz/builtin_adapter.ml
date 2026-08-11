module Il = Lang.Il
module Value = Il.Value
module Merkle = Ethereum_ssz.Ssz_merkle
module Schema = Ethereum_ssz.Ssz_schema
module Ethereum = Ethereum_ssz.Ethereum_schema

(* These fixed roots share the independently generated reference vectors from
   [hash_tree_root.ml]; this test concentrates on the public builtin ABI. *)
let hex_of_bytes bytes =
  let buffer = Buffer.create (Bytes.length bytes * 2) in
  Bytes.iter
    (fun byte -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents buffer

let find_builtin name =
  match List.assoc_opt name Builtin_eth.builtins with
  | Some builtin -> builtin
  | None -> failwith (Printf.sprintf "missing builtin %s" name)

let call_builtin name arguments =
  let builtin = find_builtin name in
  match builtin ~at:Common.Source.no_region [] arguments with
  | Ok value -> value
  | Error _ -> failwith (Printf.sprintf "builtin %s returned an error" name)

let check_builtin_rejected name arguments =
  let builtin = find_builtin name in
  match builtin ~at:Common.Source.no_region [] arguments with
  | Error _ -> ()
  | Ok _ -> failwith (Printf.sprintf "builtin %s should have rejected input" name)

let check_root name expected value =
  let num, len = Value.get_bytes value in
  if len <> 32 then
    failwith (Printf.sprintf "%s: expected a 32-byte result, got %d" name len);
  let actual = Merkle.be_of_bigint_fixed num ~len in
  let actual = hex_of_bytes actual in
  if not (String.equal expected actual) then
    failwith (Printf.sprintf "%s: expected %s, got %s" name expected actual)

let nat value = Value.nat (Bigint.of_int value)
let byte_list values = Value.list' (Il.NumT `NatT) (List.map nat values)

type fork = Capella | Deneb

let rec zero_value fork = function
  | Schema.Bool -> Value.bool false
  | Schema.Uint _ -> nat 0
  | Schema.Byte_vector length -> Value.make_bytes ~num:Bigint.zero ~len:length
  | Schema.Byte_list _ -> Value.make_bytes ~num:Bigint.zero ~len:0
  | Schema.Bit_vector length ->
      Value.list' (Il.NumT `NatT)
        (List.init length (Fun.const (Value.bool false)))
  | Schema.Bit_list _ | Schema.List _ -> Value.list' (Il.NumT `NatT) []
  | Schema.Vector (element, length) ->
      Value.list' (Il.NumT `NatT)
        (List.init length (Fun.const (zero_value fork element)))
  | Schema.Container fields ->
      Value.tuple
        (List.map (fun field -> zero_value fork field.Schema.schema) fields)
  | Schema.Container_variants variants ->
      let index = match fork with Capella -> 0 | Deneb -> 1 in
      let fields = List.nth variants index in
      Value.tuple
        (List.map (fun field -> zero_value fork field.Schema.schema) fields)

let check_builtin_zero_root name expected fork schema =
  check_root name expected (call_builtin name [ zero_value fork schema ])

let schema_builtins =
  [
    ( "hash_tree_root_beaconBlockHeader",
      Ethereum.beacon_block_header,
      "c78009fdf07fc56a11f122370658a353aaa542ed63e44c4bc15ff4cd105ab33c" );
    ( "hash_tree_root_depositData",
      Ethereum.deposit_data,
      "7d3bfa54172d8642a6c081084ce35542555a2998f48c5c9cd17f2d7a0754f3eb" );
    ( "hash_tree_root_forkdata",
      Ethereum.fork_data,
      "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b" );
    ( "hash_tree_root_eth1Data",
      Ethereum.eth1_data,
      "db56114e00fdd4c1f85c892bf35ac9a89289aaecb1ebd0a96cde606a748b5d71" );
    ( "hash_tree_root_executionPayload",
      Ethereum.execution_payload,
      "71fc711580d19a351698dab1391666d849e0609aea020965156b5e8d8c83a2e7" );
    ( "hash_tree_root_BLSToExecutionChange",
      Ethereum.bls_to_execution_change,
      "bad1ebffe915f474f39873c538915f5cb1b246dfc5dc98eed668aac9292f1351" );
    ( "hash_tree_root_SignedBLSToExecutionChange",
      Ethereum.signed_bls_to_execution_change,
      "a6a69373129d69a525918124ca20179b7e4b4b3e8f1e5962ba572d74194b8c44" );
    ( "hash_tree_root_SyncAggregate",
      Ethereum.sync_aggregate,
      "42b052541dce45557d83d34634a45a56d216d4375e5a9584f6445ce4e63324af" );
    ( "hash_tree_root_VoluntaryExit",
      Ethereum.voluntary_exit,
      "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b" );
    ( "hash_tree_root_SignedVoluntaryExit",
      Ethereum.signed_voluntary_exit,
      "42b052541dce45557d83d34634a45a56d216d4375e5a9584f6445ce4e63324af" );
    ( "hash_tree_root_Deposit",
      Ethereum.deposit,
      "a14b699cfcbfe24befcdd2c8bfd6a9ed5c4a9c167af373bf02dafb6ff664c2c8" );
    ( "hash_tree_root_Checkpoint",
      Ethereum.checkpoint,
      "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b" );
    ( "hash_tree_root_AttestationData",
      Ethereum.attestation_data,
      "01f278ee83d4e438cf8f563ce108974d64c029a20280ab8eca07741df7ee5290" );
    ( "hash_tree_root_Attestation",
      Ethereum.attestation,
      "8cff4a2b733ad5b74df8450613cc002bb66f61364d86c6fa22adbbaca80cdb85" );
    ( "hash_tree_root_IndexedAttestation",
      Ethereum.indexed_attestation,
      "4cda58c1f827e886e86494cbf71cca1096c3d16eb5cc8ac6949fbaf360a9721e" );
    ( "hash_tree_root_AttesterSlashing",
      Ethereum.attester_slashing,
      "8057d3edd5265d28219703ee81f361fc163071c9f5671d4411832bd7d7ef7c2d" );
    ( "hash_tree_root_ProposerSlashing",
      Ethereum.proposer_slashing,
      "bd6a4376cd9cfe92961ca3346e66c53447b728f8cda39c283f358c9c50730586" );
    ( "hash_tree_root_SignedBeaconBlockHeader",
      Ethereum.signed_beacon_block_header,
      "75fbdb83b1dfa7d5cace569fb811348e77014d7ab517818a771c1a61d3303d83" );
    ( "hash_tree_root_beaconBlockBody",
      Ethereum.beacon_block_body,
      "74b4bb048d39c75f175fbb2311062eb9867d79b712907f39544fcaf2d7e1b433" );
    ( "hash_tree_root_Fork",
      Ethereum.fork,
      "db56114e00fdd4c1f85c892bf35ac9a89289aaecb1ebd0a96cde606a748b5d71" );
    ( "hash_tree_root_Validator",
      Ethereum.validator,
      "fa324a462bcb0f10c24c9e17c326a4e0ebad204feced523eccaf346c686f06ee" );
    ( "hash_tree_root_SyncCommittee",
      Ethereum.sync_committee,
      "173669ae8794c057def63b20372114a628abb029354a2ef50d7a1aaa9a3dab4a" );
    ( "hash_tree_root_ExecutionPayloadHeader",
      Ethereum.execution_payload_header,
      "22216a4a17e55cc41ce454600e5deb8aad32f15580a938b1914f93a9652c0e2c" );
    ( "hash_tree_root_HistoricalSummary",
      Ethereum.historical_summary,
      "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b" );
    ( "hash_tree_root_beaconState",
      Ethereum.beacon_state,
      "6c1dbede1fac000558326175f03b5e4fc73f63f383143b1a415d83cc209ca92f" );
    ( "hash_tree_root_DepositMessage",
      Ethereum.deposit_message,
      "da6d807bf795106146e5822775d914b0277a65240f650ed4c8a7ca77824e5adf" );
    ( "hash_tree_root_beaconBlock",
      Ethereum.beacon_block,
      "e363588e513e48ebf8afec68fa12e5be7de7f209092b89de0eec5de4c3f8fd7f" );
  ]

let check_hash_tree_root_registry () =
  let prefix = "hash_tree_root_" in
  let has_prefix name =
    String.length name >= String.length prefix
    && String.equal prefix (String.sub name 0 (String.length prefix))
  in
  let registered =
    Builtin_eth.builtins
    |> List.filter_map (fun (name, _) -> if has_prefix name then Some name else None)
    |> List.sort String.compare
  in
  let expected =
    [ "hash_tree_root_roots"; "hash_tree_root_tx"; "hash_tree_root_withdrawals" ]
    @ List.map (fun (name, _, _) -> name) schema_builtins
    |> List.sort String.compare
  in
  if registered <> expected then
    failwith
      (Printf.sprintf
         "hash_tree_root builtin ABI mismatch:\nexpected: %s\nregistered: %s"
         (String.concat ", " expected) (String.concat ", " registered))

let () =
  check_hash_tree_root_registry ();

  let bytes_a = Value.make_bytes ~num:(Bigint.of_int 7) ~len:32 in
  let bytes_b = Value.make_bytes ~num:(Bigint.of_int 7) ~len:32 in
  let bytes_wrong_length = Value.make_bytes ~num:(Bigint.of_int 7) ~len:31 in
  if not (Il.Eq.eq_value bytes_a bytes_b) then
    failwith "equal BytesV values were reported as different";
  if Il.Eq.eq_value bytes_a bytes_wrong_length then
    failwith "BytesV length mismatch was not detected";
  if not (Il.Eq.eq_value (nat 7) bytes_a) then
    failwith "numeric and byte values with the same magnitude should compare";

  check_root "hash_tree_root_roots empty compatibility"
    (String.make 64 '0')
    (call_builtin "hash_tree_root_roots"
       [ Value.list' (Il.NumT `NatT) [] ]);

  let checkpoint =
    Value.tuple
      [
        nat 3;
        Value.make_bytes
          ~num:
            (Merkle.bigint_of_be_bytes
               (Bytes.init 32 (fun index -> Char.chr index)))
          ~len:32;
      ]
  in
  check_root "hash_tree_root_Checkpoint builtin"
    "1bc121515fb6438a027f365fc291317a815fdd3bd05ad85dff24879a1a3276b1"
    (call_builtin "hash_tree_root_Checkpoint" [ checkpoint ]);

  let malformed_checkpoint =
    Value.tuple [ nat 3; Value.make_bytes ~num:Bigint.zero ~len:1 ]
  in
  check_builtin_rejected "hash_tree_root_Checkpoint"
    [ malformed_checkpoint ];

  let transactions =
    Value.list' (Il.NumT `NatT) [ byte_list [ 0; 1; 2 ]; byte_list [] ]
  in
  check_root "hash_tree_root_tx builtin"
    "33792366f49d5b0a2062d686b082cc35a972f6b7417a61106abc49533a33974d"
    (call_builtin "hash_tree_root_tx" [ transactions ]);

  check_root "hash_tree_root_tx empty-list ABI"
    "7ffe241ea60187fdb0187bfa22de35d1f9bed7ab061d9401fd47e34a54fbede1"
    (call_builtin "hash_tree_root_tx" [ Value.list' (Il.NumT `NatT) [] ]);
  check_root "hash_tree_root_withdrawals empty-list ABI"
    "792930bbd5baac43bcc798ee49aa8185ef76bb3b44ba62b91d86ae569e4bb535"
    (call_builtin "hash_tree_root_withdrawals"
       [ Value.list' (Il.NumT `NatT) [] ]);

  List.iter
    (fun (name, schema, expected) ->
      check_builtin_zero_root name expected Capella schema)
    schema_builtins;

  check_builtin_zero_root "hash_tree_root_executionPayload"
    "2e061cffdc4f4086a06e906f47de586de5ba31fbff54f361f5374b8ecaf7f50e"
    Deneb Ethereum.execution_payload;
  check_builtin_zero_root "hash_tree_root_ExecutionPayloadHeader"
    "54b4b8b897929a1ede97d29e9551d610229f22c1a59d186d95aed203333b4e5e"
    Deneb Ethereum.execution_payload_header;
  check_builtin_zero_root "hash_tree_root_beaconBlockBody"
    "bce73ee2c617851846af2b3ea2287e3b686098e18ae508c7271aaa06ab1d06cd"
    Deneb Ethereum.beacon_block_body;
  check_builtin_zero_root "hash_tree_root_beaconState"
    "e6b7639e8c664e1969196fd2a97a275fc3ebb02b811b80b4736d35b6b73c2161"
    Deneb Ethereum.beacon_state;

  Printf.printf "SpecTec SSZ builtin adapter tests passed\n"
