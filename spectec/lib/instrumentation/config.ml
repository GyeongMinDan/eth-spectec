(* Instrumentation configuration.

   Consolidates all instrumentation options into a single record type.
   Each handler has its own config type with level (if applicable) and output.
   Use `to_handlers` to convert a config to the handler list for dispatcher. *)

module Trace = Instrumentation_handlers.Trace
module Profile = Instrumentation_handlers.Profile
module Branch_coverage = Instrumentation_handlers.Branch_coverage
module Node_coverage_il = Instrumentation_handlers.Node_coverage_il
module Node_coverage_sl = Instrumentation_handlers.Node_coverage_sl
module Positive = Instrumentation_dependency.Positive
module Negative = Instrumentation_dependency.Negative
module Output = Instrumentation_core.Output

(* Shared level type for node coverage and field deps *)
type level = Summary | Full

type t = {
  trace : Trace.config option;
  profile : Profile.config option;
  branch_coverage : Branch_coverage.config option;
  node_coverage : Node_coverage_il.config option;
  dep_pos : Positive.config option;
  dep_neg : Negative.config option;
}

let default =
  {
    trace = None;
    profile = None;
    branch_coverage = None;
    node_coverage = None;
    dep_pos = None;
    dep_neg = None;
  }

(* TODO: generalize *)
let register_static_dependencies config =
  let deps =
    match config.node_coverage with
    | None -> []
    | Some _ -> Node_coverage_il.static_dependencies ()
  in
  (* Register all dependencies (idempotent register() handles deduplication) *)
  List.iter
    (fun (module M : Instrumentation_static.Static.S) ->
      Instrumentation_static.Static.register (module M))
    deps

(* Convert config to handler list *)
let to_handlers config =
  (* First, register all static analysis dependencies *)
  register_static_dependencies config;
  (* Then create handlers (they no longer need to register dependencies themselves) *)
  (match config.trace with None -> [] | Some cfg -> [ Trace.make cfg ])
  @ (match config.profile with None -> [] | Some cfg -> [ Profile.make cfg ])
  @ (match config.branch_coverage with
    | None -> []
    | Some cfg -> [ Branch_coverage.make cfg ])
  @ (match config.node_coverage with
    | None -> []
    | Some cfg ->
        (* Both IL and SL handlers share the same config;
          they self-select based on spec type at init() *)
        [ Node_coverage_il.make cfg; Node_coverage_sl.make cfg ])
  @ (match config.dep_pos with None -> [] | Some cfg -> [ Positive.make cfg ])
  @ match config.dep_neg with None -> [] | Some cfg -> [ Negative.make cfg ]

(* Close all output destinations after finish() *)
let close_outputs config =
  Option.iter (fun c -> Output.close c.Trace.output) config.trace;
  Option.iter (fun c -> Output.close c.Profile.output) config.profile;
  Option.iter
    (fun c -> Output.close c.Branch_coverage.output)
    config.branch_coverage;
  Option.iter
    (fun c -> Output.close c.Node_coverage_il.output)
    config.node_coverage;
  Option.iter (fun c -> Output.close c.Positive.output) config.dep_pos;
  Option.iter (fun c -> Output.close c.Negative.output) config.dep_neg
