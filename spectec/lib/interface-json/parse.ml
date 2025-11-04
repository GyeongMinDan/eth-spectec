open Il
open Xl
open Util.Source
open Runtime_dynamic.Envs

type error =
  | FileReadError of string * string (* filename, message *)
  | JsonParseError of string * string (* filename, Yojson error message *)
  | TypeError of string * typ' * Yojson.Safe.t (* expected, got json *)
  | FieldMissing of string * string (* field name, struct type name *)
  | UnknownField of string * string (* field name, struct type name *)

let string_of_error = function
  | FileReadError (filename, msg) ->
      Format.asprintf "File read error in '%s': %s" filename msg
  | JsonParseError (filename, msg) ->
      Format.asprintf "JSON parse error in '%s': %s" filename msg
  | TypeError (msg, typ, json) ->
      Format.asprintf "Type error (%s) : expected %s, got JSON: %s" msg
        (Typ.to_string (typ $ no_region))
        (Yojson.Safe.pretty_to_string json)
  | FieldMissing (field_name, struct_name) ->
      Format.asprintf "Field '%s' is missing in struct '%s'" field_name
        struct_name
  | UnknownField (field_name, struct_name) ->
      Format.asprintf "Unknown field '%s' in struct '%s'" field_name struct_name

type parse_result = (Value.t, error) Result.t

let ( let* ) = Result.bind

let result_all results =
  let rec aux acc = function
    | [] -> Result.ok (List.rev acc)
    | r :: rs ->
        let* v = r in
        aux (v :: acc) rs
  in
  aux [] results

let field_atom (id : string) : atom =
  Xl.Atom.Atom (id |> String.uppercase_ascii) $ no_region

(* Parse hex string to BytesV *)
let hex_string_to_bytes (s : string) : (Bigint.t * int, error) result =
  if not (String.length s >= 2 && String.sub s 0 2 = "0x") then
    TypeError ("hex string must start with 0x", NumT `NatT, `String s)
    |> Result.error
  else
    try
      let hex_content = String.sub s 2 (String.length s - 2) in
      (* Calculate actual byte length from hex string *)
      (* "0x" = 0 bytes, "0x0" = 1 byte (not empty!), "0x00" = 1 byte, "0x000" = 2 bytes *)
      let actual_len =
        if hex_content = "" then 0
        else
          (* Each pair of hex digits = 1 byte, odd number of digits = 1 more byte *)
          (String.length hex_content + 1) / 2
      in
      let num = Bigint.of_string s in
      Ok (num, actual_len)
    with Failure _ ->
      TypeError ("invalid hex string", NumT `NatT, `String s) |> Result.error

let rec json_to_value (tdenv : TDEnv.t) (expected : typ') (json : Yojson.Safe.t)
    : parse_result =
  match (expected, json) with
  | BoolT, `Bool b -> Value.bool b |> Result.ok
  | NumT `IntT, `String s when String.length s >= 2 && String.sub s 0 2 = "0x" ->
      (* Hex string for bytes type (int) - convert to BytesV *)
      let* num, len = hex_string_to_bytes s in
      let bytes_value' = BytesV { num; len } in
      Value.Make.value expected bytes_value' |> Result.ok
  | NumT `IntT, `String s -> (
      try
        let i = Bigint.of_string s in
        Value.int i |> Result.ok
      with Failure _ ->
        TypeError ("int string", expected, json) |> Result.error)
  | NumT `NatT, `Int i ->
      let n = Bigint.of_int i in
      if Bigint.compare n Bigint.zero >= 0 then Value.nat n |> Result.ok
      else TypeError ("non-negative nat", expected, json) |> Result.error
  | NumT `NatT, `Intlit s -> (
      try
        let n = Bigint.of_string s in
        if Bigint.compare n Bigint.zero >= 0 then Value.nat n |> Result.ok
        else TypeError ("non-negative nat", expected, json) |> Result.error
      with Failure _ ->
        TypeError ("nat string", expected, json) |> Result.error)
  | NumT `NatT, `String s when String.length s >= 2 && String.sub s 0 2 = "0x" ->
      (* Hex string for bytes type - convert to BytesV *)
      let* num, len = hex_string_to_bytes s in
      let bytes_value' = BytesV { num; len } in
      Value.Make.value expected bytes_value' |> Result.ok
  | IterT (elem_typ, List), `List json_list ->
      let rec parse_elements acc = function
        | [] -> Value.list elem_typ (List.rev acc) |> Result.ok
        | json_elem :: rest ->
            let* elem_value = json_to_value tdenv elem_typ.it json_elem in
            parse_elements (elem_value :: acc) rest
      in
      parse_elements [] json_list
  | IterT ({ it = BoolT; _ }, List), `String s ->
      let int = Z.of_string s in
      let bit_length = Z.numbits int in
      let bool_list =
        List.init bit_length (fun bit_index ->
            Z.testbit int bit_index |> Value.bool)
      in
      Value.list (Typ.bool $ no_region) bool_list |> Result.ok
  | VarT (tid, []), _ -> (
      match (TDEnv.find_opt tid tdenv, json) with
      | Some (_, { it = StructT typfields; _ }), `Assoc fields ->
          let parse_typefield (atom, typ) (key, value) =
            if Atom.string_of_atom atom.it |> String.lowercase_ascii = key then
              let* field = json_to_value tdenv typ.it value in
              Ok (atom, field)
            else Error (FieldMissing (Atom.string_of_atom atom.it, key))
          in
          let* typfields =
            result_all (List.map2 parse_typefield typfields fields)
          in
          Value.record tid.it typfields |> Result.ok
      | Some (_, { it = PlainT typ; _ }), _ ->
          (* Check if it's a bytes type and JSON is a hex string *)
          (match (typ.it, json) with
          | (NumT `NatT | NumT `IntT), `String s
            when String.length s >= 2 && String.sub s 0 2 = "0x" ->
              (* bytes type with hex string - convert to BytesV *)
              let* num, len = hex_string_to_bytes s in
              let bytes_value' = BytesV { num; len } in
              Value.Make.value typ.it bytes_value' |> Result.ok
          | _ -> json_to_value tdenv typ.it json)
      | None, _ ->
          TypeError ("typedef not found", expected, json) |> Result.error
      | _, _ -> TypeError ("type mismatch", expected, json) |> Result.error)
  | _ -> TypeError ("unsupported type", expected, json) |> Result.error
