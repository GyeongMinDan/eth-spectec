open Il
open Yojson.Basic.Util
open Xl
open Util.Source
open Runtime_dynamic.Envs

type error =
  | FileReadError of string * string (* filename, message *)
  | JsonParseError of string * string (* filename, Yojson error message *)
  | TypeError of string * typ' * Yojson.Basic.t (* expected, got json *)
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
        (Yojson.Basic.pretty_to_string json)
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

let parse_field (json : Yojson.Basic.t) (field_name : string) parser =
  let* field = json |> member field_name |> parser in
  (field_atom field_name, field) |> Result.ok

let rec json_to_value (tdenv : TDEnv.t) (expected : typ')
    (json : Yojson.Basic.t) : parse_result =
  match (expected, json) with
  | NumT `IntT, `String s -> (
      try
        let i = Bigint.of_string s in
        Value.int i |> Result.ok
      with Failure _ ->
        TypeError ("int string", expected, json) |> Result.error)
  | NumT `NatT, `Int i -> Value.int (Bigint.of_int i) |> Result.ok
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
      | Some (_, { it = PlainT typ; _ }), _ -> json_to_value tdenv typ.it json
      | None, _ ->
          TypeError ("typedef not found", expected, json) |> Result.error
      | _, _ -> TypeError ("type mismatch", expected, json) |> Result.error)
  | _ -> TypeError ("unsupported type", expected, json) |> Result.error
