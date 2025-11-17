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

(* Convert BytesV to hex string with 0x prefix *)
let bytes_to_hex_string (num : Bigint.t) (len : int) : string =
  (* If length is 0, return "0x" (empty bytes) to handle empty bytes types *)
  if len = 0 then "0x"
  else
    let bytes = Bytes.create len in
    let rec put i v =
      if i >= 0 then (
        let byte = Bigint.(to_int_exn (bit_and v (of_int 0xff))) in
        Bytes.set bytes i (Char.chr byte);
        put (i - 1) (Bigint.shift_right v 8))
    in
    put (len - 1) num;
    let hex_chars = "0123456789abcdef" in
    let hex = ref "0x" in
    for i = 0 to len - 1 do
      let byte = Char.code (Bytes.get bytes i) in
      hex := !hex ^ String.make 1 (String.get hex_chars (byte / 16));
      hex := !hex ^ String.make 1 (String.get hex_chars (byte mod 16))
    done;
    !hex

(* Helper: check if string ends with suffix *)
let ends_with s suffix =
  let len_s = String.length s in
  let len_suffix = String.length suffix in
  if len_s < len_suffix then false
  else String.sub s (len_s - len_suffix) len_suffix = suffix

(* Get byte length from type name *)
let rec bytes_len_from_typ (typ : Typ.t') : int option =
  match typ with
  | VarT (tid, _) ->
      let name = tid.it |> String.lowercase_ascii in
      (* Check for bytes types: bytes32, bytes4, etc. *)
      (* But exclude bytes1 as it's often used for uint8 which should be a number *)
      if String.length name >= 5 && String.sub name 0 5 = "bytes" then
        try
          let len_str = String.sub name 5 (String.length name - 5) in
          let len = int_of_string len_str in
          (* Only treat as bytes if length >= 4 (bytes4, bytes32, etc.) *)
          (* bytes1 is often uint8, bytes2 is often uint16, bytes3 is rare *)
          if len >= 4 then Some len else None
        with _ -> None
        (* Check for suffixes (e.g., previous_version, current_version) *)
      else if
        ends_with name "_version" || name = "version" || name = "domaintype"
        || name = "forkdigest"
      then Some 4
      else if
        ends_with name "_root" || ends_with name "_hash" || name = "root"
        || name = "hash32" || name = "domain"
      then Some 32
      else if name = "withdrawal_credentials" then Some 32
      else if name = "blspubkey" then Some 48
      else if name = "blssignature" then Some 96
      else if name = "executionaddress" || name = "fee_recipient" then Some 20
      else if name = "payloadid" then Some 8
      else if name = "nodeid" then Some 256
      else None
  | IterT (elem_typ, _) ->
      (* For lists, check the element type *)
      bytes_len_from_typ elem_typ.it
  | NumT _ ->
      (* NumT (NatT/IntT) are regular numbers, not bytes *)
      None
  | _ -> None

(* Get byte length from field name (fallback.. 혹시 몰라서..) *)
let bytes_len_from_field_name (field_name : string) : int option =
  let name = String.lowercase_ascii field_name in
  (* Check for suffixes (e.g., previous_version, current_version) *)
  if
    ends_with name "_version" || name = "version" || name = "domaintype"
    || name = "forkdigest"
  then Some 4
  else if
    ends_with name "_root" || ends_with name "_hash" || name = "root"
    || name = "hash32" || name = "domain"
  then Some 32
  else if name = "withdrawal_credentials" then Some 32
  else if name = "blspubkey" || name = "pubkey" then Some 48
  else if name = "blssignature" || name = "signature" then Some 96
  else if
    name = "executionaddress" || name = "fee_recipient" || name = "address"
  then Some 20
  else if name = "payloadid" then Some 8
  else if name = "nodeid" then Some 256
  else if name = "logs_bloom" then Some 256
  else None

(* Convert NumV to hex if it's a bytes type *)
(* Only convert to hex if explicitly bytes type or field name indicates bytes *)
let num_to_json ?field_name (typ : Typ.t') (num : Bigint.t) :
    (Yojson.Safe.t, error) result =
  (* First check if it's explicitly a bytes type (bytes4, bytes32, etc.) *)
  match bytes_len_from_typ typ with
  | Some len ->
      (* It's a bytes type, convert to hex string *)
      `String (bytes_to_hex_string num len) |> Result.ok
  | None -> (
      (* Not a bytes type from type info, check field name as fallback *)
      match field_name with
      | Some fname -> (
          match bytes_len_from_field_name fname with
          | Some len ->
              (* Field name indicates bytes type, convert to hex string *)
              `String (bytes_to_hex_string num len) |> Result.ok
          | None ->
              (* Regular number, output as number (not hex) *)
              `Intlit (Bigint.to_string num) |> Result.ok)
      | None ->
          (* No field name, regular number (not hex) *)
          `Intlit (Bigint.to_string num) |> Result.ok)

let rec value_to_json ?field_name (v : Value.t) : (Yojson.Safe.t, error) result
    =
  match v.it with
  | BoolV b -> `Bool b |> Result.ok
  | NumV (`Int n) -> num_to_json ?field_name v.note.typ n
  | NumV (`Nat n) -> num_to_json ?field_name v.note.typ n
  | BytesV { num; len } -> (
      (* For BytesV, check if we need to use type-based length instead of actual length *)
      match bytes_len_from_typ v.note.typ with
      | Some type_len ->
          (* Type specifies a fixed length, use that (for padding) *)
          `String (bytes_to_hex_string num type_len) |> Result.ok
      | None -> (
          (* Try field name as fallback *)
          match field_name with
          | Some fname -> (
              match bytes_len_from_field_name fname with
              | Some type_len ->
                  (* Field name indicates bytes type, use that length *)
                  `String (bytes_to_hex_string num type_len) |> Result.ok
              | None ->
                  (* No type length, use actual length from BytesV *)
                  `String (bytes_to_hex_string num len) |> Result.ok)
          | None ->
              (* No type length, use actual length from BytesV *)
              `String (bytes_to_hex_string num len) |> Result.ok))
  | ListV vs ->
      (* For list elements, use num_to_json for NumV to ensure consistent type handling *)
      (* This reuses the existing type-checking logic instead of duplicating it *)
      let elem_typ =
        match v.note.typ with
        | IterT (elem_typ, _) -> Some elem_typ.it
        | _ -> None
      in
      let rec print_values acc = function
        | [] -> `List (List.rev acc) |> Result.ok
        | value_elem :: values ->
            (* For list elements, use num_to_json for NumV to ensure consistent handling *)
            let json_elem =
              match (value_elem.it, elem_typ) with
              | (NumV (`Int n) | NumV (`Nat n)), Some typ ->
                  (* Use num_to_json with element type from list type *)
                  num_to_json typ n
              | (NumV (`Int n) | NumV (`Nat n)), None ->
                  (* No element type info, use value's own type via num_to_json *)
                  num_to_json value_elem.note.typ n
              | _ ->
                  (* BytesV or other types, use value_to_json *)
                  value_to_json value_elem
            in
            let* json_elem = json_elem in
            print_values (json_elem :: acc) values
      in
      print_values [] vs
  | StructV fields ->
      let field_to_json (atom, value) =
        let field_name =
          Xl.Atom.string_of_atom atom.it |> String.lowercase_ascii
        in
        let* json_value = value_to_json ~field_name value in
        Ok (field_name, json_value)
      in
      let* json_fields = result_all (List.map field_to_json fields) in
      Ok (`Assoc json_fields)
  | TextV s -> `String s |> Result.ok
  | OptV None -> `Null |> Result.ok
  | OptV (Some v) -> value_to_json ?field_name v
  | _ -> Error (TypeMismatch ("Unsupported type or value", v.note.typ))
