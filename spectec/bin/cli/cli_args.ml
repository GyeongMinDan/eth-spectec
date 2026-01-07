(** Shared CLI argument parsers *)

open Instrumentation

(** Convert optional file path to Output destination *)
let output_of = function None -> Output.stdout | Some path -> Output.file path

(** Parse level from int option (1=Summary, 2=Full) *)
let parse_level ~summary ~full = function
  | Some 1 -> Some summary
  | Some 2 -> Some full
  | _ -> None

(** Build handler config from level option and output *)
let make_config ~level_opt ~output ~make_cfg =
  Option.map
    (fun lvl -> make_cfg ~level:lvl ~output:(output_of output))
    level_opt

(** Shared instrumentation config CLI flags *)
let config_flags =
  let open Core.Command.Let_syntax in
  let open Core.Command.Param in
  let%map trace_level =
    flag "--trace" (optional int) ~doc:"LEVEL trace: 1=summary, 2=full"
  and trace_output =
    flag "--trace-output" (optional string) ~doc:"FILE output file for trace"
  and profile = flag "--profile" no_arg ~doc:" enable profiling"
  and profile_output =
    flag "--profile-output" (optional string)
      ~doc:"FILE output file for profile"
  and branch_level =
    flag "--branch-coverage" (optional int) ~doc:"LEVEL 1=summary, 2=full"
  and branch_output =
    flag "--branch-output" (optional string) ~doc:"FILE output file for branch"
  and node_level =
    flag "--node-coverage" (optional int) ~doc:"LEVEL 1=summary, 2=full"
  and node_output =
    flag "--node-output" (optional string) ~doc:"FILE output file for node"
  in
  Config.
    {
      trace =
        make_config
          ~level_opt:
            (parse_level ~summary:Trace.Summary ~full:Trace.Full trace_level)
          ~output:trace_output ~make_cfg:(fun ~level ~output ->
            Trace.{ level; output });
      profile =
        (if profile then Some Profile.{ output = output_of profile_output }
         else None);
      branch_coverage =
        make_config
          ~level_opt:
            (parse_level ~summary:Branch_coverage.Summary
               ~full:Branch_coverage.Full branch_level) ~output:branch_output
          ~make_cfg:(fun ~level ~output -> Branch_coverage.{ level; output });
      node_coverage =
        make_config
          ~level_opt:
            (parse_level ~summary:Node_coverage_il.Summary
               ~full:Node_coverage_il.Full node_level) ~output:node_output
          ~make_cfg:(fun ~level ~output -> Node_coverage_il.{ level; output });
    }
