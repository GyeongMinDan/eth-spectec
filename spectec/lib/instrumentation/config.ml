(* Instrumentation configuration.

   Consolidates all instrumentation options into a single record type.
   Use `to_handlers` to convert a config to the handler list for hooks. *)

(* Shared level type for node coverage *)
type node_coverage_level = Summary | Full

type t = {
  trace : Trace.level option;
  profile : bool;
  branch_coverage : Branch_coverage.level option;
  node_coverage : node_coverage_level option;
}

let default =
  {
    trace = None;
    profile = false;
    branch_coverage = None;
    node_coverage = None;
  }

(* Convert config to handler list *)
let to_handlers config =
  (match config.trace with
  | None -> []
  | Some level -> [ Trace.make ~level () ])
  @ (if config.profile then [ Profile.make () ] else [])
  @ (match config.branch_coverage with
    | None -> []
    | Some level -> [ Branch_coverage.make ~level () ])
  @
  match config.node_coverage with
  | None -> []
  | Some Summary ->
      [
        Node_coverage_il.make ~level:Summary ();
        Node_coverage_sl.make ~level:Summary ();
      ]
  | Some Full ->
      [
        Node_coverage_il.make ~level:Full ();
        Node_coverage_sl.make ~level:Full ();
      ]
