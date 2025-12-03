module Il = Lang.Il
open Il
open Lang.Xl
open Define.Error
module Arg = Define.Arg
module Bytes = Stdlib.Bytes

let ( let* ) = Result.bind

(* Built-in implementations *)

(* Helper function: BytesV to raw bytes (preserving length, big-endian) *)
let bytesv_to_raw (num : Bigint.t) (len : int) : Bytes.t =
  let out = Bytes.create len in
  let rec put i v =
    if i >= 0 then (
      let byte = Bigint.(to_int_exn (bit_and v (of_int 0xff))) in
      Bytes.set out i (Stdlib.Char.chr byte);
      put (i - 1) (Bigint.shift_right v 8))
  in
  put (len - 1) num;
  out

(* Helper: big-endian Bytes.t -> Bigint.t *)
let bigint_of_be_bytes (b : Bytes.t) : Bigint.t =
  let acc = ref Bigint.zero in
  for i = 0 to Bytes.length b - 1 do
    let v = Char.code (Bytes.get b i) in
    acc := Bigint.((!acc * of_int 256) + of_int v)
  done;
  !acc

(* Helper: Resolve bytes length from targ, including aliases *)
let bytes_len_of_targ (typ : targ) : int option =
  match typ.it with
  | VarT (id, _) -> (
      let nm = id.it in
      (* Direct bytesN type: bytes32, bytes48, bytes96, etc. *)
      if String.length nm >= 5 && String.sub nm 0 5 = "bytes" then
        try
          let len_str = String.sub nm 5 (String.length nm - 5) in
          Some (int_of_string len_str)
        with _ -> None
      else
        (* Aliases used in eth2spec *)
        match nm with
        | "blsSignature" -> Some 96
        | "blsPubkey" -> Some 48
        | "root" | "hash32" | "domain" -> Some 32
        | "version" | "domainType" | "forkDigest" -> Some 4
        | "executionAddress" -> Some 20
        | "payloadId" -> Some 8
        | "nodeID" -> Some 256
        | _ -> None)
  | _ -> None

(* Helper: Validate that a Bigint value fits in the given byte length *)
let validate_fits_len ~at (x : Bigint.t) (len : int) : unit result =
  let open Bigint in
  let pow2_8 n =
    let exp = Stdlib.( * ) 8 n in
    pow (of_int 2) (of_int exp)
  in
  if x >= zero && x < pow2_8 len then Ok ()
  else
    Error
      (runtime at (Printf.sprintf "hash_<X>: value does not fit %d bytes" len))

(* dec $hash_<X>(X) : bytes32 *)

let hash_ ~at (typ : targ) (v : Value.t) : Value.t result =
  (* bytes* 타입은 int로 표현되므로 NumV일 수도 있음 *)
  let* num, len =
    match v.it with
    | BytesV { num; len } -> Ok (num, len)
    | NumV _ -> (
        (* bytes* 타입이 int로 표현된 경우: 타입 정보에서 길이 추론 *)
        let num_bigint = Value.get_num v |> Num.to_int in
        match bytes_len_of_targ typ with
        | Some l ->
            (* 타입에서 길이를 알 수 있는 경우 *)
            (* 범위 검증: 값이 해당 길이에 맞는지 확인 *)
            let* () = validate_fits_len ~at num_bigint l in
            Ok (num_bigint, l)
        | None ->
            (* 타입 이름에서 길이를 추론할 수 없는 경우, 에러 *)
            Error (runtime at "hash_<X>: cannot infer byte length from type"))
    | _ -> Error (runtime at "hash_<X>: expected bytes or NumV")
  in
  let raw = bytesv_to_raw num len in
  let h =
    let open Digestif.SHA256 in
    digest_bytes raw |> to_raw_string |> Bytes.of_string
  in
  Ok (Value.make_bytes ~num:(bigint_of_be_bytes h) ~len:32)

let builtins : (string * Define.t) list =
  [ ("hash_", Define.T1.a1 Arg.value hash_) ]
