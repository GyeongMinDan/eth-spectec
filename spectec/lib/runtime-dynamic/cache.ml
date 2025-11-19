(* Cache entry for relation and function invocations *)

module Entry = struct
  type t = string * Il.Value.t list

  let equal (id_a, values_a) (id_b, values_b) =
    id_a = id_b
    && List.compare (fun v_a v_b -> Il.Value.compare v_a v_b) values_a values_b
       = 0

  let hash = Hashtbl.hash
end

(* LFU (with LRU tiebreak) cache over Entry keys *)

module Cache = struct
  module Table = Hashtbl.Make (Entry)

  let create ~size = Table.create size
  let clear cache = Table.clear cache
  let find cache key = Table.find_opt cache key
  let add cache key value = Table.add cache key value
end

(* Cache targets *)

let is_cached_func = function
  | name when String.starts_with ~prefix:"debug_print_label_" name -> false
  | _ -> true
let is_cached_rule = function _ -> true
