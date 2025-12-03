module Il = Lang.Il
module Value = Il.Value
open Il
open Define.Error
module Arg = Define.Arg

(* Debug print function: prints value and returns it unchanged *)
(* dec $debug_print_<X>(X) : X *)

let debug_print_ ~at:_ (_typ : targ) (v : Value.t) : Il.Value.t result =
  let value_str = Il.Print.string_of_value ~short:false v in
  Printf.printf "[DEBUG] %s\n%!" value_str;
  Ok v

(* Debug print with label *)
(* dec $debug_print_label_<X>(text, X) : X *)

let debug_print_label_ ~at:_ (_typ : targ) (label : string) (v : Value.t) :
    Value.t result =
  let value_str = Il.Print.string_of_value ~short:false v in
  Printf.printf "[DEBUG] %s: %s\n%!" label value_str;
  Ok v

let builtins : (string * Define.t) list =
  [
    ("debug_print_", Define.T1.a1 Arg.value debug_print_);
    ("debug_print_label_", Define.T1.a2 Arg.text Arg.value debug_print_label_);
  ]
