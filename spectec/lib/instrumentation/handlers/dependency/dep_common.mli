(* Common types and utilities for dependency analysis. *)

module Il = Lang.Il

(* === Types === *)

type input_source = State | Block | Local of string | Unknown

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
