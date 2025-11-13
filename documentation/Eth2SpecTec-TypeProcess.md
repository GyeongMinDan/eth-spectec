# Type Processing in Spectec: Handling Ethereum 2.0 SSZ Bytes Types
Description for builtin funcs : How to implement and how to handle the type in eth2spectec.

## 1. Introduction

Spectec is a specification language framework designed to express and execute formal specifications. When adapting Spectec for Ethereum 2.0 (eth2spec) consensus specifications, we faced the challenge of representing SSZ (Simple Serialize) byte types—such as `Bytes32`, `Bytes48`, `Bytes96`—within Spectec's type system, which originally only supported four primitive types: `bool`, `nat`, `int`, and `text`.

## 2. Type Representation Strategy

### 2.1 Spectec's Primitive Type System

According to the SpecTec EL language specification, the primitive types are limited to:

```spectec
syntax primitiveType =
  | 'bool' | 'nat' | 'int' | 'text'
```

These primitive types form the foundation of Spectec's type system, and all other types must be defined in terms of these primitives.

### 2.2 Mapping SSZ Bytes Types to Spectec Types

To handle eth2spec's SSZ bytes types, we leverage Spectec's type alias mechanism. In the spec file `00-types.spectec`, we define bytes types as aliases to the `int` primitive type:

```spectec
syntax bytes = int
syntax bytes4 = int
syntax bytes32 = int
syntax bytes48 = int
syntax bytes96 = int
syntax bytes256 = int
;; ... and so on
```

This approach allows us to:
- **Preserve type semantics**: Each bytes type (e.g., `bytes32`, `bytes48`) maintains its distinct identity in the type system
- **Leverage existing infrastructure**: The `int` primitive provides arithmetic operations and value representation
- **Enable type checking**: The type checker can distinguish between different bytes types at compile time

### 2.3 Custom eth2spec Type Aliases

Beyond primitive bytes types, we also define domain-specific aliases that map to bytes types:

```spectec
syntax root = bytes32
syntax blsPubkey = bytes48
syntax blsSignature = bytes96
syntax domain = bytes32
syntax executionAddress = bytes20
```

These aliases provide semantic clarity in the specification while maintaining the underlying bytes representation.

## 3. Runtime Representation: BytesV

### 3.1 The Problem: Length Information Loss

While representing bytes types as `int` in the type system is sufficient for static type checking, it introduces a critical problem at runtime: **the byte length information is lost**. For example, a `bytes32` value and a `bytes48` value are both represented as `Bigint.t` (arbitrary-precision integers), but we cannot distinguish their intended byte lengths.

This is problematic because:
- SSZ serialization requires exact byte lengths
- Hash tree root computation depends on byte boundaries
- Cryptographic operations (BLS signatures, public keys) require specific byte lengths

### 3.2 BytesV: Preserving Length Information

To solve this problem, we introduce `BytesV`, a runtime value type that preserves both the numeric value and the byte length:

```ocaml
type value' =
  | BytesV of { num: Bigint.t; len: int }
  | NumV of Num.t
  | BoolV of bool
  | TextV of string
  | (* ... other value types ... *)
```

The `BytesV` constructor stores:
- `num`: The big-endian integer representation of the bytes
- `len`: The intended byte length (e.g., 32 for `bytes32`, 48 for `bytes48`)

### 3.3 BytesV Operations

The runtime system provides operations to create and manipulate `BytesV` values:

```ocaml
let make_bytes ~(num: Bigint.t) ~(len:int) : t =
  if len < 0 then failwith "bytes len < 0";
  let value = BytesV { num; len } in
  (* ... create value with metadata ... *)

let get_bytes (value : t) =
  match value.it with 
  | BytesV {num; len} -> (num, len) 
  | _ -> failwith "get_bytes"
```

When converting between `NumV` and `BytesV`, the system uses type information from the elaboration phase to determine the correct byte length.

## 4. Builtin Function Implementation

### 4.1 Hash Functions (`hashImpl.ml`)

The `$hash_<X>` builtin function computes SHA-256 hash of bytes values. It handles both `BytesV` and `NumV` representations, ensuring compatibility with Ethereum's SHA-256 implementation.

#### 4.1.1 Function Implementation

```ocaml
let hash_ ~at (typ : targ) (v: Runtime_dynamic.Value.t) : (Value.t, Err.t) result =
  (* bytes* 타입은 int로 표현되므로 NumV일 수도 있음 *)
  let* (num, len) =
    match v.it with
    | BytesV {num; len} -> Ok (num, len)
    | NumV _ ->
        (* bytes* 타입이 int로 표현된 경우: 타입 정보에서 길이 추론 *)
        let num_bigint = Runtime_dynamic.Value.get_num v |> Num.to_int in
        (match bytes_len_of_targ typ with
        | Some l ->
            (* 타입에서 길이를 알 수 있는 경우 *)
            (* 범위 검증: 값이 해당 길이에 맞는지 확인 *)
            let* () = validate_fits_len ~at num_bigint l in
            Ok (num_bigint, l)
        | None ->
            (* 타입 이름에서 길이를 추론할 수 없는 경우, 에러 *)
            Error (Err.runtime at "hash_<X>: cannot infer byte length from type"))
    | _ -> Error (Err.runtime at "hash_<X>: expected bytes or NumV")
  in
  let raw = bytesv_to_raw num len in  (* Convert to raw bytes *)
  let h =
    let open Digestif.SHA256 in
    digest_bytes raw |> to_raw_string |> Bytes.of_string
  in
  Ok (make_bytes ~num:(bigint_of_be_bytes h) ~len:32)
```

#### 4.1.2 Input Handling: BytesV vs NumV

The function handles two input representations:

**Case 1: BytesV Input (Primary Path)**
When a `BytesV` is provided, the function directly extracts both the numeric value and byte length:
```ocaml
| BytesV {num; len} -> Ok (num, len)
```
The `BytesV` already contains the length information, so no type inference is needed.

**Case 2: NumV Input (Fallback Path)**
When a `NumV` is provided (which can occur during elaboration when bytes types are represented as integers), the function:
1. Extracts the numeric value from `NumV`
2. Infers the byte length from the type annotation using `bytes_len_of_targ`
3. Validates that the value fits within the inferred byte length

#### 4.1.3 Big-Endian Byte Conversion

The `bytesv_to_raw` helper function converts a `Bigint.t` value to raw bytes using big-endian encoding:

```ocaml
let bytesv_to_raw (num: Bigint.t) (len: int) : Bytes.t =
  let out = Bytes.create len in
  let rec put i v =
    if i >= 0 then (
      let byte = Bigint.(to_int_exn (bit_and v (of_int 0xff))) in
      Bytes.set out i (Stdlib.Char.chr byte);
      put (i-1) (Bigint.shift_right v 8)
    )
  in
  put (len-1) num; out
```

This function:
- Creates a byte array of the specified length
- Extracts bytes from the least significant byte (LSB) to most significant byte (MSB)
- Stores them in big-endian order (MSB at index 0, LSB at index len-1)

**Example**: For `num = 0x12345678` with `len = 4`:
- `out[0] = 0x12` (MSB)
- `out[1] = 0x34`
- `out[2] = 0x56`
- `out[3] = 0x78` (LSB)

#### 4.1.4 SHA-256 Computation and Ethereum Compatibility

The function uses `Digestif.SHA256`, which implements the standard SHA-256 algorithm (FIPS 180-4). Ethereum also uses standard SHA-256, ensuring full compatibility:

```ocaml
let h =
  let open Digestif.SHA256 in
  digest_bytes raw |> to_raw_string |> Bytes.of_string
```

- **Standard compliance**: SHA-256 is a cryptographic standard, and all compliant implementations produce identical results
- **Ethereum compatibility**: Ethereum's `keccak256` is used for hashing, but for SSZ and other parts of eth2spec, standard SHA-256 is used, which matches our implementation
- **Byte-level accuracy**: The function operates on raw bytes, ensuring bit-for-bit compatibility

#### 4.1.5 Detailed Example: Hashing a bytes32 Value

Consider hashing a `bytes32` value representing a Merkle root:

**Input**: `bytes32` value `0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef`

**Step 1: Value Representation**
- If input is `BytesV {num = 0x1234...cdef; len = 32}`:
  - Directly extract: `num = 0x1234...cdef`, `len = 32`
- If input is `NumV` with type annotation `bytes32`:
  - Extract numeric value: `num = 0x1234...cdef`
  - Infer length from type: `len = 32` (from `bytes_len_of_targ`)
  - Validate: `0x1234...cdef < 2^256` ✓

**Step 2: Big-Endian Byte Conversion**
```ocaml
let raw = bytesv_to_raw 0x1234...cdef 32
```
Result: 32-byte array:
```
[0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef]
```

**Step 3: SHA-256 Hash Computation**
```ocaml
let h = Digestif.SHA256.digest_bytes raw
```
The SHA-256 algorithm processes the 32-byte input and produces a 32-byte hash output. This is identical to what Ethereum's SHA-256 implementation would produce for the same input.

**Step 4: Result Conversion**
```ocaml
Ok (make_bytes ~num:(bigint_of_be_bytes h) ~len:32)
```
The 32-byte hash is converted back to a `Bigint.t` (big-endian interpretation) and wrapped in `BytesV` with length 32.

**Verification with Ethereum**:
If we compare this with Ethereum's implementation:
- Input: `0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef`
- Our SHA-256 output: `0x<32-byte-hash>`
- Ethereum SHA-256 output: `0x<32-byte-hash>` (identical)

Both implementations use the standard SHA-256 algorithm, so the results are bit-for-bit identical.

#### 4.1.6 Key Design Aspects

- **Type-driven length inference**: When a `NumV` is provided, the function extracts the byte length from the type annotation (`bytes_len_of_targ`)
- **Validation**: Ensures the numeric value fits within the specified byte length (e.g., `bytes32` values must be in [0, 2^256])
- **Big-endian encoding**: Converts integers to raw bytes using big-endian encoding, matching Ethereum's byte representation
- **Standard SHA-256**: Uses `Digestif.SHA256`, which implements the standard SHA-256 algorithm, ensuring compatibility with Ethereum
- **Result consistency**: Always returns a `BytesV` with length 32 (SHA-256 output is always 32 bytes)

### 4.2 Hash Tree Root Functions (`merkleImpl.ml`)

SSZ hash tree root computation is the core of Ethereum 2.0's serialization. The implementation handles various SSZ types:

#### 4.2.1 Basic Types

For basic types (uint8, uint32, uint64), values are packed into 32-byte chunks using little-endian encoding:

```ocaml
let leaf_uint_le (n: Bigint.t) ~(nbytes:int) : Bytes.t =
  let c = Bytes.make 32 '\x00' in
  let v = ref n in
  for i = 0 to nbytes - 1 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set c i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
  c
```

#### 4.2.2 Bytes Types

For bytes types (bytes32, bytes48, bytes96, etc.), the implementation converts `BytesV` to raw bytes:

```ocaml
let to_b32_exn ~at (rv: Value.t) : (Bytes.t, Err.t) result =
  match rv.it with
  | NumV n -> Ok (leaf_bytes32 (Num.to_int n))
  | BytesV { num; len } ->
      if len <> 32 then
        Error (Err.runtime at "to_b32_exn: BytesV length must be 32")
      else
        Ok (leaf_bytes32 num)
  | _ -> Error (Err.runtime at "expected NumV or BytesV (32-byte root)")
```

The `be_of_bigint_fixed` helper converts `Bigint.t` to raw bytes:

```ocaml
let be_of_bigint_fixed (n: Bigint.t) ~(len:int) : Bytes.t =
  if Bigint.(n < zero) then invalid_arg "negative";
  let out = Bytes.create len in
  let rec fill i v =
    if i < 0 then ()
    else (
      let byte = Bigint.to_int_exn Bigint.(v % of_int 256) in
      Bytes.set out i (Char.chr byte);
      fill (i - 1) Bigint.(v / of_int 256)
    )
  in
  fill (len - 1) n;
  out
```

#### 4.2.3 Composite Types

For composite types (containers, lists, vectors), the implementation follows the SSZ (Simple Serialize) specification exactly. The process involves:

1. **Recursive hash tree root computation**: Each field/element is recursively converted to its hash tree root
2. **32-byte conversion**: Each root is converted to a 32-byte `Bytes.t` representation
3. **Merkleization**: The roots are merkleized using SSZ's merkle tree algorithm

This implementation strictly adheres to the SSZ specification used in Ethereum 2.0, ensuring bit-for-bit compatibility with the Python reference implementation (`eth2spec`).

#### 4.2.4 SSZ Merkleization Algorithm: `merkleize_chunks_with_limit`

The core of SSZ hash tree root computation is the `merkleize_chunks_with_limit` function, which implements the SSZ merkleization algorithm as specified in the Ethereum 2.0 consensus specification. This function is a direct translation of the Python reference implementation, ensuring complete compatibility.

**Function Signature:**
```ocaml
let merkleize_chunks_with_limit (leaves: Bytes.t array) (limit: int) : Bytes.t
```

**Parameters:**
- `leaves`: Array of 32-byte chunks (each representing a field/element root)
- `limit`: Maximum number of chunks (for Vector: `limit = count`, for List: `limit` is the maximum length)

**SSZ Specification Compliance:**

The implementation follows the SSZ specification's merkleization rules:

1. **Power-of-2 Padding**: SSZ requires that the number of chunks be padded to the next power of 2 using zero hashes
2. **Depth Calculation**: `depth = max(count - 1, 0).bit_length()` for actual chunks, `max_depth = (limit - 1).bit_length()` for limit
3. **Incremental Merge**: Uses an incremental merge algorithm that processes leaves one by one, building the tree bottom-up

**Implementation Details:**

```ocaml
let merkleize_chunks_with_limit (leaves: Bytes.t array) (limit: int) : Bytes.t =
  let n = Array.length leaves in
  if limit = 0 then zero32
  else if n = 0 then (
    (* Empty list: return ZERO_HASHES[max_depth] per SSZ spec *)
    let max_depth = if limit <= 1 then 0 else bit_length_of (limit - 1) in
    let zero_hashes = compute_zero_hashes ~max_depth:max_depth in
    zero_hashes.(max_depth)
  )
  else
    let count = n in
    (* SSZ spec: depth = max(count - 1, 0).bit_length() *)
    let depth = if count = 0 then 0 else bit_length_of (count - 1) in
    (* SSZ spec: max_depth = (limit - 1).bit_length() *)
    let max_depth = if limit = 0 then 0 else bit_length_of (limit - 1) in
    (* Temporary array for intermediate nodes (matches Python implementation) *)
    let tmp = Array.make (max_depth + 1) None in
    let zero_hashes = compute_zero_hashes ~max_depth:max_depth in
    
    (* Incremental merge algorithm (matches Python's merge function) *)
    let merge (h: Bytes.t) (i: int) : unit =
      let h = ref h in
      let j = ref 0 in
      let should_break = ref false in
      while not !should_break do
        let bit_mask = 1 lsl !j in
        let bit_set = i land bit_mask in
        if bit_set = 0 then (
          (* i & (1 << j) == 0: complement with zero hash if needed *)
          if i = count && !j < depth then (
            (* SSZ spec: complement to next power of 2 *)
            h := merkle_hash_ !h zero_hashes.(!j)
          ) else (
            should_break := true
          )
        ) else (
          (* i & (1 << j) != 0: merge with previous node *)
          match tmp.(!j) with
          | None -> invalid_arg "tmp[j] is None"
          | Some prev -> h := merkle_hash_ prev !h
        );
        if not !should_break then j := !j + 1
      done;
      tmp.(!j) <- Some !h
    in
    
    (* Process each leaf incrementally (SSZ spec requirement) *)
    for i = 0 to count - 1 do
      merge leaves.(i) i
    done;
    
    (* Complement with zero if not power of 2 (SSZ spec) *)
    if (1 lsl depth) <> count then (
      merge zero_hashes.(0) count
    );
    
    (* Lift to max_depth using zero hashes (SSZ spec for List types) *)
    if depth <= max_depth - 1 then (
      for j = depth to max_depth - 1 do
        let prev = match tmp.(j) with
          | None -> invalid_arg "tmp[j] is None during lift"
          | Some h -> h
        in
        tmp.(j + 1) <- Some (merkle_hash_ prev zero_hashes.(j))
      done
    );
    
    (* Return final root *)
    match tmp.(max_depth) with
    | None -> invalid_arg "tmp[max_depth] is None"
    | Some h -> h
```

**Key SSZ Rules Implemented:**

1. **Zero Hash Precomputation**: 
   ```ocaml
   let compute_zero_hashes ~max_depth : Bytes.t array =
     let arr = Array.make (max_depth + 1) zero32 in
     for h = 0 to max_depth - 1 do
       arr.(h + 1) <- merkle_hash_ arr.(h) arr.(h)
     done;
     arr
   ```
   Precomputes zero hashes for each depth level, matching SSZ spec: `ZERO_HASHES[h+1] = H(ZERO_HASHES[h], ZERO_HASHES[h])`

2. **Bit Manipulation for Tree Structure**: 
   The algorithm uses the binary representation of the index `i` to determine the tree path, exactly as specified in SSZ

3. **Power-of-2 Complement**: 
   When the count is not a power of 2, the algorithm complements with zero hashes to reach the next power of 2

4. **Limit-based Lifting**: 
   For List types with large limits, the algorithm "lifts" the tree to `max_depth` using zero hashes, implementing virtual padding

**Example: Merkleizing 5 Chunks (Vector)**

Consider a Vector with 5 elements (e.g., `BeaconBlockHeader` with 5 fields):

- Input: 5 chunks (32 bytes each)
- `count = 5`, `limit = 5` (Vector: limit = count)
- `depth = bit_length(5-1) = bit_length(4) = 3` (need 8 = 2³ leaves)
- `max_depth = bit_length(5-1) = 3`

Process:
1. Process leaves 0-4 incrementally using `merge`
2. Complement with 3 zero hashes to reach 8 leaves (power of 2)
3. Build tree: 4 pairs → 2 nodes → 1 root
4. Result: Single 32-byte root

**Example: Merkleizing List with Large Limit**

For a List with 3 elements but limit = 1,000,000:

- Input: 3 chunks
- `count = 3`, `limit = 1,000,000`
- `depth = bit_length(3-1) = 2` (need 4 = 2² leaves)
- `max_depth = bit_length(1,000,000-1) ≈ 20`

Process:
1. Process 3 leaves, complement to 4 (power of 2)
2. Build tree to depth 2
3. "Lift" from depth 2 to depth 20 using zero hashes (virtual padding)
4. Result: Root at depth 20, representing a tree that could hold up to 1,000,000 elements

This virtual padding approach is memory-efficient: instead of allocating 1,000,000 zero chunks, we use precomputed zero hashes to "lift" the tree.

#### 4.2.5 Length Mixing for List Types: `mix_in_length`

SSZ specification requires that all List types mix in the actual length information:

```ocaml
let mix_in_length (root: Bytes.t) (len: Bigint.t) : Bytes.t =
  let le32 = Bytes.make 32 '\x00' in
  let v = ref len in
  (* Encode length as little-endian uint256 *)
  for i = 0 to 31 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set le32 i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
  (* SSZ spec: H(root || length) *)
  merkle_hash_ root le32
```

**SSZ Rule**: For List types, the final root is `H(merkle_root || length)`, where:
- `merkle_root`: Root of the merkleized chunks (with limit-based padding)
- `length`: Actual number of elements, encoded as little-endian uint256

This ensures that lists with the same elements but different lengths produce different roots, which is crucial for SSZ's serialization guarantees.

**Example**: 
- List with 3 elements: `H(merkle_root_of_3_chunks || 3)`
- List with 5 elements (same first 3): `H(merkle_root_of_5_chunks || 5)`

Even if the first 3 elements are identical, the roots differ because:
1. The merkle roots differ (different padding)
2. The length values differ (3 vs 5)

#### 4.2.6 Verification Against eth2spec

Our implementation has been verified against the Python `eth2spec` reference implementation:

1. **Algorithm Compatibility**: The `merkleize_chunks_with_limit` function is a direct translation of Python's `merkleize_chunks`, ensuring identical behavior

2. **Test Suite Validation**: We run the official Ethereum 2.0 test suite, comparing our hash tree roots with Python `eth2spec` outputs, achieving bit-for-bit matching

3. **SSZ Specification Compliance**: All SSZ rules are strictly followed:
   - Power-of-2 padding ✓
   - Zero hash computation ✓
   - Length mixing for Lists ✓
   - Virtual padding for large limits ✓
   - Little-endian encoding for basic types ✓
   - Big-endian encoding for bytes types ✓

This ensures that our implementation produces identical results to the Ethereum 2.0 consensus specification.

#### 4.2.7 Detailed Example: `hash_tree_root_beaconBlockHeader`

To illustrate how hash tree root computation works, we examine the `hash_tree_root_beaconBlockHeader` function, which computes the SSZ hash tree root of a `BeaconBlockHeader` container.

**Input Structure:**
A `BeaconBlockHeader` contains five fields:
- `slot: uint64` (8 bytes)
- `proposer_index: uint64` (8 bytes)
- `parent_root: bytes32` (32 bytes)
- `state_root: bytes32` (32 bytes)
- `body_root: bytes32` (32 bytes)

**Step 1: Value Extraction and Validation**

The function first extracts values from the input `Value.t` structure, handling multiple representation formats (StructV, TupleV, ListV):

```ocaml
let* (slot, proposer_index, parent_root, state_root, body_root) =
  match hdr.it with
  | StructV [ (_ , slot_v); (_, proposer_v); (_, parent_v); (_, state_v); (_, body_v) ] ->
      Ok (get_nat slot_v, get_nat proposer_v, get_nat parent_v, get_nat state_v, get_nat body_v)
  | TupleV [slot_v; proposer_v; parent_v; state_v; body_v] ->
      Ok (get_nat slot_v, get_nat proposer_v, get_nat parent_v, get_nat state_v, get_nat body_v)
  | ListV [slot_v; proposer_v; parent_v; state_v; body_v] ->
      Ok (get_nat slot_v, get_nat proposer_v, get_nat parent_v, get_nat state_v, get_nat body_v)
  | _ -> Error (Err.runtime at "beaconBlockHeader: unexpected value shape")
```

Each value is validated to ensure it fits within its byte length constraint:
- `slot` and `proposer_index` must fit in 8 bytes (uint64 range)
- `parent_root`, `state_root`, and `body_root` must fit in 32 bytes (bytes32 range)

**Step 2: Field Root Computation**

Each field is converted to a 32-byte leaf node according to SSZ rules:

```ocaml
let leaves = [|
  leaf_uint_le slot ~nbytes:8;           (* uint64 → 32B leaf (LE packed, right-padded) *)
  leaf_uint_le proposer_index ~nbytes:8; (* uint64 → 32B leaf (LE packed, right-padded) *)
  leaf_bytes32 parent_root;              (* bytes32 → 32B leaf (direct) *)
  leaf_bytes32 state_root;                (* bytes32 → 32B leaf (direct) *)
  leaf_bytes32 body_root;                 (* bytes32 → 32B leaf (direct) *)
|]
```

- **uint64 fields** (`slot`, `proposer_index`): Packed as little-endian in the first 8 bytes, with remaining 24 bytes zero-padded
- **bytes32 fields** (`parent_root`, `state_root`, `body_root`): Already 32 bytes, used directly as leaf nodes

**Step 3: Merkleization**

The five 32-byte leaves are merkleized using `merkleize_vector_roots`:

```ocaml
let root_bytes = merkleize_vector_roots leaves
```

For a Vector with 5 elements, the merkleization process:
1. Creates a binary Merkle tree with the 5 leaves
2. Pads to the next power of 2 (8) using zero hashes
3. Computes parent nodes by hashing pairs: `H(left || right)`
4. Continues until a single root is obtained

The merkleization algorithm (`merkleize_chunks_with_limit`) uses an incremental merge approach:
- Processes leaves one by one, maintaining a temporary array `tmp` for intermediate nodes
- Uses bit manipulation to determine tree structure (index `i`'s binary representation determines path)
- Complements with zero hashes when needed to reach power-of-2 boundaries

**Step 4: Result Conversion**

The final 32-byte root is converted back to `BytesV`:

```ocaml
Ok (make_bytes ~num:(bigint_of_be_bytes root_bytes) ~len:32)
```

**Complete Example Flow:**

Consider a `BeaconBlockHeader` with:
- `slot = 1000` (uint64)
- `proposer_index = 42` (uint64)
- `parent_root = 0x1234...` (bytes32)
- `state_root = 0x5678...` (bytes32)
- `body_root = 0x9abc...` (bytes32)

1. **Field roots** (32 bytes each):
   - `slot`: `[0xe8 0x03 0x00 ... 0x00]` (1000 in LE, 24 zero bytes)
   - `proposer_index`: `[0x2a 0x00 0x00 ... 0x00]` (42 in LE, 24 zero bytes)
   - `parent_root`: `[0x12 0x34 ...]` (32 bytes directly)
   - `state_root`: `[0x56 0x78 ...]` (32 bytes directly)
   - `body_root`: `[0x9a 0xbc ...]` (32 bytes directly)

2. **Merkle tree construction**:
   ```
   Level 2:                    [Root]
                              /      \
   Level 1:            [H01]          [H23]
                      /    \          /    \
   Level 0:        [H0]    [H1]    [H2]    [H3]
                  /  \    /  \    /  \    /  \
   Leaves:    [L0][L1][L2][L3][L4][Z][Z][Z]
              slot prop parent state body zero zero zero
   ```
   Where:
   - `L0` = leaf for `slot`
   - `L1` = leaf for `proposer_index`
   - `L2` = leaf for `parent_root`
   - `L3` = leaf for `state_root`
   - `L4` = leaf for `body_root`
   - `Z` = zero hash (for padding to 8 leaves)
   - `H0` = `H(L0 || L1)`, `H1` = `H(L2 || L3)`, etc.
   - `H01` = `H(H0 || H1)`, `H23` = `H(H2 || H3)`
   - `Root` = `H(H01 || H23)`

3. **Final result**: A single 32-byte `BytesV` representing the hash tree root

This root is used throughout eth2spec for:
- Block identification and linking
- State root validation
- Signature verification (signing roots)
- Merkle proof generation

The same pattern applies to all composite types: each field/element is recursively converted to a 32-byte root, then these roots are merkleized according to SSZ rules.

### 4.3 Bytes Manipulation Functions (`bytes.ml`)

The `bytes.ml` module provides utility functions for bytes operations required by eth2spec. These functions enable Spectec to perform byte-level manipulations that are essential for Ethereum 2.0 consensus operations, such as domain construction, withdrawal credential handling, and byte extraction.

All functions in this module:
1. Accept `BytesV` or `NumV` inputs (handling both representations)
2. Validate byte length constraints (ensuring values fit within their byte ranges)
3. Perform operations on the underlying `Bigint.t` representation (preserving big-endian semantics)
4. Return `BytesV` with appropriate length information (maintaining type safety)

#### 4.3.1 Conversion Functions

These functions convert between different byte representations and numeric types, following eth2spec's encoding rules.

##### TODO.....

