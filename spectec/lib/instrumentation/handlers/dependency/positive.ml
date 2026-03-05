(* Positive dependency analysis for test mutation guidance.

   Tracks source paths (provenance) of variables and analyzes if-premises
   to extract field dependencies and mutation suggestions.

   Key features:
   - Per-test mutation tracking: mutations are organized by (premise_uid, test_id)
   - Symbolic expression tracking: preserves full comparison context
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

(* === Symbolic Expression Types === *)

(* Maps variables to their defining expression *)
type sym_env = (string, Il.exp) Hashtbl.t

(* Type hint for unknown mutations when value can't be evaluated *)
type unknown_hint =
  | ValueHint of Il.Value.t (* We have the actual value *)
  | TypeHint of Il.typ' (* We only have the type (unwrapped) *)
  | NoHint (* No information available *)

(* Mutation suggestion types *)
type mutation_kind =
  | ToConst of Il.cmpop * Il.Value.t (* path <op> value *)
  | ToLength of Il.cmpop * Il.Value.t (* collection length constraint *)
  | Unknown of unknown_hint (* over-approximation with value or type hint *)

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
              (* Compare values by their string representation for simplicity *)
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

(* Negate comparison operator for test generation (to violate constraints).
   This is different from invert_cmp_op: we want to generate mutations that
   violate the constraint, so we negate the operator. *)
let negate_cmp_op = function
  | `GtOp -> `LeOp (* x > n violated by x <= n *)
  | `GeOp -> `LtOp (* x >= n violated by x < n *)
  | `LtOp -> `GeOp (* x < n violated by x >= n *)
  | `LeOp -> `GtOp (* x <= n violated by x > n *)
  | `EqOp -> `NeOp (* x == n violated by x != n *)
  | `NeOp -> `EqOp (* x != n violated by x == n *)

(* Negate mutation_kind to generate mutations that violate constraints *)
let negate_mutation_kind = function
  | ToConst (op, value) -> ToConst (negate_cmp_op op, value)
  | ToLength (op, value) -> ToLength (negate_cmp_op op, value)
  | Unknown hint -> Unknown hint (* Unknown mutations are not negated *)

(* Negate a sym_mutation to generate mutations that violate constraints *)
let negate_sym_mutation (mut : sym_mutation) : sym_mutation =
  {
    target_path = mut.target_path;
    suggestion = negate_mutation_kind mut.suggestion;
  }

(* Frame for tracking sym_env bindings in scope *)
type pos_frame = { local_env : sym_env; is_barrier : bool }

(* === Handler State === *)
module State = struct
  let output_file : string option ref = ref None

  (* --- Static data: loaded once from spec, read-only at runtime --- *)

  let relation_inputs : (string, string list) Hashtbl.t = Hashtbl.create 50
  let relation_outputs : (string, string list) Hashtbl.t = Hashtbl.create 50
  let relation_io_indices : (string, int list) Hashtbl.t = Hashtbl.create 50
  let function_params : (string, string list) Hashtbl.t = Hashtbl.create 100

  (* Per-function interior IfPr premises for static inlining:
     fname -> (param_names, [(uid, if_prem)] list) *)
  let func_interiors : (string, string list * (int * Il.prem) list) Hashtbl.t =
    Hashtbl.create 100

  (* --- Execution context: current relation / rule / test --- *)

  let current_relation : string ref = ref ""
  let current_rule : string ref = ref ""
  let current_test_id : string ref = ref ""

  (* Current evaluation function from interpreter *)
  let current_eval : (Il.exp -> Il.Value.t) ref =
    ref (fun _ -> Il.Value.text "init")

  (* --- Symbolic environment: variable bindings with frame-based scoping --- *)

  let sym_env : sym_env = Hashtbl.create 100

  (* Frame stack for sym_env backtracking *)
  let frames : pos_frame list ref = ref []

  (* --- Relation call stack: args pushed at RulePr enter, popped at exit --- *)

  (* Stack of pending call args for nested relation calls *)
  (* Each entry: (relation_id, input_exprs, output_exprs) *)
  let call_args_stack : (string * Il.exp list * Il.exp list) list ref = ref []

  let push_call_args rel_id inputs outputs =
    call_args_stack := (rel_id, inputs, outputs) :: !call_args_stack

  let pop_call_args () =
    match !call_args_stack with
    | entry :: rest ->
        call_args_stack := rest;
        Some entry
    | [] -> None

  (* Peek at top of stack without popping (for output binding in on_prem_exit) *)
  let peek_call_args () =
    match !call_args_stack with entry :: _ -> Some entry | [] -> None

  (* --- Result accumulation: persists across tests --- *)

  (* Per-test symbolic mutations: premise_uid -> test_id -> sym_mutation list *)
  let per_test_sym_mutations :
      (int, (string, sym_mutation list) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 1000

  (* --- Coverage tracking: seen by this run --- *)

  (* Already-analyzed premises (by location string) *)
  let seen_prems : (string, unit) Hashtbl.t = Hashtbl.create 1000

  (* Track visited UIDs to distinguish "not covered" from "no mutations" *)
  let seen_uids : (int, unit) Hashtbl.t = Hashtbl.create 1000

  (* Target UIDs for filtering - empty means no filtering (use whitelist) *)
  let target_uids : (int, unit) Hashtbl.t = Hashtbl.create 16

  (* --- Telemetry --- *)

  let premise_count = ref 0
  let if_prem_count = ref 0
  let skipped_count = ref 0
  let func_depth = ref 0

  (* Set target UIDs for filtering *)

  let set_target_uids (uids : int list) =
    Hashtbl.clear target_uids;
    List.iter (fun uid -> Hashtbl.add target_uids uid ()) uids

  let is_target_uid (uid : int) : bool =
    (* If no target UIDs specified, fall back to whitelist behavior *)
    Hashtbl.length target_uids = 0 || Hashtbl.mem target_uids uid

  let reset () =
    Hashtbl.clear sym_env;
    Hashtbl.clear relation_inputs;
    Hashtbl.clear relation_outputs;
    Hashtbl.clear relation_io_indices;
    Hashtbl.clear func_interiors;
    Hashtbl.clear seen_prems;
    Hashtbl.clear seen_uids;
    current_relation := "";
    current_rule := "";
    current_test_id := "";
    current_test_id := "";
    frames := [];
    call_args_stack := [];
    Hashtbl.clear per_test_sym_mutations;
    premise_count := 0;
    if_prem_count := 0;
    skipped_count := 0

  let already_seen loc = Hashtbl.mem seen_prems loc
  let mark_seen loc = Hashtbl.replace seen_prems loc ()

  (* Frame management for sym_env backtracking *)
  let push_sym_frame () =
    let new_frame = { local_env = Hashtbl.create 20; is_barrier = false } in
    frames := new_frame :: !frames

  let push_call_frame () =
    let new_frame = { local_env = Hashtbl.create 20; is_barrier = true } in
    frames := new_frame :: !frames

  let pop_sym_frame_success () =
    match !frames with
    | frame :: rest -> (
        frames := rest;
        (* Merge local_env into parent frame or global sym_env *)
        match rest with
        | parent :: _ ->
            Hashtbl.iter
              (fun k v -> Hashtbl.replace parent.local_env k v)
              frame.local_env
        | [] ->
            Hashtbl.iter
              (fun k v -> Hashtbl.replace sym_env k v)
              frame.local_env)
    | [] -> ()

  let pop_sym_frame_failure () =
    match !frames with _ :: rest -> frames := rest | [] -> ()

  (* Lookup in sym_env: check frames from top to bottom, then global *)
  let lookup_sym (id : string) : Il.exp option =
    let rec check_frames fs =
      match fs with
      | [] -> Hashtbl.find_opt sym_env id
      | frame :: rest -> (
          match Hashtbl.find_opt frame.local_env id with
          | Some v -> Some v
          | None -> if frame.is_barrier then None else check_frames rest)
    in
    check_frames !frames

  (* Bind in current frame's local_env (or global if no frame) *)
  let bind_sym (id : string) (expr : Il.exp) : unit =
    match !frames with
    | frame :: _ -> Hashtbl.replace frame.local_env id expr
    | [] -> Hashtbl.replace sym_env id expr

  (* Add per-test symbolic mutation result *)
  let add_per_test_sym_mutation (premise_uid : int)
      (mutations : sym_mutation list) =
    if mutations <> [] then
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
      Hashtbl.replace test_table test_id final_mutations

  (* Clear checkpoint data after it's been saved - frees memory for long runs.
     Per-test state (sym_env, seen_prems) is already cleared in on_test_end. *)
  let clear_large_state () =
    Hashtbl.clear per_test_sym_mutations;
    Gc.compact () (* Force GC to reclaim memory *)
end

(* Lookup function ref - set by State module after initialization *)
(* This allows resolvers defined before State to use frame-aware lookup *)
let lookup_sym_ref : (string -> Il.exp option) ref = ref (fun _ -> None)

(* Forward references for mutual recursion *)
let expand_vars_ref : (sym_env -> Il.exp -> Il.exp) ref = ref (fun _ e -> e)

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

(* Check if a type refers to the block message (body) object *)
let is_message_type (t : Il.typ') : bool =
  match t with
  | Il.VarT (id, _) -> String.lowercase_ascii id.it = "beaconblock"
  | _ -> false

(* === Expression Resolution (Positive-specific: detailed symbolic tracking) === *)

(* Resolve expression to structured field_path.
   More restrictive than resolve_to_path - only returns paths that can be mutated.
   Complex expressions (BinE, UnE, LenE, etc.) return None.
   Uses sym_env for variable lookups.
   
   Domain knowledge: State variables always refer to the same state object,
   so we can infer State source for common state variable names.
*)
let rec resolve_to_field_path (sym_env : sym_env) (exp : Il.exp) :
    field_path option =
  resolve_to_field_path_with_visited sym_env exp []

and resolve_to_field_path_with_visited (sym_env : sym_env) (exp : Il.exp)
    (visited : string list) : field_path option =
  (* Use frame-aware lookup instead of direct hashtable access *)
  match exp.it with
  (* Variables: look up and recurse *)
  | Il.VarE id -> (
      let fallback_path ~use_local =
        if is_state_type exp.note then Some { source = State; steps = [] }
        else if is_block_type exp.note then Some { source = Block; steps = [] }
        else if is_message_type exp.note then
          (* Resolve BeaconBlockBody variables to BLOCK.MESSAGE *)
          Some { source = Block; steps = [ FieldAccess "MESSAGE" ] }
        else if use_local then Some { source = Local id.it; steps = [] }
        else Some { source = Unknown; steps = [ FieldAccess id.it ] }
      in

      if List.mem id.it visited then fallback_path ~use_local:false
      else
        match !lookup_sym_ref id.it with
        | Some expr -> (
            (* Check for immediate self-reference *)
            match expr.it with
            | Il.VarE id' when id'.it = id.it -> fallback_path ~use_local:true
            | _ -> (
                (* Recurse with new visited *)
                match
                  resolve_to_field_path_with_visited sym_env expr
                    (id.it :: visited)
                with
                | Some path -> Some path
                | None -> fallback_path ~use_local:false))
        | None -> fallback_path ~use_local:false)
  (* Field access: base.field *)
  | Il.DotE (base, atom) -> (
      match resolve_to_field_path_with_visited sym_env base visited with
      | Some base_path ->
          Some
            (append_step base_path
               (FieldAccess (Lang.Xl.Atom.string_of_atom atom.it)))
      | None -> None)
  (* Array indexing: base[idx] *)
  | Il.IdxE (base, idx) -> (
      match resolve_to_field_path_with_visited sym_env base visited with
      | None -> None
      | Some base_path -> (
          (* Try to resolve index *)
          match idx.it with
          | Il.NumE n -> (
              (* Constant index *)
              match n with
              | `Nat bi -> (
                  try
                    let i = Bigint.to_int_exn bi in
                    Some (append_step base_path (IndexAccess (ConstInt i)))
                  with _ -> None (* Index too large *))
              | _ -> None (* Non-nat index *))
          | _ -> (
              (* Try to evaluate the index expression to get a concrete value *)
              (* No longer use PathRef - only concrete indices are allowed *)
              let v_opt = try Some (!State.current_eval idx) with _ -> None in
              match v_opt with
              | Some v -> (
                  match v.it with
                  | Il.NumV (`Nat bi) -> (
                      try
                        let i = Bigint.to_int_exn bi in
                        Some (append_step base_path (IndexAccess (ConstInt i)))
                      with _ -> None)
                  | _ -> None)
              | None -> None)))
  | Il.SubE (inner, _)
  | Il.UpCastE (_, inner)
  | Il.DownCastE (_, inner)
  | Il.IterE (inner, _) ->
      resolve_to_field_path_with_visited sym_env inner visited
  (* Optional: unwrap if Some *)
  | Il.OptE (Some inner) ->
      resolve_to_field_path_with_visited sym_env inner visited
  | Il.OptE None -> None
  | Il.UpdE (inner, _, _) ->
      resolve_to_field_path_with_visited sym_env inner visited
  | Il.CallE (id, _, args) ->
      (* Special handling for filter_list_: approximate to first argument *)
      if
        String.starts_with ~prefix:"filter_list_" id.it
        || String.starts_with ~prefix:"filter_list_2" id.it
      then
        match args with
        | { it = Il.ExpA e; _ } :: _ ->
            resolve_to_field_path_with_visited sym_env e visited
        | _ -> None
      else None
  (* Everything else: can't represent as mutable path *)
  | _ -> None

let rec expand_vars (sym_env : sym_env) (exp : Il.exp) : Il.exp =
  expand_vars_with_visited sym_env exp [] 0

and expand_vars_with_visited (sym_env : sym_env) (exp : Il.exp)
    (visited : string list) (depth : int) : Il.exp =
  if depth > 100 then exp
  else
    let recurse child =
      expand_vars_with_visited sym_env child visited (depth + 1)
    in
    match exp.it with
    | Il.VarE id -> (
        if List.mem id.it visited then exp
        else
          match !lookup_sym_ref id.it with
          | Some e -> (
              match e.it with
              | Il.VarE id' when id'.it = id.it -> exp
              | _ ->
                  expand_vars_with_visited sym_env e (id.it :: visited)
                    (depth + 1))
          | None -> exp)
    | Il.UpdE (inner, path, value) ->
        (* Depth guards to prevent exponential blowup in deeply nested state updates *)
        if depth > 10 then exp
        else
          let inner' =
            match inner.it with Il.VarE _ -> recurse inner | _ -> inner
          in
          let value' = if depth > 5 then value else recurse value in
          if inner' == inner && value' == value then exp
          else { exp with it = Il.UpdE (inner', path, value') }
    | Il.CaseE _ | Il.HoldE _ ->
        (* Leave variant constructors unexpanded — matching original behavior *)
        exp
    | Il.CallE (id, _, args)
      when String.starts_with ~prefix:"filter_list_" id.it
           || String.starts_with ~prefix:"filter_list_2" id.it -> (
        (* Approximate filter_list_ calls by expanding just the first (list) argument *)
        match args with
        | { it = Il.ExpA e; _ } :: _ -> recurse e
        | _ -> Il.Traverse.map_children_exp recurse exp)
    | _ -> Il.Traverse.map_children_exp recurse exp

(* Initialize mutual recursion refs *)
let () = expand_vars_ref := expand_vars

(* Extract path from expression (wrapper around resolve_to_field_path) *)
let rec extract_paths_from_exp (sym_env : sym_env) (exp : Il.exp) :
    field_path list =
  extract_paths_from_exp_with_visited sym_env exp []

and extract_paths_from_exp_with_visited (sym_env : sym_env) (exp : Il.exp)
    (visited : Il.exp list) : field_path list =
  if List.exists (fun e -> e == exp) visited || List.length visited > 50 then []
  else
    match resolve_to_field_path sym_env exp with
    | Some p -> [ p ]
    | None -> (
        match exp.it with
        | Il.VarE _ ->
            (* Should have been returned by resolve_to_field_path *)
            assert false
        | Il.CaseE _ | Il.HoldE _ -> [] (* opaque constructors *)
        | _ ->
            Il.Traverse.fold_children_exp ( @ ) []
              (fun e ->
                extract_paths_from_exp_with_visited sym_env e (exp :: visited))
              exp)

(* Check if premise is an if-premise *)
let rec is_if_prem (prem : Il.prem) : bool =
  match prem.it with
  | Il.IfPr _ -> true
  | Il.IterPr (inner, _) -> is_if_prem inner
  | _ -> false

(* === String Formatting === *)

let string_of_cmp_op = function
  | `EqOp -> "=="
  | `NeOp -> "!="
  | `LtOp -> "<"
  | `LeOp -> "<="
  | `GtOp -> ">"
  | `GeOp -> ">="

(* String formatting for symbolic expressions *)

(* String formatting for mutation suggestions *)
let string_of_mutation_kind = function
  | ToConst (op, v) ->
      Printf.sprintf "%s %s" (string_of_cmp_op op) (Il.Print.string_of_value v)
  | ToLength (op, v) ->
      Printf.sprintf "len %s %s" (string_of_cmp_op op)
        (Il.Print.string_of_value v)
  | Unknown hint ->
      Printf.sprintf "UNKNOWN%s"
        (match hint with
        | ValueHint v -> Printf.sprintf "(%s)" (Il.Print.string_of_value v)
        | TypeHint t ->
            Printf.sprintf "[%s]"
              (Il.Print.string_of_typ
                 { it = t; at = Common.Source.no_region; note = () })
        | NoHint -> "")

let string_of_sym_mutation (mut : sym_mutation) : string =
  let target_str =
    match mut.target_path with
    | Some path -> string_of_field_path path
    | None -> "?"
  in
  Printf.sprintf "%s → %s" target_str (string_of_mutation_kind mut.suggestion)

(* === New Mutation Extraction Logic === *)

(* Invert comparison operator for algebraic rearrangement *)
let invert_cmp_op = function
  | `EqOp -> `EqOp
  | `NeOp -> `NeOp
  | `LtOp -> `GtOp
  | `LeOp -> `GeOp
  | `GtOp -> `LtOp
  | `GeOp -> `LeOp

(* String formatting for symbolic expressions (Il.exp) *)
let string_of_sym_expr (exp : Il.exp) : string = Il.Print.string_of_exp exp

(* Algebraically rearrange comparison to isolate target_path on LHS.
   For A < B + C with target=B, returns (B, >, A - C).
   Returns None if target_path not found or rearrangement not possible. *)
(* Algebraically rearrange comparison to isolate target_path on LHS.
   For A < B + C with target=B, returns (B, >, A - C).
   Returns None if target_path not found or rearrangement not possible. *)
let algebraic_rearrange (lhs_exp : Il.exp) (rhs_exp : Il.exp) (op : Il.cmpop)
    (target_path : field_path) (sym_env : sym_env) :
    (Il.cmpop * Il.exp * bool) option =
  (* Recursively extract paths to check containment *)
  let paths_lhs = extract_paths_from_exp sym_env lhs_exp in
  let paths_rhs = extract_paths_from_exp sym_env rhs_exp in
  let in_lhs = List.mem target_path paths_lhs in
  let in_rhs = List.mem target_path paths_rhs in

  match (in_lhs, in_rhs) with
  | true, false -> (
      (* Target is on LHS *)
      (* Check if simple path match *)
      match resolve_to_field_path sym_env lhs_exp with
      | Some p when p = target_path -> Some (op, rhs_exp, false)
      | _ -> (
          (* Check for len(path) *)
          match lhs_exp.it with
          | Il.LenE inner -> (
              match resolve_to_field_path sym_env inner with
              | Some p when p = target_path -> Some (op, rhs_exp, true)
              | _ -> None)
          (* Check for simple arithmetic: A + C, A - C, C + A *)
          | Il.BinE (`AddOp, typ, e1, e2) ->
              (* A + C < B  =>  A < B - C *)
              let e1_sym = expand_vars sym_env e1 in
              let e2_sym = expand_vars sym_env e2 in
              let note = lhs_exp.note in
              (* Use LHS note for types *)
              let mk_sub l r =
                { it = Il.BinE (`SubOp, typ, l, r); at = no_region; note }
              in

              if List.mem target_path (extract_paths_from_exp sym_env e1) then
                Some (op, mk_sub rhs_exp e2_sym, false)
              else if List.mem target_path (extract_paths_from_exp sym_env e2)
              then Some (op, mk_sub rhs_exp e1_sym, false)
              else None
          | Il.BinE (`SubOp, typ, e1, e2) ->
              let e1_sym = expand_vars sym_env e1 in
              let e2_sym = expand_vars sym_env e2 in
              let note = lhs_exp.note in
              let mk_add l r =
                { it = Il.BinE (`AddOp, typ, l, r); at = no_region; note }
              in
              let mk_sub l r =
                { it = Il.BinE (`SubOp, typ, l, r); at = no_region; note }
              in

              if List.mem target_path (extract_paths_from_exp sym_env e1) then
                (* A - C < B  =>  A < B + C *)
                Some (op, mk_add rhs_exp e2_sym, false)
              else if List.mem target_path (extract_paths_from_exp sym_env e2)
              then
                (* C - A < B  =>  -A < B - C  =>  A > C - B *)
                Some (invert_cmp_op op, mk_sub e1_sym rhs_exp, false)
              else None
          | _ -> None))
  | false, true -> (
      (* Target is on RHS: LHS < B → B > LHS *)
      match resolve_to_field_path sym_env rhs_exp with
      | Some p when p = target_path -> Some (invert_cmp_op op, lhs_exp, false)
      | _ -> (
          match rhs_exp.it with
          | Il.LenE inner -> (
              match resolve_to_field_path sym_env inner with
              | Some p when p = target_path ->
                  Some (invert_cmp_op op, lhs_exp, true)
              | _ -> None)
          | _ -> None))
  | _ -> None (* Target in both sides or neither *)

let extract_symbolic_mutations (sym_env : sym_env) (exp : Il.exp) :
    sym_mutation list =
  match exp.it with
  | Il.CmpE (op, _, lhs_exp, rhs_exp) ->
      let lhs_sym = expand_vars sym_env lhs_exp in
      let rhs_sym = expand_vars sym_env rhs_exp in
      let cmp_op = op in

      (* Extract all paths from both sides *)
      let lhs_paths = extract_paths_from_exp sym_env lhs_sym in
      let rhs_paths = extract_paths_from_exp sym_env rhs_sym in
      let all_paths = lhs_paths @ rhs_paths in

      (* Try to evaluate LHS and RHS to get values for Unknown fallback *)
      let lhs_hint =
        match try Some (!State.current_eval lhs_sym) with _ -> None with
        | Some v -> ValueHint v
        | None -> TypeHint lhs_sym.note
      in
      let rhs_hint =
        match try Some (!State.current_eval rhs_sym) with _ -> None with
        | Some v -> ValueHint v
        | None -> TypeHint rhs_sym.note
      in

      (* For each path, try to rearrange and evaluate *)
      List.filter_map
        (fun path ->
          match algebraic_rearrange lhs_sym rhs_sym cmp_op path sym_env with
          | Some (isolated_op, isolated_rhs, is_len) -> (
              (* Try to evaluate using interpreter hook *)
              let eval_res =
                try Some (!State.current_eval isolated_rhs) with _ -> None
              in

              match eval_res with
              | Some value ->
                  let suggestion =
                    if is_len then ToLength (isolated_op, value)
                    else ToConst (isolated_op, value)
                  in
                  Some { target_path = Some path; suggestion }
              | None ->
                  (* Can't evaluate isolated RHS - use LHS or RHS hint for Unknown *)
                  let fallback_hint =
                    if List.mem path lhs_paths then rhs_hint else lhs_hint
                  in
                  Some
                    {
                      target_path = Some path;
                      suggestion = Unknown fallback_hint;
                    })
          | None ->
              (* Can't rearrange - use LHS or RHS hint for Unknown *)
              let fallback_hint =
                if List.mem path lhs_paths then rhs_hint else lhs_hint
              in
              Some
                { target_path = Some path; suggestion = Unknown fallback_hint })
        all_paths
  | Il.CallE (_func_id, _, args) ->
      (* Verification functions: extract TOP-LEVEL path only for each arg *)
      (* We don't want intermediate paths like state.VALIDATORS when the arg is state.VALIDATORS[i].PUBKEY *)
      let arg_mutations =
        List.filter_map
          (fun arg ->
            match arg.it with
            | Il.ExpA e -> (
                let expanded = expand_vars sym_env e in
                (* Only try to resolve as a single path - don't recurse into subexpressions *)
                let path_opt = resolve_to_field_path sym_env expanded in
                (* Try to get value hint *)
                let hint =
                  match
                    try Some (!State.current_eval expanded) with _ -> None
                  with
                  | Some v -> ValueHint v
                  | None -> TypeHint expanded.note
                in
                (* Only include if we have a path *)
                match path_opt with
                | Some path ->
                    Some { target_path = Some path; suggestion = Unknown hint }
                | None -> None)
            | Il.DefA _ -> None)
          args
      in
      arg_mutations
  | Il.MatchE (exp_match, pat) -> (
      match pat with
      | Il.ListP `Nil ->
          (* matches [] => len == 0
             After negation: len != 0
             But we can't mutate empty list to non-empty without schema, so skip *)
          []
      | Il.ListP `Cons ->
          (* matches _::_ => len > 0 *)
          let paths =
            extract_paths_from_exp sym_env (expand_vars sym_env exp_match)
          in
          List.map
            (fun path ->
              {
                target_path = Some path;
                suggestion =
                  ToLength
                    ( `GtOp,
                      Il.Value.Make.num Il.Typ.nat (`Nat (Bigint.of_int 0)) );
              })
            paths
      | _ -> [])
  | Il.UnE (`NotOp, _, e) ->
      (* Boolean negation: ~exp => exp = false *)
      let paths = extract_paths_from_exp sym_env (expand_vars sym_env e) in
      List.map
        (fun path ->
          {
            target_path = Some path;
            suggestion = ToConst (`EqOp, Il.Value.bool false);
          })
        paths
  | _ ->
      (* Boolean field or other: implicit check for true *)
      let paths = extract_paths_from_exp sym_env (expand_vars sym_env exp) in
      List.map
        (fun path ->
          {
            target_path = Some path;
            suggestion = ToConst (`EqOp, Il.Value.bool true);
          })
        paths

(* Initialize the lookup_sym_ref to point to State.lookup_sym *)
let () = lookup_sym_ref := State.lookup_sym

(* Helper: Bind relation inputs based on call-site expressions and fallback heuristics *)
let bind_relation_inputs (rel_id : string) (values : Il.Value.t list) : unit =
  match Hashtbl.find_opt State.relation_inputs rel_id with
  | None -> ()
  | Some input_names ->
      (* Peek at call args (don't pop yet - we'll pop in on_prem_exit for outputs) *)
      (* Use UNEXPANDED arguments to avoid potential expansion loops *)
      let call_inputs =
        match State.peek_call_args () with
        | Some (_, inputs, _outputs) -> inputs
        | None -> []
      in

      (* Bind each input variable *)
      List.iteri
        (fun i name ->
          if i < List.length values then
            let value = List.nth values i in
            let expr =
              if i < List.length call_inputs then
                (* Use actual call-site expression UNEXPANDED - will be expanded later when needed *)
                List.nth call_inputs i
              else
                (* Top-level relation call (no call_inputs): bind inputs directly to themselves
                   so they resolve to the input source (STATE/BLOCK) via type-based fallback *)
                (* For top-level inputs, bind to the input variable name itself.
                   When resolving, if not found in sym_env, the type-based fallback in
                   resolve_to_field_path_with_visited will correctly return State/Block source. *)
                {
                  it = Il.VarE (name $ no_region);
                  at = no_region;
                  note = value.note.Il.typ;
                }
            in
            State.bind_sym name expr)
        input_names

(* Pre-compute per-function interior IfPr premises for static inlining.
   Returns: fname -> (param_names, [(uid, if_prem)] list across all clauses).
   Called once at init; UIDs are assigned stably from source location. *)
let extract_func_interiors (il_spec : Il.spec) :
    (string, string list * (int * Il.prem) list) Hashtbl.t =
  let tbl = Hashtbl.create 100 in
  List.iter
    (fun def ->
      match def.it with
      | Il.DecD (id, _tparams, _params, _return_typ, clauses) ->
          let param_names =
            match clauses with
            | [] -> []
            | first_clause :: _ ->
                let args, _body, _prems = first_clause.it in
                List.filter_map
                  (fun arg ->
                    match arg.it with
                    | Il.ExpA { it = Il.VarE id; _ } -> Some id.it
                    | _ -> None)
                  args
          in
          let interior_prems =
            List.concat_map
              (fun clause ->
                let _args, _body, prems = clause.it in
                List.filter_map
                  (fun prem ->
                    match prem.it with
                    | Il.IfPr _ | Il.IterPr ({ it = Il.IfPr _; _ }, _) ->
                        let key = Premise_uid.prem_key prem in
                        let uid = Premise_uid.assign_uid key in
                        Some (uid, prem)
                    | _ -> None)
                  prems)
              clauses
          in
          if interior_prems <> [] then
            Hashtbl.replace tbl id.it (param_names, interior_prems)
      | _ -> ())
    il_spec;
  tbl

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
    | Instrumentation_core.Handler.IlSpec il_spec ->
        let inputs = extract_relation_inputs il_spec in
        let outputs = extract_relation_outputs il_spec in
        let io_indices = extract_relation_io_indices il_spec in
        let func_params = extract_function_params il_spec in
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.relation_inputs k v)
          inputs;
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.relation_outputs k v)
          outputs;
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.relation_io_indices k v)
          io_indices;
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.function_params k v)
          func_params;
        let func_interiors_data = extract_func_interiors il_spec in
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.func_interiors k v)
          func_interiors_data
    | Instrumentation_core.Handler.SlSpec _ -> ()

  let on_test_start ~test_case_id = State.current_test_id := test_case_id

  let on_test_end ~test_case_id:_ =
    (* Clear per-test state to prevent corruption across different inputs *)
    State.current_test_id := "";
    Hashtbl.clear State.sym_env;
    Hashtbl.clear State.seen_prems;
    State.frames := []
  (* Note: per_test_sym_mutations is preserved - it accumulates across tests *)

  let on_rel_enter ~id ~at:_ ~values =
    State.current_relation := id;
    State.push_call_frame ();
    (* Bind inputs using types and relation input names *)
    bind_relation_inputs id values

  let on_rel_exit ~id:_ ~at:_ ~success =
    if success then State.pop_sym_frame_success ()
    else State.pop_sym_frame_failure ();
    State.current_relation := "";
    State.current_rule := ""

  let on_rule_enter ~id:_ ~rule_id ~at:_ =
    State.current_rule := rule_id;
    State.push_sym_frame ()

  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success =
    if success then State.pop_sym_frame_success ()
    else State.pop_sym_frame_failure ();
    State.current_rule := ""

  let on_func_enter ~id:_ ~at:_ ~values:_ = ()
  let on_func_exit ~id:_ ~at:_ = ()
  let on_clause_enter ~id:_ ~clause_idx:_ ~at:_ = State.push_sym_frame ()

  let on_clause_exit ~id:_ ~clause_idx:_ ~at:_ ~success =
    if success then State.pop_sym_frame_success ()
    else State.pop_sym_frame_failure ()

  let on_iter_prem_enter ~prem ~at:_ =
    (* Bind iteration variables to symbolic environment *)
    match prem.it with
    | Il.IterPr (_, (_iter, vars)) ->
        List.iter
          (fun (id, typ, _) ->
            State.bind_sym id.it
              { it = Il.VarE id; at = no_region; note = typ.it })
          vars
    | _ -> ()

  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit
  let on_instr = Instrumentation_core.Noop.on_instr

  (* Collect (fname, arg_exps) for every CallE node in the expression tree. *)
  let rec collect_call_exps (exp : Il.exp) : (string * Il.exp list) list =
    match exp.it with
    | Il.CallE (fname, _, args) ->
        let arg_exps =
          List.filter_map
            (fun arg -> match arg.it with Il.ExpA e -> Some e | _ -> None)
            args
        in
        [ (fname.it, arg_exps) ]
        (* stop here — don't recurse into call args *)
    | _ -> Il.Traverse.fold_children_exp ( @ ) [] collect_call_exps exp

  (* Concretize index variables in an expression by evaluating them to NumE literals.
     This avoids the sym_env expansion that would turn 'vid' into 'vid_h' (from outer-scope
     relation bindings), which then can't be resolved in the current interpreter context. *)
  let rec materialize_arg (exp : Il.exp) : Il.exp =
    match exp.it with
    | Il.IdxE (base, idx) ->
        let base' = materialize_arg base in
        let idx' =
          match idx.it with
          | Il.VarE _ | Il.CallE _ -> (
              match try Some (!State.current_eval idx) with _ -> None with
              | Some { it = Il.NumV (`Nat bi); _ } -> (
                  try
                    {
                      idx with
                      it = Il.NumE (`Nat (Bigint.of_int (Bigint.to_int_exn bi)));
                    }
                  with _ -> idx)
              | _ -> idx)
          | _ -> idx
        in
        if base' == base && idx' == idx then exp
        else { exp with it = Il.IdxE (base', idx') }
    | _ -> Il.Traverse.map_children_exp materialize_arg exp

  (** Strip negation wrappers, extract symbolic mutations, adjust booleans if
      negated, and record in State. Called once per (uid, if-expression) pair.
  *)
  let extract_and_record_if_mutations (uid : int) (exp : Il.exp) : unit =
    let exp1, was_negated = strip_negation exp in
    let exp2, was_bool_eq_negated = strip_bool_eq exp1 in
    let total_negated = was_negated <> was_bool_eq_negated in
    let mutations = extract_symbolic_mutations State.sym_env exp2 in
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

  (** Track call-site args for a RulePr premise (pushed before relation enters,
      popped in on_prem_exit after relation exits). *)
  let track_relation_call_args (id : string) (args : Il.exp list) : unit =
    let input_indices =
      Option.value (Hashtbl.find_opt State.relation_io_indices id) ~default:[]
    in
    let num_args = List.length args in
    let indexed_exps = List.mapi (fun i exp -> (i, exp)) args in
    let input_exps =
      indexed_exps
      |> List.filter (fun (i, _) -> List.mem i input_indices)
      |> List.map snd
    in
    let output_exps =
      indexed_exps
      |> List.filter (fun (i, _) ->
             (not (List.mem i input_indices)) && i < num_args)
      |> List.map snd
    in
    State.push_call_args id input_exps output_exps

  let generate_interior_mutations (func_id : string) (call_args : Il.exp list) =
    match Hashtbl.find_opt State.func_interiors func_id with
    | None -> ()
    | Some (param_names, interior_prems) ->
        (* Push a frame so param bindings are visible through State.lookup_sym.
           We use materialize_arg instead of expand_vars to avoid sym_env expansion of
           index variables (e.g. 'vid' mapped to 'vid_h' by bind_relation_inputs for the
           outer SlashIfEligible call) — materialize_arg evaluates indices directly via
           !State.current_eval, producing NumE literals that resolve correctly. *)
        State.push_sym_frame ();
        List.iteri
          (fun i param_name ->
            if i < List.length call_args then
              let materialized = materialize_arg (List.nth call_args i) in
              State.bind_sym param_name materialized)
          param_names;
        List.iter
          (fun (uid, prem) ->
            Hashtbl.replace State.seen_uids uid ();
            let should_process =
              if Hashtbl.length State.target_uids = 0 then
                is_whitelisted !State.current_relation
              else State.is_target_uid uid
            in
            if should_process then
              match prem.it with
              | Il.IfPr exp -> extract_and_record_if_mutations uid exp
              | Il.IterPr ({ it = Il.IfPr exp; _ }, _) ->
                  extract_and_record_if_mutations uid exp
              | _ -> ())
          interior_prems;
        (* Pop without merging — param bindings must not escape to parent scope *)
        State.pop_sym_frame_failure ()

  (** For any IfPr containing a CallE, check if we have function-interior
      premises and generate mutations for them under the current call args as
      param bindings. *)
  let trigger_function_inlining (exp : Il.exp) : unit =
    let exp1, _ = strip_negation exp in
    let exp2, _ = strip_bool_eq exp1 in
    List.iter
      (fun (fname, arg_exps) -> generate_interior_mutations fname arg_exps)
      (collect_call_exps exp2)

  let on_prem_enter ~eval ~prem ~at =
    (match eval with Some f -> State.current_eval := f | None -> ());
    State.premise_count := !State.premise_count + 1;
    if !State.premise_count mod 500 = 0 then
      Format.eprintf "\r[Positive] %d premises, %d if-prems, %d skipped...%!"
        !State.premise_count !State.if_prem_count !State.skipped_count;

    if not (is_if_prem prem) then
      match prem.it with
      | Il.RulePr (id, (_, args)) -> track_relation_call_args id.it args
      | _ -> ()
    else
      let prem_key = Premise_uid.prem_key prem in
      let uid = Premise_uid.assign_uid prem_key in
      Hashtbl.replace State.seen_uids uid ();

      (* Always inline function interiors — target UIDs are inside functions, not the outer IfPr.
         Must be outside already_seen so it fires on every loop iteration. *)
      (match prem.it with
      | Il.IfPr exp | Il.IterPr ({ it = Il.IfPr exp; _ }, _) ->
          trigger_function_inlining exp
      | _ -> ());

      let should_extract =
        if Hashtbl.length State.target_uids = 0 then
          is_whitelisted !State.current_relation
        else State.is_target_uid uid
      in
      if should_extract then
        let loc = string_of_region at in
        if State.already_seen loc then
          State.skipped_count := !State.skipped_count + 1
        else (
          State.mark_seen loc;
          State.if_prem_count := !State.if_prem_count + 1;
          match prem.it with
          | Il.IfPr exp -> extract_and_record_if_mutations uid exp
          | Il.IterPr ({ it = Il.IfPr exp; _ }, _) ->
              extract_and_record_if_mutations uid exp
          | _ -> ())

  let on_prem_exit ~prem ~at:_ ~success =
    if success then
      (* Mutation extraction happens in on_prem_enter. Here we handle variable bindings. *)
      match prem.it with
      (* Bind symbolic expression for let premises *)
      | Il.LetPr ({ it = Il.VarE id; _ }, rhs) ->
          let sym = expand_vars State.sym_env rhs in
          State.bind_sym id.it sym
      (* Handle IterPr(LetPr) - nested let bindings in iterations *)
      | Il.IterPr ({ it = Il.LetPr ({ it = Il.VarE id; _ }, rhs); _ }, _) ->
          let sym = expand_vars State.sym_env rhs in
          State.bind_sym id.it sym
      | Il.RulePr (id, _) -> (
          (* Relation call succeeded - pop the call args stack to keep it balanced *)
          match State.pop_call_args () with
          | Some (rel_id, inputs, output_exprs) when rel_id = id.it ->
              (* Simple binding: for state-typed outputs, bind to first input (usually state) *)
              let first_input =
                if List.length inputs > 0 then Some (List.hd inputs) else None
              in
              (* Bind each output pattern *)
              List.iter
                (fun output_expr ->
                  match output_expr.it with
                  | Il.VarE var_id -> (
                      if
                        (* For state-typed outputs, bind to the first input *)
                        is_state_type output_expr.note
                      then
                        match first_input with
                        | Some input_expr -> State.bind_sym var_id.it input_expr
                        | None ->
                            (* No input found, bind to generic "state" *)
                            State.bind_sym var_id.it
                              {
                                it = Il.VarE ("state" $ no_region);
                                at = no_region;
                                note = output_expr.note;
                              }
                        (* Non-state outputs: don't bind, will resolve as Unknown/Local *)
                      )
                  | _ -> ())
                output_exprs
          | _ -> ())
      | _ -> ()
    else
      (* On failure, pop any pending call args to keep stack balanced *)
      match prem.it with
      | Il.RulePr (id, _) -> (
          match State.peek_call_args () with
          | Some (rel_id, _, _) when rel_id = id.it ->
              ignore (State.pop_call_args ())
          | _ -> ())
      | _ -> ()

  (* Noop - logic moved to on_prem_enter *)
  let on_prem_fields = Instrumentation_core.Noop.on_prem_fields

  let on_rule_output ~id:_ ~rule_id:_ ~at:_ ~output_exps =
    (* Extract paths from each output expression *)
    List.iter
      (fun output_exp ->
        let expanded = expand_vars State.sym_env output_exp in
        let _paths = extract_paths_from_exp State.sym_env expanded in
        (* For now, just track that these paths are outputs *)
        (* TODO: Store in a mapping for later use when the relation is called *)
        match resolve_to_field_path State.sym_env expanded with
        | Some _field_path ->
            (* Successfully resolved to a field path *)
            (* Future: store this for propagation to call sites *)
            ()
        | None -> ())
      output_exps

  let on_clause_return ~id:_ ~clause_idx:_ ~at:_ ~return_exp =
    (* Extract paths from the return expression *)
    let expanded = expand_vars State.sym_env return_exp in
    let _paths = extract_paths_from_exp State.sym_env expanded in
    (* For now, just track that we saw this return expression *)
    (* TODO: Store in a mapping for later use when the function is called *)
    match resolve_to_field_path State.sym_env expanded with
    | Some _field_path ->
        (* Successfully resolved to a field path *)
        (* Future: store this for propagation to call sites *)
        ()
    | None -> ()

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
              Format.fprintf !fmt "  (analyzed but no mutations found)\n"
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
    Format.pp_print_flush !fmt ()
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
let clear_memory () = State.clear_large_state ()
