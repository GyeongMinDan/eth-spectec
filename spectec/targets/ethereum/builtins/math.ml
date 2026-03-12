open Lang.Xl
open Lang.Il
open Builtins
open Error

(* Built-in implementations *)

(* dec $integer_square_root(int) : int *)

let integer_square_root' (n : Bigint.t) : Bigint.t =
  (* 2^64 - 1, 2^32 - 1 *)
  let uint64_max = Bigint.((one lsl 64) - one) in
  let uint64_max_sqrt = Bigint.((one lsl 32) - one) in
  if Bigint.equal n uint64_max then uint64_max_sqrt
  else
    let rec newton_method (x : Bigint.t) (n : Bigint.t) : Bigint.t =
      let y = Bigint.((x + (n / x)) / (one + one)) in
      if Bigint.(y < x) then newton_method y n else x
    in
    if Bigint.(n = zero) then Bigint.zero else newton_method n n

(* change func name... *)
let integer_square_root ~at (n : Num.t) : Value.t result =
  at |> ignore;
  let n_bigint = Num.to_int n in
  if Bigint.(n_bigint < zero) then
    Error (runtime at "integer_square_root: input must be non-negative")
  else
    (* uint64 = nat *)
    Ok (Value.nat (integer_square_root' n_bigint))

let rec shl' (v : Bigint.t) (o : Bigint.t) : Bigint.t =
  if Bigint.(o > zero) then shl' Bigint.(v * (one + one)) Bigint.(o - one)
  else v

let pow2' (w : Bigint.t) : Bigint.t = shl' Bigint.one w

let pow2 ~at (width : Bigint.t) : Value.t result =
  at |> ignore;
  Ok (Value.int (pow2' width))

let builtins : (string * Define.t) list =
  [
    ("integer_square_root", Define.T0.a1 Arg.num integer_square_root);
    ("pow2", Define.T0.a1 Arg.nat pow2);
  ]
