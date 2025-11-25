open Util.Source
(* Cache entry for relation and function invocations *)

module Entry = struct
  type t = string * Il.Value.t list

  (* Use structural equality for both equal and hash to ensure consistency *)
  let equal (id_a, values_a) (id_b, values_b) =
    id_a = id_b && values_a = values_b

  let hash = Hashtbl.hash

  (* Old semantic comparison (kept for reference, not used)
  let equal_semantic (id_a, values_a) (id_b, values_b) =
    id_a = id_b
    && List.compare (fun v_a v_b -> Il.Value.compare v_a v_b) values_a values_b
       = 0

  *)
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
  | name when String.starts_with ~prefix:"debug_print_label_" name -> false
  | _ -> true

let is_cached_rule = function _ -> true