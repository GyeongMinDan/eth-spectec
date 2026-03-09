(* Testgen backend - generates test cases by mutating JSON inputs to target uncovered premises.

   Pipeline:
   1. Run test suite with node-coverage-il to get premise-to-testid mapping
   2. Select uncovered premise UIDs to target
   3. Derive mutation constraints from positive dependency analysis
   4. Mutate JSON inputs; write results to output directory *)

open Common.Source
module Il = Lang.Il
module Checkpoint = Checkpoint
module Dep = Instrumentation.Dependency.Dep_common
module Pos = Instrumentation.Dependency.Positive
module Node_cov = Instrumentation.Node_coverage_il
module Type_tree = Instrumentation.Type_tree

(* ===== Types ===== *)

type premise_uid = int
type test_case_id = string
type field_path = Dep.field_path

type mutation_constraint = {
  field_path : field_path;
  strategies : Json_mutator.mutation_strategy list;
  suggestion_str : string option;
  class_key : string; (* structural path key — outer group for report layout *)
  sampling_key : string;
      (* structural path + op class — inner group for sampling;
         same class_key but different ops → different sampling_key *)
  group_total : int;
      (* how many sym_mutations were in this sampling group before sampling *)
}

type premise_info = {
  uid : premise_uid;
  key : region * string;
  relation : string;
  rule : string;
  content : string;
}

(* Successful mutation outcome *)
type mutation_ok = {
  field : field_path;
  prems : premise_uid list;
  suggestion : string option;
  class_key : string; (* structural path key — outer grouping for the report *)
  sampling_key : string;
      (* structural path + op class — inner grouping within class_key *)
  total_variants : int;
      (* sampling group size before sampling; 1 = not grouped *)
  from_val : string;
  to_vals : string list; (* one entry per successfully applied strategy *)
  mut_ids : string list; (* parallel to to_vals — the mut_... directory name *)
}

(* Outcome of one (constraint × all-strategies) attempt, for reporting only. *)
type constraint_outcome =
  | MutationOk of mutation_ok
  | FieldNotFound of {
      field : field_path;
      prems : premise_uid list;
      src_label : string;
    }
  | JsonLoadFailed of { field : field_path; prems : premise_uid list }

(* All diagnostic data produced by process_test_case.
   Never drives control flow — consumed only by the presentation layer. *)
type process_diag = {
  prems_no_muts : premise_uid list;
  prems_no_constraints : premise_uid list;
  constraint_outcomes : constraint_outcome list;
  covered_prems : premise_uid list;
  raw_suggestions : (premise_uid * Pos.sym_mutation list) list;
      (* one entry per puid that returned ≥1 suggestion, before sampling *)
}

(* ===== Slot-gap utilities ===== *)

let json_to_int = function
  | `Int n -> Some n
  | `Intlit s | `String s -> (
      try Some (int_of_string s) with Failure _ -> None)
  | _ -> None

let json_get_int (json : Yojson.Safe.t) (path : Dep.field_step list) :
    int option =
  Option.bind (Json_mutator.get_field json path) json_to_int

let state_slot_path = [ Dep.FieldAccess "slot" ]
let block_msg_slot_path = [ Dep.FieldAccess "message"; Dep.FieldAccess "slot" ]
let block_slot_path = [ Dep.FieldAccess "slot" ]
let get_state_slot (json : Yojson.Safe.t) = json_get_int json state_slot_path

(* Tries message.slot first (signed block envelope), then slot directly. *)
let get_block_slot (json : Yojson.Safe.t) =
  match json_get_int json block_msg_slot_path with
  | Some _ as r -> r
  | None -> json_get_int json block_slot_path

let get_slot_gap (pre_json : Yojson.Safe.t) (block_json : Yojson.Safe.t) :
    int option =
  match (get_state_slot pre_json, get_block_slot block_json) with
  | Some s, Some b -> Some (b - s)
  | _ -> None

(* Strip /pre.json suffix to get the test case directory path. *)
let test_id_to_dir (test_id : string) : string =
  if String.ends_with ~suffix:"/pre.json" test_id then
    String.sub test_id 0 (String.length test_id - 9)
  else test_id

(* The spec's main loop replays state transitions from state.slot up to block.slot - 1.
   Large gaps cause extremely slow execution; this checks whether a seed is within the limit. *)
let slot_gap_within_limit ~(test_dir : string) ~(max_slot_gap : int)
    (test_id : string) : bool =
  let dir = test_id_to_dir test_id in
  let load f = try Some (Json_mutator.load_json f) with _ -> None in
  match
    ( load (Filename.concat test_dir (dir ^ "/pre.json")),
      load (Filename.concat test_dir (dir ^ "/block.json")) )
  with
  | Some pre, Some block -> (
      match get_slot_gap pre block with
      | Some gap -> gap <= max_slot_gap
      | None -> true)
  | _ -> true

(* Cap block_slot so that block_slot - state_slot <= max_slot_gap. *)
let cap_slot_gap ~(max_slot_gap : int) (pre_json : Yojson.Safe.t)
    (block_json : Yojson.Safe.t) : Yojson.Safe.t =
  match (get_slot_gap pre_json block_json, get_state_slot pre_json) with
  | Some gap, Some state_slot when gap > max_slot_gap ->
      let capped = `Intlit (string_of_int (state_slot + max_slot_gap)) in
      let slot_path =
        if Option.is_some (json_get_int block_json block_msg_slot_path) then
          block_msg_slot_path
        else block_slot_path
      in
      Json_mutator.set_field block_json slot_path capped
  | _ -> block_json

(* Walk a type tree node following field_step list. Case-insensitive field name match. *)
let rec type_at_steps (typ : Type_tree.typ) (steps : Dep.field_step list) :
    Type_tree.typ option =
  match steps with
  | [] -> Some typ
  | Dep.FieldAccess name :: rest -> (
      match typ with
      | Type_tree.StructT fields -> (
          match
            List.find_opt
              (fun f ->
                String.lowercase_ascii f.Type_tree.fname
                = String.lowercase_ascii name)
              fields
          with
          | Some field -> type_at_steps field.Type_tree.ftyp rest
          | None -> None)
      | _ -> None)
  | Dep.IndexAccess _ :: rest -> (
      match typ with
      | Type_tree.IterT (elem_typ, Type_tree.List) ->
          type_at_steps elem_typ rest
      | _ -> None)

(* Map a Dep.source to the root type name in the type tree.
   Block paths start with 'message', consistent with signedBeaconBlock. *)
let source_root_type_name = function
  | Dep.State -> Some "beaconState"
  | Dep.Block -> Some "signedBeaconBlock"

(* Resolve the expanded type at a full field path via the type tree.
   Returns None when the root type is unknown or the path cannot be walked
   (falls back to the name heuristic in is_list_field). *)
let field_path_type (path : field_path) : Type_tree.typ option =
  match source_root_type_name path.source with
  | None -> None
  | Some root_name -> (
      match Type_tree.lookup_ci root_name with
      | None -> None
      | Some root_typ -> type_at_steps root_typ path.steps)

(* Returns true if the field at path is list-typed, using type tree resolution. *)
let is_list_field (path : field_path) : bool =
  match field_path_type path with
  | Some (Type_tree.IterT (_, Type_tree.List)) -> true
  | Some _ -> false (* known non-list type *)
  | None ->
      let root_opt = source_root_type_name path.source in
      let root_found = Option.bind root_opt Type_tree.lookup_ci in
      Format.eprintf
        "[Testgen] is_list_field: type tree returned None for path %s\n\
        \  source root name: %s\n\
        \  root lookup: %s\n\
         %!"
        (Dep.string_of_field_path path)
        (Option.value ~default:"<none>" root_opt)
        (match root_found with Some _ -> "found" | None -> "NOT FOUND");
      assert false

(* Build an AppendRandom strategy using the type tree, templated from the first existing element. *)
let make_append_random_strategy (field_name : string)
    (source_value : Yojson.Safe.t) : Json_mutator.mutation_strategy option =
  match Type_tree.lookup_ci field_name with
  | None -> None
  | Some elem_typ ->
      let new_elem =
        match source_value with
        | `List (first :: _) -> Type_tree.template_fill elem_typ first
        | _ -> Type_tree.random_value elem_typ
      in
      Some (Json_mutator.AppendRandom new_elem)

(* ===== Strategy generation ===== *)

let max_uint64 = Bigint.of_string "18446744073709551615"
let min_value = Bigint.of_int 0

let extract_numeric_value (v : Il.Value.t) : Bigint.t option =
  match v.it with Il.NumV (`Nat n) | Il.NumV (`Int n) -> Some n | _ -> None

let bigint_to_intlit (n : Bigint.t) : string = Bigint.to_string n

(* Extract a string key from an IL atom (lowercase). *)
let atom_key (atom : Il.atom) : string =
  match atom.it with
  | Lang.Xl.Atom.Atom s | Lang.Xl.Atom.SilentAtom s -> String.lowercase_ascii s
  | other -> String.lowercase_ascii (Lang.Xl.Atom.string_of_atom other)

(* Replace a field in a JSON object by (case-insensitive) key. *)
let replace_json_field (json : Yojson.Safe.t) (key : string)
    (new_val : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (k, v) ->
             if String.lowercase_ascii k = key then (k, new_val) else (k, v))
           fields)
  | _ -> json

let value_to_json (v : Il.Value.t) : (Yojson.Safe.t, string) result =
  match Interface.JSON.Print.value_to_json v with
  | Ok json -> Ok json
  | Error err -> Error (Interface.JSON.Print.string_of_error err)

(* Generate mutation strategies for a ToConst constraint.
   For each comparison operator, produces values that satisfy the constraint (e.g., >= n → [n, MAX]). *)
let generate_toconst_strategies (op : Il.cmpop) (value : Il.Value.t)
    (source_value_opt : Yojson.Safe.t option) :
    Json_mutator.mutation_strategy list =
  match value.it with
  | Il.BoolV b -> (
      match source_value_opt with
      | Some (`Bool src) -> [ Json_mutator.SetValue (`Bool (not src)) ]
      | _ -> [ Json_mutator.SetValue (`Bool (not b)) ])
  | _ -> (
      match extract_numeric_value value with
      | Some n -> (
          let n_str = bigint_to_intlit n in
          let max_str = bigint_to_intlit max_uint64 in
          let min_str = bigint_to_intlit min_value in
          match op with
          | `GeOp ->
              [
                Json_mutator.SetValue (`Intlit n_str);
                Json_mutator.SetValue (`Intlit max_str);
              ]
          | `LeOp ->
              [
                Json_mutator.SetValue (`Intlit n_str);
                Json_mutator.SetValue (`Intlit min_str);
              ]
          | `GtOp -> (
              match Bigint.to_int n with
              | Some i ->
                  [
                    Json_mutator.SetValue
                      (`Intlit (bigint_to_intlit (Bigint.of_int (i + 1))));
                    Json_mutator.SetValue (`Intlit max_str);
                  ]
              | None -> [ Json_mutator.SetValue (`Intlit max_str) ])
          | `LtOp -> (
              match Bigint.to_int n with
              | Some i when i > 0 ->
                  [
                    Json_mutator.SetValue
                      (`Intlit (bigint_to_intlit (Bigint.of_int (i - 1))));
                    Json_mutator.SetValue (`Intlit max_str);
                  ]
              | _ -> [ Json_mutator.SetValue (`Intlit max_str) ])
          | `EqOp -> [ Json_mutator.SetValue (`Intlit n_str) ]
          | `NeOp -> (
              match Bigint.to_int n with
              | Some i ->
                  let lo = if i > 0 then Bigint.of_int (i - 1) else min_value in
                  [
                    Json_mutator.SetValue (`Intlit (bigint_to_intlit lo));
                    Json_mutator.SetValue
                      (`Intlit (bigint_to_intlit (Bigint.of_int (i + 1))));
                  ]
              | None -> [ Json_mutator.SetValue (`Intlit n_str) ]))
      | None -> (
          match value_to_json value with
          | Ok json -> [ Json_mutator.SetValue json ]
          | Error _ -> []))

(* Generate mutation strategies for a ToLength constraint (list-length variant of ToConst). *)
let generate_tolength_strategies (op : Il.cmpop) (value : Il.Value.t) :
    Json_mutator.mutation_strategy list =
  match extract_numeric_value value with
  | None -> [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ]
  | Some n -> (
      match Bigint.to_int n with
      | None -> [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ]
      | Some n_int -> (
          match op with
          | `GeOp ->
              [
                Json_mutator.SetLength n_int; Json_mutator.SetLength (2 * n_int);
              ]
          | `LeOp -> [ Json_mutator.SetLength n_int; Json_mutator.SetLength 0 ]
          | `GtOp ->
              [
                Json_mutator.SetLength (n_int + 1);
                Json_mutator.SetLength (2 * n_int);
              ]
          | `LtOp ->
              if n_int > 0 then
                [
                  Json_mutator.SetLength (n_int - 1);
                  Json_mutator.SetLength (2 * n_int);
                ]
              else [ Json_mutator.SetLength (2 * n_int) ]
          | `EqOp -> [ Json_mutator.SetLength n_int ]
          | `NeOp ->
              if n_int > 0 then
                [
                  Json_mutator.SetLength (n_int - 1);
                  Json_mutator.SetLength (n_int + 1);
                ]
              else [ Json_mutator.SetLength (n_int + 1) ]))

(* Strategies for Unknown hints carrying a concrete IL value (boundary + complement). *)
let rec strategies_from_il_value (v : Il.Value.t) :
    Json_mutator.mutation_strategy list =
  match v.it with
  | Il.NumV (`Nat _) | Il.NumV (`Int _) ->
      [
        Json_mutator.SetValue (`Intlit "0");
        Json_mutator.SetValue (`Intlit "18446744073709551615");
      ]
  | Il.BytesV { len; _ } ->
      [
        Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) '0'));
        Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) 'f'));
      ]
  | Il.BoolV _ ->
      [
        Json_mutator.SetValue (`Bool true); Json_mutator.SetValue (`Bool false);
      ]
  | Il.ListV items ->
      let n = List.length items in
      if n = 0 then []
      else [ Json_mutator.SetLength (2 * n); Json_mutator.SetLength 0 ]
  | Il.StructV valuefield_list -> (
      match value_to_json v with
      | Error _ -> []
      | Ok struct_json ->
          List.filter_map
            (fun (atom, field_val) ->
              let key = atom_key atom in
              match strategies_from_il_value field_val with
              | Json_mutator.SetValue new_scalar :: _ ->
                  Some
                    (Json_mutator.SetValue
                       (replace_json_field struct_json key new_scalar))
              | _ -> None)
            valuefield_list
          |> fun strats -> List.filteri (fun i _ -> i < 3) strats)
  | _ -> []

(* Strategies for Unknown hints carrying only a type name (boundary values per type). *)
let strategies_from_il_type (t : Il.typ') : Json_mutator.mutation_strategy list
    =
  match t with
  | Il.NumT (`NatT | `IntT) ->
      [
        Json_mutator.SetValue (`Intlit "0");
        Json_mutator.SetValue (`Intlit "18446744073709551615");
      ]
  | Il.BoolT ->
      [
        Json_mutator.SetValue (`Bool true); Json_mutator.SetValue (`Bool false);
      ]
  | Il.TextT ->
      [
        Json_mutator.SetValue (`String "");
        Json_mutator.SetValue (`String "mutated_string");
      ]
  | Il.VarT (id, _) ->
      let name = String.lowercase_ascii id.it in
      if String.length name >= 5 && String.sub name 0 5 = "bytes" then
        let len =
          try int_of_string (String.sub name 5 (String.length name - 5))
          with _ -> 32
        in
        [
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) '0'));
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) 'f'));
        ]
      else if name = "boolean" || name = "bool" then
        [
          Json_mutator.SetValue (`Bool true);
          Json_mutator.SetValue (`Bool false);
        ]
      else if
        List.mem name
          [ "uint64"; "slot"; "epoch"; "validatorindex"; "nat"; "int" ]
      then
        [
          Json_mutator.SetValue (`Intlit "0");
          Json_mutator.SetValue (`Intlit "18446744073709551615");
        ]
      else if List.mem name [ "root"; "hash32"; "blspubkey"; "blssignature" ]
      then
        let len =
          if name = "blspubkey" || name = "blssignature" then 48 else 32
        in
        [
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) '0'));
          Json_mutator.SetValue (`String ("0x" ^ String.make (len * 2) 'f'));
        ]
      else []
  | _ -> []

let strategies_from_hint (hint : Pos.unknown_hint) :
    Json_mutator.mutation_strategy list =
  match hint with
  | Pos.ValueHint v -> strategies_from_il_value v
  | Pos.TypeHint t -> strategies_from_il_type t
  | Pos.NoHint -> []

let deduplicate_strategies (strategies : Json_mutator.mutation_strategy list) :
    Json_mutator.mutation_strategy list =
  List.sort_uniq
    (fun s1 s2 ->
      match (s1, s2) with
      | Json_mutator.SetValue v1, Json_mutator.SetValue v2 ->
          String.compare (Yojson.Safe.to_string v1) (Yojson.Safe.to_string v2)
      | Json_mutator.SetLength l1, Json_mutator.SetLength l2 -> compare l1 l2
      | Json_mutator.Increment i1, Json_mutator.Increment i2 -> compare i1 i2
      | Json_mutator.Decrement i1, Json_mutator.Decrement i2 -> compare i1 i2
      | _ -> compare s1 s2)
    strategies

(* ===== Mutation suggestion grouping and sampling ===== *)

(* Maximum representative samples to keep per sampling group. *)
let max_samples_per_group = 3

(* Structural field path: normalize all IndexAccess steps to index 0 so that
   validators[0].effective_balance and validators[42].effective_balance share
   the same structural key. *)
let structural_field_path (path : field_path) : field_path =
  let normalize = function Dep.IndexAccess _ -> Dep.IndexAccess 0 | s -> s in
  { path with steps = List.map normalize path.steps }

(* Human-readable structural path: show [*] in place of concrete indices. *)
let string_of_structural_field_path (path : field_path) : string =
  let source_str =
    match path.source with Dep.State -> "STATE" | Dep.Block -> "BLOCK"
  in
  let step_str = function
    | Dep.FieldAccess f -> "." ^ f
    | Dep.IndexAccess _ -> "[*]"
  in
  source_str ^ String.concat "" (List.map step_str path.steps)

(* Report-level class key: structural path only.
   All ops and all concrete indices for the same field shape share one key,
   so the report can group them under a single header. *)
let structural_path_key (path : field_path) : string =
  Dep.string_of_field_path (structural_field_path path)

(* Sampling key: structural path + mutation kind class.
   Different ops (e.g. "!= N" vs ">= M") for the same structural path are
   sampled independently; same op with different values / indices are sampled
   together. *)
let sym_mutation_sampling_key (m : Pos.sym_mutation) : string =
  match m.target_path with
  | None -> "__none__"
  | Some path -> (
      let spk = structural_path_key path in
      match m.suggestion with
      | Pos.ToLength (op, _) ->
          Printf.sprintf "%s|TL|%s" spk (Pos.string_of_cmp_op op)
      | Pos.ToConst (op, _) ->
          Printf.sprintf "%s|TC|%s" spk (Pos.string_of_cmp_op op)
      | Pos.Unknown _ -> Printf.sprintf "%s|UK" spk)

(* Extract a numeric sort key from a sym_mutation for ordering within a group. *)
let sym_mutation_numeric (m : Pos.sym_mutation) : int option =
  match m.suggestion with
  | Pos.ToLength (_, v) | Pos.ToConst (_, v) ->
      Option.bind (extract_numeric_value v) Bigint.to_int
  | Pos.Unknown _ -> None

(* Select up to n items evenly spaced from a list (first and last always included). *)
let evenly_sample (lst : 'a list) (n : int) : 'a list =
  let total = List.length lst in
  if total <= n then lst
  else
    let arr = Array.of_list lst in
    if n = 1 then [ arr.(0) ]
    else
      let indices =
        List.init n (fun i -> min (total - 1) (i * (total - 1) / (n - 1)))
      in
      List.map (Array.get arr) (List.sort_uniq compare indices)

(* Group sym_mutations by sampling key (structural path + op class), keep up to
   max_samples_per_group representatives evenly spaced by numeric value or
   array index.  Returns (sym_mutation * group_total) list. *)
let group_and_sample_sym_mutations (muts : Pos.sym_mutation list) :
    (Pos.sym_mutation * int) list =
  let groups : (string, Pos.sym_mutation list) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun m ->
      let k = sym_mutation_sampling_key m in
      let existing = Option.value ~default:[] (Hashtbl.find_opt groups k) in
      Hashtbl.replace groups k (m :: existing))
    muts;
  Hashtbl.fold
    (fun _k members acc ->
      let total = List.length members in
      (* Sort by: numeric value first, then concrete array index as fallback
         so that validators[0], validators[108], validators[217] are ordered
         when they all carry the same suggestion value. *)
      let sort_key m =
        match sym_mutation_numeric m with
        | Some n -> n
        | None -> (
            match m.Pos.target_path with
            | Some path -> (
                match List.rev path.steps with
                | Dep.IndexAccess i :: _ -> i
                | _ -> 0)
            | None -> 0)
      in
      let sorted =
        List.sort (fun m1 m2 -> compare (sort_key m1) (sort_key m2)) members
      in
      let selected = evenly_sample sorted max_samples_per_group in
      List.map (fun m -> (m, total)) selected @ acc)
    groups []

(* ===== Building mutation constraints ===== *)

(* Generate mutation strategies for a sym_mutation target path and suggestion. *)
let strategies_for_sym_mutation (target_path : field_path)
    (suggestion : Pos.mutation_kind) =
  match suggestion with
  | Pos.ToConst (op, v) ->
      if is_list_field target_path then
        match v.it with
        | Il.ListV items ->
            let n = List.length items in
            let len_val : Il.Value.t =
              { v with it = Il.NumV (`Nat (Bigint.of_int n)) }
            in
            generate_tolength_strategies op len_val
        | _ -> []
      else generate_toconst_strategies op v None
  | Pos.ToLength (op, v) -> generate_tolength_strategies op v
  | Pos.Unknown hint -> strategies_from_hint hint

(* A target path is valid if it names a specific field rather than the whole state or an unknown source. *)
let is_valid_target (path : field_path) : bool =
  not (path.source = Dep.State && path.steps = [])

(* Diagnose why a sym_mutation was filtered out. Returns None if it wasn't filtered. *)
let diagnose_filtered_mutation (sym_mut : Pos.sym_mutation) : string option =
  let truncate s n =
    if String.length s > n then String.sub s 0 n ^ "..." else s
  in
  match sym_mut.target_path with
  | None -> Some "no target path"
  | Some target_path when not (is_valid_target target_path) ->
      Some
        (Printf.sprintf "invalid target: %s"
           (Dep.string_of_field_path target_path))
  | Some target_path ->
      let is_list = is_list_field target_path in
      let strategies =
        strategies_for_sym_mutation target_path sym_mut.suggestion
        |> deduplicate_strategies
      in
      if strategies = [] then
        let kind_str =
          truncate (Pos.string_of_mutation_kind sym_mut.suggestion) 60
        in
        Some
          (Printf.sprintf "no strategies (is_list=%b, kind=%s, path=%s)" is_list
             kind_str
             (Dep.string_of_field_path target_path))
      else None

(* Convert a symbolic mutation from the dependency analysis into a mutation constraint.
   Returns None if the target is invalid or no strategies apply.
   [group_total] is the number of sym_mutations in the class group this was sampled from. *)
let sym_mutation_to_constraint ?(group_total = 1) (sym_mut : Pos.sym_mutation) :
    mutation_constraint option =
  match sym_mut.target_path with
  | None -> None
  | Some target_path when not (is_valid_target target_path) -> None
  | Some target_path ->
      let strategies =
        strategies_for_sym_mutation target_path sym_mut.suggestion
        |> deduplicate_strategies
      in
      if strategies = [] then None
      else
        Some
          {
            field_path = target_path;
            strategies;
            suggestion_str = Some (Pos.string_of_sym_mutation sym_mut);
            class_key = structural_path_key target_path;
            sampling_key = sym_mutation_sampling_key sym_mut;
            group_total;
          }

(* ===== Strategy application ===== *)

(* True if applying this strategy to source_value would be a no-op. *)
let is_identity_strategy (source_value : Yojson.Safe.t)
    (strategy : Json_mutator.mutation_strategy) : bool =
  match (source_value, strategy) with
  | `Bool a, Json_mutator.SetValue (`Bool b) -> a = b
  | `Int a, Json_mutator.SetValue (`Int b) -> a = b
  | `Intlit a, Json_mutator.SetValue (`Intlit b) -> a = b
  | `String a, Json_mutator.SetValue (`String b) -> a = b
  | `List lst, Json_mutator.SetLength n -> List.length lst = n
  | _ -> false

(* For boolean fields, flip the actual source value rather than a predetermined one. *)
let adjust_bool_strategy (source_value : Yojson.Safe.t)
    (strategy : Json_mutator.mutation_strategy) : Json_mutator.mutation_strategy
    =
  match (source_value, strategy) with
  | `Bool src, Json_mutator.SetValue (`Bool _) ->
      Json_mutator.SetValue (`Bool (not src))
  | _ -> strategy

(* For list paths with no pre-computed strategies, derive strategies from the source length. *)
let list_strategies_from_source (fp : field_path) source_value =
  match source_value with
  | `List [] -> []
  | `List lst ->
      let n = List.length lst in
      let len_strats =
        [ Json_mutator.SetLength (2 * n); Json_mutator.SetLength 0 ]
      in
      let append_strat =
        match List.rev fp.steps with
        | Dep.FieldAccess name :: _ ->
            make_append_random_strategy name source_value
        | _ -> None
      in
      len_strats @ Option.to_list append_strat
  | _ -> []

(* Compute the valid, adjusted strategies for a constraint given the current source value. *)
let resolve_strategies (constraint_ : mutation_constraint)
    (source_value : Yojson.Safe.t) : Json_mutator.mutation_strategy list =
  let is_list = is_list_field constraint_.field_path in
  let base =
    if source_value = `List [] then []
    else
      List.filter
        (fun s -> not (is_identity_strategy source_value s))
        constraint_.strategies
  in
  let extra =
    if is_list && constraint_.strategies = [] then
      list_strategies_from_source constraint_.field_path source_value
    else []
  in
  List.map (adjust_bool_strategy source_value) (base @ extra)

(* Look up the current value at the constraint's target path in the appropriate JSON. *)
let source_value_of_constraint (constraint_ : mutation_constraint)
    (pre_json_opt : Yojson.Safe.t option)
    (block_json_opt : Yojson.Safe.t option) : Yojson.Safe.t option =
  match (constraint_.field_path.source, pre_json_opt, block_json_opt) with
  | Dep.State, Some pre, _ ->
      Json_mutator.get_value_at_path pre constraint_.field_path
  | Dep.Block, _, Some blk ->
      Json_mutator.get_value_at_path blk constraint_.field_path
  | _ -> None

(* ===== Constraint deduplication helpers ===== *)

let strategy_to_display_string : Json_mutator.mutation_strategy -> string =
  function
  | Json_mutator.SetValue v -> Yojson.Safe.to_string v
  | Json_mutator.Increment i -> Printf.sprintf "+%d" i
  | Json_mutator.Decrement i -> Printf.sprintf "-%d" i
  | Json_mutator.SetBoundary -> "<boundary>"
  | Json_mutator.AppendItem -> "<append>"
  | Json_mutator.RemoveItem -> "<remove>"
  | Json_mutator.SetLength n -> string_of_int n
  | Json_mutator.AppendRandom _ -> "<append:random>"

(* Canonical string key for a strategy, used for deduplication. *)
let strategy_key : Json_mutator.mutation_strategy -> string = function
  | Json_mutator.SetValue v -> "SetValue:" ^ Yojson.Safe.to_string v
  | Json_mutator.SetLength n -> "SetLength:" ^ string_of_int n
  | Json_mutator.Increment i -> "Increment:" ^ string_of_int i
  | Json_mutator.Decrement i -> "Decrement:" ^ string_of_int i
  | Json_mutator.SetBoundary -> "SetBoundary"
  | Json_mutator.AppendItem -> "AppendItem"
  | Json_mutator.RemoveItem -> "RemoveItem"
  | Json_mutator.AppendRandom _ -> "AppendRandom"

let constraint_key (c : mutation_constraint) : string =
  Printf.sprintf "%s|%s"
    (Dep.string_of_field_path c.field_path)
    (String.concat "," (List.map strategy_key c.strategies))

let deduplicate_constraints (constraints : mutation_constraint list) :
    mutation_constraint list =
  let seen = Hashtbl.create (List.length constraints) in
  List.filter
    (fun c ->
      let k = constraint_key c in
      if Hashtbl.mem seen k then false
      else (
        Hashtbl.replace seen k ();
        true))
    constraints

(* ===== Coverage queries ===== *)

let get_uncovered_premises (coverage : Node_cov.result option) =
  match coverage with
  | None -> []
  | Some cov ->
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in
      List.filter_map
        (fun ((region, content_str), uid) ->
          let key = (region, content_str) in
          if List.mem key succeeded_keys then None
          else
            Some
              {
                uid;
                key;
                relation = "unknown";
                rule = "unknown";
                content = content_str;
              })
        cov.prem_to_uid

let get_test_cases_for_premise (puid : premise_uid)
    (coverage : Node_cov.result option) =
  match coverage with
  | None -> []
  | Some cov -> (
      let uid_to_key = List.to_seq cov.uid_to_prem |> Hashtbl.of_seq in
      match Hashtbl.find_opt uid_to_key puid with
      | None -> []
      | Some key ->
          let key_to_tests = List.to_seq cov.prem_to_test |> Hashtbl.of_seq in
          Hashtbl.find_opt key_to_tests key |> Option.value ~default:[])

let get_premise_info (puid : premise_uid) (coverage : Node_cov.result option) =
  match coverage with
  | None -> None
  | Some cov -> (
      let key =
        List.find_map
          (fun (uid, k) -> if uid = puid then Some k else None)
          cov.uid_to_prem
      in
      match key with
      | None -> None
      | Some ((_, content_str) as k) ->
          let test_cases = get_test_cases_for_premise puid coverage in
          Some
            ( {
                uid = puid;
                key = k;
                relation = "unknown";
                rule = "unknown";
                content = content_str;
              },
              test_cases ))

(* Build a mapping from test_id to the subset of target_uids that covered it. *)
let get_test_to_premises (target_uids : premise_uid list)
    (coverage : Node_cov.result option) =
  match coverage with
  | None -> []
  | Some cov ->
      let key_to_uid = Hashtbl.create 256 in
      List.iter
        (fun (key, uid) -> Hashtbl.add key_to_uid key uid)
        cov.prem_to_uid;
      let test_to_prems = Hashtbl.create 256 in
      List.iter
        (fun (prem_key, test_ids) ->
          match Hashtbl.find_opt key_to_uid prem_key with
          | Some uid when List.mem uid target_uids ->
              List.iter
                (fun test_id ->
                  let existing =
                    Hashtbl.find_opt test_to_prems test_id
                    |> Option.value ~default:[]
                  in
                  if not (List.mem uid existing) then
                    Hashtbl.replace test_to_prems test_id (uid :: existing))
                test_ids
          | _ -> ())
        cov.prem_to_test;
      Hashtbl.to_seq test_to_prems
      |> List.of_seq
      |> List.map (fun (test_id, uids) -> (test_id, List.sort compare uids))
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* Collect and filter sym_mutations for a single premise across all tests. *)
let get_mutation_suggestions_for_premise (puid : premise_uid)
    (dependency : Pos.result option) =
  match dependency with
  | None -> []
  | Some dep -> (
      match List.assoc_opt puid dep.per_test_sym_mutations with
      | None -> []
      | Some test_muts ->
          let all =
            List.fold_left (fun acc (_, muts) -> acc @ muts) [] test_muts
          in
          List.filter
            (fun (mut : Pos.sym_mutation) ->
              match mut.target_path with
              | None -> false
              | Some path -> is_valid_target path)
            all)

(* Collect and deduplicate sym_mutations for multiple premises filtered to a specific test_id. *)
let get_mutation_suggestions_for_premises (puids : premise_uid list)
    (_coverage : Node_cov.result option) (dependency : Pos.result option)
    (test_id : test_case_id) =
  match dependency with
  | None -> []
  | Some dep ->
      let all =
        List.fold_left
          (fun acc puid ->
            match List.assoc_opt puid dep.per_test_sym_mutations with
            | None -> acc
            | Some test_muts -> (
                match List.assoc_opt test_id test_muts with
                | None -> acc
                | Some muts -> acc @ muts))
          [] puids
      in
      let valid =
        List.filter
          (fun (mut : Pos.sym_mutation) ->
            match mut.target_path with
            | None -> false
            | Some path -> is_valid_target path)
          all
      in
      let compare_sym_mutation (m1 : Pos.sym_mutation) (m2 : Pos.sym_mutation) =
        match (m1.target_path, m2.target_path) with
        | Some p1, Some p2 -> (
            let path_cmp = compare p1 p2 in
            if path_cmp <> 0 then path_cmp
            else
              match (m1.suggestion, m2.suggestion) with
              | Pos.ToConst (op1, v1), Pos.ToConst (op2, v2) ->
                  let c = compare op1 op2 in
                  if c <> 0 then c
                  else
                    String.compare
                      (Il.Print.string_of_value v1)
                      (Il.Print.string_of_value v2)
              | Pos.ToLength (op1, v1), Pos.ToLength (op2, v2) ->
                  let c = compare op1 op2 in
                  if c <> 0 then c
                  else
                    String.compare
                      (Il.Print.string_of_value v1)
                      (Il.Print.string_of_value v2)
              | Pos.Unknown _, Pos.Unknown _ -> 0
              | Pos.ToConst _, _ -> -1
              | Pos.ToLength _, Pos.ToConst _ -> 1
              | Pos.ToLength _, _ -> -1
              | Pos.Unknown _, _ -> 1)
        | None, None -> 0
        | Some _, None -> -1
        | None, Some _ -> 1
      in
      List.sort_uniq compare_sym_mutation valid

let is_blacklisted (path : field_path) (blacklist : field_path list) : bool =
  List.mem path blacklist

let get_blacklisted_fields (_puid : premise_uid)
    (_coverage : Node_cov.result option) =
  []

(* ===== File I/O ===== *)

let mkdir_p (dir : string) : unit =
  try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let load_json_opt (path : string) : Yojson.Safe.t option =
  try Some (Json_mutator.load_json path) with _ -> None

(* Derive pre.json and block.json absolute paths from a test_id and base directory. *)
let test_case_paths ~(test_dir : string) (test_id : string) : string * string =
  let dir = test_id_to_dir test_id in
  ( Filename.concat test_dir (dir ^ "/pre.json"),
    Filename.concat test_dir (dir ^ "/block.json") )

(* Write mutated pre/block JSON files for a single mutation into a subdirectory.
   Returns output file paths, or input paths if mutation could not be applied. *)
let mutate_json_input ~output_dir ?(max_slot_gap : int option) (mut_id : string)
    (constraints : mutation_constraint list) (blacklisted : field_path list)
    (pre_path : string) (block_path : string) =
  let flat_id = String.map (fun c -> if c = '/' then '_' else c) mut_id in
  let mut_dir = Filename.concat output_dir flat_id in
  mkdir_p mut_dir;
  match (load_json_opt pre_path, load_json_opt block_path) with
  | None, _ | _, None -> (pre_path, block_path)
  | Some pre, Some block ->
      let apply_matching src_tag json =
        List.fold_left
          (fun acc c ->
            if is_blacklisted c.field_path blacklisted then acc
            else
              match (c.field_path.source, src_tag) with
              | Dep.State, "state" | Dep.Block, "block" -> (
                  match c.strategies with
                  | [] -> acc
                  | strategy :: _ ->
                      Json_mutator.mutate_json_file acc c.field_path strategy)
              | _ -> acc)
          json constraints
      in
      let mutated_pre = apply_matching "state" pre in
      let mutated_block_raw = apply_matching "block" block in
      let mutated_block =
        match max_slot_gap with
        | Some max_gap ->
            cap_slot_gap ~max_slot_gap:max_gap mutated_pre mutated_block_raw
        | None -> mutated_block_raw
      in
      let out_pre = Filename.concat mut_dir "pre.json" in
      let out_block = Filename.concat mut_dir "block.json" in
      Json_mutator.save_json out_pre mutated_pre;
      Json_mutator.save_json out_block mutated_block;
      (out_pre, out_block)

(* ===== Core test-case processing ===== *)

(* Apply constraints to a test case, writing mutation files.
   - constraints_with_prems: deduplicated constraints tagged with their premise UIDs
   Returns (result option, process_diag).
   result is Some (test_id, [...]) if any mutations were generated.
   process_diag holds all observability data; never drives control flow. *)
let process_test_case ~test_dir ~output_dir test_id prem_uids
    (dependency_result : Pos.result) =
  (* Collect and deduplicate constraints from all target premises.
     Track per-premise status for diagnostics. *)
  let constraint_map = Hashtbl.create 64 in
  let prem_no_muts = ref [] in
  let prem_no_constraints = ref [] in
  let raw_sugg_acc = ref [] in
  List.iter
    (fun puid ->
      let muts =
        get_mutation_suggestions_for_premise puid (Some dependency_result)
      in
      if muts = [] then prem_no_muts := puid :: !prem_no_muts
      else
        let any_constraint = ref false in
        let filtered_reasons = ref [] in
        raw_sugg_acc := (puid, muts) :: !raw_sugg_acc;
        let muts_sampled = group_and_sample_sym_mutations muts in
        List.iter
          (fun (sym_mut, group_total) ->
            match sym_mutation_to_constraint ~group_total sym_mut with
            | None -> (
                match diagnose_filtered_mutation sym_mut with
                | Some reason -> filtered_reasons := reason :: !filtered_reasons
                | None -> ())
            | Some c -> (
                any_constraint := true;
                let k = constraint_key c in
                match Hashtbl.find_opt constraint_map k with
                | None -> Hashtbl.replace constraint_map k (c, [ puid ])
                | Some (_, puids) when not (List.mem puid puids) ->
                    Hashtbl.replace constraint_map k (c, puid :: puids)
                | _ -> ()))
          muts_sampled;
        if not !any_constraint then (
          prem_no_constraints := puid :: !prem_no_constraints;
          Format.eprintf
            "[Testgen] uid=%d: %d mutations (%d sampled) but ALL filtered: %s\n\
             %!"
            puid (List.length muts) (List.length muts_sampled)
            (String.concat "; "
               (List.sort_uniq String.compare !filtered_reasons))))
    prem_uids;

  (* Collect all constraints for this seed. The same constraint key may appear
     across multiple seeds — that is intentional, since the same mutation applied
     to different base states can expose different implementation bugs. *)
  let all_constraints =
    Hashtbl.fold
      (fun _k (c, puids) acc -> (c, List.sort_uniq compare puids) :: acc)
      constraint_map []
  in

  let base_diag =
    {
      prems_no_muts = List.sort compare !prem_no_muts;
      prems_no_constraints = List.sort compare !prem_no_constraints;
      constraint_outcomes = [];
      covered_prems = [];
      raw_suggestions = List.rev !raw_sugg_acc;
    }
  in

  if all_constraints = [] then (None, base_diag)
  else
    let test_case_sanitized =
      String.map (fun c -> if c = '/' then '_' else c) test_id
    in
    let out_dir = Filename.concat output_dir test_case_sanitized in
    mkdir_p out_dir;

    let pre_path, block_path = test_case_paths ~test_dir test_id in
    let pre_json_opt = load_json_opt pre_path in
    let block_json_opt = load_json_opt block_path in

    let outcomes = ref [] in
    let local_covered : (premise_uid, unit) Hashtbl.t = Hashtbl.create 16 in
    let generated = ref [] in
    List.iteri
      (fun c_idx (constraint_, puids_for_constraint) ->
        match
          source_value_of_constraint constraint_ pre_json_opt block_json_opt
        with
        | None ->
            let src_label =
              match constraint_.field_path.source with
              | Dep.State -> "<not found in state>"
              | Dep.Block -> "<not found in block>"
            in
            outcomes :=
              FieldNotFound
                {
                  field = constraint_.field_path;
                  prems = puids_for_constraint;
                  src_label;
                }
              :: !outcomes
        | Some src ->
            let strats = resolve_strategies constraint_ src in
            let prem_str =
              String.concat "_"
                (List.map (Printf.sprintf "prem%d") puids_for_constraint)
            in
            (* Apply all strategies for this constraint; accumulate to_vals
               so the report shows one grouped entry per constraint. *)
            let to_vals = ref [] in
            let mut_ids = ref [] in
            List.iteri
              (fun s_idx strategy ->
                let mut_id =
                  Printf.sprintf "mut_%s_%d_%d" prem_str c_idx s_idx
                in
                let single = { constraint_ with strategies = [ strategy ] } in
                let out_pre, out_block =
                  mutate_json_input ~output_dir:out_dir mut_id [ single ] []
                    pre_path block_path
                in
                if out_pre <> pre_path then (
                  List.iter
                    (fun uid -> Hashtbl.replace local_covered uid ())
                    puids_for_constraint;
                  generated := (mut_id, out_pre, out_block) :: !generated;
                  to_vals := strategy_to_display_string strategy :: !to_vals;
                  mut_ids := mut_id :: !mut_ids))
              strats;
            if !to_vals <> [] then
              outcomes :=
                MutationOk
                  {
                    field = constraint_.field_path;
                    prems = puids_for_constraint;
                    suggestion = constraint_.suggestion_str;
                    class_key = constraint_.class_key;
                    sampling_key = constraint_.sampling_key;
                    total_variants = constraint_.group_total;
                    from_val =
                      (match src with
                      | `List items ->
                          Printf.sprintf "(%d items)" (List.length items)
                      | _ -> Yojson.Safe.to_string src);
                    to_vals = List.rev !to_vals;
                    mut_ids = List.rev !mut_ids;
                  }
                :: !outcomes
            else
              outcomes :=
                JsonLoadFailed
                  {
                    field = constraint_.field_path;
                    prems = puids_for_constraint;
                  }
                :: !outcomes)
      all_constraints;

    let covered_prems_list =
      Hashtbl.fold (fun uid () acc -> uid :: acc) local_covered []
    in
    let diag =
      {
        prems_no_muts = List.sort compare !prem_no_muts;
        prems_no_constraints = List.sort compare !prem_no_constraints;
        constraint_outcomes = List.rev !outcomes;
        covered_prems = List.sort_uniq compare covered_prems_list;
        raw_suggestions = List.rev !raw_sugg_acc;
      }
    in

    let result =
      if !generated = [] then None
      else Some (test_id, [ (List.hd prem_uids, List.rev !generated) ])
    in
    (result, diag)

(* Write a report.txt file for a processed seed.
   Pure presentation: reads only from diag, performs no branching on diag data. *)
let write_seed_report ~output_dir ~test_id ~prem_uids (diag : process_diag) =
  let test_case_sanitized =
    String.map (fun c -> if c = '/' then '_' else c) test_id
  in
  let out_dir = Filename.concat output_dir test_case_sanitized in
  let report_ch = open_out (Filename.concat out_dir "report.txt") in
  Printf.fprintf report_ch "Test Case: %s\n\nMutations for premises (%d): %s\n"
    test_id (List.length prem_uids)
    (String.concat ", " (List.map string_of_int prem_uids));
  if diag.prems_no_muts <> [] then
    Printf.fprintf report_ch "  No suggestions (%d): %s\n"
      (List.length diag.prems_no_muts)
      (String.concat ", " (List.map string_of_int diag.prems_no_muts));
  if diag.prems_no_constraints <> [] then
    Printf.fprintf report_ch "  No valid constraints (%d): %s\n"
      (List.length diag.prems_no_constraints)
      (String.concat ", " (List.map string_of_int diag.prems_no_constraints));
  (* Premises that had constraints but all field-lookups failed (FieldNotFound /
     JsonLoadFailed) — not in covered_prems, prems_no_muts, or prems_no_constraints. *)
  let prems_all_failed =
    List.sort compare
      (List.filter
         (fun uid ->
           (not (List.mem uid diag.covered_prems))
           && (not (List.mem uid diag.prems_no_muts))
           && not (List.mem uid diag.prems_no_constraints))
         prem_uids)
  in
  if prems_all_failed <> [] then
    Printf.fprintf report_ch "  All constraints failed (%d): %s\n"
      (List.length prems_all_failed)
      (String.concat ", " (List.map string_of_int prems_all_failed));
  Printf.fprintf report_ch "\n";
  (* Group constraint_outcomes by class_key (structural path) so that all
     mutations for the same field shape appear together, regardless of which
     op or which concrete array index was sampled. *)
  let outcome_class_key = function
    | MutationOk { class_key; _ } -> class_key
    | FieldNotFound { field; _ } -> structural_path_key field
    | JsonLoadFailed { field; _ } -> structural_path_key field
  in
  (* Stable group ordering: collect keys in first-seen order. *)
  let seen_keys : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let key_order = ref [] in
  List.iter
    (fun o ->
      let k = outcome_class_key o in
      if not (Hashtbl.mem seen_keys k) then (
        Hashtbl.replace seen_keys k ();
        key_order := k :: !key_order))
    diag.constraint_outcomes;
  let grouped : (string, constraint_outcome list) Hashtbl.t =
    Hashtbl.create 16
  in
  List.iter
    (fun o ->
      let k = outcome_class_key o in
      let existing = Option.value ~default:[] (Hashtbl.find_opt grouped k) in
      Hashtbl.replace grouped k (o :: existing))
    diag.constraint_outcomes;
  (* Extract the "kind" part of a suggestion string (after " → ").
     The arrow is UTF-8 U+2192 = bytes \xe2\x86\x92. *)
  let suggestion_kind s =
    let sep = " -> " in
    let sep_len = String.length sep in
    let s_len = String.length s in
    let rec find i =
      if i + sep_len > s_len then s
      else if String.sub s i sep_len = sep then
        String.sub s (i + sep_len) (s_len - i - sep_len)
      else find (i + 1)
    in
    find 0
  in
  let truncate_val s =
    let max = 60 in
    if String.length s <= max then s else String.sub s 0 max ^ "..."
  in
  List.iter
    (fun key ->
      let outcomes_for_key =
        List.rev (Option.value ~default:[] (Hashtbl.find_opt grouped key))
      in
      let ok_entries =
        List.filter_map
          (function MutationOk r -> Some r | _ -> None)
          outcomes_for_key
      in
      (* Does any entry in this group have a concrete index in its path? *)
      let has_index =
        List.exists
          (fun r ->
            List.exists
              (function Dep.IndexAccess _ -> true | _ -> false)
              r.field.steps)
          ok_entries
      in
      (* Structural display string and sampled index list *)
      let struct_str =
        match List.find_map (fun r -> Some r.field) ok_entries with
        | Some f -> string_of_structural_field_path f
        | None -> key
      in
      let sampled_indices =
        if has_index then
          List.filter_map
            (fun r ->
              List.find_map
                (function Dep.IndexAccess i -> Some i | _ -> None)
                r.field.steps)
            ok_entries
          |> List.sort_uniq compare
        else []
      in
      (* Group total from the first entry (all entries in one sampling key
         share the same group_total value since they were sampled together). *)
      let group_total_for_index =
        match ok_entries with r :: _ -> r.total_variants | [] -> 1
      in
      let field_header =
        if has_index && List.length sampled_indices > 1 then
          Printf.sprintf "%s  (i = %s; %d total)" struct_str
            (String.concat ", " (List.map string_of_int sampled_indices))
            group_total_for_index
        else struct_str
      in
      Printf.fprintf report_ch "  - Field: %s\n" field_header;
      (* Sub-group by sampling_key so that different ops on the same field
         (e.g. ">= 33" and "!= 1") appear as separate labelled blocks. *)
      let sub_seen = Hashtbl.create 4 in
      let sub_order = ref [] in
      List.iter
        (fun r ->
          if not (Hashtbl.mem sub_seen r.sampling_key) then (
            Hashtbl.replace sub_seen r.sampling_key ();
            sub_order := r.sampling_key :: !sub_order))
        ok_entries;
      let sub_grouped = Hashtbl.create 4 in
      List.iter
        (fun r ->
          let xs =
            Option.value ~default:[]
              (Hashtbl.find_opt sub_grouped r.sampling_key)
          in
          Hashtbl.replace sub_grouped r.sampling_key (r :: xs))
        ok_entries;
      List.iter
        (fun sk ->
          let sub_entries =
            List.rev
              (Option.value ~default:[] (Hashtbl.find_opt sub_grouped sk))
          in
          let sub_total =
            match sub_entries with r :: _ -> r.total_variants | [] -> 1
          in
          (* Print per-sub-group premises *)
          let sub_prems =
            List.sort_uniq compare
              (List.concat_map (fun r -> r.prems) sub_entries)
          in
          if sub_prems <> [] then
            Printf.fprintf report_ch "    Premises: %s\n"
              (String.concat ", " (List.map string_of_int sub_prems));
          (* Print each instance — no sub-group label; the kind string on each
             line already makes the suggestion clear. Each (mut_id, to_val)
             pair gets its own line. *)
          List.iter
            (fun r ->
              let kind_str =
                match r.suggestion with
                | Some s -> suggestion_kind s
                | None -> "?"
              in
              let variant_suffix =
                if sub_total > 1 then Printf.sprintf "  (group: %d)" sub_total
                else ""
              in
              let pairs = List.combine r.mut_ids r.to_vals in
              if has_index then
                let idx =
                  match
                    List.find_map
                      (function Dep.IndexAccess i -> Some i | _ -> None)
                      r.field.steps
                  with
                  | Some i -> i
                  | None -> -1
                in
                List.iter
                  (fun (mid, tval) ->
                    Printf.fprintf report_ch "    [i=%-4d] [%s]  %s%s  →  %s\n"
                      idx mid kind_str variant_suffix tval)
                  pairs
              else
                List.iter
                  (fun (mid, tval) ->
                    Printf.fprintf report_ch "    [%s]  %s%s  From: %s  →  %s\n"
                      mid kind_str variant_suffix (truncate_val r.from_val) tval)
                  pairs)
            sub_entries)
        (List.rev !sub_order);
      (* Append non-MutationOk failures for this group *)
      List.iter
        (fun outcome ->
          match outcome with
          | FieldNotFound { field; prems; src_label } ->
              Printf.fprintf report_ch
                "    [FAILED] field %s not found (%s)  prems: %s\n"
                (Dep.string_of_field_path field)
                src_label
                (String.concat ", " (List.map string_of_int prems))
          | JsonLoadFailed { field; prems } ->
              Printf.fprintf report_ch "    [FAILED] JSON load: %s  prems: %s\n"
                (Dep.string_of_field_path field)
                (String.concat ", " (List.map string_of_int prems))
          | MutationOk _ -> ())
        outcomes_for_key)
    (List.rev !key_order);
  let mutation_count =
    List.fold_left
      (fun acc -> function
        | MutationOk { to_vals; _ } -> acc + List.length to_vals | _ -> acc)
      0 diag.constraint_outcomes
  in
  let field_not_found_count =
    List.length
      (List.filter
         (function FieldNotFound _ -> true | _ -> false)
         diag.constraint_outcomes)
  in
  Printf.fprintf report_ch
    "\nResult: %d mutation(s) generated | %d field(s) not found\n"
    mutation_count field_not_found_count;
  close_out report_ch

(* Write suggestions.txt: all sym_mutations before sampling, grouped by
   structural path (outer) then by op (inner).  Within each op, each unique
   concrete index is listed once (deduplicating across test-case repetitions).
   This lets you verify that, e.g., all 40 validator indices were found before
   sampling reduced them to 3. *)
let write_suggestions_log ~output_dir ~test_id (diag : process_diag) =
  let test_case_sanitized =
    String.map (fun c -> if c = '/' then '_' else c) test_id
  in
  let out_dir = Filename.concat output_dir test_case_sanitized in
  let ch = open_out (Filename.concat out_dir "suggestions.txt") in
  Printf.fprintf ch "Test Case: %s\n\n" test_id;
  (* Flatten all raw suggestions, preserving puid.
     Use string_of_structural_field_path as the outer grouping key so that
     paths that share the same structural shape (e.g. STATE.validators[*].x)
     always land in the same bucket regardless of which concrete index they carry. *)
  let all_muts : (premise_uid * Pos.sym_mutation) list =
    List.concat_map
      (fun (puid, muts) -> List.map (fun m -> (puid, m)) muts)
      diag.raw_suggestions
    (* Drop ToConst on list paths: provenance-through-LenE artifacts that are
       always filtered by strategies_for_sym_mutation anyway. *)
    |> List.filter (fun (_, m) ->
           match (m.Pos.target_path, m.Pos.suggestion) with
           | Some p, Pos.ToConst _ -> not (is_list_field p)
           | _ -> true)
  in
  let display_key (m : Pos.sym_mutation) =
    match m.target_path with
    | None -> None
    | Some p -> Some (string_of_structural_field_path p)
  in
  (* Collect structural display keys in first-seen order. *)
  let grp_seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let grp_order = ref [] in
  List.iter
    (fun (_puid, m) ->
      match display_key m with
      | None -> ()
      | Some k ->
          if not (Hashtbl.mem grp_seen k) then (
            Hashtbl.replace grp_seen k ();
            grp_order := k :: !grp_order))
    all_muts;
  (* Group muts by structural display key. *)
  let by_grp : (string, (premise_uid * Pos.sym_mutation) list) Hashtbl.t =
    Hashtbl.create 16
  in
  List.iter
    (fun ((_, m) as entry) ->
      match display_key m with
      | None -> ()
      | Some k ->
          let xs = Option.value ~default:[] (Hashtbl.find_opt by_grp k) in
          Hashtbl.replace by_grp k (entry :: xs))
    all_muts;
  (* Header summary: count unique (concrete_path, op) pairs per group. *)
  let count_unique_pairs entries =
    let seen = Hashtbl.create 16 in
    List.iter
      (fun (_, m) ->
        let path_s =
          match m.Pos.target_path with
          | Some p -> Dep.string_of_field_path p
          | None -> "?"
        in
        let op_s = Pos.string_of_mutation_kind m.Pos.suggestion in
        Hashtbl.replace seen (path_s ^ "|" ^ op_s) ())
      entries;
    Hashtbl.length seen
  in
  let total_unique =
    Hashtbl.fold
      (fun _ entries acc -> acc + count_unique_pairs entries)
      by_grp 0
  in
  let n_paths = List.length !grp_order in
  Printf.fprintf ch
    "Extracted mutation suggestions (before sampling)\n\
    \  Total: %d unique suggestion%s across %d structural path%s\n\n"
    total_unique
    (if total_unique = 1 then "" else "s")
    n_paths
    (if n_paths = 1 then "" else "s");
  List.iter
    (fun grp_key ->
      let entries =
        List.rev (Option.value ~default:[] (Hashtbl.find_opt by_grp grp_key))
      in
      let muts_here = List.map snd entries in
      let n_unique = count_unique_pairs entries in
      (* Collect op keys in first-seen order. *)
      let op_seen : (string, unit) Hashtbl.t = Hashtbl.create 8 in
      let op_order = ref [] in
      List.iter
        (fun m ->
          let sk = sym_mutation_sampling_key m in
          if not (Hashtbl.mem op_seen sk) then (
            Hashtbl.replace op_seen sk ();
            op_order := sk :: !op_order))
        muts_here;
      let prems_here = List.sort_uniq compare (List.map fst entries) in
      Printf.fprintf ch "%s  (%d unique suggestion%s)\n" grp_key n_unique
        (if n_unique = 1 then "" else "s");
      Printf.fprintf ch "  Premises: %s\n"
        (String.concat ", " (List.map string_of_int prems_here));
      (* Group by op sampling key. *)
      let by_op : (string, Pos.sym_mutation list) Hashtbl.t =
        Hashtbl.create 8
      in
      List.iter
        (fun m ->
          let sk = sym_mutation_sampling_key m in
          let xs = Option.value ~default:[] (Hashtbl.find_opt by_op sk) in
          Hashtbl.replace by_op sk (m :: xs))
        muts_here;
      List.iter
        (fun op_key ->
          let op_muts =
            List.rev (Option.value ~default:[] (Hashtbl.find_opt by_op op_key))
          in
          let op_label =
            match op_muts with
            | m :: _ -> Pos.string_of_mutation_kind m.Pos.suggestion
            | [] -> op_key
          in
          (* Sort by concrete array index (primary) or numeric value (fallback),
             then deduplicate so each index appears at most once. *)
          let index_of m =
            match m.Pos.target_path with
            | Some path ->
                List.find_map
                  (function Dep.IndexAccess i -> Some i | _ -> None)
                  path.steps
            | None -> None
          in
          let is_indexed_group =
            List.exists (fun m -> index_of m <> None) op_muts
          in
          if is_indexed_group then Printf.fprintf ch "  %s\n" op_label;
          let sort_key m =
            match index_of m with
            | Some i -> i
            | None -> Option.value ~default:0 (sym_mutation_numeric m)
          in
          let sorted =
            List.sort (fun m1 m2 -> compare (sort_key m1) (sort_key m2)) op_muts
          in
          (* Deduplicate by display string: each distinct "i=N" or suggestion
             is shown at most once per op group. *)
          let dup_seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
          List.iter
            (fun m ->
              let display =
                match index_of m with
                | Some i -> Printf.sprintf "i=%-4d" i
                | None -> Pos.string_of_mutation_kind m.Pos.suggestion
              in
              if not (Hashtbl.mem dup_seen display) then (
                Hashtbl.replace dup_seen display ();
                let indent = if is_indexed_group then "    " else "  " in
                Printf.fprintf ch "%s%s\n" indent display))
            sorted)
        (List.rev !op_order);
      Printf.fprintf ch "\n")
    (List.rev !grp_order);
  close_out ch

(* ===== Legacy premise-centric generation ===== *)

(* Convert sym_mutations for a premise into a deduplicated mutation_constraint list. *)
let infer_mutation_constraints (puid : premise_uid)
    (_coverage : Node_cov.result option) (dependency : Pos.result option) :
    mutation_constraint list =
  get_mutation_suggestions_for_premise puid dependency
  |> group_and_sample_sym_mutations
  |> List.filter_map (fun (sym_mut, group_total) ->
         sym_mutation_to_constraint ~group_total sym_mut)
  |> deduplicate_constraints

(* Generate mutations for a single premise using one base test case.
   Returns list of (mut_id, out_pre_path, out_block_path). *)
let generate_test_case ~(test_dir : string) ~(output_dir : string)
    (puid : premise_uid) (coverage : Node_cov.result option)
    (dependency : Pos.result option) (base_test_case_id : test_case_id option) =
  let constraints = infer_mutation_constraints puid coverage dependency in
  let test_id_opt =
    match base_test_case_id with
    | Some id -> Some id
    | None -> (
        match get_test_cases_for_premise puid coverage with
        | [] -> None
        | first :: _ -> Some first)
  in
  match test_id_opt with
  | None -> []
  | Some test_id_raw ->
      let test_id = test_id_to_dir test_id_raw in
      let pre_path = Filename.concat test_dir (test_id ^ "_pre.json") in
      let block_path = Filename.concat test_dir (test_id ^ "_block.json") in
      let premise_output_dir =
        Filename.concat output_dir (Printf.sprintf "premise_%d" puid)
      in
      mkdir_p premise_output_dir;

      let report_ch =
        open_out (Filename.concat premise_output_dir "report.txt")
      in
      Printf.fprintf report_ch
        "Mutation Report for Premise UID %d\nBase Test Case: %s\n\n" puid
        test_id;

      let generated = ref [] in
      List.iteri
        (fun c_idx constraint_ ->
          List.iteri
            (fun s_idx strategy ->
              let mut_id =
                Printf.sprintf "%s_mut%d_%d"
                  (String.map (fun c -> if c = '/' then '_' else c) test_id)
                  c_idx s_idx
              in
              let single = { constraint_ with strategies = [ strategy ] } in
              let out_pre, out_block =
                mutate_json_input ~output_dir:premise_output_dir mut_id
                  [ single ] [] pre_path block_path
              in
              if out_pre <> pre_path then (
                generated := (mut_id, out_pre, out_block) :: !generated;
                Printf.fprintf report_ch
                  "Mutation ID: %s\n  Field Path: %s\n  Strategy: %s\n\n" mut_id
                  (Dep.string_of_field_path constraint_.field_path)
                  (strategy_to_display_string strategy)))
            constraint_.strategies)
        constraints;

      close_out report_ch;
      List.rev !generated

(* Run generate_test_case for each premise in puids. *)
let generate_test_cases ~(test_dir : string) ~(output_dir : string)
    (puids : premise_uid list) (coverage : Node_cov.result option)
    (dependency : Pos.result option) =
  List.map
    (fun uid ->
      let results =
        generate_test_case ~test_dir ~output_dir uid coverage dependency None
      in
      (uid, results))
    puids

(* ===== Checkpoint utilities ===== *)

(* Load a coverage checkpoint and extract its coverage and dependency fields. *)
let load_checkpoint (checkpoint_file : string) =
  let checkpoint =
    match Checkpoint.load_from_file ~file:checkpoint_file with
    | Ok cp -> cp
    | Error e ->
        failwith
          (Printf.sprintf "Failed to load checkpoint: %s"
             (Error.string_of_error e))
  in
  let coverage = checkpoint.Checkpoint.coverage.node_il in
  let dependency = checkpoint.Checkpoint.coverage.dependency in
  (checkpoint, coverage, dependency)

let checkpoint_summary (checkpoint_file : string) =
  let checkpoint, coverage, dependency = load_checkpoint checkpoint_file in
  let buf = Buffer.create 256 in
  let fmt = Format.formatter_of_buffer buf in
  Format.fprintf fmt "Checkpoint: %s\n" checkpoint_file;
  Format.fprintf fmt "  Completed tests: %d\n"
    (List.length checkpoint.Checkpoint.completed_inputs);
  Format.fprintf fmt "  Coverage data: %s\n"
    (if Option.is_some coverage then "present" else "missing");
  (match coverage with
  | Some cov ->
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in
      let uncovered_count =
        List.fold_left
          (fun count ((region, content_str), _) ->
            if not (List.mem (region, content_str) succeeded_keys) then
              count + 1
            else count)
          0 cov.prem_to_uid
      in
      Format.fprintf fmt "    Total premises: %d\n" cov.total_prems;
      Format.fprintf fmt "    Premises with UIDs: %d\n"
        (List.length cov.prem_to_uid);
      Format.fprintf fmt "    Premises succeeded: %d\n"
        (List.length cov.prems_succeeded);
      Format.fprintf fmt "    Uncovered premises: %d\n" uncovered_count
  | None -> ());
  Format.fprintf fmt "  Positive data: %s\n"
    (if Option.is_some dependency then "present" else "missing");
  (match dependency with
  | Some dep ->
      let total_mutations =
        List.fold_left
          (fun acc (_, test_muts) ->
            List.fold_left
              (fun acc (_, muts) -> acc + List.length muts)
              acc test_muts)
          0 dep.per_test_sym_mutations
      in
      Format.fprintf fmt "    Total mutation suggestions: %d\n" total_mutations
  | None -> ());
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let load_testgen_checkpoint (file : string) =
  match Checkpoint.load_from_file ~file with
  | Ok cp -> (
      match cp.Checkpoint.coverage.testgen with
      | Some data -> data
      | None -> Testgen_data.empty)
  | Error _ -> Testgen_data.empty

let save_testgen_checkpoint ~(file : string option) ~(analyzed : string list)
    ~(positive_result : Pos.result) =
  match file with
  | None -> ()
  | Some checkpoint_file ->
      let testgen_data =
        Testgen_data.of_positive_result ~analyzed positive_result
      in
      let coverage =
        {
          Checkpoint.branch = None;
          node_il = None;
          node_sl = None;
          dependency = Some positive_result;
          testgen = Some testgen_data;
        }
      in
      let checkpoint =
        {
          Checkpoint.spec_hash = "";
          completed_inputs = analyzed;
          coverage;
          timestamp = Unix.gettimeofday ();
        }
      in
      Checkpoint.save_to_file ~file:checkpoint_file checkpoint;
      Format.printf "Saved testgen checkpoint: %s (%d tests analyzed)\n%!"
        checkpoint_file (List.length analyzed)

(* ===== Seed filtering ===== *)

let filter_by_seed_type (seed_filter : string option)
    (test_ids : (string * 'a) list) =
  match seed_filter with
  | None -> test_ids
  | Some filter_type ->
      let lower_filter = String.lowercase_ascii filter_type in
      List.filter
        (fun (test_id, _) ->
          let lower_id = String.lowercase_ascii test_id in
          try
            let _ =
              Str.search_forward (Str.regexp_string lower_filter) lower_id 0
            in
            true
          with Not_found -> false)
        test_ids

(* ===== Test-case-centric generation ===== *)

(* Generate mutations for each test case in test_to_prems using an on-demand
   dependency analysis callback. No checkpoint support or global dedup. *)
let generate_tests_by_test_case ~(test_dir : string) ~(output_dir : string)
    (premise_uids : premise_uid list) (coverage : Node_cov.result option)
    (analyze_test_case : test_case_id -> premise_uid list -> Pos.result option)
    =
  let test_to_prems = get_test_to_premises premise_uids coverage in
  List.filter_map
    (fun (test_id, prem_uids) ->
      Format.printf "Processing test case: %s (premises: %s)\n%!" test_id
        (String.concat ", " (List.map string_of_int prem_uids));
      match analyze_test_case test_id prem_uids with
      | None ->
          Format.printf "  Skipped: analysis failed\n%!";
          None
      | Some dependency_result ->
          let result_opt, diag =
            process_test_case ~test_dir ~output_dir test_id prem_uids
              dependency_result
          in
          (match result_opt with
          | Some _ ->
              write_seed_report ~output_dir ~test_id ~prem_uids diag;
              write_suggestions_log ~output_dir ~test_id diag
          | None -> ());
          result_opt)
    test_to_prems

(* Generate mutations for each test case with checkpoint support.
   Supports resuming from a prior run, seed-type filtering, slot-gap filtering,
   K-cover seed selection, and periodic checkpoint saves. *)
let generate_tests_with_checkpoint ~(test_dir : string) ~(output_dir : string)
    ~(checkpoint_file : string option) ~(resume_file : string option)
    ~(save_interval : int) ~(filter_seeds : string option)
    ~(coverage_level : int) ?(max_slot_gap : int = 32)
    (premise_uids : premise_uid list) (coverage : Node_cov.result option)
    (analyze_test_case : test_case_id -> premise_uid list -> Pos.result option)
    =
  let testgen_data =
    match resume_file with
    | Some file ->
        Format.printf "Resuming from checkpoint: %s\n%!" file;
        load_testgen_checkpoint file
    | None -> Testgen_data.empty
  in

  let all_test_to_prems = get_test_to_premises premise_uids coverage in
  let seed_filtered = filter_by_seed_type filter_seeds all_test_to_prems in

  let slot_filtered =
    let before = List.length seed_filtered in
    let result =
      List.filter
        (fun (tid, _) -> slot_gap_within_limit ~test_dir ~max_slot_gap tid)
        seed_filtered
    in
    let after = List.length result in
    if before <> after then
      Format.printf "Slot-gap filter (max %d): %d → %d tests\n%!" max_slot_gap
        before after;
    result
  in

  let test_to_prems =
    if coverage_level = 0 then slot_filtered
    else (
      Format.printf
        "Selecting seeds with K-cover (k=%d, greedy set cover)...\n%!"
        coverage_level;
      let prem_to_tests = Hashtbl.create 256 in
      let test_to_prems_tbl = Hashtbl.create 256 in
      List.iter
        (fun (tid, prems) ->
          Hashtbl.replace test_to_prems_tbl tid prems;
          List.iter
            (fun p ->
              let existing =
                Hashtbl.find_opt prem_to_tests p |> Option.value ~default:[]
              in
              if not (List.mem tid existing) then
                Hashtbl.replace prem_to_tests p (tid :: existing))
            prems)
        slot_filtered;
      let selected =
        Source_selector.select_k_cover_tests ~k:coverage_level premise_uids
          prem_to_tests test_to_prems_tbl
      in
      Format.printf
        "Selected %d tests (from %d candidates) covering %d premises (k=%d)\n%!"
        (List.length selected)
        (List.length slot_filtered)
        (List.length premise_uids) coverage_level;
      let test_priority (test_id, _) =
        let lower = String.lowercase_ascii test_id in
        let contains s =
          try
            let _ = Str.search_forward (Str.regexp_string s) lower 0 in
            true
          with Not_found -> false
        in
        if contains "sanity" then 0 else if contains "random" then 2 else 1
      in
      List.sort
        (fun t1 t2 ->
          let p1 = test_priority t1 and p2 = test_priority t2 in
          if p1 <> p2 then compare p1 p2 else String.compare (fst t1) (fst t2))
        selected)
  in

  let all_test_ids = List.map fst test_to_prems in
  let remaining_ids = Testgen_data.filter_remaining testgen_data all_test_ids in
  let remaining =
    List.filter (fun (tid, _) -> List.mem tid remaining_ids) test_to_prems
  in

  Format.printf "Total tests: %d, Already analyzed: %d, Remaining: %d\n%!"
    (List.length all_test_ids)
    (List.length all_test_ids - List.length remaining_ids)
    (List.length remaining_ids);

  let analyzed = ref (Testgen_data.analyzed_tests testgen_data) in
  let last_dep_result = ref None in
  let analysis_failed_count = ref 0 in
  let all_diags = ref [] in
  let already_completed =
    List.length all_test_ids - List.length remaining_ids
  in
  let total = List.length all_test_ids in

  let results =
    List.mapi
      (fun idx (test_id, prem_uids) ->
        Format.printf "[%d/%d] Processing test case: %s\n%!"
          (already_completed + idx + 1)
          total test_id;

        let result_opt = analyze_test_case test_id prem_uids in
        (match result_opt with
        | Some r -> last_dep_result := Some r
        | None -> ());
        analyzed := test_id :: !analyzed;

        (if (idx + 1) mod save_interval = 0 then
           match result_opt with
           | Some r ->
               save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
                 ~positive_result:r;
               Instrumentation.Dependency.Positive.clear_large_state ()
           | None -> ());

        match result_opt with
        | None ->
            analysis_failed_count := !analysis_failed_count + 1;
            Format.printf "  Skipped: analysis failed\n%!";
            None
        | Some dep_result ->
            let tc_result, diag =
              process_test_case ~test_dir ~output_dir test_id prem_uids
                dep_result
            in
            all_diags := diag :: !all_diags;
            (match tc_result with
            | Some _ ->
                write_seed_report ~output_dir ~test_id ~prem_uids diag;
                write_suggestions_log ~output_dir ~test_id diag
            | None -> ());
            tc_result)
      remaining
    |> List.filter_map Fun.id
  in

  (match checkpoint_file with
  | Some _ when results <> [] -> (
      Format.printf "Saving final checkpoint...\n%!";
      match !last_dep_result with
      | Some r ->
          save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
            ~positive_result:r
      | None -> ())
  | _ -> ());

  (* ===== Comprehensive summary ===== *)
  let seeds_with_mutations =
    List.length (List.filter (fun d -> d.covered_prems <> []) !all_diags)
  in
  let all_covered_prems =
    List.sort_uniq compare
      (List.concat_map (fun d -> d.covered_prems) !all_diags)
  in
  let total_mutations =
    List.fold_left
      (fun acc d ->
        acc
        + List.length
            (List.filter
               (function MutationOk _ -> true | _ -> false)
               d.constraint_outcomes))
      0 !all_diags
  in
  (* Seed type breakdown *)
  let n_sanity, n_finality, n_random, n_other =
    List.fold_left
      (fun (s, f, r, o) (tid, _) ->
        let lower = String.lowercase_ascii tid in
        let contains str =
          try
            let _ = Str.search_forward (Str.regexp_string str) lower 0 in
            true
          with Not_found -> false
        in
        if contains "sanity" then (s + 1, f, r, o)
        else if contains "finality" then (s, f + 1, r, o)
        else if contains "random" then (s, f, r + 1, o)
        else (s, f, r, o + 1))
      (0, 0, 0, 0) test_to_prems
  in
  (* Premise coverage *)
  let covered_by_seeds =
    List.fold_left
      (fun acc (_, prems) ->
        List.fold_left (fun a p -> if List.mem p a then a else p :: a) acc prems)
      [] test_to_prems
  in
  let no_seed_coverage =
    List.filter (fun uid -> not (List.mem uid covered_by_seeds)) premise_uids
  in
  let no_mutations =
    List.filter
      (fun uid -> not (List.mem uid all_covered_prems))
      covered_by_seeds
  in
  let seeds_analyzed = List.length remaining in
  let seeds_no_mutations =
    seeds_analyzed - !analysis_failed_count - seeds_with_mutations
  in
  let summary_lines =
    let buf = Buffer.create 512 in
    let pr fmt = Printf.bprintf buf (fmt ^^ "\n") in
    pr "=== Test Generation Summary ===";
    pr "";
    pr "Seeds:";
    pr "  Selected: %d  (Sanity: %d | Finality: %d | Random: %d | Other: %d)"
      (List.length test_to_prems)
      n_sanity n_finality n_random n_other;
    if already_completed > 0 then
      pr "  Already analyzed (checkpoint): %d" already_completed;
    pr "  Analyzed this run: %d  (failed: %d)" seeds_analyzed
      !analysis_failed_count;
    pr "  Generated mutations: %d seeds  |  No new mutations: %d seeds"
      seeds_with_mutations seeds_no_mutations;
    pr "";
    pr "Mutations: %d total" total_mutations;
    if seeds_with_mutations > 0 then
      pr "  Avg per seed: %.1f"
        (float_of_int total_mutations /. float_of_int seeds_with_mutations);
    pr "";
    pr "Premise coverage (%d targeted):" (List.length premise_uids);
    pr "  Covered by seeds:  %d" (List.length covered_by_seeds);
    pr "  Got >=1 mutation:  %d" (List.length all_covered_prems);
    if no_seed_coverage <> [] then
      pr "  No seed coverage:  %d  (UIDs: %s)"
        (List.length no_seed_coverage)
        (String.concat ", "
           (List.map string_of_int (List.sort compare no_seed_coverage)));
    if no_mutations <> [] then
      pr "  No mutations:      %d  (UIDs: %s)" (List.length no_mutations)
        (String.concat ", "
           (List.map string_of_int (List.sort compare no_mutations)));
    Buffer.contents buf
  in
  Format.printf "\n%s%!" summary_lines;
  (let summary_path = Filename.concat output_dir "summary.txt" in
   let ch = open_out summary_path in
   output_string ch summary_lines;
   close_out ch;
   Format.printf "Summary written to: %s\n%!" summary_path);

  results
