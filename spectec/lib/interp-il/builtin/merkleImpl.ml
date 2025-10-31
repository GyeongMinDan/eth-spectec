open Il
open Xl
open Util.Source

let ( let* ) = Result.bind

module Bytes = Stdlib.Bytes

(* Helpers *)
let pow2_8 (n : int) = Bigint.pow (Bigint.of_int 2) (Bigint.of_int (8 * n))

let ensure_fits_bytes ~at (n : Bigint.t) ~(len : int) : (unit, Err.t) result =
  if Bigint.(n >= zero && n < pow2_8 len) then Ok ()
  else
    Error (Err.runtime at (Printf.sprintf "value does not fit in %d bytes" len))

let be_of_bigint_fixed (n : Bigint.t) ~(len : int) : Bytes.t =
  if Bigint.(n < zero) then invalid_arg "negative";
  let out = Bytes.create len in
  let rec fill i v =
    if i < 0 then ()
    else
      let byte = Bigint.to_int_exn Bigint.(v % of_int 256) in
      Bytes.set out i (Stdlib.Char.chr byte);
      fill (i - 1) Bigint.(v / of_int 256)
  in
  fill (len - 1) n;
  out

let bigint_of_be_bytes (b : Bytes.t) : Bigint.t =
  let acc = ref Bigint.zero in
  for i = 0 to Bytes.length b - 1 do
    let v = Stdlib.Char.code (Bytes.get b i) in
    acc := Bigint.((!acc * of_int 256) + of_int v)
  done;
  !acc

let sha256_bytes32 (x : Bytes.t) : Bigint.t =
  let open Digestif.SHA256 in
  digest_bytes x |> to_raw_string |> Bytes.of_string |> bigint_of_be_bytes

(* SSZ merkle helpers *)
let merkle_hash_ (left : Bytes.t) (right : Bytes.t) : Bytes.t =
  let cat = Bytes.create 64 in
  Bytes.blit left 0 cat 0 32;
  Bytes.blit right 0 cat 32 32;
  Digestif.SHA256.(digest_bytes cat |> to_raw_string |> Bytes.of_string)

let zero32 : Bytes.t = Bytes.make 32 '\x00'

let merkleize_leaves (leaves : Bytes.t array) : Bytes.t =
  let n = Array.length leaves in
  if n = 0 then zero32
  else
    let next_pow2 x =
      if x <= 1 then 1
      else
        let rec f p = if p >= x then p else f (p lsl 1) in
        f 1
    in
    let size = next_pow2 n in
    let level = Array.make size zero32 in
    Array.blit leaves 0 level 0 n;
    let rec up lvl =
      if Array.length lvl = 1 then lvl.(0)
      else
        let m = Array.length lvl / 2 in
        let upper =
          Array.init m (fun i -> merkle_hash_ lvl.(2 * i) lvl.((2 * i) + 1))
        in
        up upper
    in
    up level

let mix_in_length (root : Bytes.t) (len : Bigint.t) : Bytes.t =
  let le32 = Bytes.make 32 '\x00' in
  let v = ref len in
  for i = 0 to 31 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set le32 i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
  merkle_hash_ root le32

let chunkize_bytes_bytev (raw : Bytes.t) : Bytes.t array =
  let len = Bytes.length raw in
  let full = len / 32 * 32 in
  let k = if len = full then len / 32 else (len / 32) + 1 in
  if k = 0 then [| zero32 |]
  else
    Array.init k (fun i ->
        if i < k - 1 then (
          let c = Bytes.create 32 in
          Bytes.blit raw (i * 32) c 0 32;
          c)
        else
          let c = Bytes.make 32 '\x00' in
          Bytes.blit raw full c 0 (len - full);
          c)

let leaf_uint_le (n : Bigint.t) ~(nbytes : int) : Bytes.t =
  let c = Bytes.make 32 '\x00' in
  let v = ref n in
  for i = 0 to nbytes - 1 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set c i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
  c

let leaf_bytes32 (x : Bigint.t) : Bytes.t = be_of_bigint_fixed x ~len:32

let merkleize_vector_roots (leaves : Bytes.t array) : Bytes.t =
  merkleize_leaves leaves

let chunkize_bytevector_fixed (raw : Bytes.t) ~(len : int) : Bytes.t array =
  if Bytes.length raw <> len then
    invalid_arg "chunkize_bytevector_fixed: len mismatch";
  let k = (len + 31) / 32 in
  if k = 0 then [| Bytes.make 32 '\x00' |]
  else
    Array.init k (fun i ->
        let c = Bytes.make 32 '\x00' in
        let off = i * 32 in
        let remain = max 0 (len - off) in
        let to_copy = if remain >= 32 then 32 else remain in
        if to_copy > 0 then Bytes.blit raw off c 0 to_copy;
        c)

let to_raw_bytes_fixed ~(len : int) (n : Bigint.t) : Bytes.t =
  be_of_bigint_fixed n ~len

let bigint_to_int n = int_of_string (Bigint.to_string n)

(* dec $is_valid_merkle_branch(bytes32, bytes32*, uint64, uint64, root) : boolean *)
let is_valid_merkle_branch ~at (leaf : Bigint.t) (branch : Bigint.t list)
    (depth : Bigint.t) (index : Bigint.t) (root : Bigint.t) :
    (Value.t, Err.t) result =
  (* Validate inputs *)
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
  (* Convert depth to int for loop bounds *)
  let depth_int = try Bigint.to_int_exn depth with _ -> -1 in
  if depth_int < 0 then Error (Err.runtime at "depth too large")
  else if List.length branch < depth_int then
    Error (Err.runtime at "branch shorter than depth")
  else
    (* Loop *)
    let rec iter i (value : Bigint.t) : Bigint.t =
      if i >= depth_int then value
      else
        let sibling = List.nth branch i in
        (* parity = (index >> i) & 1 *)
        let bit_i = Bigint.(bit_and (shift_right index i) (of_int 1)) in
        let left, right =
          if Bigint.(bit_i = zero) then (* value || sibling *) (value, sibling)
          else (sibling, value)
        in
        let b_left = be_of_bigint_fixed left ~len:32 in
        let b_right = be_of_bigint_fixed right ~len:32 in
        let cat = Bytes.create 64 in
        Bytes.blit b_left 0 cat 0 32;
        Bytes.blit b_right 0 cat 32 32;
        let value' = sha256_bytes32 cat in
        iter (i + 1) value'
    in
    let computed = iter 0 leaf in
    Ok (Value.bool Bigint.(computed = root))

(* ----- hash_tree_root_roots(root list) : root ----- *)
let hash_tree_root_roots ~at (lst : Bigint.t list) : (Value.t, Err.t) result =
  at |> ignore;
  let leaves =
    Array.of_list (List.map (fun n -> be_of_bigint_fixed n ~len:32) lst)
  in
  let root = merkleize_leaves leaves in
  let root' = mix_in_length root (Bigint.of_int (Array.length leaves)) in
  Ok (Value.nat (bigint_of_be_bytes root'))

(* ----- hash_tree_root_tx(bytes list) : root ----- *)
let hash_tree_root_tx ~at (bytes_list : Bigint.t list) : (Value.t, Err.t) result
    =
  at |> ignore;
  (* bytes* is a list of bytes1 (0..255) *)
  let buf = Buffer.create (List.length bytes_list) in
  let rec put = function
    | [] -> Ok ()
    | n :: ns ->
        if Bigint.(n < zero || n >= of_int 256) then
          Error (Err.runtime at "hash_tree_root_tx: byte out of range")
        else (
          Buffer.add_char buf (Stdlib.Char.chr (Bigint.to_int_exn n));
          put ns)
  in
  let* () = put bytes_list in
  let raw = Bytes.of_string (Buffer.contents buf) in
  let leaves = chunkize_bytes_bytev raw in
  let root = merkleize_leaves leaves in
  let out = mix_in_length root (Bigint.of_int (Bytes.length raw)) in
  Ok (Value.nat (bigint_of_be_bytes out))

(* ----- hash_tree_root_beaconBlockHeader(beaconBlockHeader) : root ----- *)
let hash_tree_root_beaconBlockHeader ~at (hdr : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  let* slot, proposer_index, parent_root, state_root, body_root =
    match hdr.it with
    | StructV
        [
          (_, slot_v); (_, proposer_v); (_, parent_v); (_, state_v); (_, body_v);
        ] ->
        Ok
          ( get_nat slot_v,
            get_nat proposer_v,
            get_nat parent_v,
            get_nat state_v,
            get_nat body_v )
    | TupleV [ slot_v; proposer_v; parent_v; state_v; body_v ] ->
        Ok
          ( get_nat slot_v,
            get_nat proposer_v,
            get_nat parent_v,
            get_nat state_v,
            get_nat body_v )
    | ListV [ slot_v; proposer_v; parent_v; state_v; body_v ] ->
        Ok
          ( get_nat slot_v,
            get_nat proposer_v,
            get_nat parent_v,
            get_nat state_v,
            get_nat body_v )
    | _ -> Error (Err.runtime at "beaconBlockHeader: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at slot ~len:8 in
  let* () = ensure_fits_bytes ~at proposer_index ~len:8 in
  let* () = ensure_fits_bytes ~at parent_root ~len:32 in
  let* () = ensure_fits_bytes ~at state_root ~len:32 in
  let* () = ensure_fits_bytes ~at body_root ~len:32 in
  let leaves =
    [|
      leaf_uint_le slot ~nbytes:8;
      leaf_uint_le proposer_index ~nbytes:8;
      leaf_bytes32 parent_root;
      leaf_bytes32 state_root;
      leaf_bytes32 body_root;
    |]
  in
  let root_bytes = merkleize_vector_roots leaves in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_depositData(depositData) : root ----- *)
let hash_tree_root_depositData ~at (dd : Value.t) : (Value.t, Err.t) result =
  let get_num v = v |> Il.Value.get_num |> Num.to_int in
  let* pubkey_b48, wcred_b32, amount_u64, sig_b96 =
    match dd.it with
    | StructV [ (_, v_pub); (_, v_wcr); (_, v_amt); (_, v_sig) ] ->
        Ok (get_num v_pub, get_num v_wcr, get_num v_amt, get_num v_sig)
    | TupleV [ v_pub; v_wcr; v_amt; v_sig ] ->
        Ok (get_num v_pub, get_num v_wcr, get_num v_amt, get_num v_sig)
    | ListV [ v_pub; v_wcr; v_amt; v_sig ] ->
        Ok (get_num v_pub, get_num v_wcr, get_num v_amt, get_num v_sig)
    | _ -> Error (Err.runtime at "depositData: unexpected value shape")
  in
  (* range checks *)
  let* () = ensure_fits_bytes ~at pubkey_b48 ~len:48 in
  let* () = ensure_fits_bytes ~at wcred_b32 ~len:32 in
  let* () = ensure_fits_bytes ~at amount_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at sig_b96 ~len:96 in
  (* field roots *)
  let pubkey_raw = to_raw_bytes_fixed ~len:48 pubkey_b48 in
  let pubkey_leafs = chunkize_bytevector_fixed pubkey_raw ~len:48 in
  let r_pubkey = merkleize_leaves pubkey_leafs in

  let r_wcred = leaf_bytes32 wcred_b32 in
  let r_amount = leaf_uint_le amount_u64 ~nbytes:8 in

  let sig_raw = to_raw_bytes_fixed ~len:96 sig_b96 in
  let sig_leafs = chunkize_bytevector_fixed sig_raw ~len:96 in
  let r_sig = merkleize_leaves sig_leafs in

  let field_roots = [| r_pubkey; r_wcred; r_amount; r_sig |] in
  let root_bytes = merkleize_vector_roots field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_forkdata(forkdata) : root ----- *)
let hash_tree_root_forkdata ~at (fd : Value.t) : (Value.t, Err.t) result =
  let get_num v = v |> Il.Value.get_num |> Num.to_int in
  let* version_b4, gvr_b32 =
    match fd.it with
    | StructV [ (_, v_ver); (_, v_gvr) ] -> Ok (get_num v_ver, get_num v_gvr)
    | TupleV [ v_ver; v_gvr ] -> Ok (get_num v_ver, get_num v_gvr)
    | ListV [ v_ver; v_gvr ] -> Ok (get_num v_ver, get_num v_gvr)
    | _ -> Error (Err.runtime at "forkdata: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at version_b4 ~len:4 in
  let* () = ensure_fits_bytes ~at gvr_b32 ~len:32 in
  (* version: 4B ByteVector → 32B 단일 청크 *)
  let version_raw = be_of_bigint_fixed version_b4 ~len:4 in
  let version_leafs = chunkize_bytevector_fixed version_raw ~len:4 in
  let r_version = merkleize_leaves version_leafs in
  (* genesis_validators_root: bytes32 → 단일 리프 *)
  let r_gvr = leaf_bytes32 gvr_b32 in
  let field_roots = [| r_version; r_gvr |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- Withdrawal container → 32B root ----- *)
(* can not find better naming... *)
let htr_withdrawal_container ~at (w : Value.t) : (Bytes.t, Err.t) result =
  let get_num v = v |> Il.Value.get_num |> Num.to_int in
  let* index_u64, validator_index_u64, address_b20, amount_u64 =
    match w.it with
    | StructV
        [ (_, v_index); (_, v_validator_index); (_, v_address); (_, v_amount) ]
      ->
        Ok
          ( get_num v_index,
            get_num v_validator_index,
            get_num v_address,
            get_num v_amount )
    | TupleV [ v_index; v_validator_index; v_address; v_amount ] ->
        Ok
          ( get_num v_index,
            get_num v_validator_index,
            get_num v_address,
            get_num v_amount )
    | ListV [ v_index; v_validator_index; v_address; v_amount ] ->
        Ok
          ( get_num v_index,
            get_num v_validator_index,
            get_num v_address,
            get_num v_amount )
    | _ -> Error (Err.runtime at "withdrawal: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at index_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at validator_index_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at address_b20 ~len:20 in
  let* () = ensure_fits_bytes ~at amount_u64 ~len:8 in
  let r_index = leaf_uint_le index_u64 ~nbytes:8 in
  let r_validator = leaf_uint_le validator_index_u64 ~nbytes:8 in
  let addr_raw = be_of_bigint_fixed address_b20 ~len:20 in
  let addr_leafs = chunkize_bytevector_fixed addr_raw ~len:20 in
  let r_address = merkleize_leaves addr_leafs in
  let r_amount = leaf_uint_le amount_u64 ~nbytes:8 in
  let leaves = [| r_index; r_validator; r_address; r_amount |] in
  let root_bytes = merkleize_vector_roots leaves in
  Ok root_bytes

(* (* ----- hash_tree_root_withdrawals(withdrawal*) : root ----- *)
let hash_tree_root_withdrawals ~at (ws : Value.t list) : (Value.t, Err.t) result
    =
  let rec mapM f = function
    | [] -> Ok []
    | x :: xs ->
        let* y = f x in
        let* ys = mapM f xs in
        Ok (y :: ys)
  in
  let* leaves_list = mapM (htr_withdrawal_container ~at) ws in
  let leaves = Array.of_list leaves_list in
  let root_vec = merkleize_leaves leaves in
  let root_final =
    mix_in_length root_vec (Bigint.of_int (Array.length leaves))
  in
  Ok (Value.nat (bigint_of_be_bytes root_final))

(* ----- hash_tree_root_eth1Data(eth1Data) : root ----- *)
let hash_tree_root_eth1Data ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let* deposit_root_b32, deposit_count_u64, block_hash_b32 =
    match v.it with
    | StructV [ (_, v_dr); (_, v_dc); (_, v_bh) ]
    | TupleV [ v_dr; v_dc; v_bh ]
    | ListV [ v_dr; v_dc; v_bh ] ->
        Ok (get_nat v_dr, get_nat v_dc, get_nat v_bh)
    | _ -> Error (Err.runtime at "eth1Data: unexpected shape")
  in
  let* () = ensure_fits_bytes ~at deposit_root_b32 ~len:32 in
  let* () = ensure_fits_bytes ~at deposit_count_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at block_hash_b32 ~len:32 in
  let r_deposit_root = leaf_bytes32 deposit_root_b32 in
  let r_deposit_count = leaf_uint_le deposit_count_u64 ~nbytes:8 in
  let r_block_hash = leaf_bytes32 block_hash_b32 in
  let field_roots = [| r_deposit_root; r_deposit_count; r_block_hash |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_executionPayload(executionPayload) : root ----- *)
let hash_tree_root_executionPayload ~at (v : Value.t) : (Value.t, Err.t) result
    =
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  let get_bytes_len v = v |> Il.Value.get_bytes in
  (* 15 fields *)
  let* temp =
    match v.it with
    | StructV
        [
          (_, v1);
          (_, v2);
          (_, v3);
          (_, v4);
          (_, v5);
          (_, v6);
          (_, v7);
          (_, v8);
          (_, v9);
          (_, v10);
          (_, v11);
          (_, v12);
          (_, v13);
          (_, v14);
          (_, v15);
        ]
    | TupleV
        [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15 ]
    | ListV [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15 ]
      ->
        Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15)
    | _ -> Error (Err.runtime at "executionPayload: unexpected value shape")
  in
  let ( parent_hash,
        fee_recipient,
        state_root,
        receipts_root,
        logs_bloom,
        prev_randao,
        block_number,
        gas_limit,
        gas_used,
        timestamp,
        extra_data,
        base_fee_per_gas,
        block_hash,
        transactions,
        withdrawals ) =
    temp
  in
  (* 1. parent_hash: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat parent_hash) ~len:32 in
  let r_parent_hash = leaf_bytes32 (get_nat parent_hash) in
  (* 2. fee_recipient (ExecutionAddress): ByteVector[20] *)
  let* () = ensure_fits_bytes ~at (get_nat fee_recipient) ~len:20 in
  let fr_bytes = be_of_bigint_fixed (get_nat fee_recipient) ~len:20 in
  let r_fee_recipient =
    chunkize_bytevector_fixed fr_bytes ~len:20 |> merkleize_leaves
  in
  (* 3. state_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat state_root) ~len:32 in
  let r_state_root = leaf_bytes32 (get_nat state_root) in
  (* 4. receipts_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat receipts_root) ~len:32 in
  let r_receipts_root = leaf_bytes32 (get_nat receipts_root) in
  (* 5. logs_bloom: ByteVector[256] *)
  let* () = ensure_fits_bytes ~at (get_nat logs_bloom) ~len:256 in
  let lb_bytes = be_of_bigint_fixed (get_nat logs_bloom) ~len:256 in
  let r_logs_bloom =
    chunkize_bytevector_fixed lb_bytes ~len:256 |> merkleize_leaves
  in
  (* 6. prev_randao: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat prev_randao) ~len:32 in
  let r_prev_randao = leaf_bytes32 (get_nat prev_randao) in
  (* 7. block_number: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat block_number) ~len:8 in
  let r_block_number = leaf_uint_le (get_nat block_number) ~nbytes:8 in
  (* 8. gas_limit: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat gas_limit) ~len:8 in
  let r_gas_limit = leaf_uint_le (get_nat gas_limit) ~nbytes:8 in
  (* 9. gas_used: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat gas_used) ~len:8 in
  let r_gas_used = leaf_uint_le (get_nat gas_used) ~nbytes:8 in
  (* 10. timestamp: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat timestamp) ~len:8 in
  let r_timestamp = leaf_uint_le (get_nat timestamp) ~nbytes:8 in
  (* 11. extra_data: ByteList[<=32], mix_in_length 적용 *)
  let extra_raw, extra_len = get_bytes_len extra_data in
  let extra_bytes = be_of_bigint_fixed extra_raw ~len:extra_len in
  let extra_leaves = chunkize_bytes_bytev extra_bytes in
  let extra_root = merkleize_leaves extra_leaves in
  let r_extra_data = mix_in_length extra_root (Bigint.of_int extra_len) in
  (* 12. base_fee_per_gas: uint256, 32B LE *)
  let* () = ensure_fits_bytes ~at (get_nat base_fee_per_gas) ~len:32 in
  let r_base_fee = leaf_uint_le (get_nat base_fee_per_gas) ~nbytes:32 in
  (* 13. block_hash: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat block_hash) ~len:32 in
  let r_block_hash = leaf_bytes32 (get_nat block_hash) in
  (* 14. transactions: ListV ByteList, tx별로 mix_in_length → 모아서 merkleize → 전체 거래 개수로 mix_in_length *)
  let get_list v = match v.it with ListV xs -> xs | _ -> [] in
  let txs = get_list transactions in
  let tx_elem_root tx =
    let data, len = get_bytes_len tx in
    let data_bytes = be_of_bigint_fixed data ~len in
    let chunks = chunkize_bytes_bytev data_bytes in
    let root = merkleize_leaves chunks in
    mix_in_length root (Bigint.of_int len)
  in
  let tx_roots = List.map tx_elem_root txs |> Array.of_list in
  let root_tx_vec = merkleize_leaves tx_roots in
  let r_transactions =
    mix_in_length root_tx_vec (Bigint.of_int (Array.length tx_roots))
  in
  (* 15. withdrawals: hash_tree_root_withdrawals에 위임 *)
  let ws = get_list withdrawals in
  let* r_withdrawals_v = hash_tree_root_withdrawals ~at ws in
  let r_withdrawals =
    match r_withdrawals_v.it with
    | NumV n -> leaf_bytes32 (Num.to_int n)
    | _ -> zero32
  in
  (* 정해진 순서로 배열 *)
  let field_roots =
    [|
      r_parent_hash;
      r_fee_recipient;
      r_state_root;
      r_receipts_root;
      r_logs_bloom;
      r_prev_randao;
      r_block_number;
      r_gas_limit;
      r_gas_used;
      r_timestamp;
      r_extra_data;
      r_base_fee;
      r_block_hash;
      r_transactions;
      r_withdrawals;
    |]
  in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_BLSToExecutionChange(message) : root ----- *)
let hash_tree_root_BLSToExecutionChange ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_index); (_, v_pubkey); (_, v_addr) ]
    | TupleV [ v_index; v_pubkey; v_addr ]
    | ListV [ v_index; v_pubkey; v_addr ] ->
        Ok (v_index, v_pubkey, v_addr)
    | _ -> Error (Err.runtime at "BLSToExecutionChange: unexpected value shape")
  in
  let validator_index, from_bls_pubkey, to_execution_address = temp in
  let* () = ensure_fits_bytes ~at (get_nat validator_index) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat from_bls_pubkey) ~len:48 in
  let* () = ensure_fits_bytes ~at (get_nat to_execution_address) ~len:20 in
  let r_index = leaf_uint_le (get_nat validator_index) ~nbytes:8 in
  let pubkey_bytes = be_of_bigint_fixed (get_nat from_bls_pubkey) ~len:48 in
  let r_pubkey =
    chunkize_bytevector_fixed pubkey_bytes ~len:48 |> merkleize_leaves
  in
  let addr_bytes = be_of_bigint_fixed (get_nat to_execution_address) ~len:20 in
  let r_addr =
    chunkize_bytevector_fixed addr_bytes ~len:20 |> merkleize_leaves
  in
  let field_roots = [| r_index; r_pubkey; r_addr |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_SignedBLSToExecutionChange(signed) : root ----- *)
let hash_tree_root_SignedBLSToExecutionChange ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_msg); (_, v_sig) ]
    | TupleV [ v_msg; v_sig ]
    | ListV [ v_msg; v_sig ] ->
        Ok (v_msg, v_sig)
    | _ ->
        Error
          (Err.runtime at "SignedBLSToExecutionChange: unexpected value shape")
  in
  let message, signature = temp in
  (* message: BLSToExecutionChange *)
  let* msg_root_v = hash_tree_root_BLSToExecutionChange ~at message in
  let msg_root =
    match msg_root_v.it with
    | NumV n -> leaf_bytes32 (Num.to_int n)
    | _ -> zero32
  in
  (* signature: BLSSignature(96) → ByteVector[96] *)
  let* () = ensure_fits_bytes ~at (get_nat signature) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat signature) ~len:96 in
  let sig_root =
    chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves
  in
  let field_roots = [| msg_root; sig_root |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

let pack_bits_lsb_first (lst : Value.t list) : Bytes.t =
  let arr = Array.make 64 0 in
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  List.iteri
    (fun i b ->
      let v = bigint_to_int (get_nat b) in
      if v <> 0 then arr.(i / 8) <- arr.(i / 8) lor (1 lsl (i mod 8)) else ())
    lst;
  Bytes.init 64 (fun i -> Stdlib.Char.chr arr.(i))

(* ----- hash_tree_root_SyncAggregate(syncAggregate) : root ----- *)
let hash_tree_root_SyncAggregate ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_bits); (_, v_sig) ]
    | TupleV [ v_bits; v_sig ]
    | ListV [ v_bits; v_sig ] ->
        Ok (v_bits, v_sig)
    | _ -> Error (Err.runtime at "SyncAggregate: unexpected value shape")
  in
  let v_bits, v_sig = temp in
  (* bits: Bitvector[512] 패킹 *)
  let bits_bytes =
    match v_bits.it with
    | ListV lst when List.length lst = 512 -> pack_bits_lsb_first lst
    | _ -> Bytes.make 64 '\x00'
  in
  let r_bits =
    chunkize_bytevector_fixed bits_bytes ~len:64 |> merkleize_leaves
  in
  (* signature: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat v_sig) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat v_sig) ~len:96 in
  let r_sig = chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves in
  let field_roots = [| r_bits; r_sig |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_VoluntaryExit(voluntaryExit) : root ----- *)
let hash_tree_root_VoluntaryExit ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_epoch); (_, v_validator) ]
    | TupleV [ v_epoch; v_validator ]
    | ListV [ v_epoch; v_validator ] ->
        Ok (v_epoch, v_validator)
    | _ -> Error (Err.runtime at "VoluntaryExit: unexpected value shape")
  in
  let epoch, validator_index = temp in
  let* () = ensure_fits_bytes ~at (get_nat epoch) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat validator_index) ~len:8 in
  let r_epoch = leaf_uint_le (get_nat epoch) ~nbytes:8 in
  let r_validator = leaf_uint_le (get_nat validator_index) ~nbytes:8 in
  let field_roots = [| r_epoch; r_validator |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_SignedVoluntaryExit(signed) : root ----- *)
let hash_tree_root_SignedVoluntaryExit ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_msg); (_, v_sig) ]
    | TupleV [ v_msg; v_sig ]
    | ListV [ v_msg; v_sig ] ->
        Ok (v_msg, v_sig)
    | _ -> Error (Err.runtime at "SignedVoluntaryExit: unexpected value shape")
  in
  let message, signature = temp in
  (* message: VoluntaryExit *)
  let* msg_root_v = hash_tree_root_VoluntaryExit ~at message in
  let msg_root =
    match msg_root_v.it with
    | NumV n -> leaf_bytes32 (Num.to_int n)
    | _ -> zero32
  in
  (* signature: BLSSignature(96) → ByteVector[96] *)
  let* () = ensure_fits_bytes ~at (get_nat signature) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat signature) ~len:96 in
  let sig_root =
    chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves
  in
  let field_roots = [| msg_root; sig_root |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_Deposit(deposit) : root ----- *)
let hash_tree_root_Deposit ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let get_list v = match v.it with ListV xs -> xs | _ -> [] in
  let* temp =
    match v.it with
    | StructV [ (_, v_proof); (_, v_data) ]
    | TupleV [ v_proof; v_data ]
    | ListV [ v_proof; v_data ] ->
        Ok (v_proof, v_data)
    | _ -> Error (Err.runtime at "Deposit: unexpected value shape")
  in
  let proof_v, data_v = temp in
  (* 1. proof: Vector[Bytes32, N+1] *)
  let proof_list = get_list proof_v in
  let leaves =
    proof_list |> List.map (fun x -> leaf_bytes32 (get_nat x)) |> Array.of_list
  in
  let r_proof = merkleize_leaves leaves in
  (* 2. data: DepositData *)
  let* r_data_v = hash_tree_root_depositData ~at data_v in
  let r_data =
    match r_data_v.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  let field_roots = [| r_proof; r_data |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_Checkpoint(checkpoint) : root ----- *)
let hash_tree_root_Checkpoint ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_epoch); (_, v_root) ]
    | TupleV [ v_epoch; v_root ]
    | ListV [ v_epoch; v_root ] ->
        Ok (v_epoch, v_root)
    | _ -> Error (Err.runtime at "Checkpoint: unexpected value shape")
  in
  let epoch, root = temp in
  let* () = ensure_fits_bytes ~at (get_nat epoch) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat root) ~len:32 in
  let r_epoch = leaf_uint_le (get_nat epoch) ~nbytes:8 in
  let r_root = leaf_bytes32 (get_nat root) in
  let field_roots = [| r_epoch; r_root |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_AttestationData(ad) : root ----- *)
let hash_tree_root_AttestationData ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV
        [ (_, v_slot); (_, v_index); (_, v_bbr); (_, v_source); (_, v_target) ]
    | TupleV [ v_slot; v_index; v_bbr; v_source; v_target ]
    | ListV [ v_slot; v_index; v_bbr; v_source; v_target ] ->
        Ok (v_slot, v_index, v_bbr, v_source, v_target)
    | _ -> Error (Err.runtime at "AttestationData: unexpected value shape")
  in
  let slot, index, beacon_block_root, source, target = temp in
  let* () = ensure_fits_bytes ~at (get_nat slot) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat index) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat beacon_block_root) ~len:32 in
  let r_slot = leaf_uint_le (get_nat slot) ~nbytes:8 in
  let r_index = leaf_uint_le (get_nat index) ~nbytes:8 in
  let r_bbr = leaf_bytes32 (get_nat beacon_block_root) in
  let* r_source_v = hash_tree_root_Checkpoint ~at source in
  let r_source =
    match r_source_v.it with
    | NumV n -> leaf_bytes32 (Num.to_int n)
    | _ -> zero32
  in
  let* r_target_v = hash_tree_root_Checkpoint ~at target in
  let r_target =
    match r_target_v.it with
    | NumV n -> leaf_bytes32 (Num.to_int n)
    | _ -> zero32
  in
  let field_roots = [| r_slot; r_index; r_bbr; r_source; r_target |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_Attestation(attestation) : root ----- *)
let hash_tree_root_Attestation ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_bits); (_, v_data); (_, v_sig) ]
    | TupleV [ v_bits; v_data; v_sig ]
    | ListV [ v_bits; v_data; v_sig ] ->
        Ok (v_bits, v_data, v_sig)
    | _ -> Error (Err.runtime at "Attestation: unexpected value shape")
  in
  let v_bits, v_data, v_sig = temp in
  (* aggregation_bits: Bitlist -> 바이트 LSB-first 패킹 + chunk + mix_in_length(비트수) *)
  let bit_bytes, bitlen =
    match v_bits.it with
    | ListV lst ->
        let bitlen = List.length lst in
        let arr = Array.make ((bitlen + 7) / 8) 0 in
        List.iteri
          (fun i b ->
            let v = bigint_to_int (get_nat b) in
            if v <> 0 then arr.(i / 8) <- arr.(i / 8) lor (1 lsl (i mod 8))
            else ())
          lst;
        ( Bytes.init ((bitlen + 7) / 8) (fun i -> Stdlib.Char.chr arr.(i)),
          bitlen )
    | _ -> (Bytes.make 0 '\x00', 0)
  in
  let bit_chunks = chunkize_bytes_bytev bit_bytes in
  let bit_root = merkleize_leaves bit_chunks in
  let r_bits = mix_in_length bit_root (Bigint.of_int bitlen) in
  (* data: AttestationData *)
  let* r_data_v = hash_tree_root_AttestationData ~at v_data in
  let r_data =
    match r_data_v.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  (* signature: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat v_sig) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat v_sig) ~len:96 in
  let r_sig = chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves in
  let field_roots = [| r_bits; r_data; r_sig |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_IndexedAttestation(indexedAttestation) : root ----- *)
let hash_tree_root_IndexedAttestation ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let get_list v = match v.it with ListV xs -> xs | _ -> [] in
  let* temp =
    match v.it with
    | StructV [ (_, v_indices); (_, v_data); (_, v_sig) ]
    | TupleV [ v_indices; v_data; v_sig ]
    | ListV [ v_indices; v_data; v_sig ] ->
        Ok (v_indices, v_data, v_sig)
    | _ -> Error (Err.runtime at "IndexedAttestation: unexpected value shape")
  in
  let v_indices, v_data, v_sig = temp in
  (* indices: List[uint64], 리스트 SSZ 규칙(mix_in_length) *)
  let indices = get_list v_indices in
  let leaves =
    indices
    |> List.map (fun idx -> leaf_uint_le (get_nat idx) ~nbytes:8)
    |> Array.of_list
  in
  let root_indices = merkleize_leaves leaves in
  let r_indices =
    mix_in_length root_indices (Bigint.of_int (Array.length leaves))
  in
  (* data: AttestationData *)
  let* r_data_v = hash_tree_root_AttestationData ~at v_data in
  let r_data =
    match r_data_v.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  (* signature: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat v_sig) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat v_sig) ~len:96 in
  let r_sig = chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves in
  let field_roots = [| r_indices; r_data; r_sig |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_AttesterSlashing(attesterSlashing) : root ----- *)
let hash_tree_root_AttesterSlashing ~at (v : Value.t) : (Value.t, Err.t) result
    =
  let* temp =
    match v.it with
    | StructV [ (_, a1); (_, a2) ] | TupleV [ a1; a2 ] | ListV [ a1; a2 ] ->
        Ok (a1, a2)
    | _ -> Error (Err.runtime at "AttesterSlashing: unexpected value shape")
  in
  let attestation_1, attestation_2 = temp in
  let* r_a1_v = hash_tree_root_IndexedAttestation ~at attestation_1 in
  let r_a1 =
    match r_a1_v.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  let* r_a2_v = hash_tree_root_IndexedAttestation ~at attestation_2 in
  let r_a2 =
    match r_a2_v.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  let field_roots = [| r_a1; r_a2 |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_SignedBeaconBlockHeader(signed) : root ----- *)
let hash_tree_root_SignedBeaconBlockHeader ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_msg); (_, v_sig) ]
    | TupleV [ v_msg; v_sig ]
    | ListV [ v_msg; v_sig ] ->
        Ok (v_msg, v_sig)
    | _ ->
        Error (Err.runtime at "SignedBeaconBlockHeader: unexpected value shape")
  in
  let message, signature = temp in
  (* message: BeaconBlockHeader *)
  let* msg_root_v = hash_tree_root_beaconBlockHeader ~at message in
  let r_message =
    match msg_root_v.it with
    | NumV n -> leaf_bytes32 (Num.to_int n)
    | _ -> zero32
  in
  (* signature: BLSSignature(96) → ByteVector[96] *)
  let* () = ensure_fits_bytes ~at (get_nat signature) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat signature) ~len:96 in
  let r_signature =
    chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves
  in
  let field_roots = [| r_message; r_signature |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_ProposerSlashing(proposerSlashing) : root ----- *)
let hash_tree_root_ProposerSlashing ~at (v : Value.t) : (Value.t, Err.t) result
    =
  let* temp =
    match v.it with
    | StructV [ (_, sh1); (_, sh2) ] | TupleV [ sh1; sh2 ] | ListV [ sh1; sh2 ]
      ->
        Ok (sh1, sh2)
    | _ -> Error (Err.runtime at "ProposerSlashing: unexpected value shape")
  in
  let signed_header_1, signed_header_2 = temp in
  let* r_sh1_v = hash_tree_root_SignedBeaconBlockHeader ~at signed_header_1 in
  let r_sh1 =
    match r_sh1_v.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  let* r_sh2_v = hash_tree_root_SignedBeaconBlockHeader ~at signed_header_2 in
  let r_sh2 =
    match r_sh2_v.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  let field_roots = [| r_sh1; r_sh2 |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

(* ----- hash_tree_root_beaconBlockBody(beaconBlockBody) : root ----- *)
let hash_tree_root_beaconBlockBody ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Il.Value.get_num |> Num.to_int in
  let get_list vv = match vv.it with ListV xs -> xs | _ -> [] in
  let to_b32 (rv : Value.t) : Bytes.t =
    match rv.it with NumV n -> leaf_bytes32 (Num.to_int n) | _ -> zero32
  in
  let* ( randao_reveal,
         eth1_data,
         graffiti,
         proposer_slashings,
         attester_slashings,
         attestations,
         deposits,
         voluntary_exits,
         sync_aggregate,
         execution_payload,
         bls_to_execution_changes ) =
    match v.it with
    | StructV
        [
          (_, a1);
          (_, a2);
          (_, a3);
          (_, a4);
          (_, a5);
          (_, a6);
          (_, a7);
          (_, a8);
          (_, a9);
          (_, a10);
          (_, a11);
        ]
    | TupleV [ a1; a2; a3; a4; a5; a6; a7; a8; a9; a10; a11 ]
    | ListV [ a1; a2; a3; a4; a5; a6; a7; a8; a9; a10; a11 ] ->
        Ok (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
    | _ -> Error (Err.runtime at "beaconBlockBody: unexpected value shape")
  in
  (* 1) randao_reveal: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat randao_reveal) ~len:96 in
  let sig96 = be_of_bigint_fixed (get_nat randao_reveal) ~len:96 in
  let r_randao = chunkize_bytevector_fixed sig96 ~len:96 |> merkleize_leaves in
  (* 2) eth1_data *)
  let* r_eth1_v = hash_tree_root_eth1Data ~at eth1_data in
  let r_eth1 = to_b32 r_eth1_v in
  (* 3) graffiti: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat graffiti) ~len:32 in
  let r_graffiti = leaf_bytes32 (get_nat graffiti) in
  (* 리스트 공통 헬퍼 *)
  let list_htr (xs : Value.t list) (f : Value.t -> (Value.t, Err.t) result) :
      (Bytes.t, Err.t) result =
    let rec mapM acc = function
      | [] -> Ok (List.rev acc)
      | x :: tl ->
          let* rv = f x in
          mapM (to_b32 rv :: acc) tl
    in
    let* leaves_list = mapM [] xs in
    let arr = Array.of_list leaves_list in
    let vec_root = merkleize_leaves arr in
    Ok (mix_in_length vec_root (Bigint.of_int (Array.length arr)))
  in
  let* r_prop_slash =
    list_htr (get_list proposer_slashings) (hash_tree_root_ProposerSlashing ~at)
  in
  let* r_att_slash =
    list_htr (get_list attester_slashings) (hash_tree_root_AttesterSlashing ~at)
  in
  let* r_attest =
    list_htr (get_list attestations) (hash_tree_root_Attestation ~at)
  in
  let* r_deposits = list_htr (get_list deposits) (hash_tree_root_Deposit ~at) in
  let* r_vol =
    list_htr (get_list voluntary_exits) (hash_tree_root_SignedVoluntaryExit ~at)
  in
  let* r_sync_v = hash_tree_root_SyncAggregate ~at sync_aggregate in
  let r_sync = to_b32 r_sync_v in
  let* r_exec_v = hash_tree_root_executionPayload ~at execution_payload in
  let r_exec = to_b32 r_exec_v in
  let* r_bls2exec =
    list_htr
      (get_list bls_to_execution_changes)
      (hash_tree_root_SignedBLSToExecutionChange ~at)
  in
  let field_roots =
    [|
      r_randao;
      r_eth1;
      r_graffiti;
      r_prop_slash;
      r_att_slash;
      r_attest;
      r_deposits;
      r_vol;
      r_sync;
      r_exec;
      r_bls2exec;
    |]
  in
  let root_bytes = merkleize_leaves field_roots in
  Ok (Value.nat (bigint_of_be_bytes root_bytes))

let builtins : (string * Define.t) list =
  [
    ( "is_valid_merkle_branch",
      Define.T0.a5 Arg.nat (Arg.list_of Arg.nat) Arg.nat Arg.nat Arg.nat
        is_valid_merkle_branch );
    ( "hash_tree_root_roots",
      Define.T0.a1 (Arg.list_of Arg.nat) hash_tree_root_roots );
    ("hash_tree_root_tx", Define.T0.a1 (Arg.list_of Arg.nat) hash_tree_root_tx);
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
  ]
