(* IL Node coverage handler - Tracks premise execution.

   Implements Instrumentation_core.Handler.S interface.
   Records all premises at init(), then tracks which are hit during execution.

   Output levels:
   - Summary: stats + uncovered items only
   - Full: GCOV-style annotated spec with execution counts

   Usage:
     let handler = Node_coverage_il.make { level = Full; output = Instrumentation_core.Output.stdout }
*)

open Common.Source
module Il = Lang.Il
open Instrumentation_core.Util

(* Verbosity levels *)
type level = Summary | Full

(* Handler configuration *)
type config = { level : level; output : Instrumentation_core.Output.t }

let default_config =
  { level = Summary; output = Instrumentation_core.Output.stdout }

let config = ref default_config
let fmt = ref Format.std_formatter

(* Runtime state - changes during execution *)
module State = struct
  let il_spec : Il.spec ref = ref []
  let prems_attempted : (region * string, int) Hashtbl.t = Hashtbl.create 256
  let prems_succeeded : (region * string, int) Hashtbl.t = Hashtbl.create 256
  let prems_failed : (region * string, int) Hashtbl.t = Hashtbl.create 256
  let prem_to_uid : (region * string, int) Hashtbl.t = Hashtbl.create 256
  let uid_to_prem : (int, region * string) Hashtbl.t = Hashtbl.create 256

  let prem_to_test : (region * string, string list) Hashtbl.t =
    Hashtbl.create 256

  let current_test_case_id : string option ref = ref None
  let next_uid = ref 0
  let total_prems = ref 0
  let total_if_prems = ref 0

  let reset () =
    il_spec := [];
    Hashtbl.clear prems_attempted;
    Hashtbl.clear prems_succeeded;
    Hashtbl.clear prems_failed;
    Hashtbl.clear prem_to_uid;
    Hashtbl.clear uid_to_prem;
    Hashtbl.clear prem_to_test;
    current_test_case_id := None;
    next_uid := 0;
    total_prems := 0;
    total_if_prems := 0

  (* Set current test case ID (called by runner before each test) *)
  let set_test_case_id id = current_test_case_id := Some id
  let clear_test_case_id () = current_test_case_id := None

  (* Record that a premise was covered by the current test case *)
  let record_premise_coverage key =
    match !current_test_case_id with
    | Some test_id ->
        let existing =
          Hashtbl.find_opt prem_to_test key |> Option.value ~default:[]
        in
        if not (List.mem test_id existing) then
          Hashtbl.replace prem_to_test key (test_id :: existing)
    | None -> ()

  let incr_count tbl key =
    let count = Hashtbl.find_opt tbl key |> Option.value ~default:0 in
    Hashtbl.replace tbl key (count + 1)

  (* Assign a stable UID to a premise key, or return existing UID *)
  let assign_uid key =
    match Hashtbl.find_opt prem_to_uid key with
    | Some uid -> uid
    | None ->
        let uid = !next_uid in
        next_uid := !next_uid + 1;
        Hashtbl.replace prem_to_uid key uid;
        Hashtbl.replace uid_to_prem uid key;
        uid
end

(* Create a unique key for a premise using region + content prefix *)
let prem_key prem =
  let content = Il.Print.string_of_prem prem |> normalize_whitespace in
  (prem.at, truncate 30 content)

module M : Instrumentation_core.Handler.S = struct
  let rec count_prem prem =
    State.total_prems := !State.total_prems + 1;
    match prem.it with
    | Il.LetPr _ -> ()
    | Il.IterPr (inner, _) -> count_prem inner
    | _ -> State.total_if_prems := !State.total_if_prems + 1

  (* Assign UIDs to all premises during init *)
  let rec assign_premise_uid prem =
    let key = prem_key prem in
    let _ = State.assign_uid key in
    match prem.it with
    (* | Il.LetPr _ -> () *)
    | Il.IterPr (inner, _) -> assign_premise_uid inner
    | _ -> ()

  let init ~spec =
    State.reset ();
    match spec with
    | Instrumentation_core.Handler.IlSpec il_spec ->
        State.il_spec := il_spec;
        List.iter
          (fun def ->
            match def.it with
            | Il.RelD (_, _, _, rules) ->
                List.iter
                  (fun rule ->
                    let _, _, prems = rule.it in
                    List.iter
                      (fun prem ->
                        count_prem prem;
                        assign_premise_uid prem)
                      prems)
                  rules
            | Il.DecD (_, _, _, _, clauses) ->
                List.iter
                  (fun clause ->
                    let _, _, prems = clause.it in
                    List.iter
                      (fun prem ->
                        count_prem prem;
                        assign_premise_uid prem)
                      prems)
                  clauses
            | Il.TypD _ -> ())
          il_spec
    | Instrumentation_core.Handler.SlSpec _ -> ()

  let on_rel_enter = Instrumentation_core.Noop.on_rel_enter
  let on_rel_exit = Instrumentation_core.Noop.on_rel_exit
  let on_rule_enter = Instrumentation_core.Noop.on_rule_enter
  let on_rule_exit = Instrumentation_core.Noop.on_rule_exit
  let on_func_enter = Instrumentation_core.Noop.on_func_enter
  let on_func_exit = Instrumentation_core.Noop.on_func_exit
  let on_clause_enter = Instrumentation_core.Noop.on_clause_enter
  let on_clause_exit = Instrumentation_core.Noop.on_clause_exit
  let on_iter_prem_enter = Instrumentation_core.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit

  let on_prem_enter ~prem ~at:_ =
    let key = prem_key prem in
    State.incr_count State.prems_attempted key;
    State.record_premise_coverage key

  (* Only track failures for non-let premises since let cannot fail *)
  let on_prem_exit ~prem ~at:_ ~success =
    let key = prem_key prem in
    if success then (
      State.incr_count State.prems_succeeded key;
      State.record_premise_coverage key)
    else
      match prem.it with
      | Il.LetPr _ -> ()
      | _ -> State.incr_count State.prems_failed key

  let on_instr = Instrumentation_core.Noop.on_instr
  let on_prem_fields = Instrumentation_core.Noop.on_prem_fields

  (* --- Output: Summary mode (stats + uncovered only) --- *)

  let print_stats () =
    let succeeded = Hashtbl.length State.prems_succeeded in
    let failed = Hashtbl.length State.prems_failed in
    let attempted = Hashtbl.length State.prems_attempted in
    let total = !State.total_prems in
    let total_if = !State.total_if_prems in
    if total > 0 then (
      Format.fprintf !fmt
        "IL Premises: %d/%d succeeded (%.2f%%), %d/%d attempted (%.2f%%)\n"
        succeeded total
        (percentage succeeded total)
        attempted total
        (percentage attempted total);
      Format.fprintf !fmt
        "If Premises: %d/%d failed at least once, %d never failed\n" failed
        total_if (attempted - failed))

  let print_uncovered () =
    let total = !State.total_prems in
    if total > 0 then (
      (* Collect uncovered - premises never successfully executed *)
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
                      if not (Hashtbl.mem State.prems_succeeded (prem_key prem))
                      then
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
                      if not (Hashtbl.mem State.prems_succeeded (prem_key prem))
                      then
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
        Format.fprintf !fmt "\nNever succeeded:\n";
        List.iter
          (fun (rel, rule, content) ->
            Format.fprintf !fmt "  %s/%s:\n    %s\n" rel rule
              (normalize_whitespace content))
          (List.rev !uncovered)))

  (* --- Output: Full mode (GCOV-style annotated spec) --- *)

  (* Format as succ/fail - omit fail for let premises *)
  let fmt_succ_fail prem =
    let key = prem_key prem in
    let succ =
      Hashtbl.find_opt State.prems_succeeded key |> Option.value ~default:0
    in
    let succ_str = format_count succ in
    match prem.it with
    | LetPr _ -> Format.sprintf "%s     " succ_str
    | _ ->
        let fail =
          Hashtbl.find_opt State.prems_failed key |> Option.value ~default:0
        in
        let fail_str = format_count fail in
        Format.sprintf "%s/%s" succ_str fail_str

  let get_prem_succeeded key =
    Hashtbl.find_opt State.prems_succeeded key |> Option.value ~default:0

  let print_prem indent prem =
    let succ_fail = fmt_succ_fail prem in
    let content = Il.Print.string_of_prem prem |> normalize_whitespace in
    Format.fprintf !fmt "%d: %s %s-- %s\n"
      (State.assign_uid (prem_key prem))
      succ_fail indent content

  let print_prems indent prems =
    List.iter (print_prem indent) prems;
    (* Print success count for final premise *)
    match List.rev prems with
    | last :: _ ->
        let key = prem_key last in
        let succ = get_prem_succeeded key in
        Format.fprintf !fmt "%d: %s      %sSUCCESS\n" (State.assign_uid key)
          (format_count succ) indent
    | [] -> ()

  let print_full () =
    List.iter
      (fun def ->
        match def.it with
        | Il.RelD (id, _, _, rules) ->
            Format.fprintf !fmt "\nrelation %s:\n" id.it;
            List.iter
              (fun rule ->
                let rule_id, _, prems = rule.it in
                Format.fprintf !fmt "      rule %s:\n" rule_id.it;
                print_prems "    " prems)
              rules
        | Il.DecD (id, _, _, _, clauses) ->
            Format.fprintf !fmt "\ndef $%s:\n" id.it;
            List.iteri
              (fun idx clause ->
                let _, _, prems = clause.it in
                Format.fprintf !fmt "      clause %d:\n" idx;
                print_prems "    " prems)
              clauses
        | Il.TypD _ -> ())
      !State.il_spec

  (* --- Finish: print report --- *)

  let finish () =
    if !State.total_prems > 0 then (
      Format.fprintf !fmt "\n=== IL Node Coverage ===\n\n";
      match !config.level with
      | Summary ->
          print_stats ();
          print_uncovered ()
      | Full ->
          print_stats ();
          print_full ())
end

(* Result type for programmatic access *)
type result = {
  prems_attempted : ((region * string) * int) list; (* key * count *)
  prems_succeeded : ((region * string) * int) list; (* key * count *)
  prem_to_uid : ((region * string) * int) list; (* key * uid *)
  uid_to_prem : (int * (region * string)) list; (* uid * key *)
  prem_to_test : ((region * string) * string list) list;
      (* key * test_case_ids *)
  total_prems : int;
}

let get_result () =
  {
    prems_attempted = State.prems_attempted |> Hashtbl.to_seq |> List.of_seq;
    prems_succeeded = State.prems_succeeded |> Hashtbl.to_seq |> List.of_seq;
    prem_to_uid = State.prem_to_uid |> Hashtbl.to_seq |> List.of_seq;
    uid_to_prem = State.uid_to_prem |> Hashtbl.to_seq |> List.of_seq;
    prem_to_test = State.prem_to_test |> Hashtbl.to_seq |> List.of_seq;
    total_prems = !State.total_prems;
  }

(* Restore state from a previous result (for checkpoint resume) *)
let restore result =
  Hashtbl.clear State.prems_attempted;
  Hashtbl.clear State.prems_succeeded;
  Hashtbl.clear State.prem_to_uid;
  Hashtbl.clear State.uid_to_prem;
  Hashtbl.clear State.prem_to_test;
  List.iter
    (fun (key, count) -> Hashtbl.replace State.prems_attempted key count)
    result.prems_attempted;
  List.iter
    (fun (key, count) -> Hashtbl.replace State.prems_succeeded key count)
    result.prems_succeeded;
  List.iter
    (fun (key, uid) ->
      Hashtbl.replace State.prem_to_uid key uid;
      Hashtbl.replace State.uid_to_prem uid key)
    result.prem_to_uid;
  List.iter
    (fun (key, test_cases) -> Hashtbl.replace State.prem_to_test key test_cases)
    result.prem_to_test;
  State.total_prems := result.total_prems;
  (* Update next_uid to be higher than any existing UID *)
  State.next_uid :=
    List.fold_left
      (fun max_uid (uid, _) -> max max_uid uid)
      0 result.uid_to_prem
    + 1

(* Expose test case ID setter for use by runner *)
let set_test_case_id = State.set_test_case_id
let clear_test_case_id = State.clear_test_case_id

(* Handler with data access - implements HANDLER_WITH_DATA signature *)
module HandlerWithData :
  Instrumentation_core.Handler.S_with_data with type result = result = struct
  include M

  type nonrec result = result

  let get_result = get_result
  let restore = restore
end

let make cfg =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  (module M : Instrumentation_core.Handler.S)

(* Create handler with data getter for programmatic access.
   Usage:
     let handler, get_coverage = Node_coverage.make_with_data cfg in
     Hooks.set_handlers [handler];
     (* ... run interpreter ... *)
     let data = get_coverage () in
*)
let make_with_data cfg =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  ( (module HandlerWithData : Instrumentation_core.Handler.S_with_data
      with type result = result),
    get_result )
