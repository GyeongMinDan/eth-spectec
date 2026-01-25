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

(* Comparison operators - used by mutation_kind *)
type cmp_op = Eq | Ne | Lt | Le | Gt | Ge

(* === Field Path Set for Efficient Dependency Tracking === *)

module FieldPathSet = Set.Make (struct
  type t = field_path

  let compare = compare
end)

(* === Symbolic Expression Types === *)

(* Symbolic expression - tracks structure, not values *)
type sym_expr =
  | SVar of string * Il.Value.t option (* Variable reference + value *)
  | SPath of field_path * Il.Value.t option (* Resolved field path + value *)
  | SBinOp of Il.binop * Il.optyp * sym_expr * sym_expr (* A + B, A - B, etc. *)
  | SUnOp of Il.unop * Il.optyp * sym_expr (* -A, !A *)
  | SConst of Il.Value.t (* Constant value *)
  | SUpdate of sym_expr * field_path list (* state{.A, .B} - tracks mutations *)
  | SCall of string * sym_expr list (* $func(args) - future: inline getters *)
  | SUnknown of string (* Unresolvable *)

(* Enhanced source environment - maps variables to symbolic expressions *)
type sym_env = (string, sym_expr) Hashtbl.t

(* Mutation suggestion types *)
type mutation_kind =
  | ToConst of cmp_op * Il.Value.t (* path <op> value *)
  | ToLength of cmp_op * Il.Value.t (* collection length constraint *)
  | Unknown of Il.typ option (* over-approximation *)

type sym_mutation = {
  target_path : field_path option;
  suggestion : mutation_kind;
}

(* Frame for tracking sym_env bindings in scope *)
type pos_frame = { local_env : sym_env }

(* Lookup function ref - set by State module after initialization *)
(* This allows resolvers defined before State to use frame-aware lookup *)
let lookup_sym_ref : (string -> sym_expr option) ref = ref (fun _ -> None)

(* === Domain Knowledge: Ethereum Beacon Chain === *)

(* Check if a variable name refers to the state object *)
let is_state_var (name : string) : bool =
  name = "state" || name = "state'" || name = "state_cur" || name = "state_next"
  || name = "state_out"
  || name = "state_after_header"
  || String.starts_with ~prefix:"state_" name

(* Convert block input pattern to field path (used in on_rel_enter) *)
let path_of_block_pattern
    (pattern : Instrumentation_static.Mutator_analysis.block_input_pattern) :
    field_path =
  match pattern with
  | Instrumentation_static.Mutator_analysis.FullBlock
  | Instrumentation_static.Mutator_analysis.BlockMessage ->
      { source = Block; steps = [] }
  | Instrumentation_static.Mutator_analysis.BlockBody ->
      { source = Block; steps = [ FieldAccess "BODY" ] }
  | Instrumentation_static.Mutator_analysis.ExecutionPayload ->
      {
        source = Block;
        steps = [ FieldAccess "BODY"; FieldAccess "EXECUTION_PAYLOAD" ];
      }
  | Instrumentation_static.Mutator_analysis.SyncAggregate ->
      {
        source = Block;
        steps = [ FieldAccess "BODY"; FieldAccess "SYNC_AGGREGATE" ];
      }
  | Instrumentation_static.Mutator_analysis.Custom _path ->
      (* Defer to actual converter - will be defined later *)
      { source = Unknown; steps = [] }

(* === Expression Resolution (Positive-specific: detailed symbolic tracking) === *)

(* Convert IL cmpop to our type *)
let convert_cmpop (op : Il.cmpop) : cmp_op =
  match op with
  | `EqOp -> Eq
  | `NeOp -> Ne
  | `LtOp -> Lt
  | `LeOp -> Le
  | `GtOp -> Gt
  | `GeOp -> Ge

(* Resolve expression to structured field_path.
   More restrictive than resolve_to_path - only returns paths that can be mutated.
   Complex expressions (BinE, UnE, LenE, etc.) return None.
   Uses sym_env for variable lookups.
   
   Domain knowledge: State variables always refer to the same state object,
   so we can infer State source for common state variable names.
*)
let rec resolve_to_field_path (sym_env : sym_env) (exp : Il.exp) :
    field_path option =
  (* Use frame-aware lookup instead of direct hashtable access *)
  let lookup id = !lookup_sym_ref id in
  match exp.it with
  (* Variables: look up using frame-aware lookup for SPath *)
  | Il.VarE id -> (
      match lookup id.it with
      | Some (SPath (path, _)) -> Some path
      | Some (SVar (name, _)) ->
          Some { source = Unknown; steps = [ FieldAccess name ] }
      | Some _ -> None (* Has sym_expr but not a path *)
      | None ->
          (* Use centralized domain knowledge for state variables *)
          if is_state_var id.it then Some { source = State; steps = [] }
          else Some { source = Unknown; steps = [ FieldAccess id.it ] })
  (* Field access: base.field *)
  | Il.DotE (base, atom) -> (
      match resolve_to_field_path sym_env base with
      | Some base_path ->
          Some
            (append_step base_path
               (FieldAccess (Lang.Xl.Atom.string_of_atom atom.it)))
      | None -> None)
  (* Array indexing: base[idx] *)
  | Il.IdxE (base, idx) -> (
      match resolve_to_field_path sym_env base with
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
              (* Try to resolve as field path *)
              match resolve_to_field_path sym_env idx with
              | Some idx_path ->
                  Some (append_step base_path (IndexAccess (PathRef idx_path)))
              | None -> None)))
  | Il.SubE (inner, _)
  | Il.UpCastE (_, inner)
  | Il.DownCastE (_, inner)
  | Il.IterE (inner, _) ->
      resolve_to_field_path sym_env inner
  (* Optional: unwrap if Some *)
  | Il.OptE (Some inner) -> resolve_to_field_path sym_env inner
  | Il.OptE None -> None
  (* Everything else: can't represent as mutable path *)
  | Il.NumE _ | Il.BoolE _ | Il.TextE _ -> None (* Constants *)
  | Il.LenE _ -> None (* Length is not a mutable field *)
  | Il.UnE _ -> None (* Unary operations *)
  | Il.BinE _ -> None (* Binary operations *)
  | Il.CallE _ -> None (* Function calls *)
  | Il.MemE _ -> None (* Membership *)
  | Il.MatchE _ -> None (* Match expressions *)
  | _ -> None (* Fallback *)

(* Check if expression is a constant value *)
let is_constant_exp (exp : Il.exp) : Il.Value.t option =
  match exp.it with
  | Il.NumE n -> (
      match exp.note with
      | Il.NumT typ -> Some (Il.Value.Make.num (Il.NumT typ) n)
      | _ -> Some (Il.Value.Make.num Il.Typ.nat n))
  | Il.TextE s -> Some (Il.Value.Make.text Il.Typ.text s)
  | _ -> None

(* Extract field value from a struct value *)
let resolve_field_value (v : Il.Value.t) (field : string) : Il.Value.t option =
  try
    let fields = Il.Value.get_struct v in
    let _, value =
      List.find
        (fun (a, _) ->
          String.lowercase_ascii (Lang.Xl.Atom.string_of_atom a.it)
          = String.lowercase_ascii field)
        fields
    in
    Some value
  with _ -> None

(* Extract index value from a list value *)
let resolve_index_value (v : Il.Value.t) (idx : int) : Il.Value.t option =
  try
    let list = Il.Value.get_list v in
    Some (List.nth list idx)
  with _ -> None

(* Evaluate numeric binary operations *)
let eval_binop (op : Il.binop) (v1 : Il.Value.t) (v2 : Il.Value.t) :
    Il.Value.t option =
  let open Il in
  match (v1.it, v2.it) with
  | NumV n1, NumV n2 -> (
      match op with
      | `AddOp ->
          Some (Value.Make.num v1.note.typ (Lang.Xl.Num.bin `AddOp n1 n2))
      | `SubOp ->
          Some (Value.Make.num v1.note.typ (Lang.Xl.Num.bin `SubOp n1 n2))
      | `MulOp ->
          Some (Value.Make.num v1.note.typ (Lang.Xl.Num.bin `MulOp n1 n2))
      | `DivOp ->
          Some (Value.Make.num v1.note.typ (Lang.Xl.Num.bin `DivOp n1 n2))
      | `ModOp ->
          Some (Value.Make.num v1.note.typ (Lang.Xl.Num.bin `ModOp n1 n2))
      | `PowOp ->
          Some (Value.Make.num v1.note.typ (Lang.Xl.Num.bin `PowOp n1 n2))
      | _ -> None)
  | _ -> None

(* Evaluate numeric unary operations *)
let eval_unop (op : Il.unop) (v : Il.Value.t) : Il.Value.t option =
  let open Il in
  match v.it with
  | NumV n -> (
      match op with
      | `PlusOp -> Some (Value.Make.num v.note.typ (Lang.Xl.Num.un `PlusOp n))
      | `MinusOp -> Some (Value.Make.num v.note.typ (Lang.Xl.Num.un `MinusOp n))
      | _ -> None)
  | _ -> None

(* Evaluate symbolic expression to concrete value recursively. *)
let rec eval_sym_expr (sym : sym_expr) : Il.Value.t option =
  match sym with
  | SConst v -> Some v
  | SBinOp (op, _, s1, s2) -> (
      match (eval_sym_expr s1, eval_sym_expr s2) with
      | Some v1, Some v2 -> eval_binop op v1 v2
      | _ -> None)
  | SUnOp (op, _, s) -> (
      match eval_sym_expr s with Some v -> eval_unop op v | None -> None)
  | SPath (_, v_opt) -> v_opt (* Use tracked runtime value if available *)
  | SVar (_, v_opt) -> v_opt
  | SCall _ | SUpdate _ | SUnknown _ -> None

(* Resolve expression to symbolic expression *)
let rec resolve_to_sym_expr (sym_env : sym_env) (exp : Il.exp) : sym_expr =
  (* Use frame-aware lookup instead of direct hashtable access *)
  let lookup id = !lookup_sym_ref id in
  match exp.it with
  (* Variable lookup *)
  | Il.VarE id -> (
      match lookup id.it with Some sym -> sym | None -> SVar (id.it, None))
  (* Field paths - handle DotE and IdxE recursively *)
  | Il.DotE (base, atom) -> (
      let base_sym = resolve_to_sym_expr sym_env base in
      match base_sym with
      | SPath (base_path, base_val_opt) ->
          let field_name = Lang.Xl.Atom.string_of_atom atom.it in
          (* Try to extract field value if base has value *)
          let val_opt =
            match base_val_opt with
            | Some v -> resolve_field_value v field_name
            | None -> None
          in
          SPath (append_step base_path (FieldAccess field_name), val_opt)
      | _ -> (
          (* Fallback to direct resolution *)
          match resolve_to_field_path sym_env exp with
          | Some path -> SPath (path, None)
          | None -> SUnknown "complex_path"))
  | Il.IdxE (base, idx) -> (
      let base_sym = resolve_to_sym_expr sym_env base in
      let idx_sym = resolve_to_sym_expr sym_env idx in
      match (base_sym, idx_sym) with
      | SPath (base_path, base_val_opt), SPath (idx_path, _) ->
          (* Dynamic index - we likely can't resolve value unless we know index value *)
          (* But we have idx_sym, maybe it has a value? *)
          let val_opt =
            match (base_val_opt, eval_sym_expr idx_sym) with
            | Some v_base, Some v_idx -> (
                match v_idx.it with
                | Il.NumV (`Nat n) ->
                    resolve_index_value v_base (Bigint.to_int_exn n)
                | _ -> None)
            | _ -> None
          in
          SPath (append_step base_path (IndexAccess (PathRef idx_path)), val_opt)
      | SPath (base_path, base_val_opt), SVar (idx_name, idx_val_opt) ->
          (* Symbolic index from variable SVar *)
          let val_opt =
            match (base_val_opt, idx_val_opt) with
            | Some v_base, Some v_idx -> (
                match v_idx.it with
                | Il.NumV (`Nat n) ->
                    resolve_index_value v_base (Bigint.to_int_exn n)
                | _ -> None)
            | _ -> None
          in
          let idx_path =
            { source = Unknown; steps = [ FieldAccess idx_name ] }
          in
          SPath (append_step base_path (IndexAccess (PathRef idx_path)), val_opt)
      | SPath (base_path, base_val_opt), SConst v_idx -> (
          (* Constant index from expression *)
          let val_opt =
            match base_val_opt with
            | Some v_base -> (
                match v_idx.it with
                | Il.NumV (`Nat n) ->
                    resolve_index_value v_base (Bigint.to_int_exn n)
                | _ -> None)
            | None -> None
          in
          (* Note: path logic for SConst index is complex inside resolve_to_field_path *)
          (* But here we construct SPath. SPath usually expects PathRef for index step? *)
          (* Or ConstInt. append_step takes field_step. field_step takes index_expr. *)
          (* index_expr has ConstInt. *)
          let idx_step =
            match v_idx.it with
            | Il.NumV (`Nat n) -> Some (ConstInt (Bigint.to_int_exn n))
            | _ -> None
          in
          match idx_step with
          | Some step ->
              SPath (append_step base_path (IndexAccess step), val_opt)
          | None -> SUnknown "invalid_index")
      | _ -> (
          (* Fallback to direct resolution *)
          match resolve_to_field_path sym_env exp with
          | Some path -> SPath (path, None)
          | None -> SUnknown "complex_path"))
  (* Constants *)
  | Il.NumE _ | Il.BoolE _ | Il.TextE _ -> (
      match is_constant_exp exp with
      | Some v -> SConst v
      | None -> SUnknown "constant")
  (* Binary operations *)
  | Il.BinE (op, typ, e1, e2) ->
      let s1 = resolve_to_sym_expr sym_env e1 in
      let s2 = resolve_to_sym_expr sym_env e2 in
      SBinOp (op, typ, s1, s2)
  (* Unary operations *)
  | Il.UnE (op, typ, e) ->
      let s = resolve_to_sym_expr sym_env e in
      SUnOp (op, typ, s)
  (* Length expressions *)
  | Il.LenE inner ->
      (* For now, treat as a special kind of call - we can't resolve to a concrete value *)
      (* but we can still track it symbolically *)
      SCall ("len", [ resolve_to_sym_expr sym_env inner ])
  (* Function calls *)
  | Il.CallE (id, _, args) ->
      let func_name = id.it in
      let sym_args =
        List.filter_map
          (fun arg ->
            match arg.it with
            | Il.ExpA e -> Some (resolve_to_sym_expr sym_env e)
            | Il.DefA _ -> None)
          args
      in
      (* Handle special functions that return computed values we can track *)
      if func_name = "get_current_epoch" || func_name = "$get_current_epoch"
      then
        (* This returns a computed epoch value - treat as a symbolic variable for now *)
        SVar ("current_epoch", None)
      else SCall (func_name, sym_args)
  (* Unwrap wrappers *)
  | Il.SubE (e, _) | Il.UpCastE (_, e) | Il.DownCastE (_, e) | Il.IterE (e, _)
    ->
      resolve_to_sym_expr sym_env e
  | Il.OptE (Some e) -> resolve_to_sym_expr sym_env e
  (* Everything else *)
  | _ -> SUnknown "unsupported"

(* Extract all field paths from a symbolic expression *)
let rec extract_paths_from_sym_expr (sym : sym_expr) : field_path list =
  match sym with
  | SVar (var_name, _) ->
      (* Check if it's an epoch-related variable *)
      if
        String.starts_with ~prefix:"epoch" var_name
        || var_name = "current_epoch"
        || String.ends_with ~suffix:"_epoch" var_name
      then [ { source = State; steps = [ FieldAccess "SLOT" ] } ]
      else [ { source = Unknown; steps = [ FieldAccess var_name ] } ]
  | SPath (p, _) -> [ p ]
  | SBinOp (_, _, s1, s2) ->
      extract_paths_from_sym_expr s1 @ extract_paths_from_sym_expr s2
  | SUnOp (_, _, s) -> extract_paths_from_sym_expr s
  | SConst _ -> []
  | SUpdate (s, paths) -> extract_paths_from_sym_expr s @ paths
  | SCall (_, args) -> List.concat_map extract_paths_from_sym_expr args
  | SUnknown _ -> []

(* Convert Mutator_analysis.field_path to Dep_common.field_path *)
let rec convert_ma_index_expr
    (idx : Instrumentation_static.Mutator_analysis.index_expr) : index_expr =
  match idx with
  | Instrumentation_static.Mutator_analysis.ConstInt i -> ConstInt i
  | Instrumentation_static.Mutator_analysis.PathRef p ->
      PathRef (convert_ma_field_path p)

and convert_ma_field_step
    (step : Instrumentation_static.Mutator_analysis.field_step) : field_step =
  match step with
  | Instrumentation_static.Mutator_analysis.FieldAccess s -> FieldAccess s
  | Instrumentation_static.Mutator_analysis.IndexAccess idx ->
      IndexAccess (convert_ma_index_expr idx)

and convert_ma_field_path
    (path : Instrumentation_static.Mutator_analysis.field_path) : field_path =
  let source =
    match path.source with
    | Instrumentation_static.Mutator_analysis.State -> State
    | Instrumentation_static.Mutator_analysis.Block -> Block
    | Instrumentation_static.Mutator_analysis.Unknown -> Unknown
  in
  { source; steps = List.map convert_ma_field_step path.steps }

(* Check if premise is an if-premise *)
let rec is_if_prem (prem : Il.prem) : bool =
  match prem.it with
  | Il.IfPr _ -> true
  | Il.IterPr (inner, _) -> is_if_prem inner
  | _ -> false

(* === String Formatting === *)

let string_of_cmp_op = function
  | Eq -> "=="
  | Ne -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="

(* String formatting for symbolic expressions *)
let rec string_of_sym_expr (sym : sym_expr) : string =
  match sym with
  | SVar (id, None) -> id
  | SVar (id, Some v) ->
      Printf.sprintf "%s(=%s)" id (Il.Print.string_of_value v)
  | SPath (path, None) -> string_of_field_path path
  | SPath (path, Some v) ->
      Printf.sprintf "%s(=%s)"
        (string_of_field_path path)
        (Il.Print.string_of_value v)
  | SBinOp (op, _, s1, s2) ->
      Printf.sprintf "(%s %s %s)" (string_of_sym_expr s1)
        (Il.Print.string_of_binop op)
        (string_of_sym_expr s2)
  | SUnOp (op, _, s) ->
      Printf.sprintf "%s%s" (Il.Print.string_of_unop op) (string_of_sym_expr s)
  | SConst v -> Il.Print.string_of_value v
  | SUpdate (s, paths) ->
      Printf.sprintf "%s{.%s}" (string_of_sym_expr s)
        (String.concat ", ." (List.map string_of_field_path paths))
  | SCall (name, args) ->
      Printf.sprintf "$%s(%s)" name
        (String.concat ", " (List.map string_of_sym_expr args))
  | SUnknown msg -> Printf.sprintf "?%s" msg

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
  | Eq -> Eq
  | Ne -> Ne
  | Lt -> Gt
  | Le -> Ge
  | Gt -> Lt
  | Ge -> Le

(* Algebraically rearrange comparison to isolate target_path on LHS.
   For A < B + C with target=B, returns (B, >, A - C).
   Returns None if target_path not found or rearrangement not possible. *)
let algebraic_rearrange (lhs_sym : sym_expr) (rhs_sym : sym_expr) (op : cmp_op)
    (target_path : field_path) : (cmp_op * sym_expr) option =
  (* Check if target_path appears in lhs_sym *)
  let paths_lhs = extract_paths_from_sym_expr lhs_sym in
  let paths_rhs = extract_paths_from_sym_expr rhs_sym in
  let in_lhs = List.mem target_path paths_lhs in
  let in_rhs = List.mem target_path paths_rhs in

  match (in_lhs, in_rhs) with
  | true, false -> (
      if
        (* Target is on LHS *)
        lhs_sym = SPath (target_path, None)
        || lhs_sym = SPath (target_path, eval_sym_expr lhs_sym)
      then Some (op, rhs_sym)
      (* Note: equality on SPath might fail if values differ? Should check path only *)
        else
        match lhs_sym with
        | SPath (p, _) when p = target_path -> Some (op, rhs_sym)
        | _ -> (
            (* Try to isolate target from simple arithmetic: A + C, A - C, C + A *)
            match lhs_sym with
            | SBinOp (`AddOp, _, s1, s2) ->
                if match s1 with SPath (p, _) -> p = target_path | _ -> false
                then
                  (* A + C < B  =>  A < B - C *)
                  Some (op, SBinOp (`SubOp, `IntT, rhs_sym, s2))
                else if
                  match s2 with SPath (p, _) -> p = target_path | _ -> false
                then
                  (* C + A < B  =>  A < B - C *)
                  Some (op, SBinOp (`SubOp, `IntT, rhs_sym, s1))
                else None
            | SBinOp (`SubOp, _, s1, s2) ->
                if match s1 with SPath (p, _) -> p = target_path | _ -> false
                then
                  (* A - C < B  =>  A < B + C *)
                  Some (op, SBinOp (`AddOp, `IntT, rhs_sym, s2))
                else if
                  match s2 with SPath (p, _) -> p = target_path | _ -> false
                then
                  (* C - A < B  =>  -A < B - C  =>  A > C - B *)
                  (* Note: Inverting op! *)
                  Some (invert_cmp_op op, SBinOp (`SubOp, `IntT, s1, rhs_sym))
                else None
            | _ -> None))
  | false, true ->
      (* Target is on RHS: LHS < B → B > LHS *)
      if match rhs_sym with SPath (p, _) -> p = target_path | _ -> false then
        Some (invert_cmp_op op, lhs_sym)
      else None (* Isolate from RHS arithmetic not implemented yet *)
  | _ -> None (* Target in both sides or neither *)

let extract_symbolic_mutations (sym_env : sym_env) (exp : Il.exp) :
    sym_mutation list =
  match exp.it with
  | Il.CmpE (op, _, lhs_exp, rhs_exp) ->
      let lhs_sym = resolve_to_sym_expr sym_env lhs_exp in
      let rhs_sym = resolve_to_sym_expr sym_env rhs_exp in
      let cmp_op = convert_cmpop op in

      (* Extract all paths from both sides *)
      let lhs_paths = extract_paths_from_sym_expr lhs_sym in
      let rhs_paths = extract_paths_from_sym_expr rhs_sym in
      let all_paths = lhs_paths @ rhs_paths in

      (* For each path, try to rearrange and evaluate *)
      List.filter_map
        (fun path ->
          match algebraic_rearrange lhs_sym rhs_sym cmp_op path with
          | Some (isolated_op, isolated_rhs) -> (
              (* Try to evaluate RHS to concrete value *)
              match eval_sym_expr isolated_rhs with
              | Some value ->
                  Some
                    {
                      target_path = Some path;
                      suggestion = ToConst (isolated_op, value);
                    }
              | None ->
                  (* Can't evaluate - return Unknown with type *)
                  Some { target_path = Some path; suggestion = Unknown None })
          | None ->
              (* Can't rearrange - return Unknown *)
              Some { target_path = Some path; suggestion = Unknown None })
        all_paths
  | Il.CallE (_, _, args) ->
      (* Verification functions: all args get Unknown *)
      let arg_paths =
        List.concat_map
          (fun arg ->
            match arg.it with
            | Il.ExpA e ->
                extract_paths_from_sym_expr (resolve_to_sym_expr sym_env e)
            | Il.DefA _ -> [])
          args
      in
      List.map
        (fun path -> { target_path = Some path; suggestion = Unknown None })
        arg_paths
  | Il.MatchE (exp_match, pat) -> (
      match pat with
      | Il.ListP `Nil ->
          (* matches [] => len == 0 *)
          let paths =
            extract_paths_from_sym_expr (resolve_to_sym_expr sym_env exp_match)
          in
          List.map
            (fun path ->
              {
                target_path = Some path;
                suggestion =
                  ToLength
                    (Eq, Il.Value.Make.num Il.Typ.nat (`Nat (Bigint.of_int 0)));
              })
            paths
      | Il.ListP `Cons ->
          (* matches _::_ => len > 0 *)
          let paths =
            extract_paths_from_sym_expr (resolve_to_sym_expr sym_env exp_match)
          in
          List.map
            (fun path ->
              {
                target_path = Some path;
                suggestion =
                  ToLength
                    (Gt, Il.Value.Make.num Il.Typ.nat (`Nat (Bigint.of_int 0)));
              })
            paths
      | _ -> [])
  | _ ->
      (* Boolean field or other: try to extract paths *)
      let paths =
        extract_paths_from_sym_expr (resolve_to_sym_expr sym_env exp)
      in
      List.map
        (fun path -> { target_path = Some path; suggestion = Unknown None })
        paths

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

  (* Per-test symbolic mutations: premise_uid -> test_id -> sym_mutation list *)
  let per_test_sym_mutations :
      (int, (string, sym_mutation list) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 1000

  (* Progress tracking *)
  let premise_count = ref 0
  let if_prem_count = ref 0
  let skipped_count = ref 0
  let func_depth = ref 0

  (* Target UIDs for filtering - empty means no filtering (use whitelist) *)
  let target_uids : (int, unit) Hashtbl.t = Hashtbl.create 16

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
    frames := [];
    Hashtbl.clear per_test_sym_mutations;
    premise_count := 0;
    if_prem_count := 0;
    skipped_count := 0;
    func_depth := 0

  let in_helper_function () = !func_depth > 0
  let already_seen loc = Hashtbl.mem seen_prems loc
  let mark_seen loc = Hashtbl.replace seen_prems loc ()

  (* Frame management for sym_env backtracking *)
  let push_sym_frame () =
    let new_frame = { local_env = Hashtbl.create 20 } in
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
  let lookup_sym (id : string) : sym_expr option =
    let rec check_frames fs =
      match fs with
      | [] -> Hashtbl.find_opt sym_env id
      | frame :: rest -> (
          match Hashtbl.find_opt frame.local_env id with
          | Some v -> Some v
          | None -> check_frames rest)
    in
    check_frames !frames

  (* Bind in current frame's local_env (or global if no frame) *)
  let bind_sym (id : string) (expr : sym_expr) : unit =
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

(* Initialize the lookup_sym_ref to point to State.lookup_sym *)
let () = lookup_sym_ref := State.lookup_sym

(* Helper: Bind relation inputs based on static analysis results and runtime values *)
let bind_relation_inputs
    (input_info : Instrumentation_static.Mutator_analysis.relation_input_info)
    (values : Il.Value.t list) : unit =
  let bind_state var value =
    State.bind_sym var (SPath ({ source = State; steps = [] }, Some value))
  in
  let bind_block var pattern value =
    let path =
      match pattern with
      | Instrumentation_static.Mutator_analysis.Custom p ->
          convert_ma_field_path p
      | _ -> path_of_block_pattern pattern
    in
    State.bind_sym var (SPath (path, Some value))
  in
  (* Iterate over inputs and bind based on type information *)
  (* Combine names, types, and values safely *)
  let rec bind_inputs names types vals =
    match (names, types, vals) with
    | name :: ns, typ :: ts, v :: vs ->
        (match typ.it with
        | Il.VarT ({ it = "beaconState"; _ }, _) -> bind_state name v
        | Il.VarT ({ it = "signedBeaconBlock"; _ }, _) ->
            bind_block name Instrumentation_static.Mutator_analysis.FullBlock v
        | Il.VarT ({ it = "beaconBlock"; _ }, _) ->
            bind_block name Instrumentation_static.Mutator_analysis.BlockMessage
              v
        | Il.VarT ({ it = "beaconBlockBody"; _ }, _) ->
            bind_block name Instrumentation_static.Mutator_analysis.BlockBody v
        | Il.VarT ({ it = "executionPayload"; _ }, _) ->
            bind_block name
              Instrumentation_static.Mutator_analysis.ExecutionPayload v
        | Il.VarT ({ it = "syncAggregate"; _ }, _) ->
            bind_block name
              Instrumentation_static.Mutator_analysis.SyncAggregate v
        | _ ->
            (* Fallback: heuristic based on variable name *)
            if is_state_var name then bind_state name v else ());
        bind_inputs ns ts vs
    | _ -> ()
  in
  bind_inputs input_info.input_var_names input_info.input_types values

(* === Handler Implementation === *)

module M : Instrumentation_core.Handler.S = struct
  let init ~spec =
    State.reset ();
    match spec with
    | Instrumentation_core.Handler.IlSpec il_spec ->
        let inputs = extract_relation_inputs il_spec in
        Hashtbl.iter
          (fun k v ->
            if k = "State_transition" then
              Format.printf "[DEBUG Positive.init] Found inputs for %s: %s\n" k
                (String.concat ", " v);
            Hashtbl.replace State.relation_inputs k v)
          inputs
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
    (* Bind inputs using static analysis for ALL relations *)
    match
      Instrumentation_static.Mutator_analysis.get_relation_input_info id
    with
    | Some input_info -> bind_relation_inputs input_info values
    | None ->
        (* Fallback for State_transition if static analysis didn't capture it *)
        if id = "State_transition" then
          match Hashtbl.find_opt State.relation_inputs id with
          | Some (state_var :: block_var :: _) -> (
              (* Heuristic: assume first two values are state and block if available *)
              match values with
              | v_state :: v_block :: _ ->
                  State.bind_sym state_var
                    (SPath ({ source = State; steps = [] }, Some v_state));
                  State.bind_sym block_var
                    (SPath ({ source = Block; steps = [] }, Some v_block))
              | _ ->
                  State.bind_sym state_var
                    (SPath ({ source = State; steps = [] }, None));
                  State.bind_sym block_var
                    (SPath ({ source = Block; steps = [] }, None)))
          | _ -> ()
        else ()

  let on_rel_exit ~id:_ ~at:_ ~success:_ =
    State.current_relation := "";
    State.current_rule := ""

  let on_rule_enter ~id:_ ~rule_id ~at:_ =
    State.current_rule := rule_id;

    State.push_sym_frame ()

  let on_rule_exit ~id:_ ~rule_id:_ ~at:_ ~success =
    if success then State.pop_sym_frame_success ()
    else State.pop_sym_frame_failure ();
    State.current_rule := ""

  let on_func_enter ~id:_ ~at:_ ~values:_ =
    State.func_depth := !State.func_depth + 1

  let on_func_exit ~id:_ ~at:_ = State.func_depth := !State.func_depth - 1
  let on_clause_enter ~id:_ ~clause_idx:_ ~at:_ = State.push_sym_frame ()

  let on_clause_exit ~id:_ ~clause_idx:_ ~at:_ ~success =
    if success then State.pop_sym_frame_success ()
    else State.pop_sym_frame_failure ()

  let on_iter_prem_enter ~prem ~at:_ =
    (* Track iteration variables in symbolic environment *)
    match prem.it with
    | Il.IterPr (_, (_iter, vars)) ->
        (* Bind iteration variables to symbolic environment *)
        List.iter
          (fun (id, _typ, _) ->
            (* For now, treat iteration variables as unknown symbolic values *)
            (* In the future, we could be more specific about their ranges/types *)
            Hashtbl.replace State.sym_env id.it (SVar (id.it, None)))
          vars
    | _ -> ()

  let on_iter_prem_exit ~at:_ =
    (* Note: We don't unbind iteration variables on exit because they might be used
       in subsequent premises. The symbolic environment persists across the relation. *)
    ()

  let on_instr = Instrumentation_core.Noop.on_instr

  let on_prem_enter ~prem ~at =
    State.premise_count := !State.premise_count + 1;
    (* Progress indicator *)
    if !State.premise_count mod 500 = 0 then
      Format.eprintf "\r[Positive] %d premises, %d if-prems, %d skipped...%!"
        !State.premise_count !State.if_prem_count !State.skipped_count;

    if State.in_helper_function () then ()
    else if not (is_if_prem prem) then ()
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
          let sym = resolve_to_sym_expr State.sym_env rhs in
          Hashtbl.replace State.sym_env id.it sym
      (* Handle IterPr(LetPr) - nested let bindings in iterations *)
      | Il.IterPr ({ it = Il.LetPr ({ it = Il.VarE id; _ }, rhs); _ }, _) ->
          let sym = resolve_to_sym_expr State.sym_env rhs in
          Hashtbl.replace State.sym_env id.it sym
      | Il.RulePr _ -> ()
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
