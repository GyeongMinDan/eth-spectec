open Il
open Util.Source

type error = TypeMismatch of string * Typ.t'

let string_of_error (e : error) : string =
  match e with
  | TypeMismatch (msg, typ) ->
      Printf.sprintf "Type mismatch: %s. Got type: %s" msg
        (Print.string_of_typ (typ $ no_region))

let result_all (l : ('a, error) result list) : ('a list, error) result =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | r :: rs -> (
        match r with Ok v -> aux (v :: acc) rs | Error e -> Error e)
  in
  aux [] l

let ( let* ) = Result.bind

let rec value_to_json (v : Value.t) : (Yojson.Safe.t, error) result =
  match (v.note.typ, v.it) with
  | BoolT, BoolV b -> `Bool b |> Result.ok
  | NumT `IntT, NumV (`Int n) ->
      `Intlit ("\"" ^ Bigint.Hex.to_string n ^ "\"") |> Result.ok
  | NumT `NatT, NumV (`Nat n) -> `Intlit (Bigint.to_string n) |> Result.ok
  | IterT (_, List), ListV vs ->
      let rec print_values acc = function
        | [] -> `List (List.rev acc) |> Result.ok
        | value_elem :: values ->
            let* json_elem = value_to_json value_elem in
            print_values (json_elem :: acc) values
      in
      print_values [] vs
  | VarT _, StructV fields ->
      let field_to_json (atom, value) =
        let* json_value = value_to_json value in
        Ok (Xl.Atom.string_of_atom atom.it |> String.lowercase_ascii, json_value)
      in
      let* json_fields = result_all (List.map field_to_json fields) in
      Ok (`Assoc json_fields)
  | _ -> Error (TypeMismatch ("Unsupported type or value", v.note.typ))
