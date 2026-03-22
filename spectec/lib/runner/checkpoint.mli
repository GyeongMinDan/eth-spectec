(* Checkpoint module for coverage run persistence.

   Enables long-running coverage runs to be interrupted and resumed.
   Saves accumulated coverage state and list of completed test inputs. *)

(* Configuration for checkpointing behavior *)
type config = {
  output_file : string option; (* File to save checkpoints to *)
  resume_from : string option; (* File to resume from, if any *)
  save_interval : int; (* Save checkpoint every N tests *)
}

val default_config : config

(* Coverage state from handlers - extensible for new handlers *)
type coverage = {
  branch : Instrumentation.Branch_coverage.result option;
  node_il : Instrumentation.Node_coverage_il.result option;
  node_sl : Instrumentation.Node_coverage_sl.result option;
  dependency : Instrumentation.Dependency.Positive.result option;
  testgen : Testgen_data.t option;
}

(* Main checkpoint type - saved/loaded state *)
type t = {
  spec_hash : string; (* MD5 of concatenated spec file contents *)
  completed_inputs : string list; (* IDs of processed test cases *)
  coverage : coverage;
  timestamp : float; (* Unix timestamp *)
}

(* Load checkpoint from file using Marshal.
   Returns Ok checkpoint if successful, Error if file cannot be loaded. *)
val load_from_file : file:string -> (t, Error.t) result

(* Save checkpoint to file using Marshal *)
val save_to_file : file:string -> t -> unit

(* Load and verify checkpoint from file *)
val verify_and_load :
  file:string ->
  spec_files:string list ->
  verbose:bool ->
  ?ignore_spec_mismatch:bool ->
  unit ->
  (t, Error.t) result

(* Filter out already-completed inputs *)
val filter_remaining : t -> 'a list -> get_id:('a -> string) -> 'a list

(* Restores coverage state *)
val restore_coverage : t -> unit

(* Save current checkpoint state to file.
   Collects current coverage state and completed inputs, then saves to file if configured. *)
val save :
  spec_files:string list ->
  completed_inputs:string list ->
  output_file:string option ->
  unit

(* Display full checkpoint report with coverage data.
   Uses provided config for output destinations, or defaults to Full/stdout. *)
val display_report :
  spec:Lang.Il.spec -> config:Instrumentation.Config.t -> t -> unit

(* Merge two checkpoints into a new checkpoint.
   Merges completed_inputs (union) and coverage data.
   Returns Error if spec hashes don't match (unless ignore_spec_mismatch is true).
   For now, only merges IL node coverage data. Other coverage types are TODO. *)
val merge : ?ignore_spec_mismatch:bool -> t -> t -> (t, Error.t) result
