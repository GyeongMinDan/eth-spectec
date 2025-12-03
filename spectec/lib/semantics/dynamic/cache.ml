open Common.Source
open Lang

(* Cache entry for relation and function invocations *)

module Entry = struct
  type t = string * Il.Value.t list

  (* (* Use structural equality for both equal and hash to ensure consistency *) *)
  (* let equal (id_a, values_a) (id_b, values_b) = *)
  (*   id_a = id_b && values_a = values_b *)

  let hash = Hashtbl.hash

  (* Old semantic comparison (kept for reference, not used) *)
  let equal (id_a, values_a) (id_b, values_b) =
    id_a = id_b
    && List.compare (fun v_a v_b -> Il.Value.compare v_a v_b) values_a values_b
       = 0
end

(* LFU (with LRU tiebreak) cache over Entry keys *)

module Cache = struct
  module Table = Hashtbl.Make (Entry)

  let create ~size = Table.create size
  let clear cache = Table.clear cache
  let find cache key = Table.find_opt cache key

  let add cache key value =
    let _, values_input = key in
    if
      List.exists
        (fun v -> match v.it with Il.FuncV _ -> true | _ -> false)
        values_input
      |> not
    then Table.add cache key value
end

(* Cache targets *)

let is_cached_func = function
  | "subst_type" | "subst_typeDef" | "specialize_typeDef" | "canon"
  | "free_type" | "is_nominal_typeIR" | "bound" | "gen_constraint_type"
  | "merge_constraint" | "merge_constraint'" | "find_matchings"
  | "nestable_struct" | "nestable_struct_in_header" | "find_map" ->
      true
  | name when String.starts_with ~prefix:"debug_print" name -> false
  | _ -> false

let is_cached_rule = function
  | "Sub_expl" | "Sub_expl_canon" | "Sub_expl_canon_neq" | "Sub_impl"
  | "Sub_impl_canon" | "Sub_impl_canon_neq" | "Type_wf" | "Type_alpha" ->
      true
  | _ -> false
