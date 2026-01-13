open Common.Source
open Common.Domain
open Semantics.Dynamic
open Semantics.Dynamic_Il
open Semantics.Dynamic_Il.Envs
open Lang.Il
module Value = Lang.Il.Value
open Error
open Attempt

(* Custom hash table modules for global environments *)
(* These use string-based hashing/equality to match Map.Make behavior *)

module TIdHashtbl = Hashtbl.Make (struct
  type t = TId.t

  let equal id1 id2 = id1.it = id2.it (* Compare by string, ignore location *)
  let hash id = Hashtbl.hash id.it (* Hash by string content *)
end)

module RIdHashtbl = Hashtbl.Make (struct
  type t = RId.t

  let equal id1 id2 = id1.it = id2.it
  let hash id = Hashtbl.hash id.it
end)

module FIdHashtbl = Hashtbl.Make (struct
  type t = FId.t

  let equal id1 id2 = id1.it = id2.it
  let hash id = Hashtbl.hash id.it
end)

(* Error *)

let error_undef (at : region) (kind : string) (id : string) =
  error at (Format.asprintf "%s `%s` is undefined" kind id)

let error_dup (at : region) (kind : string) (id : string) =
  error at (Format.asprintf "%s `%s` was already defined" kind id)

(* Cursor *)

type cursor = Global | Local

(* Context *)

(* Global layer - now using mutable hashtables *)

type global = {
  (* Hashtable from syntax ids to type definitions *)
  tdenv : Typdef.t TIdHashtbl.t;
  (* Hashtable from relation ids to relations *)
  renv : Rel.t RIdHashtbl.t;
  (* Hashtable from function ids to functions *)
  fenv : Func.t FIdHashtbl.t;
}

(* Local layer *)

type local = {
  (* Map from syntax ids to type definitions *)
  tdenv : TDEnv.t;
  (* Map from function ids to functions *)
  fenv : FEnv.t;
  (* Map from variables to values *)
  venv : VEnv.t;
}

type t = {
  (* Filename of the source file *)
  filename : string;
  (* Global layer *)
  global : global;
  (* Local layer *)
  local : local;
}

(* Finders *)

(* Finders for values *)

let find_value_opt (cursor : cursor) (ctx : t) (var : Var.t) : Value.t option =
  match cursor with Global -> None | Local -> VEnv.find_opt var ctx.local.venv

let find_value (cursor : cursor) (ctx : t) (var : Var.t) : Value.t =
  match find_value_opt cursor ctx var with
  | Some value -> value
  | None ->
      let id, _ = var in
      error_undef id.at "value" (Var.to_string var)

let bound_value (cursor : cursor) (ctx : t) (var : Var.t) : bool =
  find_value_opt cursor ctx var |> Option.is_some

(* Finders for type definitions *)

let rec find_typdef_opt (cursor : cursor) (ctx : t) (tid : TId.t) :
    Typdef.t option =
  match cursor with
  | Global -> TIdHashtbl.find_opt ctx.global.tdenv tid
  | Local -> (
      match TDEnv.find_opt tid ctx.local.tdenv with
      | Some td -> Some td
      | None -> find_typdef_opt Global ctx tid)

let find_typdef (cursor : cursor) (ctx : t) (tid : TId.t) : Typdef.t =
  match find_typdef_opt cursor ctx tid with
  | Some td -> td
  | None -> error_undef tid.at "type" tid.it

let bound_typdef (cursor : cursor) (ctx : t) (tid : TId.t) : bool =
  match cursor with
  | Global -> TIdHashtbl.mem ctx.global.tdenv tid
  | Local -> (
      match TDEnv.find_opt tid ctx.local.tdenv with
      | Some _ -> true
      | None -> TIdHashtbl.mem ctx.global.tdenv tid)

(* Finders for rules *)

let find_rel_opt (_cursor : cursor) (ctx : t) (rid : RId.t) : Rel.t option =
  RIdHashtbl.find_opt ctx.global.renv rid

let find_rel (cursor : cursor) (ctx : t) (rid : RId.t) : Rel.t =
  match find_rel_opt cursor ctx rid with
  | Some rel -> rel
  | None -> error_undef rid.at "relation" rid.it

let bound_rel (_cursor : cursor) (ctx : t) (rid : RId.t) : bool =
  RIdHashtbl.mem ctx.global.renv rid

(* Finders for definitions *)

let rec find_func_opt (cursor : cursor) (ctx : t) (fid : FId.t) : Func.t option
    =
  match cursor with
  | Global -> FIdHashtbl.find_opt ctx.global.fenv fid
  | Local -> (
      match FEnv.find_opt fid ctx.local.fenv with
      | Some func -> Some func
      | None -> find_func_opt Global ctx fid)

let find_func (cursor : cursor) (ctx : t) (fid : FId.t) : Func.t =
  match find_func_opt cursor ctx fid with
  | Some func -> func
  | None -> error_undef fid.at "function" fid.it

let bound_func (cursor : cursor) (ctx : t) (fid : FId.t) : bool =
  match cursor with
  | Global -> FIdHashtbl.mem ctx.global.fenv fid
  | Local -> (
      match FEnv.find_opt fid ctx.local.fenv with
      | Some _ -> true
      | None -> FIdHashtbl.mem ctx.global.fenv fid)

(* Adders *)

(* Adders for values *)

let add_value ?(shadow = false) (cursor : cursor) (ctx : t) (var : Var.t)
    (value : Value.t) : t =
  (if cursor = Global then
     let id, _ = var in
     error id.at "cannot add value to global context");
  (if (not shadow) && VEnv.mem var ctx.local.venv then
     let id, _ = var in
     error_dup id.at "value" (Var.to_string var));
  let venv = VEnv.add var value ctx.local.venv in
  if venv == ctx.local.venv then ctx
  else { ctx with local = { ctx.local with venv } }

(* Batch add multiple values efficiently *)
let add_values ?(shadow = false) (cursor : cursor) (ctx : t)
    (bindings : (Var.t * Value.t) list) : t =
  (if cursor = Global && bindings <> [] then
     let id, _ = fst (List.hd bindings) in
     error id.at "cannot add value to global context");
  (* Check for duplicates if not shadowing *)
  if not shadow then
    List.iter
      (fun (var, _) ->
        if bound_value cursor ctx var then
          let id, _ = var in
          error_dup id.at "value" (Var.to_string var))
      bindings;
  (* Build venv in one pass *)
  let venv =
    List.fold_left
      (fun venv (var, value) -> VEnv.add var value venv)
      ctx.local.venv bindings
  in
  (* Optimize: avoid creating new context if venv unchanged *)
  if venv == ctx.local.venv then ctx
  else { ctx with local = { ctx.local with venv } }

(* Adders for type definitions *)

let add_typdef (cursor : cursor) (ctx : t) (tid : TId.t) (td : Typdef.t) : t =
  match cursor with
  | Global ->
      if TIdHashtbl.mem ctx.global.tdenv tid then error_dup tid.at "type" tid.it;
      TIdHashtbl.add ctx.global.tdenv tid td;
      ctx (* No copy needed - mutation in place *)
  | Local ->
      if bound_typdef cursor ctx tid then error_dup tid.at "type" tid.it;
      let tdenv = TDEnv.add tid td ctx.local.tdenv in
      { ctx with local = { ctx.local with tdenv } }

(* Batch add multiple type definitions efficiently *)
let add_typdefs (cursor : cursor) (ctx : t) (bindings : (TId.t * Typdef.t) list)
    : t =
  match cursor with
  | Global ->
      (* Check for duplicates first *)
      List.iter
        (fun (tid, _) ->
          if TIdHashtbl.mem ctx.global.tdenv tid then
            error_dup tid.at "type" tid.it)
        bindings;
      (* Add all at once - mutation in place *)
      List.iter
        (fun (tid, td) -> TIdHashtbl.add ctx.global.tdenv tid td)
        bindings;
      ctx (* No copy needed *)
  | Local ->
      (* Check for duplicates *)
      List.iter
        (fun (tid, _) ->
          if bound_typdef cursor ctx tid then error_dup tid.at "type" tid.it)
        bindings;
      let tdenv =
        List.fold_left
          (fun tdenv (tid, td) -> TDEnv.add tid td tdenv)
          ctx.local.tdenv bindings
      in
      { ctx with local = { ctx.local with tdenv } }

(* Adders for relations *)

let add_rel (cursor : cursor) (ctx : t) (rid : RId.t) (rel : Rel.t) : t =
  if cursor = Local then error rid.at "cannot add relation to local context";
  if RIdHashtbl.mem ctx.global.renv rid then error_dup rid.at "relation" rid.it;
  RIdHashtbl.add ctx.global.renv rid rel;
  ctx (* No copy needed - mutation in place *)

(* Adders for functions *)

let add_func (cursor : cursor) (ctx : t) (fid : FId.t) (func : Func.t) : t =
  match cursor with
  | Global ->
      if FIdHashtbl.mem ctx.global.fenv fid then
        error_dup fid.at "function" fid.it;
      FIdHashtbl.add ctx.global.fenv fid func;
      ctx (* No copy needed - mutation in place *)
  | Local ->
      if bound_func cursor ctx fid then error_dup fid.at "function" fid.it;
      let fenv = FEnv.add fid func ctx.local.fenv in
      { ctx with local = { ctx.local with fenv } }

(* Constructors *)

(* Constructing an empty context *)

(* Cache empty environments to avoid recreating them *)
let empty_global () : global =
  {
    tdenv = TIdHashtbl.create 64;
    renv = RIdHashtbl.create 64;
    fenv = FIdHashtbl.create 64;
  }

let empty_local_cached : local =
  { tdenv = TDEnv.empty; fenv = FEnv.empty; venv = VEnv.empty }

let empty_local () : local = empty_local_cached

let empty (filename : string) : t =
  let global = empty_global () in
  let local = empty_local () in
  { filename; global; local }

(* Helper: Convert global tdenv Hashtbl to Map for external interfaces *)
let tdenv_to_map (ctx : t) : TDEnv.t =
  TIdHashtbl.fold
    (fun tid td acc -> TDEnv.add tid td acc)
    ctx.global.tdenv TDEnv.empty

(* Constructing a local context *)
let localize (ctx : t) : t = { ctx with local = empty_local () }

(* Constructing sub-contexts *)

let sub_opt (ctx : t) (vars : var list) : t option attempt =
  (* First collect the values that are to be iterated over *)
  let values =
    List.map
      (fun (id, _typ, iters) ->
        find_value Local ctx (id, iters @ [ Opt ]) |> Value.get_opt)
      vars
  in
  (* Iteration is valid when all variables agree on their optionality *)
  if List.for_all Option.is_some values then
    let values = List.map Option.get values in
    (* Build venv in one pass to avoid intermediate context creations *)
    let venv_sub =
      List.fold_left2
        (fun venv (id, _typ, iters) value -> VEnv.add (id, iters) value venv)
        ctx.local.venv vars values
    in
    let ctx_sub = { ctx with local = { ctx.local with venv = venv_sub } } in
    Ok (Some ctx_sub)
  else if List.for_all Option.is_none values then Ok None
  else fail no_region "mismatch in optionality of iterated variables"

(* Transpose a matrix of values, as a list of value batches
   that are to be each fed into an iterated expression *)

let transpose (value_matrix : value list list) : value list list attempt =
  match value_matrix with
  | [] -> Ok []
  | row :: rows ->
      let width = List.length row in
      let* _ =
        guard
          (List.for_all
             (fun value_row -> List.length value_row = width)
             value_matrix)
          no_region "cannot transpose a matrix of value batches"
      in
      let columns_init = List.map (fun elem -> [ elem ]) row in
      let columns_rev =
        List.fold_left
          (fun columns_rev row ->
            List.map2
              (fun column_rev elem -> elem :: column_rev)
              columns_rev row)
          columns_init rows
      in
      Ok (List.map List.rev columns_rev)

let sub_list (ctx : t) (vars : var list) : t list attempt =
  (* First break the values that are to be iterated over,
     into a batch of values *)
  let* values_batch =
    List.map
      (fun (id, _typ, iters) ->
        find_value Local ctx (id, iters @ [ List ]) |> Value.get_list)
      vars
    |> transpose
  in
  (* For each batch of values, create a sub-context *)
  (* Build venv in one pass per batch to avoid intermediate context creations *)
  let ctxs_sub =
    List.fold_left
      (fun ctxs_sub_rev value_batch ->
        let venv_sub =
          List.fold_left2
            (fun venv (id, _typ, iters) value ->
              VEnv.add (id, iters) value venv)
            ctx.local.venv vars value_batch
        in
        let ctx_sub = { ctx with local = { ctx.local with venv = venv_sub } } in
        ctx_sub :: ctxs_sub_rev)
      [] values_batch
    |> List.rev
  in
  Ok ctxs_sub
