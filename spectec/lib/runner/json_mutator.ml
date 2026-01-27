(* JSON mutation utilities - Mutate JSON files based on field paths.

   Handles nested field access (e.g., state.validators[0].balance) and
   supports different mutation strategies. *)

open Yojson.Safe
module Dep = Instrumentation.Dependency.Dep_common

type field_path = Dep.field_path
type field_step = Dep.field_step

type mutation_strategy =
  | SetValue of t (* Set to a specific value *)
  | Increment of int (* Increment by amount *)
  | Decrement of int (* Decrement by amount *)
  | SetBoundary (* Set to boundary value - min/max *)
  | AppendItem (* Append a default/duplicate item to list *)
  | RemoveItem (* Remove the last item from list *)
  | SetLength of int
(* Set list to target length: duplicate random items when larger, drop random items when smaller *)

(* Navigate to a field in JSON using a path *)
let rec get_field (json : t) (path : field_step list) : t option =
  match (json, path) with
  | `Assoc fields, Dep.FieldAccess field_name :: rest -> (
      (* Helper to strip "generic_" prefix *)
      let remove_generic_prefix name =
        if String.starts_with ~prefix:"generic_" name then
          String.sub name 8 (String.length name - 8)
        else name
      in
      let clean_field_name = remove_generic_prefix field_name in

      (* Try exact match first on clean name *)
      match List.assoc_opt clean_field_name fields with
      | Some nested -> if rest = [] then Some nested else get_field nested rest
      | None -> (
          (* Try case-insensitive match *)
          let target = String.lowercase_ascii clean_field_name in
          let found =
            List.find_opt
              (fun (k, _) -> String.lowercase_ascii k = target)
              fields
          in
          match found with
          | Some (_, nested) ->
              if rest = [] then Some nested else get_field nested rest
          | None -> None))
  | `List items, Dep.IndexAccess idx :: rest -> (
      match idx with
      | Dep.ConstInt i ->
          if i >= 0 && i < List.length items then
            let item = List.nth items i in
            if rest = [] then Some item else get_field item rest
          else None
      | Dep.PathRef _ -> None (* Cannot handle dynamic paths here yet *))
  | _, [] -> Some json
  | _ -> None

let find_case_insensitive_key field_name fields =
  let target = String.lowercase_ascii field_name in
  List.find_opt (fun (k, _) -> String.lowercase_ascii k = target) fields

let remove_case_insensitive_keys field_name fields =
  let target = String.lowercase_ascii field_name in
  List.filter (fun (k, _) -> String.lowercase_ascii k <> target) fields

(* Get value at path for reporting - wrapper around get_field *)
let get_value_at_path (json : t) (path : field_path) : t option =
  get_field json path.steps

(* Set a field in JSON using a path *)
let rec set_field (json : t) (path : field_step list) (value : t) : t =
  match (json, path) with
  | `Assoc fields, [ Dep.FieldAccess field_name ] ->
      let remove_generic_prefix name =
        if String.starts_with ~prefix:"generic_" name then
          String.sub name 8 (String.length name - 8)
        else name
      in
      let clean_field_name = remove_generic_prefix field_name in
      let updated_fields =
        match find_case_insensitive_key clean_field_name fields with
        | Some (k, _) ->
            let filtered =
              remove_case_insensitive_keys clean_field_name fields
            in
            (k, value) :: filtered
        | None -> (clean_field_name, value) :: fields
      in
      `Assoc updated_fields
  | `Assoc fields, Dep.FieldAccess field_name :: rest -> (
      let remove_generic_prefix name =
        if String.starts_with ~prefix:"generic_" name then
          String.sub name 8 (String.length name - 8)
        else name
      in
      let clean_field_name = remove_generic_prefix field_name in
      match find_case_insensitive_key clean_field_name fields with
      | Some (k, nested) ->
          let updated_nested = set_field nested rest value in
          let filtered = remove_case_insensitive_keys clean_field_name fields in
          `Assoc ((k, updated_nested) :: filtered)
      | None ->
          (* Create nested structure *)
          let new_nested = set_field (`Assoc []) rest value in
          `Assoc ((clean_field_name, new_nested) :: fields))
  | `List items, [ Dep.IndexAccess (Dep.PathRef _) ] ->
      (* Wildcard leaf: update all items to value - assuming PathRef here is used as wildcard/iterator *)
      (* note: usage of PathRef as wildcard is a bit of an overload here, but fits the pattern *)
      let updated_items = List.map (fun _ -> value) items in
      `List updated_items
  | `List items, Dep.IndexAccess (Dep.PathRef _) :: rest ->
      (* Wildcard traversal: recurse on all items *)
      let updated_items =
        List.map (fun item -> set_field item rest value) items
      in
      `List updated_items
  | `List items, [ Dep.IndexAccess (Dep.ConstInt i) ] ->
      if i >= 0 && i < List.length items then
        let updated_items =
          List.mapi (fun idx v -> if idx = i then value else v) items
        in
        `List updated_items
      else json
  | `List items, Dep.IndexAccess (Dep.ConstInt i) :: rest ->
      if i >= 0 && i < List.length items then
        let updated_item = set_field (List.nth items i) rest value in
        let updated_items =
          List.mapi (fun idx v -> if idx = i then updated_item else v) items
        in
        `List updated_items
      else json
  | _, [] -> value
  | _ -> json

(* Apply mutation strategy to a JSON value *)
let apply_mutation (json : t) (strategy : mutation_strategy) : t =
  match (json, strategy) with
  | `Int n, Increment amount -> `Int (n + amount)
  | `Int n, Decrement amount -> `Int (n - amount)
  | `Int _, SetBoundary -> `Int 0
  | `Int _, SetValue v -> v
  | `Float f, Increment amount -> `Float (f +. float_of_int amount)
  | `Float f, Decrement amount -> `Float (f -. float_of_int amount)
  | `Float _, SetValue v -> v
  (* List mutations *)
  | `List items, AppendItem ->
      if items = [] then `List items (* Can't append to empty without schema *)
      else
        let last_item = List.nth items (List.length items - 1) in
        `List (items @ [ last_item ])
  | `List items, RemoveItem ->
      if items = [] then `List []
      else `List (List.rev (List.tl (List.rev items)))
  | `List items, SetLength target_len ->
      (* Skip mutation if source list is empty *)
      if items = [] then `List items
      else
        let current_len = List.length items in
        if target_len = current_len then `List items
        else if target_len > current_len then
          (* Duplicate random items to reach target length *)
          let needed = target_len - current_len in
          let rec duplicate acc remaining =
            if remaining = 0 then acc
            else
              let random_idx = Random.int (List.length items) in
              let random_item = List.nth items random_idx in
              duplicate (random_item :: acc) (remaining - 1)
          in
          `List (items @ List.rev (duplicate [] needed))
        else
          (* Drop random items to reach target length *)
          (* Create list of indices and randomly select which ones to keep *)
          let indices = List.init current_len (fun i -> i) in
          let rec shuffle list =
            match list with
            | [] -> []
            | [ x ] -> [ x ]
            | _ ->
                let random_idx = Random.int (List.length list) in
                let selected = List.nth list random_idx in
                let rest = List.filteri (fun i _ -> i <> random_idx) list in
                selected :: shuffle rest
          in
          let shuffled = shuffle indices in
          (* Take first target_len elements (compatible with OCaml 5.1) *)
          let keep_indices =
            let rec take n acc = function
              | [] -> List.rev acc
              | x :: xs when n > 0 -> take (n - 1) (x :: acc) xs
              | _ -> List.rev acc
            in
            take target_len [] shuffled
          in
          let keep_set =
            List.fold_left (fun acc idx -> idx :: acc) [] keep_indices
          in
          `List (List.filteri (fun idx _ -> List.mem idx keep_set) items)
  | _, SetValue v -> v
  | _ -> json

(* Mutate a JSON file by applying mutations to specified field paths *)
let mutate_json_file (json : t) (path : field_path)
    (strategy : mutation_strategy) : t =
  match get_field json path.steps with
  | Some field_value ->
      let mutated_value = apply_mutation field_value strategy in
      set_field json path.steps mutated_value
  | None -> json (* Path not found, return unchanged *)

(* Load JSON from file *)
let load_json (filename : string) : t =
  let channel = open_in filename in
  let json = from_channel channel in
  close_in channel;
  json

(* Save JSON to file *)
let save_json (filename : string) (json : t) : unit =
  let channel = open_out filename in
  pretty_to_channel channel json;
  close_out channel

(* Mutate JSON file and save to new location *)
let mutate_and_save (input_file : string) (output_file : string)
    (path : field_path) (strategy : mutation_strategy) : unit =
  let json = load_json input_file in
  let mutated = mutate_json_file json path strategy in
  save_json output_file mutated
