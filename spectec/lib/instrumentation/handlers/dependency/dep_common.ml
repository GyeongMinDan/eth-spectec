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

(* === Structured Field Path Types === *)

(* Index into a collection *)
type index_expr =
  | ConstInt of int (* [5] - concrete index *)
  | PathRef of field_path (* [state.slot] - dynamic index *)

(* A single step in a path *)
and field_step =
  | FieldAccess of string (* .validators *)
  | IndexAccess of index_expr (* [i] *)

(* Complete path to a mutable location *)
and field_path = { source : input_source; steps : field_step list }

(* === Mutation Suggestion Types === *)

(* Binary operations between field paths *)
type binop = Add | Sub | Mul | Div | Mod

(* Source environment: maps variable names to their field paths *)
type source_env = (string, field_path) Hashtbl.t

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

let bind_source (env : source_env) (var : string) (path : field_path) : unit =
  Hashtbl.replace env var path

let lookup_source (env : source_env) (var : string) : field_path option =
  Hashtbl.find_opt env var

let clear_env (env : source_env) : unit = Hashtbl.clear env
let copy_env (env : source_env) : source_env = Hashtbl.copy env

(* === Field Path Utilities === *)

let append_step (path : field_path) (step : field_step) : field_path =
  { path with steps = path.steps @ [ step ] }

let field_path_of_source (source : input_source) : field_path =
  { source; steps = [] }

(* === String Formatting === *)

let string_of_input_source = function
  | State -> "state"
  | Block -> "block"
  | Unknown -> "?"

let rec string_of_index_expr (idx : index_expr) : string =
  match idx with
  | ConstInt i -> string_of_int i
  | PathRef path -> string_of_field_path path

and string_of_field_step (step : field_step) : string =
  match step with
  | FieldAccess f -> "." ^ f
  | IndexAccess idx -> "[" ^ string_of_index_expr idx ^ "]"

and string_of_field_path (path : field_path) : string =
  let base = string_of_input_source path.source in
  let steps_str = String.concat "" (List.map string_of_field_step path.steps) in
  base ^ steps_str

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
          if rules <> [] then
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
            bind_source env state_var { source = State; steps = [] };
            bind_source env block_var { source = Block; steps = [] }
        | _ -> ())
    | None -> ()
