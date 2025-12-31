(* Trace handler - Live logging of interpreter events.

   Implements Hooks.HANDLER interface.

   Output levels:
   - Summary: relation/function  enter/exit
   - Full: + rule/clauses, premises and iteration summaries

   Usage:
     let handler = Trace.make ~level:Full ()
*)

module Il = Lang.Il
open Util

(* Verbosity levels *)
type level = Summary | Full

let summarize_value ?(max_len = 100) (value : Il.Value.t) : string =
  Il.Print.string_of_value value |> summarize ~max_len

let format_values (values : Il.Value.t list) : string =
  match values with
  | [] -> ""
  | _ ->
      let value_strs = List.map (summarize_value ~max_len:100) values in
      Format.sprintf "  [in: %s]\n" (String.concat ", " value_strs)

module State = struct
  let depth = ref 0
  let level = ref Summary
  let reset () = depth := 0

  let indent () =
    Format.sprintf "[%2d] %s" !depth (String.make (!depth * 2) ' ')
end

module Handler : Hooks.HANDLER = struct
  let init ~spec:_ = State.reset ()
  let on_instr = Hooks.Noop.on_instr
  let on_prem_exit = Hooks.Noop.on_prem_exit
  let finish = Hooks.Noop.finish

  let on_rel_enter ~id ~at:_ ~values =
    Format.printf "%s→ %s\n%!" (State.indent ()) id;
    (* Only print inputs in full mode *)
    if !State.level = Full && values <> [] then
      Format.printf "%s%s%!" (State.indent ()) (format_values values);
    incr State.depth

  let on_rel_exit ~id ~at:_ ~success =
    decr State.depth;
    Format.printf "%s← %s [%s]\n%!" (State.indent ()) id
      (if success then "ok" else "fail")

  let on_rule_enter ~id ~rule_id ~at:_ =
    if !State.level = Full then
      Format.printf "%s→ %s/%s\n%!" (State.indent ()) id rule_id

  let on_rule_exit ~id ~rule_id ~at:_ ~success =
    if !State.level = Full then
      Format.printf "%s← %s/%s [%s]\n%!" (State.indent ()) id rule_id
        (if success then "ok" else "fail")

  let on_func_enter ~id ~at:_ ~values =
    Format.printf "%s→ $%s\n%!" (State.indent ()) id;
    (* Only print inputs in full mode *)
    if !State.level = Full && values <> [] then
      Format.printf "%s%s%!" (State.indent ()) (format_values values);
    incr State.depth

  let on_func_exit ~id ~at:_ =
    decr State.depth;
    Format.printf "%s← %s\n%!" (State.indent ()) id

  let on_clause_enter ~id ~clause_idx ~at:_ =
    if !State.level = Full then
      Format.printf "%s→ $%s/%d\n%!" (State.indent ()) id clause_idx

  let on_clause_exit ~id ~clause_idx:_ ~at:_ ~success:_ =
    if !State.level = Full then Format.printf "%s← $%s\n%!" (State.indent ()) id

  (* Function invocation return - decrement depth *)

  (* TODO: incr/decr depth *)
  let on_iter_prem_enter ~prem:_ ~at:_ =
    if !State.level = Full then
      Format.printf "%s  → [iteration]\n" (State.indent ())

  let on_iter_prem_exit ~at:_ =
    if !State.level = Full then
      Format.printf "%s  ← [iteration]\n%!" (State.indent ())

  let on_prem_enter ~prem ~at:_ =
    if !State.level = Full then
      Format.printf "%s  | -- %s\n%!" (State.indent ())
        (Il.Print.string_of_prem prem |> normalize_whitespace)
end

let make ?(level = Summary) () : (module Hooks.HANDLER) =
  State.level := level;
  (module Handler)
