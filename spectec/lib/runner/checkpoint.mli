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
type coverage_state = {
  branch : Instrumentation.Branch_coverage.result option;
  node_il : Instrumentation.Node_coverage_il.result option;
  node_sl : Instrumentation.Node_coverage_sl.result option;
  dependency : Instrumentation.Dependency.Positive.result option;
  path_condition : Instrumentation.Dependency.Negative.result option;
}

(* Main checkpoint type - saved/loaded state *)
type t = {
  spec_hash : string; (* MD5 of concatenated spec file contents *)
  completed_inputs : string list; (* IDs of processed test cases *)
  coverage : coverage_state;
  timestamp : float; (* Unix timestamp *)
}

(* Load checkpoint from file *)
val load : file:string -> t

(* Verify that spec files haven't changed *)
val verify_spec : t -> spec_files:string list -> (unit, Error.t) result

(* Load and verify checkpoint from file.
   Returns Some checkpoint if valid, None if invalid or file doesn't exist. *)
val verify_and_load :
  file:string -> spec_files:string list -> verbose:bool -> t option

(* Filter out already-completed inputs *)
val filter_remaining : t -> 'a list -> get_id:('a -> string) -> 'a list

(* Save current checkpoint state to file.
   Collects current coverage state and completed inputs, then saves to file if configured. *)
val save_current :
  spec_files:string list ->
  completed_inputs:string list ->
  output_file:string option ->
  unit

(* Display full checkpoint report with coverage data.
   Uses provided config for output destinations, or defaults to Full/stdout. *)
val display_report :
  spec:Lang.Il.spec -> config:Instrumentation.Config.t -> t -> unit
