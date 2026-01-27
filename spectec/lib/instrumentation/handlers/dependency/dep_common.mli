(* Common types and utilities for dependency analysis. *)

module Il = Lang.Il

(* === Types === *)

type input_source = State | Block | Local of string | Unknown

(* === Structured Field Path Types === *)

type index_expr = ConstInt of int | PathRef of field_path
and field_step = FieldAccess of string | IndexAccess of index_expr
and field_path = { source : input_source; steps : field_step list }

type binop = Add | Sub | Mul | Div | Mod

(* Source environment: maps variable names to their field paths *)
type source_env = (string, field_path) Hashtbl.t

(* === Centralized Whitelist === *)

val eth_whitelist : string list
val is_whitelisted : string -> bool

(* === Source Environment === *)

val create_env : unit -> source_env
val bind_source : source_env -> string -> field_path -> unit
val lookup_source : source_env -> string -> field_path option
val clear_env : source_env -> unit
val copy_env : source_env -> source_env

(* === Field Path Utilities === *)

val append_step : field_path -> field_step -> field_path
val field_path_of_source : input_source -> field_path

(* === String Formatting === *)

val string_of_input_source : input_source -> string
val string_of_index_expr : index_expr -> string
val string_of_field_step : field_step -> string
val string_of_field_path : field_path -> string

(* === Expression Analysis Helpers === *)

val strip_negation : Il.exp -> Il.exp * bool
val strip_bool_eq : Il.exp -> Il.exp * bool

(* === Relation Input/Output Binding === *)

val extract_relation_inputs : Il.spec -> (string, string list) Hashtbl.t
val extract_relation_outputs : Il.spec -> (string, string list) Hashtbl.t
val extract_relation_io_indices : Il.spec -> (string, int list) Hashtbl.t
val extract_function_params : Il.spec -> (string, string list) Hashtbl.t

val bind_state_transition_inputs :
  source_env ->
  (string, string list) Hashtbl.t ->
  string ->
  Il.Value.t list ->
  unit
