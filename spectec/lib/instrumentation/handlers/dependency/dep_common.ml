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
