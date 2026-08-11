open Common.Source
open Lang.Il
open Lang.Xl
open Value
open Builtins
open Error

let ( let* ) = Result.bind

module Bytes = Stdlib.Bytes
module Ssz_htr = Ethereum_ssz.Ssz_htr
module Ethereum_schema = Ethereum_ssz.Ethereum_schema

include Ethereum_ssz.Ssz_merkle

let ensure_fits_bytes ~at (n : Bigint.t) ~(len : int) : unit result =
  if Bigint.(n >= zero && n < pow2_8 len) then Ok ()
  else Error (runtime at (Printf.sprintf "value does not fit in %d bytes" len))

(* Strict conversion: Value.t (NumV n or BytesV) -> Bytes.t (32-byte leaf) *)
let to_b32_exn ~at (rv : Value.t) : Bytes.t result =
  match rv.it with
  | NumV n -> Ok (leaf_bytes32 (Num.to_int n))
  | BytesV { num; len } ->
      if len <> 32 then
        Error (runtime at "to_b32_exn: BytesV length must be 32")
      else Ok (leaf_bytes32 num)
  | _ -> Error (runtime at "expected NumV or BytesV (32-byte root)")

(* dec $is_valid_merkle_branch(bytes32, bytes32*, uint64, uint64, root) : boolean *)
let is_valid_merkle_branch ~at (leaf : Num.t) (branch : Num.t list)
    (depth : Num.t) (index : Num.t) (root : Num.t) : Value.t result =
  let leaf = Num.to_int leaf in
  let branch = List.map Num.to_int branch in
  let depth = Num.to_int depth in
  let index = Num.to_int index in
  let root = Num.to_int root in
  let* () = ensure_fits_bytes ~at leaf ~len:32 in
  let* () = ensure_fits_bytes ~at root ~len:32 in
  let* () = ensure_fits_bytes ~at depth ~len:8 in
  let* () = ensure_fits_bytes ~at index ~len:8 in
  let* () =
    let rec check_all = function
      | [] -> Ok ()
      | x :: xs ->
          let* () = ensure_fits_bytes ~at x ~len:32 in
          check_all xs
    in
    check_all branch
  in
  let depth_int = try Bigint.to_int_exn depth with _ -> -1 in
  if depth_int < 0 then Error (runtime at "depth too large")
  else if List.length branch < depth_int then
    Error (runtime at "branch shorter than depth")
  else
    let rec iter i (value : Bigint.t) : Bigint.t =
      if i >= depth_int then value
      else
        let sibling = List.nth branch i in
        let bit_i = Bigint.(bit_and (shift_right index i) (of_int 1)) in
        let left, right =
          if Bigint.(bit_i = zero) then (value, sibling) else (sibling, value)
        in
        let b_left = be_of_bigint_fixed left ~len:32 in
        let b_right = be_of_bigint_fixed right ~len:32 in
        let cat = Bytes.create 64 in
        Bytes.blit b_left 0 cat 0 32;
        Bytes.blit b_right 0 cat 32 32;
        iter (i + 1) (sha256_bytes32 cat)
    in
    let computed = iter 0 leaf in
    Ok (Value.bool Bigint.(computed = root))

(* The SSZ engine owns all type-directed hashing. This adapter only exposes the
   runtime Value.t shapes without coupling the reusable library to SpecTec. *)
let ssz_as_bool (value : Value.t) =
  match value.it with
  | BoolV b -> Ok b
  | _ -> Error "expected boolean"

let ssz_as_uint (value : Value.t) =
  match value.it with
  | NumV n -> Ok (Num.to_int n)
  | BytesV { num; _ } -> Ok num
  | _ -> Error "expected unsigned integer"

let bytes_of_uint8_values (values : Value.t list) =
  let out = Bytes.create (List.length values) in
  let rec fill index = function
    | [] -> Ok out
    | value :: rest ->
        let* n = ssz_as_uint value in
        if Bigint.(n < zero || n >= of_int 256) then
          Error
            (Printf.sprintf "byte value out of range: %s" (Bigint.to_string n))
        else (
          Bytes.set out index (Stdlib.Char.chr (Bigint.to_int_exn n));
          fill (index + 1) rest)
  in
  fill 0 values

let ssz_as_bytes ~length (value : Value.t) =
  let fixed_bytes num len =
    if len < 0 then Error "negative byte length"
    else if Bigint.(num < zero || num >= pow2_8 len) then
      Error
        (Printf.sprintf "value does not fit in %d bytes" len)
    else Ok (be_of_bigint_fixed num ~len)
  in
  match value.it with
  | BytesV { num; len } -> (
      match length with
      | Some expected when len <> expected ->
          Error
            (Printf.sprintf "expected %d bytes, got BytesV length %d" expected
               len)
      | Some expected -> fixed_bytes num expected
      | None -> fixed_bytes num len)
  | NumV n -> (
      match length with
      | Some expected -> fixed_bytes (Num.to_int n) expected
      | None -> Error "cannot infer byte-list length from a numeric value")
  | ListV values -> bytes_of_uint8_values values
  | _ -> Error "expected bytes or a list of uint8 values"

let ssz_as_sequence (value : Value.t) =
  match value.it with
  | ListV values -> Ok values
  | _ -> Error "expected sequence"

let ssz_as_container (value : Value.t) =
  match value.it with
  | StructV fields -> Ok (List.map snd fields)
  | TupleV values | ListV values -> Ok values
  | _ -> Error "expected container"

let ssz_accessors : Value.t Ssz_htr.accessors =
  {
    as_bool = ssz_as_bool;
    as_uint = ssz_as_uint;
    as_bytes = ssz_as_bytes;
    as_sequence = ssz_as_sequence;
    as_container = ssz_as_container;
  }

let hash_tree_root_bytes ~at schema (value : Value.t) : Bytes.t result =
  match Ssz_htr.hash_tree_root ~accessors:ssz_accessors schema value with
  | Ok root -> Ok root
  | Error error -> Error (runtime at (Ssz_htr.error_to_string error))

let hash_tree_root_value ~at schema (value : Value.t) : Value.t result =
  let* root = hash_tree_root_bytes ~at schema value in
  Ok (make_bytes ~num:(bigint_of_be_bytes root) ~len:32)

let value_of_num (n : Num.t) : Value.t =
  match n with `Nat n -> Value.nat n | `Int n -> Value.int n

let value_list (values : Value.t list) : Value.t =
  Value.list' (NumT `NatT) values

(* The three list-taking builtins keep their original OCaml/Arg signatures. *)
let hash_tree_root_roots ~at (roots : Num.t list) : Value.t result =
  match roots with
  | [] ->
      (* This helper predates the schema-driven engine and accepts a generic
         [root*], including the empty list. SSZ itself has no Vector[T, 0], so
         preserve the builtin's established empty-tree result explicitly. *)
      Ok (make_bytes ~num:Bigint.zero ~len:32)
  | _ ->
      let value = roots |> List.map value_of_num |> value_list in
      hash_tree_root_value ~at (Ethereum_schema.roots (List.length roots)) value

let hash_tree_root_tx ~at (transactions : Value.t list) : Value.t result =
  hash_tree_root_value ~at Ethereum_schema.transactions
    (value_list transactions)

let hash_tree_root_withdrawals ~at (withdrawals : Value.t list) : Value.t result
    =
  hash_tree_root_value ~at Ethereum_schema.withdrawals (value_list withdrawals)

let hash_tree_root_beaconBlockHeader ~at value =
  hash_tree_root_value ~at Ethereum_schema.beacon_block_header value

let hash_tree_root_depositData ~at value =
  hash_tree_root_value ~at Ethereum_schema.deposit_data value

let hash_tree_root_forkdata ~at value =
  hash_tree_root_value ~at Ethereum_schema.fork_data value

let hash_tree_root_eth1Data ~at value =
  hash_tree_root_value ~at Ethereum_schema.eth1_data value

let hash_tree_root_executionPayload ~at value =
  hash_tree_root_value ~at Ethereum_schema.execution_payload value

let hash_tree_root_BLSToExecutionChange ~at value =
  hash_tree_root_value ~at Ethereum_schema.bls_to_execution_change value

let hash_tree_root_SignedBLSToExecutionChange ~at value =
  hash_tree_root_value ~at Ethereum_schema.signed_bls_to_execution_change value

let hash_tree_root_SyncAggregate ~at value =
  hash_tree_root_value ~at Ethereum_schema.sync_aggregate value

let hash_tree_root_VoluntaryExit ~at value =
  hash_tree_root_value ~at Ethereum_schema.voluntary_exit value

let hash_tree_root_SignedVoluntaryExit ~at value =
  hash_tree_root_value ~at Ethereum_schema.signed_voluntary_exit value

let hash_tree_root_Deposit ~at value =
  hash_tree_root_value ~at Ethereum_schema.deposit value

let hash_tree_root_Checkpoint ~at value =
  hash_tree_root_value ~at Ethereum_schema.checkpoint value

let hash_tree_root_AttestationData ~at value =
  hash_tree_root_value ~at Ethereum_schema.attestation_data value

let hash_tree_root_Attestation ~at value =
  hash_tree_root_value ~at Ethereum_schema.attestation value

let hash_tree_root_IndexedAttestation ~at value =
  hash_tree_root_value ~at Ethereum_schema.indexed_attestation value

let hash_tree_root_AttesterSlashing ~at value =
  hash_tree_root_value ~at Ethereum_schema.attester_slashing value

let hash_tree_root_SignedBeaconBlockHeader ~at value =
  hash_tree_root_value ~at Ethereum_schema.signed_beacon_block_header value

let hash_tree_root_ProposerSlashing ~at value =
  hash_tree_root_value ~at Ethereum_schema.proposer_slashing value

let hash_tree_root_Fork ~at value =
  hash_tree_root_value ~at Ethereum_schema.fork value

let hash_tree_root_Validator ~at value =
  hash_tree_root_value ~at Ethereum_schema.validator value

let hash_tree_root_SyncCommittee ~at value =
  hash_tree_root_value ~at Ethereum_schema.sync_committee value

let hash_tree_root_ExecutionPayloadHeader ~at value =
  hash_tree_root_value ~at Ethereum_schema.execution_payload_header value

let hash_tree_root_HistoricalSummary ~at value =
  hash_tree_root_value ~at Ethereum_schema.historical_summary value

let hash_tree_root_beaconBlockBody ~at value =
  hash_tree_root_value ~at Ethereum_schema.beacon_block_body value

let hash_tree_root_beaconState ~at value =
  hash_tree_root_value ~at Ethereum_schema.beacon_state value

let hash_tree_root_DepositMessage ~at value =
  hash_tree_root_value ~at Ethereum_schema.deposit_message value

let hash_tree_root_beaconBlock ~at value =
  hash_tree_root_value ~at Ethereum_schema.beacon_block value

(* ===== SigningData(object_root: root, domain: bytes32) HTR ===== *)
let signing_data_root_from_bytes (obj_root_b : Bytes.t) (domain_b : Bytes.t) :
    Bytes.t =
  let field_roots = [| obj_root_b; domain_b |] in
  merkleize_leaves field_roots

(* ===== compute_signing_root_* ===== *)
let compute_signing_root_epoch ~at (epoch_v : Num.t) (domain_v : Num.t) :
    Value.t result =
  let epoch_bigint = Num.to_int epoch_v in
  let domain_bigint = Num.to_int domain_v in
  let* () = ensure_fits_bytes ~at epoch_bigint ~len:8 in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let obj_root_b = leaf_uint_le epoch_bigint ~nbytes:8 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_root_b dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let compute_signing_root_voluntary_exit ~at (ve : Value.t) (domain_v : Num.t) :
    Value.t result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_VoluntaryExit ~at ve in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let compute_signing_root_bls_to_execution_change ~at (msg : Value.t)
    (domain_v : Num.t) : Value.t result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_BLSToExecutionChange ~at msg in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let compute_signing_root_beaconBlockHeader ~at (hdr : Value.t)
    (domain_v : Num.t) : Value.t result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_beaconBlockHeader ~at hdr in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let compute_signing_root_attestationData ~at (ad : Value.t) (domain_v : Num.t) :
    Value.t result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_AttestationData ~at ad in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let compute_signing_root_depositMessage ~at (dm : Value.t) (domain_v : Num.t) :
    Value.t result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_DepositMessage ~at dm in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let compute_signing_root_block_root ~at (b32 : Num.t) (domain_v : Num.t) :
    Value.t result =
  let b32_bigint = Num.to_int b32 in
  let domain_bigint = Num.to_int domain_v in
  let* () = ensure_fits_bytes ~at b32_bigint ~len:32 in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let obj_b = be_of_bigint_fixed b32_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let compute_signing_root_beaconBlock ~at (blk : Value.t) (domain_v : Num.t) :
    Value.t result =
  let domain_bigint = Num.to_int domain_v in
  let* r_blk_v = hash_tree_root_beaconBlock ~at blk in
  let* obj_b32 = to_b32_exn ~at r_blk_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let builtins : (string * Define.t) list =
  [
    ( "is_valid_merkle_branch",
      Define.T0.a5 Arg.num (Arg.list_of Arg.num) Arg.num Arg.num Arg.num
        is_valid_merkle_branch );
    ( "hash_tree_root_roots",
      Define.T0.a1 (Arg.list_of Arg.num) hash_tree_root_roots );
    ("hash_tree_root_tx", Define.T0.a1 (Arg.list_of Arg.value) hash_tree_root_tx);
    ( "hash_tree_root_beaconBlockHeader",
      Define.T0.a1 Arg.value hash_tree_root_beaconBlockHeader );
    ( "hash_tree_root_depositData",
      Define.T0.a1 Arg.value hash_tree_root_depositData );
    ("hash_tree_root_forkdata", Define.T0.a1 Arg.value hash_tree_root_forkdata);
    ( "hash_tree_root_withdrawals",
      Define.T0.a1 (Arg.list_of Arg.value) hash_tree_root_withdrawals );
    ("hash_tree_root_eth1Data", Define.T0.a1 Arg.value hash_tree_root_eth1Data);
    ( "hash_tree_root_executionPayload",
      Define.T0.a1 Arg.value hash_tree_root_executionPayload );
    ( "hash_tree_root_BLSToExecutionChange",
      Define.T0.a1 Arg.value hash_tree_root_BLSToExecutionChange );
    ( "hash_tree_root_SignedBLSToExecutionChange",
      Define.T0.a1 Arg.value hash_tree_root_SignedBLSToExecutionChange );
    ( "hash_tree_root_SyncAggregate",
      Define.T0.a1 Arg.value hash_tree_root_SyncAggregate );
    ( "hash_tree_root_VoluntaryExit",
      Define.T0.a1 Arg.value hash_tree_root_VoluntaryExit );
    ( "hash_tree_root_SignedVoluntaryExit",
      Define.T0.a1 Arg.value hash_tree_root_SignedVoluntaryExit );
    ("hash_tree_root_Deposit", Define.T0.a1 Arg.value hash_tree_root_Deposit);
    ( "hash_tree_root_Checkpoint",
      Define.T0.a1 Arg.value hash_tree_root_Checkpoint );
    ( "hash_tree_root_AttestationData",
      Define.T0.a1 Arg.value hash_tree_root_AttestationData );
    ( "hash_tree_root_Attestation",
      Define.T0.a1 Arg.value hash_tree_root_Attestation );
    ( "hash_tree_root_IndexedAttestation",
      Define.T0.a1 Arg.value hash_tree_root_IndexedAttestation );
    ( "hash_tree_root_AttesterSlashing",
      Define.T0.a1 Arg.value hash_tree_root_AttesterSlashing );
    ( "hash_tree_root_ProposerSlashing",
      Define.T0.a1 Arg.value hash_tree_root_ProposerSlashing );
    ( "hash_tree_root_SignedBeaconBlockHeader",
      Define.T0.a1 Arg.value hash_tree_root_SignedBeaconBlockHeader );
    ( "hash_tree_root_beaconBlockBody",
      Define.T0.a1 Arg.value hash_tree_root_beaconBlockBody );
    ("hash_tree_root_Fork", Define.T0.a1 Arg.value hash_tree_root_Fork);
    ("hash_tree_root_Validator", Define.T0.a1 Arg.value hash_tree_root_Validator);
    ( "hash_tree_root_SyncCommittee",
      Define.T0.a1 Arg.value hash_tree_root_SyncCommittee );
    ( "hash_tree_root_ExecutionPayloadHeader",
      Define.T0.a1 Arg.value hash_tree_root_ExecutionPayloadHeader );
    ( "hash_tree_root_HistoricalSummary",
      Define.T0.a1 Arg.value hash_tree_root_HistoricalSummary );
    ( "hash_tree_root_beaconState",
      Define.T0.a1 Arg.value hash_tree_root_beaconState );
    ( "hash_tree_root_DepositMessage",
      Define.T0.a1 Arg.value hash_tree_root_DepositMessage );
    ( "hash_tree_root_beaconBlock",
      Define.T0.a1 Arg.value hash_tree_root_beaconBlock );
    ( "compute_signing_root_epoch",
      Define.T0.a2 Arg.num Arg.num compute_signing_root_epoch );
    ( "compute_signing_root_voluntary_exit",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_voluntary_exit );
    ( "compute_signing_root_bls_to_execution_change",
      Define.T0.a2 Arg.value Arg.num
        compute_signing_root_bls_to_execution_change );
    ( "compute_signing_root_beaconBlockHeader",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_beaconBlockHeader );
    ( "compute_signing_root_attestationData",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_attestationData );
    ( "compute_signing_root_depositMessage",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_depositMessage );
    ( "compute_signing_root_block_root",
      Define.T0.a2 Arg.num Arg.num compute_signing_root_block_root );
    ( "compute_signing_root_beaconBlock",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_beaconBlock );
  ]
