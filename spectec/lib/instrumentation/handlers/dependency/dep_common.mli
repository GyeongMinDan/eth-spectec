(* Common types and utilities for dependency analysis. *)

module Il = Lang.Il

(* === Types === *)

type input_source = State | Block | Unknown
type field_access = { source : input_source; fields : string list }
type source_env = (string, field_access) Hashtbl.t

(* === Centralized Whitelist === *)

val eth_whitelist : string list
val is_whitelisted : string -> bool

(* === Source Environment === *)

val create_env : unit -> source_env
val bind_source : source_env -> string -> field_access -> unit
val lookup_source : source_env -> string -> field_access option
val clear_env : source_env -> unit
val copy_env : source_env -> source_env

(* === Field Access Utilities === *)

val append_field : field_access -> string -> field_access

(* === String Formatting === *)

val string_of_input_source : input_source -> string
val string_of_field_access : field_access -> string

(* === Expression Analysis Helpers === *)

val strip_negation : Il.exp -> Il.exp * bool
val strip_bool_eq : Il.exp -> Il.exp * bool

(* === Relation Input Binding === *)

val extract_relation_inputs : Il.spec -> (string, string list) Hashtbl.t

val bind_state_transition_inputs :
  source_env ->
  (string, string list) Hashtbl.t ->
  string ->
  Il.Value.t list ->
  unit
