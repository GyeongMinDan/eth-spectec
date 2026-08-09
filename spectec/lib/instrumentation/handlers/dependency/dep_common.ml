(* Common types and utilities for dependency analysis.

   Shared between positive (mutation suggestion) analysis and the runner
   (json_mutator, testgen).

   Key components:
   - input_source: Tracks which top-level input a path comes from (State/Block)
   - field_step: A single step in a path (field name or array index).
     Defined as a type equation with Il.json_step so provenance from JSON
     loading requires zero conversion in positive.ml.
   - field_path: Complete path to a mutable location.
   - eth_whitelist: Centralized list of relations to analyze.
*)

open Common.Source
module Il = Lang.Il

(* === Types === *)

type input_source = State | Block
type field_step = Il.json_step = FieldAccess of string | IndexAccess of int
type field_path = { source : input_source; steps : field_step list }

(* === Centralized Whitelist === *)

(* Relations to analyze - single source of truth for dependency handlers *)
let eth_whitelist =
  [
    (* Top-level *)
    "State_transition";
    (* Block Processing *)
    "ProcessBlockHeader";
    "ProcessWithdrawals";
    "ProcessExecutionPayload";
    "ProcessRandao";
    "ProcessEth1Data";
    "ProcessSyncAggregate";
    (* Operations *)
    "ProcessProposerSlashing";
    "ProcessAttesterSlashing";
    "ProcessAttestation";
    "ProcessDeposit";
    "ProcessVoluntaryExit";
    "ProcessBlsToExecutionChange";
    (* Slot *)
    "ProcessSlot";
    (* Epoch *)
    "ProcessJustificationAndFinalization";
    "ProcessInactivityUpdates";
    "ProcessRewardsAndPenalties";
    "ProcessRegistryUpdates";
    "ProcessSlashings";
    "ProcessEth1DataReset";
    "ProcessEffectiveBalanceUpdates";
    "ProcessSlashingsReset";
    "ProcessRandaoMixesReset";
    "ProcessHistoricalSummariesUpdate";
    "ProcessParticipationFlagUpdates";
    "ProcessSyncCommitteeUpdates";
  ]

let is_whitelisted (rel : string) : bool = List.mem rel eth_whitelist

(* === String Formatting === *)

let string_of_input_source = function State -> "STATE" | Block -> "BLOCK"

let string_of_field_step (step : field_step) : string =
  match step with
  | FieldAccess f -> "." ^ f
  | IndexAccess i -> "[" ^ string_of_int i ^ "]"

let string_of_field_path (path : field_path) : string =
  let base = string_of_input_source path.source in
  let steps_str = String.concat "" (List.map string_of_field_step path.steps) in
  base ^ steps_str

(* === Readsets: provenance rules for the spec's generic list helpers === *)

(* A filter's result depends on the fields its predicate reads on every
   element (a rejected element leaves no trace in the output); a fold's
   result depends on every element, not just the one it returns. Value-level
   data flow cannot carry either. The matched names are spec-level def ids;
   renaming them in the spec silently disables the rule. *)

module StringMap = Map.Make (String)

(* Field chains a predicate reads, per component of its element parameter *)
type readset = field_step list list array

let atom_field (atom : Il.atom) : string =
  Lang.Xl.Atom.string_of_atom atom.it |> String.lowercase_ascii

let rec collect_chains (exp : Il.exp) : (string * field_step list) list =
  match exp.it with
  | Il.DotE _ ->
      let rec peel (e : Il.exp) steps =
        match e.it with
        | Il.DotE (base, atom) ->
            peel base (FieldAccess (atom_field atom) :: steps)
        | Il.VarE id -> [ (id.it, steps) ]
        | _ -> []
      in
      peel exp []
  | _ -> Il.Traverse.fold_children_exp ( @ ) [] collect_chains exp

let rec collect_chains_prem (prem : Il.prem) : (string * field_step list) list =
  match prem.it with
  | Il.IfPr e | Il.DebugPr e -> collect_chains e
  | Il.LetPr (e1, e2) -> collect_chains e1 @ collect_chains e2
  | Il.IterPr (inner, _) -> collect_chains_prem inner
  | Il.RulePr _ | Il.ElsePr -> []

(* None for wildcard or non-variable components *)
let comp_vars (clause : Il.clause) : string option list =
  let params, _, _ = clause.it in
  match params with
  | { it = Il.ExpA { it = Il.VarE v; _ }; _ } :: _ -> [ Some v.it ]
  | { it = Il.ExpA { it = Il.TupleE comps; _ }; _ } :: _ ->
      List.map
        (fun (c : Il.exp) ->
          match c.it with Il.VarE v -> Some v.it | _ -> None)
        comps
  | _ -> []

let readset_of_clauses (clauses : Il.clause list) : readset =
  let width =
    List.fold_left (fun w c -> max w (List.length (comp_vars c))) 0 clauses
  in
  let arr = Array.make (max width 1) [] in
  List.iter
    (fun (clause : Il.clause) ->
      let _, body, prems = clause.it in
      let chains =
        collect_chains body @ List.concat_map collect_chains_prem prems
      in
      List.iteri
        (fun i comp ->
          Option.iter
            (fun v ->
              arr.(i) <-
                arr.(i)
                @ List.filter_map
                    (fun (var, steps) -> if var = v then Some steps else None)
                    chains)
            comp)
        (comp_vars clause))
    clauses;
  arr

let readsets_of_spec (spec : Il.spec) : readset StringMap.t =
  List.fold_left
    (fun acc (def : Il.def) ->
      match def.it with
      | Il.DecD (id, _, _, _, (_ :: _ as clauses)) ->
          StringMap.add id.it (readset_of_clauses clauses) acc
      | _ -> acc)
    StringMap.empty spec

(* Sub-values carry their own notes, stamped at load or construction, so
   reading the walked field's note never fabricates a path. A chain that
   does not walk, or reaches an unstamped field, falls back to the
   element's own note, unrefined. *)
let rec walk_chain (v : Il.Value.t) (chain : field_step list) :
    Il.Value.t option =
  match chain with
  | [] -> Some v
  | FieldAccess f :: rest -> (
      match v.it with
      | Il.StructV fields ->
          List.find_map
            (fun (atom, value_f) ->
              if atom_field atom = f then walk_chain value_f rest else None)
            fields
      | _ -> None)
  | IndexAccess _ :: _ -> None

let chain_provs (chains : field_step list list) (v : Il.Value.t) :
    Il.json_provenance list =
  if chains = [] then v.note.provenance
  else
    List.concat_map
      (fun chain ->
        match walk_chain v chain with
        | Some sub when sub.note.provenance <> [] -> sub.note.provenance
        | _ -> v.note.provenance)
      chains

let elem_provs (rs : readset) (elem : Il.Value.t) : Il.json_provenance list =
  match elem.it with
  | Il.TupleV comps ->
      List.concat
        (List.mapi
           (fun i (c : Il.Value.t) ->
             let chains = if i < Array.length rs then rs.(i) else [] in
             chain_provs chains c)
           comps)
  | _ ->
      let chains = if Array.length rs > 0 then rs.(0) else [] in
      chain_provs chains elem

(* [lookup] must also resolve locally bound predicate names: a recursive
   combinator passes its predicate parameter under the local binding, not
   the global def id. *)
let call_provenance ~(lookup : string -> readset option) (id : string)
    (values_input : Il.Value.t list) : Il.json_provenance list =
  match id with
  | "filter_list_" | "filter_list_2_" | "fold_" -> (
      let list_arg =
        List.find_opt
          (fun (v : Il.Value.t) ->
            match v.it with Il.ListV _ -> true | _ -> false)
          values_input
      in
      match list_arg with
      | Some ({ it = Il.ListV elems; _ } as lst) ->
          if id = "fold_" then
            lst.note.provenance
            @ List.concat_map (fun (e : Il.Value.t) -> e.note.provenance) elems
          else
            let rs =
              match
                List.find_map
                  (fun (v : Il.Value.t) ->
                    match v.it with Il.FuncV fid -> Some fid | _ -> None)
                  values_input
              with
              | Some fid -> Option.value ~default:[||] (lookup fid.it)
              | None -> [||]
            in
            lst.note.provenance @ List.concat_map (elem_provs rs) elems
      | _ -> [])
  | _ -> []
