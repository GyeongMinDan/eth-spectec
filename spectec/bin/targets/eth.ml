(** Ethereum CLI command - Extends Targets_eth with CLI flags *)
open Targets_eth.Eth

(** CLI_TASK for Ethereum state transition *)
module Cli_task : Cli.Command.CLI_TASK with type input = StateTransition.input =
struct
  include StateTransition

  let cli_flags =
    let open Core.Command.Let_syntax in
    let open Core.Command.Param in
    let%map pre = flag "--pre" (required string) ~doc:"FILE pre-state JSON"
    and block = flag "--block" (required string) ~doc:"FILE block JSON" in
    make ~pre_file:pre ~block_file:block ()
end

(** Ethereum command *)
let command =
  Cli.Command.make ~summary:"Run Ethereum state transition" (module Cli_task)
