module Merkle = Ethereum_ssz.Ssz_merkle

let hex_of_bytes bytes =
  let buffer = Buffer.create (Bytes.length bytes * 2) in
  Bytes.iter
    (fun byte -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents buffer

let check_hex name expected actual =
  let actual = hex_of_bytes actual in
  if not (String.equal expected actual) then
    failwith
      (Printf.sprintf "%s: expected %s, got %s" name expected actual)

let check_int name expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %d, got %d" name expected actual)

let check_invalid_argument name f =
  try
    let _ = f () in
    failwith (Printf.sprintf "%s: expected Invalid_argument" name)
  with Invalid_argument _ -> ()

let leaf byte =
  let result = Bytes.make 32 '\x00' in
  Bytes.set result 0 (Char.chr byte);
  result

let () =
  let mutable_zero = Merkle.zero_chunk () in
  Bytes.set mutable_zero 0 '\x01';
  check_hex "fresh zero chunk" (String.make 64 '0') (Merkle.zero_chunk ());

  let sha256_abc =
    Merkle.sha256_bytes32 (Bytes.of_string "abc")
    |> Merkle.be_of_bigint_fixed ~len:32
  in
  check_hex "sha256(abc)"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    sha256_abc;

  let empty_limit_8 = Merkle.merkleize_chunks_with_limit [||] 8 in
  check_hex "empty tree with limit 8"
    "c78009fdf07fc56a11f122370658a353aaa542ed63e44c4bc15ff4cd105ab33c"
    empty_limit_8;

  let three_leaf_root =
    Merkle.merkleize_chunks_with_limit [| leaf 1; leaf 2; leaf 3 |] 4
  in
  check_hex "three-leaf tree"
    "66c419026fee8793be7fd0011b9db46b98a79f9c9b640e25317865c358f442db"
    three_leaf_root;
  check_hex "mix in length"
    "48e0187123ec029d586ac948fc8081f1e6d11632e336b41983c90685040fe63d"
    (Merkle.mix_in_length three_leaf_root (Bigint.of_int 3));

  let chunks = Merkle.chunkize_bytes_bytev (Bytes.init 33 Char.chr) in
  check_int "33-byte chunk count" 2 (Array.length chunks);
  check_hex "33-byte first chunk"
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    chunks.(0);
  check_hex "33-byte second chunk" ("20" ^ String.make 62 '0') chunks.(1);

  check_hex "big-endian fixed bytes" "00010203"
    (Merkle.be_of_bigint_fixed (Bigint.of_int 0x010203) ~len:4);
  check_hex "little-endian uint leaf"
    ("0807060504030201" ^ String.make 48 '0')
    (Merkle.leaf_uint_le (Bigint.of_int 0x0102030405060708) ~nbytes:8);

  check_invalid_argument "non-empty tree with zero limit" (fun () ->
      Merkle.merkleize_chunks_with_limit [| leaf 1 |] 0);
  check_invalid_argument "leaf count beyond limit" (fun () ->
      Merkle.merkleize_chunks_with_limit [| leaf 1; leaf 2 |] 1);
  check_invalid_argument "non-chunk leaf" (fun () ->
      Merkle.merkleize_chunks_with_limit [| Bytes.make 31 '\x00' |] 1);
  check_invalid_argument "fixed big-endian overflow" (fun () ->
      Merkle.be_of_bigint_fixed (Bigint.of_int 256) ~len:1);
  check_invalid_argument "negative little-endian uint" (fun () ->
      Merkle.leaf_uint_le (Bigint.of_int (-1)) ~nbytes:8);
  check_invalid_argument "power exponent overflow" (fun () ->
      Merkle.pow2_8 max_int);

  Printf.printf "SSZ Merkle primitive tests passed\n"
