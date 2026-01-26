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

(* Mutation suggestion types *)
type mutation_kind =
  | ToConst of Il.cmpop * Il.Value.t (* path <op> value *)
  | ToLength of Il.cmpop * Il.Value.t (* collection length constraint *)
  | Unknown of Il.typ option (* over-approximation *)

type sym_mutation = {
  target_path : field_path option;
  suggestion : mutation_kind;
}

(* Frame for tracking sym_env bindings in scope *)
type pos_frame = {
  local_env : sym_env;
  is_barrier : bool;
  relation_id : string option;
      (* Track which relation this frame belongs to, if any *)
}

(* === Handler State === *)
module State = struct
  let output_file : string option ref = ref None

  (* Symbolic expression environment - maps variable names to symbolic expressions *)
  let sym_env : sym_env = Hashtbl.create 100

  (* Relation input variable names from spec *)
  let relation_inputs : (string, string list) Hashtbl.t = Hashtbl.create 50

  (* Already-analyzed premises (by location string) *)
  let seen_prems : (string, unit) Hashtbl.t = Hashtbl.create 1000

  (* Track visited UIDs to distinguish "not covered" from "no mutations" *)
  let seen_uids : (int, unit) Hashtbl.t = Hashtbl.create 1000

  (* Current context *)
  let current_relation : string ref = ref ""
  let current_rule : string ref = ref ""
  let current_test_id : string ref = ref ""

  (* Frame stack for sym_env backtracking *)
  let frames : pos_frame list ref = ref []

  (* Pending symbolic arguments for the next relation entry (Call Graph) *)
  let pending_call_args : Il.exp list option ref = ref None

  (* Track relation outputs: relation_id -> variable_name -> expression *)
  (* This captures variables bound within a relation that should be propagated to callers *)
  let relation_outputs : (string, (string, Il.exp) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 50

  (* Per-test symbolic mutations: premise_uid -> test_id -> sym_mutation list *)
  let per_test_sym_mutations :
      (int, (string, sym_mutation list) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 1000

  (* Map from field_path to original expression for PathRef evaluation *)
  (* This allows us to evaluate PathRef indices later when we have more context *)
  let path_to_expr : (field_path, Il.exp) Hashtbl.t = Hashtbl.create 1000

  (* Progress tracking *)
  let premise_count = ref 0
  let if_prem_count = ref 0
  let skipped_count = ref 0
  let func_depth = ref 0

  (* Target UIDs for filtering - empty means no filtering (use whitelist) *)
  let target_uids : (int, unit) Hashtbl.t = Hashtbl.create 16

  (* Current evaluation function from interpreter *)
  let current_eval : (Il.exp -> Il.Value.t) ref =
    ref (fun _ -> Il.Value.text "init")

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
    Hashtbl.clear seen_prems;
    Hashtbl.clear seen_uids;
    current_relation := "";
    current_rule := "";
    current_test_id := "";
    current_test_id := "";
    frames := [];
    pending_call_args := None;
    Hashtbl.clear relation_outputs;
    Hashtbl.clear per_test_sym_mutations;
    Hashtbl.clear path_to_expr;
    premise_count := 0;
    if_prem_count := 0;
    skipped_count := 0

  let already_seen loc = Hashtbl.mem seen_prems loc
  let mark_seen loc = Hashtbl.replace seen_prems loc ()

  (* Frame management for sym_env backtracking *)
  let push_sym_frame () =
    let relation_id =
      match !frames with
      | frame :: _ when frame.is_barrier -> frame.relation_id
      | _ -> None
    in
    let new_frame =
      { local_env = Hashtbl.create 20; is_barrier = false; relation_id }
    in
    frames := new_frame :: !frames

  let push_call_frame () =
    let new_frame =
      {
        local_env = Hashtbl.create 20;
        is_barrier = true;
        relation_id = Some !current_relation;
      }
    in
    frames := new_frame :: !frames

  let pop_sym_frame_success () =
    match !frames with
    | frame :: rest -> (
        frames := rest;
        (* Only merge into immediate parent frame or global sym_env *)
        (* This prevents bindings from leaking across unrelated scopes *)
        match rest with
        | parent :: _ ->
            (* Merge into immediate parent only *)
            Hashtbl.iter
              (fun k v -> Hashtbl.replace parent.local_env k v)
              frame.local_env
        | [] ->
            (* No parent - merge into global sym_env *)
            Hashtbl.iter
              (fun k v -> Hashtbl.replace sym_env k v)
              frame.local_env)
    | [] -> ()

  let pop_sym_frame_failure () =
    match !frames with _ :: rest -> frames := rest | [] -> ()

  (* Lookup in sym_env: check frames from top to bottom, then global *)
  (* Barriers prevent lookups from outside the relation, but allow lookups
     within nested scopes of the same relation *)
  let lookup_sym (id : string) : Il.exp option =
    let rec check_frames fs current_relation_id =
      match fs with
      | [] -> Hashtbl.find_opt sym_env id
      | frame :: rest -> (
          match Hashtbl.find_opt frame.local_env id with
          | Some v -> Some v
          | None ->
              if
                (* If this is a barrier frame, check if we're within the same relation *)
                frame.is_barrier
              then
                match (frame.relation_id, current_relation_id) with
                | Some rel_id, Some current_id when rel_id = current_id ->
                    (* Same relation - continue searching *)
                    check_frames rest current_relation_id
                | _ ->
                    None (* Different relation or no current relation - stop *)
              else
                (* Not a barrier - continue searching *)
                check_frames rest current_relation_id)
    in
    let current_rel_id =
      match !frames with
      | frame :: _ when frame.is_barrier -> frame.relation_id
      | _ -> None
    in
    check_frames !frames current_rel_id

  (* Bind in current frame's local_env (or global if no frame) *)
  let bind_sym (id : string) (expr : Il.exp) : unit =
    match !frames with
    | frame :: _ -> Hashtbl.replace frame.local_env id expr
    | [] -> Hashtbl.replace sym_env id expr

  (* Add per-test symbolic mutation result *)
  let add_per_test_sym_mutation (premise_uid : int)
      (mutations : sym_mutation list) =
    if mutations <> [] then
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
      Hashtbl.replace test_table test_id (existing @ mutations)

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

(* === Expression Resolution (Positive-specific: detailed symbolic tracking) === *)

(* Helper: Deduplicate repeated fields like MESSAGE.MESSAGE *)
let rec deduplicate_path (path : field_path) : field_path =
  let rec dedup_steps steps =
    match steps with
    | FieldAccess s1
      :: FieldAccess s2
      :: FieldAccess s3
      :: FieldAccess s4
      :: rest
      when s1 = s2 && s2 = s3 && s3 = s4 ->
        dedup_steps (FieldAccess s1 :: rest)
    | FieldAccess s1 :: FieldAccess s2 :: FieldAccess s3 :: rest
      when s1 = s2 && s2 = s3 ->
        dedup_steps (FieldAccess s1 :: rest)
    | FieldAccess s1 :: FieldAccess s2 :: rest when s1 = s2 ->
        dedup_steps (FieldAccess s1 :: rest)
    | IndexAccess (PathRef nested_path) :: rest ->
        (* Recursively deduplicate nested paths in index expressions *)
        let deduped_nested = deduplicate_path nested_path in
        IndexAccess (PathRef deduped_nested) :: dedup_steps rest
    | step :: rest -> step :: dedup_steps rest
    | [] -> []
  in
  { path with steps = dedup_steps path.steps }

(* Concretize paths by evaluating PathRef indices to ConstInt when possible.
   This function tries to evaluate index paths to get concrete integer values.
   It uses the stored original expressions from State.path_to_expr.
*)
(* Concretize paths by evaluating PathRef indices to ConstInt when possible.
   This function tries to evaluate index paths to get concrete integer values.
   It uses the stored original expressions from State.path_to_expr.
   If evaluation fails, we eliminate the PathRef and return None for the path
   (which will cause it to be filtered out).
*)
(* Concretize paths by evaluating PathRef indices to ConstInt when possible.
   This function tries to evaluate index paths to get concrete integer values.
   It uses the stored original expressions from State.path_to_expr.
   If evaluation fails, we keep the PathRef (don't filter out the path).
   The path will be handled by the mutator which can work with PathRef in some cases.
*)
let rec concretize_path_indices (path : field_path) : field_path =
  let rec concretize_steps steps =
    match steps with
    | IndexAccess (PathRef idx_path) :: rest -> (
        (* Try to get the original expression for this path *)
        match Hashtbl.find_opt State.path_to_expr idx_path with
        | Some orig_expr -> (
            (* Try to evaluate the stored expression directly *)
            let v_opt =
              try Some (!State.current_eval orig_expr) with _ -> None
            in
            match v_opt with
            | Some v -> (
                match v.it with
                | Il.NumV (`Nat bi) ->
                    let i = Bigint.to_int_exn bi in
                    IndexAccess (ConstInt i) :: concretize_steps rest
                | Il.NumV (`Int bi) -> (
                    try
                      let i = Bigint.to_int_exn bi in
                      if i >= 0 then
                        IndexAccess (ConstInt i) :: concretize_steps rest
                      else
                        (* Negative index - keep PathRef *)
                        IndexAccess (PathRef (concretize_path_indices idx_path))
                        :: concretize_steps rest
                    with _ ->
                      (* Can't convert - keep PathRef *)
                      IndexAccess (PathRef (concretize_path_indices idx_path))
                      :: concretize_steps rest)
                | _ ->
                    (* Not a number - keep PathRef *)
                    IndexAccess (PathRef (concretize_path_indices idx_path))
                    :: concretize_steps rest)
            | None ->
                (* Evaluation failed - keep PathRef and continue *)
                IndexAccess (PathRef (concretize_path_indices idx_path))
                :: concretize_steps rest)
        | None ->
            (* No stored expression - keep PathRef and continue *)
            IndexAccess (PathRef (concretize_path_indices idx_path))
            :: concretize_steps rest)
    | IndexAccess (ConstInt i) :: rest ->
        IndexAccess (ConstInt i) :: concretize_steps rest
    | step :: rest -> step :: concretize_steps rest
    | [] -> []
  in
  { path with steps = concretize_steps path.steps }

(* Resolve expression to structured field_path.
   More restrictive than resolve_to_path - only returns paths that can be mutated.
   Complex expressions (BinE, UnE, LenE, etc.) return None.
   Uses sym_env for variable lookups.
   
   Domain knowledge: State variables always refer to the same state object,
   so we can infer State source for common state variable names.
*)
let rec resolve_to_field_path (sym_env : sym_env) (exp : Il.exp) :
    field_path option =
  match resolve_to_field_path_with_visited sym_env exp [] with
  | Some path -> Some (deduplicate_path path)
  | None -> None

and resolve_to_field_path_with_visited (sym_env : sym_env) (exp : Il.exp)
    (visited : string list) : field_path option =
  (* Use frame-aware lookup instead of direct hashtable access *)
  match exp.it with
  (* Variables: look up and recurse *)
  | Il.VarE id -> (
      let fallback_path ~use_local =
        (* Try to infer source from type information first *)
        if is_state_type exp.note then Some { source = State; steps = [] }
        else if is_block_type exp.note then Some { source = Block; steps = [] }
        else if use_local then Some { source = Local id.it; steps = [] }
        else
          (* Last resort: check if variable name suggests a source *)
          let var_lower = String.lowercase_ascii id.it in
          if var_lower = "state" || String.starts_with ~prefix:"state" var_lower
          then Some { source = State; steps = [] }
          else if
            var_lower = "block" || String.starts_with ~prefix:"block" var_lower
          then Some { source = Block; steps = [] }
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
          (* Deduplicate the base path before appending the field *)
          let deduped_base = deduplicate_path base_path in
          Some
            (append_step deduped_base
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
              (* Try to evaluate the index expression first to get a concrete value *)
              (* Expand variables first to help the evaluator *)
              let idx_expanded = !expand_vars_ref sym_env idx in
              let v_opt =
                try Some (!State.current_eval idx_expanded) with _ -> None
              in
              match v_opt with
              | Some v -> (
                  (* Successfully evaluated - use concrete index *)
                  match v.it with
                  | Il.NumV (`Nat bi) ->
                      let i = Bigint.to_int_exn bi in
                      Some (append_step base_path (IndexAccess (ConstInt i)))
                  | Il.NumV (`Int bi) -> (
                      (* Try to convert signed int to unsigned if non-negative *)
                      try
                        let i = Bigint.to_int_exn bi in
                        if i >= 0 then
                          Some
                            (append_step base_path (IndexAccess (ConstInt i)))
                        else None
                      with _ -> None)
                  | _ -> None)
              | None -> (
                  (* Evaluation failed - try to resolve as path *)
                  match
                    resolve_to_field_path_with_visited sym_env idx visited
                  with
                  | Some idx_path -> (
                      (* Deduplicate the nested path before using it *)
                      let deduped_idx_path = deduplicate_path idx_path in
                      (* Store the expanded expression for later evaluation during concretization *)
                      Hashtbl.replace State.path_to_expr deduped_idx_path
                        idx_expanded;
                      (* Try evaluating the expanded expression again with more context *)
                      (* Also try evaluating the original expression in case expansion broke something *)
                      let v_opt2 =
                        try Some (!State.current_eval idx_expanded)
                        with _ -> None
                      in
                      let v_opt3 =
                        match v_opt2 with
                        | Some _ -> v_opt2
                        | None -> (
                            try Some (!State.current_eval idx) with _ -> None)
                      in
                      match v_opt3 with
                      | Some v -> (
                          match v.it with
                          | Il.NumV (`Nat bi) ->
                              let i = Bigint.to_int_exn bi in
                              Some
                                (append_step base_path
                                   (IndexAccess (ConstInt i)))
                          | Il.NumV (`Int bi) -> (
                              try
                                let i = Bigint.to_int_exn bi in
                                if i >= 0 then
                                  Some
                                    (append_step base_path
                                       (IndexAccess (ConstInt i)))
                                else None
                              with _ -> None)
                          | _ ->
                              (* Not a number - create PathRef for later concretization *)
                              Some
                                (append_step base_path
                                   (IndexAccess (PathRef deduped_idx_path))))
                      | None ->
                          (* Can't evaluate now - create PathRef for later concretization *)
                          (* We'll try to evaluate it during concretization when we have more context *)
                          Some
                            (append_step base_path
                               (IndexAccess (PathRef deduped_idx_path))))
                  | None ->
                      (* Can't resolve as path either - return None (drop the path) *)
                      None))))
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
  expand_vars_with_visited sym_env exp []

and expand_vars_with_visited (sym_env : sym_env) (exp : Il.exp)
    (visited : string list) : Il.exp =
  (* Use frame-aware lookup *)
  let lookup id = !lookup_sym_ref id in
  match exp.it with
  | Il.VarE id -> (
      if List.mem id.it visited then exp
      else
        match lookup id.it with
        | Some e -> (
            match e.it with
            | Il.VarE id' when id'.it = id.it -> exp
            | _ -> expand_vars_with_visited sym_env e (id.it :: visited))
        | None -> exp)
  | Il.DotE (base, atom) ->
      let base' = expand_vars_with_visited sym_env base visited in
      if base' == base then exp else { exp with it = Il.DotE (base', atom) }
  | Il.IdxE (base, idx) ->
      let base' = expand_vars_with_visited sym_env base visited in
      let idx' = expand_vars_with_visited sym_env idx visited in
      if base' == base && idx' == idx then exp
      else { exp with it = Il.IdxE (base', idx') }
  | Il.BinE (op, typ, e1, e2) ->
      let e1' = expand_vars_with_visited sym_env e1 visited in
      let e2' = expand_vars_with_visited sym_env e2 visited in
      { exp with it = Il.BinE (op, typ, e1', e2') }
  | Il.CmpE (op, typ, e1, e2) ->
      let e1' = expand_vars_with_visited sym_env e1 visited in
      let e2' = expand_vars_with_visited sym_env e2 visited in
      { exp with it = Il.CmpE (op, typ, e1', e2') }
  | Il.UnE (op, typ, e) ->
      let e' = expand_vars_with_visited sym_env e visited in
      { exp with it = Il.UnE (op, typ, e') }
  (* Special handling for len *)
  | Il.LenE inner ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      { exp with it = Il.LenE inner' }
  (* Handle calls? Arguments might need expansion *)
  | Il.CallE (id, targs, args) ->
      (* Special handling for filter_list_: approximate to first argument *)
      if
        String.starts_with ~prefix:"filter_list_" id.it
        || String.starts_with ~prefix:"filter_list_2" id.it
      then
        match args with
        | { it = Il.ExpA e; _ } :: _ ->
            expand_vars_with_visited sym_env e visited
        | _ -> { exp with it = Il.CallE (id, targs, args) }
      else
        let args' =
          List.map
            (fun arg ->
              match arg.it with
              | Il.ExpA e ->
                  {
                    arg with
                    it = Il.ExpA (expand_vars_with_visited sym_env e visited);
                  }
              | _ -> arg)
            args
        in
        { exp with it = Il.CallE (id, targs, args') }
  | Il.UpdE (inner, path, value) ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      let value' = expand_vars_with_visited sym_env value visited in
      { exp with it = Il.UpdE (inner', path, value') }
  | Il.OptE (Some inner) ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      { exp with it = Il.OptE (Some inner') }
  | Il.IterE (inner, iter) ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      { exp with it = Il.IterE (inner', iter) }
  | Il.SubE (inner, typ) ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      { exp with it = Il.SubE (inner', typ) }
  | Il.UpCastE (typ, inner) ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      { exp with it = Il.UpCastE (typ, inner') }
  | Il.DownCastE (typ, inner) ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      { exp with it = Il.DownCastE (typ, inner') }
  | Il.OptE None -> exp
  | Il.ListE inners ->
      let inners' =
        List.map (fun e -> expand_vars_with_visited sym_env e visited) inners
      in
      { exp with it = Il.ListE inners' }
  | Il.SliceE (base, high, low) ->
      let base' = expand_vars_with_visited sym_env base visited in
      let high' = expand_vars_with_visited sym_env high visited in
      let low' = expand_vars_with_visited sym_env low visited in
      { exp with it = Il.SliceE (base', high', low') }
  | Il.MemE (base, member) ->
      let base' = expand_vars_with_visited sym_env base visited in
      let member' = expand_vars_with_visited sym_env member visited in
      { exp with it = Il.MemE (base', member') }
  | Il.CatE (head, tail) ->
      let head' = expand_vars_with_visited sym_env head visited in
      let tail' = expand_vars_with_visited sym_env tail visited in
      { exp with it = Il.CatE (head', tail') }
  | Il.ConsE (head, tail) ->
      let head' = expand_vars_with_visited sym_env head visited in
      let tail' = expand_vars_with_visited sym_env tail visited in
      { exp with it = Il.ConsE (head', tail') }
  | Il.TupleE inners ->
      let inners' =
        List.map (fun e -> expand_vars_with_visited sym_env e visited) inners
      in
      { exp with it = Il.TupleE inners' }
  | Il.MatchE (inner, pattern) ->
      let inner' = expand_vars_with_visited sym_env inner visited in
      { exp with it = Il.MatchE (inner', pattern) }
  | Il.StrE fields ->
      let fields' =
        List.map
          (fun (atom, e) ->
            let e' = expand_vars_with_visited sym_env e visited in
            (atom, e'))
          fields
      in
      { exp with it = Il.StrE fields' }
  | Il.CaseE _ | Il.HoldE _ | Il.BoolE _ | Il.NumE _ | Il.TextE _ -> exp

(* Initialize mutual recursion refs *)
let () = expand_vars_ref := expand_vars

(* Extract path from expression (wrapper around resolve_to_field_path) *)
let rec extract_paths_from_exp (sym_env : sym_env) (exp : Il.exp) :
    field_path list =
  (* Try to resolve top-level *)
  match resolve_to_field_path sym_env exp with
  | Some p -> [ p ]
  | None -> (
      (* If not a path, maybe it contains paths? e.g. A + B *)
      match exp.it with
      | Il.BinE (_, _, e1, e2)
      | Il.CmpE (_, _, e1, e2)
      | Il.IdxE (e1, e2)
      | Il.CatE (e1, e2)
      | Il.ConsE (e1, e2) ->
          extract_paths_from_exp sym_env e1 @ extract_paths_from_exp sym_env e2
      | Il.UnE (_, _, e) | Il.UpdE (e, _, _) -> extract_paths_from_exp sym_env e
      | Il.LenE e -> extract_paths_from_exp sym_env e
      | Il.CallE (_, _, args) ->
          List.concat_map
            (fun arg ->
              match arg.it with
              | Il.ExpA e -> extract_paths_from_exp sym_env e
              | _ -> [])
            args
      | Il.UpCastE (_, e)
      | Il.DownCastE (_, e)
      | Il.SubE (e, _)
      | Il.MatchE (e, _)
      | Il.MemE (e, _)
      | Il.OptE (Some e)
      | Il.IterE (e, _) ->
          extract_paths_from_exp sym_env e
      | Il.DotE (e, _) -> extract_paths_from_exp sym_env e
      | Il.VarE _ ->
          (* Should have been returned by resolve_to_field_path *)
          assert false
      | Il.TupleE es | Il.ListE es ->
          List.concat_map (extract_paths_from_exp sym_env) es
      | Il.StrE fields ->
          List.concat_map
            (fun (_, e) -> extract_paths_from_exp sym_env e)
            fields
      | Il.SliceE (e1, e2, e3) ->
          extract_paths_from_exp sym_env e1
          @ extract_paths_from_exp sym_env e2
          @ extract_paths_from_exp sym_env e3
      | Il.CaseE _ | Il.HoldE _
      | Il.OptE None
      | Il.BoolE _ | Il.NumE _ | Il.TextE _ ->
          [])

(* Extract paths with their corresponding types from an expression *)
let rec extract_paths_with_types_from_exp (sym_env : sym_env) (exp : Il.exp) :
    (field_path * Il.typ') list =
  (* Try to resolve top-level and use its type *)
  match resolve_to_field_path sym_env exp with
  | Some p -> [ (p, exp.note) ]
  | None -> (
      (* If not a path, recursively extract from sub-expressions *)
      match exp.it with
      | Il.BinE (_, _, e1, e2)
      | Il.CmpE (_, _, e1, e2)
      | Il.CatE (e1, e2)
      | Il.ConsE (e1, e2) ->
          extract_paths_with_types_from_exp sym_env e1
          @ extract_paths_with_types_from_exp sym_env e2
      | Il.UnE (_, _, e) | Il.UpdE (e, _, _) ->
          extract_paths_with_types_from_exp sym_env e
      | Il.LenE e -> extract_paths_with_types_from_exp sym_env e
      | Il.CallE (_, _, args) ->
          List.concat_map
            (fun arg ->
              match arg.it with
              | Il.ExpA e -> extract_paths_with_types_from_exp sym_env e
              | _ -> [])
            args
      | Il.IdxE (base, _idx) -> (
          (* For IdxE, try to resolve the full path first *)
          match resolve_to_field_path sym_env exp with
          | Some p -> [ (p, exp.note) ]
          | None -> (
              (* If that fails, extract from base but use IdxE result type *)
              (* This ensures array accesses like validators[i] get the element type, not list type *)
              match extract_paths_with_types_from_exp sym_env base with
              | [] -> []
              | base_paths ->
                  (* Replace types with the IdxE result type for all paths from base *)
                  List.map (fun (p, _) -> (p, exp.note)) base_paths))
      | Il.UpCastE (_, e)
      | Il.DownCastE (_, e)
      | Il.SubE (e, _)
      | Il.MatchE (e, _)
      | Il.MemE (e, _)
      | Il.OptE (Some e)
      | Il.IterE (e, _) ->
          extract_paths_with_types_from_exp sym_env e
      | Il.DotE (base, _atom) -> (
          (* For DotE, try to resolve the full path first *)
          match resolve_to_field_path sym_env exp with
          | Some p -> [ (p, exp.note) ]
          | None -> (
              (* If that fails, extract from base but use DotE result type *)
              (* This ensures field accesses like state.slot get the slot type, not state type *)
              match extract_paths_with_types_from_exp sym_env base with
              | [] -> []
              | base_paths ->
                  (* Replace types with the DotE result type for all paths from base *)
                  List.map (fun (p, _) -> (p, exp.note)) base_paths))
      | Il.VarE _ ->
          (* Should have been returned by resolve_to_field_path *)
          assert false
      | Il.TupleE es | Il.ListE es ->
          List.concat_map (extract_paths_with_types_from_exp sym_env) es
      | Il.StrE fields ->
          List.concat_map
            (fun (_, e) -> extract_paths_with_types_from_exp sym_env e)
            fields
      | Il.SliceE (e1, e2, e3) ->
          extract_paths_with_types_from_exp sym_env e1
          @ extract_paths_with_types_from_exp sym_env e2
          @ extract_paths_with_types_from_exp sym_env e3
      | Il.CaseE _ | Il.HoldE _
      | Il.OptE None
      | Il.BoolE _ | Il.NumE _ | Il.TextE _ ->
          [])

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
  | Unknown typ ->
      Printf.sprintf "UNKNOWN%s"
        (match typ with
        | Some t -> Printf.sprintf "(%s)" (Il.Print.string_of_typ t)
        | None -> "")

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
      let all_paths =
        lhs_paths @ rhs_paths |> List.map deduplicate_path
        |> List.map concretize_path_indices
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
                  Some
                    {
                      target_path = Some (concretize_path_indices path);
                      suggestion;
                    }
              | None ->
                  (* Can't evaluate - return Unknown with type *)
                  Some
                    {
                      target_path = Some (concretize_path_indices path);
                      suggestion = Unknown None;
                    })
          | None ->
              (* Can't rearrange - return Unknown *)
              Some
                {
                  target_path = Some (concretize_path_indices path);
                  suggestion = Unknown None;
                })
        all_paths
  | Il.CallE (_func_id, _, args) ->
      (* Verification functions: all args get Unknown *)
      (* Extract paths with their corresponding types from each argument *)
      List.concat_map
        (fun arg ->
          match arg.it with
          | Il.ExpA e ->
              let e_expanded = expand_vars sym_env e in
              (* Extract paths with their types - each path gets the type of its expression *)
              let path_type_pairs =
                extract_paths_with_types_from_exp sym_env e_expanded
              in
              List.map
                (fun (path, typ) ->
                  {
                    target_path = Some (concretize_path_indices path);
                    suggestion =
                      Unknown (Some { it = typ; at = no_region; note = () });
                  })
                path_type_pairs
          | Il.DefA _ -> [])
        args
  | Il.MatchE (exp_match, pat) -> (
      match pat with
      | Il.ListP `Nil ->
          (* matches [] => len == 0 *)
          let paths =
            extract_paths_from_exp sym_env (expand_vars sym_env exp_match)
          in
          List.map
            (fun path ->
              {
                target_path = Some (concretize_path_indices path);
                suggestion =
                  ToLength
                    ( `EqOp,
                      Il.Value.Make.num Il.Typ.nat (`Nat (Bigint.of_int 0)) );
              })
            paths
      | Il.ListP `Cons ->
          (* matches _::_ => len > 0 *)
          let paths =
            extract_paths_from_exp sym_env (expand_vars sym_env exp_match)
          in
          List.map
            (fun path ->
              {
                target_path = Some (concretize_path_indices path);
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
            target_path = Some (concretize_path_indices path);
            suggestion = ToConst (`EqOp, Il.Value.bool false);
          })
        paths
  | _ ->
      (* Boolean field or other: implicit check for true *)
      let paths = extract_paths_from_exp sym_env (expand_vars sym_env exp) in
      List.map
        (fun path ->
          {
            target_path = Some (concretize_path_indices path);
            suggestion = ToConst (`EqOp, Il.Value.bool true);
          })
        paths

(* Initialize the lookup_sym_ref to point to State.lookup_sym *)
let () = lookup_sym_ref := State.lookup_sym

(* Helper: Bind relation inputs based on runtime types and State.relation_inputs *)
let bind_relation_inputs (rel_id : string) (values : Il.Value.t list) : unit =
  (* Look up input names from static analysis (collected in init) *)
  match Hashtbl.find_opt State.relation_inputs rel_id with
  | None -> () (* No input info available *)
  | Some input_names ->
      let bind_state var val_note =
        State.bind_sym var
          {
            it = Il.VarE ("state" $ no_region);
            at = no_region;
            note = val_note.Il.typ;
          }
      in
      let bind_block var val_note =
        State.bind_sym var
          {
            it = Il.VarE ("block" $ no_region);
            at = no_region;
            note = val_note.Il.typ;
          }
      in
      (* Zip names and values *)
      let rec bind_loop names vals call_args =
        match (names, vals, call_args) with
        | n :: ns, v :: vs, arg_opt :: args_rest ->
            (* Dynamic Binding Strategy:
               1. If we have a symbolic argument from the caller, bind it directly! *)
            (match arg_opt with
            | Some sym_arg -> State.bind_sym n sym_arg
            | None ->
                (* 2. Fallback: Type-based heuristic *)
                let type_name =
                  match v.note.Il.typ with
                  | Il.VarT (id, _) -> String.lowercase_ascii id.it
                  | _ -> ""
                in
                if type_name = "beaconstate" then bind_state n v.note
                else if type_name = "signedbeaconblock" then bind_block n v.note
                else
                  (* Bind as simple local variable *)
                  (* Use runtime type for local variable ensures it can be resolved as Block/State if needed *)
                  State.bind_sym n
                    {
                      it = Il.VarE (n $ no_region);
                      at = no_region;
                      note = v.note.Il.typ;
                    });
            bind_loop ns vs args_rest
        | _ -> () (* Mismatch length or done *)
      in

      (* Prepare arguments list matching input names *)
      let effective_call_args =
        match !State.pending_call_args with
        | Some args ->
            (* Consume pending args *)
            let args_padded =
              if List.length args >= List.length input_names then
                List.map (fun a -> Some a) args
              else
                List.map (fun a -> Some a) args
                @ List.init
                    (List.length input_names - List.length args)
                    (fun _ -> None)
            in
            State.pending_call_args := None;
            args_padded
        | None -> List.init (List.length input_names) (fun _ -> None)
      in

      bind_loop input_names values effective_call_args

(* === Handler Implementation === *)

module M : Instrumentation_core.Handler.S = struct
  let init ~spec =
    State.reset ();
    match spec with
    | Instrumentation_core.Handler.IlSpec il_spec ->
        let inputs = extract_relation_inputs il_spec in
        Hashtbl.iter
          (fun k v -> Hashtbl.replace State.relation_inputs k v)
          inputs
    | Instrumentation_core.Handler.SlSpec _ -> ()

  let on_test_start ~test_case_id = State.current_test_id := test_case_id

  let on_test_end ~test_case_id:_ =
    (* Clear per-test state to prevent corruption across different inputs *)
    State.current_test_id := "";
    Hashtbl.clear State.sym_env;
    Hashtbl.clear State.seen_prems;
    Hashtbl.clear State.relation_outputs;
    State.frames := []
  (* Note: per_test_sym_mutations is preserved - it accumulates across tests *)

  let on_rel_enter ~id ~at:_ ~values =
    State.current_relation := id;
    State.push_call_frame ();
    (* Bind inputs using types and relation input names *)
    bind_relation_inputs id values

  let on_rel_exit ~id ~at:_ ~success =
    if success then (
      (* Before popping, capture relation outputs for propagation *)
      (* Note: nested frames (rules/clauses) have already been popped and merged
         into this barrier frame, so we only need to capture from the barrier frame *)
      (match !State.frames with
      | frame :: _ when frame.is_barrier && frame.relation_id = Some id ->
          (* Capture all bindings in this relation's frame as potential outputs *)
          (* These include bindings from nested scopes that were merged on pop *)
          let outputs = Hashtbl.create 20 in
          Hashtbl.iter
            (fun var_name expr -> Hashtbl.replace outputs var_name expr)
            frame.local_env;
          (* Store outputs for this relation *)
          Hashtbl.replace State.relation_outputs id outputs
      | _ -> ());
      State.pop_sym_frame_success ())
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

  let on_func_enter = Instrumentation_core.Noop.on_func_enter
  let on_func_exit = Instrumentation_core.Noop.on_func_exit
  let on_clause_enter ~id:_ ~clause_idx:_ ~at:_ = State.push_sym_frame ()

  let on_clause_exit ~id:_ ~clause_idx:_ ~at:_ ~success =
    if success then State.pop_sym_frame_success ()
    else State.pop_sym_frame_failure ()

  let on_iter_prem_enter = Instrumentation_core.Noop.on_iter_prem_enter
  let on_iter_prem_exit = Instrumentation_core.Noop.on_iter_prem_exit
  let on_instr = Instrumentation_core.Noop.on_instr

  let on_prem_enter ~eval ~prem ~at =
    (match eval with Some f -> State.current_eval := f | None -> ());
    (* Collect any function calls in this premise for symbolic tracking *)
    State.premise_count := !State.premise_count + 1;
    (* Progress indicator *)
    if !State.premise_count mod 500 = 0 then
      Format.eprintf "\r[Positive] %d premises, %d if-prems, %d skipped...%!"
        !State.premise_count !State.if_prem_count !State.skipped_count;

    if not (is_if_prem prem) then
      match prem.it with
      | Il.RulePr (_id, (_, args)) ->
          (* It's a relation call! Resolve arguments in CURRENT environment context *)
          (* and save them for the upcoming on_rel_enter *)
          let resolved_args =
            List.map (fun arg -> expand_vars State.sym_env arg) args
          in
          State.pending_call_args := Some resolved_args
      | _ -> ()
    else
      (* Get premise UID *)
      let prem_key = Premise_uid.prem_key prem in
      let uid = Premise_uid.assign_uid prem_key in

      (* Mark UID as seen for coverage tracking *)
      Hashtbl.replace State.seen_uids uid ();

      (* Check if this UID is in our target list (or if using whitelist fallback) *)
      let should_extract_mutations =
        if Hashtbl.length State.target_uids = 0 then
          (* No target UIDs specified - use whitelist *)
          is_whitelisted !State.current_relation
        else
          (* Target UIDs specified - filter by UID *)
          State.is_target_uid uid
      in

      if not should_extract_mutations then ()
      else
        let loc = string_of_region at in
        if State.already_seen loc then
          State.skipped_count := !State.skipped_count + 1
        else (
          State.mark_seen loc;
          State.if_prem_count := !State.if_prem_count + 1;

          match prem.it with
          | Il.IfPr exp ->
              (* Strip negation and bool_eq wrappers *)
              let exp1, _neg1 = strip_negation exp in
              let exp2, _neg2 = strip_bool_eq exp1 in
              (* Extract symbolic mutations directly from expression *)
              let sym_mutations =
                extract_symbolic_mutations State.sym_env exp2
              in
              State.add_per_test_sym_mutation uid sym_mutations
          | Il.IterPr ({ it = Il.IfPr exp; _ }, _) ->
              let exp1, _neg1 = strip_negation exp in
              let exp2, _neg2 = strip_bool_eq exp1 in
              let sym_mutations =
                extract_symbolic_mutations State.sym_env exp2
              in
              State.add_per_test_sym_mutation uid sym_mutations
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
      | Il.RulePr (rel_id, _) -> (
          (* Relation call completed successfully - bind outputs if available *)
          match Hashtbl.find_opt State.relation_outputs rel_id.it with
          | Some outputs ->
              (* Propagate relation outputs to caller's context *)
              Hashtbl.iter
                (fun var_name expr ->
                  (* Only bind if not already bound in current scope *)
                  match State.lookup_sym var_name with
                  | None -> State.bind_sym var_name expr
                  | Some _ -> ())
                outputs
          | None -> ())
      | _ -> ()
    else
      (* On failure, we don't accumulate dependencies or update bindings *)
      ()

  (* Noop - logic moved to on_prem_enter *)
  let on_prem_fields = Instrumentation_core.Noop.on_prem_fields

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
