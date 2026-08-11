(** Value-independent SSZ hash-tree-root evaluation. *)

type 'a accessors = {
  as_bool : 'a -> (bool, string) result;
  as_uint : 'a -> (Bigint.t, string) result;
  (** [length = Some n] requests a fixed-size byte vector. [None] requests a
      variable-size byte list. The engine verifies the returned length. *)
  as_bytes : length:int option -> 'a -> (Bytes.t, string) result;
  as_sequence : 'a -> ('a list, string) result;
  (** Container values are positional. Field names come from the schema and
      are used in error paths. *)
  as_container : 'a -> ('a list, string) result;
}

type error = {
  path : string list;
  message : string;
}

val error_to_string : error -> string
val to_string : error -> string

(** Compute an SSZ hash-tree-root using one schema-driven recursive engine. *)
val hash_tree_root :
  accessors:'a accessors -> Ssz_schema.t -> 'a -> (Bytes.t, error) result
