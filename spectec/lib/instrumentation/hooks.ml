(* Instrumentation hooks for interpreter events.

   Provides:
   - HANDLER: module type for various instrumentations
   - notify_*: dispatcher functions called from interpreter
   - set_handlers: register handlers before running interpreter

   Usage:
   1. Create handler: module MyHandler : HANDLER = struct ... end
   2. Runner calls: set_handlers [handler1; handler2]
   3. Interpreters call: notify_rel_enter ~id ~at ~values
   4. All handlers receive the event
   5. Runner calls: finish ()
*)

open Common.Source
module Il = Lang.Il
module Sl = Lang.Sl

type spec = IlSpec of Il.spec | SlSpec of Sl.spec

(* Handler callback signature *)

module type HANDLER = sig
  val init : spec:spec -> unit

  (* Common events *)
  val on_rel_enter : id:string -> at:region -> values:Il.Value.t list -> unit
  val on_rel_exit : id:string -> at:region -> success:bool -> unit
  val on_rule_enter : id:string -> rule_id:string -> at:region -> unit

  val on_rule_exit :
    id:string -> rule_id:string -> at:region -> success:bool -> unit

  val on_func_enter : id:string -> at:region -> values:Il.Value.t list -> unit
  val on_func_exit : id:string -> at:region -> unit
  val on_clause_enter : id:string -> clause_idx:int -> at:region -> unit

  val on_clause_exit :
    id:string -> clause_idx:int -> at:region -> success:bool -> unit

  (* IL-specific events *)
  val on_iter_prem_enter : prem:Il.prem -> at:region -> unit
  val on_iter_prem_exit : at:region -> unit
  val on_prem_enter : prem:Il.prem -> at:region -> unit
  val on_prem_exit : prem:Il.prem -> at:region -> success:bool -> unit

  (* SL-specific events *)
  val on_instr : instr:Sl.instr -> at:region -> unit
  val finish : unit -> unit
end

(* Handler state - set by runner before interpretation *)

let handlers : (module HANDLER) list ref = ref []
let set_handlers hs = handlers := hs

(* Event dispatchers called from interpreters *)

let init ~spec =
  if !handlers <> [] then
    List.iter (fun (module H : HANDLER) -> H.init ~spec) !handlers

let notify_rel_enter ~id ~at ~values =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_rel_enter ~id ~at ~values)
      !handlers

let notify_rel_exit ~id ~at ~success =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_rel_exit ~id ~at ~success)
      !handlers

let notify_rule_enter ~id ~rule_id ~at =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_rule_enter ~id ~rule_id ~at)
      !handlers

let notify_rule_exit ~id ~rule_id ~at ~success =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_rule_exit ~id ~rule_id ~at ~success)
      !handlers

let notify_func_enter ~id ~at ~values =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_func_enter ~id ~at ~values)
      !handlers

let notify_func_exit ~id ~at =
  if !handlers <> [] then
    List.iter (fun (module H : HANDLER) -> H.on_func_exit ~id ~at) !handlers

let notify_clause_enter ~id ~clause_idx ~at =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_clause_enter ~id ~clause_idx ~at)
      !handlers

let notify_clause_exit ~id ~clause_idx ~at ~success =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) ->
        H.on_clause_exit ~id ~clause_idx ~at ~success)
      !handlers

let notify_iter_prem_enter ~prem ~at =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_iter_prem_enter ~prem ~at)
      !handlers

let notify_iter_prem_exit ~at =
  if !handlers <> [] then
    List.iter (fun (module H : HANDLER) -> H.on_iter_prem_exit ~at) !handlers

let notify_prem_enter ~prem ~at =
  if !handlers <> [] then
    List.iter (fun (module H : HANDLER) -> H.on_prem_enter ~prem ~at) !handlers

let notify_prem_exit ~prem ~at ~success =
  if !handlers <> [] then
    List.iter
      (fun (module H : HANDLER) -> H.on_prem_exit ~prem ~at ~success)
      !handlers

let notify_instr ~instr ~at =
  if !handlers <> [] then
    List.iter (fun (module H : HANDLER) -> H.on_instr ~instr ~at) !handlers

let finish () = List.iter (fun (module H : HANDLER) -> H.finish ()) !handlers

(* No-op default handler *)

module Noop : HANDLER = struct
  let init ~spec:_ = ()
  let on_rel_enter ~id:_ ~at:_ ~values:_ = ()
  let on_rel_exit ~id:_ ~at:_ ~success:_ = ()
  let on_rule_enter ~id:_ ~rule_id:_ ~at:_ = ()
  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success:_ = ()
  let on_func_enter ~id:_ ~at:_ ~values:_ = ()
  let on_func_exit ~id:_ ~at:_ = ()
  let on_clause_enter ~id:_ ~clause_idx:_ ~at:_ = ()
  let on_clause_exit ~id:_ ~clause_idx:_ ~at:_ ~success:_ = ()
  let on_iter_prem_enter ~prem:_ ~at:_ = ()
  let on_iter_prem_exit ~at:_ = ()
  let on_prem_enter ~prem:_ ~at:_ = ()
  let on_prem_exit ~prem:_ ~at:_ ~success:_ = ()
  let on_instr ~instr:_ ~at:_ = ()
  let finish () = ()
end
