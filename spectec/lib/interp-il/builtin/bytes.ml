open Il
open Util.Source
open Value

let ( let* ) = Result.bind

(* Built-in implementations *)

(* Helper functions for byte validation *)

let validate_bytes32 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let bytes32_max = Bigint.(pow (of_int 2) (of_int 256)) in
  if Bigint.(x >= zero && x < bytes32_max) then
    Ok ()
  else
    Error (Err.runtime at "bytes32: value must be in range [0, 2^256)")

let validate_bytes31 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let bytes31_max = Bigint.(pow (of_int 2) (of_int 248)) in
  if Bigint.(x >= zero && x < bytes31_max) then
    Ok ()
  else
    Error (Err.runtime at "bytes31: value must be in range [0, 2^248)")

let validate_bytes28 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let bytes28_max = Bigint.(pow (of_int 2) (of_int 224)) in
  if Bigint.(x >= zero && x < bytes28_max) then
    Ok ()
  else
    Error (Err.runtime at "bytes28: value must be in range [0, 2^224)")

let validate_bytes20 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let bytes20_max = Bigint.(pow (of_int 2) (of_int 160)) in
  if Bigint.(x >= zero && x < bytes20_max) then
    Ok ()
  else
    Error (Err.runtime at "bytes20: value must be in range [0, 2^160)")

let validate_bytes4 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let bytes4_max = Bigint.(pow (of_int 2) (of_int 32)) in
  if Bigint.(x >= zero && x < bytes4_max) then
    Ok ()
  else
    Error (Err.runtime at "bytes4: value must be in range [0, 2^32)")

let validate_bytes1 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let bytes1_max = Bigint.(pow (of_int 2) (of_int 8)) in
  if Bigint.(x >= zero && x < bytes1_max) then
    Ok ()
  else
    Error (Err.runtime at "bytes1: value must be in range [0, 2^8)")

let validate_uint8 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let uint8_max = Bigint.(pow (of_int 2) (of_int 8)) in
  if Bigint.(x >= zero && x < uint8_max) then
    Ok ()
  else
    Error (Err.runtime at "uint8: value must be in range [0, 2^8)")

let validate_uint32 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let uint32_max = Bigint.(pow (of_int 2) (of_int 32)) in
  if Bigint.(x >= zero && x < uint32_max) then
    Ok ()
  else
    Error (Err.runtime at "uint32: value must be in range [0, 2^32)")

let validate_uint64 (at : Util.Source.region) (x : Bigint.t) : (unit, Err.t) result =
  let uint64_max = Bigint.(pow (of_int 2) (of_int 64)) in
  if Bigint.(x >= zero && x < uint64_max) then
    Ok ()
  else
    Error (Err.runtime at "uint64: value must be in range [0, 2^64)")

(* dec $bytes_to_uint64(bytes32) : uint64 *)

let bytes_to_uint64 ~at (bytes32_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  (* Extract first 8 bytes (MSB 8 bytes) from bytes32 and interpret as little-endian *)
  (* Python: int.from_bytes(data[:8], 'little') *)
  (* Extract each byte from data[0..7] (MSB 8 bytes) *)
  let byte i =
    (* i = 0..7: data[i], MSB부터 i번째 바이트 *)
    let shift_bits = (31 - i) * 8 in
    Bigint.(bit_and (shift_right bytes32_val shift_bits) (of_int 0xff))
  in
  (* Little-endian combination: sum_{i=0..7} byte(i) * 256^i *)
  let rec loop i acc p =
    if i = 8 then acc
    else 
      let next_i = i + 1 in
      let open Bigint in
      let byte_val = byte i in
      let acc_new = acc + (byte_val * p) in
      let p_new = p * (of_int 256) in
      loop next_i acc_new p_new
  in
  let open Bigint in
  let uint64_val = loop 0 zero (of_int 1) in
  Ok (Value.nat uint64_val)

(* dec $uint_to_bytes(uint) : bytes *)

let uint_to_bytes ~at (uint_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  if Bigint.(uint_val < zero) then
    Error (Err.runtime at "uint_to_bytes: input must be non-negative")
  else
    (* Determine the appropriate uint type based on value range *)
    (* This mimics Python's encode_bytes() behavior for uint8/uint32/uint64 *)
    if Bigint.(uint_val < pow (of_int 2) (of_int 8)) then
      (* uint8 range: [0, 2^8) *)
      let* () = validate_uint8 at uint_val in
      Ok (make_bytes ~num:uint_val ~len:1)
    else if Bigint.(uint_val < pow (of_int 2) (of_int 32)) then
      (* uint32 range: [0, 2^32) *)
      let* () = validate_uint32 at uint_val in
      Ok (make_bytes ~num:uint_val ~len:4)
    else if Bigint.(uint_val < pow (of_int 2) (of_int 64)) then
      (* uint64 range: [0, 2^64) *)
      let* () = validate_uint64 at uint_val in
      Ok (make_bytes ~num:uint_val ~len:8)
    else
      Error (Err.runtime at "uint_to_bytes: value too large for uint8/uint32/uint64")

(* dec $xor(bytes32, bytes32) : bytes32 *)

let xor ~at (bytes32_a : Bigint.t) (bytes32_b : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_a in
  let* () = validate_bytes32 at bytes32_b in
  let result = Bigint.bit_xor bytes32_a bytes32_b in
  Ok (Value.nat result)

(* dec $first_28_bytes(bytes32) : bytes28 *)

let first_28_bytes ~at (bytes32_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  (* Extract first 28 bytes (MSB 28 bytes) from bytes32 *)
  (* Python x[:28] - remove last 4 bytes (32 bits) *)
  let bytes28_val = Bigint.shift_right bytes32_val 32 in
  Ok (Value.nat bytes28_val)

(* dec $get_first_byte(bytes32) : bytes1 *)

let get_first_byte ~at (bytes32_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  (* Extract first byte (MSB 1 byte) from bytes32 *)
  (* Python x[:1] - extract MSB byte *)
  let msb_byte = Bigint.(shift_right bytes32_val 248 |> bit_and (of_int 0xff)) in
  Ok (Value.nat msb_byte)

(* dec $strip_first_byte(bytes32) : bytes31 *)

let strip_first_byte ~at (bytes32_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  (* Remove first byte (MSB 1 byte) from bytes32 *)
  (* Python x[1:] - remove MSB byte, keep remaining 31 bytes *)
  let mask_248 = Bigint.(pow (of_int 2) (of_int 248) - one) in
  let bytes31_val = Bigint.bit_and bytes32_val mask_248 in
  Ok (Value.nat bytes31_val)

(* dec $bytes32_to_bytes1_list(bytes32) : bytes1* *)

let bytes32_to_bytes1_list ~at (bytes32_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  (* Extract each byte from bytes32 *)
  let bytes1_list = 
    List.init 32 (fun i ->
      let shift_amount = (31 - i) * 8 in
      let byte_val = Bigint.shift_right bytes32_val shift_amount in
      let byte_val = Bigint.bit_and byte_val (Bigint.of_int 255) in
      Value.nat byte_val)
  in
  let typ = Util.Source.(Il.NumT `NatT $ no_region) in
  Ok (Value.list typ bytes1_list)

(* dec $bytes1_to_uint64(bytes1) : uint64 *)

let bytes1_to_uint64 ~at (bytes1_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes1 at bytes1_val in
  Ok (Value.nat bytes1_val)

(* dec $concat_bytes(bytes, bytes) : bytes *)

let concat_bytes ~at (value_a : Value.t) (value_b : Value.t) : (Value.t, Err.t) result =
  at |> ignore;
  match (value_a.it, value_b.it) with
  | BytesV {num=na; len=la}, BytesV {num=nb; len=lb} ->
      (* big-endian concat: (na || nb) == na * 256^(lb) + nb *)
      let shift_bits = 8 * lb in
      let shift = Bigint.(pow (of_int 2) (of_int shift_bits)) in
      let num = Bigint.(na * shift + nb) in
      Ok (make_bytes ~num ~len:(la + lb))
  | _ ->
      Error (Err.runtime at "concat_bytes: expected bytes values")

(* dec $concat_domain(domainType, bytes28) : domain *)

let concat_domain ~at (domain_type : Bigint.t) (bytes28_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  (* Validate domainType (bytes4) *)
  let* () = validate_bytes4 at domain_type in
  (* Validate bytes28 *)
  let* () = validate_bytes28 at bytes28_val in
  (* Concatenate: domainType (4 bytes) + bytes28 (28 bytes) = domain (32 bytes) *)
  (* Shift domain_type left by 28 bytes (224 bits) and add bytes28_val *)
  let result = Bigint.(shift_left domain_type 224 + bytes28_val) in
  (* Validate result is within bytes32 range *)
  let* () = validate_bytes32 at result in
  Ok (Value.nat result)

(* dec $bytes32_to_bytes(bytes32) : bytes *)

let bytes32_to_bytes ~at (bytes32_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  Ok (make_bytes ~num:bytes32_val ~len:32)

(* dec $bytes4_to_bytes(bytes4) : bytes *)

let bytes4_to_bytes ~at (bytes4_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes4 at bytes4_val in
  Ok (make_bytes ~num:bytes4_val ~len:4)

(* dec $make_withdrawal_credentials_eth1(executionAddress) : bytes32 *)

let make_withdrawal_credentials_eth1 ~at (execution_address : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  (* Validate executionAddress (bytes20) *)
  let* () = validate_bytes20 at execution_address in
  (* ETH1_ADDRESS_WITHDRAWAL_PREFIX = 0x01 (1 byte) *)
  let eth1_prefix = Bigint.of_int 0x01 in
  (* 0x00 * 11 = 11 zero bytes *)
  let zero_bytes_11 = Bigint.zero in
  (* Concatenate: 0x01 + 0x00*11 + executionAddress = 32 bytes *)
  (* Shift eth1_prefix left by 31 bytes (248 bits) *)
  let prefix_shifted = Bigint.shift_left eth1_prefix 248 in
  (* Shift zero_bytes_11 left by 20 bytes (160 bits) *)
  let zeros_shifted = Bigint.shift_left zero_bytes_11 160 in
  (* Final result: prefix + zeros + execution_address *)
  let result = Bigint.(prefix_shifted + zeros_shifted + execution_address) in
  (* Validate result is within bytes32 range *)
  let* () = validate_bytes32 at result in
  Ok (Value.nat result)

(* dec $extract_execution_address(bytes32) : executionAddress *)

let extract_execution_address ~at (bytes32_val : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  (* Extract last 20 bytes (160 bits) from bytes32 *)
  let bytes20_mask = Bigint.(pow (of_int 2) (of_int 160) - one) in
  let execution_address = Bigint.bit_and bytes32_val bytes20_mask in
  Ok (Value.nat execution_address)

let builtins : (string * Define.t) list =
  [
    ("bytes_to_uint64", Define.T0.a1 Arg.nat bytes_to_uint64);
    ("uint_to_bytes", Define.T0.a1 Arg.nat uint_to_bytes);
    ("xor", Define.T0.a2 Arg.nat Arg.nat xor);
    ("concat_domain", Define.T0.a2 Arg.nat Arg.nat concat_domain);
    ("make_withdrawal_credentials_eth1", Define.T0.a1 Arg.nat make_withdrawal_credentials_eth1);
    ("first_28_bytes", Define.T0.a1 Arg.nat first_28_bytes);
    ("get_first_byte", Define.T0.a1 Arg.nat get_first_byte);
    ("strip_first_byte", Define.T0.a1 Arg.nat strip_first_byte);
    ("bytes32_to_bytes1_list", Define.T0.a1 Arg.nat bytes32_to_bytes1_list);
    ("bytes1_to_uint64", Define.T0.a1 Arg.nat bytes1_to_uint64);
    ("concat_bytes", Define.T0.a2 Arg.value Arg.value concat_bytes);
    ("bytes32_to_bytes", Define.T0.a1 Arg.nat bytes32_to_bytes);
    ("bytes4_to_bytes", Define.T0.a1 Arg.nat bytes4_to_bytes);
    ("extract_execution_address", Define.T0.a1 Arg.nat extract_execution_address);
  ]
