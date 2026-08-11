type t =
  | Bool
  | Uint of int
  | Byte_vector of int
  | Byte_list of int
  | Bit_vector of int
  | Bit_list of int
  | Vector of t * int
  | List of t * int
  | Container of field list
  | Container_variants of field list list

and field = {
  name : string;
  schema : t;
}

let field name schema = { name; schema }

let rec to_string = function
  | Bool -> "bool"
  | Uint byte_length -> Printf.sprintf "uint%d" (byte_length * 8)
  | Byte_vector length -> Printf.sprintf "ByteVector[%d]" length
  | Byte_list limit -> Printf.sprintf "ByteList[%d]" limit
  | Bit_vector length -> Printf.sprintf "Bitvector[%d]" length
  | Bit_list limit -> Printf.sprintf "Bitlist[%d]" limit
  | Vector (element, length) ->
      Printf.sprintf "Vector[%s, %d]" (to_string element) length
  | List (element, limit) ->
      Printf.sprintf "List[%s, %d]" (to_string element) limit
  | Container fields -> fields_to_string fields
  | Container_variants variants ->
      variants |> List.map fields_to_string |> String.concat " | "

and fields_to_string fields =
  let field_to_string { name; schema } =
    Printf.sprintf "%s: %s" name (to_string schema)
  in
  Printf.sprintf "Container{%s}"
    (fields |> List.map field_to_string |> String.concat "; ")
