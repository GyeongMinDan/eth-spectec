open Lang.Xl
open Lang.Il
open Builtins
open Error

(* Value set *)

module VSet = Set.Make (Value)

(* dec $count_occurrences_<X>(X*, X) : nat *)

let count_occurrences_ ~at (_typ : targ) (vs : Value.t list) (target : Value.t)
    : Value.t result =
  at |> ignore;
  let count =
    List.fold_left
      (fun acc v -> if Value.eq v target then Bigint.(acc + one) else acc)
      Bigint.zero vs
  in
  Ok (Value.nat count)

(* (*dec $to_set_<X>(X*) = X* *)

let to_set_ ~at (typ : targ) (vs : Value.t list) : Value.t result =
  at |> ignore;
  (* Remove duplicates while preserving order *)
  let seen = ref VSet.empty in
  let result =
    List.fold_left
      (fun acc v ->
        if VSet.mem v !seen then acc
        else (
          seen := VSet.add v !seen;
          v :: acc))
      [] vs
    |> List.rev (* Restore original order *)
  in
  Ok (Value.list typ result)

(* (*dec $sum_<X>(X*) : X  *)

let sum_ ~at (_typ : targ) (vs : Value.t list) : Value.t result =
  at |> ignore;
  let s =
    List.fold_left
      (fun acc ({ it; _ } : Value.t) ->
        match it with
        | NumV (`Int n) | NumV (`Nat n) -> Bigint.(acc + n)
        | _ -> acc)
      Bigint.zero vs
  in
  Ok (Value.nat s)

(* dec $repeat_<X>(X, nat) : X* *)

let repeat_ ~at (typ : targ) (value : Value.t) (count : Num.t) : Value.t result
    =
  let count = Num.to_int count in
  at |> ignore;
  try
    let n = Bigint.to_int_exn count in
    if n < 0 then Error (runtime at "repeat: count must be non-negative")
    else
      let repeated_list = List.init n (fun _ -> value) in
      Ok (Value.list typ repeated_list)
  with _ -> Error (runtime at "repeat: count is too large to be an integer")

(* (*dec $sort_<X>(X*) : X* *)

let sort_ ~at (typ : targ) (vs : Value.t list) : Value.t result =
  at |> ignore;
  let sorted_list = List.sort Value.compare vs in
  Ok (Value.list typ sorted_list)

(* (* dec $set_intersection_<X>(X*, X*) : X* *)

let set_intersection_ ~at (typ : targ) (vs1 : Value.t list) (vs2 : Value.t list)
    : Value.t result =
  at |> ignore;
  (* Convert lists to sets *)
  let set1 = VSet.of_list vs1 in
  let set2 = VSet.of_list vs2 in
  (* Compute intersection *)
  let intersection = VSet.inter set1 set2 in
  (* Convert back to list *)
  let result_list = VSet.elements intersection in
  Ok (Value.list typ result_list)

(* dec $range(nat) : nat* *)

let range ~at (count : Num.t) : Value.t result =
  let count = Num.to_int count in
  at |> ignore;
  try
    let n = Bigint.to_int_exn count in
    if n < 0 then Error (runtime at "range: count must be non-negative")
    else
      let range_list = List.init n (fun i -> Value.nat (Bigint.of_int i)) in
      Ok (Value.list' Typ.int range_list)
  with _ -> Error (runtime at "range: count is too large to be an integer")

(* (* dec $enumerate_<X>(X*) : enumerated_<X>* *)

let enumerate_ ~at (typ : targ) (vs : Value.t list) : Value.t result =
  at |> ignore;
  (* Create (index, value) pairs *)
  let enumerated_list =
    List.mapi
      (fun i v ->
        let index = Value.nat (Bigint.of_int i) in
        Value.tuple [ index; v ])
      vs
  in
  Ok (Value.list typ enumerated_list)

(* dec $set_or_append_list_<X>(X*, nat, X) : X* *)

let set_or_append_list_ ~at (typ : targ) (vs : Value.t list) (idx_big : Num.t)
    (value : Value.t) : Value.t result =
  let idx_big = Num.to_int idx_big in
  at |> ignore;
  try
    let idx = Bigint.to_int_exn idx_big in
    if idx < 0 then
      Error (runtime at "set_or_append_list: index must be non-negative")
    else
      let len = List.length vs in
      if idx = len then
        (* append *)
        Ok (Value.list typ (vs @ [ value ]))
      else if idx < len then
        (* set at index *)
        let rec replace i = function
          | [] -> [] (* unreachable when idx < len *)
          | _ :: tl when i = idx -> value :: tl
          | hd :: tl -> hd :: replace (i + 1) tl
        in
        Ok (Value.list typ (replace 0 vs))
      else Error (runtime at "set_or_append_list: index out of range")
  with _ ->
    Error (runtime at "set_or_append_list: index is too large to be an integer")

let builtins =
  [
    ( "count_occurrences_",
      Define.T1.a2 (Arg.list_of Arg.value) Arg.value count_occurrences_ );
    ("to_set_", Define.T1.a1 (Arg.list_of Arg.value) to_set_);
    ("sum_", Define.T1.a1 (Arg.list_of Arg.value) sum_);
    ("repeat_", Define.T1.a2 Arg.value Arg.num repeat_);
    ("sort_", Define.T1.a1 (Arg.list_of Arg.value) sort_);
    ( "set_intersection_",
      Define.T1.a2 (Arg.list_of Arg.value) (Arg.list_of Arg.value)
        set_intersection_ );
    ("range", Define.T0.a1 Arg.num range);
    ("enumerate_", Define.T1.a1 (Arg.list_of Arg.value) enumerate_);
    ( "set_or_append_list_",
      Define.T1.a3 (Arg.list_of Arg.value) Arg.num Arg.value set_or_append_list_
    );
  ]
