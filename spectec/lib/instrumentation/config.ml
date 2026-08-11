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
module Output = Instrumentation_core.Output

(* Shared level type for node coverage and field deps *)
type level = Summary | Full

type t = {
  trace : Trace.config option;
  profile : Profile.config option;
  branch_coverage : Branch_coverage.config option;
  node_coverage : Node_coverage_il.config option;
  dep_pos : Positive.config option;
}

let default =
  {
    trace = None;
    profile = None;
    branch_coverage = None;
    node_coverage = None;
    dep_pos = None;
  }

(* Stable description of the instrumentation settings that affect which data
   is collected. Output destinations are deliberately excluded: changing a
   report filename must not invalidate an otherwise compatible checkpoint. *)
let semantic_fingerprint config =
  let trace =
    match config.trace with
    | None -> "off"
    | Some cfg -> (
        match cfg.Trace.level with
        | Trace.Summary -> "summary"
        | Trace.Full -> "full")
  in
  let branch_coverage =
    match config.branch_coverage with
    | None -> "off"
    | Some cfg -> (
        match cfg.Branch_coverage.level with
        | Branch_coverage.Summary -> "summary"
        | Branch_coverage.Full -> "full")
  in
  let node_coverage =
    match config.node_coverage with
    | None -> "off"
    | Some cfg ->
        let level =
          match cfg.Node_coverage_il.level with
          | Node_coverage_il.Summary -> "summary"
          | Node_coverage_il.Full -> "full"
        in
        Printf.sprintf "%s:track-seeds=%b" level cfg.track_seeds
  in
  let dep_pos =
    match config.dep_pos with
    | None -> "off"
    | Some cfg ->
        let level =
          match cfg.Positive.level with
          | Positive.Summary -> "summary"
          | Positive.Full -> "full"
        in
        let targets =
          match cfg.target_uids with
          | None -> "default"
          | Some uids ->
              uids |> List.sort_uniq Int.compare |> List.map string_of_int
              |> String.concat "," |> Printf.sprintf "explicit:%s"
        in
        Printf.sprintf "%s:targets=%s" level targets
  in
  Printf.sprintf "trace=%s,profile=%b,branch=%s,node=%s,dep-pos=%s" trace
    (Option.is_some config.profile) branch_coverage node_coverage dep_pos

(* Convert config to handler list *)
let to_handlers config =
  let handlers =
    (match config.trace with None -> [] | Some cfg -> [ Trace.make cfg ])
    @ (match config.profile with
      | None -> []
      | Some cfg -> [ Profile.make cfg ])
    @ (match config.branch_coverage with
      | None -> []
      | Some cfg -> [ Branch_coverage.make cfg ])
    @ (match config.node_coverage with
      | None -> []
      | Some cfg ->
          (* Both IL and SL handlers share the same config;
           they self-select based on spec type at init() *)
          [ Node_coverage_il.make cfg; Node_coverage_sl.make cfg ])
    @ match config.dep_pos with None -> [] | Some cfg -> [ Positive.make cfg ]
  in
  (* Auto-collect and register static dependencies from all active handlers *)
  List.iter
    (fun (module H : Instrumentation_core.Handler.S) ->
      List.iter
        (fun (module M : Instrumentation_static.Static.S) ->
          Instrumentation_static.Static.register (module M))
        H.static_dependencies)
    handlers;
  handlers

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
  Option.iter (fun c -> Output.close c.Positive.output) config.dep_pos
