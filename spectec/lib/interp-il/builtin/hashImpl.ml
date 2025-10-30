(*open Il.Ast
open Util.Source
open Runtime_dynamic.Value

let ( let* ) = Result.bind

(* Built-in implementations *)

(* Helper function: BytesV to raw bytes (preserving length, big-endian) *)
let bytesv_to_raw (num: Bigint.t) (len: int) : Bytes.t =
  let out = Bytes.create len in
  let rec put i v =
    if i >= 0 then (
      let byte = Bigint.(to_int (bit_and v (of_int 0xff))) in
      Bytes.set out i (Char.chr byte);
      put (i-1) (shift_right v 8)
    )
  in
  put (len-1) num; out

(* dec $hash_<bytes>(bytes) : bytes32 *)

let hash_bytes ~at (v: Value.t) : (Value.t, Err.t) result =
  at |> ignore;
  match v.it with
  | BytesV { num; len } ->
      let raw = bytesv_to_raw num len in
      (* sha256(raw) 의 원시 32바이트 *)
      let h =
        let open Digestif.SHA256 in
        digest_bytes raw |> to_raw_string |> Bytes.of_string
      in
      (* bytes32를 Bigint(big-endian)로 *)
      Ok (Value.nat (Bigint.of_bytes_big_endian h))
  | _ ->
      Error (Err.runtime at "hash_<bytes>: expected bytes")

let builtins : (string * Define.t) list =
  [
    ("hash_<bytes>", Define.T0.a1 Arg.value hash_bytes);
  ]
*)