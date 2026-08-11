module Bytes = Stdlib.Bytes

type 'a accessors = {
  as_bool : 'a -> (bool, string) result;
  as_uint : 'a -> (Bigint.t, string) result;
  as_bytes : length:int option -> 'a -> (Bytes.t, string) result;
  as_sequence : 'a -> ('a list, string) result;
  as_container : 'a -> ('a list, string) result;
}

type error = {
  path : string list;
  message : string;
}

let error_to_string { path; message } =
  let append_segment rendered segment =
    if String.length segment > 0 && segment.[0] = '[' then rendered ^ segment
    else rendered ^ "." ^ segment
  in
  Printf.sprintf "%s: %s" (List.fold_left append_segment "root" path) message

let to_string = error_to_string
let ( let* ) result f = match result with Ok value -> f value | Error _ as e -> e
let fail path message = Error { path; message }

let access path accessor value =
  match accessor value with Ok converted -> Ok converted | Error message -> fail path message

let is_valid_uint_width byte_length =
  byte_length > 0
  && byte_length <= 32
  && byte_length land (byte_length - 1) = 0

let validate_uint_width path byte_length =
  if is_valid_uint_width byte_length then Ok ()
  else
    fail path
      (Printf.sprintf
         "invalid SSZ uint width %d bytes (expected 1, 2, 4, 8, 16, or 32)"
         byte_length)

let validate_positive path kind value =
  if value > 0 then Ok ()
  else fail path (Printf.sprintf "%s must be positive, got %d" kind value)

let checked_product path description left right =
  if left < 0 || right < 0 then
    fail path (Printf.sprintf "%s cannot be negative" description)
  else if left <> 0 && right > max_int / left then
    fail path (Printf.sprintf "%s exceeds the platform integer range" description)
  else Ok (left * right)

let ceil_div numerator denominator =
  if numerator = 0 then 0 else 1 + ((numerator - 1) / denominator)

let path_index path index = path @ [ Printf.sprintf "[%d]" index ]

let path_field path index name =
  if String.length name = 0 then path_index path index else path @ [ name ]

let little_endian_bytes value byte_length =
  let bytes = Bytes.make byte_length '\x00' in
  let remaining = ref value in
  for index = 0 to byte_length - 1 do
    let byte =
      Bigint.to_int_exn Bigint.(bit_and !remaining (of_int 0xff))
    in
    Bytes.set bytes index (Char.chr byte);
    remaining := Bigint.shift_right !remaining 8
  done;
  bytes

let uint_in_range value byte_length =
  Bigint.(value >= zero && value < Ssz_merkle.pow2_8 byte_length)

let root_of_serialized_bytes bytes chunk_limit =
  bytes |> Ssz_merkle.chunkize_bytes_bytev
  |> fun chunks -> Ssz_merkle.merkleize_chunks_with_limit chunks chunk_limit

let pack_bits bits =
  let bit_length = List.length bits in
  let bytes = Bytes.make (ceil_div bit_length 8) '\x00' in
  List.iteri
    (fun index bit ->
      if bit then
        let byte_index = index / 8 in
        let bit_index = index mod 8 in
        let byte = Char.code (Bytes.get bytes byte_index) in
        Bytes.set bytes byte_index (Char.chr (byte lor (1 lsl bit_index))))
    bits;
  bytes

let hash_tree_root ~accessors schema value =
  let open Ssz_schema in
  let rec validate_schema path = function
    | Bool -> Ok ()
    | Uint byte_length -> validate_uint_width path byte_length
    | Byte_vector length ->
        validate_positive path "byte-vector length" length
    | Byte_list limit -> validate_positive path "byte-list limit" limit
    | Bit_vector length -> validate_positive path "bitvector length" length
    | Bit_list limit -> validate_positive path "bitlist limit" limit
    | Vector (element, length) ->
        let* () = validate_positive path "vector length" length in
        validate_schema (path @ [ "<element>" ]) element
    | List (element, limit) ->
        let* () = validate_positive path "list limit" limit in
        validate_schema (path @ [ "<element>" ]) element
    | Container fields -> validate_fields path fields
    | Container_variants variants ->
        if variants = [] then
          fail path "container variants must contain at least one layout"
        else
          let arities = List.map List.length variants in
          let unique_arities = List.sort_uniq Int.compare arities in
          if List.length arities <> List.length unique_arities then
            fail path "container variants must have distinct field counts"
          else validate_variants path 0 variants
  and validate_fields path fields =
    let rec loop index = function
      | [] -> Ok ()
      | field :: remaining ->
          let* () =
            validate_schema (path_field path index field.name) field.schema
          in
          loop (index + 1) remaining
    in
    loop 0 fields
  and validate_variants path index = function
    | [] -> Ok ()
    | fields :: remaining ->
        let* () =
          validate_fields (path @ [ Printf.sprintf "<variant:%d>" index ])
            fields
        in
        validate_variants path (index + 1) remaining
  in
  let encode_basic path schema value =
    match schema with
    | Bool ->
        let* boolean = access path accessors.as_bool value in
        Ok (Bytes.make 1 (if boolean then '\x01' else '\x00'))
    | Uint byte_length ->
        let* () = validate_uint_width path byte_length in
        let* integer = access path accessors.as_uint value in
        if uint_in_range integer byte_length then
          Ok (little_endian_bytes integer byte_length)
        else
          fail path
            (Printf.sprintf "integer is outside the range of %s"
               (Ssz_schema.to_string schema))
    | _ -> fail path "internal error: expected an SSZ basic type"
  in
  let basic_size path = function
    | Bool -> Ok 1
    | Uint byte_length ->
        let* () = validate_uint_width path byte_length in
        Ok byte_length
    | _ -> fail path "internal error: expected an SSZ basic type"
  in
  let is_basic = function Bool | Uint _ -> true | _ -> false in
  let encode_basic_sequence path element values =
    let* element_size = basic_size path element in
    let count = List.length values in
    let* serialized_length =
      checked_product path "serialized basic sequence length" count
        element_size
    in
    let serialized = Bytes.make serialized_length '\x00' in
    let rec write index = function
      | [] -> Ok serialized
      | item :: rest ->
          let* encoded = encode_basic (path_index path index) element item in
          Bytes.blit encoded 0 serialized (index * element_size) element_size;
          write (index + 1) rest
    in
    write 0 values
  in
  let bits_of_value path value =
    let* values = access path accessors.as_sequence value in
    let rec convert index accumulator = function
      | [] -> Ok (List.rev accumulator)
      | item :: rest ->
          let* bit = access (path_index path index) accessors.as_bool item in
          convert (index + 1) (bit :: accumulator) rest
    in
    convert 0 [] values
  in
  let rec hash path schema value =
    match schema with
    | Bool | Uint _ ->
        let* serialized = encode_basic path schema value in
        let root = Bytes.make 32 '\x00' in
        Bytes.blit serialized 0 root 0 (Bytes.length serialized);
        Ok root
    | Byte_vector length ->
        let* () = validate_positive path "byte-vector length" length in
        let* bytes = access path (accessors.as_bytes ~length:(Some length)) value in
        let actual = Bytes.length bytes in
        if actual <> length then
          fail path
            (Printf.sprintf "expected %d bytes, got %d" length actual)
        else
          let chunk_count = ceil_div length 32 in
          Ok (root_of_serialized_bytes bytes chunk_count)
    | Byte_list limit ->
        let* () = validate_positive path "byte-list limit" limit in
        let* bytes = access path (accessors.as_bytes ~length:None) value in
        let actual = Bytes.length bytes in
        if actual > limit then
          fail path
            (Printf.sprintf "byte list length %d exceeds limit %d" actual limit)
        else
          let chunk_limit = ceil_div limit 32 in
          let root = root_of_serialized_bytes bytes chunk_limit in
          Ok (Ssz_merkle.mix_in_length root (Bigint.of_int actual))
    | Bit_vector length ->
        let* () = validate_positive path "bitvector length" length in
        let* bits = bits_of_value path value in
        let actual = List.length bits in
        if actual <> length then
          fail path
            (Printf.sprintf "expected %d bits, got %d" length actual)
        else
          let root = root_of_serialized_bytes (pack_bits bits) (ceil_div length 256) in
          Ok root
    | Bit_list limit ->
        let* () = validate_positive path "bitlist limit" limit in
        let* bits = bits_of_value path value in
        let actual = List.length bits in
        if actual > limit then
          fail path
            (Printf.sprintf "bitlist length %d exceeds limit %d" actual limit)
        else
          let root = root_of_serialized_bytes (pack_bits bits) (ceil_div limit 256) in
          Ok (Ssz_merkle.mix_in_length root (Bigint.of_int actual))
    | Vector (element, length) ->
        let* () = validate_positive path "vector length" length in
        let* values = access path accessors.as_sequence value in
        let actual = List.length values in
        if actual <> length then
          fail path
            (Printf.sprintf "expected %d vector elements, got %d" length actual)
        else if is_basic element then
          let* element_size = basic_size path element in
          let* serialized_limit =
            checked_product path "serialized vector length" length element_size
          in
          let* serialized = encode_basic_sequence path element values in
          Ok
            (root_of_serialized_bytes serialized
               (ceil_div serialized_limit 32))
        else
          let* roots = hash_elements path element values in
          Ok (Ssz_merkle.merkleize_chunks_with_limit roots length)
    | List (element, limit) ->
        let* () = validate_positive path "list limit" limit in
        let* values = access path accessors.as_sequence value in
        let actual = List.length values in
        if actual > limit then
          fail path
            (Printf.sprintf "list length %d exceeds limit %d" actual limit)
        else if is_basic element then
          let* element_size = basic_size path element in
          let* serialized_limit =
            checked_product path "serialized list limit" limit element_size
          in
          let* serialized = encode_basic_sequence path element values in
          let root =
            root_of_serialized_bytes serialized (ceil_div serialized_limit 32)
          in
          Ok (Ssz_merkle.mix_in_length root (Bigint.of_int actual))
        else
          let* roots = hash_elements path element values in
          let root = Ssz_merkle.merkleize_chunks_with_limit roots limit in
          Ok (Ssz_merkle.mix_in_length root (Bigint.of_int actual))
    | Container fields ->
        let* values = access path accessors.as_container value in
        hash_container path fields values
    | Container_variants variants ->
        let* values = access path accessors.as_container value in
        let arity = List.length values in
        let matching =
          List.filter (fun fields -> List.length fields = arity) variants
        in
        (match matching with
        | [ fields ] -> hash_container path fields values
        | [] ->
            let expected =
              variants
              |> List.map (fun fields -> string_of_int (List.length fields))
              |> String.concat ", "
            in
            fail path
              (Printf.sprintf
                 "container has %d fields; expected one of these arities: %s"
                 arity expected)
        | _ ->
            fail path
              (Printf.sprintf
                 "container schema has multiple variants with arity %d" arity))
  and hash_elements path schema values =
    let roots =
      Array.make (List.length values) (Ssz_merkle.zero_chunk ())
    in
    let rec fill index = function
      | [] -> Ok roots
      | item :: rest ->
          let* root = hash (path_index path index) schema item in
          roots.(index) <- root;
          fill (index + 1) rest
    in
    fill 0 values
  and hash_container path fields values =
    let expected = List.length fields in
    let actual = List.length values in
    if actual <> expected then
      fail path
        (Printf.sprintf "expected %d container fields, got %d" expected actual)
    else
      let roots = Array.make expected (Ssz_merkle.zero_chunk ()) in
      let rec fill index fields values =
        match (fields, values) with
        | [], [] -> Ok roots
        | field :: remaining_fields, item :: remaining_values ->
            let field_path = path_field path index field.name in
            let* root = hash field_path field.schema item in
            roots.(index) <- root;
            fill (index + 1) remaining_fields remaining_values
        | _ -> fail path "internal error: container arity changed during hashing"
      in
      let* roots = fill 0 fields values in
      Ok
        (Ssz_merkle.merkleize_chunks_with_limit roots (Array.length roots))
  in
  let* () = validate_schema [] schema in
  hash [] schema value
