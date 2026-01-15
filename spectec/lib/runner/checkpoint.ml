(* Configuration for checkpointing behavior *)
type config = {
  output_file : string option; (* File to save checkpoints to *)
  resume_from : string option; (* File to resume from, if any *)
  save_interval : int; (* Save checkpoint every N tests *)
}

let default_config =
  { output_file = None; resume_from = None; save_interval = 100 }

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

(* Compute MD5 hash of spec files for change detection *)
let compute_spec_hash spec_files =
  let contents =
    List.sort String.compare spec_files
    |> List.map (fun filename ->
           let input_channel = open_in filename in
           let length = in_channel_length input_channel in
           let content = really_input_string input_channel length in
           close_in input_channel;
           content)
    |> String.concat "\n"
  in
  Digest.string contents |> Digest.to_hex

(* Create a new checkpoint *)
let create ~spec_files ~completed_inputs ~coverage =
  {
    spec_hash = compute_spec_hash spec_files;
    completed_inputs;
    coverage;
    timestamp = Unix.gettimeofday ();
  }

(* Save checkpoint to file using Marshal *)
let save ~file checkpoint =
  let output_channel = open_out_bin file in
  Marshal.to_channel output_channel checkpoint [];
  close_out output_channel

(* Load checkpoint from file *)
let load ~file =
  let input_channel = open_in_bin file in
  let checkpoint : t = Marshal.from_channel input_channel in
  close_in input_channel;
  checkpoint

(* Verify that spec files haven't changed *)
let verify_spec checkpoint ~spec_files =
  let current_hash = compute_spec_hash spec_files in
  if checkpoint.spec_hash = current_hash then Ok ()
  else Error (Error.SpecMismatchError (checkpoint.spec_hash, current_hash))

(* Filter out already-completed inputs *)
let filter_remaining checkpoint inputs ~get_id =
  List.filter
    (fun input -> not (List.mem (get_id input) checkpoint.completed_inputs))
    inputs

(* Human-readable summary of checkpoint *)
let summary checkpoint =
  Printf.sprintf "Checkpoint: %d tests completed, saved at %s"
    (List.length checkpoint.completed_inputs)
    ( Unix.gmtime checkpoint.timestamp |> fun time_record ->
      Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d UTC"
        (time_record.tm_year + 1900)
        (time_record.tm_mon + 1) time_record.tm_mday time_record.tm_hour
        time_record.tm_min time_record.tm_sec )

(* Load and verify checkpoint from file.
   Returns Some checkpoint if valid, None if invalid or file doesn't exist. *)
let verify_and_load ~file ~spec_files ~verbose =
  try
    let checkpoint = load ~file in
    match verify_spec checkpoint ~spec_files with
    | Ok () ->
        if verbose then
          Format.printf "Resuming from checkpoint: %s\n" (summary checkpoint);
        Some checkpoint
    | Error e ->
        Format.printf "%s\n" (Error.string_of_error e);
        None
  with _ -> None

(* Restore coverage state from checkpoint.
   This should be called after instrumentation handlers are initialized
   but before running any tests. *)
let restore_coverage checkpoint =
  (match checkpoint.coverage.branch with
  | Some branch_result -> Instrumentation.Branch_coverage.restore branch_result
  | None -> ());
  (match checkpoint.coverage.node_il with
  | Some node_result -> Instrumentation.Node_coverage_il.restore node_result
  | None -> ());
  (match checkpoint.coverage.node_sl with
  | Some node_result -> Instrumentation.Node_coverage_sl.restore node_result
  | None -> ());
  match checkpoint.coverage.dependency with
  | Some dep_result -> Instrumentation.Dependency.Positive.restore dep_result
  | None -> ()

(* Collect current coverage state from all instrumentation handlers *)
let get_current_coverage () =
  {
    branch = Some (Instrumentation.Branch_coverage.get_result ());
    node_il = Some (Instrumentation.Node_coverage_il.get_result ());
    node_sl = Some (Instrumentation.Node_coverage_sl.get_result ());
    dependency = Some (Instrumentation.Dependency.Positive.get_result ());
    path_condition = Some (Instrumentation.Dependency.Negative.get_result ());
  }

(* Save current checkpoint state to file.
   Collects current coverage state and completed inputs, then saves to file if configured. *)
let save_current ~spec_files ~completed_inputs ~output_file =
  match output_file with
  | Some file ->
      let checkpoint =
        create ~spec_files ~completed_inputs ~coverage:(get_current_coverage ())
      in
      save ~file checkpoint
  | None -> ()

(* Display full checkpoint report with coverage data.
   Uses provided config for output destinations, or defaults to Full/stdout. *)
let display_report ~spec ~(config : Instrumentation.Config.t) checkpoint =
  Format.printf "=== Checkpoint Contents ===\n\n";
  Format.printf "%s\n\n" (summary checkpoint);
  Format.printf "Completed tests: %d\n\n"
    (List.length checkpoint.completed_inputs);
  (* Use provided config if present, else default to Full/stdout *)
  let branch_cfg =
    match config.branch_coverage with
    | Some cfg -> cfg
    | None -> Instrumentation.Branch_coverage.default_config
  in
  let node_il_cfg =
    match config.node_coverage with
    | Some cfg -> cfg
    | None -> Instrumentation.Node_coverage_il.default_config
  in
  let dep_cfg =
    match config.dependency with
    | Some cfg -> cfg
    | None -> Instrumentation.Dependency.Positive.default_config
  in
  (* Create handlers with configured outputs *)
  let handlers =
    [
      Instrumentation.Branch_coverage.make branch_cfg;
      Instrumentation.Node_coverage_il.make node_il_cfg;
      Instrumentation.Node_coverage_sl.make node_il_cfg;
      Instrumentation.Dependency.Positive.make dep_cfg;
    ]
  in
  (* Initialize Static analysis *)
  Instrumentation_static.Static.reset_all ();
  Instrumentation_static.Static.init_all
    (Instrumentation_static.Static.IlSpec spec);
  Instrumentation.Dispatcher.set_handlers handlers;
  Instrumentation.Dispatcher.init ~spec:(Instrumentation.Handler.IlSpec spec);
  (* Restore state from checkpoint data *)
  restore_coverage checkpoint;
  (* Call finish to print the reports *)
  Instrumentation.Dispatcher.finish ();
  Instrumentation.Config.close_outputs config
