open Lang.Il
open Builtins
open Error

(* Global mutable state to simulate execution engine behavior per test *)
let validity = ref true

(* Setter for test runner side-channel *)
let set_validity v = validity := v

(* Helper to check if payload is valid *)
let ee_verify_and_notify_new_payload ~at _payload : Value.t result =
  at |> ignore;
  Ok (Value.bool !validity)

(* Register builtin *)
let builtins : (string * Define.t) list =
  [
    ( "ee_verify_and_notify_new_payload",
      Define.T0.a1 Arg.value ee_verify_and_notify_new_payload );
  ]
