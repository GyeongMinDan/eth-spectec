val pow2_8 : int -> Bigint.t

val be_of_bigint_fixed : Bigint.t -> len:int -> Bytes.t
val bigint_of_be_bytes : Bytes.t -> Bigint.t
val sha256_bytes32 : Bytes.t -> Bigint.t

(** Return a fresh all-zero SSZ chunk. *)
val zero_chunk : unit -> Bytes.t

(** Merkleize 32-byte chunks without allocating the absent leaves up to
    [limit]. Raises [Invalid_argument] for a negative limit, too many leaves,
    or a chunk whose length is not 32 bytes. *)
val merkleize_chunks_with_limit : Bytes.t array -> int -> Bytes.t
val merkleize_leaves : Bytes.t array -> Bytes.t
val mix_in_length : Bytes.t -> Bigint.t -> Bytes.t

val chunkize_bytes_bytev : Bytes.t -> Bytes.t array
val leaf_uint_le : Bigint.t -> nbytes:int -> Bytes.t
val leaf_bytes32 : Bigint.t -> Bytes.t
