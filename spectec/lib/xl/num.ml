(* Numbers: natural numbers and integers *)

type t = [ `Nat of Bigint.t | `Int of Bigint.t ]
type typ = [ `NatT | `IntT ]

let to_typ = function `Nat _ -> `NatT | `Int _ -> `IntT
let to_int = function `Nat i | `Int i -> i

(* Operations *)

type unop = [ `PlusOp | `MinusOp ]
type binop = [ `AddOp | `SubOp | `MulOp | `DivOp | `ModOp | `PowOp ]
type cmpop = [ `LtOp | `GtOp | `LeOp | `GeOp ]

(* Comparison *)

let compare (n_a : t) (n_b : t) : int =
  match (n_a, n_b) with
  | `Nat n_a, `Nat n_b -> Bigint.compare n_a n_b
  | `Int i_a, `Int i_b -> Bigint.compare i_a i_b
  | `Nat _, `Int _ -> -1
  | `Int _, `Nat _ -> 1

(* Equality *)
(* For equality, compare the actual values *)
let eq (n_a : t) (n_b : t) : bool =
  match (n_a, n_b) with
  | `Nat n_a, `Nat n_b -> Bigint.compare n_a n_b = 0
  | `Int i_a, `Int i_b -> Bigint.compare i_a i_b = 0
  | `Nat n_a, `Int i_b -> Bigint.compare n_a i_b = 0
  | `Int i_a, `Nat n_b -> Bigint.compare i_a n_b = 0

(* Subtyping *)

let equiv typ_a typ_b = typ_a = typ_b

let sub typ_a typ_b =
  match (typ_a, typ_b) with `NatT, `IntT -> true | _, _ -> equiv typ_a typ_b

(* Stringifiers *)

let string_of_num = function
  | `Nat n -> Bigint.to_string n
  | `Int i ->
      (if i >= Bigint.zero then "+" else "-") ^ Bigint.to_string (Bigint.abs i)

let string_of_typ = function `NatT -> "nat" | `IntT -> "int"
let string_of_unop = function `PlusOp -> "+" | `MinusOp -> "-"

let string_of_binop = function
  | `AddOp -> "+"
  | `SubOp -> "-"
  | `MulOp -> "*"
  | `DivOp -> "/"
  | `ModOp -> "\\"
  | `PowOp -> "^"

let string_of_cmpop = function
  | `LtOp -> "<"
  | `GtOp -> ">"
  | `LeOp -> "<="
  | `GeOp -> ">="

(* Unary *)

let un (op : unop) num : t =
  match (op, num) with
  | `PlusOp, `Nat _ -> num
  | `PlusOp, `Int _ -> num
  | `MinusOp, `Nat n -> `Int (Bigint.neg n)
  | `MinusOp, `Int n -> `Int (Bigint.neg n)

(* Binary *)
(* Change because of calc between nat and int *)
(* +, -, *, /  *)

let bin (op : binop) num_l num_r : t =
  match (op, num_l, num_r) with
  | `AddOp, `Nat n_l, `Nat n_r -> `Nat Bigint.(n_l + n_r)
  | `AddOp, `Int i_l, `Int i_r -> `Int Bigint.(i_l + i_r)
  | `AddOp, `Nat n_l, `Int i_r -> `Int Bigint.(n_l + i_r)
  | `AddOp, `Int i_l, `Nat n_r -> `Int Bigint.(i_l + n_r)
  | `SubOp, `Nat n_l, `Nat n_r when n_l >= n_r -> `Nat Bigint.(n_l - n_r)
  | `SubOp, `Nat n_l, `Nat n_r -> `Int Bigint.(n_l - n_r)
  | `SubOp, `Int i_l, `Int i_r -> `Int Bigint.(i_l - i_r)
  | `SubOp, `Nat n_l, `Int i_r -> `Int Bigint.(n_l - i_r)
  | `SubOp, `Int i_l, `Nat n_r -> `Int Bigint.(i_l - n_r)
  | `MulOp, `Nat n_l, `Nat n_r -> `Nat Bigint.(n_l * n_r)
  | `MulOp, `Int i_l, `Int i_r -> `Int Bigint.(i_l * i_r)
  | `MulOp, `Nat n_l, `Int i_r -> `Int Bigint.(n_l * i_r)
  | `MulOp, `Int i_l, `Nat n_r -> `Int Bigint.(i_l * n_r)
  | `DivOp, `Nat n_l, `Nat n_r when Bigint.(n_r <> zero && rem n_l n_r = zero)
    ->
      `Nat Bigint.(n_l / n_r)
  | `DivOp, `Int i_l, `Int i_r when Bigint.(i_r <> zero && rem i_l i_r = zero)
    ->
      `Int Bigint.(i_l / i_r)
  | `DivOp, `Nat n_l, `Nat n_r when Bigint.(n_r <> zero) ->
      `Int Bigint.(n_l / n_r)
  | `DivOp, `Int i_l, `Int i_r when Bigint.(i_r <> zero) ->
      `Int Bigint.(i_l / i_r)
  | `DivOp, `Nat n_l, `Int i_r when Bigint.(i_r <> zero) ->
      `Int Bigint.(n_l / i_r)
  | `DivOp, `Int i_l, `Nat n_r when Bigint.(n_r <> zero) ->
      `Int Bigint.(i_l / n_r)
  | `ModOp, `Nat n_l, `Nat n_r when Bigint.(n_r <> zero) ->
      `Nat Bigint.(rem n_l n_r)
  | `ModOp, `Int i_l, `Int i_r when Bigint.(i_r <> zero) ->
      `Int Bigint.(rem i_l i_r)
  | `ModOp, `Nat n_l, `Int i_r when Bigint.(i_r <> zero) ->
      `Int Bigint.(rem n_l i_r)
  | `ModOp, `Int i_l, `Nat n_r when Bigint.(n_r <> zero) ->
      `Int Bigint.(rem i_l n_r)
  | `PowOp, `Nat n_l, `Nat n_r -> `Nat Bigint.(pow n_l n_r)
  | `PowOp, `Int i_l, `Int i_r -> `Int Bigint.(pow i_l i_r)
  | `PowOp, `Nat n_l, `Int i_r -> `Int Bigint.(pow n_l i_r)
  | `PowOp, `Int i_l, `Nat n_r -> `Int Bigint.(pow i_l n_r)
  | _, _, _ -> assert false

(* Comparison *)

let cmp (op : cmpop) num_l num_r : bool =
  match (op, num_l, num_r) with
  | `LtOp, `Nat n_l, `Nat n_r -> n_l < n_r
  | `LtOp, `Int i_l, `Int i_r -> i_l < i_r
  | `LtOp, `Nat n_l, `Int i_r -> Bigint.compare n_l i_r < 0
  | `LtOp, `Int i_l, `Nat n_r -> Bigint.compare i_l n_r < 0
  | `GtOp, `Nat n_l, `Nat n_r -> n_l > n_r
  | `GtOp, `Int i_l, `Int i_r -> i_l > i_r
  | `GtOp, `Nat n_l, `Int i_r -> Bigint.compare n_l i_r > 0
  | `GtOp, `Int i_l, `Nat n_r -> Bigint.compare i_l n_r > 0
  | `LeOp, `Nat n_l, `Nat n_r -> n_l <= n_r
  | `LeOp, `Int i_l, `Int i_r -> i_l <= i_r
  | `LeOp, `Nat n_l, `Int i_r -> Bigint.compare n_l i_r <= 0
  | `LeOp, `Int i_l, `Nat n_r -> Bigint.compare i_l n_r <= 0
  | `GeOp, `Nat n_l, `Nat n_r -> n_l >= n_r
  | `GeOp, `Int i_l, `Int i_r -> i_l >= i_r
  | `GeOp, `Nat n_l, `Int i_r -> Bigint.compare n_l i_r >= 0
  | `GeOp, `Int i_l, `Nat n_r -> Bigint.compare i_l n_r >= 0
  | _, _, _ -> assert false
