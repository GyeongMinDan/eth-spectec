(** The subset of SSZ types needed to describe Ethereum consensus objects. *)

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
      (** A container with one fixed field layout. *)
  | Container_variants of field list list
      (** Alternative layouts selected uniquely by the value's field count. *)

and field = {
  name : string;
  schema : t;
}

val field : string -> t -> field
val to_string : t -> string
