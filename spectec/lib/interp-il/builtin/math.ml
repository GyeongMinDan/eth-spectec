open Il.Ast

(* Built-in implementations *)

(* dec $integer_square_root(int) : int *)

let integer_square_root' (n : Bigint.t) : Bigint.t =
  (* 2^64 - 1, 2^32 - 1 *)
  let uint64_max      = Bigint.( (one lsl 64) - one ) in
  let uint64_max_sqrt = Bigint.( (one lsl 32) - one ) in
  if Bigint.equal n uint64_max then
    uint64_max_sqrt
  else
    let rec newton_method (x : Bigint.t) (n : Bigint.t) : Bigint.t =
      let y = Bigint.((x + n / x) / (one + one)) in
      if Bigint.(y < x) then
        newton_method y n
      else
        x
    in
    if Bigint.(n = zero) then
      Bigint.zero
    else
      newton_method n n

let integer_square_root ~at (n : Bigint.t) : (Value.t, Err.t) result =
  at |> ignore;
  if Bigint.(n < zero) then
    Error (Err.runtime at "integer_square_root: input must be non-negative")
  else
    Ok (Value.int (integer_square_root' n))

let builtins : (string * Define.t) list =
  [
    ("integer_square_root", Define.T0.a1 Arg.int integer_square_root);
  ]
