(* Node coverage handler - Tracks premise and instruction execution.

   Implements Hooks.HANDLER interface.
   Records all nodes (premises for IL, instructions for SL) at init(),
   then tracks which are hit during execution.

   Output levels:
   - Summary: stats + uncovered items only
   - Full: GCOV-style annotated spec with execution counts

   Usage:
     let handler = Node_coverage.make ~level:Full ()
*)

open Common.Source
module Il = Lang.Il
module Sl = Lang.Sl

(* Verbosity levels *)
type level = Summary | Full

module State = struct
  let level = ref Summary
  let il_spec : Il.spec ref = ref []
  let sl_spec : Sl.spec ref = ref []
  let prems_hit : (region * string, int) Hashtbl.t = Hashtbl.create 256
  let instrs_hit : (region * string, int) Hashtbl.t = Hashtbl.create 256
  let total_prems = ref 0
  let total_instrs = ref 0

  let reset () =
    il_spec := [];
    sl_spec := [];
    Hashtbl.clear prems_hit;
    Hashtbl.clear instrs_hit;
    total_prems := 0;
    total_instrs := 0

  let incr tbl key =
    let count = Hashtbl.find_opt tbl key |> Option.value ~default:0 in
    Hashtbl.replace tbl key (count + 1)
end

(* Normalize whitespace *)
let normalize_ws s =
  let buf = Buffer.create (String.length s) in
  let last_ws = ref false in
  String.iter
    (fun c ->
      if c = ' ' || c = '\n' || c = '\t' || c = '\r' then (
        if not !last_ws then Buffer.add_char buf ' ';
        last_ws := true)
      else (
        Buffer.add_char buf c;
        last_ws := false))
    s;
  Buffer.contents buf

(* Truncate string to max length *)
let truncate max_len s =
  if String.length s > max_len then String.sub s 0 (max_len - 3) ^ "..." else s

(* Create a unique key for a premise using region + content prefix *)
let prem_key prem =
  let content = Il.Print.string_of_prem prem |> normalize_ws in
  (prem.at, truncate 30 content)

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
  let content = instr_header instr |> normalize_ws in
  (instr.at, content)

module Handler : Hooks.HANDLER = struct
  let rec count_il_prem prem =
    State.total_prems := !State.total_prems + 1;
    match prem.it with Il.IterPr (inner, _) -> count_il_prem inner | _ -> ()

  let rec count_sl_instr instr =
    State.total_instrs := !State.total_instrs + 1;
    match instr.it with
    | Sl.IfI (_, _, instrs, _) -> List.iter count_sl_instr instrs
    | Sl.CaseI (_, cases, _) ->
        List.iter (fun (_, instrs) -> List.iter count_sl_instr instrs) cases
    | Sl.OtherwiseI instrs -> List.iter count_sl_instr instrs
    | _ -> ()

  let init ~spec =
    State.reset ();
    match spec with
    | Hooks.IlSpec il_spec ->
        State.il_spec := il_spec;
        List.iter
          (fun def ->
            match def.it with
            | Il.RelD (_, _, _, rules) ->
                List.iter
                  (fun rule ->
                    let _, _, prems = rule.it in
                    List.iter count_il_prem prems)
                  rules
            | Il.DecD (_, _, _, _, clauses) ->
                List.iter
                  (fun clause ->
                    let _, _, prems = clause.it in
                    List.iter count_il_prem prems)
                  clauses
            | Il.TypD _ -> ())
          il_spec
    | Hooks.SlSpec sl_spec ->
        State.sl_spec := sl_spec;
        List.iter
          (fun def ->
            match def.it with
            | Sl.RelD (_, _, _, instrs) -> List.iter count_sl_instr instrs
            | Sl.DecD (_, _, _, instrs) -> List.iter count_sl_instr instrs
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
  let on_prem ~prem ~at:_ = State.incr State.prems_hit (prem_key prem)
  let on_instr ~instr ~at:_ = State.incr State.instrs_hit (instr_key instr)

  (* --- Output: Summary mode (stats + uncovered only) --- *)

  let print_summary_il () =
    let hit = Hashtbl.length State.prems_hit in
    let total = !State.total_prems in
    if total > 0 then (
      Format.printf "IL Premises: %d/%d (%.0f%%)\n" hit total
        (100.0 *. float hit /. float total);
      (* Collect uncovered *)
      let uncovered = ref [] in
      List.iter
        (fun def ->
          match def.it with
          | Il.RelD (id, _, _, rules) ->
              List.iter
                (fun rule ->
                  let rule_id, _, prems = rule.it in
                  List.iter
                    (fun prem ->
                      if not (Hashtbl.mem State.prems_hit (prem_key prem)) then
                        uncovered :=
                          (id.it, rule_id.it, Il.Print.string_of_prem prem)
                          :: !uncovered)
                    prems)
                rules
          | Il.DecD (id, _, _, _, clauses) ->
              List.iteri
                (fun idx clause ->
                  let _, _, prems = clause.it in
                  List.iter
                    (fun prem ->
                      if not (Hashtbl.mem State.prems_hit (prem_key prem)) then
                        uncovered :=
                          ( id.it,
                            Format.sprintf "clause/%d" idx,
                            Il.Print.string_of_prem prem )
                          :: !uncovered)
                    prems)
                clauses
          | Il.TypD _ -> ())
        !State.il_spec;
      if !uncovered <> [] then (
        Format.printf "\nUncovered premises:\n";
        List.iter
          (fun (rel, rule, content) ->
            Format.printf "  %s/%s:\n    %s\n" rel rule (normalize_ws content))
          (List.rev !uncovered)))

  let print_summary_sl () =
    let hit = Hashtbl.length State.instrs_hit in
    let total = !State.total_instrs in
    if total > 0 then
      Format.printf "SL Instructions: %d/%d (%.0f%%)\n" hit total
        (100.0 *. float hit /. float total)

  (* --- Output: Full mode (GCOV-style annotated spec) --- *)

  let fmt_count tbl key =
    match Hashtbl.find_opt tbl key with
    | Some n -> Format.sprintf "%4d" n
    | None -> "####"

  let print_il_prem indent prem =
    let count = fmt_count State.prems_hit (prem_key prem) in
    let content = Il.Print.string_of_prem prem |> normalize_ws in
    Format.printf "%s  %s-- %s\n" count indent content

  let rec print_sl_instr indent instr =
    let count = fmt_count State.instrs_hit (instr_key instr) in
    let max_len = max 40 (80 - String.length indent) in
    let content = instr_header instr |> normalize_ws |> truncate max_len in
    Format.printf "%5s %s%s\n" count indent content;
    match instr.it with
    | Sl.IfI (_, _, instrs, _) ->
        List.iter (print_sl_instr (indent ^ "  ")) instrs
    | Sl.CaseI (_, cases, _) ->
        List.iter
          (fun (guard, instrs) ->
            (* Print hyphen for guards (untracked) *)
            Format.printf "    - %s  Case %s:\n" indent
              (Sl.Print.string_of_guard guard);
            List.iter (print_sl_instr (indent ^ "    ")) instrs)
          cases
    | Sl.OtherwiseI instrs -> List.iter (print_sl_instr (indent ^ "  ")) instrs
    | _ -> ()

  let print_full_il () =
    List.iter
      (fun def ->
        match def.it with
        | Il.RelD (id, _, _, rules) ->
            Format.printf "\nrelation %s:\n" id.it;
            List.iter
              (fun rule ->
                let rule_id, _, prems = rule.it in
                Format.printf "      rule %s:\n" rule_id.it;
                List.iter (print_il_prem "    ") prems)
              rules
        | Il.DecD (id, _, _, _, clauses) ->
            Format.printf "\ndef $%s:\n" id.it;
            List.iteri
              (fun idx clause ->
                let _, _, prems = clause.it in
                Format.printf "      clause %d:\n" idx;
                List.iter (print_il_prem "    ") prems)
              clauses
        | Il.TypD _ -> ())
      !State.il_spec

  let print_full_sl () =
    List.iter
      (fun def ->
        match def.it with
        | Sl.RelD (id, _, _, instrs) ->
            Format.printf "\nrelation %s:\n" id.it;
            List.iter (print_sl_instr "  ") instrs
        | Sl.DecD (id, _, _, instrs) ->
            Format.printf "\ndef $%s:\n" id.it;
            List.iter (print_sl_instr "  ") instrs
        | Sl.TypD _ -> ())
      !State.sl_spec

  (* --- Finish: print report --- *)

  let finish () =
    Format.printf "\n=== Node Coverage ===\n\n";
    match !State.level with
    | Summary ->
        print_summary_il ();
        print_summary_sl ()
    | Full ->
        print_full_il ();
        print_full_sl ()
end

let make ?(level = Summary) () : (module Hooks.HANDLER) =
  State.level := level;
  (module Handler)
