(* Branch coverage handler - Tracks rule and clause execution.

   Implements Hooks.HANDLER interface.
   Records all branches at init(), then tracks which are hit.

   Output levels:
   - Summary: stats + uncovered branches only
   - Full: all relations/functions with coverage markers

   Usage:
     let handler = Branch_coverage.make ~level:Full ()
*)

open Common.Source
module Il = Lang.Il
module Sl = Lang.Sl
open Util

(* Verbosity levels *)
type level = Summary | Full

module State = struct
  let level = ref Summary
  let all_rules : (string * string) list ref = ref []
  let all_clauses : (string * int) list ref = ref []
  let rules_hit : (string * string, int) Hashtbl.t = Hashtbl.create 64
  let clauses_hit : (string * int, int) Hashtbl.t = Hashtbl.create 64

  let reset () =
    all_rules := [];
    all_clauses := [];
    Hashtbl.clear rules_hit;
    Hashtbl.clear clauses_hit

  let incr tbl key =
    let count = Hashtbl.find_opt tbl key |> Option.value ~default:0 in
    Hashtbl.replace tbl key (count + 1)
end

(* Group items by their first component *)
let group_by items =
  List.fold_left
    (fun acc (k, v) ->
      let vs = List.assoc_opt k acc |> Option.value ~default:[] in
      (k, v :: vs) :: List.remove_assoc k acc)
    [] items
  |> List.sort compare

module Handler : Hooks.HANDLER = struct
  let init ~spec =
    State.reset ();
    match spec with
    | Hooks.IlSpec il_spec ->
        List.iter
          (fun def ->
            match def.it with
            | Il.RelD (id, _, _, rules) ->
                List.iter
                  (fun rule ->
                    let rule_id, _, _ = rule.it in
                    State.all_rules := (id.it, rule_id.it) :: !State.all_rules)
                  rules
            | Il.DecD (id, _, _, _, clauses) ->
                List.iteri
                  (fun idx _ ->
                    State.all_clauses := (id.it, idx) :: !State.all_clauses)
                  clauses
            | Il.TypD _ -> ())
          il_spec
    | Hooks.SlSpec sl_spec ->
        List.iter
          (fun def ->
            match def.it with
            | Sl.RelD (id, _, _, _) ->
                State.all_rules := (id.it, "0") :: !State.all_rules
            | Sl.DecD (id, _, _, _) ->
                State.all_clauses := (id.it, 0) :: !State.all_clauses
            | Sl.TypD _ -> ())
          sl_spec

  let on_rel_enter = Hooks.Noop.on_rel_enter
  let on_rel_exit = Hooks.Noop.on_rel_exit
  let on_rule_enter = Hooks.Noop.on_rule_enter

  let on_rule_exit ~id ~rule_id ~at:_ ~success =
    if success then State.incr State.rules_hit (id, rule_id)

  let on_func_enter = Hooks.Noop.on_func_enter
  let on_func_exit = Hooks.Noop.on_func_exit
  let on_clause_enter = Hooks.Noop.on_clause_enter

  let on_clause_exit ~id ~clause_idx ~at:_ ~success =
    if success then State.incr State.clauses_hit (id, clause_idx)

  let on_iter_prem_enter = Hooks.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Hooks.Noop.on_iter_prem_exit
  let on_prem_enter = Hooks.Noop.on_prem_enter
  let on_prem_exit = Hooks.Noop.on_prem_exit
  let on_instr = Hooks.Noop.on_instr

  (* --- Output: Summary mode (stats + uncovered only) --- *)

  let print_summary () =
    let rules_by_rel = group_by !State.all_rules in
    let clauses_by_func = group_by !State.all_clauses in

    (* Rules summary *)
    let total_rules = List.length !State.all_rules in
    if total_rules > 0 then (
      let hit =
        List.filter
          (fun key -> Hashtbl.mem State.rules_hit key)
          !State.all_rules
        |> List.length
      in
      Format.printf "Rules: %d/%d (%.2f%%)\n" hit total_rules
        (percentage hit total_rules);
      (* Uncovered rules *)
      let uncovered =
        List.filter_map
          (fun (rel, rules) ->
            let uncov =
              List.filter
                (fun r -> not (Hashtbl.mem State.rules_hit (rel, r)))
                rules
            in
            if uncov <> [] then Some (rel, uncov) else None)
          rules_by_rel
      in
      if uncovered <> [] then (
        Format.printf "\nUncovered rules:\n";
        List.iter
          (fun (rel, rules) ->
            List.iter (fun r -> Format.printf "  %s/%s\n" rel r) rules)
          uncovered));

    (* Clauses summary *)
    let total_clauses = List.length !State.all_clauses in
    if total_clauses > 0 then (
      let hit =
        List.filter
          (fun key -> Hashtbl.mem State.clauses_hit key)
          !State.all_clauses
        |> List.length
      in
      Format.printf "\nClauses: %d/%d (%.2f%%)\n" hit total_clauses
        (percentage hit total_clauses);
      (* Uncovered clauses *)
      let uncovered =
        List.filter_map
          (fun (func, idxs) ->
            let uncov =
              List.filter
                (fun i -> not (Hashtbl.mem State.clauses_hit (func, i)))
                idxs
            in
            if uncov <> [] then Some (func, uncov) else None)
          clauses_by_func
      in
      if uncovered <> [] then (
        Format.printf "\nUncovered clauses:\n";
        List.iter
          (fun (func, idxs) ->
            List.iter (fun i -> Format.printf "  $%s/%d\n" func i) idxs)
          uncovered))

  (* --- Output: Full mode (all branches with execution counts) --- *)

  let print_full () =
    let rules_by_rel = group_by !State.all_rules in
    let clauses_by_func = group_by !State.all_clauses in

    (* Relations *)
    if rules_by_rel <> [] then (
      Format.printf "-- Relations --\n\n";
      List.iter
        (fun (rel, rules) ->
          let rules = List.sort compare rules in
          let hit =
            List.filter (fun r -> Hashtbl.mem State.rules_hit (rel, r)) rules
            |> List.length
          in
          let total = List.length rules in
          Format.printf "relation %s: (%d/%d = %.2f%%)\n" rel hit total
            (percentage hit total);
          List.iter
            (fun r ->
              let count =
                Hashtbl.find_opt State.rules_hit (rel, r)
                |> Option.value ~default:0
              in
              Format.printf "  %s  rule %s\n" (format_count count) r)
            rules;
          Format.printf "\n")
        rules_by_rel);

    (* Functions *)
    if clauses_by_func <> [] then (
      Format.printf "-- Functions --\n\n";
      List.iter
        (fun (func, idxs) ->
          let idxs = List.sort compare idxs in
          let hit =
            List.filter (fun i -> Hashtbl.mem State.clauses_hit (func, i)) idxs
            |> List.length
          in
          let total = List.length idxs in
          Format.printf "def $%s: (%d/%d = %.2f%%)\n" func hit total
            (percentage hit total);
          List.iter
            (fun i ->
              let count =
                Hashtbl.find_opt State.clauses_hit (func, i)
                |> Option.value ~default:0
              in
              Format.printf "  %s  clause %d\n" (format_count count) i)
            idxs;
          Format.printf "\n")
        clauses_by_func)

  let finish () =
    Format.printf "\n=== Branch Coverage ===\n\n";
    match !State.level with
    | Summary -> print_summary ()
    | Full -> print_full ()
end

let make ?(level = Summary) () : (module Hooks.HANDLER) =
  State.level := level;
  (module Handler)
