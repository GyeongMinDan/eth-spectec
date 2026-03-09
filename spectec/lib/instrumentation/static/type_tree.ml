(* Static type tree - expands IL type definitions into fully resolved types.
 *
 * The IL AST has `typ'` (syntactic types) and `deftyp'` (type definitions).
 * This module resolves all VarT aliases into a single expanded representation,
 * enabling type-aware mutations without re-walking the spec on every query.
 *
 * Naming mirrors the IL AST: BoolT, NumT, TextT, StructT, IterT.
 * Added: BytesT (bytes aliases resolved to byte widths), OpaqueT (fallback).
 *)

module Il = Lang.Il
module Atom = Lang.Xl.Atom

(* === Expanded type representation ===
 *
 * Mirrors Il.typ' but with all VarT aliases resolved inline.
 * StructT fields use lowercase string names (from Atom.string_of_atom).
 * BytesT is a resolved form of the bytes/bytes32/... VarT aliases.
 *)
type iter = List | Opt (* mirrors Il.iter *)

type typ =
  | BoolT
  | NumT of [ `NatT | `IntT ]
  | TextT
  | BytesT of int (* byte width; 0 = variable-length (plain `bytes`) *)
  | StructT of field list
  | IterT of typ * iter
  | OpaqueT of string (* unresolvable type name, kept for completeness *)

and field = { fname : string; ftyp : typ }

(* === Building the expanded type map === *)

(* Known bytes-alias widths, keyed by lowercase type name *)
let bytes_widths =
  [
    ("bytes", 0);
    ("bytes1", 1);
    ("bytes4", 4);
    ("bytes8", 8);
    ("bytes20", 20);
    ("bytes28", 28);
    ("bytes31", 31);
    ("bytes32", 32);
    ("bytes48", 48);
    ("bytes96", 96);
    ("bytes256", 256);
  ]

let atom_name (atom : Il.atom) : string =
  match atom.it with
  | Atom.Atom s | Atom.SilentAtom s -> s
  | other -> Atom.string_of_atom other

(* Resolve an Il.typ' to our expanded typ, given a name→typ lookup *)
let rec resolve (lookup : string -> typ option) (t : Il.typ') : typ =
  match t with
  | Il.BoolT -> BoolT
  | Il.NumT `NatT -> NumT `NatT
  | Il.NumT `IntT -> NumT `IntT
  | Il.TextT -> TextT
  | Il.FuncT -> OpaqueT "func"
  | Il.TupleT _ -> OpaqueT "tuple"
  | Il.IterT (inner, Il.List) -> IterT (resolve lookup inner.it, List)
  | Il.IterT (inner, Il.Opt) -> IterT (resolve lookup inner.it, Opt)
  | Il.VarT (id, _) -> (
      let name = id.it in
      match lookup name with
      | Some resolved -> resolved
      | None -> (
          match List.assoc_opt (String.lowercase_ascii name) bytes_widths with
          | Some w -> BytesT w
          | None -> OpaqueT name))

(* Expand an Il.deftyp' into our typ *)
let expand_deftyp (lookup : string -> typ option) (dt : Il.deftyp') : typ option
    =
  match dt with
  | Il.PlainT typ -> Some (resolve lookup typ.it)
  | Il.StructT fields ->
      let expanded =
        List.map
          (fun ((atom : Il.atom), (typ : Il.typ)) ->
            { fname = atom_name atom; ftyp = resolve lookup typ.it })
          fields
      in
      Some (StructT expanded)
  | Il.VariantT _ -> None (* Variant types aren't used for mutations *)

(* Collect (name, deftyp') pairs from the spec *)
let collect_defs (spec : Il.spec) : (string * Il.deftyp') list =
  List.filter_map
    (fun (def : Il.def) ->
      match def.it with
      | Il.TypD (id, _tparams, deftyp) -> Some (id.it, deftyp.it)
      | _ -> None)
    spec

(* Build the fully expanded type map.
 * Iterates until fixpoint: types that reference not-yet-expanded names get
 * OpaqueT on early passes and are resolved on later ones.
 * Terminates because the spec has no recursive types. *)
let build_type_map (spec : Il.spec) : (string, typ) Hashtbl.t =
  let defs = collect_defs spec in
  let tbl : (string, typ) Hashtbl.t = Hashtbl.create 128 in
  let lookup name = Hashtbl.find_opt tbl name in
  let changed = ref true in
  let passes = ref 0 in
  while !changed && !passes < 20 do
    changed := false;
    incr passes;
    List.iter
      (fun (name, deftyp) ->
        match expand_deftyp lookup deftyp with
        | None -> ()
        | Some node ->
            let prev = Hashtbl.find_opt tbl name in
            if prev <> Some node then (
              Hashtbl.replace tbl name node;
              changed := true))
      defs
  done;
  tbl

(* === Random value generation === *)

let random_hex (byte_len : int) : string =
  let hex = "0123456789abcdef" in
  let buf = Buffer.create (byte_len * 2) in
  for _ = 1 to byte_len * 2 do
    Buffer.add_char buf hex.[Random.int 16]
  done;
  "0x" ^ Buffer.contents buf

let rec random_value (t : typ) : Yojson.Safe.t =
  match t with
  | BoolT -> `Bool (Random.bool ())
  | NumT _ -> `Intlit (string_of_int (Random.int 100))
  | TextT -> `String ""
  | BytesT 0 -> `String (random_hex 32) (* variable-length: default 32 bytes *)
  | BytesT n -> `String (random_hex n)
  | StructT fs -> `Assoc (List.map (fun f -> (f.fname, random_value f.ftyp)) fs)
  | IterT (_, _) -> `List [] (* callers append elements explicitly *)
  | OpaqueT _ -> `Null

(* Fill missing fields in a JSON value using the type tree.
 * Existing values are preserved; only absent struct fields are generated. *)
let rec template_fill (t : typ) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match (t, json) with
  | StructT fields, `Assoc existing ->
      let lower_existing =
        List.map (fun (k, v) -> (String.lowercase_ascii k, (k, v))) existing
      in
      `Assoc
        (List.map
           (fun f ->
             match
               List.assoc_opt (String.lowercase_ascii f.fname) lower_existing
             with
             | Some (orig_k, v) -> (orig_k, template_fill f.ftyp v)
             | None -> (f.fname, random_value f.ftyp))
           fields)
  | IterT (elem_t, _), `List items ->
      `List (List.map (template_fill elem_t) items)
  | _ -> json

(* Generate a fresh random list element for a IterT(_, List) node *)
let random_element (t : typ) : Yojson.Safe.t option =
  match t with IterT (elem_t, List) -> Some (random_value elem_t) | _ -> None

(* Generate a list element using an existing item as a structural template *)
let random_element_from (t : typ) (template : Yojson.Safe.t) :
    Yojson.Safe.t option =
  match t with
  | IterT (elem_t, List) -> Some (template_fill elem_t template)
  | _ -> None

(* === Static.S interface === *)

module State = struct
  let tbl : (string, typ) Hashtbl.t = Hashtbl.create 128
  let reset () = Hashtbl.clear tbl
end

type export_data = (string * typ) list

let name = "type_tree"

(* === Debug pretty-printer === *)

let rec string_of_typ ?(indent = 0) (t : typ) : string =
  let pad = String.make (indent * 2) ' ' in
  match t with
  | BoolT -> "bool"
  | NumT `NatT -> "nat"
  | NumT `IntT -> "int"
  | TextT -> "text"
  | BytesT 0 -> "bytes"
  | BytesT n -> Printf.sprintf "bytes%d" n
  | StructT fs ->
      let inner =
        String.concat ",\n"
          (List.map
             (fun f ->
               Printf.sprintf "%s  %s: %s" pad f.fname
                 (string_of_typ ~indent:(indent + 1) f.ftyp))
             fs)
      in
      Printf.sprintf "{\n%s\n%s}" inner pad
  | IterT (t, List) -> string_of_typ ~indent t ^ "*"
  | IterT (t, Opt) -> string_of_typ ~indent t ^ "?"
  | OpaqueT s -> Printf.sprintf "<%s>" s

let init (spec : Static.spec) =
  State.reset ();
  (match spec with
  | Static.IlSpec il_spec ->
      let built = build_type_map il_spec in
      Hashtbl.iter (Hashtbl.replace State.tbl) built
  | _ -> ());
  let names =
    Hashtbl.fold (fun k _ acc -> k :: acc) State.tbl []
    |> List.sort String.compare
  in
  Format.eprintf "[TypeTree] Loaded %d types: %s\n%!" (Hashtbl.length State.tbl)
    (String.concat ", " names)

let reset () = State.reset ()

let export () : export_data option =
  Some (Hashtbl.fold (fun k v acc -> (k, v) :: acc) State.tbl [])

let restore (data : export_data) =
  State.reset ();
  List.iter (fun (k, v) -> Hashtbl.replace State.tbl k v) data

(* Resolve an Il.typ' using the current type map.
 * Callers with an Il.typ' can get a fully expanded typ without re-walking the spec. *)
let resolve_il_typ (t : Il.typ') : typ = resolve (Hashtbl.find_opt State.tbl) t

(* === Public query API === *)

let lookup (name : string) : typ option = Hashtbl.find_opt State.tbl name

let lookup_ci (name : string) : typ option =
  match lookup name with
  | Some _ as r -> r
  | None ->
      let target = String.lowercase_ascii name in
      Hashtbl.fold
        (fun k v acc ->
          if acc = None && String.lowercase_ascii k = target then Some v
          else acc)
        State.tbl None

let all_type_names () : string list =
  Hashtbl.fold (fun k _ acc -> k :: acc) State.tbl []
