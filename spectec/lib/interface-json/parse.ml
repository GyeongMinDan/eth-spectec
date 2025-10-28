open Il.Ast
open Yojson.Basic.Util
open Util.Source

type error =
  | FileReadError of string * string (* filename, message *)
  | JsonParseError of string * string (* filename, Yojson error message *)
  | TypeError of string * typ' * Yojson.Basic.t (* expected, got json *)
  | FieldMissing of string * string (* field name, struct type name *)
  | UnknownField of string * string (* field name, struct type name *)

type parse_result = (Value.t, error) Result.t

let ( let* ) = Result.bind

let field_atom (id : string) =
  Xl.Atom.Atom (id |> String.uppercase_ascii) $ no_region

let parse_field (json : Yojson.Basic.t) (field_name : string) parser =
  let* field = json |> member field_name |> parser in
  (field_atom field_name, field) |> Result.ok

let parse_beaconBlock (_json : Yojson.Basic.t) : parse_result =
  failwith "parse_beaconBlock not implemented"

let parse_blsSignature (_json : Yojson.Basic.t) : parse_result =
  failwith "parse_blsSignature not implemented"

let parse_signedBeaconBlock (json : Yojson.Basic.t) : parse_result =
  let* message = parse_field json "message" parse_beaconBlock in
  let* signature = parse_field json "signature" parse_blsSignature in
  Value.record "signedBeaconBlock" [ message; signature ] |> Result.ok
