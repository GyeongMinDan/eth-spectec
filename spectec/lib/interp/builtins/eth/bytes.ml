open Common.Source
open Lang.Xl
module Value = Lang.Il.Value
open Value
module Bytes = Stdlib.Bytes
open Define.Error
module Arg = Define.Arg

let ( let* ) = Result.bind

(* Built-in implementations *)

(* Helper functions for byte conversion *)
let be_of_bigint_fixed (n : Bigint.t) ~(len : int) : Bytes.t =
  if Bigint.(n < zero) then invalid_arg "negative";
  let out = Bytes.create len in
  let rec fill i v =
    if i < 0 then ()
    else
      let byte = Bigint.to_int_exn Bigint.(v % of_int 256) in
      Bytes.set out i (Char.chr byte);
      fill (i - 1) Bigint.(v / of_int 256)
  in
  fill (len - 1) n;
  out

let bigint_of_be_bytes (b : Bytes.t) : Bigint.t =
  let acc = ref Bigint.zero in
  for i = 0 to Bytes.length b - 1 do
    let v = Char.code (Bytes.get b i) in
    acc := Bigint.((!acc * of_int 256) + of_int v)
  done;
  !acc

(* Helper functions for byte validation *)

let validate_bytes32 (at : region) (x : Bigint.t) : unit result =
  let bytes32_max = Bigint.(pow (of_int 2) (of_int 256)) in
  if Bigint.(x >= zero && x < bytes32_max) then Ok ()
  else Error (runtime at "bytes32: value must be in range [0, 2^256)")

let validate_bytes31 (at : region) (x : Bigint.t) : unit result =
  let bytes31_max = Bigint.(pow (of_int 2) (of_int 248)) in
  if Bigint.(x >= zero && x < bytes31_max) then Ok ()
  else Error (runtime at "bytes31: value must be in range [0, 2^248)")

let validate_bytes28 (at : region) (x : Bigint.t) : unit result =
  let bytes28_max = Bigint.(pow (of_int 2) (of_int 224)) in
  if Bigint.(x >= zero && x < bytes28_max) then Ok ()
  else Error (runtime at "bytes28: value must be in range [0, 2^224)")

let validate_bytes20 (at : region) (x : Bigint.t) : unit result =
  let bytes20_max = Bigint.(pow (of_int 2) (of_int 160)) in
  if Bigint.(x >= zero && x < bytes20_max) then Ok ()
  else Error (runtime at "bytes20: value must be in range [0, 2^160)")

let validate_bytes4 (at : region) (x : Bigint.t) : unit result =
  let bytes4_max = Bigint.(pow (of_int 2) (of_int 32)) in
  if Bigint.(x >= zero && x < bytes4_max) then Ok ()
  else Error (runtime at "bytes4: value must be in range [0, 2^32)")

let validate_bytes1 (at : region) (x : Bigint.t) : unit result =
  let bytes1_max = Bigint.(pow (of_int 2) (of_int 8)) in
  if Bigint.(x >= zero && x < bytes1_max) then Ok ()
  else Error (runtime at "bytes1: value must be in range [0, 2^8)")

let validate_uint8 (at : region) (x : Bigint.t) : unit result =
  let uint8_max = Bigint.(pow (of_int 2) (of_int 8)) in
  if Bigint.(x >= zero && x < uint8_max) then Ok ()
  else Error (runtime at "uint8: value must be in range [0, 2^8)")

let validate_uint32 (at : region) (x : Bigint.t) : unit result =
  let uint32_max = Bigint.(pow (of_int 2) (of_int 32)) in
  if Bigint.(x >= zero && x < uint32_max) then Ok ()
  else Error (runtime at "uint32: value must be in range [0, 2^32)")

let validate_uint64 (at : region) (x : Bigint.t) : unit result =
  let uint64_max = Bigint.(pow (of_int 2) (of_int 64)) in
  if Bigint.(x >= zero && x < uint64_max) then Ok ()
  else Error (runtime at "uint64: value must be in range [0, 2^64)")

(* dec $bytes_to_uint64(bytes32) : uint64 *)
(* not used *)
let bytes_to_uint64 ~at (bytes32_val : Num.t) : Value.t result =
  let bytes32_val = Num.to_int bytes32_val in
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
      let p_new = p * of_int 256 in
      loop next_i acc_new p_new
  in
  let open Bigint in
  let uint64_val = loop 0 zero (of_int 1) in
  Ok (Value.nat uint64_val)

(* dec $uint_to_bytes(uint) : bytes *)

let uint_to_bytes ~at (uint_val : Num.t) : Value.t result =
  let uint_val = Num.to_int uint_val in
  at |> ignore;
  if Bigint.(uint_val < zero) then
    Error (runtime at "uint_to_bytes: input must be non-negative")
  else if
    (* Determine the appropriate uint type based on value range *)
    (* This mimics Python's encode_bytes() behavior for uint8/uint32/uint64 *)
    Bigint.(uint_val < pow (of_int 2) (of_int 8))
  then
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
    Error (runtime at "uint_to_bytes: value too large for uint8/uint32/uint64")

(* dec $xor(bytes32, bytes32) : bytes32 *)

let xor ~at (bytes32_a : Num.t) (bytes32_b : Num.t) : Value.t result =
  let bytes32_a = Num.to_int bytes32_a in
  let bytes32_b = Num.to_int bytes32_b in
  at |> ignore;
  let* () = validate_bytes32 at bytes32_a in
  let* () = validate_bytes32 at bytes32_b in
  let result = Bigint.bit_xor bytes32_a bytes32_b in
  Ok (make_bytes ~num:result ~len:32)

(* dec $first_28_bytes(bytes32) : bytes28 *)

let first_28_bytes ~at (value : Value.t) : Value.t result =
  at |> ignore;
  let* bytes32_val =
    match value.it with
    | BytesV { num; len = 32 } -> Ok num
    | BytesV { num; len = _ } ->
        let* () = validate_bytes32 at num in
        Ok num
    | NumV n ->
        let bytes32_val = Num.to_int n in
        let* () = validate_bytes32 at bytes32_val in
        Ok bytes32_val
    | _ -> Error (runtime at "first_28_bytes: expected bytes32 or NumV")
  in
  (* Extract first 28 bytes (MSB 28 bytes) from bytes32 *)
  (* Python x[:28] - remove last 4 bytes (32 bits) *)
  let bytes28_val = Bigint.shift_right bytes32_val 32 in
  Ok (make_bytes ~num:bytes28_val ~len:28)

(* dec $get_first_byte(bytes32) : bytes1 *)

let get_first_byte ~at (value : Value.t) : Value.t result =
  at |> ignore;
  let* bytes32_val =
    match value.it with
    | BytesV { num; len = 32 } -> Ok num
    | BytesV { num; len = _ } ->
        let* () = validate_bytes32 at num in
        Ok num
    | NumV n ->
        let bytes32_val = Num.to_int n in
        let* () = validate_bytes32 at bytes32_val in
        Ok bytes32_val
    | _ -> Error (runtime at "get_first_byte: expected bytes32 or NumV")
  in
  (* Extract first byte (MSB 1 byte) from bytes32 *)
  (* Python x[:1] - extract MSB byte *)
  let msb_byte =
    Bigint.(shift_right bytes32_val 248 |> bit_and (of_int 0xff))
  in
  Ok (make_bytes ~num:msb_byte ~len:1)

(* dec $strip_first_byte(bytes32) : bytes31 *)

let strip_first_byte ~at (value : Value.t) : Value.t result =
  at |> ignore;
  let* bytes32_val =
    match value.it with
    | BytesV { num; len = 32 } -> Ok num
    | BytesV { num; len = _ } ->
        let* () = validate_bytes32 at num in
        Ok num
    | NumV n ->
        let bytes32_val = Num.to_int n in
        let* () = validate_bytes32 at bytes32_val in
        Ok bytes32_val
    | _ -> Error (runtime at "strip_first_byte: expected bytes32 or NumV")
  in
  (* Remove first byte (MSB 1 byte) from bytes32 *)
  (* Python x[1:] - remove MSB byte, keep remaining 31 bytes *)
  let mask_248 = Bigint.(pow (of_int 2) (of_int 248) - one) in
  let bytes31_val = Bigint.bit_and bytes32_val mask_248 in
  Ok (make_bytes ~num:bytes31_val ~len:31)

(* dec $bytes32_to_bytes1_list(bytes32) : bytes1* *)

let bytes32_to_bytes1_list ~at (bytes32_val : Num.t) : Value.t result =
  let bytes32_val = Num.to_int bytes32_val in
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
  let typ = Lang.Il.NumT `NatT $ no_region in
  Ok (Value.list typ bytes1_list)

(* dec $bytes1_to_uint64(bytes1) : uint64 *)

let bytes1_to_uint64 ~at (bytes1_val : Num.t) : Value.t result =
  let bytes1_val = Num.to_int bytes1_val in
  at |> ignore;
  let* () = validate_bytes1 at bytes1_val in
  Ok (Value.nat bytes1_val)

(* dec $concat_bytes(bytes, bytes) : bytes *)

let concat_bytes ~at (value_a : Value.t) (value_b : Value.t) : Value.t result =
  at |> ignore;
  match (value_a.it, value_b.it) with
  | BytesV { num = na; len = la }, BytesV { num = nb; len = lb } ->
      (* big-endian concat: (na || nb) == na * 256^(lb) + nb *)
      let shift_bits = 8 * lb in
      let shift = Bigint.(pow (of_int 2) (of_int shift_bits)) in
      let num = Bigint.((na * shift) + nb) in
      Ok (make_bytes ~num ~len:(la + lb))
  | _ -> Error (runtime at "concat_bytes: expected bytes values")

(* dec $concat_domain(domainType, bytes28) : domain *)

let concat_domain ~at (domain_type : Num.t) (bytes28_val : Num.t) :
    Value.t result =
  let domain_type = Num.to_int domain_type in
  let bytes28_val = Num.to_int bytes28_val in
  at |> ignore;
  (* Validate domainType (bytes4) *)
  let* () = validate_bytes4 at domain_type in
  (* Validate bytes28 *)
  let* () = validate_bytes28 at bytes28_val in
  (* Concatenate: domainType (4 bytes) + bytes28 (28 bytes) = domain (32 bytes) *)
  (* Convert to bytes (Big-endian) *)
  let dt_bytes = be_of_bigint_fixed domain_type ~len:4 in
  let b28_bytes = be_of_bigint_fixed bytes28_val ~len:28 in
  (* Concatenate: domain_type (4 bytes) + bytes28 (28 bytes) *)
  let out = Bytes.create 32 in
  Bytes.blit dt_bytes 0 out 0 4;
  Bytes.blit b28_bytes 0 out 4 28;
  (* Convert back to integer (Big-endian) *)
  let result = bigint_of_be_bytes out in
  (* Validate result is within bytes32 range *)
  let* () = validate_bytes32 at result in
  Ok (make_bytes ~num:result ~len:32)

(* dec $bytes32_to_bytes(bytes32) : bytes *)

let bytes32_to_bytes ~at (value : Value.t) : Value.t result =
  at |> ignore;
  match value.it with
  | BytesV { num = _; len = 32 } ->
      (* Already BytesV with correct length, just return it *)
      Ok value
  | BytesV { num; len = _ } ->
      (* BytesV with wrong length, validate and create new one *)
      let bytes32_val = num in
      let* () = validate_bytes32 at bytes32_val in
      Ok (make_bytes ~num:bytes32_val ~len:32)
  | NumV n ->
      (* NumV case: convert to BytesV *)
      let bytes32_val = Num.to_int n in
      let* () = validate_bytes32 at bytes32_val in
      Ok (make_bytes ~num:bytes32_val ~len:32)
  | _ -> Error (runtime at "bytes32_to_bytes: expected bytes32 or NumV")

(* dec $bytes4_to_bytes(bytes4) : bytes *)

let bytes4_to_bytes ~at (value : Value.t) : Value.t result =
  at |> ignore;
  match value.it with
  | BytesV { num = _; len = 4 } ->
      (* Already BytesV with correct length, just return it *)
      Ok value
  | BytesV { num; len = _ } ->
      (* BytesV with wrong length, validate and create new one *)
      let bytes4_val = num in
      let* () = validate_bytes4 at bytes4_val in
      Ok (make_bytes ~num:bytes4_val ~len:4)
  | NumV n ->
      (* NumV case: convert to BytesV *)
      let bytes4_val = Num.to_int n in
      let* () = validate_bytes4 at bytes4_val in
      Ok (make_bytes ~num:bytes4_val ~len:4)
  | _ -> Error (runtime at "bytes4_to_bytes: expected bytes4 or NumV")

(* dec $make_withdrawal_credentials_eth1(executionAddress) : bytes32 *)

let make_withdrawal_credentials_eth1 ~at (execution_address : Num.t) :
    Value.t result =
  let execution_address = Num.to_int execution_address in
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
  (* Return as BytesV with length 32 (bytes32) *)
  Ok (make_bytes ~num:result ~len:32)

(* dec $extract_execution_address(bytes32) : executionAddress *)

let extract_execution_address ~at (bytes32_val : Num.t) : Value.t result =
  let bytes32_val = Num.to_int bytes32_val in
  at |> ignore;
  let* () = validate_bytes32 at bytes32_val in
  (* Extract last 20 bytes (160 bits) from bytes32 *)
  let bytes20_mask = Bigint.(pow (of_int 2) (of_int 160) - one) in
  let execution_address = Bigint.bit_and bytes32_val bytes20_mask in
  Ok (make_bytes ~num:execution_address ~len:20)

(* dec $make_versioned_hash(bytes1, bytes31) : bytes32 *)

let make_versioned_hash ~at (bytes1_prefix : Num.t) (bytes31_suffix : Num.t) :
    Value.t result =
  let bytes1_prefix = Num.to_int bytes1_prefix in
  let bytes31_suffix = Num.to_int bytes31_suffix in
  at |> ignore;
  (* Validate bytes1 (1 byte) *)
  let* () = validate_bytes1 at bytes1_prefix in
  (* Validate bytes31 (31 bytes) *)
  let* () = validate_bytes31 at bytes31_suffix in
  (* Concatenate: bytes1 (1 byte) + bytes31 (31 bytes) = bytes32 (32 bytes) *)
  (* Shift bytes1_prefix left by 31 bytes (248 bits) *)
  let prefix_shifted = Bigint.shift_left bytes1_prefix 248 in
  (* Final result: prefix + suffix *)
  let result = Bigint.(prefix_shifted + bytes31_suffix) in
  (* Validate result is within bytes32 range *)
  let* () = validate_bytes32 at result in
  (* Return as BytesV with length 32 (bytes32) *)
  Ok (make_bytes ~num:result ~len:32)

(* ============================================================ *)
(* Fixed-width Little-Endian encoders for eth2spec compatibility *)
(* ============================================================ *)

(* Helper: create LE bytes from integer
 * LE encoding: b[0] = LSB, b[len-1] = MSB (as byte sequence)
 * But BytesV stores as BE num, so we need to convert LE bytes to BE num
 * 
 * Python: epoch.to_bytes(8, 'little') -> [0x01, 0x00, ..., 0x00] for epoch=1
 * When this byte array is interpreted as BE (int.from_bytes(..., 'big')):
 *   First byte becomes MSB, last byte becomes LSB
 *   [0x01, 0x00, ..., 0x00] -> BE: 0x0100000000000000
 * 
 * So: LE bytes [b0, b1, ..., b7] when read as BE = b0*256^7 + b1*256^6 + ... + b7*256^0
 * 
 * Extract bytes from input num in LE order (LSB first from num), 
 * then arrange as BE num (first extracted byte becomes MSB)
 *)
let make_bytes_le ~num ~(len : int) : Value.t =
  let open Bigint in
  (* Extract bytes in LE order: b0 (LSB from num), b1, ..., b_{len-1} (MSB from num) *)
  (* Extract LSB first: byte i = (num >> (i*8)) & 0xff *)
  (* When stored as BE num: b0 becomes MSB, b_{len-1} becomes LSB *)
  (* BE num = b0*256^{len-1} + b1*256^{len-2} + ... + b_{len-1}*256^0 *)
  let rec extract_and_build i bytes_list v =
    if Stdlib.( >= ) i len then bytes_list
    else
      let shift_bits = Stdlib.( * ) i 8 in
      let byte_val = bit_and (shift_right v shift_bits) (of_int 0xff) in
      extract_and_build (Stdlib.( + ) i 1) (byte_val :: bytes_list) v
  in
  let bytes_list = extract_and_build 0 [] num in
  (* bytes_list = [b7, b6, ..., b1, b0] where b0 was LSB from num (reversed order) *)
  (* LE bytes [b0, b1, ..., b7] when read as BE: b0 becomes MSB *)
  (* BE num = b0*256^{len-1} + b1*256^{len-2} + ... + b7*256^0 *)
  (* bytes_list is [b7, ..., b0], so we need to reverse it to [b0, ..., b7] *)
  (* Then: first (b0) * 256^{len-1}, second (b1) * 256^{len-2}, ..., last (b7) * 256^0 *)
  let rec reverse_list acc = function
    | [] -> acc
    | x :: rest -> reverse_list (x :: acc) rest
  in
  let bytes_forward = reverse_list [] bytes_list in
  (* bytes_forward = [b0, b1, ..., b7] *)
  let rec build_be_num acc shift = function
    | [] -> acc
    | byte_val :: rest ->
        build_be_num (acc + (byte_val * shift)) (shift / of_int 256) rest
  in
  let len_minus_1 = Stdlib.( - ) len 1 in
  let be_num =
    build_be_num zero (pow (of_int 256) (of_int len_minus_1)) bytes_forward
  in
  make_bytes ~num:be_num ~len

(* dec $uint8_to_bytes_le(uint8) : bytes *)
(* Always 1 byte, LE *)
let uint8_to_bytes_le ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_uint8 at x in
  Ok (make_bytes_le ~num:x ~len:1)

(* dec $uint32_to_bytes_le(uint32) : bytes *)
(* Always 4 bytes, LE *)
let uint32_to_bytes_le ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_uint32 at x in
  Ok (make_bytes_le ~num:x ~len:4)

(* dec $uint64_to_bytes_le(uint64) : bytes *)
(* Always 8 bytes, LE *)
let uint64_to_bytes_le ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_uint64 at x in
  Ok (make_bytes_le ~num:x ~len:8)

(* dec $bytes32_prefix8(bytes32) : bytes *)
(* Extract first 8 bytes (MSB 8 bytes) from bytes32 *)
let bytes32_prefix8 ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_bytes32 at x in
  (* Extract upper 8 bytes: x >> (24 * 8) *)
  let hi8 = Bigint.shift_right x (8 * 24) in
  (* hi8 is already in BE format, so just create bytes with len=8 *)
  Ok (make_bytes ~num:hi8 ~len:8)

(* dec $shr_uint64(uint64, nat) : uint64 *)
(* Right shift: x >> k *)
let shr_uint64 ~at (x : Num.t) (k : Num.t) : Value.t result =
  let x = Num.to_int x in
  let k = Num.to_int k in
  (* k must be non-negative and fit in int *)
  if Bigint.compare k Bigint.zero < 0 then
    Error (runtime at "shr_uint64: shift amount must be non-negative")
  else
    try
      let k_int = Bigint.to_int_exn k in
      if k_int >= 0 && k_int < 64 then
        Ok (Value.nat (Bigint.shift_right x k_int))
      else Error (runtime at "shr_uint64: shift amount must be in [0, 64]")
    with _ -> Error (runtime at "shr_uint64: shift amount too large")

(* dec $and_uint64(uint64, uint64) : uint64 *)
(* Bitwise AND: x & y *)
let and_uint64 ~at:_ (x : Num.t) (y : Num.t) : Value.t result =
  let x = Num.to_int x in
  let y = Num.to_int y in
  Ok (Value.nat (Bigint.bit_and x y))

(* dec $bytes8_to_uint64_le(bytes) : uint64 *)
(* Decode 8-byte value as little-endian uint64 *)
(* BytesV stores as BE num, so we extract bytes and re-interpret as LE *)
let bytes8_to_uint64_le ~at (v : Value.t) : Value.t result =
  match v.it with
  | BytesV { num; len = 8 } ->
      let open Bigint in
      (* Extract each byte from BE representation *)
      (* num = b[0]*256^7 + b[1]*256^6 + ... + b[7]*256^0 (BE interpretation) *)
      (* We want LE interpretation: b[0] + b[1]*256 + ... + b[7]*256^7 *)
      let rec extract_byte i =
        if Stdlib.( >= ) i 8 then []
        else
          let shift_bits = Stdlib.( * ) (Stdlib.( - ) 7 i) 8 in
          let byte_val = bit_and (shift_right num shift_bits) (of_int 0xff) in
          byte_val :: extract_byte (Stdlib.( + ) i 1)
      in
      let bytes = extract_byte 0 in
      (* LE interpretation: b[0] + b[1]*256 + ... + b[7]*256^7 *)
      let rec build_le_num i acc shift bytes_list =
        match bytes_list with
        | [] -> acc
        | byte_val :: rest ->
            build_le_num (Stdlib.( + ) i 1)
              (acc + (byte_val * shift))
              (shift * of_int 256)
              rest
      in
      Ok (Value.nat (build_le_num 0 zero (of_int 1) bytes))
  | _ -> Error (runtime at "bytes8_to_uint64_le: expects 8-byte value")

let builtins : (string * Define.t) list =
  [
    ("bytes_to_uint64", Define.T0.a1 Arg.num bytes_to_uint64);
    (* not used *)
    ("uint_to_bytes", Define.T0.a1 Arg.num uint_to_bytes);
    ("xor", Define.T0.a2 Arg.num Arg.num xor);
    ("concat_domain", Define.T0.a2 Arg.num Arg.num concat_domain);
    ( "make_withdrawal_credentials_eth1",
      Define.T0.a1 Arg.num make_withdrawal_credentials_eth1 );
    ("make_versioned_hash", Define.T0.a2 Arg.num Arg.num make_versioned_hash);
    ("first_28_bytes", Define.T0.a1 Arg.value first_28_bytes);
    ("get_first_byte", Define.T0.a1 Arg.value get_first_byte);
    ("strip_first_byte", Define.T0.a1 Arg.value strip_first_byte);
    ("bytes32_to_bytes1_list", Define.T0.a1 Arg.num bytes32_to_bytes1_list);
    ("bytes1_to_uint64", Define.T0.a1 Arg.num bytes1_to_uint64);
    ("concat_bytes", Define.T0.a2 Arg.value Arg.value concat_bytes);
    ("bytes32_to_bytes", Define.T0.a1 Arg.value bytes32_to_bytes);
    ("bytes4_to_bytes", Define.T0.a1 Arg.value bytes4_to_bytes);
    ("extract_execution_address", Define.T0.a1 Arg.num extract_execution_address);
    (* Fixed-width Little-Endian encoders *)
    ("uint8_to_bytes_le", Define.T0.a1 Arg.num uint8_to_bytes_le);
    ("uint32_to_bytes_le", Define.T0.a1 Arg.num uint32_to_bytes_le);
    ("uint64_to_bytes_le", Define.T0.a1 Arg.num uint64_to_bytes_le);
    ("bytes32_prefix8", Define.T0.a1 Arg.num bytes32_prefix8);
    ("bytes8_to_uint64_le", Define.T0.a1 Arg.value bytes8_to_uint64_le);
    (* Bitwise operations *)
    ("shr_uint64", Define.T0.a2 Arg.num Arg.num shr_uint64);
    ("and_uint64", Define.T0.a2 Arg.num Arg.num and_uint64);
  ]
