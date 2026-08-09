open Types
open Common.Source

type t = value

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
  | NumV n_l, NumV n_r -> Xl.Num.compare n_l n_r
  | NumV n_l, BytesV { num = n_r; _ } -> Xl.Num.compare n_l (`Nat n_r)
  | BytesV { num = n_l; _ }, NumV n_r -> Xl.Num.compare (`Nat n_l) n_r
  | TextV s_l, TextV s_r -> String.compare s_l s_r
  | BytesV { num = n1; len = l1 }, BytesV { num = n2; len = l2 } ->
      let len_cmp = Int.compare l1 l2 in
      if len_cmp <> 0 then len_cmp else Bigint.compare n1 n2
  | StructV fields_l, StructV fields_r ->
      let fields_l_sorted =
        List.sort (fun (a1, _) (a2, _) -> Xl.Atom.compare a1 a2) fields_l
      in
      let fields_r_sorted =
        List.sort (fun (a1, _) (a2, _) -> Xl.Atom.compare a1 a2) fields_r
      in
      let atoms_l, values_l = List.split fields_l_sorted in
      let atoms_r, values_r = List.split fields_r_sorted in
      let cmp_atoms = List.compare Xl.Atom.compare atoms_l atoms_r in
      if cmp_atoms <> 0 then cmp_atoms else compares values_l values_r
  | CaseV (mixop_l, values_l), CaseV (mixop_r, values_r) ->
      let cmp_mixop = Xl.Mixop.compare mixop_l mixop_r in
      if cmp_mixop <> 0 then cmp_mixop else compares values_l values_r
  | TupleV values_l, TupleV values_r -> compares values_l values_r
  | OptV value_opt_l, OptV value_opt_r -> (
      match (value_opt_l, value_opt_r) with
      | Some value_l, Some value_r -> compare value_l value_r
      | Some _, None -> 1
      | None, Some _ -> -1
      | None, None -> 0)
  | ListV values_l, ListV values_r -> compares values_l values_r
  | FuncV id_l, FuncV id_r ->
      failwith
        (Format.asprintf "Cannot compare functions: %s vs %s" id_l.it id_r.it)
  | _ -> Int.compare (tag value_l) (tag value_r)

and compares (values_l : t list) (values_r : t list) : int =
  match (values_l, values_r) with
  | [], [] -> 0
  | [], _ :: _ -> -1
  | _ :: _, [] -> 1
  | value_l :: values_l, value_r :: values_r ->
      let cmp = compare value_l value_r in
      if cmp <> 0 then cmp else compares values_l values_r

let eq (value_l : t) (value_r : t) : bool =
  (* For NumV, use Xl.Num.eq to compare actual values (handles Nat vs Int) *)
  (* For NumV vs BytesV, compare the numeric values *)
  match (value_l.it, value_r.it) with
  | NumV n_l, NumV n_r -> Xl.Num.eq n_l n_r
  | NumV n_l, BytesV { num = n_r; _ } -> Xl.Num.eq n_l (`Nat n_r)
  | BytesV { num = n_l; _ }, NumV n_r -> Xl.Num.eq (`Nat n_l) n_r
  | BytesV { num = n_l; len = len_l }, BytesV { num = n_r; len = len_r } ->
      (* Compare bytes: same length and same value *)
      len_l = len_r && Bigint.compare n_l n_r = 0
  | _ -> compare value_l value_r = 0

(* Vid provider signature *)
module type VidProvider = sig
  val fresh : unit -> vid
end

(* Global mutable vid provider for shared use across parsing and interpretation *)
module GlobalVidProvider = struct
  let provider : (unit -> vid) ref = ref (fun () -> 0)
  let set (p : unit -> vid) = provider := p
  let reset () = provider := fun () -> 0
  let fresh () = !provider ()
end

(* Functor for creating value module with custom vid provider *)
module MakeWithVid (VidProvider : VidProvider) = struct
  (* Incremental hashing: compute hash from value' using child vhash values 
     -> O(width) not O(tree-size) *)
  let hash_of (v : value') : int =
    let ( +! ) h1 h2 = (h1 * 65599) + h2 in
    let hash_atom (atom : Xl.Atom.t) : int = Hashtbl.hash atom in

    let hash_num (num : Xl.Num.t) : int =
      match num with
      | `Nat n -> 0 +! Bigint.hash n
      | `Int i -> 1 +! Bigint.hash i
    in

    let hash_mixop (mixop : Xl.Mixop.t) : int =
      List.fold_left
        (fun hash atoms ->
          List.fold_left
            (fun hash atom -> hash +! hash_atom atom.Common.Source.it)
            hash atoms)
        2 mixop
    in
    match v with
    | BoolV b -> 0 +! Hashtbl.hash b
    | NumV n -> 1 +! hash_num n
    | TextV s -> 2 +! Hashtbl.hash s
    | StructV fields ->
        List.fold_left
          (fun hash (atom, v) ->
            hash +! (hash_atom atom.Common.Source.it +! v.note.vhash))
          3 fields
    | CaseV (mixop, values) ->
        let base_hash = 4 +! hash_mixop mixop in
        List.fold_left (fun hash v -> hash +! v.note.vhash) base_hash values
    | TupleV values ->
        List.fold_left (fun hash v -> hash +! v.note.vhash) 5 values
    | OptV None -> 6
    | OptV (Some v) -> 7 +! v.note.vhash
    | ListV values ->
        List.fold_left (fun hash v -> hash +! v.note.vhash) 8 values
    | FuncV id -> 9 +! Hashtbl.hash id.Common.Source.it
    | BytesV { num; len } -> 10 +! Bigint.hash num +! Hashtbl.hash len

  let with_fresh_vid (typ : typ') (vhash : int) : vnote =
    let vid = VidProvider.fresh () in
    { vid; vhash; typ; provenance = [] }

  let make_val (typ : typ') (v : value') : t =
    let vhash = hash_of v in
    v $$$ with_fresh_vid typ vhash

  let with_provenance (p : json_provenance) (v : t) : t =
    { v with note = { v.note with provenance = [ p ] } }

  let with_merged_provenance (sources : t list) (result : t) : t =
    let provs = List.concat_map (fun v -> v.note.provenance) sources in
    let deduped = List.sort_uniq Stdlib.compare provs in
    if deduped = [] then result
    else { result with note = { result.note with provenance = deduped } }

  let add_provenance (provs : json_provenance list) (v : t) : t =
    if provs = [] then v
    else
      let merged = List.sort_uniq Stdlib.compare (v.note.provenance @ provs) in
      { v with note = { v.note with provenance = merged } }

  module Make = struct
    let value (t' : typ') (v : value') : t = make_val t' v
    let bool (t' : typ') (b : bool) : t = make_val t' (BoolV b)
    let num (t' : typ') (n : num) : t = make_val t' (NumV n)
    let nat (t' : typ') (n : Bigint.t) : t = make_val t' (NumV (`Nat n))
    let int (t' : typ') (n : Bigint.t) : t = make_val t' (NumV (`Int n))
    let text (t' : typ') (s : string) : t = make_val t' (TextV s)
    let tuple (t' : typ') (vs : t list) : t = make_val t' (TupleV vs)

    let record (t' : typ') (fs : valuefield list) : value =
      make_val t' (StructV fs)

    let opt (t' : typ') (v : t option) : t = make_val t' (OptV v)
    let list (t' : typ') (vs : t list) : t = make_val t' (ListV vs)

    let case (t' : typ') (cases : mixop * value list) : t =
      make_val t' (CaseV cases)
  end

  let make_bytes ~(num : Bigint.t) ~(len : int) : t =
    make_val (NumT `NatT) (BytesV { num; len })

  let bool (b : bool) : t = Make.bool Typ.bool b
  let nat (i : Bigint.t) : t = Make.nat Typ.nat i
  let int (i : Bigint.t) : t = Make.int Typ.int i
  let text (s : string) : t = Make.text Typ.text s
  let func (id : id) : t = FuncV id |> make_val Typ.func

  let record (tid : string) (fields : valuefield list) : t =
    Make.record (Typ.var tid []) fields

  let tuple (vs : t list) : t =
    let typs = List.map (fun v -> v.note.typ $ no_region) vs in
    TupleV vs |> make_val (Typ.tuple typs)

  let opt (typ : typ) (v : t option) : t = OptV v |> make_val (Typ.opt typ)
  let list (typ : typ) (vs : t list) : t = ListV vs |> make_val (Typ.list typ)
  let list' (typ : typ') (vs : t list) : t = list (typ $ no_region) vs
end

(* Default instance using global provider *)
module DefaultVidProvider = struct
  let fresh () = GlobalVidProvider.fresh ()
end

(* Default module instance *)
module Default = MakeWithVid (DefaultVidProvider)

(* Export default as main module for backward compatibility *)
include Default

let get_bool (value : t) =
  match value.it with BoolV b -> b | _ -> failwith "get_bool"

let get_num (value : t) =
  match value.it with
  | NumV n -> n
  | BytesV { num; _ } -> `Nat num
  | _ -> failwith "get_num"

let get_text (value : t) =
  match value.it with TextV s -> s | _ -> failwith "get_text"

let get_list (value : t) =
  match value.it with ListV values -> values | _ -> failwith "unseq"

let get_opt (value : t) =
  match value.it with OptV value -> value | _ -> failwith "get_opt"

let get_struct (value : t) =
  match value.it with StructV fields -> fields | _ -> failwith "get_struct"

(* Bytes *)

let get_bytes (value : t) =
  match value.it with
  | BytesV { num; len } -> (num, len)
  | _ -> failwith "get_bytes"
