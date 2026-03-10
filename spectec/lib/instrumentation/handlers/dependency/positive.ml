(* Positive dependency analysis for test mutation guidance.

   Tracks source paths (provenance) of variables and analyzes if-premises
   to extract field dependencies and mutation suggestions.

   Key features:
   - Per-test mutation tracking: mutations are organized by (premise_uid, test_id)
   - Provenance-based path resolution: uses vnote.provenance attached during
     JSON loading instead of a shadow symbolic environment
   - Mutation strategy extraction: generates concrete mutation suggestions

   Uses Common module for shared types and utilities.
*)

open Common.Source
module Il = Lang.Il
module Premise_uid = Instrumentation_static.Premise_uid
open Dep_common

(* === Positive-Analysis Specific Types === *)

(* Verbosity levels *)
type level = Summary | Full

(* Handler configuration *)
type config = {
  level : level;
  output : Instrumentation_core.Output.t;
  target_uids : int list option;
      (* None = use whitelist, Some [] = all, Some [uids] = filter *)
}

let default_config =
  {
    level = Summary;
    output = Instrumentation_core.Output.stdout;
    target_uids = None;
  }

let config = ref default_config
let fmt = ref Format.std_formatter

(* === Field Path Set for Efficient Dependency Tracking === *)

module FieldPathSet = Set.Make (struct
  type t = field_path

  let compare = compare
end)

(* Mutation suggestion types *)
type mutation_kind =
  | ToConst of Il.cmpop * Il.Value.t (* path <op> value *)
  | ToLength of Il.cmpop * Il.Value.t (* collection length constraint *)
  | Unknown of Il.Value.t (* over-approximation with value or type hint *)

type sym_mutation = {
  target_path : field_path option;
  suggestion : mutation_kind;
}

(* Compare two sym_mutations for equality (for deduplication) *)
let compare_sym_mutation m1 m2 =
  match (m1.target_path, m2.target_path) with
  | Some p1, Some p2 ->
      let path_cmp = compare p1 p2 in
      if path_cmp = 0 then
        (* Same path, compare suggestions *)
        match (m1.suggestion, m2.suggestion) with
        | ToConst (op1, v1), ToConst (op2, v2) ->
            let op_cmp = compare op1 op2 in
            if op_cmp = 0 then
              compare
                (Il.Print.string_of_value v1)
                (Il.Print.string_of_value v2)
            else op_cmp
        | ToLength (op1, v1), ToLength (op2, v2) ->
            let op_cmp = compare op1 op2 in
            if op_cmp = 0 then
              compare
                (Il.Print.string_of_value v1)
                (Il.Print.string_of_value v2)
            else op_cmp
        | Unknown _, Unknown _ -> 0 (* All Unknown are considered equal *)
        | ToConst _, _ -> -1
        | ToLength _, ToConst _ -> 1
        | ToLength _, _ -> -1
        | Unknown _, _ -> 1
      else path_cmp
  | None, None -> 0
  | Some _, None -> -1
  | None, Some _ -> 1

(* Negate comparison operator for test generation (to violate constraints). *)
let negate_cmp_op = function
  | `GtOp -> `LeOp
  | `GeOp -> `LtOp
  | `LtOp -> `GeOp
  | `LeOp -> `GtOp
  | `EqOp -> `NeOp
  | `NeOp -> `EqOp

(* Invert comparison operator for RHS-as-target case. *)
let invert_cmp_op = function
  | `EqOp -> `EqOp
  | `NeOp -> `NeOp
  | `LtOp -> `GtOp
  | `LeOp -> `GeOp
  | `GtOp -> `LtOp
  | `GeOp -> `LeOp

(* Negate mutation_kind to generate mutations that violate constraints *)
let negate_mutation_kind = function
  | ToConst (op, value) -> ToConst (negate_cmp_op op, value)
  | ToLength (op, value) -> ToLength (negate_cmp_op op, value)
  | Unknown hint -> Unknown hint

(* Negate a sym_mutation to generate mutations that violate constraints *)
let negate_sym_mutation (mut : sym_mutation) : sym_mutation =
  {
    target_path = mut.target_path;
    suggestion = negate_mutation_kind mut.suggestion;
  }

(* === Handler State === *)
module State = struct
  let output_file : string option ref = ref None

  (* --- Execution context: current relation / rule / test --- *)

  let current_relation : string ref = ref ""
  let current_rule : string ref = ref ""
  let current_test_id : string ref = ref ""

  (* --- Result accumulation: persists across tests --- *)

  (* Per-test symbolic mutations: premise_uid -> test_id -> sym_mutation list *)
  let per_test_sym_mutations :
      (int, (string, sym_mutation list) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 1000

  (* --- Coverage tracking: seen by this run --- *)

  (* Track visited UIDs to distinguish "not covered" from "no mutations" *)
  let seen_uids : (int, unit) Hashtbl.t = Hashtbl.create 1000

  (* Track UIDs that ever produced mutations - persists across clear_large_state *)
  let uids_with_mutations : (int, unit) Hashtbl.t = Hashtbl.create 256

  (* Target UIDs for filtering - empty means no filtering (use whitelist) *)
  let target_uids : (int, unit) Hashtbl.t = Hashtbl.create 16

  (* --- Diagnostics: why a UID has no mutations --- *)

  (* uid -> reason string (only first occurrence recorded) *)
  let no_mutation_reasons : (int, string) Hashtbl.t = Hashtbl.create 100

  let record_no_mutation_reason (uid : int) (reason : string) =
    if not (Hashtbl.mem no_mutation_reasons uid) then
      Hashtbl.replace no_mutation_reasons uid reason

  (* --- Telemetry --- *)

  let premise_count = ref 0
  let if_prem_count = ref 0
  let skipped_count = ref 0

  (* Set target UIDs for filtering *)

  let set_target_uids (uids : int list) =
    Hashtbl.clear target_uids;
    List.iter (fun uid -> Hashtbl.add target_uids uid ()) uids

  let is_target_uid (uid : int) : bool =
    (* If no target UIDs specified, fall back to whitelist behavior *)
    Hashtbl.length target_uids = 0 || Hashtbl.mem target_uids uid

  let reset () =
    Hashtbl.clear seen_uids;
    Hashtbl.clear uids_with_mutations;
    Hashtbl.clear no_mutation_reasons;
    current_relation := "";
    current_rule := "";
    current_test_id := "";
    Hashtbl.clear per_test_sym_mutations;
    premise_count := 0;
    if_prem_count := 0;
    skipped_count := 0

  (* Add per-test symbolic mutation result *)
  let add_per_test_sym_mutation (premise_uid : int)
      (mutations : sym_mutation list) =
    if mutations <> [] then (
      (* Negate all mutations to generate violations of constraints *)
      let negated_mutations = List.map negate_sym_mutation mutations in
      (* Deduplicate mutations for the same test *)
      let deduplicated_mutations =
        List.sort_uniq compare_sym_mutation negated_mutations
      in
      let test_id =
        if !current_test_id <> "" then !current_test_id else "default"
      in
      let test_table =
        match Hashtbl.find_opt per_test_sym_mutations premise_uid with
        | Some t -> t
        | None ->
            let t = Hashtbl.create 100 in
            Hashtbl.add per_test_sym_mutations premise_uid t;
            t
      in
      let existing =
        match Hashtbl.find_opt test_table test_id with
        | Some m -> m
        | None -> []
      in
      (* Merge and deduplicate with existing mutations *)
      let merged = existing @ deduplicated_mutations in
      let final_mutations = List.sort_uniq compare_sym_mutation merged in
      Hashtbl.replace test_table test_id final_mutations;
      Hashtbl.replace uids_with_mutations premise_uid ())

  (* Clear checkpoint data after it's been saved - frees memory for long runs. *)
  let clear_large_state () =
    Hashtbl.clear per_test_sym_mutations;
    Gc.compact () (* Force GC to reclaim memory *)
end

(* === Domain Knowledge: Ethereum Beacon Chain === *)

(* Check if a type refers to the state object *)
let is_state_type (t : Il.typ') : bool =
  match t with
  | Il.VarT (id, _) -> String.lowercase_ascii id.it = "beaconstate"
  | _ -> false

(* Check if a type refers to the block object *)
let is_block_type (t : Il.typ') : bool =
  match t with
  | Il.VarT (id, _) -> String.lowercase_ascii id.it = "signedbeaconblock"
  | _ -> false

(* === Provenance-based Path Resolution === *)

(* Convert IL provenance to dep_common field_path.
   No conversion needed for steps: field_step = Il.json_step via type equation. *)
let provenance_to_field_path (prov : Il.json_provenance) : field_path =
  let source, steps = prov in
  {
    source = (match source with Il.JsonState -> State | Il.JsonBlock -> Block);
    steps;
  }

(* Get the field_paths from a value's provenance list *)
let provs_of_val (v : Il.Value.t) : field_path list =
  List.map provenance_to_field_path v.note.provenance

(* Check if expression is wrapped in LenE *)
let is_length_exp (exp : Il.exp) : bool =
  match exp.it with Il.LenE _ -> true | _ -> false

(* Get the inner expression of LenE, or the expression itself *)
let strip_len (exp : Il.exp) : Il.exp =
  match exp.it with Il.LenE inner -> inner | _ -> exp

(* === String Formatting === *)

let string_of_cmp_op = function
  | `EqOp -> "=="
  | `NeOp -> "!="
  | `LtOp -> "<"
  | `LeOp -> "<="
  | `GtOp -> ">"
  | `GeOp -> ">="

(* String formatting for mutation suggestions *)
let string_of_mutation_kind = function
  | ToConst (op, v) ->
      Printf.sprintf "%s %s" (string_of_cmp_op op) (Il.Print.string_of_value v)
  | ToLength (op, v) ->
      Printf.sprintf "len %s %s" (string_of_cmp_op op)
        (Il.Print.string_of_value v)
  | Unknown v -> Printf.sprintf "UNKNOWN(%s)" (Il.Print.string_of_value v)

let string_of_sym_mutation (mut : sym_mutation) : string =
  let target_str =
    match mut.target_path with
    | Some path -> string_of_field_path path
    | None -> "?"
  in
  Printf.sprintf "%s → %s" target_str (string_of_mutation_kind mut.suggestion)

(* === Provenance-based Mutation Extraction === *)

let extract_symbolic_mutations (eval : Il.exp -> Il.Value.t) (exp : Il.exp) :
    sym_mutation list =
  let try_eval e = try Some (eval e) with _ -> None in
  (* For a (target_exp, constraint_exp, op) triple:
     evaluate target for provenance, constraint for concrete value.
     Returns sym_mutations for each provenance path. *)
  let make_muts_from_prov target_exp constraint_exp effective_op is_len =
    (* For LenE(inner), get provenance from inner, not the length value *)
    let prov_exp = strip_len target_exp in
    match try_eval prov_exp with
    | None -> []
    | Some tv ->
        let paths = provs_of_val tv in
        if paths = [] then []
        else
          let constraint_val = try_eval constraint_exp in
          List.map
            (fun path ->
              let suggestion =
                match constraint_val with
                | Some cv ->
                    if is_len then ToLength (effective_op, cv)
                    else
                      (* If the target is a bytes field but the constraint is a
                         plain integer, coerce the constraint to BytesV so that
                         testgen produces a length-preserving hex string mutation
                         instead of an integer that would fail SSZ conversion. *)
                      let cv' =
                        match (tv.it, cv.it) with
                        | Il.BytesV { len; _ }, Il.NumV (`Nat n) ->
                            Il.Value.make_bytes ~num:n ~len
                        | _ -> cv
                      in
                      ToConst (effective_op, cv')
                | None -> assert false
              in
              { target_path = Some path; suggestion })
            paths
  in
  match exp.it with
  | Il.CmpE (op, _, lhs, rhs) ->
      let lhs_is_len = is_length_exp lhs in
      let rhs_is_len = is_length_exp rhs in
      (* LHS as target: lhs op rhs *)
      let muts_lhs = make_muts_from_prov lhs rhs op lhs_is_len in
      (* RHS as target: rhs invert_op lhs *)
      let muts_rhs =
        make_muts_from_prov rhs lhs (invert_cmp_op op) rhs_is_len
      in
      muts_lhs @ muts_rhs
  | Il.CallE (_, _, args) ->
      (* Verification-function args: extract provenance from each argument *)
      List.concat_map
        (fun arg ->
          match arg.it with
          | Il.ExpA e -> (
              match try_eval e with
              | Some v ->
                  let paths = provs_of_val v in
                  List.map
                    (fun path ->
                      { target_path = Some path; suggestion = Unknown v })
                    paths
              | None -> [])
          | Il.DefA _ -> [])
        args
  | Il.MatchE (inner, pat) -> (
      match pat with
      | Il.ListP `Nil -> []
      | Il.ListP `Cons -> (
          (* Evaluate the inner expression (the list), not the MatchE bool result *)
          match try_eval inner with
          | Some v ->
              let paths = provs_of_val v in
              List.map
                (fun path ->
                  {
                    target_path = Some path;
                    suggestion =
                      ToLength
                        ( `GtOp,
                          Il.Value.Make.num Il.Typ.nat (`Nat (Bigint.of_int 0))
                        );
                  })
                paths
          | None -> [])
      | _ -> [])
  | Il.UnE (`NotOp, _, e) -> (
      match try_eval e with
      | Some v ->
          let paths = provs_of_val v in
          List.map
            (fun path ->
              {
                target_path = Some path;
                suggestion = ToConst (`EqOp, Il.Value.bool false);
              })
            paths
      | None -> [])
  | _ -> (
      match try_eval exp with
      | Some v ->
          let paths = provs_of_val v in
          List.map
            (fun path ->
              {
                target_path = Some path;
                suggestion = ToConst (`EqOp, Il.Value.bool true);
              })
            paths
      | None -> [])

(* Check if premise is an if-premise (possibly wrapped in IterPr) *)
let rec is_if_prem (prem : Il.prem) : bool =
  match prem.it with
  | Il.IfPr _ -> true
  | Il.IterPr (inner, _) -> is_if_prem inner
  | _ -> false

(* Strip negation wrappers: ¬e -> e *)
let rec strip_negation (exp : Il.exp) : Il.exp * bool =
  match exp.it with
  | Il.UnE (`NotOp, _, inner) ->
      let stripped, was_negated = strip_negation inner in
      (stripped, not was_negated)
  | _ -> (exp, false)

(* Strip = true / = false wrappers *)
let strip_bool_eq (exp : Il.exp) : Il.exp * bool =
  match exp.it with
  | Il.CmpE (`EqOp, _, inner, { it = Il.BoolE true; _ }) -> (inner, false)
  | Il.CmpE (`EqOp, _, inner, { it = Il.BoolE false; _ }) -> (inner, true)
  | Il.CmpE (`EqOp, _, { it = Il.BoolE true; _ }, inner) -> (inner, false)
  | Il.CmpE (`EqOp, _, { it = Il.BoolE false; _ }, inner) -> (inner, true)
  | _ -> (exp, false)

(* Diagnose why extract_symbolic_mutations returned empty for a given expression *)
let diagnose_no_mutations (eval : Il.exp -> Il.Value.t) (exp : Il.exp) : string
    =
  let try_eval e = try Some (eval e) with _ -> None in
  let val_info e =
    match try_eval e with
    | None -> "eval=false"
    | Some v ->
        let prov = v.note.provenance <> [] in
        let vstr = Il.Print.string_of_value v in
        (* Truncate long values *)
        let vstr =
          if String.length vstr > 40 then String.sub vstr 0 40 ^ "..." else vstr
        in
        if prov then Printf.sprintf "eval=true,prov=true,val=%s" vstr
        else Printf.sprintf "eval=true,prov=false,val=%s" vstr
  in
  match exp.it with
  | Il.CmpE (op, _, lhs, rhs) ->
      Printf.sprintf "CmpE(%s): lhs(%s) rhs(%s)" (string_of_cmp_op op)
        (val_info (strip_len lhs))
        (val_info (strip_len rhs))
  | Il.CallE _ -> "CallE: all args prov=NONE or eval failed"
  | Il.MatchE (inner, _) -> Printf.sprintf "MatchE: inner(%s)" (val_info inner)
  | Il.UnE (`NotOp, _, e) -> Printf.sprintf "UnE(NotOp): inner(%s)" (val_info e)
  | _ -> Printf.sprintf "Other: exp(%s)" (val_info exp)

(** Extract mutations from an if-expression, adjust for negation, and record. *)
let extract_and_record_if_mutations (eval : Il.exp -> Il.Value.t) (uid : int)
    (exp : Il.exp) : unit =
  let exp1, was_negated = strip_negation exp in
  let exp2, was_bool_eq_negated = strip_bool_eq exp1 in
  let total_negated = was_negated <> was_bool_eq_negated in
  let mutations = extract_symbolic_mutations eval exp2 in
  if mutations = [] then
    State.record_no_mutation_reason uid (diagnose_no_mutations eval exp2);
  let adjusted =
    if not total_negated then mutations
    else
      List.map
        (fun mut ->
          match mut.suggestion with
          | ToConst (`EqOp, ({ it = Il.BoolV b; _ } as v)) ->
              {
                mut with
                suggestion = ToConst (`EqOp, { v with it = Il.BoolV (not b) });
              }
          | _ -> mut)
        mutations
  in
  State.add_per_test_sym_mutation uid adjusted

(* === Handler Implementation === *)

module M : Instrumentation_core.Handler.S = struct
  let static_dependencies =
    [
      (module Instrumentation_static.Premise_uid.Premise_uid
      : Instrumentation_static.Static.S);
    ]

  let init ~spec =
    State.reset ();
    match spec with
    | Instrumentation_core.Handler.IlSpec _il_spec -> ()
    | Instrumentation_core.Handler.SlSpec _ -> ()

  let on_test_start ~test_case_id = State.current_test_id := test_case_id
  let on_test_end ~test_case_id:_ = State.current_test_id := ""
  (* Note: per_test_sym_mutations is preserved - it accumulates across tests *)

  let on_rel_enter ~id ~at:_ ~values:_ = State.current_relation := id

  let on_rel_exit ~id:_ ~at:_ ~success:_ =
    State.current_relation := "";
    State.current_rule := ""

  let on_rule_enter ~id:_ ~rule_id ~at:_ = State.current_rule := rule_id
  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success:_ = State.current_rule := ""
  let on_func_enter ~id:_ ~at:_ ~values:_ = ()
  let on_func_exit ~id:_ ~at:_ = ()
  let on_clause_enter ~id:_ ~clause_idx:_ ~at:_ = ()
  let on_clause_exit ~id:_ ~clause_idx:_ ~at:_ ~success:_ = ()
  let on_iter_prem_enter ~prem:_ ~at:_ = ()
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit
  let on_instr = Instrumentation_core.Noop.on_instr

  let on_prem_enter ~eval ~prem ~at:_ =
    State.premise_count := !State.premise_count + 1;
    if !State.premise_count mod 500 = 0 then
      Format.eprintf "\r[Positive] %d premises, %d if-prems, %d skipped...%!"
        !State.premise_count !State.if_prem_count !State.skipped_count;

    if not (is_if_prem prem) then ()
    else
      let prem_key = Premise_uid.prem_key prem in
      let uid = Premise_uid.assign_uid prem_key in
      Hashtbl.replace State.seen_uids uid ();

      let should_extract =
        if Hashtbl.length State.target_uids = 0 then
          is_whitelisted !State.current_relation
        else State.is_target_uid uid
      in
      if should_extract then
        match eval with
        | None -> State.record_no_mutation_reason uid "no eval closure"
        | Some eval_fn -> (
            State.if_prem_count := !State.if_prem_count + 1;
            let extract exp = extract_and_record_if_mutations eval_fn uid exp in
            match prem.it with
            | Il.IfPr exp -> extract exp
            | Il.IterPr ({ it = Il.IfPr exp; _ }, _) -> extract exp
            | _ -> ())

  let on_prem_exit ~prem:_ ~at:_ ~success:_ = ()

  (* Noop - logic moved to on_prem_enter *)
  let on_prem_fields = Instrumentation_core.Noop.on_prem_fields
  let on_rule_output ~id:_ ~rule_id:_ ~at:_ ~output_exps:_ = ()
  let on_clause_return ~id:_ ~clause_idx:_ ~at:_ ~return_exp:_ = ()

  let finish () =
    Format.fprintf !fmt "\n=== Symbolic Mutations ===\n\n";
    (* Print symbolic mutations organized by premise UID *)
    (* Collect entries from mutations *)
    let mutation_entries =
      Hashtbl.fold
        (fun uid tests acc -> (uid, tests) :: acc)
        State.per_test_sym_mutations []
    in

    (* Collect entries from target UIDs that have no mutations *)
    let missing_target_entries =
      Hashtbl.fold
        (fun uid _ acc ->
          if Hashtbl.mem State.per_test_sym_mutations uid then acc
          else (uid, Hashtbl.create 0) :: acc)
        State.target_uids []
    in

    let entries = mutation_entries @ missing_target_entries in
    let sorted =
      List.sort (fun (uid1, _) (uid2, _) -> compare uid1 uid2) entries
    in
    if sorted = [] then Format.fprintf !fmt "(no symbolic mutations found)\n\n"
    else
      List.iter
        (fun (uid, tests) ->
          Format.fprintf !fmt "premise %d:\n" uid;
          if Hashtbl.length tests = 0 then
            if Hashtbl.mem State.seen_uids uid then
              let reason =
                match Hashtbl.find_opt State.no_mutation_reasons uid with
                | Some r -> r
                | None -> "unknown"
              in
              Format.fprintf !fmt "  (analyzed but no mutations found: %s)\n"
                reason
            else Format.fprintf !fmt "  (not covered)\n"
          else
            Hashtbl.iter
              (fun test_id muts ->
                Format.fprintf !fmt "  test %s:\n" test_id;
                List.iter
                  (fun mut ->
                    Format.fprintf !fmt "    %s\n" (string_of_sym_mutation mut))
                  muts)
              tests;
          Format.fprintf !fmt "\n")
        sorted;
    Format.pp_print_flush !fmt ();

    (* Print no-mutation diagnostics to stderr for visibility.
       Use uids_with_mutations (persists across clear_large_state) so that
       the final report is accurate even after checkpoint clearing. *)
    let no_mut_uids =
      List.filter_map
        (fun (uid, tests) ->
          if
            Hashtbl.length tests = 0
            && not (Hashtbl.mem State.uids_with_mutations uid)
          then Some uid
          else None)
        sorted
    in
    if no_mut_uids <> [] then (
      Format.eprintf "\n[Positive] UIDs with no mutations:\n%!";
      List.iter
        (fun uid ->
          let reason =
            if not (Hashtbl.mem State.seen_uids uid) then "not covered"
            else
              match Hashtbl.find_opt State.no_mutation_reasons uid with
              | Some r -> r
              | None -> "unknown"
          in
          Format.eprintf "  uid=%d: %s\n%!" uid reason)
        no_mut_uids)
end

(* Result type for programmatic access *)
type result = {
  per_test_sym_mutations : (int * (string * sym_mutation list) list) list;
      (* premise_uid -> test_id -> sym_mutation list *)
}

let get_result () =
  {
    per_test_sym_mutations =
      Hashtbl.fold
        (fun uid tests acc ->
          let test_list =
            Hashtbl.fold
              (fun test_id muts sub_acc -> (test_id, muts) :: sub_acc)
              tests []
          in
          (uid, test_list) :: acc)
        State.per_test_sym_mutations [];
  }

(* Merge two results - combines per_test_sym_mutations from both *)
let merge_result (r1 : result) (r2 : result) : result =
  let merged = Hashtbl.create 256 in
  (* Add all from r1 *)
  List.iter
    (fun (uid, test_muts) ->
      let tbl = Hashtbl.create 64 in
      List.iter (fun (tid, muts) -> Hashtbl.replace tbl tid muts) test_muts;
      Hashtbl.replace merged uid tbl)
    r1.per_test_sym_mutations;
  (* Merge in r2 *)
  List.iter
    (fun (uid, test_muts) ->
      let tbl =
        match Hashtbl.find_opt merged uid with
        | Some t -> t
        | None ->
            let t = Hashtbl.create 64 in
            Hashtbl.replace merged uid t;
            t
      in
      List.iter
        (fun (tid, muts) ->
          let existing = Hashtbl.find_opt tbl tid |> Option.value ~default:[] in
          Hashtbl.replace tbl tid (existing @ muts))
        test_muts)
    r2.per_test_sym_mutations;
  (* Convert back to list format *)
  {
    per_test_sym_mutations =
      Hashtbl.fold
        (fun uid tbl acc ->
          let test_list =
            Hashtbl.fold (fun tid muts sub -> (tid, muts) :: sub) tbl []
          in
          (uid, test_list) :: acc)
        merged [];
  }

let restore (_result : result) = ()

module HandlerWithData :
  Instrumentation_core.Handler.S_with_data with type result = result = struct
  include M

  type nonrec result = result

  let get_result = get_result
  let restore = restore
end

(* Declare static analysis dependencies *)
let static_dependencies () =
  [
    (module Instrumentation_static.Premise_uid.Premise_uid
    : Instrumentation_static.Static.S);
    (module Instrumentation_static.Mutator_analysis.Mutator_analysis
    : Instrumentation_static.Static.S);
    (module Instrumentation_static.Type_tree : Instrumentation_static.Static.S);
  ]

let make cfg : (module Instrumentation_core.Handler.S) =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  (match cfg.target_uids with
  | Some uids -> State.set_target_uids uids
  | None -> ());
  (module M)

let make_with_data cfg =
  config := cfg;
  fmt := Instrumentation_core.Output.formatter cfg.output;
  (* Initialize target UIDs if provided *)
  (match cfg.target_uids with
  | Some uids -> State.set_target_uids uids
  | None -> Hashtbl.clear State.target_uids);
  (* Clear to use whitelist *)
  ( (module HandlerWithData : Instrumentation_core.Handler.S_with_data
      with type result = result),
    get_result )

(* Public function to clear large state - call after checkpoint save *)
let clear_large_state () = State.clear_large_state ()
