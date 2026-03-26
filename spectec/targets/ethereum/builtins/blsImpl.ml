open Lang.Xl
open Lang.Il
open Lang.Il.Value
module Bytes = Stdlib.Bytes
open Builtins
open Error

let ( let* ) = Result.bind

let pow2_8 (n : int) =
  let exp = 8 * n in
  Bigint.pow (Bigint.of_int 2) (Bigint.of_int exp)

let ensure_fits_bytes ~at (n : Bigint.t) ~(len : int) =
  if Bigint.(n >= zero && n < pow2_8 len) then Ok ()
  else Error (runtime at (Printf.sprintf "value does not fit in %d bytes" len))

let be_of_bigint_fixed (n : Bigint.t) ~(len : int) : bytes =
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

(* BE Bytes -> int(Bigint) *)
let bigint_of_be_bytes (b : Bytes.t) : Bigint.t =
  let acc = ref Bigint.zero in
  for i = 0 to Bytes.length b - 1 do
    let v = Char.code (Bytes.get b i) in
    acc := Bigint.((!acc * of_int 256) + of_int v)
  done;
  !acc

(* Built-in implementations *)

(* dec $bls_verify(blsPubkey, root, blsSignature) : boolean *)

let bls_verify ~at (bls_pubkey : Num.t) (root : Num.t) (bls_signature : Num.t) :
    Value.t result =
  let bls_pubkey = Num.to_int bls_pubkey in
  let root = Num.to_int root in
  let bls_signature = Num.to_int bls_signature in
  let* () = ensure_fits_bytes ~at bls_pubkey ~len:48 in
  let* () = ensure_fits_bytes ~at bls_signature ~len:96 in
  let* () = ensure_fits_bytes ~at root ~len:32 in
  (* Big-endian byte order *)
  let pk_bytes = be_of_bigint_fixed bls_pubkey ~len:48 in
  let sig_bytes = be_of_bigint_fixed bls_signature ~len:96 in
  let msg_bytes = be_of_bigint_fixed root ~len:32 in

  (* Convert bytes to BLS types using provided constructors *)
  match Bls12_381_signature.MinPk.pk_of_bytes_opt pk_bytes with
  | None -> Ok (Value.bool false) (* invalid public key *)
  | Some pk -> (
      match Bls12_381_signature.MinPk.signature_of_bytes_opt sig_bytes with
      | None -> Ok (Value.bool false) (* invalid signature *)
      | Some signature ->
          let ok =
            Bls12_381_signature.MinPk.Pop.verify pk msg_bytes signature
          in
          Ok (Value.bool ok)
          (* valid signature *))

(* dec $eth_aggregate_pubkeys(blsPubkey* ) : blsPubkey *)

let eth_aggregate_pubkeys ~at (pubkeys_num : Num.t list) : Value.t result =
  let pubkeys_int = List.map Num.to_int pubkeys_num in
  (* 1) int -> bytes48 -> G1 (validation) *)
  let conv_one n =
    let* () = ensure_fits_bytes ~at n ~len:48 in
    let b = be_of_bigint_fixed n ~len:48 in
    match Bls12_381.G1.of_compressed_bytes_opt b with
    | None ->
        Error (runtime at "eth_aggregate_pubkeys: invalid G1 pubkey (bytes48)")
    | Some p -> Ok p
  in
  let rec mapM f = function
    | [] -> Ok []
    | x :: xs ->
        let* y = f x in
        let* ys = mapM f xs in
        Ok (y :: ys)
  in
  let* points = mapM conv_one pubkeys_int in

  (* 2) cumulative sum *)
  let agg = List.fold_left Bls12_381.G1.add Bls12_381.G1.zero points in

  (* 3) serialize to 48B -> BytesV (48 bytes) *)
  let out_b = Bls12_381.G1.to_compressed_bytes agg in
  let out_n = bigint_of_be_bytes out_b in
  (* BLSPubkey is 48 bytes, so return BytesV *)
  Ok (make_bytes ~num:out_n ~len:48)

(* dec $bls_fast_aggregate_verify(blsPubkey*, bytes32, blsSignature) : boolean *)

let bls_fast_aggregate_verify ~at (pubkeys_num : Num.t list) (root : Num.t)
    (sig_num : Num.t) : Value.t result =
  (* (Note: eth_fast_aggregate_verify handles empty list + G2_POINT_AT_INFINITY before calling this) *)
  (* Despite of this condition if pubkey list is empty, it will return false. *)
  if List.length pubkeys_num = 0 then Ok (Value.bool false)
  else
    let pubkeys_int = List.map Num.to_int pubkeys_num in
    let root = Num.to_int root in
    let sig_int = Num.to_int sig_num in
    (* length validation *)
    let* () = ensure_fits_bytes ~at root ~len:32 in
    let* () = ensure_fits_bytes ~at sig_int ~len:96 in

    (* message/signature bytes *)
    let msg_bytes = be_of_bigint_fixed root ~len:32 in
    let sig_bytes = be_of_bigint_fixed sig_int ~len:96 in

    (* To follow the orders of py_ecc fast_aggregate_verify function *)
    let rec mapM f = function
      | [] -> Ok []
      | x :: xs ->
          let* y = f x in
          let* ys = mapM f xs in
          Ok (y :: ys)
    in
    let conv_pk (n : Bigint.t) =
      let* () = ensure_fits_bytes ~at n ~len:48 in
      let b = be_of_bigint_fixed n ~len:48 in
      match Bls12_381.G1.of_compressed_bytes_opt b with
      | None -> Ok None
      | Some p -> Ok (Some p)
    in
    let* points_opt = mapM conv_pk pubkeys_int in
    if List.exists (fun o -> o = None) points_opt then Ok (Value.bool false)
    else
      let points = List.map Option.get points_opt in

      (* aggregate public key *)
      let agg = List.fold_left Bls12_381.G1.add Bls12_381.G1.zero points in
      let agg_pk_bytes = Bls12_381.G1.to_compressed_bytes agg in

      (* is valid signature ?*)
      match Bls12_381_signature.MinPk.signature_of_bytes_opt sig_bytes with
      | None -> Ok (Value.bool false)
      | Some signature -> (
          (* is valid public key ? *)
          match Bls12_381_signature.MinPk.pk_of_bytes_opt agg_pk_bytes with
          | None -> Ok (Value.bool false)
          | Some pk ->
              let ok =
                Bls12_381_signature.MinPk.Pop.verify pk msg_bytes signature
              in
              Ok (Value.bool ok))

let builtins : (string * Define.t) list =
  [
    ("bls_verify", Define.T0.a3 Arg.num Arg.num Arg.num bls_verify);
    ( "eth_aggregate_pubkeys",
      Define.T0.a1 (Arg.list_of Arg.num) eth_aggregate_pubkeys );
    ( "bls_fast_aggregate_verify",
      Define.T0.a3 (Arg.list_of Arg.num) Arg.num Arg.num
        bls_fast_aggregate_verify );
  ]
