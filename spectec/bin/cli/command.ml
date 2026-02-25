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

let make_parse (type i) ~summary (module T : CLI_TASK with type input = i) =
  Core.Command.basic ~summary
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames_spec =
       flag "--spec" (listed string)
         ~doc:"FILES spec files (default: use target spec dir)"
     and input = T.cli_flags
     and roundtrip = flag "-r" no_arg ~doc:" roundtrip parse/unparse" in
     fun () ->
       let run () =
         let spec_files =
           match filenames_spec with
           | [] -> collect_spec_files T.Target.spec_dir
           | files -> files
         in
         let open Runner in
         let* spec_el = parse_spec_files spec_files in
         let* spec_il = elaborate spec_el in
         let* _, values = T.parse_input ~spec:spec_il input in
         let unparsed = T.unparse ~spec:spec_il values in
         if roundtrip then
           let* values_rt =
             unparsed |> T.parse_string ~spec:spec_il ~filename:(T.source input)
           in
           let eq = Lang.Il.Eq.eq_values ~dbg:true values values_rt in
           if eq then Ok unparsed
           else
             Error
               (Error.RoundtripError
                  (Common.Source.no_region, "Roundtrip failed"))
         else Ok unparsed
       in
       match run () with
       | Ok s -> Format.printf "%s\n" s
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
       and test_dir =
         flag "--test-dir" (optional string)
           ~doc:
             "DIR directory containing test inputs (default: target's test \
              directory)"
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
             run_target_coverage ~config:instrumentation_config ?test_dir
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
    let report_command =
      Core.Command.basic ~summary:"Decode and display checkpoint contents"
        (let open Core.Command.Let_syntax in
         let open Core.Command.Param in
         let%map checkpoint_file = anon ("checkpoint-file" %: string)
         and instrumentation_config = Cli_args.config_flags in
         fun () ->
           let open Runner in
           let run () =
             let spec_files = collect_spec_files Tgt.spec_dir in
             let* spec = parse_spec_files spec_files in
             let* spec_il = elaborate spec in
             let* checkpoint =
               Checkpoint.verify_and_load ~file:checkpoint_file ~spec_files
                 ~verbose:true
             in
             Checkpoint.display_report ~spec:spec_il
               ~config:instrumentation_config checkpoint;
             Ok ()
           in
           match run () with
           | Ok () -> ()
           | Error error ->
               Format.printf "Error:\n  %s\n"
                 (Runner.Error.string_of_error error))
    in
    let merge_command =
      Core.Command.basic ~summary:"Merge two checkpoint files"
        (let open Core.Command.Let_syntax in
         let open Core.Command.Param in
         let%map checkpoint_file1 = anon ("checkpoint-file-1" %: string)
         and checkpoint_file2 = anon ("checkpoint-file-2" %: string)
         and output_file =
           flag "--output" (required string)
             ~doc:"FILE output file for merged checkpoint"
         in
         fun () ->
           let open Runner in
           let run () =
             let spec_files = collect_spec_files Tgt.spec_dir in
             let* checkpoint1 =
               Checkpoint.verify_and_load ~file:checkpoint_file1 ~spec_files
                 ~verbose:false
             in
             let* checkpoint2 =
               Checkpoint.verify_and_load ~file:checkpoint_file2 ~spec_files
                 ~verbose:false
             in
             let* merged = Checkpoint.merge checkpoint1 checkpoint2 in
             Checkpoint.save_to_file ~file:output_file merged;
             Format.printf "Merged checkpoint saved to: %s\n" output_file;
             Format.printf "  Checkpoint 1: %d tests\n"
               (List.length checkpoint1.completed_inputs);
             Format.printf "  Checkpoint 2: %d tests\n"
               (List.length checkpoint2.completed_inputs);
             Format.printf "  Merged: %d tests\n"
               (List.length merged.completed_inputs);
             Ok ()
           in
           match run () with
           | Ok () -> ()
           | Error error ->
               Format.printf "Error:\n  %s\n"
                 (Runner.Error.string_of_error error))
    in
    Core.Command.group ~summary:"Checkpoint utilities"
      [ ("report", report_command); ("merge", merge_command) ]

  (* Generate "testgen" command *)
  let make_testgen () =
    Core.Command.basic
      ~summary:
        ("Generate test cases targeting uncovered premises for " ^ Tgt.name)
      (let open Core.Command.Let_syntax in
       let open Core.Command.Param in
       let%map coverage_file =
         flag "--coverage" (required string)
           ~doc:
             "FILE coverage checkpoint file to load coverage and dependency \
              data"
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
       and premises_file =
         flag "--premises-file" (optional string)
           ~doc:
             "FILE file containing premise UIDs (one per line, # for comments)"
       and list_only =
         flag "--list" no_arg
           ~doc:" only list uncovered premises, don't generate tests"
       and verify =
         flag "--verify" no_arg
           ~doc:" verify that generated tests actually fail the target premise"
       and testgen_checkpoint =
         flag "--checkpoint" (optional string)
           ~doc:"FILE save testgen progress to checkpoint file"
       and testgen_resume =
         flag "--resume" (optional string)
           ~doc:"FILE resume testgen from checkpoint file"
       and save_interval =
         flag "--save-interval"
           (optional_with_default 100 int)
           ~doc:"N save testgen checkpoint every N tests (default: 100)"
       and filter_seeds =
         flag "--filter-seeds" (optional string)
           ~doc:"TYPE only process seeds of TYPE (sanity|finality|random)"
       and select_minimal =
         flag "--select-minimal" no_arg
           ~doc:
             " select minimal set of tests covering all premises (greedy set \
              cover)"
       and max_slot_gap =
         flag "--max-slot-gap"
           (optional_with_default 32 int)
           ~doc:
             "N max slot gap between state and block (default: 32, 0 to \
              disable)"
       in
       fun () ->
         let open Runner.Testgen in
         try
           (* Load coverage checkpoint *)
           let _checkpoint, coverage, _dependency, _path_condition =
             load_checkpoint coverage_file
           in

           (* Restore premise UID mapping from checkpoint *)
           (match coverage with
           | Some cov ->
               Instrumentation_static.Premise_uid.restore
                 (cov.prem_to_uid, cov.uid_to_prem);
               Format.printf "Restored %d premise UIDs from checkpoint\n%!"
                 (List.length cov.prem_to_uid)
           | None ->
               Format.eprintf
                 "Warning: No coverage data in checkpoint, UIDs may not match\n\
                  %!");

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
             (* Merge UIDs from file and command line *)
             let uids_from_file =
               match premises_file with
               | Some file -> Runner.Uid_parser.parse_uid_file file
               | None -> []
             in
             let all_uids = premise_uids @ uids_from_file in

             let uids_to_generate =
               match all_uids with
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

             (* Helper to lookup relation name/sig from premise region *)
             let spec_files = collect_spec_files Tgt.spec_dir in
             let spec_result =
               let open Result in
               let ( let* ) = bind in
               let* spec = Runner.parse_spec_files spec_files in
               Runner.elaborate spec
             in
             let spec_il = match spec_result with Ok s -> s | Error _ -> [] in
             (* best effort *)

             (* Initialize static analysis for positive dependency handler *)
             Instrumentation_static.Mutator_analysis.init
               (Instrumentation_static.Static.IlSpec spec_il);

             let _find_relation_for_uid uid =
               match get_premise_info uid coverage with
               | Some ({ key = region, _; _ }, _) ->
                   (* Scan spec for this region *)
                   let found = ref None in
                   let open Common.Source in
                   let open Lang.Il in
                   List.iter
                     (fun def ->
                       match def.it with
                       | RelD (id, sig_, _, rules) ->
                           List.iter
                             (fun rule ->
                               let _, _, prems = rule.it in
                               List.iter
                                 (fun prem ->
                                   if prem.at = region then
                                     found := Some (id.it, sig_))
                                 prems)
                             rules
                       | _ -> ())
                     spec_il;
                   !found
               | None -> None
             in

             (* Helper to run positive analysis on a specific test case *)
             let analyze_test_case test_id target_uids =
               let open Instrumentation in
               (* Construct paths *)
               let pre_path = Filename.concat test_path test_id in
               let test_dir_path = Filename.dirname pre_path in
               let block_path = Filename.concat test_dir_path "block.json" in

               let found = ref None in
               List.iter
                 (fun def ->
                   let open Common.Source in
                   match def.it with
                   | Lang.Il.RelD (id, sig_, _, _)
                     when id.it = "State_transition" ->
                       found := Some sig_
                   | _ -> ())
                 spec_il;

               match !found with
               | None ->
                   Format.printf
                     "WARNING: State_transition relation not found in spec. \
                      Cannot run analysis on %s.\n"
                     test_id;
                   None
               | Some sig_ -> (
                   match sig_.it with
                   | _, args -> (
                       if List.length args < 3 then None
                       else
                         let open Common.Source in
                         let type_pre = List.nth args 0 in
                         let type_block = List.nth args 1 in
                         (* type_bool is arg 2 *)

                         (* Parse Inputs *)
                         let tdenv =
                           List.fold_left
                             (fun tdenv (def : Lang.Il.def) ->
                               match def.it with
                               | Lang.Il.TypD (id, tparams, deftyp) ->
                                   Envs.Il.TDEnv.add id (tparams, deftyp) tdenv
                               | _ -> tdenv)
                             Envs.Il.TDEnv.empty spec_il
                         in
                         let parse_file f t =
                           try
                             let json = Yojson.Safe.from_file f in
                             Interface.JSON.Parse.json_to_value tdenv t.it json
                             |> Result.to_option
                           with _ -> None
                         in

                         match
                           ( parse_file pre_path type_pre,
                             parse_file block_path type_block )
                         with
                         | Some val_pre, Some val_block ->
                             (* Synthesize 3rd arg: true *)
                             let val_bool =
                               Lang.Il.Value.Make.bool Lang.Il.Typ.bool true
                             in
                             let values_input =
                               [ val_pre; val_block; val_bool ]
                             in

                             (* Setup Positive Handler *)
                             let handler, get_result =
                               Dependency.Positive.make_with_data
                                 {
                                   level = Summary;
                                   output = Quiet;
                                   target_uids = Some target_uids;
                                 }
                             in

                             Dispatcher.set_handlers
                               [ (module (val handler) : Handler.S) ];
                             Dispatcher.init ~spec:(Handler.IlSpec spec_il);
                             Dispatcher.notify_test_start ~test_case_id:test_id;

                             (* Run interpretation *)
                             let _ =
                               try
                                 Runner.eval_il_run
                                   (module Tgt)
                                   spec_il "State_transition" values_input
                                   pre_path
                               with _ ->
                                 Result.error
                                   (Runner.Error.EvalIlError
                                      ( Common.Source.no_region,
                                        "Analysis Exec failed" ))
                             in

                             Dispatcher.notify_test_end ~test_case_id:test_id;
                             Dispatcher.finish ();
                             Some (get_result ())
                         | _ -> None))
             in

             (* Use test-case-centric generation with checkpoint support *)
             Format.printf "Starting test-case-centric generation...\n%!";
             let results =
               Runner.Testgen.generate_tests_with_checkpoint ~test_dir:test_path
                 ~output_dir:output_path ~checkpoint_file:testgen_checkpoint
                 ~resume_file:testgen_resume ~save_interval ~filter_seeds
                 ~select_minimal ~max_slot_gap uids_to_generate coverage
                 analyze_test_case
             in

             (* Print summary *)
             Format.printf "\nGeneration complete:\n";
             List.iter
               (fun (test_id, premise_results) ->
                 Format.printf "  Test case: %s\n" test_id;
                 List.iter
                   (fun (prem_uid, mutations) ->
                     Format.printf "    Premise %d: %d mutations\n" prem_uid
                       (List.length mutations))
                   premise_results)
               results;
             Format.printf "\n";

             (* Verification if requested *)
             if verify then
               Format.printf
                 "Verification not yet implemented for test-case-centric mode\n\
                  %!"
         with e -> Format.eprintf "Error: %s\n" (Printexc.to_string e))
end
