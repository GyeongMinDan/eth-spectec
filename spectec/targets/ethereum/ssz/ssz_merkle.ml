module Bytes = Stdlib.Bytes

let invalid_argf format = Printf.ksprintf invalid_arg format

let pow2_8 (n : int) =
  if n < 0 then invalid_argf "pow2_8: negative byte width %d" n;
  if n > max_int / 8 then
    invalid_argf "pow2_8: byte width %d exceeds the platform integer range" n;
  Bigint.pow (Bigint.of_int 2) (Bigint.of_int (8 * n))

let be_of_bigint_fixed (n : Bigint.t) ~(len : int) : Bytes.t =
  if len < 0 then invalid_argf "be_of_bigint_fixed: negative length %d" len;
  if Bigint.(n < zero || n >= pow2_8 len) then
    invalid_argf "be_of_bigint_fixed: value does not fit in %d bytes" len;
  let out = Bytes.create len in
  let rec fill i v =
    if i < 0 then ()
    else
      let byte = Bigint.to_int_exn Bigint.(v % of_int 256) in
      Bytes.set out i (Stdlib.Char.chr byte);
      fill (i - 1) Bigint.(v / of_int 256)
  in
  fill (len - 1) n;
  out

let bigint_of_be_bytes (b : Bytes.t) : Bigint.t =
  let acc = ref Bigint.zero in
  for i = 0 to Bytes.length b - 1 do
    let v = Stdlib.Char.code (Bytes.get b i) in
    acc := Bigint.((!acc * of_int 256) + of_int v)
  done;
  !acc

let sha256_bytes32 (x : Bytes.t) : Bigint.t =
  let open Digestif.SHA256 in
  digest_bytes x |> to_raw_string |> Bytes.of_string |> bigint_of_be_bytes

let merkle_hash_ (left : Bytes.t) (right : Bytes.t) : Bytes.t =
  if Bytes.length left <> 32 || Bytes.length right <> 32 then
    invalid_arg "merkle_hash_: both inputs must be 32-byte chunks";
  let cat = Bytes.create 64 in
  Bytes.blit left 0 cat 0 32;
  Bytes.blit right 0 cat 32 32;
  Digestif.SHA256.(digest_bytes cat |> to_raw_string |> Bytes.of_string)

let zero_chunk () : Bytes.t = Bytes.make 32 '\x00'

let bit_length_of (v : int) : int =
  if v <= 0 then 0
  else if v = 1 then 1
  else
    let rec go v acc = if v = 0 then acc else go (v lsr 1) (acc + 1) in
    go (v lsr 1) 1

(* [zero_hashes.(h)] is the root of an all-zero subtree of depth [h]. *)
let compute_zero_hashes ~max_depth : Bytes.t array =
  if max_depth < 0 then invalid_arg "compute_zero_hashes: negative depth";
  let arr = Array.init (max_depth + 1) (fun _ -> zero_chunk ()) in
  for h = 0 to max_depth - 1 do
    arr.(h + 1) <- merkle_hash_ arr.(h) arr.(h)
  done;
  arr

let merkleize_chunks_with_limit (leaves : Bytes.t array) (limit : int) : Bytes.t
    =
  let n = Array.length leaves in
  if limit < 0 then
    invalid_argf "merkleize_chunks_with_limit: negative limit %d" limit;
  if n > limit then
    invalid_argf
      "merkleize_chunks_with_limit: %d leaves exceed limit %d" n limit;
  Array.iteri
    (fun index leaf ->
      if Bytes.length leaf <> 32 then
        invalid_argf
          "merkleize_chunks_with_limit: leaf %d has length %d, expected 32"
          index (Bytes.length leaf))
    leaves;
  if limit = 0 then zero_chunk ()
  else if n = 0 then
    let max_depth = if limit <= 1 then 0 else bit_length_of (limit - 1) in
    let zero_hashes = compute_zero_hashes ~max_depth in
    zero_hashes.(max_depth)
  else
    let count = n in
    let depth = if count = 0 then 0 else bit_length_of (count - 1) in
    let max_depth = if limit = 0 then 0 else bit_length_of (limit - 1) in
    let tmp = Array.make (max_depth + 1) None in
    let zero_hashes = compute_zero_hashes ~max_depth in
    (* Merge one chunk into the frontier. When [i = count], this also pads the
       partially filled right edge to the next power of two. *)
    let merge (h : Bytes.t) (i : int) : unit =
      let h = ref h in
      let j = ref 0 in
      let should_break = ref false in
      while not !should_break do
        let bit_mask = 1 lsl !j in
        let bit_set = i land bit_mask in
        (if bit_set = 0 then
           if i = count && !j < depth then
             h := merkle_hash_ !h zero_hashes.(!j)
           else should_break := true
         else
           match tmp.(!j) with
           | None ->
               invalid_arg
                 (Printf.sprintf
                    "merkleize_chunks_with_limit: tmp[%d] is None when i=%d, \
                     j=%d"
                    !j i !j)
           | Some prev -> h := merkle_hash_ prev !h);
        if not !should_break then j := !j + 1
      done;
      tmp.(!j) <- Some !h
    in
    for i = 0 to count - 1 do
      merge leaves.(i) i
    done;
    (* Complete a non-power-of-two leaf count. *)
    if 1 lsl depth <> count then merge zero_hashes.(0) count;
    (* Lift the actual tree to the logical depth implied by [limit] without
       allocating the logically absent leaves. *)
    if depth <= max_depth - 1 then
      for j = depth to max_depth - 1 do
        let prev =
          match tmp.(j) with
          | None ->
              invalid_arg
                (Printf.sprintf
                   "merkleize_chunks_with_limit: tmp[%d] is None during lift" j)
          | Some h -> h
        in
        tmp.(j + 1) <- Some (merkle_hash_ prev zero_hashes.(j))
      done;
    let final =
      match tmp.(max_depth) with
      | None ->
          invalid_arg
            (Printf.sprintf
               "merkleize_chunks_with_limit: tmp[%d] is None after lift"
               max_depth)
      | Some h -> h
    in
    final

let merkleize_leaves (leaves : Bytes.t array) : Bytes.t =
  let n = Array.length leaves in
  merkleize_chunks_with_limit leaves n

let mix_in_length (root : Bytes.t) (len : Bigint.t) : Bytes.t =
  if Bytes.length root <> 32 then
    invalid_arg "mix_in_length: root must be a 32-byte chunk";
  if Bigint.(len < zero || len >= pow2_8 32) then
    invalid_arg "mix_in_length: length does not fit in uint256";
  let le32 = Bytes.make 32 '\x00' in
  let v = ref len in
  for i = 0 to 31 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set le32 i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
  merkle_hash_ root le32

let chunkize_bytes_bytev (raw : Bytes.t) : Bytes.t array =
  let len = Bytes.length raw in
  let full = len / 32 * 32 in
  let k = if len = full then len / 32 else (len / 32) + 1 in
  if k = 0 then [||]
  else
    Array.init k (fun i ->
        let start = i * 32 in
        if start < len then (
          let c = Bytes.make 32 '\x00' in
          let copy_len = min 32 (len - start) in
          Bytes.blit raw start c 0 copy_len;
          c)
        else Bytes.make 32 '\x00')

let leaf_uint_le (n : Bigint.t) ~(nbytes : int) : Bytes.t =
  if nbytes < 0 || nbytes > 32 then
    invalid_argf "leaf_uint_le: invalid byte width %d" nbytes;
  if Bigint.(n < zero || n >= pow2_8 nbytes) then
    invalid_argf "leaf_uint_le: value does not fit in %d bytes" nbytes;
  let c = Bytes.make 32 '\x00' in
  let v = ref n in
  for i = 0 to nbytes - 1 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set c i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
  c

let leaf_bytes32 (x : Bigint.t) : Bytes.t = be_of_bigint_fixed x ~len:32
