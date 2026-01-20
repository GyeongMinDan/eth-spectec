(** Shared CLI argument parsers *)

open Instrumentation

(** Convert optional file path to Output destination *)
let output_of = function None -> Output.stdout | Some path -> Output.file path

(** Parse named level (summary|full) *)
let parse_named_level ~summary ~full = function
  | Some "summary" -> Some summary
  | Some "full" -> Some full
  | Some other ->
      failwith ("Invalid level: " ^ other ^ " (expected: summary|full)")
  | None -> None

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
    flag "--trace.level" (optional string) ~doc:"LEVEL summary|full"
  and trace_output =
    flag "--trace.output" (optional string) ~doc:"FILE output file for trace"
  and profile_output =
    flag "--profile.output" (optional string)
      ~doc:"FILE output file for profile"
  and branch_level =
    flag "--branch-coverage.level" (optional string) ~doc:"LEVEL summary|full"
  and branch_output =
    flag "--branch-coverage.output" (optional string) ~doc:"FILE output file"
  and node_level =
    flag "--node-coverage.level" (optional string) ~doc:"LEVEL summary|full"
  and node_output =
    flag "--node-coverage.output" (optional string) ~doc:"FILE output file"
  and dep_pos_level =
    flag "--dep-pos.level" (optional string) ~doc:"LEVEL summary|full"
  and dep_pos_output =
    flag "--dep-pos.output" (optional string) ~doc:"FILE output file"
  and dep_neg_level =
    flag "--dep-neg.level" (optional string) ~doc:"LEVEL summary|full"
  and dep_neg_output =
    flag "--dep-neg.output" (optional string) ~doc:"FILE output file"
  in
  Config.
    {
      trace =
        make_config
          ~level_opt:
            (parse_named_level ~summary:Trace.Summary ~full:Trace.Full
               trace_level) ~output:trace_output
          ~make_cfg:(fun ~level ~output -> Trace.{ level; output });
      profile =
        (if Option.is_some profile_output then
           Some Profile.{ output = output_of profile_output }
         else None);
      branch_coverage =
        make_config
          ~level_opt:
            (parse_named_level ~summary:Branch_coverage.Summary
               ~full:Branch_coverage.Full branch_level) ~output:branch_output
          ~make_cfg:(fun ~level ~output -> Branch_coverage.{ level; output });
      node_coverage =
        make_config
          ~level_opt:
            (parse_named_level ~summary:Node_coverage_il.Summary
               ~full:Node_coverage_il.Full node_level) ~output:node_output
          ~make_cfg:(fun ~level ~output -> Node_coverage_il.{ level; output });
      dep_pos =
        make_config
          ~level_opt:
            (parse_named_level ~summary:Positive.Summary ~full:Positive.Full
               dep_pos_level) ~output:dep_pos_output
          ~make_cfg:(fun ~level ~output ->
            Positive.{ level; output; target_uids = None });
      dep_neg =
        make_config
          ~level_opt:
            (parse_named_level ~summary:Negative.Summary ~full:Negative.Full
               dep_neg_level) ~output:dep_neg_output
          ~make_cfg:(fun ~level ~output -> Negative.{ level; output });
    }
