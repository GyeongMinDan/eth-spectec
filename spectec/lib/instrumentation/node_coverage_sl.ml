(* SL Node coverage handler - Tracks instruction execution.

   Implements Hooks.HANDLER interface.
   Records all instructions at init(), then tracks which are hit during execution.

   Output levels:
   - Summary: stats + uncovered items only
   - Full: GCOV-style annotated spec with execution counts

   Usage:
     let handler = Node_coverage_sl.make ~level:Full ()
*)

open Common.Source
module Sl = Lang.Sl
open Util

(* Verbosity levels *)
type level = Summary | Full

module State = struct
  let level = ref Summary
  let sl_spec : Sl.spec ref = ref []
  let instrs_hit : (region * string, int) Hashtbl.t = Hashtbl.create 256
  let total_instrs = ref 0

  let reset () =
    sl_spec := [];
    Hashtbl.clear instrs_hit;
    total_instrs := 0

  let incr tbl key =
    let count = Hashtbl.find_opt tbl key |> Option.value ~default:0 in
    Hashtbl.replace tbl key (count + 1)
end

(* Get short header for instruction (without recursive children) *)
let instr_header instr =
  match instr.it with
  | Sl.IfI (exp, iterexps, _, _) ->
      Format.sprintf "If (%s)%s"
        (Sl.Print.string_of_exp exp)
        (Sl.Print.string_of_iterexps iterexps)
  | Sl.CaseI (exp, _, _) ->
      Format.sprintf "Case on %s" (Sl.Print.string_of_exp exp)
  | Sl.OtherwiseI _ -> "Otherwise"
  | Sl.LetI (exp_l, exp_r, iterexps) ->
      Format.sprintf "Let %s = %s%s"
        (Sl.Print.string_of_exp exp_l)
        (Sl.Print.string_of_exp exp_r)
        (Sl.Print.string_of_iterexps iterexps)
  | Sl.RuleI (id, notexp, iterexps) ->
      Format.sprintf "%s: %s%s"
        (Sl.Print.string_of_relid id)
        (Sl.Print.string_of_notexp notexp)
        (Sl.Print.string_of_iterexps iterexps)
  | Sl.ResultI [] -> "Relation holds"
  | Sl.ResultI exps ->
      Format.sprintf "Result %s" (Sl.Print.string_of_exps ", " exps)
  | Sl.ReturnI exp -> Format.sprintf "Return %s" (Sl.Print.string_of_exp exp)
  | Sl.DebugI exp -> Format.sprintf "Debug: %s" (Sl.Print.string_of_exp exp)

(* Create a unique key for an instruction using region + content header *)
let instr_key instr =
  let content = instr_header instr |> normalize_whitespace in
  (instr.at, content)

module Handler : Hooks.HANDLER = struct
  let rec count_instr instr =
    State.total_instrs := !State.total_instrs + 1;
    match instr.it with
    | Sl.IfI (_, _, instrs, _) -> List.iter count_instr instrs
    | Sl.CaseI (_, cases, _) ->
        List.iter (fun (_, instrs) -> List.iter count_instr instrs) cases
    | Sl.OtherwiseI instrs -> List.iter count_instr instrs
    | _ -> ()

  let init ~spec =
    State.reset ();
    match spec with
    | Hooks.IlSpec _ -> ()
    | Hooks.SlSpec sl_spec ->
        State.sl_spec := sl_spec;
        List.iter
          (fun def ->
            match def.it with
            | Sl.RelD (_, _, _, instrs) -> List.iter count_instr instrs
            | Sl.DecD (_, _, _, instrs) -> List.iter count_instr instrs
            | Sl.TypD _ -> ())
          sl_spec

  let on_rel_enter = Hooks.Noop.on_rel_enter
  let on_rel_exit = Hooks.Noop.on_rel_exit
  let on_rule_enter = Hooks.Noop.on_rule_enter
  let on_rule_exit = Hooks.Noop.on_rule_exit
  let on_func_enter = Hooks.Noop.on_func_enter
  let on_func_exit = Hooks.Noop.on_func_exit
  let on_clause_enter = Hooks.Noop.on_clause_enter
  let on_clause_exit = Hooks.Noop.on_clause_exit
  let on_iter_prem_enter = Hooks.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Hooks.Noop.on_iter_prem_exit
  let on_prem_enter = Hooks.Noop.on_prem_enter
  let on_prem_exit = Hooks.Noop.on_prem_exit
  let on_instr ~instr ~at:_ = State.incr State.instrs_hit (instr_key instr)

  (* --- Output: Summary mode (stats + uncovered only) --- *)

  let print_stats () =
    let hit = Hashtbl.length State.instrs_hit in
    let total = !State.total_instrs in
    if total > 0 then
      Format.printf "SL Instructions: %d/%d (%.2f%%)\n" hit total
        (percentage hit total)

  let print_uncovered () =
    let total = !State.total_instrs in
    if total > 0 then (
      (* Collect uncovered instructions *)
      let uncovered = ref [] in
      List.iter
        (fun def ->
          match def.it with
          | Sl.RelD (id, _, _, instrs) ->
              List.iter
                (fun instr ->
                  if not (Hashtbl.mem State.instrs_hit (instr_key instr)) then
                    uncovered := (id.it, instr_header instr) :: !uncovered)
                instrs
          | Sl.DecD (id, _, _, instrs) ->
              List.iter
                (fun instr ->
                  if not (Hashtbl.mem State.instrs_hit (instr_key instr)) then
                    uncovered := (id.it, instr_header instr) :: !uncovered)
                instrs
          | Sl.TypD _ -> ())
        !State.sl_spec;
      if !uncovered <> [] then (
        Format.printf "\nUncovered SL instructions:\n";
        List.iter
          (fun (rel, content) ->
            Format.printf "  %s:\n    %s\n" rel (normalize_whitespace content))
          (List.rev !uncovered)))

  (* --- Output: Full mode (GCOV-style annotated spec) --- *)

  let fmt_count tbl key =
    match Hashtbl.find_opt tbl key with
    | Some n -> Format.sprintf "%4d" n
    | None -> "####"

  let rec print_instr indent instr =
    let count = fmt_count State.instrs_hit (instr_key instr) in
    let max_len = max 40 (80 - String.length indent) in
    let content = instr_header instr |> summarize ~max_len in
    Format.printf "%5s %s%s\n" count indent content;
    match instr.it with
    | Sl.IfI (_, _, instrs, _) -> List.iter (print_instr (indent ^ "  ")) instrs
    | Sl.CaseI (_, cases, _) ->
        List.iter
          (fun (guard, instrs) ->
            (* Print hyphen for guards (untracked) *)
            Format.printf "    - %s  Case %s:\n" indent
              (Sl.Print.string_of_guard guard);
            List.iter (print_instr (indent ^ "    ")) instrs)
          cases
    | Sl.OtherwiseI instrs -> List.iter (print_instr (indent ^ "  ")) instrs
    | _ -> ()

  let print_full () =
    List.iter
      (fun def ->
        match def.it with
        | Sl.RelD (id, _, _, instrs) ->
            Format.printf "\nrelation %s:\n" id.it;
            List.iter (print_instr "  ") instrs
        | Sl.DecD (id, _, _, instrs) ->
            Format.printf "\ndef $%s:\n" id.it;
            List.iter (print_instr "  ") instrs
        | Sl.TypD _ -> ())
      !State.sl_spec

  (* --- Finish: print report --- *)

  let finish () =
    if !State.total_instrs > 0 then (
      Format.printf "\n=== SL Node Coverage ===\n\n";
      match !State.level with
      | Summary ->
          print_stats ();
          print_uncovered ()
      | Full ->
          print_stats ();
          print_full ())
end

let make ?(level = Summary) () : (module Hooks.HANDLER) =
  State.level := level;
  (module Handler)
