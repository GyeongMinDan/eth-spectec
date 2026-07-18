(* Common types and utilities for dependency analysis. *)

module Il = Lang.Il

(* === Types === *)

type input_source = State | Block

(* Type equation with Il.json_step — values of these types are identical. *)
type field_step = Il.json_step = FieldAccess of string | IndexAccess of int
type field_path = { source : input_source; steps : field_step list }

(* === Centralized Whitelist === *)

val eth_whitelist : string list
val is_whitelisted : string -> bool

(* === String Formatting === *)

val string_of_input_source : input_source -> string
val string_of_field_step : field_step -> string
val string_of_field_path : field_path -> string

(* === Readsets: provenance rules for the spec's generic list helpers === *)

module StringMap : Map.S with type key = string

(* Field chains a predicate reads, per component of its element parameter *)
type readset = field_step list list array

val readset_of_clauses : Il.clause list -> readset
val readsets_of_spec : Il.spec -> readset StringMap.t

val call_provenance :
  lookup:(string -> readset option) ->
  string ->
  Il.Value.t list ->
  Il.json_provenance list
