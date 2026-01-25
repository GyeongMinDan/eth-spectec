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

(* Comparison operators - used by sym_mutation *)
type cmp_op = Eq | Ne | Lt | Le | Gt | Ge

(* === Field Path Set for Efficient Dependency Tracking === *)

module FieldPathSet = Set.Make (struct
  type t = field_path

  let compare = compare
end)

(* === Symbolic Expression Types === *)

(* Symbolic expression - tracks structure, not values *)
type sym_expr =
  | SVar of string (* Variable reference *)
  | SPath of field_path (* Resolved field path *)
  | SBinOp of Il.binop * Il.optyp * sym_expr * sym_expr (* A + B, A - B, etc. *)
  | SUnOp of Il.unop * Il.optyp * sym_expr (* -A, !A *)
  | SConst of Il.Value.t (* Constant value *)
  | SUpdate of sym_expr * field_path list (* state{.A, .B} - tracks mutations *)
  | SCall of string * sym_expr list (* $func(args) - future: inline getters *)
  | SUnknown of string (* Unresolvable *)

(* Enhanced source environment - maps variables to symbolic expressions *)
type sym_env = (string, sym_expr) Hashtbl.t

(* Mutation suggestion with symbolic target *)
type sym_mutation = {
  target_path : field_path option; (* None if unresolved *)
  suggestion : mutation_kind;
  mutation_target : mutation_target; (* What aspect to mutate *)
  debug_info : string option;
}

and mutation_kind =
  | ToValue of sym_expr (* Set to symbolic expression *)
  | ToRelation of cmp_op * sym_expr
  | Unresolved of string

(* Unresolved mutation with reason *)
(* e.g., <= (A + B) → A=B, A=B+1, A=B-MAX *)

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
      | Some (SPath path) -> Some path
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
  | Il.BoolE b -> Some (Il.Value.Make.bool Il.Typ.bool b)
  | Il.TextE s -> Some (Il.Value.Make.text Il.Typ.text s)
  | _ -> None

(* Resolve expression to symbolic expression *)
let rec resolve_to_sym_expr (sym_env : sym_env) (exp : Il.exp) : sym_expr =
  (* Use frame-aware lookup instead of direct hashtable access *)
  let lookup id = !lookup_sym_ref id in
  match exp.it with
  (* Variable lookup *)
  | Il.VarE id -> (
      match lookup id.it with Some sym -> sym | None -> SVar id.it)
  (* Field paths - handle DotE and IdxE recursively *)
  | Il.DotE (base, atom) -> (
      let base_sym = resolve_to_sym_expr sym_env base in
      match base_sym with
      | SPath base_path ->
          SPath
            (append_step base_path
               (FieldAccess (Lang.Xl.Atom.string_of_atom atom.it)))
      | _ -> (
          (* Fallback to direct resolution *)
          match resolve_to_field_path sym_env exp with
          | Some path -> SPath path
          | None -> SUnknown "complex_path"))
  | Il.IdxE (base, idx) -> (
      let base_sym = resolve_to_sym_expr sym_env base in
      let idx_sym = resolve_to_sym_expr sym_env idx in
      match (base_sym, idx_sym) with
      | SPath base_path, SPath idx_path ->
          SPath (append_step base_path (IndexAccess (PathRef idx_path)))
      | SPath _base_path, SConst _v -> (
          (* For now, we can't easily extract numeric index from Il.Value.t *)
          (* Fallback to direct resolution *)
          match resolve_to_field_path sym_env exp with
          | Some path -> SPath path
          | None -> SUnknown "complex_path")
      | _ -> (
          (* Fallback to direct resolution *)
          match resolve_to_field_path sym_env exp with
          | Some path -> SPath path
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
        SVar "current_epoch"
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
  | SVar var_name ->
      (* Check if it's an epoch-related variable *)
      if
        String.starts_with ~prefix:"epoch" var_name
        || var_name = "current_epoch"
        || String.ends_with ~suffix:"_epoch" var_name
      then [ { source = State; steps = [ FieldAccess "SLOT" ] } ]
      else [] (* Other variables don't have paths directly *)
  | SPath p -> [ p ]
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
  | SVar id -> id
  | SPath path -> string_of_field_path path
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
let string_of_mutation_kind (kind : mutation_kind) : string =
  match kind with
  | ToValue sym -> Printf.sprintf "= %s" (string_of_sym_expr sym)
  | ToRelation (op, sym) ->
      Printf.sprintf "%s %s"
        (match op with
        | Eq -> "=="
        | Ne -> "!="
        | Lt -> "<"
        | Le -> "<="
        | Gt -> ">"
        | Ge -> ">=")
        (string_of_sym_expr sym)
  | Unresolved reason -> Printf.sprintf "[UNRESOLVED: %s]" reason

let string_of_sym_mutation (mut : sym_mutation) : string =
  let target_str =
    match mut.target_path with
    | Some path -> string_of_field_path path
    | None -> "?"
  in
  let base_str =
    Printf.sprintf "%s → %s" target_str (string_of_mutation_kind mut.suggestion)
  in
  match mut.debug_info with
  | Some info -> Printf.sprintf "%s [DEBUG: %s]" base_str info
  | None -> base_str

(* Check if a field path corresponds to a variable in sym_env *)
let find_var_for_path (sym_env : sym_env) (path : field_path) : sym_expr option
    =
  let rec path_matches (sym : sym_expr) : bool =
    match sym with
    | SPath p when p = path -> true
    | SBinOp (_, _, s1, s2) -> path_matches s1 || path_matches s2
    | SUnOp (_, _, s) -> path_matches s
    | SUpdate (s, _) -> path_matches s
    | SCall (_, args) -> List.exists path_matches args
    | _ -> false
  in
  let found_var = ref None in
  Hashtbl.iter
    (fun _var_id sym ->
      if !found_var = None && path_matches sym then found_var := Some sym)
    sym_env;
  !found_var

(* === Mutation Extraction Helpers === *)

(* Resolve LHS expression to a field path.
   Function calls (including length expressions) are computed values,
   not mutable field paths, so they return None. *)
let resolve_comparison_lhs (sym_env : sym_env) (lhs_exp : Il.exp) :
    field_path option =
  let lhs_sym = resolve_to_sym_expr sym_env lhs_exp in
  match lhs_sym with
  | SPath p -> Some p
  | SCall _ -> None (* Function calls/len are computed, not mutable paths *)
  | SBinOp _ | SUnOp _ -> None (* Arithmetic expressions are not mutable *)
  | _ -> (
      let paths = extract_paths_from_sym_expr lhs_sym in
      match paths with p :: _ -> Some p | [] -> None)

(* Over-approximate LHS resolution: returns a LIST of field paths.
   Used when precise resolution fails. Expands function calls to their
   input dependencies, and arithmetic expressions to their component paths. *)
let resolve_comparison_lhs_overapprox (sym_env : sym_env) (lhs_exp : Il.exp) :
    field_path list =
  let lhs_sym = resolve_to_sym_expr sym_env lhs_exp in
  match lhs_sym with
  | SPath p -> [ p ] (* Precise: single path *)
  | SCall (_func_name, args) ->
      (* Extract paths from function arguments via sym_env resolution *)
      (* The args are already sym_expr from the environment, so just extract paths *)
      List.concat_map extract_paths_from_sym_expr args
  | SBinOp (_, _, s1, s2) ->
      (* Arithmetic: extract all paths from both operands *)
      extract_paths_from_sym_expr s1 @ extract_paths_from_sym_expr s2
  | SUnOp (_, _, s) -> extract_paths_from_sym_expr s
  | SVar var_name ->
      (* Unbound variable: check if it's epoch-related or loop index *)
      if
        String.starts_with ~prefix:"epoch" var_name
        || var_name = "current_epoch"
        || String.ends_with ~suffix:"_epoch" var_name
      then [ { source = State; steps = [ FieldAccess "SLOT" ] } ]
      else if var_name = "i" || String.starts_with ~prefix:"vid" var_name then
        (* Loop index - will be handled by extracting from RHS *)
        []
      else []
  | _ -> extract_paths_from_sym_expr lhs_sym

(* Resolve RHS expression to symbolic expression *)
let resolve_comparison_rhs (sym_env : sym_env) (rhs_exp : Il.exp) : sym_expr =
  resolve_to_sym_expr sym_env rhs_exp

(* Generate mutations for a function call RHS *)
let handle_function_call_rhs (target_path : field_path) (func_name : string)
    (args : sym_expr list) (rhs_exp : Il.exp) : sym_mutation list =
  (* No-arg functions are constants *)
  if args = [] then
    [
      {
        target_path = Some target_path;
        mutation_target = Value;
        suggestion = ToValue (SCall (func_name, args));
        debug_info = Some (Printf.sprintf "Constant: $%s()" func_name);
      };
    ]
  else
    match func_name with
    | "ZERO_ROOT" ->
        (* ZERO_ROOT is a constant even with args *)
        [
          {
            target_path = Some target_path;
            mutation_target = Value;
            suggestion = ToValue (SCall (func_name, args));
            debug_info = None;
          };
        ]
    | "hash_tree_root_beaconBlockHeader" ->
        [
          {
            target_path = Some target_path;
            mutation_target = Value;
            suggestion =
              Unresolved
                (Printf.sprintf "RHS: complex hash function %s" func_name);
            debug_info = Some (Il.Print.string_of_exp rhs_exp);
          };
        ]
    | "get_randao_mix" | "compute_time_at_slot" ->
        (* Over-approximate: extract paths from arguments *)
        let arg_paths = List.concat_map extract_paths_from_sym_expr args in
        if arg_paths = [] then
          [
            {
              target_path = Some target_path;
              mutation_target = Value;
              suggestion =
                Unresolved
                  (Printf.sprintf "RHS: computed value from %s" func_name);
              debug_info = Some (Il.Print.string_of_exp rhs_exp);
            };
          ]
        else
          (* Generate mutations for argument paths *)
          List.map
            (fun arg_path ->
              {
                target_path = Some arg_path;
                mutation_target = Value;
                suggestion = ToValue (SUnknown "affects-rhs");
                debug_info =
                  Some (Printf.sprintf "From %s arg (affects RHS)" func_name);
              })
            arg_paths
    | _ ->
        (* Unknown function: over-approximate by extracting argument paths *)
        let arg_paths = List.concat_map extract_paths_from_sym_expr args in
        if arg_paths = [] then
          [
            {
              target_path = Some target_path;
              mutation_target = Value;
              suggestion =
                Unresolved (Printf.sprintf "RHS: function call %s" func_name);
              debug_info = Some (Il.Print.string_of_exp rhs_exp);
            };
          ]
        else
          (* Return both target and argument paths *)
          {
            target_path = Some target_path;
            mutation_target = Value;
            suggestion = ToValue (SCall (func_name, args));
            debug_info = Some (Printf.sprintf "RHS: $%s(...)" func_name);
          }
          :: List.map
               (fun arg_path ->
                 {
                   mutation_target = Value;
                   target_path = Some arg_path;
                   suggestion = ToValue (SUnknown "affects-rhs");
                   debug_info = Some (Printf.sprintf "From %s arg" func_name);
                 })
               arg_paths

(* Generate mutations based on comparison operator and RHS *)
let generate_mutations (target_path : field_path) (rhs_sym : sym_expr)
    (cmp_op : cmp_op) (rhs_exp : Il.exp) : sym_mutation list =
  match rhs_sym with
  | SConst v ->
      (* RHS is constant: suggest setting LHS to that value *)
      [
        {
          target_path = Some target_path;
          mutation_target = Value;
          suggestion = ToValue (SConst v);
          debug_info = None;
        };
      ]
  | SPath _ | SVar _ | SBinOp _ | SUnOp _ -> (
      (* RHS is symbolic: generate mutation based on operator *)
      match cmp_op with
      | Eq | Ne ->
          [
            {
              target_path = Some target_path;
              mutation_target = Value;
              suggestion = ToValue rhs_sym;
              debug_info = None;
            };
          ]
      | Lt | Le | Gt | Ge ->
          [
            {
              target_path = Some target_path;
              mutation_target = Value;
              suggestion = ToRelation (cmp_op, rhs_sym);
              debug_info = None;
            };
          ])
  | SUnknown reason ->
      [
        {
          target_path = Some target_path;
          mutation_target = Value;
          suggestion = Unresolved (Printf.sprintf "RHS: %s" reason);
          debug_info = Some (Il.Print.string_of_exp rhs_exp);
        };
      ]
  | SCall (func_name, args) ->
      (* Special handling for length expressions *)
      if func_name = "len" then
        (* Extract the collection path from len argument *)
        let collection_paths =
          List.concat_map extract_paths_from_sym_expr args
        in
        if collection_paths = [] then
          handle_function_call_rhs target_path func_name args rhs_exp
        else
          (* Mutating the collection affects its length *)
          List.map
            (fun coll_path ->
              {
                target_path = Some coll_path;
                mutation_target = CollectionLength;
                suggestion = ToValue (SUnknown "collection-length");
                debug_info = Some "Mutate collection to change length";
              })
            collection_paths
      else handle_function_call_rhs target_path func_name args rhs_exp
  | _ ->
      [
        {
          target_path = Some target_path;
          mutation_target = CollectionLength;
          suggestion =
            Unresolved
              (Printf.sprintf "RHS type: %s" (string_of_sym_expr rhs_sym));
          debug_info = None;
        };
      ]

(* Handle boolean field access (for if-premises that check boolean fields) *)
let handle_boolean_field (sym_env : sym_env) (exp : Il.exp) : sym_mutation list
    =
  let lhs_sym = resolve_to_sym_expr sym_env exp in
  let lhs_path =
    match lhs_sym with
    | SPath p -> Some p
    | _ -> (
        let paths = extract_paths_from_sym_expr lhs_sym in
        match paths with p :: _ -> Some p | [] -> None)
  in
  match lhs_path with
  | None ->
      [
        {
          target_path = None;
          mutation_target = Value;
          suggestion =
            Unresolved
              (Printf.sprintf "Boolean field LHS unresolved: %s"
                 (Il.Print.string_of_exp exp));
          debug_info = None;
        };
      ]
  | Some target_path ->
      (* For boolean fields, suggest setting to false (to make condition fail) *)
      [
        {
          target_path = Some target_path;
          mutation_target = Value;
          suggestion = ToValue (SConst (Il.Value.Make.bool Il.Typ.bool false));
          debug_info =
            Some
              (Printf.sprintf "Boolean field: %s" (Il.Print.string_of_exp exp));
        };
      ]

let extract_symbolic_mutations (sym_env : sym_env) (exp : Il.exp) :
    sym_mutation list =
  match exp.it with
  | Il.CmpE (op, _, lhs_exp, rhs_exp) -> (
      (* First try precise LHS resolution *)
      match resolve_comparison_lhs sym_env lhs_exp with
      | Some target_path ->
          (* Precise resolution succeeded *)
          let rhs_sym = resolve_comparison_rhs sym_env rhs_exp in
          let cmp_op = convert_cmpop op in
          generate_mutations target_path rhs_sym cmp_op rhs_exp
      | None -> (
          (* Precise failed - try over-approximation *)
          let overapprox_paths =
            resolve_comparison_lhs_overapprox sym_env lhs_exp
          in
          match overapprox_paths with
          | [] ->
              (* Over-approximation also failed *)
              [
                {
                  target_path = None;
                  mutation_target = Value;
                  suggestion =
                    Unresolved
                      (Printf.sprintf "LHS unresolved: %s"
                         (Il.Print.string_of_exp lhs_exp));
                  debug_info = Some (Il.Print.string_of_exp exp);
                };
              ]
          | paths ->
              (* Generate mutations for all over-approximated paths *)
              let rhs_sym = resolve_comparison_rhs sym_env rhs_exp in
              let cmp_op = convert_cmpop op in
              List.concat_map
                (fun target_path ->
                  generate_mutations target_path rhs_sym cmp_op rhs_exp)
                paths))
  | Il.DotE _ | Il.IdxE _ -> handle_boolean_field sym_env exp
  | Il.CallE (func_id, _, args) ->
      (* Verification functions: expand to argument paths *)
      let func_name = func_id.it in
      let arg_paths =
        List.concat_map
          (fun arg ->
            match arg.it with
            | Il.ExpA e ->
                let sym = resolve_to_sym_expr sym_env e in
                extract_paths_from_sym_expr sym
            | Il.DefA _ -> [])
          args
      in
      if arg_paths = [] then
        [
          {
            target_path = None;
            mutation_target = Value;
            suggestion =
              Unresolved
                (Printf.sprintf "Function %s with no resolvable args" func_name);
            debug_info = Some (Il.Print.string_of_exp exp);
          };
        ]
      else
        (* Generate mutation for each argument path *)
        List.map
          (fun path ->
            {
              target_path = Some path;
              mutation_target = Value;
              suggestion = ToValue (SUnknown "verification-related");
              debug_info = Some (Printf.sprintf "From %s arg" func_name);
            })
          arg_paths
  | Il.VarE id -> (
      (* Bare variable as boolean expression *)
      let lhs_sym = resolve_to_sym_expr sym_env exp in
      let paths = extract_paths_from_sym_expr lhs_sym in
      match paths with
      | [] ->
          [
            {
              target_path = None;
              mutation_target = Value;
              suggestion = Unresolved (Printf.sprintf "Bool var: %s" id.it);
              debug_info = None;
            };
          ]
      | _ ->
          List.map
            (fun path ->
              {
                target_path = Some path;
                mutation_target = Value;
                suggestion = ToValue (SUnknown "toggle-boolean");
                debug_info = Some (Printf.sprintf "Bool var: %s" id.it);
              })
            paths)
  | _ ->
      (* Not a comparison expression or handled boolean field *)
      [
        {
          target_path = None;
          mutation_target = Value;
          suggestion =
            Unresolved
              (Printf.sprintf "Not handled: %s" (Il.Print.string_of_exp exp));
          debug_info = None;
        };
      ]

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
end

(* Initialize the lookup_sym_ref to point to State.lookup_sym *)
let () = lookup_sym_ref := State.lookup_sym

(* Helper: Bind relation inputs based on static analysis results *)
let bind_relation_inputs
    (input_info : Instrumentation_static.Mutator_analysis.relation_input_info) :
    unit =
  let bind_state var =
    State.bind_sym var (SPath { source = State; steps = [] })
  in
  let bind_block var pattern =
    let path =
      match pattern with
      | Instrumentation_static.Mutator_analysis.Custom p ->
          convert_ma_field_path p
      | _ -> path_of_block_pattern pattern
    in
    State.bind_sym var (SPath path)
  in
  (* Iterate over inputs and bind based on type information *)
  List.iter2
    (fun var_name typ ->
      match typ.it with
      | Il.VarT ({ it = "beaconState"; _ }, _) -> bind_state var_name
      | Il.VarT ({ it = "signedBeaconBlock"; _ }, _) ->
          bind_block var_name Instrumentation_static.Mutator_analysis.FullBlock
      | Il.VarT ({ it = "beaconBlock"; _ }, _) ->
          bind_block var_name
            Instrumentation_static.Mutator_analysis.BlockMessage
      | Il.VarT ({ it = "beaconBlockBody"; _ }, _) ->
          bind_block var_name Instrumentation_static.Mutator_analysis.BlockBody
      | Il.VarT ({ it = "executionPayload"; _ }, _) ->
          bind_block var_name
            Instrumentation_static.Mutator_analysis.ExecutionPayload
      | Il.VarT ({ it = "syncAggregate"; _ }, _) ->
          bind_block var_name
            Instrumentation_static.Mutator_analysis.SyncAggregate
      | _ ->
          (* Fallback: heuristic based on variable name *)
          if is_state_var var_name then bind_state var_name else ())
    input_info.input_var_names input_info.input_types

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
  let on_test_end ~test_case_id:_ = State.current_test_id := ""

  let on_rel_enter ~id ~at:_ ~values:_ =
    State.current_relation := id;
    State.push_sym_frame ();
    (* Bind inputs using static analysis for ALL relations *)
    match
      Instrumentation_static.Mutator_analysis.get_relation_input_info id
    with
    | Some input_info -> bind_relation_inputs input_info
    | None ->
        (* Fallback for State_transition if static analysis didn't capture it *)
        if id = "State_transition" then
          match Hashtbl.find_opt State.relation_inputs id with
          | Some (state_var :: block_var :: _) ->
              State.bind_sym state_var (SPath { source = State; steps = [] });
              State.bind_sym block_var (SPath { source = Block; steps = [] })
          | _ -> ()
        else ()

  let on_rel_exit ~id:_ ~at:_ ~success =
    State.current_relation := "";
    State.current_rule := "";
    (* Pop the relation's frame instead of clearing everything *)
    if success then State.pop_sym_frame_success ()
    else State.pop_sym_frame_failure ()

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
            Hashtbl.replace State.sym_env id.it (SVar id.it))
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
