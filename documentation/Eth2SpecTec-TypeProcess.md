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

To solve this problem, we introduce `BytesV`, a runtime value type that preserves both the numeric value and the byte length. In the IL (Intermediate Language) value system, `BytesV` is defined as part of the `value'` type:

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

The `Il.Value` module provides operations to create and manipulate `BytesV` values:

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
let hash_ ~at (typ : targ) (v: Il.Value.t) : (Il.Value.t, Err.t) result =
  let* (num, len) =
    match v.it with
    | BytesV {num; len} -> Ok (num, len)
    | NumV _ ->
        let num_bigint = Il.Value.get_num v |> Num.to_int in
        (match bytes_len_of_targ typ with
        | Some l ->
            let* () = validate_fits_len ~at num_bigint l in
            Ok (num_bigint, l)
        | None ->
            Error (Err.runtime at "hash_<X>: cannot infer byte length from type"))
    | _ -> Error (Err.runtime at "hash_<X>: expected bytes or NumV")
  in
  let raw = bytesv_to_raw num len in 
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
1. Extracts the numeric value from `NumV` using `Il.Value.get_num`
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
    let max_depth = if limit <= 1 then 0 else bit_length_of (limit - 1) in
    let zero_hashes = compute_zero_hashes ~max_depth:max_depth in
    zero_hashes.(max_depth)
  )
  else
    let count = n in
    let depth = if count = 0 then 0 else bit_length_of (count - 1) in
    let max_depth = if limit = 0 then 0 else bit_length_of (limit - 1) in
    let tmp = Array.make (max_depth + 1) None in
    let zero_hashes = compute_zero_hashes ~max_depth:max_depth in
    let merge (h: Bytes.t) (i: int) : unit =
      let h = ref h in
      let j = ref 0 in
      let should_break = ref false in
      while not !should_break do
        let bit_mask = 1 lsl !j in
        let bit_set = i land bit_mask in
        if bit_set = 0 then (
          if i = count && !j < depth then (
            h := merkle_hash_ !h zero_hashes.(!j)
          ) else (
            should_break := true
          )
        ) else (
          match tmp.(!j) with
          | None -> invalid_arg (Printf.sprintf "merkleize_chunks_with_limit: tmp[%d] is None when i=%d, j=%d" !j i !j)
          | Some prev -> h := merkle_hash_ prev !h
        );
        if not !should_break then j := !j + 1
      done;
      tmp.(!j) <- Some !h
    in
    for i = 0 to count - 1 do
      merge leaves.(i) i
    done;
    if (1 lsl depth) <> count then (
      merge zero_hashes.(0) count
    );
    if depth <= max_depth - 1 then (
      for j = depth to max_depth - 1 do
        let prev = match tmp.(j) with
          | None -> invalid_arg (Printf.sprintf "merkleize_chunks_with_limit: tmp[%d] is None during lift" j)
          | Some h -> h
        in
        tmp.(j + 1) <- Some (merkle_hash_ prev zero_hashes.(j))
      done
    );
    let final = match tmp.(max_depth) with
      | None -> invalid_arg (Printf.sprintf "merkleize_chunks_with_limit: tmp[%d] is None after lift" max_depth)
    | Some h -> h
    in
    final
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
  for i = 0 to 31 do
    let b = Bigint.to_int_exn Bigint.(bit_and !v (of_int 0xff)) in
    Bytes.set le32 i (Stdlib.Char.chr b);
    v := Bigint.shift_right !v 8
  done;
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

### 4.3 BLS Signature Verification Functions (`blsImpl.ml`)

The `blsImpl.ml` module implements BLS (Boneh-Lynn-Shacham) signature verification functions required by eth2spec. BLS signatures are essential for Ethereum 2.0 consensus operations, including block proposal verification, attestation validation, and validator exit processing and so on.

**Library Selection and Ethereum 2.0 Compatibility:**

Ethereum 2.0 uses the BLS signature scheme `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` as specified in the [IETF BLS signature draft (Section 3.3)](https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-bls-signature-04#section-3.3). To implement this scheme in OCaml, we use the [`bls12-381-signature`](https://ocaml.org/p/bls12-381-signature/1.0.0) library, which provides the `Bls12_381_signature.MinPk.Pop.verify` function that implements the Proof of Possession (POP) variant of BLS signatures. This library choice ensures that our implementation matches Ethereum 2.0's exact cryptographic requirements and maintains compatibility with the `eth2spec` Python reference implementation.

All functions in this module:
1. Accept `Num.t` inputs representing bytes types (`blsPubkey`, `blsSignature`, `root`)
2. Validate byte length constraints (48 bytes for public keys, 96 bytes for signatures, 32 bytes for roots)
3. Convert big-endian integer representations to raw bytes
4. Use the `Bls12_381_signature` library for cryptographic operations
5. Return boolean results for verification operations or `BytesV` for aggregation operations

Note : We do not override the default ciphersuite in bls12-381-signature library

#### 4.3.1 Single Signature Verification: `bls_verify`

The `$bls_verify` function verifies a single BLS signature against a public key and message root. This is the fundamental building block for all BLS signature verification in eth2spec.

**Function Signature:**
```spectec
dec $bls_verify(blsPubkey, root, blsSignature) : boolean
```

**Implementation:**
```ocaml
let bls_verify ~at (bls_pubkey : Num.t) (root : Num.t) (bls_signature : Num.t)
  : (Value.t, Err.t) result =
  let bls_pubkey = Num.to_int bls_pubkey in
  let root = Num.to_int root in
  let bls_signature = Num.to_int bls_signature in
  let* () = ensure_fits_bytes ~at bls_pubkey ~len:48 in
  let* () = ensure_fits_bytes ~at bls_signature ~len:96 in
  let* () = ensure_fits_bytes ~at root ~len:32 in
  let pk_bytes   = be_of_bigint_fixed bls_pubkey ~len:48 in
  let sig_bytes  = be_of_bigint_fixed bls_signature ~len:96 in
  let msg_bytes  = be_of_bigint_fixed root         ~len:32 in

  match Bls12_381_signature.MinPk.pk_of_bytes_opt pk_bytes with
  | None -> Ok (Value.bool false)
  | Some pk ->
    begin match Bls12_381_signature.MinPk.signature_of_bytes_opt sig_bytes with
    | None -> Ok (Value.bool false)
    | Some signature ->
      let ok = Bls12_381_signature.MinPk.Pop.verify pk msg_bytes signature in
      Ok (Value.bool ok)
    end
```

**Why This Design:**

1. **Input Validation**: The function validates that each input fits within its byte length constraint:
   - `blsPubkey`: Must be in range [0, 2^384] (48 bytes)
   - `blsSignature`: Must be in range [0, 2^768] (96 bytes)
   - `root`: Must be in range [0, 2^256] (32 bytes)

2. **Big-Endian Conversion**: All inputs are stored as big-endian integers in `Bigint.t`, so they must be converted to raw bytes using `be_of_bigint_fixed`:
   - `pk_bytes`: 48-byte compressed public key (G1 point)
   - `sig_bytes`: 96-byte compressed signature (G2 point)
   - `msg_bytes`: 32-byte message root (hash tree root)

3. **Error Handling and Security Checks**: The function returns `false` (not an error) if:
   - The public key is invalid (cannot be decoded from bytes)
   - The signature is invalid (cannot be decoded from bytes)
   - The signature verification fails
   
   The library's `*_of_bytes_opt` functions perform strict decoding that rejects invalid encodings, points at infinity, and non-subgroup elements, ensuring subgroup-secure verification required by the Ethereum consensus. The library internally applies the scheme's domain separation tag (DST) and POP rules as specified in the BLS signature standard.

4. **BLS12-381 Compatibility with Proof of Possession (POP)**: This function uses `Bls12_381_signature.MinPk.Pop.verify` from the OCaml `bls12-381-signature` library, which corresponds to `bls.Verify` in the Ethereum consensus specification. Since Ethereum 2.0 uses the `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` scheme, we use the POP variant implementation provided by this library to ensure compatibility with `eth2spec`'s Python reference implementation. The library internally applies the scheme's domain separation tag (DST) for hash-to-curve operations and POP rules for rogue-key attack resistance.

**Detailed Example: Verifying a Block Proposal Signature**

Consider verifying a block proposal signature in `Process_block_header`:

**Input Values:**
- `blsPubkey = 0x1234...` (48 bytes, validator's public key)
- `root = 0x5678...` (32 bytes, signing root of the block header)
- `blsSignature = 0x9abc...` (96 bytes, signature on the signing root)

**Step 1: Input Validation**
```ocaml
let* () = ensure_fits_bytes ~at bls_pubkey ~len:48 in  (* 0 ≤ x < 2^(8·48) ✓ *)
let* () = ensure_fits_bytes ~at root ~len:32 in        (* 0 ≤ x < 2^(8·32) ✓ *)
let* () = ensure_fits_bytes ~at bls_signature ~len:96 in (* 0 ≤ x < 2^(8·96) ✓ *)
```

**Step 2: Big-Endian Byte Conversion**
```ocaml
let pk_bytes = be_of_bigint_fixed bls_pubkey ~len:48
let msg_bytes = be_of_bigint_fixed root ~len:32
let sig_bytes = be_of_bigint_fixed bls_signature ~len:96
```

Result: Three byte arrays:
- `pk_bytes`: `[0x12, 0x34, ...]` (48 bytes, compressed G1 point)
- `msg_bytes`: `[0x56, 0x78, ...]` (32 bytes, message)
- `sig_bytes`: `[0x9a, 0xbc, ...]` (96 bytes, compressed G2 point)

**Step 3: BLS Type Conversion**
```ocaml
match Bls12_381_signature.MinPk.pk_of_bytes_opt pk_bytes with
| None -> Ok (Value.bool false)  (* Invalid public key *)
| Some pk -> ...
```

The `pk_of_bytes_opt` function attempts to decode the 48-byte compressed public key into a G1 point. If decoding fails (e.g., invalid point encoding), the function returns `None` and verification fails.

**Step 4: Signature Verification**
```ocaml
let ok = Bls12_381_signature.MinPk.Pop.verify pk msg_bytes signature
```

The `Pop.verify` function from the `bls12-381-signature` library performs BLS signature verification using the POP variant, matching Ethereum 2.0's `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` scheme. This ensures our results match `eth2spec`'s Python implementation.

Returns `true` if the signature is valid, `false` otherwise.

**Step 5: Result**
```ocaml
Ok (Value.bool ok)
```

Returns `true` if the signature is valid, `false` otherwise.

**Example Usages in eth2spec:**

This function is used throughout eth2spec for:
- Block proposal verification: `$bls_verify(validator_proposer.PUBKEY, root_signing, body_beaconBlockBody.RANDAO_REVEAL)`
- Attestation verification: `$bls_verify(blsPubkey_pk, root_sign, blsSignature_sig)`
- Voluntary exit verification: `$bls_verify(validator.PUBKEY, root_vol_exit_signing_root, signedVoluntaryExit.SIGNATURE)`
- BLS to execution change verification: `$bls_verify(blsToExecutionChange.FROM_BLS_PUBKEY, root_sign, signedBlsToExecutionChange.SIGNATURE)`

#### 4.3.2 Public Key Aggregation: `eth_aggregate_pubkeys`

The `$eth_aggregate_pubkeys` function aggregates multiple BLS public keys into a single aggregated public key. This corresponds to the public key aggregation operation (G1 point addition) used in the Ethereum consensus specification. This is used for efficient batch signature verification when multiple validators sign the same message (FastAggregateVerify scenario).

**Function Signature:**
```spectec
dec $eth_aggregate_pubkeys(blsPubkey*) : blsPubkey
```

**Implementation:**
```ocaml
let eth_aggregate_pubkeys ~at (pubkeys_num : Num.t list)
  : (Value.t, Err.t) result =
  let pubkeys_int = List.map Num.to_int pubkeys_num in
  let conv_one n =
    let* () = ensure_fits_bytes ~at n ~len:48 in
    let b = be_of_bigint_fixed n ~len:48 in
    match Bls12_381.G1.of_compressed_bytes_opt b with
    | None -> Error (Err.runtime at "eth_aggregate_pubkeys: invalid G1 pubkey (bytes48)")
    | Some p -> Ok p
  in
  let rec mapM f = function
    | [] -> Ok []
    | x::xs -> let* y = f x in let* ys = mapM f xs in Ok (y::ys)
  in
  let* points = mapM conv_one pubkeys_int in

  let agg =
    List.fold_left Bls12_381.G1.add Bls12_381.G1.zero points
  in

  let out_b = Bls12_381.G1.to_compressed_bytes agg in
  let out_n = bigint_of_be_bytes out_b in
  Ok (make_bytes ~num:out_n ~len:48)
```

**Why This Design:**

1. **Point Conversion and Error Handling**: Each public key (48 bytes) is converted to a G1 point using `Bls12_381.G1.of_compressed_bytes_opt`. If any public key is invalid (invalid encoding, point at infinity, or non-subgroup element), the function returns an error. This strict error handling at the API boundary ensures validity guarantees and facilitates debugging, in contrast to verification routines that return `false` for consensus-friendly behavior.

2. **Elliptic Curve Addition**: The aggregated public key is computed by adding all G1 points together:
   ```ocaml
   let agg = List.fold_left Bls12_381.G1.add Bls12_381.G1.zero points
   ```
   This uses the group operation on the elliptic curve: `agg = pk0 + pk1 + ... + pkN`.

3. **Result Serialization**: The aggregated G1 point is compressed back to 48 bytes and converted to `BytesV`:
   ```ocaml
   let out_b = Bls12_381.G1.to_compressed_bytes agg in
   let out_n = bigint_of_be_bytes out_b in
   Ok (make_bytes ~num:out_n ~len:48)
   ```

**Mathematical Foundation:**

BLS signatures support aggregation when multiple signers sign the same message: if `sig = sig0 + sig1 + ... + sigN` (where each `sig_i` is a signature on the same message) and `pk = pk0 + pk1 + ... + pkN`, then verifying the aggregated signature `sig` against the aggregated public key `pk` is equivalent to verifying all individual signatures. This property enables efficient batch verification through FastAggregateVerify (as specified in the [IETF BLS signature draft](https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-bls-signature-04)). For different messages, the AggregateVerify procedure must be used instead.

**Example: Aggregating Three Public Keys**

**Input**: List of three public keys:
- `pk0 = 0x1234...` (48 bytes)
- `pk1 = 0x5678...` (48 bytes)
- `pk2 = 0x9abc...` (48 bytes)

**Step 1: Convert to G1 Points**
```ocaml
let points = [G1_point0, G1_point1, G1_point2]
```

**Step 2: Aggregate Using Elliptic Curve Addition**
```ocaml
let agg = G1.zero + G1_point0 + G1_point1 + G1_point2
```

**Step 3: Compress and Return**
```ocaml
let out_b = Bls12_381.G1.to_compressed_bytes agg
let out_n = bigint_of_be_bytes out_b
Ok (make_bytes ~num:out_n ~len:48)
```

Result: `agg_pk = 0x<48-byte-compressed-G1-point>`

**Usage in eth2spec:**

This function is used when aggregating multiple validators' public keys for batch verification, particularly in attestation processing.

#### 4.3.3 Fast Aggregate Verification: `bls_fast_aggregate_verify`

The `$bls_fast_aggregate_verify` function verifies an aggregated BLS signature against a list of public keys and a single message. This corresponds to `FastAggregateVerify` in the Ethereum consensus specification and implements the FastAggregateVerify procedure from the IETF BLS signature standard, which applies when multiple validators have signed the same message. In FastAggregateVerify (same-message case), verification reduces to a single pairing-style check against the aggregated public key, enabling near-constant verification cost with respect to the number of signers (typically one pairing computation, though implementation optimizations may affect constant factors).

**Function Signature:**
```spectec
dec $bls_fast_aggregate_verify(blsPubkey*, root, blsSignature) : boolean
```

**Implementation:**
```ocaml
let bls_fast_aggregate_verify
    ~at
    (pubkeys_num : Num.t list)
    (root       : Num.t)
    (sig_num    : Num.t)
  : (Value.t, Err.t) result =
  if List.length pubkeys_num = 0 then
    Ok (Value.bool false)
  else (
    let pubkeys_int = List.map Num.to_int pubkeys_num in
    let root = Num.to_int root in
    let sig_int = Num.to_int sig_num in
    let* () = ensure_fits_bytes ~at root    ~len:32 in
    let* () = ensure_fits_bytes ~at sig_int ~len:96 in

    let msg_bytes = be_of_bigint_fixed root    ~len:32 in
    let sig_bytes = be_of_bigint_fixed sig_int ~len:96 in

    let rec mapM f = function
      | [] -> Ok []
      | x::xs ->
        let* y  = f x in
        let* ys = mapM f xs in
        Ok (y::ys)
    in
    let conv_pk (n:Bigint.t) =
      let* () = ensure_fits_bytes ~at n ~len:48 in
      let b = be_of_bigint_fixed n ~len:48 in
      match Bls12_381.G1.of_compressed_bytes_opt b with
      | None   -> Ok None
      | Some p -> Ok (Some p)
    in
    let* points_opt = mapM conv_pk pubkeys_int in
    if List.exists (fun o -> o = None) points_opt
    then Ok (Value.bool false)
    else
      let points = List.map Option.get points_opt in

      let agg = List.fold_left Bls12_381.G1.add Bls12_381.G1.zero points in
      let agg_pk_bytes = Bls12_381.G1.to_compressed_bytes agg in

      match Bls12_381_signature.MinPk.signature_of_bytes_opt sig_bytes with
      | None -> Ok (Value.bool false)
      | Some signature ->
        match Bls12_381_signature.MinPk.pk_of_bytes_opt agg_pk_bytes with
        | None -> Ok (Value.bool false)
        | Some pk ->
          let ok = Bls12_381_signature.MinPk.Pop.verify pk msg_bytes signature in
          Ok (Value.bool ok)
    )
```

**Why This Design:**

1. **Empty List Handling**: If the public key list is empty, the function immediately returns `false` (no signatures to verify).

2. **Tolerant Public Key Conversion**: Unlike `eth_aggregate_pubkeys`, this function tolerates invalid public keys by returning `None` instead of an error. If any public key is invalid, the function returns `false`:
   ```ocaml
   if List.exists (fun o -> o = None) points_opt
   then Ok (Value.bool false)
   ```
   This design difference reflects the different API boundaries: `eth_aggregate_pubkeys` uses strict error handling for validity guarantees and debugging convenience, while `bls_fast_aggregate_verify` returns `false` for consensus-friendly behavior that matches the Ethereum consensus specification's verification routines.

3. **Aggregation and Verification**: The function implements FastAggregateVerify, which applies when all validators have signed the same message:
   - Aggregates all public keys into a single G1 point
   - Verifies the aggregated signature (sum of individual signatures on the same message) against the aggregated public key and the single message
   - This is valid because BLS signatures on the same message can be aggregated: if `sig_sum = sig0 + sig1 + ... + sigN` and `pk_sum = pk0 + pk1 + ... + pkN`, then verifying `sig_sum` against `pk_sum` is equivalent to verifying all individual signatures

4. **Efficiency**: This is more efficient than verifying each signature individually because:
   - Only one pairing computation is needed (instead of N pairings)
   - The aggregated public key is computed once
   - Note: For different messages, the AggregateVerify procedure must be used instead

**Detailed Example: Verifying an Aggregated Attestation**

Consider verifying an attestation with multiple validators:

**Input Values:**
- `pubkeys = [pk0, pk1, pk2]` (list of 3 public keys, each 48 bytes)
- `root = 0x5678...` (32 bytes, attestation data root)
- `sig = 0x9abc...` (96 bytes, aggregated signature)

**Step 1: Input Validation**
```ocaml
let* () = ensure_fits_bytes ~at root ~len:32 in
let* () = ensure_fits_bytes ~at sig_int ~len:96 in
```

**Step 2: Convert Public Keys to G1 Points**
```ocaml
let points_opt = [Some G1_point0, Some G1_point1, Some G1_point2]
```

If any public key is invalid, `points_opt` contains `None` and verification fails.

**Step 3: Aggregate Public Keys**
```ocaml
let agg = G1.zero + G1_point0 + G1_point1 + G1_point2
let agg_pk_bytes = Bls12_381.G1.to_compressed_bytes agg
```

**Step 4: Verify Aggregated Signature**
```ocaml
let ok = Bls12_381_signature.MinPk.Pop.verify pk msg_bytes signature
```

This verifies that the aggregated signature is valid for the aggregated public key and message using the same `Pop.verify` function from the `bls12-381-signature` library, ensuring consistency with single signature verification and compatibility with `eth2spec`'s aggregated signature verification.

**Usage in eth2spec:**

This function is primarily used for attestation verification:
```spectec
if $bls_fast_aggregate_verify(blsPubkey_pk*, root_sign, indexedAttestation.SIGNATURE) = true
```

This allows verifying that multiple validators signed the same attestation data efficiently.

#### 4.3.4 Design Principles

All BLS signature verification functions follow these principles:

1. **Big-Endian Semantics**: All inputs are stored as big-endian integers and converted to raw bytes using `be_of_bigint_fixed`.

2. **Type Safety**: Functions validate that inputs fit within their byte length constraints before processing.

3. **Error Handling**: Functions return `false` (not errors) for invalid inputs or failed verification, matching eth2spec's behavior.

4. **BLS12-381 Compatibility with POP**: All functions use the `Bls12_381_signature.MinPk.Pop` module from the OCaml `bls12-381-signature` library. Since Ethereum 2.0 uses the `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` scheme, we use the POP variant implementation provided by this library to ensure compatibility with `eth2spec`'s Python reference implementation.

5. **Efficiency**: Aggregation functions enable efficient batch verification, reducing computational overhead for large validator sets.

These functions enable Spectec to perform all BLS signature verification operations required by eth2spec, ensuring compatibility with Ethereum 2.0's consensus layer cryptographic requirements.

### 4.4 Bytes Manipulation Functions (`bytes.ml`)

The `bytes.ml` module provides utility functions for bytes operations required by eth2spec. These functions enable Spectec to perform byte-level manipulations that are essential for Ethereum 2.0 consensus operations, such as domain construction, withdrawal credential handling, and byte extraction.

All functions in this module:
1. Accept `BytesV` or `NumV` inputs (handling both representations)
2. Validate byte length constraints (ensuring values fit within their byte ranges)
3. Perform operations on the underlying `Bigint.t` representation (preserving big-endian semantics)
4. Return `BytesV` with appropriate length information (maintaining type safety)

#### 4.4.1 Conversion Functions

These functions convert between different byte representations and numeric types, following eth2spec's encoding rules.

##### `bytes32_prefix8` and `bytes8_to_uint64_le`: Two-Step bytes32 to uint64 Conversion

To extract the leftmost 8 bytes of a `bytes32` and interpret them as a little-endian `uint64`, we use a two-step composition that provides better modularity and reuse:

**Step 1: `bytes32_prefix8` - Extract First 8 Bytes**

Extracts `x[0:8]` (the leftmost 8 bytes) from a `bytes32` value, returning a `bytes8` (BytesV with length 8).

**Implementation:**
```ocaml
let bytes32_prefix8 ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_bytes32 at x in
  (* Extract upper 8 bytes: x >> (24 * 8) *)
  let hi8 = Bigint.shift_right x (8 * 24) in
  (* hi8 is already in BE format, so just create bytes with len=8 *)
  Ok (make_bytes ~num:hi8 ~len:8)
```

**Why This Design:**
- **Bit shift extraction**: With big-endian-integer backing, extracting the leftmost 8 bytes is implemented as `x >> 192` (shifting right by 192 bits = 24 bytes)
- **Modular design**: Separates byte extraction from endianness conversion, enabling reuse

**Step 2: `bytes8_to_uint64_le` - Decode as Little-Endian**

Decodes an 8-byte value as little-endian `uint64`, matching Python's `int.from_bytes(x, 'little')` behavior.

**Implementation:**
```ocaml
let bytes8_to_uint64_le ~at (v : Value.t) : Value.t result =
  match v.it with
  | BytesV { num; len = 8 } ->
      let open Bigint in
      (* Extract each byte from BE representation *)
      (* num = b[0]*256^7 + b[1]*256^6 + ... + b[7]*256^0 (BE interpretation) *)
      (* We want LE interpretation: b[0] + b[1]*256 + ... + b[7]*256^7 *)
      let rec extract_byte i =
        if i >= 8 then []
        else
          let shift_bits = (7 - i) * 8 in
          let byte_val = bit_and (shift_right num shift_bits) (of_int 0xff) in
          byte_val :: extract_byte (i + 1)
      in
      let bytes = extract_byte 0 in
      (* LE interpretation: b[0] + b[1]*256 + ... + b[7]*256^7 *)
      let rec build_le_num i acc shift bytes_list =
        match bytes_list with
        | [] -> acc
        | byte_val :: rest ->
            build_le_num (i + 1)
              (acc + (byte_val * shift))
              (shift * of_int 256)
              rest
      in
      Ok (Value.nat (build_le_num 0 zero (of_int 1) bytes))
  | _ -> Error (runtime at "bytes8_to_uint64_le: expects 8-byte value")
```

**Why This Design:**
- **Big-endian to little-endian conversion**: The `BytesV` stores values as big-endian integers, so we extract bytes and re-interpret them in little-endian order
- **Accurate conversion**: Reconstructs the value using little-endian semantics: `byte[0] + byte[1]*256 + ... + byte[7]*256^7`
- **Reusable**: Can be used with any 8-byte value, not just the result of `bytes32_prefix8`

**Example:**

To extract the leftmost 8 bytes of a `bytes32` and interpret them as little-endian `uint64`, we compose the two functions:

- Input: `bytes32 = 0x00000000000000000000000000000000000000000000000000000000000003e8` (represents 1000 in big-endian, with value at the rightmost bytes)
- Step 1 (`bytes32_prefix8`): Extract `x[0:8]` → `bytes8 = 0x0000000000000000` (leftmost 8 bytes, all zeros)
- Step 2 (`bytes8_to_uint64_le`): Decode as LE → `uint64 = 0` (little-endian interpretation)

This matches Python's `int.from_bytes(x[:8], 'little')` behavior exactly. For values like 1000 that are stored in the rightmost bytes of a big-endian representation, reading the leftmost 8 bytes yields 0, which is the expected behavior.

This two-step approach replaces a monolithic `bytes_to_uint64` operator, providing better modularity and enabling reuse of the LE decoding logic for other 8-byte values.

##### `uint_to_bytes`: Automatic Length Detection

This function converts a `uint` value to `BytesV` with automatic length detection based on the value's range, mimicking Python's `encode_bytes()` behavior.

**Note**: This is a convenience helper and **not SSZ serialization**. SSZ uses fixed-width little-endian encoding (e.g., `uint64` → exactly 8 bytes). This function chooses a minimal length for convenience.

**Implementation:**
```ocaml
let uint_to_bytes ~at (uint_val : Num.t) : (Value.t, Err.t) result =
  let uint_val = Num.to_int uint_val in
  if Bigint.(uint_val < zero) then
    Error (Err.runtime at "uint_to_bytes: input must be non-negative")
  else
    (* Determine the appropriate uint type based on value range *)
    if Bigint.(uint_val < pow (of_int 2) (of_int 8)) then
      (* uint8 range: [0, 2^8) *)
      let* () = validate_uint8 at uint_val in
      Ok (make_bytes ~num:uint_val ~len:1)
    else if Bigint.(uint_val < pow (of_int 2) (of_int 32)) then
      (* uint32 range: [0, 2^32) *)
      let* () = validate_uint32 at uint_val in
      Ok (make_bytes ~num:uint_val ~len:4)
    else if Bigint.(uint_val < pow (of_int 2) (of_int 64)) then
      (* uint64 range: [0, 2^64) *)
      let* () = validate_uint64 at uint_val in
      Ok (make_bytes ~num:uint_val ~len:8)
    else
      Error (Err.runtime at "uint_to_bytes: value too large for uint8/uint32/uint64")
```

**Why This Design:**
- **Automatic sizing**: Chooses the minimal byte length that can represent the value
- **eth2spec compatibility**: Matches Python's behavior where uint types are encoded with minimal bytes
- **Type safety**: Validates that the value fits within the chosen type's range

**Example:**
- Input: `42` → Output: `BytesV {num = 42; len = 1}` (fits in uint8)
- Input: `1000` → Output: `BytesV {num = 1000; len = 4}` (fits in uint32)
- Input: `1000000000` → Output: `BytesV {num = 1000000000; len = 8}` (fits in uint64)

##### `bytes32_to_bytes` and `bytes4_to_bytes`: Type Conversion

These functions convert `bytes32` and `bytes4` values to `BytesV` representation, handling both `BytesV` and `NumV` inputs.

**Implementation:**
```ocaml
let bytes32_to_bytes ~at (value : Value.t) : Value.t result =
  match value.it with
  | BytesV { num = _; len = 32 } ->
      (* Already BytesV with correct length, just return it *)
      Ok value
  | BytesV { num; len = _ } ->
      (* BytesV with wrong length, validate and create new one *)
      let bytes32_val = num in
      let* () = validate_bytes32 at bytes32_val in
      Ok (make_bytes ~num:bytes32_val ~len:32)
  | NumV n ->
      (* NumV case: convert to BytesV *)
      let bytes32_val = Num.to_int n in
      let* () = validate_bytes32 at bytes32_val in
      Ok (make_bytes ~num:bytes32_val ~len:32)
  | _ -> Error (runtime at "bytes32_to_bytes: expected bytes32 or NumV")

let bytes4_to_bytes ~at (value : Value.t) : Value.t result =
  match value.it with
  | BytesV { num = _; len = 4 } ->
      Ok value
  | BytesV { num; len = _ } ->
      let bytes4_val = num in
      let* () = validate_bytes4 at bytes4_val in
      Ok (make_bytes ~num:bytes4_val ~len:4)
  | NumV n ->
      let bytes4_val = Num.to_int n in
      let* () = validate_bytes4 at bytes4_val in
      Ok (make_bytes ~num:bytes4_val ~len:4)
  | _ -> Error (runtime at "bytes4_to_bytes: expected bytes4 or NumV")
```

**Why This Design:**
- **Unified representation**: Ensures all `bytes32`/`bytes4` values are represented as `BytesV` with correct length
- **Type normalization**: Converts `NumV` to `BytesV` when needed, preserving the value
- **Validation**: Ensures the value fits within the appropriate byte range

##### Little-Endian Encoders: `uint8_to_bytes_le`, `uint32_to_bytes_le`, `uint64_to_bytes_le`

These functions encode unsigned integers as fixed-width little-endian byte sequences, used when constructing SSZ-compatible byte payloads for hashing and signing operations.

**Implementation:**
```ocaml
let make_bytes_le ~num ~(len : int) : Value.t =
  let open Bigint in
  (* Extract bytes in LE order: b0 (LSB from num), b1, ..., b_{len-1} (MSB from num) *)
  (* Extract LSB first: byte i = (num >> (i*8)) & 0xff *)
  (* When stored as BE num: b0 becomes MSB, b_{len-1} becomes LSB *)
  (* BE num = b0*256^{len-1} + b1*256^{len-2} + ... + b_{len-1}*256^0 *)
  let rec extract_and_build i bytes_list v =
    if i >= len then bytes_list
    else
      let shift_bits = i * 8 in
      let byte_val = bit_and (shift_right v shift_bits) (of_int 0xff) in
      extract_and_build (i + 1) (byte_val :: bytes_list) v
  in
  let bytes_list = extract_and_build 0 [] num in
  (* Reverse to get [b0, b1, ..., b_{len-1}] *)
  let bytes_forward = List.rev bytes_list in
  (* Build BE num: b0*256^{len-1} + b1*256^{len-2} + ... + b_{len-1}*256^0 *)
  let rec build_be_num acc shift = function
    | [] -> acc
    | byte_val :: rest ->
        build_be_num (acc + (byte_val * shift)) (shift / of_int 256) rest
  in
  let be_num = build_be_num zero (pow (of_int 256) (of_int (len - 1))) bytes_forward in
  make_bytes ~num:be_num ~len

let uint8_to_bytes_le ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_uint8 at x in
  Ok (make_bytes_le ~num:x ~len:1)

let uint32_to_bytes_le ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_uint32 at x in
  Ok (make_bytes_le ~num:x ~len:4)

let uint64_to_bytes_le ~at (x : Num.t) : Value.t result =
  let x = Num.to_int x in
  let* () = validate_uint64 at x in
  Ok (make_bytes_le ~num:x ~len:8)
```

**Why This Design:**
- **SSZ compatibility**: SSZ uses fixed-width little-endian encoding for integers (e.g., `uint64` → exactly 8 bytes LE)
- **Byte extraction**: Extracts bytes from the integer in little-endian order (LSB first)
- **Big-endian storage**: The extracted bytes are then stored as a big-endian integer in `BytesV`, but when converted back to raw bytes, they maintain the little-endian byte order
- **Fixed width**: Always produces the exact byte length required (1, 4, or 8 bytes)

**Example:**
- Input: `uint64 = 1000` (0x3e8)
- `uint64_to_bytes_le`: Extracts bytes in LE order → `[0xe8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]`
- Stored as `BytesV` with BE interpretation, but when converted to raw bytes, maintains LE order

##### `bytes32_to_bytes1_list` and `bytes1_to_uint64`: Byte List Conversions

These functions enable indexed access to individual bytes within a `bytes32` value.

**`bytes32_to_bytes1_list`**: Converts a `bytes32` into a list of 32 `bytes1` values.

**Implementation:**
```ocaml
let bytes32_to_bytes1_list ~at (bytes32_val : Num.t) : Value.t result =
  let bytes32_val = Num.to_int bytes32_val in
  let* () = validate_bytes32 at bytes32_val in
  (* Extract each byte from bytes32 *)
  let bytes1_list =
    List.init 32 (fun i ->
        let shift_amount = (31 - i) * 8 in
        let byte_val = Bigint.shift_right bytes32_val shift_amount in
        let byte_val = Bigint.bit_and byte_val (Bigint.of_int 255) in
        Value.nat byte_val)
  in
  Ok (Value.list typ bytes1_list)
```

**`bytes1_to_uint64`**: Extracts the numeric value (0-255) from a single byte.

**Implementation:**
```ocaml
let bytes1_to_uint64 ~at (bytes1_val : Num.t) : Value.t result =
  let bytes1_val = Num.to_int bytes1_val in
  let* () = validate_bytes1 at bytes1_val in
  Ok (Value.nat bytes1_val)
```

**Why This Design:**
- **Indexed access**: Enables accessing individual bytes by index (e.g., `bytes32_to_bytes1_list(x)[i]`)
- **Bit manipulation**: Used in shuffle/sampling algorithms where individual bits need to be extracted
- **Type conversion**: `bytes1_to_uint64` converts a byte value to a numeric type for arithmetic operations

##### `concat_bytes`: Byte Sequence Concatenation

Concatenates two byte sequences (of any length) into a single `BytesV`, preserving big-endian byte order in the underlying integer representation.

**Implementation:**
```ocaml
let concat_bytes ~at (value_a : Value.t) (value_b : Value.t) : Value.t result =
  match (value_a.it, value_b.it) with
  | BytesV { num = na; len = la }, BytesV { num = nb; len = lb } ->
      (* big-endian concat: (na || nb) == na * 256^(lb) + nb *)
      let shift_bits = 8 * lb in
      let shift = Bigint.(pow (of_int 2) (of_int shift_bits)) in
      let num = Bigint.((na * shift) + nb) in
      Ok (make_bytes ~num ~len:(la + lb))
  | _ -> Error (runtime at "concat_bytes: expected bytes values")
```

**Why This Design:**
- **Big-endian concatenation**: The first sequence is shifted left by `8 * lb` bits, then the second sequence is added
- **Length preservation**: The result length is the sum of input lengths
- **Used in hashing**: Commonly used to construct message payloads for hashing (e.g., `concat_bytes(seed, round)` for shuffle operations)

#### 4.4.2 Bitwise Operations

These functions perform bitwise operations on bytes values, essential for domain construction and byte manipulation in eth2spec.

##### `xor`: Bitwise XOR

Performs XOR operation on two `bytes32` values, used in eth2spec for operations like RANDAO mixing.

**Implementation:**
```ocaml
let xor ~at (bytes32_a : Num.t) (bytes32_b : Num.t) : Value.t result =
  let bytes32_a = Num.to_int bytes32_a in
  let bytes32_b = Num.to_int bytes32_b in
  let* () = validate_bytes32 at bytes32_a in
  let* () = validate_bytes32 at bytes32_b in
  let result = Bigint.bit_xor bytes32_a bytes32_b in
  Ok (make_bytes ~num:result ~len:32)
```

**Why This Design:**
- **Direct bitwise operation**: `Bigint.bit_xor` performs bitwise XOR on the integer representation
- **Big-endian preservation**: Since both inputs are big-endian, the result is also big-endian
- **Type safety**: Validates inputs and returns `BytesV` with correct length

**Example:**
- Input: `bytes32_a = 0x1234...`, `bytes32_b = 0x5678...`
- Operation: `0x1234... XOR 0x5678... = 0x444c...` (bitwise)
- Result: `BytesV {num = 0x444c...; len = 32}`

##### `shr_uint64` and `and_uint64`: Bitwise Operations on uint64

These functions perform bitwise operations on `uint64` values, used for extracting individual bits from bytes during shuffling and selection algorithms.

**`shr_uint64`**: Right shift a `uint64` value by a non-negative amount (0-63).

**Implementation:**
```ocaml
let shr_uint64 ~at (x : Num.t) (k : Num.t) : Value.t result =
  let x = Num.to_int x in
  let k = Num.to_int k in
  if Bigint.compare k Bigint.zero < 0 then
    Error (runtime at "shr_uint64: shift amount must be non-negative")
  else
    try
      let k_int = Bigint.to_int_exn k in
      if k_int >= 0 && k_int < 64 then
        Ok (Value.nat (Bigint.shift_right x k_int))
      else Error (runtime at "shr_uint64: shift amount must be in [0, 64]")
    with _ -> Error (runtime at "shr_uint64: shift amount too large")
```

**`and_uint64`**: Bitwise AND of two `uint64` values.

**Implementation:**
```ocaml
let and_uint64 ~at:_ (x : Num.t) (y : Num.t) : Value.t result =
  let x = Num.to_int x in
  let y = Num.to_int y in
  Ok (Value.nat (Bigint.bit_and x y))
```

**Why This Design:**
- **Bit extraction**: Used in shuffle algorithms to extract individual bits from bytes (e.g., `(byte >> k) & 1`)
- **Range validation**: `shr_uint64` validates that the shift amount is within the valid range [0, 64)
- **Type safety**: Both functions operate on `uint64` values, ensuring correct bit-width semantics

##### `first_28_bytes`: Extract Leftmost 28 Bytes

Returns `x[0:28]` (the leftmost 28 bytes) from a `bytes32` value. In our big-endian-integer backing, this equals `x >> 32` (shifting right by 32 bits to remove the rightmost 4 bytes). Used in domain construction to extract `fork_data_root[:28]` per SSZ rules.

**Implementation:**
```ocaml
let first_28_bytes ~at (value : Value.t) : (Value.t, Err.t) result =
  let* bytes32_val =
    match value.it with
    | BytesV { num; len = 32 } -> Ok num
    | BytesV { num; len = _ } ->
        let* () = validate_bytes32 at num in
        Ok num
    | NumV n ->
        let bytes32_val = Num.to_int n in
        let* () = validate_bytes32 at bytes32_val in
        Ok bytes32_val
    | _ -> Error (Err.runtime at "first_28_bytes: expected bytes32 or NumV")
  in
  (* Extract first 28 bytes (MSB 28 bytes) from bytes32 *)
  (* Python x[:28] - remove last 4 bytes (32 bits) *)
  let bytes28_val = Bigint.shift_right bytes32_val 32 in
  Ok (make_bytes ~num:bytes28_val ~len:28)
```

**Why This Design:**
- **Byte slice operation**: Returns `x[0:28]` (leftmost 28 bytes in byte array indexing)
- **Bit shift implementation**: With big-endian-integer backing, this is implemented as `x >> 32` (shifting right by 32 bits removes the rightmost 4 bytes)
- **Domain construction**: Used to extract `fork_data_root[:28]` per SSZ domain construction rules

**Example:**
- Input: `bytes32 = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef`
- Shift right by 32 bits: removes last 4 bytes `0x90abcdef`
- Result: `bytes28 = 0x1234567890abcdef1234567890abcdef1234567890abcdef12345678`

##### `get_first_byte`: Extract Leftmost Byte

Extracts `x[0:1]` (the leftmost byte) from a `bytes32` value. In our big-endian-integer backing, this is implemented as `(x >> 248) & 0xff`.

**Implementation:**
```ocaml
let get_first_byte ~at (value : Value.t) : (Value.t, Err.t) result =
  let* bytes32_val = (* ... extract bytes32_val ... *) in
  (* Extract first byte (MSB 1 byte) from bytes32 *)
  (* Python x[:1] - extract MSB byte *)
  let msb_byte = Bigint.(shift_right bytes32_val 248 |> bit_and (of_int 0xff)) in
  Ok (make_bytes ~num:msb_byte ~len:1)
```

**Why This Design:**
- **Byte slice operation**: Returns `x[0:1]` (leftmost byte in byte array indexing)
- **Bit shift and mask implementation**: With big-endian-integer backing, this is implemented as `(x >> 248) & 0xff` (shifting right by 248 bits isolates the leftmost byte, then masking with `0xff`)

**Example:**
- Input: `bytes32 = 0x1234567890abcdef...`
- Shift right 248 bits: `0x12`
- Mask with `0xff`: `0x12`
- Result: `bytes1 = 0x12`

##### `strip_first_byte`: Remove Leftmost Byte

Removes `x[0:1]` (the leftmost byte) from a `bytes32` value, keeping `x[1:32]` (the remaining 31 bytes). In our big-endian-integer backing, this is implemented as `x & (2^248 - 1)` (masking to keep only the lower 248 bits).

**Implementation:**
```ocaml
let strip_first_byte ~at (value : Value.t) : (Value.t, Err.t) result =
  let* bytes32_val = (* ... extract bytes32_val ... *) in
  (* Remove first byte (MSB 1 byte) from bytes32 *)
  (* Python x[1:] - remove MSB byte, keep remaining 31 bytes *)
  let mask_248 = Bigint.(pow (of_int 2) (of_int 248) - one) in
  let bytes31_val = Bigint.bit_and bytes32_val mask_248 in
  Ok (make_bytes ~num:bytes31_val ~len:31)
```

**Why This Design:**
- **Byte slice operation**: Returns `x[1:32]` (bytes from index 1 to 31, removing the leftmost byte)
- **Bit mask implementation**: With big-endian-integer backing, this is implemented as `x & (2^248 - 1)` (masking to keep only the lower 248 bits, effectively removing the leftmost 8 bits)

**Example:**
- Input: `bytes32 = 0x1234567890abcdef...`
- Mask: `0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff`
- Result: `bytes31 = 0x34567890abcdef...` (removed `0x12`)

#### 4.4.3 Domain-Specific Operations

These functions implement eth2spec-specific operations for domain construction and withdrawal credential handling.

##### `concat_domain`: Domain Construction

Concatenates a `domainType` (4 bytes) and `bytes28` to form a `domain` (32 bytes), following eth2spec's domain construction rules.

**Implementation:**
```ocaml
let concat_domain ~at (domain_type : Num.t) (bytes28_val : Num.t) : (Value.t, Err.t) result =
  let domain_type = Num.to_int domain_type in
  let bytes28_val = Num.to_int bytes28_val in
  (* Validate domainType (bytes4) *)
  let* () = validate_bytes4 at domain_type in
  (* Validate bytes28 *)
  let* () = validate_bytes28 at bytes28_val in
  (* Convert to bytes (Big-endian) *)
  let dt_bytes = be_of_bigint_fixed domain_type ~len:4 in
  let b28_bytes = be_of_bigint_fixed bytes28_val ~len:28 in
  (* Concatenate: domain_type (4 bytes) + bytes28 (28 bytes) *)
  let out = create 32 in
  blit dt_bytes 0 out 0 4;
  blit b28_bytes 0 out 4 28;
  (* Convert back to integer (Big-endian) *)
  let result = bigint_of_be_bytes out in
  (* Validate result is within bytes32 range *)
  let* () = validate_bytes32 at result in
  Ok (make_bytes ~num:result ~len:32)
```

**Why This Design:**
- **SSZ domain format**: eth2spec domains are 32 bytes: `domainType (4B) || fork_data_root[28B]`
- **Big-endian concatenation**: Both components are converted to big-endian bytes, then concatenated
- **Byte-level accuracy**: Uses `blit` for precise byte copying, ensuring correct ordering

**Example:**
- Input: `domainType = 0x00000007` (DOMAIN_RANDAO), `bytes28 = 0x1234...` (fork data root)
- `dt_bytes = [0x00, 0x00, 0x00, 0x07]`
- `b28_bytes = [0x12, 0x34, ...]` (28 bytes)
- Concatenated: `[0x00, 0x00, 0x00, 0x07, 0x12, 0x34, ...]` (32 bytes)
- Result: `domain = 0x000000071234...` (32 bytes)

##### `make_withdrawal_credentials_eth1`: Withdrawal Credential Construction

Creates withdrawal credentials with the ETH1 address prefix, following eth2spec's withdrawal credential format.

**Implementation:**
```ocaml
let make_withdrawal_credentials_eth1 ~at (execution_address : Num.t) : (Value.t, Err.t) result =
  let execution_address = Num.to_int execution_address in
  (* Validate executionAddress (bytes20) *)
  let* () = validate_bytes20 at execution_address in
  (* ETH1_ADDRESS_WITHDRAWAL_PREFIX = 0x01 (1 byte) *)
  let eth1_prefix = Bigint.of_int 0x01 in
  (* 0x00 * 11 = 11 zero bytes *)
  let zero_bytes_11 = Bigint.zero in
  (* Concatenate: 0x01 + 0x00*11 + executionAddress = 32 bytes *)
  (* Shift eth1_prefix left by 31 bytes (248 bits) *)
  let prefix_shifted = Bigint.shift_left eth1_prefix 248 in
  (* Shift zero_bytes_11 left by 20 bytes (160 bits) *)
  let zeros_shifted = Bigint.shift_left zero_bytes_11 160 in
  (* Final result: prefix + zeros + execution_address *)
  let result = Bigint.(prefix_shifted + zeros_shifted + execution_address) in
  (* Validate result is within bytes32 range *)
  let* () = validate_bytes32 at result in
  Ok (make_bytes ~num:result ~len:32)
```

**Why This Design:**
- **eth2spec format**: Withdrawal credentials are 32 bytes: `[0x01, 0x00*11, execution_address]`
- **Bit shifting**: Uses left shifts to position each component correctly in the 32-byte result
- **Prefix placement**: `0x01` at MSB (byte 0), 11 zero bytes, then execution address at LSB

**Example:**
- Input: `execution_address = 0x742d35cc6631c0532925a3b8d4c9db6c4e8f1234` (20 bytes)
- `prefix_shifted = 0x0100000000000000000000000000000000000000000000000000000000000000`
- `zeros_shifted = 0x0000000000000000000000000000000000000000000000000000000000000000`
- `execution_address = 0x000000000000000000000000742d35cc6631c0532925a3b8d4c9db6c4e8f1234`
- Result: `0x010000000000000000000000742d35cc6631c0532925a3b8d4c9db6c4e8f1234`

##### `extract_execution_address`: Address Extraction

Extracts the execution address (last 20 bytes) from withdrawal credentials.

**Implementation:**
```ocaml
let extract_execution_address ~at (bytes32_val : Num.t) : (Value.t, Err.t) result =
  let bytes32_val = Num.to_int bytes32_val in
  let* () = validate_bytes32 at bytes32_val in
  (* Extract last 20 bytes (160 bits) from bytes32 *)
  let bytes20_mask = Bigint.(pow (of_int 2) (of_int 160) - one) in
  let execution_address = Bigint.bit_and bytes32_val bytes20_mask in
  Ok (make_bytes ~num:execution_address ~len:20)
```

**Why This Design:**
- **Mask operation**: Uses bitwise AND with `2^160 - 1` to extract the lower 160 bits (20 bytes)
- **LSB extraction**: The mask has 160 bits set, keeping only the execution address portion

**Example:**
- Input: `bytes32 = 0x010000000000000000000000742d35cc6631c0532925a3b8d4c9db6c4e8f1234`
- Mask: `0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff`
- Result: `execution_address = 0x742d35cc6631c0532925a3b8d4c9db6c4e8f1234` (20 bytes)

#### 4.4.4 Design Principles

All bytes manipulation functions follow these principles:

1. **Big-Endian Semantics**: Since `BytesV` stores values as big-endian integers, all operations preserve this semantics
2. **Type Safety and Validation**: Functions validate inputs using helper functions that ensure values fit within their byte length constraints:
   - `validate_bytesN`: Ensures `0 ≤ v < 2^(8·N)` for bytes types (e.g., `validate_bytes32` checks `0 ≤ v < 2^256`)
   - `validate_uintN`: Ensures `0 ≤ v < 2^N` for uint types (e.g., `validate_uint64` checks `0 ≤ v < 2^64`)
3. **Dual Representation Support**: Functions handle both `BytesV` and `NumV` inputs, converting as needed
4. **eth2spec Compliance**: All operations match the behavior specified in the Ethereum 2.0 consensus specification
5. **Precise Byte Operations**: Uses bitwise operations and shifts to ensure byte-level accuracy. Byte slice operations (e.g., `x[a:b]`) are clearly distinguished from bit shift operations (e.g., `x >> k`)

These functions enable Spectec to perform all byte-level operations required by eth2spec, ensuring compatibility with the Ethereum 2.0 consensus layer.

### 4.5 Mathematical Functions (`math.ml`)

The `math.ml` module provides mathematical operations required for eth2spec calculations.

#### 4.5.1 Integer Square Root

The `$integer_square_root` function computes the integer square root using Newton's method:

```ocaml
let integer_square_root' (n : Bigint.t) : Bigint.t =
  (* Special case for uint64_max *)
  let uint64_max      = Bigint.( (one lsl 64) - one ) in
  let uint64_max_sqrt = Bigint.( (one lsl 32) - one ) in
  if Bigint.equal n uint64_max then
    uint64_max_sqrt
  else
    let rec newton_method (x : Bigint.t) (n : Bigint.t) : Bigint.t =
      let y = Bigint.((x + n / x) / (one + one)) in
      if Bigint.(y < x) then
        newton_method y n
      else
        x
    in
    if Bigint.(n = zero) then
      Bigint.zero
    else
      newton_method n n
```

This function is used in eth2spec for calculating validator rewards and penalties, where square root operations are required for effective balance calculations.

### 4.6 List Manipulation Functions (`lists.ml`)

The `lists.ml` module provides generic list operations that are extensively used in eth2spec specifications for processing validator lists, attestations, and other collections.

#### 4.6.1 Counting and Aggregation

- **`$count_occurrences_<X>`**: Counts occurrences of a target value in a list
  ```ocaml
  let count_occurrences_ ~at (_typ : targ) (vs : Value.t list) (target : Value.t) : (Value.t, Err.t) result =
    let count = 
      List.fold_left
        (fun acc v ->
          if Value.eq v target then
            Bigint.(acc + one)
          else
            acc)
        Bigint.zero vs
    in
    Ok (Value.nat count)
  ```
  Used in eth2spec for counting votes (e.g., ETH1 data votes) and determining majority consensus.

- **`$sum_<X>`**: Sums numeric values in a list
  ```ocaml
  let sum_ ~at (_typ : targ) (vs : Value.t list) : (Value.t, Err.t) result =
    let s =
      List.fold_left
        (fun acc ({ Util.Source.it; _ } : Value.t) ->
           match it with
           | NumV (`Int n) | NumV (`Nat n) -> Bigint.(acc + n)
           | _ -> acc)
         Bigint.zero
         vs
    in
    Ok (Value.nat s)
  ```
  Used for aggregating balances, rewards, and penalties across validators.

#### 4.6.2 List Construction and Transformation

- **`$enumerate_<X>`**: Creates (index, value) pairs from a list
  ```ocaml
  let enumerate_ ~at (typ : targ) (vs : Value.t list) : (Value.t, Err.t) result =
    let enumerated_list = 
      List.mapi 
        (fun i v -> 
          let index = Value.nat (Bigint.of_int i) in
          Value.tuple [index; v])
        vs
    in
    Ok (Value.list typ enumerated_list)
  ```
  Used when index information is needed alongside list elements (e.g., processing sync committee members with their indices).

- **`$range`**: Generates a list of natural numbers from 0 to n-1
  ```ocaml
  let range ~at (count : Num.t) : (Value.t, Err.t) result =
    let count = Num.to_int count in
    try
      let n = Bigint.to_int_exn count in
      if n < 0 then
        Error (Err.runtime at "range: count must be non-negative")
      else
        let range_list = List.init n (fun i -> Value.nat (Bigint.of_int i)) in
        Ok (Value.list' Typ.int range_list)
    with
    | _ -> Error (Err.runtime at "range: count is too large to be an integer")
  ```
  Used for generating validator indices and iteration ranges.

- **`$repeat_<X>`**: Creates a list by repeating a value n times
  ```ocaml
  let repeat_ ~at (typ : targ) (value : Value.t) (count : Num.t) : (Value.t, Err.t) result =
    let count = Num.to_int count in
    try
      let n = Bigint.to_int_exn count in
      if n < 0 then
        Error (Err.runtime at "repeat: count must be non-negative")
      else
        let repeated_list = List.init n (fun _ -> value) in
        Ok (Value.list typ repeated_list)
    with
    | _ -> Error (Err.runtime at "repeat: count is too large to be an integer")
  ```
  Used for initializing lists with default values.

#### 4.6.3 List Modification

- **`$set_or_append_list_<X>`**: Sets a value at an index or appends if index equals length
  ```ocaml
  let set_or_append_list_ ~at (typ : targ) (vs : Value.t list) (idx_big : Num.t) (value : Value.t) : (Value.t, Err.t) result =
    let idx_big = Num.to_int idx_big in
    try
      let idx = Bigint.to_int_exn idx_big in
      if idx < 0 then
        Error (Err.runtime at "set_or_append_list: index must be non-negative")
      else
        let len = List.length vs in
         if idx = len then
           (* append *)
           Ok (Value.list typ (vs @ [value]))
         else if idx < len then
           (* set at index *)
           let rec replace i = function
             | [] -> []
             | _ :: tl when i = idx -> value :: tl
             | hd :: tl -> hd :: replace (i + 1) tl
           in
           Ok (Value.list typ (replace 0 vs))
        else
          Error (Err.runtime at "set_or_append_list: index out of range")
    with
    | _ -> Error (Err.runtime at "set_or_append_list: index is too large to be an integer")
  ```
  This function provides a unified interface for both updating existing list elements and appending new ones, which is commonly needed in state transition functions.

#### 4.6.4 List Ordering and Set Operations

- **`$sort_<X>`**: Sorts a list using value comparison
  ```ocaml
  let sort_ ~at (typ : targ) (vs : Value.t list) : (Value.t, Err.t) result =
    let sorted_list = List.sort Value.compare vs in
    Ok (Value.list typ sorted_list)
  ```
  Used for ordering validators, attestations, and other collections.

- **`$to_set_<X>`**: Removes duplicates from a list while preserving order
  ```ocaml
  let to_set_ ~at (typ : targ) (vs : Value.t list) : (Value.t, Err.t) result =
    (* Remove duplicates while preserving order *)
    let seen = ref Sets.VSet.empty in
    let result = 
      List.fold_left
        (fun acc v ->
          if Sets.VSet.mem v !seen then
            acc
          else
            (seen := Sets.VSet.add v !seen;
             v :: acc))
        [] vs
      |> List.rev  (* Restore original order *)
    in
    Ok (Value.list typ result)
  ```
  Used for deduplication operations in eth2spec.

- **`$set_intersection_<X>`**: Computes intersection of two lists as sets
  ```ocaml
  let set_intersection_ ~at (typ : targ) (vs1 : Value.t list) (vs2 : Value.t list) : (Value.t, Err.t) result =
    (* Convert lists to sets *)
    let set1 = Sets.VSet.of_list vs1 in
    let set2 = Sets.VSet.of_list vs2 in
    (* Compute intersection *)
    let intersection = Sets.VSet.inter set1 set2 in
    (* Convert back to list *)
    let result_list = Sets.VSet.elements intersection in
    Ok (Value.list typ result_list)
  ```
  Used for finding common elements between collections (e.g., common validators in attestations).

#### 4.6.5 Design Considerations

These list manipulation functions are designed with the following principles:

1. **Type genericity**: Functions use type parameters (`<X>`) to work with any value type
2. **Bigint handling**: All numeric operations use `Bigint.t` to handle arbitrary-precision integers
3. **Error handling**: Functions validate inputs and provide clear error messages
4. **Immutable semantics**: Functions return new lists rather than modifying inputs, maintaining functional programming principles

These functions are essential for implementing eth2spec's state transition logic, which heavily relies on list operations for processing validators, attestations, slashings, and other collections.

## 5. Conclusion

This document has presented a comprehensive approach to handling Ethereum 2.0's SSZ bytes types within Spectec's type system. Our solution demonstrates how a specification language framework with limited primitive types can be extended to support complex domain-specific requirements without compromising its core simplicity.

### 5.1 Summary of the Approach

Our type processing strategy for eth2spec consists of four key components:

1. **Type Aliases for Static Type Checking** (Section 2): We leverage Spectec's type alias mechanism to map SSZ bytes types (`bytes32`, `bytes48`, `bytes96`, etc.) and domain-specific aliases (`blsPubkey`, `blsSignature`, `root`, etc.) to the `int` primitive type. This approach preserves type semantics at compile time while maintaining compatibility with existing infrastructure.

2. **Runtime Value Types for Length Preservation** (Section 3): We introduce `BytesV`, a runtime value type that stores both the numeric value (`Bigint.t`) and the byte length (`int`). This solves the critical problem of length information loss that would otherwise occur when bytes types are represented solely as integers.

3. **Type-Driven Inference in Builtin Functions** (Section 4): All builtin functions implement type-driven length inference using helper functions like `bytes_len_of_targ` to extract byte lengths from type annotations. This enables seamless handling of both `BytesV` and `NumV` representations, ensuring compatibility throughout the elaboration and execution phases.

4. **Consistent Big-Endian Encoding** (Throughout): We consistently use big-endian encoding for all byte representations, matching SSZ standards and Ethereum's byte conventions. This ensures bit-for-bit compatibility with the `eth2spec` Python reference implementation.

### 5.2 Key Achievements

Our implementation successfully addresses the challenges of representing SSZ bytes types in Spectec:

- **Complete SSZ Compatibility**: All hash tree root computations, Merkle tree operations, and serialization procedures strictly adhere to the SSZ specification, producing identical results to the Python `eth2spec` reference implementation.

- **Cryptographic Correctness**: BLS signature verification functions correctly handle compressed public keys (48 bytes) and signatures (96 bytes), using the exact `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` scheme required by Ethereum 2.0.

- **Type Safety**: The combination of static type aliases and runtime `BytesV` validation ensures that values fit within their specified byte length constraints, preventing type-related errors at both compile time and runtime.

- **Comprehensive Builtin Support**: We provide a complete set of builtin functions covering:
  - Hash operations (SHA-256)
  - Hash tree root computation (SSZ Merkleization)
  - BLS signature verification (single, fast aggregate, and aggregation)
  - Byte manipulation (conversion, extraction, domain construction)
  - Mathematical operations (integer square root)
  - List operations (counting, aggregation, transformation, set operations)

### 5.3 Design Principles

Throughout this implementation, we maintained several key design principles:

- **Minimal Core Changes**: By using type aliases and runtime value types, we avoided modifications to Spectec's core type system, preserving its simplicity and maintainability.

- **Backward Compatibility**: Existing arithmetic operations and type checking mechanisms continue to work seamlessly with bytes types represented as `int`.

- **Specification Compliance**: All implementations strictly follow Ethereum 2.0 consensus specifications and SSZ standards, ensuring correctness and interoperability.

- **Error Handling**: Functions provide clear error messages and validate inputs at appropriate boundaries, balancing strict error handling for debugging with consensus-friendly behavior for verification routines.

### 5.4 Future Work

This type processing strategy enables Spectec to fully support Ethereum 2.0 consensus specifications, allowing formal verification and execution of eth2spec's state transition logic. The approach demonstrates that minimal type systems can be effectively extended to handle complex domain requirements through careful design of type representations and runtime value types.

Future extensions could include:
- Support for additional SSZ types (e.g., variable-length lists with dynamic limits)
- Support for additional composite types that may be introduced in future versions

The techniques presented in this document provide a foundation for adapting Spectec to other blockchain specifications that require similar byte-level type handling.