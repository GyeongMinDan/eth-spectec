open Il
open Xl
open Util.Source
open Value

let ( let* ) = Result.bind

module Bytes = Stdlib.Bytes

(* Helpers *)
let pow2_8 (n : int) = Bigint.pow (Bigint.of_int 2) (Bigint.of_int (8 * n))

(* Hex string conversion helper *)
let bytes_to_hex (b : Bytes.t) : string =
  let len = Bytes.length b in
  let buf = Buffer.create (len * 2) in
  for i = 0 to len - 1 do
    Buffer.add_string buf
      (Printf.sprintf "%02x" (Stdlib.Char.code (Bytes.get b i)))
  done;
  Buffer.contents buf

let ensure_fits_bytes ~at (n : Bigint.t) ~(len : int) : (unit, Err.t) result =
  if Bigint.(n >= zero && n < pow2_8 len) then Ok ()
  else
    Error (Err.runtime at (Printf.sprintf "value does not fit in %d bytes" len))

let be_of_bigint_fixed (n : Bigint.t) ~(len : int) : Bytes.t =
  if Bigint.(n < zero) then invalid_arg "negative";
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

(* SSZ merkle helpers *)
let merkle_hash_ (left : Bytes.t) (right : Bytes.t) : Bytes.t =
  let cat = Bytes.create 64 in
  Bytes.blit left 0 cat 0 32;
  Bytes.blit right 0 cat 32 32;
  Digestif.SHA256.(digest_bytes cat |> to_raw_string |> Bytes.of_string)

let zero32 : Bytes.t = Bytes.make 32 '\x00'

(* Python의 bit_length 함수 (int.bit_length()) *)
let bit_length_of (v : int) : int =
  if v <= 0 then 0
  else if v = 1 then 1
  else
    let rec go v acc = if v = 0 then acc else go (v lsr 1) (acc + 1) in
    go (v lsr 1) 1

(* ZERO_HASHES: 각 높이별 완전한 zero 서브트리의 루트 *)
(* ZERO_HASHES[0] = zero32 *)
(* ZERO_HASHES[h+1] = H(ZERO_HASHES[h], ZERO_HASHES[h]) *)
let compute_zero_hashes ~max_depth : Bytes.t array =
  let arr = Array.make (max_depth + 1) zero32 in
  for h = 0 to max_depth - 1 do
    arr.(h + 1) <- merkle_hash_ arr.(h) arr.(h)
  done;
  arr

(* Python의 merkleize_chunks와 동일한 알고리즘 구현 *)
(* Vector의 경우 limit = count, List의 경우 limit은 별도로 지정 *)
let merkleize_chunks_with_limit (leaves : Bytes.t array) (limit : int) : Bytes.t
    =
  let n = Array.length leaves in
  if limit = 0 then zero32
  else if n = 0 then
    let max_depth = if limit <= 1 then 0 else bit_length_of (limit - 1) in
    let zero_hashes = compute_zero_hashes ~max_depth in
    zero_hashes.(max_depth)
  else
    let count = n in
    (* depth = max(count - 1, 0).bit_length() *)
    let depth = if count = 0 then 0 else bit_length_of (count - 1) in
    (* max_depth = (limit - 1).bit_length() *)
    let max_depth = if limit = 0 then 0 else bit_length_of (limit - 1) in
    (* Python의 merge 알고리즘 시뮬레이션 *)
    (* Python: tmp = [None for _ in range(max_depth + 1)] *)
    (* OCaml에서는 option 타입을 사용하여 None을 정확히 표현 *)
    let tmp = Array.make (max_depth + 1) None in
    let zero_hashes = compute_zero_hashes ~max_depth in
    (* Python의 merge 알고리즘을 정확히 재현 *)
    (* Python 코드:
       def merge(h, i):
           j = 0
           while True:
               if i & (1 << j) == 0:
                   if i == count and j < depth:
                       h = hash(h + zerohashes[j])
                   else:
                       break
               else:
                   h = hash(tmp[j] + h)
               j += 1
           tmp[j] = h
    *)
    let merge (h : Bytes.t) (i : int) : unit =
      let h = ref h in
      let j = ref 0 in
      let should_break = ref false in
      while not !should_break do
        (* i & (1 << j) 계산 *)
        let bit_mask = 1 lsl !j in
        let bit_set = i land bit_mask in
        (if bit_set = 0 then
           if
             (* i & (1 << j) == 0 *)
             i = count && !j < depth
           then
             (* keep going if we are complementing the void to the next power of 2 *)
             h := merkle_hash_ !h zero_hashes.(!j)
           else
             (* break *)
             should_break := true
         else
           (* i & (1 << j) != 0, 즉 비트가 설정됨 *)
           (* h = hash(tmp[j] + h) *)
           (* tmp[j]는 이미 값이 설정되어 있어야 함 (Python의 None 체크와 동일) *)
           match tmp.(!j) with
           | None ->
               invalid_arg
                 (Printf.sprintf
                    "merkleize_chunks_with_limit: tmp[%d] is None when i=%d, \
                     j=%d"
                    !j i !j)
           | Some prev -> h := merkle_hash_ prev !h);
        (* j += 1 (break할 때는 실행되지 않음) *)
        if not !should_break then j := !j + 1
      done;
      (* tmp[j] = h *)
      tmp.(!j) <- Some !h
    in
    (* merge in leaf by leaf *)
    for i = 0 to count - 1 do
      merge leaves.(i) i
    done;
    (* complement with 0 if empty, or if not the right power of 2 *)
    (* Python: merge(zerohashes[0], count) - zerohashes[0] = zero32 *)
    if 1 lsl depth <> count then merge zero_hashes.(0) count;
    (* the next power of two may be smaller than the ultimate virtual size, complement with zero-hashes at each depth *)
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

(* Vector의 경우: limit = count *)
let merkleize_leaves (leaves : Bytes.t array) : Bytes.t =
  let n = Array.length leaves in
  merkleize_chunks_with_limit leaves n

(* SSZ 규칙: List[T, N]은 최대 길이 N까지 zero-chunk로 패딩한 뒤 merkleize *)
(* 메모리 효율: limit이 매우 큰 경우 (예: VALIDATOR_REGISTRY_LIMIT) 가상 패딩 사용 *)
(* leaves: 각 요소의 32B root들 (컴포지트의 경우 요소별 HTR) *)
(* limit: List[...]의 최대 길이 N *)
let merkleize_list_composite_with_limit (leaves : Bytes.t array) (limit : int) :
    Bytes.t =
  let n = Array.length leaves in
  (* limit이 0인 경우 *)
  if limit = 0 then zero32
  else if
    (* Python의 merkleize_chunks 로직: depth = max(count-1, 0).bit_length(), max_depth = (limit-1).bit_length() *)
    (* 빈 리스트의 경우 zerohashes[max_depth]를 반환 *)
    (* Python: max_depth = (limit-1).bit_length() *)
    n = 0
  then
    let max_depth = if limit <= 1 then 0 else bit_length_of (limit - 1) in
    let zero_hashes = compute_zero_hashes ~max_depth in
    zero_hashes.(max_depth)
  else
    (* 메모리 효율: limit이 매우 큰 경우 (1억 이상) 가상 패딩 사용 *)
    let threshold = 100_000_000 in
    (* 1억 *)
    if limit > threshold then
      (* 큰 limit: 가상 패딩 방식 *)
      (* 1) 요소 머클: len -> pow2(len)까지 zero32 패딩은 merkleize_leaves가 처리 *)
      let h0 = merkleize_leaves leaves in
      (* 2) 깊이 보정: limit까지의 가상 패딩을 해시로만 "끌어올림" *)
      (* Python: depth = max(count-1, 0).bit_length(), max_depth = (limit-1).bit_length() *)
      let depth = if n = 0 then 0 else bit_length_of (n - 1) in
      let max_depth = if limit <= 1 then 0 else bit_length_of (limit - 1) in
      (* 각 레벨에 맞는 ZERO_HASHES를 사용하여 위로 끌어올리기 *)
      let zero_hashes = compute_zero_hashes ~max_depth in
      let rec lift h current_depth =
        if current_depth >= max_depth then h
        else
          (* 현재 높이의 zero 서브트리 루트를 오른쪽 형제로 사용 *)
          (* Python: tmp[j+1] = hash(tmp[j] + zerohashes[j]) *)
          let zero_at_depth = zero_hashes.(current_depth) in
          let h_next = merkle_hash_ h zero_at_depth in
          lift h_next (current_depth + 1)
      in
      lift h0 depth
    else
      (* 작은 limit: 실제 배열로 패딩 (정확한 결과 보장) *)
      let arr =
        if limit <= n then leaves
        else
          let a = Array.make limit zero32 in
          Array.blit leaves 0 a 0 n;
          a
      in
      merkleize_leaves arr

let mix_in_length (root : Bytes.t) (len : Bigint.t) : Bytes.t =
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

(* Basic 타입 시퀀스를 연속 바이트로 패킹 (LE) *)
let pack_basic_le (items : (Bigint.t * int) list) : Bytes.t =
  let total = List.fold_left (fun acc (_, n) -> acc + n) 0 items in
  let buf = Bytes.make total '\x00' in
  let off = ref 0 in
  List.iter
    (fun (v, nbytes) ->
      for i = 0 to nbytes - 1 do
        let shift_amount = 8 * i in
        let shifted = Bigint.shift_right v shift_amount in
        let b = Bigint.to_int_exn Bigint.(bit_and shifted (of_int 0xff)) in
        Bytes.set buf (!off + i) (Stdlib.Char.chr b)
      done;
      off := !off + nbytes)
    items;
  buf

(* Basic Vector: 연속 패킹 → 청크 → merkleize (mix_in_length 없음) *)
let htr_basic_vector (items : (Bigint.t * int) list) : Bytes.t =
  let packed = pack_basic_le items in
  let chunks = chunkize_bytes_bytev packed in
  merkleize_leaves chunks

(* Vector[bytes32, N] 전용: 각 32B를 그대로 리프로 사용 → 바로 merkleize *)
let htr_bytes32_vector (items_be32 : Bytes.t list) : Bytes.t =
  let leaves =
    items_be32
    |> List.map (fun b ->
           if Bytes.length b <> 32 then
             invalid_arg "htr_bytes32_vector: elem size != 32";
           (* 이미 32B라서 패딩/복사 불필요, 그대로 리프로 사용 *)
           b)
    |> Array.of_list
  in
  merkleize_leaves leaves

(* Vector[ByteVector[elem_size], N] 전용: 원소 바이트를 그대로 이어붙여 청크 → merkleize *)
let htr_fixed_bytevec_vector (items_be_bytes : Bytes.t list) ~(elem_size : int)
    : Bytes.t =
  let n = List.length items_be_bytes in
  let total = n * elem_size in
  let buf = Bytes.make total '\x00' in
  let off = ref 0 in
  List.iter
    (fun b ->
      if Bytes.length b <> elem_size then
        invalid_arg "htr_fixed_bytevec_vector: elem_size mismatch";
      Bytes.blit b 0 buf !off elem_size;
      off := !off + elem_size)
    items_be_bytes;
  chunkize_bytes_bytev buf |> merkleize_leaves

(* Basic List with limit: 연속 패킹 → 청크 → limit 기반 가상 패딩 → mix_in_length *)
let htr_basic_list_with_limit (items : (Bigint.t * int) list)
    (limit_elems : int) (elem_size : int) : Bytes.t =
  (* 원소 범위 검증: 각 원소가 해당 바이트 수에 맞는 범위인지 확인 *)
  let items_checked =
    List.map
      (fun (v, nbytes) ->
        if Bigint.(v < zero || v >= pow2_8 nbytes) then
          invalid_arg "htr_basic_list_with_limit: element out of range";
        (v, nbytes))
      items
  in
  let packed = pack_basic_le items_checked in
  let chunks = chunkize_bytes_bytev packed in
  (* limit에 따른 '필요 청크 수' = ceil(limit_elems * elem_size / 32) *)
  let need_chunks =
    let total_bytes = limit_elems * elem_size in
    if total_bytes = 0 then 0 else (total_bytes + 31) / 32
  in
  let root =
    if need_chunks = 0 then zero32
    else if Array.length chunks = 0 then
      (* 빈 리스트: ZERO_HASHES[max_depth]에 해당. max_depth = (need_chunks-1).bit_length() *)
      let max_depth =
        if need_chunks <= 1 then 0 else bit_length_of (need_chunks - 1)
      in
      let zero_hashes = compute_zero_hashes ~max_depth in
      zero_hashes.(max_depth)
    else
      (* Python의 merkleize_chunks(chunks, limit=need_chunks)를 직접 호출 *)
      merkleize_chunks_with_limit chunks need_chunks
  in
  (* 마지막에 실제 길이 mix_in_length *)
  (* SSZ 규칙: 모든 List 타입은 mix_in_length에 요소 개수를 넣어야 함 *)
  let elem_len = List.length items in
  mix_in_length root (Bigint.of_int elem_len)

(* ByteVector[N] 리스트 (예: List[bytes32, L]) 전용:
   - 각 원소를 "있는 그대로의 바이트열"로 이어붙임 (엔디언 변환 금지)
   - 그 바이트 버퍼를 32B 청크로 쪼개 Merkleize
   - limit 기반 가상 패딩(depth 고정) 후 mix_in_length 적용 *)
let htr_bytevec_list_with_limit
    (items_be_bytes : Bytes.t list) (* 각 원소는 길이 elem_size의 Bytes.t *)
    (limit_elems : int) (elem_size : int) : Bytes.t =
  (* 1) 원소 바이트들을 그대로 이어붙임 *)
  let total = List.length items_be_bytes * elem_size in
  let buf = Bytes.make total '\x00' in
  let off = ref 0 in
  List.iter
    (fun b ->
      if Bytes.length b <> elem_size then invalid_arg "elem_size mismatch";
      Bytes.blit b 0 buf !off elem_size;
      off := !off + elem_size)
    items_be_bytes;
  (* 2) 32B 청크화 → Merkleize *)
  let chunks = chunkize_bytes_bytev buf in
  (* 3) limit 기반 깊이 고정(가상 패딩) *)
  let need_chunks =
    let total_bytes = limit_elems * elem_size in
    if total_bytes = 0 then 0 else (total_bytes + 31) / 32
  in
  let root =
    if need_chunks = 0 then zero32
    else if Array.length chunks = 0 then
      let max_depth =
        if need_chunks <= 1 then 0 else bit_length_of (need_chunks - 1)
      in
      let zero_hashes = compute_zero_hashes ~max_depth in
      zero_hashes.(max_depth)
    else
      let h0 = merkleize_leaves chunks in
      let chunk_count = Array.length chunks in
      let depth =
        if chunk_count = 0 then 0 else bit_length_of (chunk_count - 1)
      in
      let max_depth =
        if need_chunks <= 1 then 0 else bit_length_of (need_chunks - 1)
      in
      let zero_hashes = compute_zero_hashes ~max_depth in
      let rec lift h d =
        if d >= max_depth then h
        else lift (merkle_hash_ h zero_hashes.(d)) (d + 1)
      in
      lift h0 depth
  in
  (* 4) 실제 길이 mix_in_length *)
  (* SSZ 규칙: 모든 List 타입은 mix_in_length에 요소 개수를 넣어야 함 *)
  let elem_len = List.length items_be_bytes in
  mix_in_length root (Bigint.of_int elem_len)

(* Bitlist with limit: 비트 패킹 → 청크 수를 limit 기반으로 보정 → mix_in_length *)
let htr_bitlist_with_limit (bits : bool list) (limit_bits : int) : Bytes.t =
  (* 실제 비트들을 LSB-first 바이트로 패킹 *)
  let bitlen = List.length bits in
  let byte_len = (bitlen + 7) / 8 in
  let arr = Bytes.make byte_len '\x00' in
  List.iteri
    (fun i b ->
      if b then
        let byte_idx = i / 8 in
        let bit_pos = i mod 8 in
        let old_byte = Stdlib.Char.code (Bytes.get arr byte_idx) in
        Bytes.set arr byte_idx (Stdlib.Char.chr (old_byte lor (1 lsl bit_pos))))
    bits;
  let chunks = chunkize_bytes_bytev arr in
  (* limit 기반 '필요 청크 수' *)
  let need_chunks = (limit_bits + 255) / 256 in
  let root =
    if need_chunks = 0 then zero32
    else if Array.length chunks = 0 then
      (* 빈 리스트: ZERO_HASHES[max_depth]에 해당. max_depth = (need_chunks-1).bit_length() *)
      let max_depth =
        if need_chunks <= 1 then 0 else bit_length_of (need_chunks - 1)
      in
      let zero_hashes = compute_zero_hashes ~max_depth in
      zero_hashes.(max_depth)
    else
      (* 실제 청크들을 merkleize 한 다음, limit 깊이까지 "끌어올림" (가상 패딩 효과) *)
      (* Python: depth = max(count-1, 0).bit_length(), max_depth = (limit-1).bit_length() *)
      let h0 = merkleize_leaves chunks in
      let chunk_count = Array.length chunks in
      let depth =
        if chunk_count = 0 then 0 else bit_length_of (chunk_count - 1)
      in
      let max_depth =
        if need_chunks <= 1 then 0 else bit_length_of (need_chunks - 1)
      in
      let zero_hashes = compute_zero_hashes ~max_depth in
      let rec lift h d =
        if d >= max_depth then h
        else lift (merkle_hash_ h zero_hashes.(d)) (d + 1)
      in
      lift h0 depth
  in
  mix_in_length root (Bigint.of_int bitlen)

let leaf_uint_le (n : Bigint.t) ~(nbytes : int) : Bytes.t =
  let c = Bytes.make 32 '\x00' in
  let v = ref n in
  for i = 0 to nbytes - 1 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set c i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
  c

let leaf_bytes32 (x : Bigint.t) : Bytes.t = be_of_bigint_fixed x ~len:32

let merkleize_vector_roots (leaves : Bytes.t array) : Bytes.t =
  merkleize_leaves leaves

let chunkize_bytevector_fixed (raw : Bytes.t) ~(len : int) : Bytes.t array =
  if Bytes.length raw <> len then
    invalid_arg "chunkize_bytevector_fixed: len mismatch";
  let k = (len + 31) / 32 in
  if k = 0 then [| Bytes.make 32 '\x00' |]
  else
    Array.init k (fun i ->
        let c = Bytes.make 32 '\x00' in
        let off = i * 32 in
        let remain = max 0 (len - off) in
        let to_copy = if remain >= 32 then 32 else remain in
        if to_copy > 0 then Bytes.blit raw off c 0 to_copy;
        c)

let to_raw_bytes_fixed ~(len : int) (n : Bigint.t) : Bytes.t =
  be_of_bigint_fixed n ~len

(* Strict conversion: Value.t (NumV n or BytesV) -> Bytes.t (32-byte leaf) *)
let to_b32_exn ~at (rv : Value.t) : (Bytes.t, Err.t) result =
  match rv.it with
  | NumV n -> Ok (leaf_bytes32 (Num.to_int n))
  | BytesV { num; len } ->
      (* BytesV: extract num and ensure it's 32 bytes *)
      if len <> 32 then
        Error (Err.runtime at "to_b32_exn: BytesV length must be 32")
      else Ok (leaf_bytes32 num)
  | _ -> Error (Err.runtime at "expected NumV or BytesV (32-byte root)")

(* dec $is_valid_merkle_branch(bytes32, bytes32*, uint64, uint64, root) : boolean *)
let is_valid_merkle_branch ~at (leaf : Num.t) (branch : Num.t list)
    (depth : Num.t) (index : Num.t) (root : Num.t) : (Value.t, Err.t) result =
  let leaf = Num.to_int leaf in
  let branch = List.map Num.to_int branch in
  let depth = Num.to_int depth in
  let index = Num.to_int index in
  let root = Num.to_int root in
  (* Validate inputs *)
  let* () = ensure_fits_bytes ~at leaf ~len:32 in
  let* () = ensure_fits_bytes ~at root ~len:32 in
  let* () = ensure_fits_bytes ~at depth ~len:8 in
  let* () = ensure_fits_bytes ~at index ~len:8 in
  let* () =
    let rec check_all = function
      | [] -> Ok ()
      | x :: xs ->
          let* () = ensure_fits_bytes ~at x ~len:32 in
          check_all xs
    in
    check_all branch
  in
  (* Convert depth to int for loop bounds *)
  let depth_int = try Bigint.to_int_exn depth with _ -> -1 in
  if depth_int < 0 then Error (Err.runtime at "depth too large")
  else if List.length branch < depth_int then
    Error (Err.runtime at "branch shorter than depth")
  else
    (* Loop *)
    let rec iter i (value : Bigint.t) : Bigint.t =
      if i >= depth_int then value
      else
        let sibling = List.nth branch i in
        (* parity = (index >> i) & 1 *)
        let bit_i = Bigint.(bit_and (shift_right index i) (of_int 1)) in
        let left, right =
          if Bigint.(bit_i = zero) then (* value || sibling *) (value, sibling)
          else (sibling, value)
        in
        let b_left = be_of_bigint_fixed left ~len:32 in
        let b_right = be_of_bigint_fixed right ~len:32 in
        let cat = Bytes.create 64 in
        Bytes.blit b_left 0 cat 0 32;
        Bytes.blit b_right 0 cat 32 32;
        let value' = sha256_bytes32 cat in
        iter (i + 1) value'
    in
    let computed = iter 0 leaf in
    Ok (Value.bool Bigint.(computed = root))

(* ----- hash_tree_root_roots(root Vector) : root ----- *)
(* Vector[Root, N] 타입을 처리: Vector는 mix_in_length를 적용하지 않음 *)
(* hash_tree_root_beaconState에서 사용하는 htr_bytes32_vector와 동일한 로직 사용 *)
let hash_tree_root_roots ~at (lst : Num.t list) : (Value.t, Err.t) result =
  let lst = List.map Num.to_int lst in
  at |> ignore;
  (* Num.t list -> Bytes.t list 변환 (각 root를 32B로 변환) *)
  let roots_bytes = List.map (fun n -> be_of_bigint_fixed n ~len:32) lst in
  (* htr_bytes32_vector 사용: Vector는 mix_in_length 없이 merkleize_leaves만 적용 *)
  let root = htr_bytes32_vector roots_bytes in
  Ok (make_bytes ~num:(bigint_of_be_bytes root) ~len:32)

(* ----- hash_tree_root_tx(transactions list) : root ----- *)
(* transactions: List[Transaction, MAX_TRANSACTIONS_PER_PAYLOAD] = List[ByteList, 1048576] *)
(* SSZ 규칙: 최대 길이 N까지 zero-chunk 패딩 후 merkleize, 그 다음 mix_in_length *)
let hash_tree_root_tx ~at (txs_list : Value.t list) : (Value.t, Err.t) result =
  at |> ignore;
  (* get_list_bytes: Value.t (ListV of bytes) -> Bytes.t *)
  let get_list_bytes v =
    match v.it with
    | ListV lst ->
        let get_nat v = v |> Value.get_num |> Num.to_int in
        let bytes_list = List.map get_nat lst in
        let buf = Buffer.create (List.length bytes_list) in
        List.iter
          (fun n ->
            if Bigint.(n < zero || n >= of_int 256) then
              invalid_arg
                (Printf.sprintf "hash_tree_root_tx: byte out of range: %s"
                   (Bigint.to_string n))
            else Buffer.add_char buf (Stdlib.Char.chr (Bigint.to_int_exn n)))
          bytes_list;
        Bytes.of_string (Buffer.contents buf)
    | BytesV { num; len } ->
        (* BytesV: num을 len 바이트로 변환 (Big-endian) *)
        be_of_bigint_fixed num ~len
    | _ -> Bytes.make 0 '\x00'
  in
  (* 각 transaction (ByteList)의 root 계산 *)
  (* ByteList의 경우: subtree_fill_to_contents(chunks, contents_depth)를 사용 *)
  (* contents_depth = get_depth(MAX_BYTES_PER_TRANSACTION // 32) = get_depth(33554432) = 25 *)
  (* 따라서 limit = 33554432를 사용해야 함 *)
  let tx_elem_root tx =
    let data_bytes = get_list_bytes tx in
    let len = Bytes.length data_bytes in
    let chunks = chunkize_bytes_bytev data_bytes in
    (* ByteList의 경우 limit = MAX_BYTES_PER_TRANSACTION // 32 = 33554432 *)
    let tx_bytes_limit = 33554432 in
    (* MAX_BYTES_PER_TRANSACTION // 32 *)
    let root = merkleize_chunks_with_limit chunks tx_bytes_limit in
    mix_in_length root (Bigint.of_int len)
  in
  (* 모든 transaction root를 계산 *)
  let tx_roots = List.map tx_elem_root txs_list |> Array.of_list in
  (* SSZ 규칙: MAX_TRANSACTIONS_PER_PAYLOAD (1048576)까지 zero32로 패딩 후 merkleize *)
  let tx_limit = 1048576 in
  (* MAX_TRANSACTIONS_PER_PAYLOAD *)
  let root_tx_vec = merkleize_list_composite_with_limit tx_roots tx_limit in
  (* 실제 리스트 길이로 mix_in_length *)
  let out = mix_in_length root_tx_vec (Bigint.of_int (Array.length tx_roots)) in
  Ok (make_bytes ~num:(bigint_of_be_bytes out) ~len:32)

(* ----- hash_tree_root_beaconBlockHeader(beaconBlockHeader) : root ----- *)
let hash_tree_root_beaconBlockHeader ~at (hdr : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* slot, proposer_index, parent_root, state_root, body_root =
    match hdr.it with
    | StructV
        [
          (_, slot_v); (_, proposer_v); (_, parent_v); (_, state_v); (_, body_v);
        ] ->
        Ok
          ( get_nat slot_v,
            get_nat proposer_v,
            get_nat parent_v,
            get_nat state_v,
            get_nat body_v )
    | TupleV [ slot_v; proposer_v; parent_v; state_v; body_v ] ->
        Ok
          ( get_nat slot_v,
            get_nat proposer_v,
            get_nat parent_v,
            get_nat state_v,
            get_nat body_v )
    | ListV [ slot_v; proposer_v; parent_v; state_v; body_v ] ->
        Ok
          ( get_nat slot_v,
            get_nat proposer_v,
            get_nat parent_v,
            get_nat state_v,
            get_nat body_v )
    | _ -> Error (Err.runtime at "beaconBlockHeader: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at slot ~len:8 in
  let* () = ensure_fits_bytes ~at proposer_index ~len:8 in
  let* () = ensure_fits_bytes ~at parent_root ~len:32 in
  let* () = ensure_fits_bytes ~at state_root ~len:32 in
  let* () = ensure_fits_bytes ~at body_root ~len:32 in
  let leaves =
    [|
      leaf_uint_le slot ~nbytes:8;
      leaf_uint_le proposer_index ~nbytes:8;
      leaf_bytes32 parent_root;
      leaf_bytes32 state_root;
      leaf_bytes32 body_root;
    |]
  in
  let root_bytes = merkleize_vector_roots leaves in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_depositData(depositData) : root ----- *)
let hash_tree_root_depositData ~at (dd : Value.t) : (Value.t, Err.t) result =
  let get_num v = v |> Value.get_num |> Num.to_int in
  let* pubkey_b48, wcred_b32, amount_u64, sig_b96 =
    match dd.it with
    | StructV [ (_, v_pub); (_, v_wcr); (_, v_amt); (_, v_sig) ] ->
        Ok (get_num v_pub, get_num v_wcr, get_num v_amt, get_num v_sig)
    | TupleV [ v_pub; v_wcr; v_amt; v_sig ] ->
        Ok (get_num v_pub, get_num v_wcr, get_num v_amt, get_num v_sig)
    | ListV [ v_pub; v_wcr; v_amt; v_sig ] ->
        Ok (get_num v_pub, get_num v_wcr, get_num v_amt, get_num v_sig)
    | _ -> Error (Err.runtime at "depositData: unexpected value shape")
  in
  (* range checks *)
  let* () = ensure_fits_bytes ~at pubkey_b48 ~len:48 in
  let* () = ensure_fits_bytes ~at wcred_b32 ~len:32 in
  let* () = ensure_fits_bytes ~at amount_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at sig_b96 ~len:96 in
  (* field roots *)
  let pubkey_raw = to_raw_bytes_fixed ~len:48 pubkey_b48 in
  let pubkey_leafs = chunkize_bytevector_fixed pubkey_raw ~len:48 in
  let r_pubkey = merkleize_leaves pubkey_leafs in

  let r_wcred = leaf_bytes32 wcred_b32 in
  let r_amount = leaf_uint_le amount_u64 ~nbytes:8 in

  let sig_raw = to_raw_bytes_fixed ~len:96 sig_b96 in
  let sig_leafs = chunkize_bytevector_fixed sig_raw ~len:96 in
  let r_sig = merkleize_leaves sig_leafs in

  let field_roots = [| r_pubkey; r_wcred; r_amount; r_sig |] in
  let root_bytes = merkleize_vector_roots field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_forkdata(forkdata) : root ----- *)
let hash_tree_root_forkdata ~at (fd : Value.t) : (Value.t, Err.t) result =
  let get_num v = v |> Value.get_num |> Num.to_int in
  let* version_b4, gvr_b32 =
    match fd.it with
    | StructV [ (_, v_ver); (_, v_gvr) ] -> Ok (get_num v_ver, get_num v_gvr)
    | TupleV [ v_ver; v_gvr ] -> Ok (get_num v_ver, get_num v_gvr)
    | ListV [ v_ver; v_gvr ] -> Ok (get_num v_ver, get_num v_gvr)
    | _ -> Error (Err.runtime at "forkdata: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at version_b4 ~len:4 in
  let* () = ensure_fits_bytes ~at gvr_b32 ~len:32 in
  (* version: 4B ByteVector → 32B 단일 청크 *)
  let version_raw = be_of_bigint_fixed version_b4 ~len:4 in
  let version_leafs = chunkize_bytevector_fixed version_raw ~len:4 in
  let r_version = merkleize_leaves version_leafs in
  (* genesis_validators_root: bytes32 → 단일 리프 *)
  let r_gvr = leaf_bytes32 gvr_b32 in
  let field_roots = [| r_version; r_gvr |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- Withdrawal container → 32B root ----- *)
(* can not find better naming... *)
let htr_withdrawal_container ~at (w : Value.t) : (Bytes.t, Err.t) result =
  let get_num v = v |> Value.get_num |> Num.to_int in
  let* index_u64, validator_index_u64, address_b20, amount_u64 =
    match w.it with
    | StructV
        [ (_, v_index); (_, v_validator_index); (_, v_address); (_, v_amount) ]
      ->
        Ok
          ( get_num v_index,
            get_num v_validator_index,
            get_num v_address,
            get_num v_amount )
    | TupleV [ v_index; v_validator_index; v_address; v_amount ] ->
        Ok
          ( get_num v_index,
            get_num v_validator_index,
            get_num v_address,
            get_num v_amount )
    | ListV [ v_index; v_validator_index; v_address; v_amount ] ->
        Ok
          ( get_num v_index,
            get_num v_validator_index,
            get_num v_address,
            get_num v_amount )
    | _ -> Error (Err.runtime at "withdrawal: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at index_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at validator_index_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at address_b20 ~len:20 in
  let* () = ensure_fits_bytes ~at amount_u64 ~len:8 in
  let r_index = leaf_uint_le index_u64 ~nbytes:8 in
  let r_validator = leaf_uint_le validator_index_u64 ~nbytes:8 in
  let addr_raw = be_of_bigint_fixed address_b20 ~len:20 in
  let addr_leafs = chunkize_bytevector_fixed addr_raw ~len:20 in
  let r_address = merkleize_leaves addr_leafs in
  let r_amount = leaf_uint_le amount_u64 ~nbytes:8 in
  let leaves = [| r_index; r_validator; r_address; r_amount |] in
  let root_bytes = merkleize_vector_roots leaves in
  Ok root_bytes

(* (* ----- hash_tree_root_withdrawals(withdrawal*) : root ----- *)
(* withdrawals: List[Withdrawal, MAX_WITHDRAWALS_PER_PAYLOAD] = List[Withdrawal, 16] *)
(* SSZ 규칙: 최대 길이 N까지 zero-chunk 패딩 후 merkleize, 그 다음 mix_in_length *)
let hash_tree_root_withdrawals ~at (ws : Value.t list) : (Value.t, Err.t) result
    =
  let rec mapM f = function
    | [] -> Ok []
    | x :: xs ->
        let* y = f x in
        let* ys = mapM f xs in
        Ok (y :: ys)
  in
  let* leaves_list = mapM (htr_withdrawal_container ~at) ws in
  let leaves = Array.of_list leaves_list in
  (* SSZ 규칙: MAX_WITHDRAWALS_PER_PAYLOAD (16)까지 zero32로 패딩 후 merkleize *)
  let wd_limit = 16 in
  (* MAX_WITHDRAWALS_PER_PAYLOAD *)
  let root_vec = merkleize_list_composite_with_limit leaves wd_limit in
  (* 실제 리스트 길이로 mix_in_length *)
  let root_final =
    mix_in_length root_vec (Bigint.of_int (Array.length leaves))
  in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_final) ~len:32)

(* ----- hash_tree_root_eth1Data(eth1Data) : root ----- *)
let hash_tree_root_eth1Data ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let* deposit_root_b32, deposit_count_u64, block_hash_b32 =
    match v.it with
    | StructV [ (_, v_dr); (_, v_dc); (_, v_bh) ]
    | TupleV [ v_dr; v_dc; v_bh ]
    | ListV [ v_dr; v_dc; v_bh ] ->
        Ok (get_nat v_dr, get_nat v_dc, get_nat v_bh)
    | _ -> Error (Err.runtime at "eth1Data: unexpected shape")
  in
  let* () = ensure_fits_bytes ~at deposit_root_b32 ~len:32 in
  let* () = ensure_fits_bytes ~at deposit_count_u64 ~len:8 in
  let* () = ensure_fits_bytes ~at block_hash_b32 ~len:32 in
  let r_deposit_root = leaf_bytes32 deposit_root_b32 in
  let r_deposit_count = leaf_uint_le deposit_count_u64 ~nbytes:8 in
  let r_block_hash = leaf_bytes32 block_hash_b32 in
  let field_roots = [| r_deposit_root; r_deposit_count; r_block_hash |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_executionPayload(executionPayload) : root ----- *)
let hash_tree_root_executionPayload ~at (v : Value.t) : (Value.t, Err.t) result
    =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  (* Detect fork by field count: 15 fields = Capella, 17 fields = Deneb *)
  let* ( parent_hash,
         fee_recipient,
         state_root,
         receipts_root,
         logs_bloom,
         prev_randao,
         block_number,
         gas_limit,
         gas_used,
         timestamp,
         extra_data,
         base_fee_per_gas,
         block_hash,
         transactions,
         withdrawals,
         blob_gas_used,
         excess_blob_gas ) =
    match v.it with
    | StructV fields ->
        let count = List.length fields in
        if count = 15 then
          (match fields with
          | [ (_, v1); (_, v2); (_, v3); (_, v4); (_, v5); (_, v6); (_, v7);
              (_, v8); (_, v9); (_, v10); (_, v11); (_, v12); (_, v13);
              (_, v14); (_, v15) ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, None, None)
          | _ -> Error (Err.runtime at "executionPayload: unexpected field count"))
        else if count = 17 then
          (match fields with
          | [ (_, v1); (_, v2); (_, v3); (_, v4); (_, v5); (_, v6); (_, v7);
              (_, v8); (_, v9); (_, v10); (_, v11); (_, v12); (_, v13);
              (_, v14); (_, v15); (_, v16); (_, v17) ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, Some v16, Some v17)
          | _ -> Error (Err.runtime at "executionPayload: unexpected field count"))
        else
          Error (Err.runtime at "executionPayload: unexpected field count")
    | TupleV fields ->
        let count = List.length fields in
        if count = 15 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, None, None)
          | _ -> Error (Err.runtime at "executionPayload: unexpected field count"))
        else if count = 17 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15; v16; v17 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, Some v16, Some v17)
          | _ -> Error (Err.runtime at "executionPayload: unexpected field count"))
        else
          Error (Err.runtime at "executionPayload: unexpected field count")
    | ListV fields ->
        let count = List.length fields in
        if count = 15 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, None, None)
          | _ -> Error (Err.runtime at "executionPayload: unexpected field count"))
        else if count = 17 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15; v16; v17 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, Some v16, Some v17)
          | _ -> Error (Err.runtime at "executionPayload: unexpected field count"))
        else
          Error (Err.runtime at "executionPayload: unexpected field count")
    | _ -> Error (Err.runtime at "executionPayload: unexpected value shape")
  in
  (* 1. parent_hash: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat parent_hash) ~len:32 in
  let r_parent_hash = leaf_bytes32 (get_nat parent_hash) in
  (* 2. fee_recipient (ExecutionAddress): ByteVector[20] *)
  let* () = ensure_fits_bytes ~at (get_nat fee_recipient) ~len:20 in
  let fr_bytes = be_of_bigint_fixed (get_nat fee_recipient) ~len:20 in
  let r_fee_recipient =
    chunkize_bytevector_fixed fr_bytes ~len:20 |> merkleize_leaves
  in
  (* 3. state_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat state_root) ~len:32 in
  let r_state_root = leaf_bytes32 (get_nat state_root) in
  (* 4. receipts_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat receipts_root) ~len:32 in
  let r_receipts_root = leaf_bytes32 (get_nat receipts_root) in
  (* 5. logs_bloom: ByteVector[256] *)
  let* () = ensure_fits_bytes ~at (get_nat logs_bloom) ~len:256 in
  let lb_bytes = be_of_bigint_fixed (get_nat logs_bloom) ~len:256 in
  let r_logs_bloom =
    chunkize_bytevector_fixed lb_bytes ~len:256 |> merkleize_leaves
  in
  (* 6. prev_randao: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat prev_randao) ~len:32 in
  let r_prev_randao = leaf_bytes32 (get_nat prev_randao) in
  (* 7. block_number: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat block_number) ~len:8 in
  let r_block_number = leaf_uint_le (get_nat block_number) ~nbytes:8 in
  (* 8. gas_limit: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat gas_limit) ~len:8 in
  let r_gas_limit = leaf_uint_le (get_nat gas_limit) ~nbytes:8 in
  (* 9. gas_used: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat gas_used) ~len:8 in
  let r_gas_used = leaf_uint_le (get_nat gas_used) ~nbytes:8 in
  (* 10. timestamp: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat timestamp) ~len:8 in
  let r_timestamp = leaf_uint_le (get_nat timestamp) ~nbytes:8 in
  (* 11. extra_data: ByteList[<=32], mix_in_length 적용 *)
  (* extra_data는 ListV 형태 (각 요소는 uint8) 또는 BytesV 형태 *)
  let get_list_bytes v =
    match v.it with
    | ListV lst ->
        let get_nat v = v |> Value.get_num |> Num.to_int in
        let bytes_list = List.map get_nat lst in
        let buf = Buffer.create (List.length bytes_list) in
        List.iter
          (fun n ->
            (* 범위를 벗어난 바이트는 무시하지 않고 예외를 발생시켜야 함 *)
            if Bigint.(n < zero || n >= of_int 256) then
              invalid_arg
                (Printf.sprintf "get_list_bytes: byte out of range: %s"
                   (Bigint.to_string n))
            else Buffer.add_char buf (Stdlib.Char.chr (Bigint.to_int_exn n)))
          bytes_list;
        Bytes.of_string (Buffer.contents buf)
    | BytesV { num; len } ->
        (* BytesV: num을 len 바이트로 변환 (Big-endian) *)
        be_of_bigint_fixed num ~len
    | _ -> Bytes.make 0 '\x00'
  in
  let extra_bytes = get_list_bytes extra_data in
  let extra_len = Bytes.length extra_bytes in
  (* Printf.printf "[DEBUG exec extra_data] raw bytes (hex): %s\n%!" (bytes_to_hex extra_bytes); *)
  (* Printf.printf "[DEBUG exec extra_data] length: %d bytes\n%!" extra_len; *)
  let extra_leaves = chunkize_bytes_bytev extra_bytes in
  (* Printf.printf "[DEBUG exec extra_data] chunk count: %d\n%!" (Array.length extra_leaves); *)
  (* if Array.length extra_leaves > 0 then *)
  (*   Printf.printf "[DEBUG exec extra_data] first chunk (hex): %s\n%!" (bytes_to_hex extra_leaves.(0)); *)
  let extra_root = merkleize_leaves extra_leaves in
  (* Printf.printf "[DEBUG exec extra_data] merkle root (before mix_in_length): %s\n%!" (bytes_to_hex extra_root); *)
  let r_extra_data = mix_in_length extra_root (Bigint.of_int extra_len) in
  (* Printf.printf "[DEBUG exec extra_data] final root (after mix_in_length): %s\n%!" (bytes_to_hex r_extra_data); *)
  (* 12. base_fee_per_gas: uint256, 32B LE *)
  let* () = ensure_fits_bytes ~at (get_nat base_fee_per_gas) ~len:32 in
  let r_base_fee = leaf_uint_le (get_nat base_fee_per_gas) ~nbytes:32 in
  (* 13. block_hash: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat block_hash) ~len:32 in
  let r_block_hash = leaf_bytes32 (get_nat block_hash) in
  (* 14. transactions: ListV ByteList, tx별로 mix_in_length → 모아서 merkleize → 전체 거래 개수로 mix_in_length *)
  let get_list v = match v.it with ListV xs -> xs | _ -> [] in
  let get_list_bytes v =
    match v.it with
    | ListV lst ->
        let get_nat v = v |> Value.get_num |> Num.to_int in
        let bytes_list = List.map get_nat lst in
        let buf = Buffer.create (List.length bytes_list) in
        List.iter
          (fun n ->
            (* 범위를 벗어난 바이트는 무시하지 않고 예외를 발생시켜야 함 *)
            if Bigint.(n < zero || n >= of_int 256) then
              invalid_arg
                (Printf.sprintf "get_list_bytes: byte out of range: %s"
                   (Bigint.to_string n))
            else Buffer.add_char buf (Stdlib.Char.chr (Bigint.to_int_exn n)))
          bytes_list;
        Bytes.of_string (Buffer.contents buf)
    | BytesV { num; len } ->
        (* BytesV: num을 len 바이트로 변환 (Big-endian) *)
        be_of_bigint_fixed num ~len
    | _ -> Bytes.make 0 '\x00'
  in
  let txs = get_list transactions in
  (* Printf.printf "[DEBUG exec transactions] transaction count: %d\n%!" (List.length txs); *)
  (* 단일 Transaction(ByteList)의 HTR: chunkize → merkleize → mix_in_length(바이트 길이) *)
  (* ByteList의 경우: subtree_fill_to_contents(chunks, contents_depth)를 사용 *)
  (* contents_depth = get_depth(MAX_BYTES_PER_TRANSACTION // 32) = get_depth(33554432) = 25 *)
  (* 따라서 limit = 33554432를 사용해야 함 *)
  let tx_elem_root tx =
    let data_bytes = get_list_bytes tx in
    let len = Bytes.length data_bytes in
    let chunks = chunkize_bytes_bytev data_bytes in
    (* ByteList의 경우 limit = MAX_BYTES_PER_TRANSACTION // 32 = 33554432 *)
    let tx_bytes_limit = 33554432 in
    (* MAX_BYTES_PER_TRANSACTION // 32 *)
    let root = merkleize_chunks_with_limit chunks tx_bytes_limit in
    mix_in_length root (Bigint.of_int len)
  in
  (* tx_roots: 각 Transaction(ByteList)의 HTR (Bytes.t, 32B) *)
  (* 각 tx에 대해 단일 Transaction HTR을 먼저 구함 *)
  let tx_roots = List.map tx_elem_root txs |> Array.of_list in
  (* if Array.length tx_roots > 0 then ( *)
  (*   Printf.printf "[DEBUG exec transactions] first tx root: %s\n%!" (bytes_to_hex tx_roots.(0)); *)
  (*   Printf.printf "[DEBUG exec transactions] last tx root: %s\n%!" (bytes_to_hex tx_roots.(Array.length tx_roots - 1)); *)
  (* ); *)
  (* SSZ 규칙: MAX_TRANSACTIONS_PER_PAYLOAD (1048576)까지 zero32로 패딩 후 merkleize *)
  let tx_limit = 1048576 in
  (* MAX_TRANSACTIONS_PER_PAYLOAD *)
  let root_tx_vec = merkleize_list_composite_with_limit tx_roots tx_limit in
  (* Printf.printf "[DEBUG exec transactions] merkle root (before mix_in_length): %s\n%!" (bytes_to_hex root_tx_vec); *)
  (* Printf.printf "[DEBUG exec transactions] tx count for mix_in_length: %d\n%!" (Array.length tx_roots); *)
  (* 실제 리스트 길이로 mix_in_length *)
  let r_transactions =
    mix_in_length root_tx_vec (Bigint.of_int (Array.length tx_roots))
  in
  (* Printf.printf "[DEBUG exec transactions] final root (after mix_in_length): %s\n%!" (bytes_to_hex r_transactions); *)
  (* 15. withdrawals: hash_tree_root_withdrawals에 위임 *)
  let ws = get_list withdrawals in
  let* r_withdrawals_v = hash_tree_root_withdrawals ~at ws in
  let* r_withdrawals = to_b32_exn ~at r_withdrawals_v in
  (* Deneb fields (16-17): blob_gas_used, excess_blob_gas *)
  let* (r_blob_gas_used, r_excess_blob_gas) =
    match (blob_gas_used, excess_blob_gas) with
    | Some bg, Some eb ->
        (* 16. blob_gas_used: uint64 *)
        let* () = ensure_fits_bytes ~at (get_nat bg) ~len:8 in
        let r_bg = leaf_uint_le (get_nat bg) ~nbytes:8 in
        (* 17. excess_blob_gas: uint64 *)
        let* () = ensure_fits_bytes ~at (get_nat eb) ~len:8 in
        let r_eb = leaf_uint_le (get_nat eb) ~nbytes:8 in
        Ok (r_bg, r_eb)
    | None, None -> Ok (zero32, zero32)
    | _ -> Error (Err.runtime at "executionPayload: inconsistent Deneb fields")
  in
  (* 정해진 순서로 배열 *)
  let field_roots =
    match (blob_gas_used, excess_blob_gas) with
    | None, None ->
        (* Capella: 15 fields *)
        [|
          r_parent_hash;
          r_fee_recipient;
          r_state_root;
          r_receipts_root;
          r_logs_bloom;
          r_prev_randao;
          r_block_number;
          r_gas_limit;
          r_gas_used;
          r_timestamp;
          r_extra_data;
          r_base_fee;
          r_block_hash;
          r_transactions;
          r_withdrawals;
        |]
    | Some _, Some _ ->
        (* Deneb: 17 fields *)
        [|
          r_parent_hash;
          r_fee_recipient;
          r_state_root;
          r_receipts_root;
          r_logs_bloom;
          r_prev_randao;
          r_block_number;
          r_gas_limit;
          r_gas_used;
          r_timestamp;
          r_extra_data;
          r_base_fee;
          r_block_hash;
          r_transactions;
          r_withdrawals;
          r_blob_gas_used;
          r_excess_blob_gas;
        |]
    | _ -> assert false
  in
  let root_bytes = merkleize_leaves field_roots in
  (* Printf.printf "[DEBUG exec] FINAL EXECUTION_PAYLOAD_ROOT: %s\n%!" (bytes_to_hex root_bytes); *)
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_BLSToExecutionChange(message) : root ----- *)
let hash_tree_root_BLSToExecutionChange ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_index); (_, v_pubkey); (_, v_addr) ]
    | TupleV [ v_index; v_pubkey; v_addr ]
    | ListV [ v_index; v_pubkey; v_addr ] ->
        Ok (v_index, v_pubkey, v_addr)
    | _ -> Error (Err.runtime at "BLSToExecutionChange: unexpected value shape")
  in
  let validator_index, from_bls_pubkey, to_execution_address = temp in
  let* () = ensure_fits_bytes ~at (get_nat validator_index) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat from_bls_pubkey) ~len:48 in
  let* () = ensure_fits_bytes ~at (get_nat to_execution_address) ~len:20 in
  let r_index = leaf_uint_le (get_nat validator_index) ~nbytes:8 in
  let pubkey_bytes = be_of_bigint_fixed (get_nat from_bls_pubkey) ~len:48 in
  let r_pubkey =
    chunkize_bytevector_fixed pubkey_bytes ~len:48 |> merkleize_leaves
  in
  let addr_bytes = be_of_bigint_fixed (get_nat to_execution_address) ~len:20 in
  let r_addr =
    chunkize_bytevector_fixed addr_bytes ~len:20 |> merkleize_leaves
  in
  let field_roots = [| r_index; r_pubkey; r_addr |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_SignedBLSToExecutionChange(signed) : root ----- *)
let hash_tree_root_SignedBLSToExecutionChange ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_msg); (_, v_sig) ]
    | TupleV [ v_msg; v_sig ]
    | ListV [ v_msg; v_sig ] ->
        Ok (v_msg, v_sig)
    | _ ->
        Error
          (Err.runtime at "SignedBLSToExecutionChange: unexpected value shape")
  in
  let message, signature = temp in
  (* message: BLSToExecutionChange *)
  let* msg_root_v = hash_tree_root_BLSToExecutionChange ~at message in
  let* msg_root = to_b32_exn ~at msg_root_v in
  (* signature: BLSSignature(96) → ByteVector[96] *)
  let* () = ensure_fits_bytes ~at (get_nat signature) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat signature) ~len:96 in
  let sig_root =
    chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves
  in
  let field_roots = [| msg_root; sig_root |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

let pack_bits_lsb_first (lst : Value.t list) : Bytes.t =
  let arr = Array.make 64 0 in
  let get_bool v = Value.get_bool v in
  List.iteri
    (fun i b ->
      if get_bool b then arr.(i / 8) <- arr.(i / 8) lor (1 lsl (i mod 8))
      else ())
    lst;
  Bytes.init 64 (fun i -> Stdlib.Char.chr arr.(i))

(* ----- hash_tree_root_SyncAggregate(syncAggregate) : root ----- *)
let hash_tree_root_SyncAggregate ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_bits); (_, v_sig) ]
    | TupleV [ v_bits; v_sig ]
    | ListV [ v_bits; v_sig ] ->
        Ok (v_bits, v_sig)
    | _ -> Error (Err.runtime at "SyncAggregate: unexpected value shape")
  in
  let v_bits, v_sig = temp in
  (* bits: Bitvector[512] 패킹 *)
  let bits_bytes =
    match v_bits.it with
    | ListV lst when List.length lst = 512 -> pack_bits_lsb_first lst
    | _ -> Bytes.make 64 '\x00'
  in
  let r_bits =
    chunkize_bytevector_fixed bits_bytes ~len:64 |> merkleize_leaves
  in
  (* signature: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat v_sig) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat v_sig) ~len:96 in
  let r_sig = chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves in
  let field_roots = [| r_bits; r_sig |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_VoluntaryExit(voluntaryExit) : root ----- *)
let hash_tree_root_VoluntaryExit ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_epoch); (_, v_validator) ]
    | TupleV [ v_epoch; v_validator ]
    | ListV [ v_epoch; v_validator ] ->
        Ok (v_epoch, v_validator)
    | _ -> Error (Err.runtime at "VoluntaryExit: unexpected value shape")
  in
  let epoch, validator_index = temp in
  let* () = ensure_fits_bytes ~at (get_nat epoch) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat validator_index) ~len:8 in
  let r_epoch = leaf_uint_le (get_nat epoch) ~nbytes:8 in
  let r_validator = leaf_uint_le (get_nat validator_index) ~nbytes:8 in
  let field_roots = [| r_epoch; r_validator |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_SignedVoluntaryExit(signed) : root ----- *)
let hash_tree_root_SignedVoluntaryExit ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_msg); (_, v_sig) ]
    | TupleV [ v_msg; v_sig ]
    | ListV [ v_msg; v_sig ] ->
        Ok (v_msg, v_sig)
    | _ -> Error (Err.runtime at "SignedVoluntaryExit: unexpected value shape")
  in
  let message, signature = temp in
  (* message: VoluntaryExit *)
  let* msg_root_v = hash_tree_root_VoluntaryExit ~at message in
  let* msg_root = to_b32_exn ~at msg_root_v in
  (* signature: BLSSignature(96) → ByteVector[96] *)
  let* () = ensure_fits_bytes ~at (get_nat signature) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat signature) ~len:96 in
  let sig_root =
    chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves
  in
  let field_roots = [| msg_root; sig_root |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_Deposit(deposit) : root ----- *)
let hash_tree_root_Deposit ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let get_list v = match v.it with ListV xs -> xs | _ -> [] in
  let* temp =
    match v.it with
    | StructV [ (_, v_proof); (_, v_data) ]
    | TupleV [ v_proof; v_data ]
    | ListV [ v_proof; v_data ] ->
        Ok (v_proof, v_data)
    | _ -> Error (Err.runtime at "Deposit: unexpected value shape")
  in
  let proof_v, data_v = temp in
  (* 1. proof: Vector[Bytes32, N+1] *)
  let proof_list = get_list proof_v in
  let leaves =
    proof_list |> List.map (fun x -> leaf_bytes32 (get_nat x)) |> Array.of_list
  in
  let r_proof = merkleize_leaves leaves in
  (* 2. data: DepositData *)
  let* r_data_v = hash_tree_root_depositData ~at data_v in
  let* r_data = to_b32_exn ~at r_data_v in
  let field_roots = [| r_proof; r_data |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_Checkpoint(checkpoint) : root ----- *)
let hash_tree_root_Checkpoint ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_epoch); (_, v_root) ]
    | TupleV [ v_epoch; v_root ]
    | ListV [ v_epoch; v_root ] ->
        Ok (v_epoch, v_root)
    | _ -> Error (Err.runtime at "Checkpoint: unexpected value shape")
  in
  let epoch, root = temp in
  let* () = ensure_fits_bytes ~at (get_nat epoch) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat root) ~len:32 in
  let r_epoch = leaf_uint_le (get_nat epoch) ~nbytes:8 in
  let r_root = leaf_bytes32 (get_nat root) in
  let field_roots = [| r_epoch; r_root |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_AttestationData(ad) : root ----- *)
let hash_tree_root_AttestationData ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV
        [ (_, v_slot); (_, v_index); (_, v_bbr); (_, v_source); (_, v_target) ]
    | TupleV [ v_slot; v_index; v_bbr; v_source; v_target ]
    | ListV [ v_slot; v_index; v_bbr; v_source; v_target ] ->
        Ok (v_slot, v_index, v_bbr, v_source, v_target)
    | _ -> Error (Err.runtime at "AttestationData: unexpected value shape")
  in
  let slot, index, beacon_block_root, source, target = temp in
  let* () = ensure_fits_bytes ~at (get_nat slot) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat index) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat beacon_block_root) ~len:32 in
  let r_slot = leaf_uint_le (get_nat slot) ~nbytes:8 in
  let r_index = leaf_uint_le (get_nat index) ~nbytes:8 in
  let r_bbr = leaf_bytes32 (get_nat beacon_block_root) in
  let* r_source_v = hash_tree_root_Checkpoint ~at source in
  let* r_source = to_b32_exn ~at r_source_v in
  let* r_target_v = hash_tree_root_Checkpoint ~at target in
  let* r_target = to_b32_exn ~at r_target_v in
  let field_roots = [| r_slot; r_index; r_bbr; r_source; r_target |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_Attestation(attestation) : root ----- *)
let hash_tree_root_Attestation ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_bits); (_, v_data); (_, v_sig) ]
    | TupleV [ v_bits; v_data; v_sig ]
    | ListV [ v_bits; v_data; v_sig ] ->
        Ok (v_bits, v_data, v_sig)
    | _ -> Error (Err.runtime at "Attestation: unexpected value shape")
  in
  let v_bits, v_data, v_sig = temp in
  (* aggregation_bits: Bitlist[MAX_VALIDATORS_PER_COMMITTEE] -> limit 기반 가상 패딩 + mix_in_length *)
  let bits_list =
    match v_bits.it with ListV lst -> List.map Value.get_bool lst | _ -> []
  in
  let max_validators_per_committee = 2048 in
  (* MAX_VALIDATORS_PER_COMMITTEE *)
  let r_bits = htr_bitlist_with_limit bits_list max_validators_per_committee in
  (* data: AttestationData *)
  let* r_data_v = hash_tree_root_AttestationData ~at v_data in
  let* r_data = to_b32_exn ~at r_data_v in
  (* signature: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat v_sig) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat v_sig) ~len:96 in
  let r_sig = chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves in
  let field_roots = [| r_bits; r_data; r_sig |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_IndexedAttestation(indexedAttestation) : root ----- *)
let hash_tree_root_IndexedAttestation ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let get_list v = match v.it with ListV xs -> xs | _ -> [] in
  let* temp =
    match v.it with
    | StructV [ (_, v_indices); (_, v_data); (_, v_sig) ]
    | TupleV [ v_indices; v_data; v_sig ]
    | ListV [ v_indices; v_data; v_sig ] ->
        Ok (v_indices, v_data, v_sig)
    | _ -> Error (Err.runtime at "IndexedAttestation: unexpected value shape")
  in
  let v_indices, v_data, v_sig = temp in
  (* indices: List[uint64, MAX_VALIDATORS_PER_COMMITTEE] -> 연속 패킹 + limit 기반 가상 패딩 + mix_in_length *)
  let indices = get_list v_indices in
  let items = indices |> List.map (fun idx -> (get_nat idx, 8)) in
  let max_validators_per_committee = 2048 in
  (* MAX_VALIDATORS_PER_COMMITTEE *)
  let r_indices =
    htr_basic_list_with_limit items max_validators_per_committee 8
  in
  (* data: AttestationData *)
  let* r_data_v = hash_tree_root_AttestationData ~at v_data in
  let* r_data = to_b32_exn ~at r_data_v in
  (* signature: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat v_sig) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat v_sig) ~len:96 in
  let r_sig = chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves in
  let field_roots = [| r_indices; r_data; r_sig |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_AttesterSlashing(attesterSlashing) : root ----- *)
let hash_tree_root_AttesterSlashing ~at (v : Value.t) : (Value.t, Err.t) result
    =
  let* temp =
    match v.it with
    | StructV [ (_, a1); (_, a2) ] | TupleV [ a1; a2 ] | ListV [ a1; a2 ] ->
        Ok (a1, a2)
    | _ -> Error (Err.runtime at "AttesterSlashing: unexpected value shape")
  in
  let attestation_1, attestation_2 = temp in
  let* r_a1_v = hash_tree_root_IndexedAttestation ~at attestation_1 in
  let* r_a1 = to_b32_exn ~at r_a1_v in
  let* r_a2_v = hash_tree_root_IndexedAttestation ~at attestation_2 in
  let* r_a2 = to_b32_exn ~at r_a2_v in
  let field_roots = [| r_a1; r_a2 |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_SignedBeaconBlockHeader(signed) : root ----- *)
let hash_tree_root_SignedBeaconBlockHeader ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let* temp =
    match v.it with
    | StructV [ (_, v_msg); (_, v_sig) ]
    | TupleV [ v_msg; v_sig ]
    | ListV [ v_msg; v_sig ] ->
        Ok (v_msg, v_sig)
    | _ ->
        Error (Err.runtime at "SignedBeaconBlockHeader: unexpected value shape")
  in
  let message, signature = temp in
  (* message: BeaconBlockHeader *)
  let* msg_root_v = hash_tree_root_beaconBlockHeader ~at message in
  let* r_message = to_b32_exn ~at msg_root_v in
  (* signature: BLSSignature(96) → ByteVector[96] *)
  let* () = ensure_fits_bytes ~at (get_nat signature) ~len:96 in
  let sig_bytes = be_of_bigint_fixed (get_nat signature) ~len:96 in
  let r_signature =
    chunkize_bytevector_fixed sig_bytes ~len:96 |> merkleize_leaves
  in
  let field_roots = [| r_message; r_signature |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_ProposerSlashing(proposerSlashing) : root ----- *)
let hash_tree_root_ProposerSlashing ~at (v : Value.t) : (Value.t, Err.t) result
    =
  let* temp =
    match v.it with
    | StructV [ (_, sh1); (_, sh2) ] | TupleV [ sh1; sh2 ] | ListV [ sh1; sh2 ]
      ->
        Ok (sh1, sh2)
    | _ -> Error (Err.runtime at "ProposerSlashing: unexpected value shape")
  in
  let signed_header_1, signed_header_2 = temp in
  let* r_sh1_v = hash_tree_root_SignedBeaconBlockHeader ~at signed_header_1 in
  let* r_sh1 = to_b32_exn ~at r_sh1_v in
  let* r_sh2_v = hash_tree_root_SignedBeaconBlockHeader ~at signed_header_2 in
  let* r_sh2 = to_b32_exn ~at r_sh2_v in
  let field_roots = [| r_sh1; r_sh2 |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_Fork(fork) : root ----- *)
let hash_tree_root_Fork ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* previous_version, current_version, epoch =
    match v.it with
    | StructV [ (_, v_pv); (_, v_cv); (_, v_epoch) ]
    | TupleV [ v_pv; v_cv; v_epoch ]
    | ListV [ v_pv; v_cv; v_epoch ] ->
        Ok (v_pv, v_cv, v_epoch)
    | _ -> Error (Err.runtime at "Fork: unexpected value shape")
  in
  (* previous_version: Bytes4 *)
  let* () = ensure_fits_bytes ~at (get_nat previous_version) ~len:4 in
  let pv_raw = be_of_bigint_fixed (get_nat previous_version) ~len:4 in
  let pv_leaves = chunkize_bytevector_fixed pv_raw ~len:4 in
  let r_pv = merkleize_leaves pv_leaves in
  (* current_version: Bytes4 *)
  let* () = ensure_fits_bytes ~at (get_nat current_version) ~len:4 in
  let cv_raw = be_of_bigint_fixed (get_nat current_version) ~len:4 in
  let cv_leaves = chunkize_bytevector_fixed cv_raw ~len:4 in
  let r_cv = merkleize_leaves cv_leaves in
  (* epoch: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat epoch) ~len:8 in
  let r_epoch = leaf_uint_le (get_nat epoch) ~nbytes:8 in
  (* container root *)
  let field_roots = [| r_pv; r_cv; r_epoch |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_Validator(validator) : root ----- *)
let hash_tree_root_Validator ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* ( pubkey,
         withdrawal_credentials,
         effective_balance,
         slashed,
         activation_eligibility_epoch,
         activation_epoch,
         exit_epoch,
         withdrawable_epoch ) =
    match v.it with
    | StructV
        [
          (_, v1); (_, v2); (_, v3); (_, v4); (_, v5); (_, v6); (_, v7); (_, v8);
        ]
    | TupleV [ v1; v2; v3; v4; v5; v6; v7; v8 ]
    | ListV [ v1; v2; v3; v4; v5; v6; v7; v8 ] ->
        Ok (v1, v2, v3, v4, v5, v6, v7, v8)
    | _ -> Error (Err.runtime at "Validator: unexpected value shape")
  in
  (* pubkey: BLSPubkey(Bytes48) *)
  let* () = ensure_fits_bytes ~at (get_nat pubkey) ~len:48 in
  let pubkey_raw = be_of_bigint_fixed (get_nat pubkey) ~len:48 in
  let pubkey_leaves = chunkize_bytevector_fixed pubkey_raw ~len:48 in
  let r_pubkey = merkleize_leaves pubkey_leaves in
  (* withdrawal_credentials: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat withdrawal_credentials) ~len:32 in
  let r_wcred = leaf_bytes32 (get_nat withdrawal_credentials) in
  (* effective_balance: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat effective_balance) ~len:8 in
  let r_effective_balance =
    leaf_uint_le (get_nat effective_balance) ~nbytes:8
  in
  (* slashed: boolean -> 1바이트 *)
  let slashed_bool = Value.get_bool slashed in
  let slashed_nat = if slashed_bool then Bigint.one else Bigint.zero in
  let* () = ensure_fits_bytes ~at slashed_nat ~len:1 in
  let r_slashed = leaf_uint_le slashed_nat ~nbytes:1 in
  (* activation_eligibility_epoch: uint64 *)
  let* () =
    ensure_fits_bytes ~at (get_nat activation_eligibility_epoch) ~len:8
  in
  let r_activation_eligibility_epoch =
    leaf_uint_le (get_nat activation_eligibility_epoch) ~nbytes:8
  in
  (* activation_epoch: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat activation_epoch) ~len:8 in
  let r_activation_epoch = leaf_uint_le (get_nat activation_epoch) ~nbytes:8 in
  (* exit_epoch: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat exit_epoch) ~len:8 in
  let r_exit_epoch = leaf_uint_le (get_nat exit_epoch) ~nbytes:8 in
  (* withdrawable_epoch: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat withdrawable_epoch) ~len:8 in
  let r_withdrawable_epoch =
    leaf_uint_le (get_nat withdrawable_epoch) ~nbytes:8
  in
  (* container root *)
  let field_roots =
    [|
      r_pubkey;
      r_wcred;
      r_effective_balance;
      r_slashed;
      r_activation_eligibility_epoch;
      r_activation_epoch;
      r_exit_epoch;
      r_withdrawable_epoch;
    |]
  in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_SyncCommittee(syncCommittee) : root ----- *)
let hash_tree_root_SyncCommittee ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let get_list vv = match vv.it with ListV xs -> xs | _ -> [] in
  let* pubkeys, aggregate_pubkey =
    match v.it with
    | StructV [ (_, v_pubkeys); (_, v_agg) ]
    | TupleV [ v_pubkeys; v_agg ]
    | ListV [ v_pubkeys; v_agg ] ->
        Ok (v_pubkeys, v_agg)
    | _ -> Error (Err.runtime at "SyncCommittee: unexpected value shape")
  in
  (* pubkeys: Vector[BLSPubkey, 512] (고정) *)
  (* ByteVector[48]는 48B이므로 각 요소를 먼저 merkleize한 후 그 root들을 merkleize *)
  let pubkeys_list = get_list pubkeys in
  let rec process_pubkeys acc = function
    | [] -> Ok (List.rev acc)
    | pk :: rest ->
        let* () = ensure_fits_bytes ~at (get_nat pk) ~len:48 in
        let pk_raw = be_of_bigint_fixed (get_nat pk) ~len:48 in
        let pk_root =
          chunkize_bytevector_fixed pk_raw ~len:48 |> merkleize_leaves
        in
        process_pubkeys (pk_root :: acc) rest
  in
  let* pubkeys_roots = process_pubkeys [] pubkeys_list in
  (* Vector는 고정 길이이므로 mix_in_length 없음 *)
  let pubkeys_array = Array.of_list pubkeys_roots in
  let r_pubkeys = merkleize_leaves pubkeys_array in
  (* aggregate_pubkey: BLSPubkey(Bytes48) *)
  let* () = ensure_fits_bytes ~at (get_nat aggregate_pubkey) ~len:48 in
  let agg_raw = be_of_bigint_fixed (get_nat aggregate_pubkey) ~len:48 in
  let agg_leaves = chunkize_bytevector_fixed agg_raw ~len:48 in
  let r_agg = merkleize_leaves agg_leaves in
  (* container root *)
  let field_roots = [| r_pubkeys; r_agg |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_ExecutionPayloadHeader(header) : root ----- *)
let hash_tree_root_ExecutionPayloadHeader ~at (v : Value.t) :
    (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  (* Detect fork by field count: 15 fields = Capella, 17 fields = Deneb *)
  let* ( parent_hash,
         fee_recipient,
         state_root,
         receipts_root,
         logs_bloom,
         prev_randao,
         block_number,
         gas_limit,
         gas_used,
         timestamp,
         extra_data,
         base_fee_per_gas,
         block_hash,
         transactions_root,
         withdrawals_root,
         blob_gas_used,
         excess_blob_gas ) =
    match v.it with
    | StructV fields ->
        let count = List.length fields in
        if count = 15 then
          (match fields with
          | [ (_, v1); (_, v2); (_, v3); (_, v4); (_, v5); (_, v6); (_, v7);
              (_, v8); (_, v9); (_, v10); (_, v11); (_, v12); (_, v13);
              (_, v14); (_, v15) ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, None, None)
          | _ -> Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count"))
        else if count = 17 then
          (match fields with
          | [ (_, v1); (_, v2); (_, v3); (_, v4); (_, v5); (_, v6); (_, v7);
              (_, v8); (_, v9); (_, v10); (_, v11); (_, v12); (_, v13);
              (_, v14); (_, v15); (_, v16); (_, v17) ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, Some v16, Some v17)
          | _ -> Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count"))
        else
          Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count")
    | TupleV fields ->
        let count = List.length fields in
        if count = 15 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, None, None)
          | _ -> Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count"))
        else if count = 17 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15; v16; v17 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, Some v16, Some v17)
          | _ -> Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count"))
        else
          Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count")
    | ListV fields ->
        let count = List.length fields in
        if count = 15 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, None, None)
          | _ -> Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count"))
        else if count = 17 then
          (match fields with
          | [ v1; v2; v3; v4; v5; v6; v7; v8; v9; v10; v11; v12; v13; v14; v15; v16; v17 ] ->
              Ok (v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, Some v16, Some v17)
          | _ -> Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count"))
        else
          Error (Err.runtime at "ExecutionPayloadHeader: unexpected field count")
    | _ ->
        Error (Err.runtime at "ExecutionPayloadHeader: unexpected value shape")
  in
  (* 1. parent_hash: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat parent_hash) ~len:32 in
  let r_parent_hash = leaf_bytes32 (get_nat parent_hash) in
  (* 2. fee_recipient: ByteVector[20] *)
  let* () = ensure_fits_bytes ~at (get_nat fee_recipient) ~len:20 in
  let fr_bytes = be_of_bigint_fixed (get_nat fee_recipient) ~len:20 in
  let r_fee_recipient =
    chunkize_bytevector_fixed fr_bytes ~len:20 |> merkleize_leaves
  in
  (* 3. state_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat state_root) ~len:32 in
  let r_state_root = leaf_bytes32 (get_nat state_root) in
  (* 4. receipts_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat receipts_root) ~len:32 in
  let r_receipts_root = leaf_bytes32 (get_nat receipts_root) in
  (* 5. logs_bloom: ByteVector[256] *)
  let* () = ensure_fits_bytes ~at (get_nat logs_bloom) ~len:256 in
  let lb_bytes = be_of_bigint_fixed (get_nat logs_bloom) ~len:256 in
  let r_logs_bloom =
    chunkize_bytevector_fixed lb_bytes ~len:256 |> merkleize_leaves
  in
  (* 6. prev_randao: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat prev_randao) ~len:32 in
  let r_prev_randao = leaf_bytes32 (get_nat prev_randao) in
  (* 7. block_number: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat block_number) ~len:8 in
  let r_block_number = leaf_uint_le (get_nat block_number) ~nbytes:8 in
  (* 8. gas_limit: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat gas_limit) ~len:8 in
  let r_gas_limit = leaf_uint_le (get_nat gas_limit) ~nbytes:8 in
  (* 9. gas_used: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat gas_used) ~len:8 in
  let r_gas_used = leaf_uint_le (get_nat gas_used) ~nbytes:8 in
  (* 10. timestamp: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat timestamp) ~len:8 in
  let r_timestamp = leaf_uint_le (get_nat timestamp) ~nbytes:8 in
  (* 11. extra_data: ByteList[<=32], mix_in_length 적용 *)
  (* extra_data는 ListV 형태 (각 요소는 uint8) 또는 BytesV 형태 *)
  let get_list_bytes v =
    match v.it with
    | ListV lst ->
        let get_nat v = v |> Value.get_num |> Num.to_int in
        let bytes_list = List.map get_nat lst in
        let buf = Buffer.create (List.length bytes_list) in
        List.iter
          (fun n ->
            (* 범위를 벗어난 바이트는 무시하지 않고 예외를 발생시켜야 함 *)
            if Bigint.(n < zero || n >= of_int 256) then
              invalid_arg
                (Printf.sprintf "get_list_bytes: byte out of range: %s"
                   (Bigint.to_string n))
            else Buffer.add_char buf (Stdlib.Char.chr (Bigint.to_int_exn n)))
          bytes_list;
        Bytes.of_string (Buffer.contents buf)
    | BytesV { num; len } ->
        (* BytesV: num을 len 바이트로 변환 (Big-endian) *)
        be_of_bigint_fixed num ~len
    | _ -> Bytes.make 0 '\x00'
  in
  let extra_bytes = get_list_bytes extra_data in
  let extra_len = Bytes.length extra_bytes in
  (* extra_data: ByteList[MAX_EXTRA_DATA_BYTES], ExecutionPayload와 동일하게 처리 *)
  let extra_leaves = chunkize_bytes_bytev extra_bytes in
  let extra_root = merkleize_leaves extra_leaves in
  let r_extra_data = mix_in_length extra_root (Bigint.of_int extra_len) in
  (* 12. base_fee_per_gas: uint256, 32B LE *)
  let* () = ensure_fits_bytes ~at (get_nat base_fee_per_gas) ~len:32 in
  let r_base_fee = leaf_uint_le (get_nat base_fee_per_gas) ~nbytes:32 in
  (* 13. block_hash: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat block_hash) ~len:32 in
  let r_block_hash = leaf_bytes32 (get_nat block_hash) in
  (* 14. transactions_root: bytes32 (이미 루트) *)
  let* () = ensure_fits_bytes ~at (get_nat transactions_root) ~len:32 in
  let r_transactions_root = leaf_bytes32 (get_nat transactions_root) in
  (* 15. withdrawals_root: bytes32 (이미 루트) *)
  let* () = ensure_fits_bytes ~at (get_nat withdrawals_root) ~len:32 in
  let r_withdrawals_root = leaf_bytes32 (get_nat withdrawals_root) in
  (* Deneb fields (16-17): blob_gas_used, excess_blob_gas *)
  let* (r_blob_gas_used, r_excess_blob_gas) =
    match (blob_gas_used, excess_blob_gas) with
    | Some bg, Some eb ->
        (* 16. blob_gas_used: uint64 *)
        let* () = ensure_fits_bytes ~at (get_nat bg) ~len:8 in
        let r_bg = leaf_uint_le (get_nat bg) ~nbytes:8 in
        (* 17. excess_blob_gas: uint64 *)
        let* () = ensure_fits_bytes ~at (get_nat eb) ~len:8 in
        let r_eb = leaf_uint_le (get_nat eb) ~nbytes:8 in
        Ok (r_bg, r_eb)
    | None, None -> Ok (zero32, zero32)
    | _ -> Error (Err.runtime at "ExecutionPayloadHeader: inconsistent Deneb fields")
  in
  (* 정해진 순서로 배열 *)
  let field_roots =
    match (blob_gas_used, excess_blob_gas) with
    | None, None ->
        (* Capella: 15 fields *)
        [|
          r_parent_hash;
          r_fee_recipient;
          r_state_root;
          r_receipts_root;
          r_logs_bloom;
          r_prev_randao;
          r_block_number;
          r_gas_limit;
          r_gas_used;
          r_timestamp;
          r_extra_data;
          r_base_fee;
          r_block_hash;
          r_transactions_root;
          r_withdrawals_root;
        |]
    | Some _, Some _ ->
        (* Deneb: 17 fields *)
        [|
          r_parent_hash;
          r_fee_recipient;
          r_state_root;
          r_receipts_root;
          r_logs_bloom;
          r_prev_randao;
          r_block_number;
          r_gas_limit;
          r_gas_used;
          r_timestamp;
          r_extra_data;
          r_base_fee;
          r_block_hash;
          r_transactions_root;
          r_withdrawals_root;
          r_blob_gas_used;
          r_excess_blob_gas;
        |]
    | _ -> assert false
  in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_HistoricalSummary(summary) : root ----- *)
let hash_tree_root_HistoricalSummary ~at (v : Value.t) : (Value.t, Err.t) result
    =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* block_summary_root, state_summary_root =
    match v.it with
    | StructV [ (_, v_block); (_, v_state) ]
    | TupleV [ v_block; v_state ]
    | ListV [ v_block; v_state ] ->
        Ok (v_block, v_state)
    | _ -> Error (Err.runtime at "HistoricalSummary: unexpected value shape")
  in
  (* block_summary_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat block_summary_root) ~len:32 in
  let r_block = leaf_bytes32 (get_nat block_summary_root) in
  (* state_summary_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat state_summary_root) ~len:32 in
  let r_state = leaf_bytes32 (get_nat state_summary_root) in
  (* container root *)
  let field_roots = [| r_block; r_state |] in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_beaconBlockBody(beaconBlockBody) : root ----- *)
let hash_tree_root_beaconBlockBody ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat x = x |> Value.get_num |> Num.to_int in
  let get_list vv = match vv.it with ListV xs -> xs | _ -> [] in
  (* Detect fork by field count: 11 fields = Capella, 12 fields = Deneb *)
  let* ( randao_reveal,
         eth1_data,
         graffiti,
         proposer_slashings,
         attester_slashings,
         attestations,
         deposits,
         voluntary_exits,
         sync_aggregate,
         execution_payload,
         bls_to_execution_changes,
         blob_kzg_commitments ) =
    match v.it with
    | StructV fields ->
        let count = List.length fields in
        if count = 11 then
          (match fields with
          | [ (_, a1); (_, a2); (_, a3); (_, a4); (_, a5); (_, a6); (_, a7);
              (_, a8); (_, a9); (_, a10); (_, a11) ] ->
              Ok (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, None)
          | _ -> Error (Err.runtime at "beaconBlockBody: unexpected field count"))
        else if count = 12 then
          (match fields with
          | [ (_, a1); (_, a2); (_, a3); (_, a4); (_, a5); (_, a6); (_, a7);
              (_, a8); (_, a9); (_, a10); (_, a11); (_, a12) ] ->
              Ok (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, Some a12)
          | _ -> Error (Err.runtime at "beaconBlockBody: unexpected field count"))
        else
          Error (Err.runtime at "beaconBlockBody: unexpected field count")
    | TupleV fields ->
        let count = List.length fields in
        if count = 11 then
          (match fields with
          | [ a1; a2; a3; a4; a5; a6; a7; a8; a9; a10; a11 ] ->
              Ok (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, None)
          | _ -> Error (Err.runtime at "beaconBlockBody: unexpected field count"))
        else if count = 12 then
          (match fields with
          | [ a1; a2; a3; a4; a5; a6; a7; a8; a9; a10; a11; a12 ] ->
              Ok (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, Some a12)
          | _ -> Error (Err.runtime at "beaconBlockBody: unexpected field count"))
        else
          Error (Err.runtime at "beaconBlockBody: unexpected field count")
    | ListV fields ->
        let count = List.length fields in
        if count = 11 then
          (match fields with
          | [ a1; a2; a3; a4; a5; a6; a7; a8; a9; a10; a11 ] ->
              Ok (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, None)
          | _ -> Error (Err.runtime at "beaconBlockBody: unexpected field count"))
        else if count = 12 then
          (match fields with
          | [ a1; a2; a3; a4; a5; a6; a7; a8; a9; a10; a11; a12 ] ->
              Ok (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, Some a12)
          | _ -> Error (Err.runtime at "beaconBlockBody: unexpected field count"))
        else
          Error (Err.runtime at "beaconBlockBody: unexpected field count")
    | _ -> Error (Err.runtime at "beaconBlockBody: unexpected value shape")
  in
  (* randao_reveal: BLSSignature(96) *)
  let* () = ensure_fits_bytes ~at (get_nat randao_reveal) ~len:96 in
  let sig96 = be_of_bigint_fixed (get_nat randao_reveal) ~len:96 in
  let r_randao = chunkize_bytevector_fixed sig96 ~len:96 |> merkleize_leaves in
  (* Printf.printf "[DEBUG body] 1. RANDAO_REVEAL: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_randao) *)
  (*   (bigint_of_be_bytes r_randao |> Bigint.to_string); *)

  let* r_eth1_v = hash_tree_root_eth1Data ~at eth1_data in
  let* r_eth1 = to_b32_exn ~at r_eth1_v in
  (* Printf.printf "[DEBUG body] 2. ETH1_DATA: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_eth1) *)
  (*   (bigint_of_be_bytes r_eth1 |> Bigint.to_string); *)
  (* graffiti: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat graffiti) ~len:32 in
  let r_graffiti = leaf_bytes32 (get_nat graffiti) in

  (* Printf.printf "[DEBUG body] 3. GRAFFITI: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_graffiti) *)
  (*   (bigint_of_be_bytes r_graffiti |> Bigint.to_string); *)

  (* composite List[T, N] 처리를 위한 헬퍼: 최대 길이 N까지 패딩 후 merkleize *)
  let list_htr_with_limit (xs : Value.t list)
      (f : Value.t -> (Value.t, Err.t) result) (limit : int) :
      (Bytes.t, Err.t) result =
    let rec mapM acc = function
      | [] -> Ok (List.rev acc)
      | x :: tl ->
          let* rv = f x in
          let* rv_bytes = to_b32_exn ~at rv in
          mapM (rv_bytes :: acc) tl
    in
    let* leaves_list = mapM [] xs in
    let arr = Array.of_list leaves_list in
    (* SSZ 규칙: 최대 길이 N까지 zero32 패딩 후 merkleize *)
    let vec_root = merkleize_list_composite_with_limit arr limit in
    Ok (mix_in_length vec_root (Bigint.of_int (Array.length arr)))
  in
  (* Capella 메인넷 상수 값 *)
  let max_proposer_slashings = 16 in
  let max_attester_slashings = 2 in
  let max_attestations = 128 in
  let max_deposits = 16 in
  let max_voluntary_exits = 16 in
  let max_bls_to_execution_changes = 16 in
  let* r_prop_slash =
    list_htr_with_limit
      (get_list proposer_slashings)
      (hash_tree_root_ProposerSlashing ~at)
      max_proposer_slashings
  in
  (* Printf.printf "[DEBUG body] 4. PROPOSER_SLASHINGS: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_prop_slash) *)
  (*   (bigint_of_be_bytes r_prop_slash |> Bigint.to_string); *)
  let* r_att_slash =
    list_htr_with_limit
      (get_list attester_slashings)
      (hash_tree_root_AttesterSlashing ~at)
      max_attester_slashings
  in
  (* Printf.printf "[DEBUG body] 5. ATTESTER_SLASHINGS: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_att_slash) *)
  (*   (bigint_of_be_bytes r_att_slash |> Bigint.to_string); *)
  let* r_attest =
    list_htr_with_limit (get_list attestations)
      (hash_tree_root_Attestation ~at)
      max_attestations
  in
  (* Printf.printf "[DEBUG body] 6. ATTESTATIONS: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_attest) *)
  (*   (bigint_of_be_bytes r_attest |> Bigint.to_string); *)
  let* r_deposits =
    list_htr_with_limit (get_list deposits)
      (hash_tree_root_Deposit ~at)
      max_deposits
  in
  (* Printf.printf "[DEBUG body] 7. DEPOSITS: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_deposits) *)
  (*   (bigint_of_be_bytes r_deposits |> Bigint.to_string); *)
  let* r_vol =
    list_htr_with_limit (get_list voluntary_exits)
      (hash_tree_root_SignedVoluntaryExit ~at)
      max_voluntary_exits
  in
  (* Printf.printf "[DEBUG body] 8. VOLUNTARY_EXITS: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_vol) *)
  (*   (bigint_of_be_bytes r_vol |> Bigint.to_string); *)
  let* r_sync_v = hash_tree_root_SyncAggregate ~at sync_aggregate in
  let* r_sync = to_b32_exn ~at r_sync_v in
  (* Printf.printf "[DEBUG body] 9. SYNC_AGGREGATE: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_sync) *)
  (*   (bigint_of_be_bytes r_sync |> Bigint.to_string); *)
  let* r_exec_v = hash_tree_root_executionPayload ~at execution_payload in
  let* r_exec = to_b32_exn ~at r_exec_v in
  (* Printf.printf "[DEBUG body] 10. EXECUTION_PAYLOAD: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_exec) *)
  (*   (bigint_of_be_bytes r_exec |> Bigint.to_string); *)
  let* r_bls2exec =
    list_htr_with_limit
      (get_list bls_to_execution_changes)
      (hash_tree_root_SignedBLSToExecutionChange ~at)
      max_bls_to_execution_changes
  in
  (* Printf.printf "[DEBUG body] 11. BLS_TO_EXECUTION_CHANGES: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex r_bls2exec) *)
  (*   (bigint_of_be_bytes r_bls2exec |> Bigint.to_string); *)
  (* Deneb field (12): blob_kzg_commitments *)
  let* r_blob_kzg_commitments =
    match blob_kzg_commitments with
    | Some commitments ->
        (* blob_kzg_commitments: List[KZGCommitment, MAX_BLOB_COMMITMENTS_PER_BLOCK] *)
        (* KZGCommitment is bytes48, so we need to process each commitment *)
        let max_blob_commitments = 4096 in
        (* MAX_BLOB_COMMITMENTS_PER_BLOCK *)
        let commitments_list = get_list commitments in
        (* Process each KZGCommitment (bytes48) *)
        let process_kzg_commitment (commitment : Value.t) : (Bytes.t, Err.t) result =
          (* KZGCommitment: bytes48 *)
          let* () = ensure_fits_bytes ~at (get_nat commitment) ~len:48 in
          let bytes48 = be_of_bigint_fixed (get_nat commitment) ~len:48 in
          (* bytes48을 chunkize하여 merkleize *)
          let chunks = chunkize_bytevector_fixed bytes48 ~len:48 in
          Ok (merkleize_leaves chunks)
        in
        let rec mapM acc = function
          | [] -> Ok (List.rev acc)
          | x :: tl ->
              let* rv = process_kzg_commitment x in
              mapM (rv :: acc) tl
        in
        let* commitment_roots = mapM [] commitments_list in
        let arr = Array.of_list commitment_roots in
        (* SSZ 규칙: 최대 길이까지 zero32 패딩 후 merkleize *)
        let vec_root = merkleize_list_composite_with_limit arr max_blob_commitments in
        Ok (mix_in_length vec_root (Bigint.of_int (Array.length arr)))
    | None -> Ok zero32
  in
  (* 정해진 순서로 배열 *)
  let field_roots =
    match blob_kzg_commitments with
    | None ->
        (* Capella: 11 fields *)
        [|
          r_randao;
          r_eth1;
          r_graffiti;
          r_prop_slash;
          r_att_slash;
          r_attest;
          r_deposits;
          r_vol;
          r_sync;
          r_exec;
          r_bls2exec;
        |]
    | Some _ ->
        (* Deneb: 12 fields *)
        [|
          r_randao;
          r_eth1;
          r_graffiti;
          r_prop_slash;
          r_att_slash;
          r_attest;
          r_deposits;
          r_vol;
          r_sync;
          r_exec;
          r_bls2exec;
          r_blob_kzg_commitments;
        |]
  in
  let root_bytes = merkleize_leaves field_roots in
  (* Printf.printf "[DEBUG body] FINAL BODY_ROOT: %s (int: %s)\n%!"  *)
  (*   (bytes_to_hex root_bytes) *)
  (*   (bigint_of_be_bytes root_bytes |> Bigint.to_string); *)
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ----- hash_tree_root_beaconState(beaconState) : root ----- *)
let hash_tree_root_beaconState ~at (v : Value.t) : (Value.t, Err.t) result =
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let get_list vv = match vv.it with ListV xs -> xs | _ -> [] in
  (* 28 fields *)
  let* ( genesis_time,
         genesis_validators_root,
         slot,
         fork,
         latest_block_header,
         block_roots,
         state_roots,
         historical_roots,
         eth1_data,
         eth1_data_votes,
         eth1_deposit_index,
         validators,
         balances,
         randao_mixes,
         slashings,
         previous_epoch_participation,
         current_epoch_participation,
         justification_bits,
         previous_justified_checkpoint,
         current_justified_checkpoint,
         finalized_checkpoint,
         inactivity_scores,
         current_sync_committee,
         next_sync_committee,
         latest_execution_payload_header,
         next_withdrawal_index,
         next_withdrawal_validator_index,
         historical_summaries ) =
    match v.it with
    | StructV
        [
          (_, f1);
          (_, f2);
          (_, f3);
          (_, f4);
          (_, f5);
          (_, f6);
          (_, f7);
          (_, f8);
          (_, f9);
          (_, f10);
          (_, f11);
          (_, f12);
          (_, f13);
          (_, f14);
          (_, f15);
          (_, f16);
          (_, f17);
          (_, f18);
          (_, f19);
          (_, f20);
          (_, f21);
          (_, f22);
          (_, f23);
          (_, f24);
          (_, f25);
          (_, f26);
          (_, f27);
          (_, f28);
        ]
    | TupleV
        [
          f1;
          f2;
          f3;
          f4;
          f5;
          f6;
          f7;
          f8;
          f9;
          f10;
          f11;
          f12;
          f13;
          f14;
          f15;
          f16;
          f17;
          f18;
          f19;
          f20;
          f21;
          f22;
          f23;
          f24;
          f25;
          f26;
          f27;
          f28;
        ]
    | ListV
        [
          f1;
          f2;
          f3;
          f4;
          f5;
          f6;
          f7;
          f8;
          f9;
          f10;
          f11;
          f12;
          f13;
          f14;
          f15;
          f16;
          f17;
          f18;
          f19;
          f20;
          f21;
          f22;
          f23;
          f24;
          f25;
          f26;
          f27;
          f28;
        ] ->
        Ok
          ( f1,
            f2,
            f3,
            f4,
            f5,
            f6,
            f7,
            f8,
            f9,
            f10,
            f11,
            f12,
            f13,
            f14,
            f15,
            f16,
            f17,
            f18,
            f19,
            f20,
            f21,
            f22,
            f23,
            f24,
            f25,
            f26,
            f27,
            f28 )
    | _ -> Error (Err.runtime at "beaconState: unexpected value shape")
  in
  (* 1. genesis_time: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat genesis_time) ~len:8 in
  let r_genesis_time = leaf_uint_le (get_nat genesis_time) ~nbytes:8 in
  (* 2. genesis_validators_root: bytes32 *)
  let* () = ensure_fits_bytes ~at (get_nat genesis_validators_root) ~len:32 in
  let r_genesis_validators_root =
    leaf_bytes32 (get_nat genesis_validators_root)
  in
  (* 3. slot: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat slot) ~len:8 in
  let r_slot = leaf_uint_le (get_nat slot) ~nbytes:8 in
  (* 4. fork: Fork *)
  let* r_fork_v = hash_tree_root_Fork ~at fork in
  let* r_fork = to_b32_exn ~at r_fork_v in
  (* 5. latest_block_header: BeaconBlockHeader *)
  let* r_latest_block_header_v =
    hash_tree_root_beaconBlockHeader ~at latest_block_header
  in
  let* r_latest_block_header = to_b32_exn ~at r_latest_block_header_v in
  (* 6. block_roots: Vector[Root, ...] (고정, basic vector) *)
  let block_roots_list = get_list block_roots in
  let block_roots_bytes =
    block_roots_list
    |> List.map (fun r -> be_of_bigint_fixed (get_nat r) ~len:32)
  in
  let r_block_roots = htr_bytes32_vector block_roots_bytes in
  (* 7. state_roots: Vector[Root, ...] (고정, basic vector) *)
  let state_roots_list = get_list state_roots in
  let state_roots_bytes =
    state_roots_list
    |> List.map (fun r -> be_of_bigint_fixed (get_nat r) ~len:32)
  in
  let r_state_roots = htr_bytes32_vector state_roots_bytes in
  (* 8. historical_roots: List[Root, HISTORICAL_ROOTS_LIMIT] *)
  (* Capella: 16777216 *)
  (* Root는 bytes32 = ByteVector[32]이므로 raw bytes로 처리 (LE 변환 없이) *)
  let historical_roots_limit = 16777216 in
  (* HISTORICAL_ROOTS_LIMIT *)
  let historical_roots_list = get_list historical_roots in
  let historical_roots_bytes =
    historical_roots_list
    |> List.map (fun r -> be_of_bigint_fixed (get_nat r) ~len:32)
  in
  let r_historical_roots =
    htr_bytevec_list_with_limit historical_roots_bytes historical_roots_limit 32
  in
  (* 9. eth1_data: Eth1Data *)
  let* r_eth1_data_v = hash_tree_root_eth1Data ~at eth1_data in
  let* r_eth1_data = to_b32_exn ~at r_eth1_data_v in
  (* 10. eth1_data_votes: List[Eth1Data, EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH] *)
  (* Capella: 64 * 32 = 2048 *)
  let eth1_data_votes_limit = 2048 in
  let eth1_votes_list = get_list eth1_data_votes in
  let rec process_eth1_votes acc = function
    | [] -> Ok (List.rev acc)
    | vote :: rest ->
        let* r_vote_v = hash_tree_root_eth1Data ~at vote in
        let* r_vote = to_b32_exn ~at r_vote_v in
        process_eth1_votes (r_vote :: acc) rest
  in
  let* eth1_votes_roots = process_eth1_votes [] eth1_votes_list in
  let eth1_votes_arr = Array.of_list eth1_votes_roots in
  (* SSZ 규칙: 최대 길이 N까지 zero32 패딩 후 merkleize *)
  let eth1_votes_vec =
    merkleize_list_composite_with_limit eth1_votes_arr eth1_data_votes_limit
  in
  let r_eth1_data_votes =
    mix_in_length eth1_votes_vec (Bigint.of_int (Array.length eth1_votes_arr))
  in
  (* 11. eth1_deposit_index: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat eth1_deposit_index) ~len:8 in
  let r_eth1_deposit_index =
    leaf_uint_le (get_nat eth1_deposit_index) ~nbytes:8
  in
  (* 12. validators: List[Validator, VALIDATOR_REGISTRY_LIMIT] *)
  (* Capella: 1099511627776 *)
  let validator_registry_limit = 1099511627776 in
  let validators_list = get_list validators in
  let rec process_validators acc = function
    | [] -> Ok (List.rev acc)
    | vali :: rest ->
        let* r_vali_v = hash_tree_root_Validator ~at vali in
        let* r_vali = to_b32_exn ~at r_vali_v in
        process_validators (r_vali :: acc) rest
  in
  let* validators_roots = process_validators [] validators_list in
  let validators_arr = Array.of_list validators_roots in
  (* SSZ 규칙: 최대 길이 N까지 zero32 패딩 후 merkleize *)
  let validators_vec =
    merkleize_list_composite_with_limit validators_arr validator_registry_limit
  in
  let r_validators =
    mix_in_length validators_vec (Bigint.of_int (Array.length validators_arr))
  in
  (* 13. balances: List[uint64, VALIDATOR_REGISTRY_LIMIT] *)
  let balances_list = get_list balances in
  let items = balances_list |> List.map (fun b -> (get_nat b, 8)) in
  let r_balances = htr_basic_list_with_limit items validator_registry_limit 8 in
  (* 14. randao_mixes: Vector[Bytes32, ...] (고정, basic vector) *)
  let randao_mixes_list = get_list randao_mixes in
  let randao_mixes_bytes =
    randao_mixes_list
    |> List.map (fun r -> be_of_bigint_fixed (get_nat r) ~len:32)
  in
  let r_randao_mixes = htr_bytes32_vector randao_mixes_bytes in
  (* 15. slashings: Vector[uint64, ...] (고정) - 연속 패킹만 (mix_in_length 없음) *)
  let slashings_list = get_list slashings in
  let items = slashings_list |> List.map (fun s -> (get_nat s, 8)) in
  let r_slashings = htr_basic_vector items in
  (* 16. previous_epoch_participation: List[uint8, VALIDATOR_REGISTRY_LIMIT] *)
  let prev_epoch_list = get_list previous_epoch_participation in
  let items = prev_epoch_list |> List.map (fun p -> (get_nat p, 1)) in
  let r_previous_epoch_participation =
    htr_basic_list_with_limit items validator_registry_limit 1
  in
  (* 17. current_epoch_participation: List[uint8, VALIDATOR_REGISTRY_LIMIT] *)
  let curr_epoch_list = get_list current_epoch_participation in
  let items = curr_epoch_list |> List.map (fun p -> (get_nat p, 1)) in
  let r_current_epoch_participation =
    htr_basic_list_with_limit items validator_registry_limit 1
  in
  (* 18. justification_bits: Bitvector[4] (고정) *)
  (* SSZ 스펙: merkleize(pack_bits(value), limit=chunk_count(type)) *)
  (* chunk_count(Bitvector[4]) = ceil(4/256) = 1 *)
  (* 스펙 규칙: "If 1 chunk: the root is the chunk itself" *)
  (* 따라서 1개 청크의 경우 청크 자체를 반환하므로, 32B 패딩된 바이트가 결과 *)
  let justification_bits_list = get_list justification_bits in
  let r_justification_bits =
    if List.length justification_bits_list <> 4 then
      Error (Err.runtime at "justification_bits: must be 4 bits")
    else
      let arr = Array.make 1 0 in
      List.iteri
        (fun i b ->
          if Value.get_bool b then arr.(0) <- arr.(0) lor (1 lsl (i mod 8))
          else ())
        justification_bits_list;
      (* pack_bits: LSB-first로 패킹 → 1바이트 *)
      (* pack: 1바이트를 32B 청크로 (오른쪽에 0 패딩) *)
      (* merkleize(1개 청크, limit=1) → 청크 자체 반환 *)
      let r = Bytes.make 32 '\x00' in
      Bytes.set r 0 (Stdlib.Char.chr arr.(0));
      Ok r
  in
  let* r_justification_bits = r_justification_bits in
  (* 19. previous_justified_checkpoint: Checkpoint *)
  let* r_prev_just_checkpoint_v =
    hash_tree_root_Checkpoint ~at previous_justified_checkpoint
  in
  let* r_previous_justified_checkpoint =
    to_b32_exn ~at r_prev_just_checkpoint_v
  in
  (* 20. current_justified_checkpoint: Checkpoint *)
  let* r_curr_just_checkpoint_v =
    hash_tree_root_Checkpoint ~at current_justified_checkpoint
  in
  let* r_current_justified_checkpoint =
    to_b32_exn ~at r_curr_just_checkpoint_v
  in
  (* 21. finalized_checkpoint: Checkpoint *)
  let* r_final_checkpoint_v =
    hash_tree_root_Checkpoint ~at finalized_checkpoint
  in
  let* r_finalized_checkpoint = to_b32_exn ~at r_final_checkpoint_v in
  (* 22. inactivity_scores: List[uint64, VALIDATOR_REGISTRY_LIMIT] *)
  let inactivity_scores_list = get_list inactivity_scores in
  let items = inactivity_scores_list |> List.map (fun s -> (get_nat s, 8)) in
  let r_inactivity_scores =
    htr_basic_list_with_limit items validator_registry_limit 8
  in
  (* 23. current_sync_committee: SyncCommittee *)
  let* r_current_sync_committee_v =
    hash_tree_root_SyncCommittee ~at current_sync_committee
  in
  let* r_current_sync_committee = to_b32_exn ~at r_current_sync_committee_v in
  (* 24. next_sync_committee: SyncCommittee *)
  let* r_next_sync_committee_v =
    hash_tree_root_SyncCommittee ~at next_sync_committee
  in
  let* r_next_sync_committee = to_b32_exn ~at r_next_sync_committee_v in
  (* 25. latest_execution_payload_header: ExecutionPayloadHeader *)
  let* r_latest_exec_payload_header_v =
    hash_tree_root_ExecutionPayloadHeader ~at latest_execution_payload_header
  in
  let* r_latest_execution_payload_header =
    to_b32_exn ~at r_latest_exec_payload_header_v
  in
  (* 26. next_withdrawal_index: uint64 *)
  let* () = ensure_fits_bytes ~at (get_nat next_withdrawal_index) ~len:8 in
  let r_next_withdrawal_index =
    leaf_uint_le (get_nat next_withdrawal_index) ~nbytes:8
  in
  (* 27. next_withdrawal_validator_index: uint64 *)
  let* () =
    ensure_fits_bytes ~at (get_nat next_withdrawal_validator_index) ~len:8
  in
  let r_next_withdrawal_validator_index =
    leaf_uint_le (get_nat next_withdrawal_validator_index) ~nbytes:8
  in
  (* 28. historical_summaries: List[HistoricalSummary, HISTORICAL_ROOTS_LIMIT] *)
  (* Capella: 16777216 *)
  let historical_roots_limit = 16777216 in
  let historical_summaries_list = get_list historical_summaries in
  let rec process_historical_summaries acc = function
    | [] -> Ok (List.rev acc)
    | summary :: rest ->
        let* r_summary_v = hash_tree_root_HistoricalSummary ~at summary in
        let* r_summary = to_b32_exn ~at r_summary_v in
        process_historical_summaries (r_summary :: acc) rest
  in
  let* historical_summaries_roots =
    process_historical_summaries [] historical_summaries_list
  in
  let historical_summaries_arr = Array.of_list historical_summaries_roots in
  (* SSZ 규칙: 최대 길이 N까지 zero32 패딩 후 merkleize *)
  let historical_summaries_vec =
    merkleize_list_composite_with_limit historical_summaries_arr
      historical_roots_limit
  in
  let r_historical_summaries =
    mix_in_length historical_summaries_vec
      (Bigint.of_int (Array.length historical_summaries_arr))
  in
  (* 정해진 순서로 배열 *)
  let field_roots =
    [|
      r_genesis_time;
      r_genesis_validators_root;
      r_slot;
      r_fork;
      r_latest_block_header;
      r_block_roots;
      r_state_roots;
      r_historical_roots;
      r_eth1_data;
      r_eth1_data_votes;
      r_eth1_deposit_index;
      r_validators;
      r_balances;
      r_randao_mixes;
      r_slashings;
      r_previous_epoch_participation;
      r_current_epoch_participation;
      r_justification_bits;
      r_previous_justified_checkpoint;
      r_current_justified_checkpoint;
      r_finalized_checkpoint;
      r_inactivity_scores;
      r_current_sync_committee;
      r_next_sync_committee;
      r_latest_execution_payload_header;
      r_next_withdrawal_index;
      r_next_withdrawal_validator_index;
      r_historical_summaries;
    |]
  in
  let root_bytes = merkleize_leaves field_roots in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)

(* ===== SigningData(object_root: root, domain: bytes32) HTR 공통 헬퍼 ===== *)
let signing_data_root_from_bytes (obj_root_b : Bytes.t) (domain_b : Bytes.t) :
    Bytes.t =
  let field_roots = [| obj_root_b; domain_b |] in
  merkleize_leaves field_roots

(* ----- hash_tree_root_DepositMessage(depositMessage) : root ----- *)
let hash_tree_root_DepositMessage ~at (dm : Value.t) : (Value.t, Err.t) result =
  (* DepositMessage(pubkey: Bytes48, withdrawal_credentials: Bytes32, amount: Gwei) *)
  let get_num v = v |> Value.get_num |> Num.to_int in
  let* pubkey_b48, wcred_b32, amount_u64 =
    match dm.it with
    | StructV [ (_, v_pub); (_, v_wcr); (_, v_amt) ]
    | TupleV [ v_pub; v_wcr; v_amt ]
    | ListV [ v_pub; v_wcr; v_amt ] ->
        Ok (get_num v_pub, get_num v_wcr, get_num v_amt)
    | _ -> Error (Err.runtime at "DepositMessage: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at pubkey_b48 ~len:48 in
  let* () = ensure_fits_bytes ~at wcred_b32 ~len:32 in
  let* () = ensure_fits_bytes ~at amount_u64 ~len:8 in
  let pubkey_raw = be_of_bigint_fixed pubkey_b48 ~len:48 in
  let r_pub =
    chunkize_bytevector_fixed pubkey_raw ~len:48 |> merkleize_leaves
  in
  let r_wcr = leaf_bytes32 wcred_b32 in
  let r_amt = leaf_uint_le amount_u64 ~nbytes:8 in
  let root = merkleize_leaves [| r_pub; r_wcr; r_amt |] in
  Ok (make_bytes ~num:(bigint_of_be_bytes root) ~len:32)

(* ----- hash_tree_root_beaconBlock(beaconBlock) : root ----- *)
let hash_tree_root_beaconBlock ~at (blk : Value.t) : (Value.t, Err.t) result =
  (* BeaconBlock(slot, proposer_index, parent_root, state_root, body) *)
  let get_nat v = v |> Value.get_num |> Num.to_int in
  let* slot_v, proposer_v, parent_v, state_v, body_v =
    match blk.it with
    | StructV [ (_, s); (_, p); (_, pr); (_, sr); (_, b) ]
    | TupleV [ s; p; pr; sr; b ]
    | ListV [ s; p; pr; sr; b ] ->
        Ok (s, p, pr, sr, b)
    | _ -> Error (Err.runtime at "BeaconBlock: unexpected value shape")
  in
  let* () = ensure_fits_bytes ~at (get_nat slot_v) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat proposer_v) ~len:8 in
  let* () = ensure_fits_bytes ~at (get_nat parent_v) ~len:32 in
  let* () = ensure_fits_bytes ~at (get_nat state_v) ~len:32 in
  let* r_body_v = hash_tree_root_beaconBlockBody ~at body_v in
  let* r_body = to_b32_exn ~at r_body_v in
  let leaves =
    [|
      leaf_uint_le (get_nat slot_v) ~nbytes:8;
      leaf_uint_le (get_nat proposer_v) ~nbytes:8;
      leaf_bytes32 (get_nat parent_v);
      leaf_bytes32 (get_nat state_v);
      r_body;
    |]
  in
  let root_b = merkleize_leaves leaves in
  Ok (make_bytes ~num:(bigint_of_be_bytes root_b) ~len:32)

(* ===== compute_signing_root_* 함수들 ===== *)
(* ----- compute_signing_root_epoch(epoch, domain) : root ----- *)
let compute_signing_root_epoch ~at (epoch_v : Num.t) (domain_v : Num.t) :
    (Value.t, Err.t) result =
  let epoch_bigint = Num.to_int epoch_v in
  let domain_bigint = Num.to_int domain_v in
  let* () = ensure_fits_bytes ~at epoch_bigint ~len:8 in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let obj_root_b = leaf_uint_le epoch_bigint ~nbytes:8 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_root_b dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

(* ----- compute_signing_root_voluntary_exit(voluntaryExit, domain) : root ----- *)
let compute_signing_root_voluntary_exit ~at (ve : Value.t) (domain_v : Num.t) :
    (Value.t, Err.t) result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_VoluntaryExit ~at ve in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

(* ----- compute_signing_root_bls_to_execution_change(message, domain) : root ----- *)
let compute_signing_root_bls_to_execution_change ~at (msg : Value.t)
    (domain_v : Num.t) : (Value.t, Err.t) result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_BLSToExecutionChange ~at msg in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

(* ----- compute_signing_root_beaconBlockHeader(header, domain) : root ----- *)
let compute_signing_root_beaconBlockHeader ~at (hdr : Value.t)
    (domain_v : Num.t) : (Value.t, Err.t) result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_beaconBlockHeader ~at hdr in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

(* ----- compute_signing_root_attestationData(ad, domain) : root ----- *)
let compute_signing_root_attestationData ~at (ad : Value.t) (domain_v : Num.t) :
    (Value.t, Err.t) result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_AttestationData ~at ad in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

(* ----- compute_signing_root_depositMessage(depositMessage, domain) : root ----- *)
let compute_signing_root_depositMessage ~at (dm : Value.t) (domain_v : Num.t) :
    (Value.t, Err.t) result =
  let domain_bigint = Num.to_int domain_v in
  let* r_obj_v = hash_tree_root_DepositMessage ~at dm in
  let* obj_b32 = to_b32_exn ~at r_obj_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

(* ----- compute_signing_root_block_root(block_root, domain) : root ----- *)
let compute_signing_root_block_root ~at (b32 : Num.t) (domain_v : Num.t) :
    (Value.t, Err.t) result =
  let b32_bigint = Num.to_int b32 in
  let domain_bigint = Num.to_int domain_v in
  let* () = ensure_fits_bytes ~at b32_bigint ~len:32 in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let obj_b = be_of_bigint_fixed b32_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

(* ----- compute_signing_root_beaconBlock(block, domain) : root ----- *)
let compute_signing_root_beaconBlock ~at (blk : Value.t) (domain_v : Num.t) :
    (Value.t, Err.t) result =
  let domain_bigint = Num.to_int domain_v in
  let* r_blk_v = hash_tree_root_beaconBlock ~at blk in
  let* obj_b32 = to_b32_exn ~at r_blk_v in
  let* () = ensure_fits_bytes ~at domain_bigint ~len:32 in
  let dom_b = be_of_bigint_fixed domain_bigint ~len:32 in
  let out_b = signing_data_root_from_bytes obj_b32 dom_b in
  Ok (make_bytes ~num:(bigint_of_be_bytes out_b) ~len:32)

let builtins : (string * Define.t) list =
  [
    ( "is_valid_merkle_branch",
      Define.T0.a5 Arg.num (Arg.list_of Arg.num) Arg.num Arg.num Arg.num
        is_valid_merkle_branch );
    ( "hash_tree_root_roots",
      Define.T0.a1 (Arg.list_of Arg.num) hash_tree_root_roots );
    ("hash_tree_root_tx", Define.T0.a1 (Arg.list_of Arg.value) hash_tree_root_tx);
    ( "hash_tree_root_beaconBlockHeader",
      Define.T0.a1 Arg.value hash_tree_root_beaconBlockHeader );
    ( "hash_tree_root_depositData",
      Define.T0.a1 Arg.value hash_tree_root_depositData );
    ("hash_tree_root_forkdata", Define.T0.a1 Arg.value hash_tree_root_forkdata);
    ( "hash_tree_root_withdrawals",
      Define.T0.a1 (Arg.list_of Arg.value) hash_tree_root_withdrawals );
    ("hash_tree_root_eth1Data", Define.T0.a1 Arg.value hash_tree_root_eth1Data);
    ( "hash_tree_root_executionPayload",
      Define.T0.a1 Arg.value hash_tree_root_executionPayload );
    ( "hash_tree_root_BLSToExecutionChange",
      Define.T0.a1 Arg.value hash_tree_root_BLSToExecutionChange );
    ( "hash_tree_root_SignedBLSToExecutionChange",
      Define.T0.a1 Arg.value hash_tree_root_SignedBLSToExecutionChange );
    ( "hash_tree_root_SyncAggregate",
      Define.T0.a1 Arg.value hash_tree_root_SyncAggregate );
    ( "hash_tree_root_VoluntaryExit",
      Define.T0.a1 Arg.value hash_tree_root_VoluntaryExit );
    ( "hash_tree_root_SignedVoluntaryExit",
      Define.T0.a1 Arg.value hash_tree_root_SignedVoluntaryExit );
    ("hash_tree_root_Deposit", Define.T0.a1 Arg.value hash_tree_root_Deposit);
    ( "hash_tree_root_Checkpoint",
      Define.T0.a1 Arg.value hash_tree_root_Checkpoint );
    ( "hash_tree_root_AttestationData",
      Define.T0.a1 Arg.value hash_tree_root_AttestationData );
    ( "hash_tree_root_Attestation",
      Define.T0.a1 Arg.value hash_tree_root_Attestation );
    ( "hash_tree_root_IndexedAttestation",
      Define.T0.a1 Arg.value hash_tree_root_IndexedAttestation );
    ( "hash_tree_root_AttesterSlashing",
      Define.T0.a1 Arg.value hash_tree_root_AttesterSlashing );
    ( "hash_tree_root_ProposerSlashing",
      Define.T0.a1 Arg.value hash_tree_root_ProposerSlashing );
    ( "hash_tree_root_SignedBeaconBlockHeader",
      Define.T0.a1 Arg.value hash_tree_root_SignedBeaconBlockHeader );
    ( "hash_tree_root_beaconBlockBody",
      Define.T0.a1 Arg.value hash_tree_root_beaconBlockBody );
    ("hash_tree_root_Fork", Define.T0.a1 Arg.value hash_tree_root_Fork);
    ("hash_tree_root_Validator", Define.T0.a1 Arg.value hash_tree_root_Validator);
    ( "hash_tree_root_SyncCommittee",
      Define.T0.a1 Arg.value hash_tree_root_SyncCommittee );
    ( "hash_tree_root_ExecutionPayloadHeader",
      Define.T0.a1 Arg.value hash_tree_root_ExecutionPayloadHeader );
    ( "hash_tree_root_HistoricalSummary",
      Define.T0.a1 Arg.value hash_tree_root_HistoricalSummary );
    ( "hash_tree_root_beaconState",
      Define.T0.a1 Arg.value hash_tree_root_beaconState );
    ( "hash_tree_root_DepositMessage",
      Define.T0.a1 Arg.value hash_tree_root_DepositMessage );
    ( "hash_tree_root_beaconBlock",
      Define.T0.a1 Arg.value hash_tree_root_beaconBlock );
    ( "compute_signing_root_epoch",
      Define.T0.a2 Arg.num Arg.num compute_signing_root_epoch );
    ( "compute_signing_root_voluntary_exit",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_voluntary_exit );
    ( "compute_signing_root_bls_to_execution_change",
      Define.T0.a2 Arg.value Arg.num
        compute_signing_root_bls_to_execution_change );
    ( "compute_signing_root_beaconBlockHeader",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_beaconBlockHeader );
    ( "compute_signing_root_attestationData",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_attestationData );
    ( "compute_signing_root_depositMessage",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_depositMessage );
    ( "compute_signing_root_block_root",
      Define.T0.a2 Arg.num Arg.num compute_signing_root_block_root );
    ( "compute_signing_root_beaconBlock",
      Define.T0.a2 Arg.value Arg.num compute_signing_root_beaconBlock );
  ]
