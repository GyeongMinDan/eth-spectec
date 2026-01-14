(** CLI command generator for input specs and target specs *)

(** Extended input spec with CLI argument parsing support *)
module type CLI_TASK = sig
  include Runner.Task.S

  (** Command-line argument parser that produces an input value *)
  val cli_flags : input Core.Command.Param.t
end

(* Collect spec files from a directory - I/O utility *)
let collect_spec_files spec_dir =
  Sys.readdir spec_dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".spectec")
  |> List.sort String.compare
  |> List.map (Filename.concat spec_dir)

(* Print outcome for a single test *)
let print_outcome (type i) (module T : Runner.Task.S with type input = i) source
    outcome =
  let open Runner in
  match outcome with
  | Task.Pass values ->
      Format.printf "Passed: %s\n  %s\n\n" source (T.format_output values)
  | Task.ExpectedFail err ->
      Format.printf "Expected fail (passed): %s\n  %s\n\n" source
        (Error.string_of_error err)
  | Task.Fail err ->
      Format.printf "Failed: %s\n  %s\n\n" source (Error.string_of_error err)
  | Task.UnexpectedPass values ->
      Format.printf "Unexpected pass (failed): %s\n  %s\n\n" source
        (T.format_output values)

(* Run interpreter on a single input and print result *)
let run_single (type i) (module T : Runner.Task.S with type input = i) ~config
    ~sl_mode ~spec_il (input : i) =
  let outcome =
    Runner.run_with_outcome (module T) ~config ~sl_mode ~spec_il input
  in
  print_outcome (module T) (T.source input) outcome

(* Run interpreter on a suite of inputs and print results *)
let run_suite (type i) (module T : Runner.Task.S with type input = i) ~config
    ~sl_mode ~spec_il ~verbose (inputs : i list) =
  let results =
    Runner.run_suite_with_outcomes
      (module T)
      ~config ~sl_mode ~spec_il ~verbose inputs
  in
  match verbose with
  | true ->
      (* Summary only in verbose mode, as progress was printed *)
      let summary = Runner.summarize_outcomes results in
      let passed = Runner.summary_passed summary in
      let failed = Runner.summary_failed summary in
      Format.printf "\nTest Results: %d/%d passed, %d failed\n" passed
        summary.total failed
  | false ->
      (* Full report at end if not verbose *)
      List.iter
        (fun Runner.{ source; outcome; _ } ->
          Format.printf ">>> Running %s on %s\n" T.name source;
          print_outcome (module T) source outcome)
        results;
      let summary = Runner.summarize_outcomes results in
      let passed = Runner.summary_passed summary in
      let failed = Runner.summary_failed summary in
      Format.printf "\nTest Results: %d/%d passed, %d failed\n" passed
        summary.total failed

(* Generate a CLI command for any CLI_TASK *)
let make (type i) ~summary (module T : CLI_TASK with type input = i) =
  Core.Command.basic ~summary
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames_spec =
       flag "--spec" (listed string)
         ~doc:"FILES spec files (default: use target spec dir)"
     and sl_mode = flag "--sl" no_arg ~doc:" use SL interpreter (default: IL)"
     and verbose = flag "-v" no_arg ~doc:" verbose output"
     and suite_mode =
       flag "--suite" no_arg ~doc:" run on test suite (default dir)"
     and suite_dir_arg =
       flag "--suite-dir" (optional string) ~doc:"DIR run on test suite in DIR"
     and input = T.cli_flags
     and config = Cli_args.config_flags in
     fun () ->
       let open Runner in
       let run () =
         let filenames_spec =
           match filenames_spec with
           | [] -> collect_spec_files T.Target.spec_dir
           | files -> files
         in
         let* spec = parse_spec_files filenames_spec in
         let* spec_il = elaborate spec in
         match (suite_mode, suite_dir_arg) with
         | false, None ->
             run_single (module T) ~config ~sl_mode ~spec_il input;
             Ok ()
         | true, None ->
             (* Use task defaults *)
             run_suite
               (module T)
               ~config ~sl_mode ~spec_il ~verbose (T.collect ());
             Ok ()
         | _, Some dir ->
             (* Use explicit directory *)
             run_suite
               (module T)
               ~config ~sl_mode ~spec_il ~verbose (T.collect ~dir ());
             Ok ()
       in
       match run () with
       | Ok () -> ()
       | Error e ->
           Format.printf "Error:\n  %s\n" (Runner.Error.string_of_error e))

(* Functor to generate commands for a specific target.
   Enforces that only tasks belonging to this target can be used. *)
module Make (Tgt : Runner.Target.S) = struct
  (* Task signature restricted to this target *)
  module type TARGET_TASK = Runner.Task.S with module Target = Tgt

  (* Packed task restricted to this target *)
  type packed_task =
    | Pack : (module TARGET_TASK with type input = 'a) -> packed_task

  (* Convert to generic packed task for Runner *)
  let to_generic (Pack (module T)) = Runner.Task.Pack (module T)

  (* Generate "coverage" command *)
  let make_coverage (tasks : packed_task list) =
    Core.Command.basic
      ~summary:("Run coverage for all " ^ Tgt.name ^ " input specs")
      (let open Core.Command.Let_syntax in
       let open Core.Command.Param in
       let%map sl_mode =
         flag "--sl" no_arg ~doc:" use SL interpreter (default: IL)"
       and verbose =
         flag "-v" no_arg ~doc:" verbose: print progress for each test"
       and checkpoint_output_file =
         flag "--checkpoint" (optional string)
           ~doc:"FILE save checkpoint to file (enables resume)"
       and checkpoint_resume_file =
         flag "--resume" (optional string)
           ~doc:"FILE resume from checkpoint file"
       and checkpoint_save_interval =
         flag "--save-interval"
           (optional_with_default 100 int)
           ~doc:"N save checkpoint every N tests (default: 100)"
       and instrumentation_config = Cli_args.config_flags in
       fun () ->
         let open Runner in
         (* Handle --show-checkpoint: decode and display, then exit *)
         (* Normal coverage run *)
         let run () =
           let spec_files = collect_spec_files Tgt.spec_dir in
           (* Build checkpoint configuration from CLI flags *)
           let checkpoint_config : Checkpoint.config =
             {
               output_file = checkpoint_output_file;
               resume_from = checkpoint_resume_file;
               save_interval = checkpoint_save_interval;
             }
           in
           let* spec = parse_spec_files spec_files in
           let* spec_il = elaborate spec in
           (* Convert to generic tasks for runner *)
           let generic_tasks = List.map to_generic tasks in
           let results =
             run_target_coverage ~config:instrumentation_config
               ~checkpoint_config ~verbose ~sl_mode ~spec_files spec_il
               generic_tasks
           in
           (* Print summary for each input spec *)
           List.iter
             (fun { task_name; summary } ->
               let passed = Runner.summary_passed summary in
               let failed = Runner.summary_failed summary in
               Format.printf "%s: %d/%d passed, %d failed\n" task_name passed
                 summary.total failed)
             results;
           Ok ()
         in
         match run () with
         | Ok () -> ()
         | Error error ->
             Format.printf "Error:\n  %s\n" (Runner.Error.string_of_error error))

  let make_checkpoint () =
    Core.Command.basic ~summary:"Checkpoint utilities"
      (let open Core.Command.Let_syntax in
       let open Core.Command.Param in
       let%map report_from =
         flag "--report" (required string)
           ~doc:"FILE decode and display checkpoint contents (no tests run)"
       and instrumentation_config = Cli_args.config_flags in
       fun () ->
         let open Runner in
         let run () =
           let spec_files = collect_spec_files Tgt.spec_dir in
           let* spec = parse_spec_files spec_files in
           let* spec_il = elaborate spec in
           let checkpoint = Checkpoint.load ~file:report_from in
           let* _ = Checkpoint.verify_spec checkpoint ~spec_files in
           Checkpoint.display_report ~spec:spec_il
             ~config:instrumentation_config checkpoint;
           Ok ()
         in
         match run () with
         | Ok () -> ()
         | Error error ->
             Format.printf "Error:\n  %s\n" (Runner.Error.string_of_error error))

  (* Generate "testgen" command *)
  let make_testgen () =
    Core.Command.basic
      ~summary:
        ("Generate test cases targeting uncovered premises for " ^ Tgt.name)
      (let open Core.Command.Let_syntax in
       let open Core.Command.Param in
       let%map checkpoint_file =
         flag "--checkpoint" (required string)
           ~doc:"FILE checkpoint file to load coverage and dependency data"
       and test_dir =
         flag "--test-dir" (optional string)
           ~doc:
             "DIR directory containing original test cases (default: target's \
              test directory)"
       and output_dir =
         flag "--output" (optional string)
           ~doc:
             "DIR output directory for generated test cases (default: \
              ./testgen_output)"
       and premise_uids =
         flag "--premises" (listed int)
           ~doc:
             "UID list of premise UIDs to generate tests for (if not provided, \
              shows uncovered)"
       and list_only =
         flag "--list" no_arg
           ~doc:" only list uncovered premises, don't generate tests"
       in
       fun () ->
         let open Runner.Testgen in
         try
           (* Load checkpoint *)
           let _checkpoint, coverage, dependency, path_condition =
             load_checkpoint checkpoint_file
           in

           (* Get uncovered premises *)
           let uncovered = get_uncovered_premises coverage in

           if list_only then (
             (* Just list uncovered premises with test case info *)
             Format.printf "Uncovered Premises (%d total):\n\n"
               (List.length uncovered);
             List.iter
               (fun prem ->
                 let test_cases =
                   Runner.Testgen.get_test_cases_for_premise prem.uid coverage
                 in
                 Format.printf "  UID %d: %s/%s\n" prem.uid prem.relation
                   prem.rule;
                 Format.printf "    Content: %s\n" prem.content;
                 if test_cases = [] then
                   Format.printf
                     "    Test cases: (none - premise never succeeded)\n"
                 else (
                   Format.printf
                     "    Test cases that succeeded this premise (%d):\n"
                     (List.length test_cases);
                   List.iter
                     (fun test_id -> Format.printf "      - %s\n" test_id)
                     test_cases);
                 Format.printf "\n")
               uncovered)
           else
             (* Generate test cases *)
             let uids_to_generate =
               match premise_uids with
               | [] ->
                   (* If no UIDs specified, ask user or generate for all *)
                   Format.printf
                     "No premise UIDs specified. Use --premises to select.\n";
                   Format.printf "Uncovered Premises:\n";
                   List.iter
                     (fun prem ->
                       Format.printf "  UID %d: %s/%s\n" prem.uid prem.relation
                         prem.rule)
                     uncovered;
                   []
               | uids -> uids
             in

             let test_path =
               match test_dir with Some dir -> dir | None -> Tgt.test_dir
             in

             let output_path =
               match output_dir with
               | Some dir -> dir
               | None -> "./testgen_output"
             in

             (* Create output directory *)
             (try Unix.mkdir output_path 0o755 with Unix.Unix_error _ -> ());

             (* Generate test cases for each selected premise *)
             List.iter
               (fun uid ->
                 try
                   match
                     generate_test_case ~test_dir:test_path
                       ~output_dir:output_path uid coverage dependency
                       path_condition None
                   with
                   | Some (pre_path, block_path) ->
                       Format.printf "Generated test case for premise UID %d:\n"
                         uid;
                       Format.printf "  Pre: %s\n" pre_path;
                       Format.printf "  Block: %s\n\n" block_path
                   | None ->
                       Format.printf
                         "Skipped premise UID %d: no test cases available\n" uid
                 with e ->
                   Format.eprintf
                     "Error generating test for premise UID %d: %s\n" uid
                     (Printexc.to_string e))
               uids_to_generate
         with e -> Format.eprintf "Error: %s\n" (Printexc.to_string e))
end
