(* Common types and utilities for dependency analysis.

   Shared between positive (mutation suggestion) and negative (blacklist) analysis.

   Key components:
   - input_source: Tracks which top-level input a path comes from (State/Block)
   - field_access: Represents a path to a field in the input
   - source_env: Maps variable names to their field accesses
   - eth_whitelist: Centralized list of relations to analyze
*)

open Common.Source
module Il = Lang.Il

(* === Types === *)

(* Input source: tracks which top-level input a path comes from *)
type input_source = State | Block | Unknown

(* Field access - represents a path to a field in the input *)
type field_access = {
  source : input_source;
  fields : string list; (* e.g., ["SLOT"] for state.SLOT *)
}

(* Source environment: maps variable names to their field accesses *)
type source_env = (string, field_access) Hashtbl.t

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

(* === Source Environment === *)

let create_env () : source_env = Hashtbl.create 100

let bind_source (env : source_env) (var : string) (access : field_access) : unit
    =
  Hashtbl.replace env var access

let lookup_source (env : source_env) (var : string) : field_access option =
  Hashtbl.find_opt env var

let clear_env (env : source_env) : unit = Hashtbl.clear env
let copy_env (env : source_env) : source_env = Hashtbl.copy env

(* === Field Access Utilities === *)

let append_field (access : field_access) (field : string) : field_access =
  { access with fields = access.fields @ [ field ] }

(* === String Formatting === *)

let string_of_input_source = function
  | State -> "state"
  | Block -> "block"
  | Unknown -> "?"

let string_of_field_access (access : field_access) : string =
  match (access.source, access.fields) with
  | Unknown, [] -> "?"
  | Unknown, fields -> (
      (* For Unknown source with fields, check if first field is "state" or "block" *)
      match fields with
      | "state" :: rest -> "state" ^ "." ^ String.concat "." rest
      | "block" :: rest -> "block" ^ "." ^ String.concat "." rest
      | _ -> "?." ^ String.concat "." fields)
  | source, [] -> string_of_input_source source
  | source, fields ->
      string_of_input_source source ^ "." ^ String.concat "." fields

(* === Expression Analysis Helpers === *)

(* Strip outermost negation: ¬e -> e *)
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

(* === Relation Input Binding === *)

(* Extract input variable names from spec relations *)
let extract_relation_inputs (il_spec : Il.spec) :
    (string, string list) Hashtbl.t =
  let relation_inputs = Hashtbl.create 50 in
  List.iter
    (fun def ->
      match def.it with
      | Il.RelD (id, _, input_hints, rules) ->
          if id.it = "State_transition" && rules <> [] then
            (* Get input expressions from first rule's notexp *)
            let rule = List.hd rules in
            let _, notexp, _ = rule.it in
            let _, exps = notexp in
            (* Split expressions based on input_hints (indices) *)
            let exps_input =
              exps
              |> List.mapi (fun idx exp -> (idx, exp))
              |> List.filter (fun (idx, _) -> List.mem idx input_hints)
              |> List.map snd
            in
            (* Extract variable names from input expressions *)
            let input_vars =
              List.filter_map
                (fun exp ->
                  match exp.it with Il.VarE id -> Some id.it | _ -> None)
                exps_input
            in
            Hashtbl.replace relation_inputs id.it input_vars
      | _ -> ())
    il_spec;
  relation_inputs

(* Bind input variables for State_transition relation *)
let bind_state_transition_inputs (env : source_env)
    (relation_inputs : (string, string list) Hashtbl.t) (rel_id : string)
    (_values : Il.Value.t list) : unit =
  if rel_id = "State_transition" then
    match Hashtbl.find_opt relation_inputs rel_id with
    | Some input_vars -> (
        match input_vars with
        | state_var :: block_var :: _ ->
            bind_source env state_var { source = State; fields = [] };
            bind_source env block_var { source = Block; fields = [] }
        | _ -> ())
    | None -> ()
