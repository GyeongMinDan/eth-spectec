open Xl
open Il.Ast
open Util.Source

(* Ticker for node identifier tracking *)

let tick = ref 0
let refresh () = tick := 0

let fresh () =
  let id = !tick in
  tick := id + 1;
  id

(* Value *)

type t = value

(* Stringifier *)

let to_string t = Print.string_of_value t

(* Comparison *)

let rec compare (value_l : t) (value_r : t) =
  let tag (value : t) =
    match value.it with
    | BoolV _ -> 0
    | NumV _ -> 1
    | TextV _ -> 2
    | BytesV _ -> 3
    | StructV _ -> 4
    | CaseV _ -> 5
    | TupleV _ -> 6
    | OptV _ -> 7
    | ListV _ -> 8
    | FuncV _ -> 9
  in
  match (value_l.it, value_r.it) with
  | BoolV b_l, BoolV b_r -> Stdlib.compare b_l b_r
  | NumV n_l, NumV n_r -> Num.compare n_l n_r
  | TextV s_l, TextV s_r -> String.compare s_l s_r
  | BytesV {num=n1; len=l1}, BytesV {num=n2; len=l2} ->
      let len_cmp = Int.compare l1 l2 in
      if len_cmp <> 0 then len_cmp else Bigint.compare n1 n2
  | StructV fields_l, StructV fields_r ->
      let atoms_l, values_l = List.split fields_l in
      let atoms_r, values_r = List.split fields_r in
      let cmp_atoms = List.compare Atom.compare atoms_l atoms_r in
      if cmp_atoms <> 0 then cmp_atoms else compares values_l values_r
  | CaseV (mixop_l, values_l), CaseV (mixop_r, values_r) ->
      let cmp_mixop = Mixop.compare mixop_l mixop_r in
      if cmp_mixop <> 0 then cmp_mixop else compares values_l values_r
  | TupleV values_l, TupleV values_r -> compares values_l values_r
  | OptV value_opt_l, OptV value_opt_r -> (
      match (value_opt_l, value_opt_r) with
      | Some value_l, Some value_r -> compare value_l value_r
      | Some _, None -> 1
      | None, Some _ -> -1
      | None, None -> 0)
  | ListV values_l, ListV values_r -> compares values_l values_r
  | _ -> Int.compare (tag value_l) (tag value_r)

and compares (values_l : t list) (values_r : t list) : int =
  match (values_l, values_r) with
  | [], [] -> 0
  | [], _ :: _ -> -1
  | _ :: _, [] -> 1
  | value_l :: values_l, value_r :: values_r ->
      let cmp = compare value_l value_r in
      if cmp <> 0 then cmp else compares values_l values_r

(* Equality *)

let eq (value_l : t) (value_r : t) : bool =
  (* compare actual values (handles Nat vs Int) *)
  match (value_l.it, value_r.it) with
  | NumV n_l, NumV n_r -> Num.eq n_l n_r
  | _ -> compare value_l value_r = 0

(* Boolean *)

let get_bool (value : t) =
  match value.it with BoolV b -> b | _ -> failwith "get_bool"

(* Number *)

let get_num (value : t) =
  match value.it with
  | NumV n -> n
  | BytesV { num; _ } -> `Nat num
  | _ -> failwith "get_num"

(* Text *)

let get_text (value : t) =
  match value.it with TextV s -> s | _ -> failwith "get_text"

(* Bytes *)

let make_bytes ~(num: Bigint.t) ~(len:int) : t =
  if len < 0 then failwith "bytes len < 0";
  let value = BytesV { num; len } in
  let vid = fresh () in
  let typ = NumT `NatT in
  value $$$ { vid; typ }

let get_bytes (value : t) =
  match value.it with BytesV {num; len} -> (num, len) | _ -> failwith "get_bytes"

(* List *)

let to_list (values : t list) = ListV values

let get_list (value : t) =
  match value.it with ListV values -> values | _ -> failwith "unseq"

(* Option *)

let to_opt (value : t option) = OptV value

let get_opt (value : t) =
  match value.it with OptV value -> value | _ -> failwith "get_opt"

(* Struct *)

let get_struct (value : t) =
  match value.it with StructV fields -> fields | _ -> failwith "get_struct"
