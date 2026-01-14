(* Common types and utilities for dependency analysis. *)

module Il = Lang.Il

(* === Types === *)

type input_source = State | Block | Unknown

(* === Structured Field Path Types === *)

type index_expr = ConstInt of int | PathRef of field_path
and field_step = FieldAccess of string | IndexAccess of index_expr
and field_path = { source : input_source; steps : field_step list }

type mutation_target = Value | CollectionLength

type concrete_hint =
  | ToLiteral of Lang.Il.Value.t
  | ToMax
  | ToMin
  | ToZero
  | ToOne

type binop = Add | Sub | Mul | Div | Mod

type symbolic_hint =
  | ToFieldValue of field_path
  | ToFieldOffset of field_path * int
  | ToBoundaryOf of field_path * [ `Above | `Below ]
  | ToBinOp of field_path * binop * field_path

type mutation_hint =
  | Concrete of concrete_hint
  | Symbolic of symbolic_hint
  | Unresolved of string

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

(* === Relation Input Binding === *)

val extract_relation_inputs : Il.spec -> (string, string list) Hashtbl.t

val bind_state_transition_inputs :
  source_env ->
  (string, string list) Hashtbl.t ->
  string ->
  Il.Value.t list ->
  unit
