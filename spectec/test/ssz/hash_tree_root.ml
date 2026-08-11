module Htr = Ethereum_ssz.Ssz_htr
module Schema = Ethereum_ssz.Ssz_schema
module Ethereum = Ethereum_ssz.Ethereum_schema

(* Root constants in this test were generated with a standalone Python
   hashlib SSZ reference, independently of the OCaml engine and adapter. *)
type value =
  | Boolean of bool
  | Integer of Bigint.t
  | Bytes of Bytes.t
  | Sequence of value list

let accessors : value Htr.accessors =
  {
    as_bool =
      (function Boolean value -> Ok value | _ -> Error "expected boolean");
    as_uint =
      (function Integer value -> Ok value | _ -> Error "expected integer");
    as_bytes =
      (fun ~length:_ ->
        function Bytes value -> Ok value | _ -> Error "expected bytes");
    as_sequence =
      (function Sequence values -> Ok values | _ -> Error "expected sequence");
    as_container =
      (function Sequence values -> Ok values | _ -> Error "expected container");
  }

let hex_of_bytes bytes =
  let buffer = Buffer.create (Bytes.length bytes * 2) in
  Bytes.iter
    (fun byte -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents buffer

let check_root name expected schema value =
  match Htr.hash_tree_root ~accessors schema value with
  | Ok root ->
      let actual = hex_of_bytes root in
      if not (String.equal expected actual) then
        failwith
          (Printf.sprintf "%s: expected %s, got %s" name expected actual)
  | Error error ->
      failwith (Printf.sprintf "%s: %s" name (Htr.error_to_string error))

let check_rejected name schema value =
  match Htr.hash_tree_root ~accessors schema value with
  | Error _ -> ()
  | Ok root ->
      failwith
        (Printf.sprintf "%s: expected rejection, got %s" name
           (hex_of_bytes root))

let integer value = Integer (Bigint.of_int value)

let alternating_bits length =
  Sequence (List.init length (fun index -> Boolean (index mod 3 = 0)))

let bytes_from_zero length = Bytes (Bytes.init length Char.chr)

let leaf byte =
  let value = Bytes.make 32 '\x00' in
  Bytes.set value 0 (Char.chr byte);
  Bytes value

let indexed_leaves length =
  Sequence (List.init length (fun index -> leaf (index mod 251)))

type fork = Capella | Deneb

let rec zero_value fork = function
  | Schema.Bool -> Boolean false
  | Schema.Uint _ -> integer 0
  | Schema.Byte_vector length -> Bytes (Bytes.make length '\x00')
  | Schema.Byte_list _ -> Bytes Bytes.empty
  | Schema.Bit_vector length ->
      Sequence (List.init length (Fun.const (Boolean false)))
  | Schema.Bit_list _ | Schema.List _ -> Sequence []
  | Schema.Vector (element, length) ->
      Sequence (List.init length (Fun.const (zero_value fork element)))
  | Schema.Container fields ->
      Sequence
        (List.map (fun field -> zero_value fork field.Schema.schema) fields)
  | Schema.Container_variants variants ->
      let index = match fork with Capella -> 0 | Deneb -> 1 in
      let fields = List.nth variants index in
      Sequence
        (List.map (fun field -> zero_value fork field.Schema.schema) fields)

let check_zero_root name expected fork schema =
  check_root name expected schema (zero_value fork schema)

let () =
  check_root "Ethereum Checkpoint schema"
    "1bc121515fb6438a027f365fc291317a815fdd3bd05ad85dff24879a1a3276b1"
    Ethereum.checkpoint
    (Sequence [ integer 3; Bytes (Bytes.init 32 Char.chr) ]);

  check_root "ByteList length mixing"
    "9863be41f9700db1a6da98141f7d9a2ae172a578d5cad6b3bcf39e9e1598f13a"
    (Schema.Byte_list 32) (Bytes (Bytes.of_string "abc"));

  List.iter
    (fun (length, expected) ->
      check_root (Printf.sprintf "ByteVector[%d] chunk boundary" length)
        expected (Schema.Byte_vector length) (bytes_from_zero length))
    [
      ( 31,
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e00"
      );
      ( 32,
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
      );
      ( 33,
        "d1fe638391d3ea81f192505cef1b81ec87821b255c6ec8896e399a7a4cc8413e"
      );
    ];

  check_root "ByteList[33] empty"
    "7a0501f5957bdf9cb3a8ff4966f02265f968658b7a9c62642cba1165e86642f5"
    (Schema.Byte_list 33) (Bytes Bytes.empty);
  List.iter
    (fun (length, expected) ->
      check_root (Printf.sprintf "ByteList[33] length %d" length) expected
        (Schema.Byte_list 33) (bytes_from_zero length))
    [
      (31, "f61288058d4c106ffe81545ba11e23c5e5b97a4cc5f0bbe03b2983cdc6a02ec4");
      (32, "c96b7e311178900fb54e96a5b7f0d6776024018bb48f7eeaa0d9bb2fd6066a8d");
      (33, "635625879e3d12286181b0fc1449cc79807f77b1aeacf4185e51f6eeba6ef080");
    ];
  check_rejected "ByteList[33] over limit" (Schema.Byte_list 33)
    (bytes_from_zero 34);
  check_rejected "ByteVector[32] under length" (Schema.Byte_vector 32)
    (bytes_from_zero 31);
  check_rejected "ByteVector[32] over length" (Schema.Byte_vector 32)
    (bytes_from_zero 33);

  check_root "composite List"
    "194bad49fedb07a784ee3d70ba18ca61b31e3fa35b16b7f7ae42973d1a67f779"
    (Schema.List (Schema.Byte_vector 32, 4))
    (Sequence [ leaf 1; leaf 2 ]);

  check_root "large logical List limit"
    "7dd52b2055ed30d8c11e81178ad08677f943d36b99f3df34e7dca4a950365d05"
    (Schema.List (Schema.Byte_vector 32, 1 lsl 30))
    (Sequence [ leaf 1 ]);

  check_root "Vector of composite ByteVector[48]"
    "bfa4108c5d5878b2aa52aaa74fcf141b1989f9b9a99ab2e234b3e63ca7e4e7c5"
    (Schema.Vector (Schema.Byte_vector 48, 2))
    (Sequence
       [
         Bytes (Bytes.init 48 Char.chr);
         Bytes (Bytes.init 48 (fun i -> Char.chr (i + 48)));
       ]);

  let variants =
    Schema.Container_variants
      [
        [ Schema.field "ONLY" (Schema.Uint 1) ];
        [
          Schema.field "LEFT" (Schema.Uint 1);
          Schema.field "RIGHT" (Schema.Uint 1);
        ];
      ]
  in
  check_root "container arity variant"
    "ff55c97976a840b4ced964ed49e3794594ba3f675238b5fd25d282b60f70a194"
    variants (Sequence [ integer 1; integer 2 ]);

  check_root "basic List packing"
    "cb24423d7c328b1a4d63335d02cf6f58fe9fbfc683fccf5d373d2bf9e9b46c29"
    (Schema.List (Schema.Uint 8, 8))
    (Sequence
       [
         integer 1;
         integer 2;
         Integer (Bigint.of_string "72623859790382856");
       ]);

  check_root "basic Vector packing"
    "0100000000000000020000000000000008070605040302010000000000000000"
    (Schema.Vector (Schema.Uint 8, 3))
    (Sequence
       [
         integer 1;
         integer 2;
         Integer (Bigint.of_string "72623859790382856");
       ]);

  check_root "Bitlist packing"
    "dc09c830ee660a3fcb3423d42e2bf99f5eadb8d15378ddde5ba658cb5e6de517"
    (Schema.Bit_list 512)
    (Sequence
       [
         Boolean true;
         Boolean false;
         Boolean true;
         Boolean true;
         Boolean false;
         Boolean false;
         Boolean false;
         Boolean true;
         Boolean true;
       ]);

  check_root "empty Bitlist"
    "7a0501f5957bdf9cb3a8ff4966f02265f968658b7a9c62642cba1165e86642f5"
    (Schema.Bit_list 512) (Sequence []);

  List.iter
    (fun (length, expected) ->
      check_root (Printf.sprintf "Bitvector[%d] boundary" length) expected
        (Schema.Bit_vector length) (alternating_bits length))
    [
      (255, "4992244992244992244992244992244992244992244992244992244992244912");
      (256, "4992244992244992244992244992244992244992244992244992244992244992");
      (257, "77c571049a1de6558a3d5ec7cfbd12d07901b91b1bb32ff4a26353d6493b37fc");
    ];

  check_root "Bitlist[257] empty"
    "7a0501f5957bdf9cb3a8ff4966f02265f968658b7a9c62642cba1165e86642f5"
    (Schema.Bit_list 257) (Sequence []);
  List.iter
    (fun (length, expected) ->
      check_root (Printf.sprintf "Bitlist[257] length %d" length) expected
        (Schema.Bit_list 257) (alternating_bits length))
    [
      (255, "c3362ae9ebd383368b0b2a19d830219a39c34a482f2975536c82e16b39128702");
      (256, "25f01ef233dd44d2615671507b9a90483b7823f384453d6be67e24f0f6bfb0c6");
      (257, "fec916f5b6e1bc6234bb5acc03c02a861decd249025933af4b3101b8232a0377");
    ];
  check_rejected "Bitlist[257] over limit" (Schema.Bit_list 257)
    (alternating_bits 258);

  check_root "composite List[257] empty"
    "8d88050ac84001d0796fc9de86de5768a435c21150ee647c28e02118ef69cd8e"
    (Schema.List (Schema.Byte_vector 32, 257)) (Sequence []);
  List.iter
    (fun (length, expected) ->
      check_root (Printf.sprintf "composite List[257] length %d" length)
        expected
        (Schema.List (Schema.Byte_vector 32, 257))
        (indexed_leaves length))
    [
      (255, "fd13a08fdcab55c032cb0a0ecdd824e4f0c55e8b48b76e6ee3a2529fb35bcb31");
      (256, "c1046a5a0cb28c591e6f46a0229b3122c16d570d45294234ce837bfd2c9b3429");
      (257, "f07002b4271e8affabd2ec26e5260b1f9ff2361537192c4c5034e077e0250e31");
    ];
  check_rejected "composite List[257] over limit"
    (Schema.List (Schema.Byte_vector 32, 257))
    (indexed_leaves 258);

  check_root "basic List exact limit"
    "149f1afcf7cc2c9fa187d3c36a3bdc95c7a3e49b7176407eaddf6601f19ea4b9"
    (Schema.List (Schema.Uint 1, 3))
    (Sequence [ integer 1; integer 2; integer 3 ]);
  check_rejected "basic List over limit" (Schema.List (Schema.Uint 1, 3))
    (Sequence [ integer 1; integer 2; integer 3; integer 4 ]);

  check_rejected "fixed Vector arity"
    (Schema.Vector (Schema.Uint 8, 2))
    (Sequence [ integer 1 ]);
  check_rejected "fixed Vector over arity"
    (Schema.Vector (Schema.Uint 8, 2))
    (Sequence [ integer 1; integer 2; integer 3 ]);
  check_rejected "fixed Bitvector under length" (Schema.Bit_vector 256)
    (alternating_bits 255);
  check_rejected "fixed Bitvector over length" (Schema.Bit_vector 256)
    (alternating_bits 257);

  check_rejected "negative uint" (Schema.Uint 1) (integer (-1));
  check_rejected "uint upper bound" (Schema.Uint 1) (integer 256);
  check_rejected "invalid nested schema"
    (Schema.List (Schema.Byte_vector 0, 1))
    (Sequence []);

  check_zero_root "Capella ExecutionPayload dispatch"
    "71fc711580d19a351698dab1391666d849e0609aea020965156b5e8d8c83a2e7"
    Capella Ethereum.execution_payload;
  check_zero_root "Deneb ExecutionPayload dispatch"
    "2e061cffdc4f4086a06e906f47de586de5ba31fbff54f361f5374b8ecaf7f50e"
    Deneb Ethereum.execution_payload;
  check_zero_root "Capella ExecutionPayloadHeader dispatch"
    "22216a4a17e55cc41ce454600e5deb8aad32f15580a938b1914f93a9652c0e2c"
    Capella Ethereum.execution_payload_header;
  check_zero_root "Deneb ExecutionPayloadHeader dispatch"
    "54b4b8b897929a1ede97d29e9551d610229f22c1a59d186d95aed203333b4e5e"
    Deneb Ethereum.execution_payload_header;
  check_zero_root "Capella BeaconBlockBody dispatch"
    "74b4bb048d39c75f175fbb2311062eb9867d79b712907f39544fcaf2d7e1b433"
    Capella Ethereum.beacon_block_body;
  check_zero_root "Deneb BeaconBlockBody dispatch"
    "bce73ee2c617851846af2b3ea2287e3b686098e18ae508c7271aaa06ab1d06cd"
    Deneb Ethereum.beacon_block_body;
  check_zero_root "Capella BeaconState nested header dispatch"
    "6c1dbede1fac000558326175f03b5e4fc73f63f383143b1a415d83cc209ca92f"
    Capella Ethereum.beacon_state;
  check_zero_root "Deneb BeaconState nested header dispatch"
    "e6b7639e8c664e1969196fd2a97a275fc3ebb02b811b80b4736d35b6b73c2161"
    Deneb Ethereum.beacon_state;

  let malformed_variant arity = Sequence (List.init arity (Fun.const (integer 0))) in
  check_rejected "ExecutionPayload unknown fork arity" Ethereum.execution_payload
    (malformed_variant 16);
  check_rejected "ExecutionPayloadHeader unknown fork arity"
    Ethereum.execution_payload_header (malformed_variant 16);
  check_rejected "BeaconBlockBody unknown fork arity" Ethereum.beacon_block_body
    (malformed_variant 13);

  Printf.printf "Schema-driven SSZ hash_tree_root tests passed\n"
