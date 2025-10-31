open Il

let ( let* ) = Result.bind

module Bytes = Stdlib.Bytes

(* Built-in implementations *)

(* Helper function: BytesV to raw bytes (preserving length, big-endian) *)
let bytesv_to_raw (num: Bigint.t) (len: int) : Bytes.t =
  let out = Bytes.create len in
  let rec put i v =
    if i >= 0 then (
      let byte = Bigint.(to_int_exn (bit_and v (of_int 0xff))) in
      Bytes.set out i (Stdlib.Char.chr byte);
      put (i-1) (Bigint.shift_right v 8)
    )
  in
  put (len-1) num; out

(* Helper: big-endian Bytes.t -> Bigint.t *)
let bigint_of_be_bytes (b: Bytes.t) : Bigint.t =
  let acc = ref Bigint.zero in
  for i = 0 to Bytes.length b - 1 do
    let v = Char.code (Bytes.get b i) in
    acc := Bigint.( !acc * of_int 256 + of_int v )
  done;
  !acc

(* dec $hash_<X>(X) : bytes32 *)

let hash_ ~at (_typ : targ) (v: Il.Value.t) : (Il.Value.t, Err.t) result =
  (* 제네릭 형으로 변환 *)
  try
    let (num, len) = Il.Value.get_bytes v in
    let raw = bytesv_to_raw num len in
    let h =
      let open Digestif.SHA256 in
      digest_bytes raw |> to_raw_string |> Bytes.of_string
    in
    Ok (Value.nat (bigint_of_be_bytes h))
  with _ -> Error (Err.runtime at "hash_<X>: expected bytes or serializable value")

let builtins : (string * Define.t) list =
  [
    ("hash_", Define.T1.a1 Arg.value hash_);
  ]
