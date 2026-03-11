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
  is_fallback : bool;
      (* true when strategies come from Unknown or type-mismatch fallback *)
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
  from_json : Yojson.Safe.t;
  applied : Json_mutator.mutation_strategy list;
      (* one entry per successfully applied strategy *)
  mut_ids : string list; (* parallel to applied — the mut_... directory name *)
  is_fallback : bool;
      (* true when the applied strategies were fallback-generated *)
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
let get_state_slot (json : Yojson.Safe.t) = json_get_int json state_slot_path

let get_block_slot (json : Yojson.Safe.t) =
  match json_get_int json block_msg_slot_path with
  | Some _ as r -> r
  | None -> assert false

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
      Json_mutator.set_field block_json block_msg_slot_path capped
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

(* Replace the element at index i in a JSON array. *)
let replace_json_item (json : Yojson.Safe.t) (i : int) (new_val : Yojson.Safe.t)
    : Yojson.Safe.t =
  match json with
  | `List items ->
      `List (List.mapi (fun idx v -> if idx = i then new_val else v) items)
  | _ -> json

let value_to_json (v : Il.Value.t) : (Yojson.Safe.t, string) result =
  match Interface.JSON.Print.value_to_json v with
  | Ok json -> Ok json
  | Error err -> Error (Interface.JSON.Print.string_of_error err)

(* ===== Interval-based strategy generation ===== *)

let min_interval_for_interior = Bigint.of_int 16

(* Compute interval(s) representing the valid range for a comparison constraint. *)
let intervals_of_numop (op : Il.cmpop) (n : Bigint.t) (min_v : Bigint.t)
    (max_v : Bigint.t) : (Bigint.t * Bigint.t) list =
  let clamp_iv lo hi =
    let lo' = if Bigint.compare lo min_v < 0 then min_v else lo in
    let hi' = if Bigint.compare hi max_v > 0 then max_v else hi in
    if Bigint.compare lo' hi' > 0 then [] else [ (lo', hi') ]
  in
  match op with
  | `LtOp -> clamp_iv min_v Bigint.(n - of_int 1)
  | `LeOp -> clamp_iv min_v n
  | `GtOp -> clamp_iv Bigint.(n + of_int 1) max_v
  | `GeOp -> clamp_iv n max_v
  | `EqOp -> clamp_iv n n
  | `NeOp ->
      clamp_iv min_v Bigint.(n - of_int 1)
      @ clamp_iv Bigint.(n + of_int 1) max_v

(* Merge overlapping or adjacent intervals (input need not be sorted). *)
let simple_merge_intervals (ivs : (Bigint.t * Bigint.t) list) :
    (Bigint.t * Bigint.t) list =
  let sorted = List.sort (fun (a, _) (b, _) -> Bigint.compare a b) ivs in
  List.fold_left
    (fun acc (lo, hi) ->
      match acc with
      | [] -> [ (lo, hi) ]
      | (alo, ahi) :: rest ->
          if Bigint.compare Bigint.(ahi + of_int 1) lo >= 0 then
            let merged_hi = if Bigint.compare ahi hi >= 0 then ahi else hi in
            (alo, merged_hi) :: rest
          else (lo, hi) :: acc)
    [] sorted
  |> List.rev

(* One-outside values: just below first interval, gap endpoints between non-adjacent
   intervals, and just above last interval. *)
let one_outside_values (ivs : (Bigint.t * Bigint.t) list) (min_v : Bigint.t)
    (max_v : Bigint.t) : Bigint.t list =
  match ivs with
  | [] -> []
  | _ ->
      let first_lo = fst (List.hd ivs) in
      let last_hi = snd (List.nth ivs (List.length ivs - 1)) in
      let below =
        if Bigint.compare first_lo min_v > 0 then
          [ Bigint.(first_lo - of_int 1) ]
        else []
      in
      let above =
        if Bigint.compare last_hi max_v < 0 then [ Bigint.(last_hi + of_int 1) ]
        else []
      in
      let rec gap_pts = function
        | [] | [ _ ] -> []
        | (_, hi_i) :: ((lo_next, _) :: _ as rest) ->
            let pts = gap_pts rest in
            if Bigint.compare lo_next Bigint.(hi_i + of_int 1) > 0 then
              Bigint.(hi_i + of_int 1) :: Bigint.(lo_next - of_int 1) :: pts
            else pts
      in
      below @ gap_pts ivs @ above

(* Compute count equally-spaced interior points in [lo, hi], if width >= threshold. *)
let interior_points (lo : Bigint.t) (hi : Bigint.t) ~(count : int) :
    Bigint.t list =
  let width = Bigint.(hi - lo) in
  if Bigint.compare width min_interval_for_interior < 0 then []
  else
    let denom = count + 1 in
    List.init count (fun k ->
        let numer = k + 1 in
        let num = Bigint.(width * of_int numer) in
        Bigint.(lo + (num / of_int denom)))

(* Full interval-based mutation value pipeline. *)
let values_from_suggestions ~(min_v : Bigint.t) ~(max_v : Bigint.t)
    ~(known : (Il.cmpop * Bigint.t) list) ~(unknown_vals : Bigint.t list) :
    Bigint.t list =
  let known_intervals =
    List.concat_map (fun (op, n) -> intervals_of_numop op n min_v max_v) known
  in
  if known <> [] && known_intervals = [] then []
  else
    let base =
      if known_intervals = [] then [ (min_v, max_v) ]
      else simple_merge_intervals known_intervals
    in
    let clamp v =
      if Bigint.compare v min_v < 0 then min_v
      else if Bigint.compare v max_v > 0 then max_v
      else v
    in
    let interval_boundaries ivs =
      List.concat_map (fun (lo, hi) -> [ lo; hi ]) ivs
    in
    let slice_pts =
      List.concat_map
        (fun k ->
          [ clamp Bigint.(k - of_int 1); k; clamp Bigint.(k + of_int 1) ])
        unknown_vals
    in
    let all_pts =
      List.sort_uniq Bigint.compare
        (interval_boundaries known_intervals
        @ interval_boundaries base @ slice_pts)
    in
    let is_subinterval (lo, hi) =
      List.exists
        (fun (blo, bhi) ->
          Bigint.compare lo blo >= 0 && Bigint.compare hi bhi <= 0)
        base
    in
    let final_intervals =
      match all_pts with
      | [] -> []
      | [ p ] -> if is_subinterval (p, p) then [ (p, p) ] else []
      | _ ->
          let rec mk_pairs = function
            | [] | [ _ ] -> []
            | a :: (b :: _ as rest) -> (a, b) :: mk_pairs rest
          in
          List.filter is_subinterval (mk_pairs all_pts)
    in
    let boundaries = interval_boundaries final_intervals in
    let outside = one_outside_values final_intervals min_v max_v in
    let n_final = List.length final_intervals in
    let interior =
      List.concat_map
        (fun (lo, hi) ->
          let count = if n_final = 1 then 2 else 1 in
          interior_points lo hi ~count)
        final_intervals
    in
    let all =
      List.filter
        (fun v -> Bigint.compare v min_v >= 0 && Bigint.compare v max_v <= 0)
        (boundaries @ outside @ interior)
    in
    List.sort_uniq Bigint.compare all

(* Generate combined numeric mutation strategies from known constraints and unknown hints. *)
let generate_combined_numeric_strategies (known : (Il.cmpop * Bigint.t) list)
    (unknown_vals : Bigint.t list) : Json_mutator.mutation_strategy list =
  values_from_suggestions ~min_v:min_value ~max_v:max_uint64 ~known
    ~unknown_vals
  |> List.map (fun n -> Json_mutator.SetValue (`Intlit (bigint_to_intlit n)))

(* Generate combined length mutation strategies from known constraints and unknown hints. *)
let generate_combined_length_strategies (known : (Il.cmpop * int) list)
    (unknown_vals : int list) : Json_mutator.mutation_strategy list =
  let known_big = List.map (fun (op, n) -> (op, Bigint.of_int n)) known in
  let unknown_big = List.map Bigint.of_int unknown_vals in
  let all_n = List.map snd known_big @ unknown_big in
  let max_n =
    List.fold_left
      (fun acc n -> if Bigint.compare n acc > 0 then n else acc)
      (Bigint.of_int 1) all_n
  in
  let max_v = Bigint.(of_int 2 * max_n) in
  let max_v =
    if Bigint.compare max_v (Bigint.of_int 2) < 0 then Bigint.of_int 2
    else max_v
  in
  let min_v = Bigint.of_int 0 in
  values_from_suggestions ~min_v ~max_v ~known:known_big
    ~unknown_vals:unknown_big
  |> List.filter_map (fun n ->
         match Bigint.to_int n with
         | Some n_int -> Some (Json_mutator.SetLength n_int)
         | None -> None)

(* Generate mutation strategies for a ToConst constraint.
   For each comparison operator, produces values that satisfy the constraint (e.g., >= n → [n, MAX]). *)
let rec generate_toconst_strategies (op : Il.cmpop) (value : Il.Value.t)
    (source_value_opt : Yojson.Safe.t option) :
    Json_mutator.mutation_strategy list =
  match value.it with
  | Il.BoolV b -> (
      match source_value_opt with
      | Some (`Bool src) -> [ Json_mutator.SetValue (`Bool (not src)) ]
      | _ -> [ Json_mutator.SetValue (`Bool (not b)) ])
  | Il.NumV (`Nat n) | Il.NumV (`Int n) ->
      generate_combined_numeric_strategies [ (op, n) ] []
  | Il.ListV items -> (
      (* List value: only EqOp and NeOp are meaningful. *)
      match op with
      | `EqOp ->
          let n = List.length items in
          let len_val = { value with it = Il.NumV (`Nat (Bigint.of_int n)) } in
          generate_tolength_strategies `EqOp len_val
      | `NeOp -> (
          (* Mutate the first element so the list differs in content, not length.
             Mirror the StructV approach: convert to JSON, patch index 0, return SetValue. *)
          match items with
          | [] -> []
          | first_item :: _ -> (
              match value_to_json value with
              | Error _ -> []
              | Ok list_json ->
                  generate_toconst_strategies `NeOp first_item None
                  |> List.filter_map (function
                       | Json_mutator.SetValue new_elem ->
                           Some
                             (Json_mutator.SetValue
                                (replace_json_item list_json 0 new_elem))
                       | _ -> None)))
      | _ -> [])
  | Il.BytesV { num; len } -> (
      let sv n =
        Json_mutator.SetValue
          (`String (Interface.JSON.Print.bytes_to_hex_string n len))
      in
      let bit_width = 8 * len in
      let max_n = Bigint.(shift_left (of_int 1) bit_width - of_int 1) in
      let min_n = Bigint.of_int 0 in
      let pred_n =
        if Bigint.compare num min_n > 0 then Bigint.(num - of_int 1) else min_n
      in
      let succ_n =
        let s = Bigint.(num + of_int 1) in
        if Bigint.compare s max_n > 0 then max_n else s
      in
      match op with
      | `EqOp -> [ sv num ]
      | `NeOp ->
          (if Bigint.compare num min_n > 0 then [ sv pred_n ] else [])
          @ if Bigint.compare num max_n < 0 then [ sv succ_n ] else []
      | `GeOp -> [ sv num; sv max_n ]
      | `LeOp -> [ sv num; sv min_n ]
      | `GtOp -> [ sv succ_n; sv max_n ]
      | `LtOp ->
          if Bigint.compare num min_n > 0 then [ sv pred_n; sv min_n ] else [])
  | _ -> (
      (* For EqOp: set the field to exactly this value.
                 For other ops we have no way to produce a different
                 non-numeric value, so skip to avoid identity mutations. *)
      match op with
      | `EqOp -> (
          match value_to_json value with
          | Ok json -> [ Json_mutator.SetValue json ]
          | Error _ -> [])
      | _ -> [])

(* Generate mutation strategies for a ToLength constraint (list-length variant of ToConst). *)
and generate_tolength_strategies (op : Il.cmpop) (value : Il.Value.t) :
    Json_mutator.mutation_strategy list =
  match extract_numeric_value value with
  | None -> [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ]
  | Some n -> (
      match Bigint.to_int n with
      | None -> [ Json_mutator.SetLength 0; Json_mutator.SetLength 1 ]
      | Some n_int -> generate_combined_length_strategies [ (op, n_int) ] [])

(* Strategies for Unknown hints carrying a concrete IL value.
   For NumV/BytesV/ListV produces: min, max, v-1, v+1 (with v itself added separately
   as hint_strat in strategies_for_sym_mutation).  BytesV preserves the IL byte length. *)
let rec strategies_from_il_value (v : Il.Value.t) :
    Json_mutator.mutation_strategy list =
  match v.it with
  | Il.NumV (`Nat n) | Il.NumV (`Int n) ->
      let pred =
        if Bigint.compare n (Bigint.of_int 0) > 0 then
          [
            Json_mutator.SetValue
              (`Intlit (bigint_to_intlit Bigint.(n - of_int 1)));
          ]
        else []
      in
      let succ =
        [
          Json_mutator.SetValue
            (`Intlit (bigint_to_intlit Bigint.(n + of_int 1)));
        ]
      in
      [
        Json_mutator.SetValue (`Intlit "0");
        Json_mutator.SetValue (`Intlit "18446744073709551615");
      ]
      @ pred @ succ
  | Il.BytesV { num; len } ->
      let sv b =
        Json_mutator.SetValue
          (`String (Interface.JSON.Print.bytes_to_hex_string b len))
      in
      let bit_width = 8 * len in
      let max_n = Bigint.(shift_left (of_int 1) bit_width - of_int 1) in
      let min_n = Bigint.of_int 0 in
      let pred_n =
        if Bigint.compare num min_n > 0 then Bigint.(num - of_int 1) else min_n
      in
      let succ_n =
        let s = Bigint.(num + of_int 1) in
        if Bigint.compare s max_n > 0 then max_n else s
      in
      [ sv min_n; sv max_n; sv pred_n; sv succ_n ]
  | Il.BoolV _ ->
      [
        Json_mutator.SetValue (`Bool true); Json_mutator.SetValue (`Bool false);
      ]
  | Il.ListV items ->
      let n = List.length items in
      if n = 0 then []
      else
        let pred = [ Json_mutator.SetLength (n - 1) ] in
        let succ = [ Json_mutator.SetLength (n + 1) ] in
        [ Json_mutator.SetLength 0; Json_mutator.SetLength (2 * n) ]
        @ pred @ succ
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

(* Generate type-accurate fallback strategies directly from the source JSON value.
   Used when all IL-derived strategies are type-incompatible or when the suggestion
   is Unknown.  Produces min / max / pred / succ for scalars and lengths for lists. *)
let rec fallback_strategies_from_source (source : Yojson.Safe.t) :
    Json_mutator.mutation_strategy list =
  match source with
  | `Int n ->
      let pred =
        if n > 0 then [ Json_mutator.SetValue (`Int (n - 1)) ] else []
      in
      [
        Json_mutator.SetValue (`Int 0);
        Json_mutator.SetValue (`Intlit (bigint_to_intlit max_uint64));
      ]
      @ pred
      @ [ Json_mutator.SetValue (`Int (n + 1)) ]
  | `Intlit n_str ->
      let n = Bigint.of_string n_str in
      let pred =
        if Bigint.compare n (Bigint.of_int 0) > 0 then
          [
            Json_mutator.SetValue
              (`Intlit (bigint_to_intlit Bigint.(n - of_int 1)));
          ]
        else []
      in
      [
        Json_mutator.SetValue (`Intlit "0");
        Json_mutator.SetValue (`Intlit (bigint_to_intlit max_uint64));
      ]
      @ pred
      @ [
          Json_mutator.SetValue
            (`Intlit (bigint_to_intlit Bigint.(n + of_int 1)));
        ]
  | `String s when String.length s >= 2 && String.sub s 0 2 = "0x" ->
      (* BytesV hex string — preserve byte length *)
      let hex = String.sub s 2 (String.length s - 2) in
      let byte_len = String.length hex / 2 in
      let n = Bigint.of_string ("0x" ^ if hex = "" then "0" else hex) in
      let bit_width = 8 * byte_len in
      let max_n =
        if byte_len = 0 then Bigint.of_int 0
        else Bigint.(shift_left (of_int 1) bit_width - of_int 1)
      in
      let sv b =
        Json_mutator.SetValue
          (`String (Interface.JSON.Print.bytes_to_hex_string b byte_len))
      in
      let pred_n =
        if Bigint.compare n (Bigint.of_int 0) > 0 then Bigint.(n - of_int 1)
        else Bigint.of_int 0
      in
      let succ_n =
        let s = Bigint.(n + of_int 1) in
        if Bigint.compare s max_n > 0 then max_n else s
      in
      [ sv (Bigint.of_int 0); sv max_n; sv pred_n; sv succ_n ]
  | `List lst ->
      let n = List.length lst in
      let pred = if n > 0 then [ Json_mutator.SetLength (n - 1) ] else [] in
      [ Json_mutator.SetLength 0; Json_mutator.SetLength (2 * n) ]
      @ pred
      @ [ Json_mutator.SetLength (n + 1) ]
  | `Bool b -> [ Json_mutator.SetValue (`Bool (not b)) ]
  | `Assoc fields ->
      (* For struct fields: pick up to 3 fields from the SOURCE and mutate each one.
         Each strategy sets the whole struct to a copy of the source with one field changed. *)
      fields
      |> List.filter_map (fun (k, fv) ->
             match fallback_strategies_from_source fv with
             | [] -> None
             | Json_mutator.SetValue new_fv :: _ ->
                 let new_struct =
                   `Assoc
                     (List.map
                        (fun (k2, v2) ->
                          if k2 = k then (k2, new_fv) else (k2, v2))
                        fields)
                 in
                 Some (Json_mutator.SetValue new_struct)
             | _ -> None)
      |> List.filteri (fun i _ -> i < 3)
  | _ -> []

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
  | Pos.Unknown v ->
      let hint_strat =
        match value_to_json v with
        | Ok j -> [ Json_mutator.SetValue j ]
        | Error _ -> []
      in
      hint_strat @ strategies_from_il_value v

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
      let is_fallback =
        match sym_mut.suggestion with Pos.Unknown _ -> true | _ -> false
      in
      if strategies = [] && not is_fallback then None
      else if strategies = [] && is_fallback then
        (* Unknown with no IL strategies still needs a constraint for fallback *)
        Some
          {
            field_path = target_path;
            strategies = [];
            suggestion_str = Some (Pos.string_of_sym_mutation sym_mut);
            class_key = structural_path_key target_path;
            sampling_key = sym_mutation_sampling_key sym_mut;
            group_total;
            is_fallback;
          }
      else
        Some
          {
            field_path = target_path;
            strategies;
            suggestion_str = Some (Pos.string_of_sym_mutation sym_mut);
            class_key = structural_path_key target_path;
            sampling_key = sym_mutation_sampling_key sym_mut;
            group_total;
            is_fallback;
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

(* Build an AppendRandom strategy using the field path's resolved list type.
   Uses an existing element as a template when available, otherwise generates randomly. *)
let make_append_random_strategy_for_path (fp : field_path)
    (source_value : Yojson.Safe.t) : Json_mutator.mutation_strategy option =
  match field_path_type fp with
  | Some (Type_tree.IterT _ as list_typ) ->
      let new_elem =
        match source_value with
        | `List (first :: _) ->
            Option.value ~default:`Null
              (Type_tree.random_element_from list_typ first)
        | _ -> Option.value ~default:`Null (Type_tree.random_element list_typ)
      in
      Some (Json_mutator.AppendRandom new_elem)
  | _ -> None

(* For list paths with no pre-computed strategies, derive strategies from the source length. *)
let list_strategies_from_source (fp : field_path) source_value =
  match source_value with
  | `List [] ->
      (* Empty list: can only grow by appending a new element via type tree *)
      Option.to_list (make_append_random_strategy_for_path fp (`List []))
  | `List lst ->
      let n = List.length lst in
      let len_strats =
        [ Json_mutator.SetLength (2 * n); Json_mutator.SetLength 0 ]
      in
      let append_strat = make_append_random_strategy_for_path fp source_value in
      len_strats @ Option.to_list append_strat
  | _ -> []

(* Return the byte length of a "0x..." hex string, or None if not a hex string. *)
let hex_byte_len (s : string) : int option =
  if String.length s >= 2 && String.sub s 0 2 = "0x" then
    Some ((String.length s - 2) / 2)
  else None

(* True if a SetValue strategy's hex byte length is compatible with the source value.
   Filters out strategies that would set a hex field to a string of the wrong length. *)
let strategy_byte_len_ok (source_value : Yojson.Safe.t)
    (strategy : Json_mutator.mutation_strategy) : bool =
  match (source_value, strategy) with
  | `String src, Json_mutator.SetValue (`String tgt) -> (
      match (hex_byte_len src, hex_byte_len tgt) with
      | Some src_len, Some tgt_len -> src_len = tgt_len
      | _ -> true)
  | _ -> true

(* Classify a JSON value's type for mismatch detection. *)
let json_type : Yojson.Safe.t -> string = function
  | `String _ -> "string"
  | `List _ -> "array"
  | `Assoc _ -> "object"
  | `Bool _ -> "bool"
  | `Int _ | `Intlit _ | `Float _ -> "number"
  | `Null -> "null"

(* Expected source type for a mutation strategy. *)
let strategy_source_type : Json_mutator.mutation_strategy -> string = function
  | Json_mutator.SetValue v -> json_type v
  | Json_mutator.SetLength _ | Json_mutator.AppendItem | Json_mutator.RemoveItem
  | Json_mutator.AppendRandom _ ->
      "array"
  | Json_mutator.Increment _ | Json_mutator.Decrement _
  | Json_mutator.SetBoundary ->
      "number"

(* Compute the valid, adjusted strategies for a constraint given the current source value.
   Returns (strategies, is_fallback_used) where is_fallback_used is true when fallback
   strategies were generated due to type mismatch or Unknown suggestion. *)
let resolve_strategies (constraint_ : mutation_constraint)
    (source_value : Yojson.Safe.t) : Json_mutator.mutation_strategy list * bool
    =
  let is_list = is_list_field constraint_.field_path in
  let struct_keys_ok s =
    match (source_value, s) with
    | `Assoc src_fields, Json_mutator.SetValue (`Assoc tgt_fields) ->
        let src_keys = List.sort String.compare (List.map fst src_fields) in
        let tgt_keys = List.sort String.compare (List.map fst tgt_fields) in
        src_keys = tgt_keys
    | _ -> true
  in
  let type_ok s =
    strategy_source_type s = json_type source_value && struct_keys_ok s
  in
  let byte_len_ok s = strategy_byte_len_ok source_value s in
  let had_type_mismatch =
    constraint_.strategies <> []
    && List.for_all
         (fun s -> (not (type_ok s)) || not (byte_len_ok s))
         constraint_.strategies
  in
  (* Use source-based fallback when suggestion is unusable: either all strategies
     have the wrong type, or the Unknown hint produced no IL-derivable strategies. *)
  let use_source_fallback =
    had_type_mismatch || (constraint_.is_fallback && constraint_.strategies = [])
  in
  if use_source_fallback then
    let fallback =
      fallback_strategies_from_source source_value
      |> List.filter (fun s -> not (is_identity_strategy source_value s))
    in
    (deduplicate_strategies fallback, true)
  else
    let base =
      if source_value = `List [] then []
      else
        List.filter
          (fun s ->
            type_ok s && byte_len_ok s
            && not (is_identity_strategy source_value s))
          constraint_.strategies
    in
    let extra =
      if is_list && (source_value = `List [] || constraint_.strategies = [])
      then list_strategies_from_source constraint_.field_path source_value
      else []
    in
    let combined =
      List.map (adjust_bool_strategy source_value) (base @ extra)
    in
    (deduplicate_strategies combined, constraint_.is_fallback)

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

(* ===== Combined constraint builders ===== *)

(* Returns Some (op, n) if this suggestion is a ToConst NumV. *)
let numeric_known_suggestion (sugg : Pos.mutation_kind) :
    (Il.cmpop * Bigint.t) option =
  match sugg with
  | Pos.ToConst (op, v) -> (
      match v.it with
      | Il.NumV (`Nat n) | Il.NumV (`Int n) -> Some (op, n)
      | _ -> None)
  | _ -> None

(* Returns Some n if this suggestion is an Unknown NumV. *)
let numeric_unknown_val (sugg : Pos.mutation_kind) : Bigint.t option =
  match sugg with
  | Pos.Unknown v -> (
      match v.it with
      | Il.NumV (`Nat n) | Il.NumV (`Int n) -> Some n
      | _ -> None)
  | _ -> None

(* Returns Some (op, n) if this suggestion is a ToLength or ToConst ListV. *)
let length_known_suggestion (sugg : Pos.mutation_kind) : (Il.cmpop * int) option
    =
  match sugg with
  | Pos.ToLength (op, v) -> (
      match extract_numeric_value v with
      | Some n -> Option.map (fun n_int -> (op, n_int)) (Bigint.to_int n)
      | None -> None)
  | Pos.ToConst (op, v) -> (
      match v.it with
      | Il.ListV items -> Some (op, List.length items)
      | _ -> None)
  | _ -> None

(* Returns Some n if this suggestion is an Unknown ListV. *)
let length_unknown_val (sugg : Pos.mutation_kind) : int option =
  match sugg with
  | Pos.Unknown v -> (
      match v.it with Il.ListV items -> Some (List.length items) | _ -> None)
  | _ -> None

let build_combined_numeric_constraint (path : field_path)
    (known : (Il.cmpop * Bigint.t) list) (unknown_vals : Bigint.t list)
    (sym_muts : Pos.sym_mutation list) (group_total : int) :
    mutation_constraint option =
  if not (is_valid_target path) then None
  else
    let strategies =
      generate_combined_numeric_strategies known unknown_vals
      |> deduplicate_strategies
    in
    if strategies = [] then None
    else
      Some
        {
          field_path = path;
          strategies;
          suggestion_str =
            Some
              (String.concat "; "
                 (List.map Pos.string_of_sym_mutation sym_muts));
          class_key = structural_path_key path;
          sampling_key = structural_path_key path ^ "|combined";
          group_total;
          is_fallback = false;
        }

let build_combined_length_constraint (path : field_path)
    (known : (Il.cmpop * int) list) (unknown_vals : int list)
    (sym_muts : Pos.sym_mutation list) (group_total : int) :
    mutation_constraint option =
  if not (is_valid_target path) then None
  else
    let strategies =
      generate_combined_length_strategies known unknown_vals
      |> deduplicate_strategies
    in
    if strategies = [] then None
    else
      Some
        {
          field_path = path;
          strategies;
          suggestion_str =
            Some
              (String.concat "; "
                 (List.map Pos.string_of_sym_mutation sym_muts));
          class_key = structural_path_key path;
          sampling_key = structural_path_key path ^ "|combined";
          group_total;
          is_fallback = false;
        }

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
  (* Phase 1: Collect sampled sym_mutations from all puids, tagged with their puid. *)
  let all_tagged : (premise_uid * Pos.sym_mutation * int) list ref = ref [] in
  List.iter
    (fun puid ->
      let muts =
        get_mutation_suggestions_for_premise puid (Some dependency_result)
      in
      if muts = [] then prem_no_muts := puid :: !prem_no_muts
      else (
        raw_sugg_acc := (puid, muts) :: !raw_sugg_acc;
        let muts_sampled = group_and_sample_sym_mutations muts in
        List.iter
          (fun (sym_mut, gt) ->
            all_tagged := (puid, sym_mut, gt) :: !all_tagged)
          muts_sampled))
    prem_uids;

  (* Phase 2: Globally classify and group by concrete field_path. *)
  let numeric_by_path :
      (string, (premise_uid * Pos.sym_mutation * int) list) Hashtbl.t =
    Hashtbl.create 8
  in
  let length_by_path :
      (string, (premise_uid * Pos.sym_mutation * int) list) Hashtbl.t =
    Hashtbl.create 8
  in
  let other_muts_list : (premise_uid * Pos.sym_mutation * int) list ref =
    ref []
  in
  List.iter
    (fun (puid, (sym_mut : Pos.sym_mutation), gt) ->
      match sym_mut.target_path with
      | None -> other_muts_list := (puid, sym_mut, gt) :: !other_muts_list
      | Some path ->
          let is_list = is_list_field path in
          let sugg = sym_mut.suggestion in
          let path_key = Dep.string_of_field_path path in
          if
            (not is_list)
            && (Option.is_some (numeric_known_suggestion sugg)
               || Option.is_some (numeric_unknown_val sugg))
          then
            let existing =
              Option.value ~default:[]
                (Hashtbl.find_opt numeric_by_path path_key)
            in
            Hashtbl.replace numeric_by_path path_key
              ((puid, sym_mut, gt) :: existing)
          else if
            Option.is_some (length_known_suggestion sugg)
            || (is_list && Option.is_some (length_unknown_val sugg))
          then
            let existing =
              Option.value ~default:[]
                (Hashtbl.find_opt length_by_path path_key)
            in
            Hashtbl.replace length_by_path path_key
              ((puid, sym_mut, gt) :: existing)
          else other_muts_list := (puid, sym_mut, gt) :: !other_muts_list)
    !all_tagged;

  (* Track which puids got at least one constraint (for prem_no_constraints). *)
  let puids_with_constraint : (premise_uid, unit) Hashtbl.t =
    Hashtbl.create 16
  in
  let add_constraint_for_puids c puids_list =
    List.iter (fun p -> Hashtbl.replace puids_with_constraint p ()) puids_list;
    let k = constraint_key c in
    match Hashtbl.find_opt constraint_map k with
    | None -> Hashtbl.replace constraint_map k (c, puids_list)
    | Some (_, existing) ->
        let merged = List.sort_uniq compare (puids_list @ existing) in
        Hashtbl.replace constraint_map k (c, merged)
  in

  (* Phase 3: Build one combined constraint per field_path (globally). *)
  let process_numeric_group _path_key entries =
    match entries with
    | [] -> ()
    | (_, first_sym_mut, _) :: _ -> (
        match first_sym_mut.Pos.target_path with
        | None -> ()
        | Some path -> (
            let known =
              List.filter_map
                (fun (_, m, _) -> numeric_known_suggestion m.Pos.suggestion)
                entries
            in
            let unknown_vals =
              List.filter_map
                (fun (_, m, _) -> numeric_unknown_val m.Pos.suggestion)
                entries
            in
            let sym_muts_list = List.map (fun (_, m, _) -> m) entries in
            let all_puids =
              List.sort_uniq compare (List.map (fun (p, _, _) -> p) entries)
            in
            let group_total =
              List.fold_left (fun acc (_, _, gt) -> max acc gt) 1 entries
            in
            match
              build_combined_numeric_constraint path known unknown_vals
                sym_muts_list group_total
            with
            | None ->
                List.iter
                  (fun (puid, sym_mut, gt) ->
                    match
                      sym_mutation_to_constraint ~group_total:gt sym_mut
                    with
                    | None -> ()
                    | Some c -> add_constraint_for_puids c [ puid ])
                  entries
            | Some c -> add_constraint_for_puids c all_puids))
  in
  Hashtbl.iter process_numeric_group numeric_by_path;

  let process_length_group _path_key entries =
    match entries with
    | [] -> ()
    | (_, first_sym_mut, _) :: _ -> (
        match first_sym_mut.Pos.target_path with
        | None -> ()
        | Some path -> (
            let known =
              List.filter_map
                (fun (_, m, _) -> length_known_suggestion m.Pos.suggestion)
                entries
            in
            let unknown_vals =
              List.filter_map
                (fun (_, m, _) -> length_unknown_val m.Pos.suggestion)
                entries
            in
            let sym_muts_list = List.map (fun (_, m, _) -> m) entries in
            let all_puids =
              List.sort_uniq compare (List.map (fun (p, _, _) -> p) entries)
            in
            let group_total =
              List.fold_left (fun acc (_, _, gt) -> max acc gt) 1 entries
            in
            match
              build_combined_length_constraint path known unknown_vals
                sym_muts_list group_total
            with
            | None ->
                List.iter
                  (fun (puid, sym_mut, gt) ->
                    match
                      sym_mutation_to_constraint ~group_total:gt sym_mut
                    with
                    | None -> ()
                    | Some c -> add_constraint_for_puids c [ puid ])
                  entries
            | Some c -> add_constraint_for_puids c all_puids))
  in
  Hashtbl.iter process_length_group length_by_path;

  let filtered_reasons = ref [] in
  List.iter
    (fun (puid, sym_mut, gt) ->
      match sym_mutation_to_constraint ~group_total:gt sym_mut with
      | None -> (
          match diagnose_filtered_mutation sym_mut with
          | Some reason -> filtered_reasons := reason :: !filtered_reasons
          | None -> ())
      | Some c -> add_constraint_for_puids c [ puid ])
    !other_muts_list;

  (* Populate prem_no_constraints for puids that had muts but no constraint. *)
  List.iter
    (fun puid ->
      if
        (not (List.mem puid !prem_no_muts))
        && not (Hashtbl.mem puids_with_constraint puid)
      then (
        prem_no_constraints := puid :: !prem_no_constraints;
        Format.eprintf
          "[Testgen] uid=%d: had mutations but all filtered: %s\n%!" puid
          (String.concat "; " (List.sort_uniq String.compare !filtered_reasons))))
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
    (* Track (field_path, strategy) pairs already written this seed so that
       different suggestions producing the same mutation (e.g. len<=0 and
       len<=255 both generating SetLength 0) are deduplicated. *)
    let seen_field_strategies : (string, unit) Hashtbl.t = Hashtbl.create 64 in
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
            let strats, is_fallback_used = resolve_strategies constraint_ src in
            let prem_str =
              String.concat "_"
                (List.map (Printf.sprintf "prem%d") puids_for_constraint)
            in
            (* Apply all strategies for this constraint; accumulate applied
               strategies so the report shows one grouped entry per constraint. *)
            let applied = ref [] in
            let mut_ids = ref [] in
            (* True once a strategy for this constraint was not a cross-constraint
               duplicate, regardless of whether it ultimately produced a file. *)
            let had_non_dupe_strategy = ref false in
            List.iteri
              (fun s_idx strategy ->
                let fp_strat_key =
                  Dep.string_of_field_path constraint_.field_path
                  ^ "|" ^ strategy_key strategy
                in
                if Hashtbl.mem seen_field_strategies fp_strat_key then
                  (* Duplicate of an already-written mutation: mark premises
                     covered (the earlier file serves the same purpose) but
                     don't write a second identical file. *)
                  List.iter
                    (fun uid -> Hashtbl.replace local_covered uid ())
                    puids_for_constraint
                else (
                  had_non_dupe_strategy := true;
                  Hashtbl.replace seen_field_strategies fp_strat_key ();
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
                    applied := strategy :: !applied;
                    mut_ids := mut_id :: !mut_ids)))
              strats;
            if !applied <> [] then
              outcomes :=
                MutationOk
                  {
                    field = constraint_.field_path;
                    prems = puids_for_constraint;
                    suggestion = constraint_.suggestion_str;
                    class_key = constraint_.class_key;
                    sampling_key = constraint_.sampling_key;
                    total_variants = constraint_.group_total;
                    from_json = src;
                    applied = List.rev !applied;
                    mut_ids = List.rev !mut_ids;
                    is_fallback = is_fallback_used;
                  }
                :: !outcomes
            else if strats <> [] && not !had_non_dupe_strategy then
              (* Every strategy for this constraint was already written by a
                 prior constraint — premises are covered, no new outcome needed. *)
              ()
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

(* Extract the "kind" part of a suggestion string (after " -> "). *)
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

let truncate_val s =
  let max = 60 in
  if String.length s <= max then s else String.sub s 0 max ^ "..."

(* Display the source JSON value: lists show count instead of content. *)
let display_from_json json =
  match json with
  | `List items ->
      Printf.sprintf "(%d item%s)" (List.length items)
        (if List.length items = 1 then "" else "s")
  | _ -> truncate_val (Yojson.Safe.to_string json)

(* Display the target value with list-aware formatting. *)
let display_strategy_value _from_json strategy =
  match strategy with
  | Json_mutator.SetLength n ->
      Printf.sprintf "(%d item%s)" n (if n = 1 then "" else "s")
  | _ -> strategy_to_display_string strategy

(* Extract suggestion kinds from a (possibly combined "; "-joined) suggestion string.
   Each part has the form "PATH -> KIND"; we extract KIND and deduplicate in order. *)
let suggestion_kinds_display (suggestion : string option) : string =
  match suggestion with
  | None -> "?"
  | Some s ->
      let parts = String.split_on_char ';' s in
      let seen = Hashtbl.create 4 in
      let kinds =
        List.filter_map
          (fun part ->
            let t = String.trim part in
            if t = "" then None
            else
              let k = suggestion_kind t in
              if k = t then None (* no " -> " found — skip *)
              else if Hashtbl.mem seen k then None
              else (
                Hashtbl.replace seen k ();
                Some k))
          parts
      in
      if kinds = [] then suggestion_kind s (* fallback: no " -> " anywhere *)
      else String.concat "; " kinds

(* Get the concrete IndexAccess value from a mutation_ok field path, if any. *)
let entry_index (r : mutation_ok) : int option =
  List.find_map
    (function Dep.IndexAccess i -> Some i | _ -> None)
    r.field.steps

(* Write one content block: premises, suggestion groups, and mutation list.
   [ind] is the indentation prefix for this block's content lines. *)
let write_block ch ~ind (entries : mutation_ok list) =
  let prems =
    List.sort_uniq compare (List.concat_map (fun r -> r.prems) entries)
  in
  if prems <> [] then
    Printf.fprintf ch "%sPremises: %s\n" ind
      (String.concat ", " (List.map string_of_int prems));
  (* Sub-group by sampling_key to handle multiple suggestion groups per block. *)
  let seen_sk = Hashtbl.create 4 in
  let sk_order = ref [] in
  List.iter
    (fun r ->
      if not (Hashtbl.mem seen_sk r.sampling_key) then (
        Hashtbl.replace seen_sk r.sampling_key ();
        sk_order := r.sampling_key :: !sk_order))
    entries;
  let sk_grouped = Hashtbl.create 4 in
  List.iter
    (fun r ->
      let xs =
        Option.value ~default:[] (Hashtbl.find_opt sk_grouped r.sampling_key)
      in
      Hashtbl.replace sk_grouped r.sampling_key (r :: xs))
    entries;
  List.iter
    (fun sk ->
      let sub =
        List.rev (Option.value ~default:[] (Hashtbl.find_opt sk_grouped sk))
      in
      let kinds =
        suggestion_kinds_display
          (match sub with r :: _ -> r.suggestion | [] -> None)
      in
      let fallback_flag =
        if List.exists (fun r -> r.is_fallback) sub then " [FALLBACK]" else ""
      in
      Printf.fprintf ch "%s%s%s\n" ind kinds fallback_flag;
      let inner_ind = ind ^ "  " in
      List.iter
        (fun r ->
          let from_s = display_from_json r.from_json in
          let pairs = List.combine r.mut_ids r.applied in
          List.iter
            (fun (mid, strategy) ->
              let to_s = display_strategy_value r.from_json strategy in
              Printf.fprintf ch "%s- [%s]  %s  →  %s\n" inner_ind mid from_s
                to_s)
            pairs)
        sub)
    (List.rev !sk_order)

(* Write the "  - Field:" section for one class_key group. *)
let write_field_group ch (outcomes_for_key : constraint_outcome list) =
  let ok_entries =
    List.filter_map
      (function MutationOk r -> Some r | _ -> None)
      outcomes_for_key
  in
  let has_index =
    List.exists
      (fun r ->
        List.exists
          (function Dep.IndexAccess _ -> true | _ -> false)
          r.field.steps)
      ok_entries
  in
  let struct_str =
    match List.find_map (fun r -> Some r.field) ok_entries with
    | Some f -> string_of_structural_field_path f
    | None -> (
        match outcomes_for_key with
        | o :: _ -> (
            match o with
            | MutationOk r -> structural_path_key r.field
            | FieldNotFound { field; _ } -> structural_path_key field
            | JsonLoadFailed { field; _ } -> structural_path_key field)
        | [] -> "")
  in
  Printf.fprintf ch "  - Field: %s\n" struct_str;
  if has_index then (
    (* Group by concrete index, then write one sub-block per index. *)
    let idx_seen = Hashtbl.create 8 in
    let idx_order = ref [] in
    List.iter
      (fun r ->
        let idx = Option.value ~default:(-1) (entry_index r) in
        if not (Hashtbl.mem idx_seen idx) then (
          Hashtbl.replace idx_seen idx ();
          idx_order := idx :: !idx_order))
      ok_entries;
    let idx_grouped = Hashtbl.create 8 in
    List.iter
      (fun r ->
        let idx = Option.value ~default:(-1) (entry_index r) in
        let xs = Option.value ~default:[] (Hashtbl.find_opt idx_grouped idx) in
        Hashtbl.replace idx_grouped idx (r :: xs))
      ok_entries;
    List.iter
      (fun idx ->
        let idx_entries =
          List.rev (Option.value ~default:[] (Hashtbl.find_opt idx_grouped idx))
        in
        Printf.fprintf ch "    [i=%-4d]\n" idx;
        write_block ch ~ind:"      " idx_entries)
      (List.sort compare (List.rev !idx_order)))
  else write_block ch ~ind:"    " ok_entries;
  List.iter
    (fun outcome ->
      match outcome with
      | FieldNotFound { field; prems; src_label } ->
          Printf.fprintf ch "    [FAILED] field %s not found (%s)  prems: %s\n"
            (Dep.string_of_field_path field)
            src_label
            (String.concat ", " (List.map string_of_int prems))
      | JsonLoadFailed { field; prems } ->
          Printf.fprintf ch "    [FAILED] JSON load: %s  prems: %s\n"
            (Dep.string_of_field_path field)
            (String.concat ", " (List.map string_of_int prems))
      | MutationOk _ -> ())
    outcomes_for_key

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
  List.iter
    (fun key ->
      let outcomes_for_key =
        List.rev (Option.value ~default:[] (Hashtbl.find_opt grouped key))
      in
      write_field_group report_ch outcomes_for_key)
    (List.rev !key_order);
  let mutation_count =
    List.fold_left
      (fun acc -> function
        | MutationOk { applied; _ } -> acc + List.length applied | _ -> acc)
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

(* Classify a seed test id as sanity / finality / random / other. *)
let seed_kind_of_id id =
  let lower = String.lowercase_ascii id in
  let contains s =
    try
      let _ = Str.search_forward (Str.regexp_string s) lower 0 in
      true
    with Not_found -> false
  in
  if contains "sanity" then `Sanity
  else if contains "finality" then `Finality
  else if contains "random" then `Random
  else `Other

(* Seed-type filter + slot-gap filter + K-cover selection.
   Returns the list of (test_id, prem_uids) to process. *)
let filter_and_select_seeds ~test_dir ~max_slot_gap ~coverage_level
    ~filter_seeds premise_uids
    (all_test_to_prems : (test_case_id * premise_uid list) list) =
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
  if coverage_level = 0 then slot_filtered
  else (
    Format.printf "Selecting seeds with K-cover (k=%d, greedy set cover)...\n%!"
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
    List.sort
      (fun (t1, _) (t2, _) ->
        let p1 =
          match seed_kind_of_id t1 with `Sanity -> 0 | `Random -> 2 | _ -> 1
        in
        let p2 =
          match seed_kind_of_id t2 with `Sanity -> 0 | `Random -> 2 | _ -> 1
        in
        if p1 <> p2 then compare p1 p2 else String.compare t1 t2)
      selected)

(* Process one seed in the main loop; returns tc_result option.
   Mutates analyzed, last_dep_result, analysis_failed_count, all_diags. *)
let process_one_seed ~test_dir ~output_dir ~checkpoint_file ~save_interval ~idx
    ~total ~already_completed ~analyzed ~last_dep_result ~analysis_failed_count
    ~all_diags analyze_test_case (test_id, prem_uids) =
  Format.printf "[%d/%d] Processing test case: %s\n%!"
    (already_completed + idx + 1)
    total test_id;
  let result_opt = analyze_test_case test_id prem_uids in
  (match result_opt with Some r -> last_dep_result := Some r | None -> ());
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
        process_test_case ~test_dir ~output_dir test_id prem_uids dep_result
      in
      all_diags := diag :: !all_diags;
      (match tc_result with
      | Some _ ->
          write_seed_report ~output_dir ~test_id ~prem_uids diag;
          write_suggestions_log ~output_dir ~test_id diag
      | None -> ());
      tc_result

(* Compute all summary stats, print to stdout, and write summary.txt. *)
let build_and_write_summary ~output_dir ~total_selected ~already_completed
    ~seeds_analyzed ~analysis_failed_count ~test_to_prems ~premise_uids
    ~all_diags =
  let seeds_with_mutations =
    List.length (List.filter (fun d -> d.covered_prems <> []) all_diags)
  in
  let all_covered_prems =
    List.sort_uniq compare
      (List.concat_map (fun d -> d.covered_prems) all_diags)
  in
  let total_mutations =
    List.fold_left
      (fun acc d ->
        acc
        + List.length
            (List.filter
               (function MutationOk _ -> true | _ -> false)
               d.constraint_outcomes))
      0 all_diags
  in
  let n_sanity, n_finality, n_random, n_other =
    List.fold_left
      (fun (s, f, r, o) (tid, _) ->
        match seed_kind_of_id tid with
        | `Sanity -> (s + 1, f, r, o)
        | `Finality -> (s, f + 1, r, o)
        | `Random -> (s, f, r + 1, o)
        | `Other -> (s, f, r, o + 1))
      (0, 0, 0, 0) test_to_prems
  in
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
  let seeds_no_mutations =
    seeds_analyzed - analysis_failed_count - seeds_with_mutations
  in
  let summary_lines =
    let buf = Buffer.create 512 in
    let pr fmt = Printf.bprintf buf (fmt ^^ "\n") in
    pr "=== Test Generation Summary ===";
    pr "";
    pr "Seeds:";
    pr "  Selected: %d  (Sanity: %d | Finality: %d | Random: %d | Other: %d)"
      total_selected n_sanity n_finality n_random n_other;
    if already_completed > 0 then
      pr "  Already analyzed (checkpoint): %d" already_completed;
    pr "  Analyzed this run: %d  (failed: %d)" seeds_analyzed
      analysis_failed_count;
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
  let summary_path = Filename.concat output_dir "summary.txt" in
  let ch = open_out summary_path in
  output_string ch summary_lines;
  close_out ch;
  Format.printf "Summary written to: %s\n%!" summary_path

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
  let test_to_prems =
    filter_and_select_seeds ~test_dir ~max_slot_gap ~coverage_level
      ~filter_seeds premise_uids all_test_to_prems
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
      (fun idx seed ->
        process_one_seed ~test_dir ~output_dir ~checkpoint_file ~save_interval
          ~idx ~total ~already_completed ~analyzed ~last_dep_result
          ~analysis_failed_count ~all_diags analyze_test_case seed)
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

  build_and_write_summary ~output_dir
    ~total_selected:(List.length test_to_prems)
    ~already_completed ~seeds_analyzed:(List.length remaining)
    ~analysis_failed_count:!analysis_failed_count ~test_to_prems ~premise_uids
    ~all_diags:!all_diags;

  results
