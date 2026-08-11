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

let digest_file filename = Digest.file filename |> Digest.to_hex

let is_corpus_file name =
  List.mem name
    [
      ".fork";
      ".official-oracle";
      "pre.json";
      "post.json";
      "error.txt";
      "block.json";
      "slots.yaml";
      "proposer_slashing.json";
      "attester_slashing.json";
      "attestation.json";
      "deposit.json";
      "voluntary_exit.json";
      "bls_to_execution_change.json";
      "execution_payload.json";
      "execution.json";
      "withdrawals.json";
      "block_header.json";
      "sync_aggregate.json";
    ]

let is_hex_digest value =
  String.length value = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
         | _ -> false)
       value

let validate_official_oracles ~root ~fork ~expected_total =
  let rec collect_leaves path leaves =
    if not (Sys.is_directory path) then leaves
    else
      let pre = Filename.concat path "pre.json" in
      if Sys.file_exists pre && not (Sys.is_directory pre) then path :: leaves
      else
        Sys.readdir path |> Array.to_list
        |> List.fold_left
             (fun leaves name ->
               let child = Filename.concat path name in
               if Sys.is_directory child then collect_leaves child leaves
               else leaves)
             leaves
  in
  let leaves = collect_leaves root [] |> List.sort String.compare in
  if List.length leaves <> expected_total then
    Error
      (Printf.sprintf "official corpus has %d leaves, expected %d"
         (List.length leaves) expected_total)
  else
    let validate_leaf case_dir =
      let post = Filename.concat case_dir "post.json" in
      let error = Filename.concat case_dir "error.txt" in
      if Sys.file_exists post = Sys.file_exists error then
        Error
          (Printf.sprintf
             "official test must contain exactly one of post.json or error.txt: %s"
             case_dir)
      else
        let marker = Filename.concat case_dir ".official-oracle" in
        if not (Sys.file_exists marker) || Sys.is_directory marker then
          Error
            (Printf.sprintf "official test is missing oracle marker: %s" marker)
        else
          try
            let channel = open_in marker in
            let value =
              Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
                  input_line channel |> String.trim)
            in
            match String.split_on_char ':' value with
            | [ "official-oracle-v1"; marker_fork; polarity; digest ]
              when marker_fork = fork
                   && (polarity = "positive" || polarity = "negative")
                   && is_hex_digest digest ->
                Ok ()
            | _ ->
                Error
                  (Printf.sprintf "invalid official oracle marker: %s" marker)
          with
          | Sys_error message ->
            Error
              (Printf.sprintf "cannot read official oracle marker %s: %s"
                 marker message)
          | End_of_file ->
              Error
                (Printf.sprintf "official oracle marker is empty: %s" marker)
    in
    let rec validate = function
      | [] -> Ok ()
      | case_dir :: rest -> (
          match validate_leaf case_dir with
          | Ok () -> validate rest
          | Error _ as error -> error)
    in
    validate leaves

let digest_tree root =
  let rec collect path files =
    if Sys.is_directory path then
      Sys.readdir path |> Array.to_list
      |> List.fold_left
           (fun files name -> collect (Filename.concat path name) files)
           files
    else
      let name = Filename.basename path in
      if is_corpus_file name then path :: files else files
  in
  if not (Sys.file_exists root) then "missing"
  else
    let files = collect root [] |> List.sort String.compare in
    let root_prefix =
      if Filename.check_suffix root Filename.dir_sep then root
      else root ^ Filename.dir_sep
    in
    let buffer = Buffer.create (List.length files * 64) in
    List.iter
      (fun filename ->
        let relative =
          let prefix_length = String.length root_prefix in
          if
            String.length filename >= prefix_length
            && String.sub filename 0 prefix_length = root_prefix
          then
            String.sub filename prefix_length
              (String.length filename - prefix_length)
          else filename
        in
        Buffer.add_string buffer relative;
        Buffer.add_char buffer '\000';
        Buffer.add_string buffer (digest_file filename);
        Buffer.add_char buffer '\n')
      files;
    Digest.string (Buffer.contents buffer) |> Digest.to_hex

let epoch_official_counts =
  [
    ("justification_and_finalization", 10);
    ("inactivity_updates", 21);
    ("rewards_and_penalties", 15);
    ("registry_updates", 11);
    ("slashings", 5);
    ("eth1_data_reset", 2);
    ("effective_balance_updates", 1);
    ("slashings_reset", 1);
    ("randao_mixes_reset", 1);
    ("historical_summaries_update", 1);
    ("participation_flag_updates", 10);
  ]

let common_operation_official_counts =
  [
    ("proposer_slashing", 15);
    ("attester_slashing", 30);
    ("attestation", 41);
    ("deposit", 21);
    ("voluntary_exit", 15);
    ("withdrawals", 50);
    ("block_header", 6);
    ("sync_aggregate", 26);
  ]

let official_counts = function
  | "capella" ->
      Some
        (common_operation_official_counts
        @ [ ("bls_to_execution_change", 15); ("execution_payload", 26) ]
        @ epoch_official_counts
        @ [ ("slots", 7); ("state_transition", 581) ])
  | "deneb" ->
      Some
        (common_operation_official_counts
        @ [ ("bls_to_execution_change", 14); ("execution_payload", 38) ]
        @ epoch_official_counts
        @ [ ("slots", 6); ("state_transition", 590) ])
  | _ -> None

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
  | Task.Skipped -> Format.printf "Skipped: %s\n\n" source

(* Run interpreter on a single input and print result *)
let run_single (type i) (module T : Runner.Task.S with type input = i) ~config
    ~sl_mode ~spec_il ~check_output (input : i) =
  let outcome =
    Runner.run_with_outcome (module T) ~config ~check_output ~sl_mode ~spec_il
      input
  in
  print_outcome (module T) (T.source input) outcome;
  outcome

(* Run interpreter on a suite of inputs and print results *)
let run_suite (type i) (module T : Runner.Task.S with type input = i) ~config
    ~sl_mode ~spec_il ~verbose ~check_output (inputs : i list) =
  let results =
    Runner.run_suite_with_outcomes
      (module T) ~config ~sl_mode ~spec_il ~verbose ~check_output inputs
  in
  let summary = Runner.summarize_outcomes results in
  let passed = Runner.summary_passed summary in
  let failed = Runner.summary_failed summary in
  match verbose with
  | true ->
      (* Summary only in verbose mode, as progress was printed *)
      Format.printf "\nTest Results: %d/%d passed, %d failed\n" passed
        summary.total failed;
      summary
  | false ->
      (* Full report at end if not verbose *)
      List.iter
        (fun Runner.{ source; outcome; _ } ->
          Format.printf ">>> Running %s on %s\n" T.name source;
          print_outcome (module T) source outcome)
        results;
      Format.printf "\nTest Results: %d/%d passed, %d failed\n" passed
        summary.total failed;
      summary

(* Generate a CLI command for any CLI_TASK *)
let make (type i) ~summary (module T : CLI_TASK with type input = i) =
  Core.Command.basic ~summary
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames_spec =
       flag "--spec" (listed string)
         ~doc:"FILES spec files (default: use target spec dir)"
     and spec_dir_arg =
       flag "--spec-dir" (optional string)
         ~doc:"DIR directory containing spec files (default: target spec dir)"
     and sl_mode = flag "--sl" no_arg ~doc:" use SL interpreter (default: IL)"
     and verbose = flag "-v" no_arg ~doc:" verbose output"
     and check_output =
       flag "--check-post" no_arg
         ~doc:" compare successful output with sibling post.json"
     and suite_mode =
       flag "--suite" no_arg ~doc:" run on test suite (default dir)"
     and suite_dir_arg =
       flag "--suite-dir" (optional string) ~doc:"DIR run on test suite in DIR"
     and input = T.cli_flags
     and config = Cli_args.config_flags in
     fun () ->
       let open Runner in
       let run () =
         let* () =
           if check_output && spec_dir_arg = None && filenames_spec = [] then
             Error
               (Error.TestRunError
                  "--check-post requires an explicit --spec-dir or --spec")
           else Ok ()
         in
         let filenames_spec =
           match (filenames_spec, spec_dir_arg) with
           | [], None -> collect_spec_files T.Target.spec_dir
           | [], Some dir -> collect_spec_files dir
           | files, _ -> files
         in
         let* spec = parse_spec_files filenames_spec in
         let* spec_il = elaborate spec in
         match (suite_mode, suite_dir_arg) with
         | false, None ->
             let outcome =
               run_single (module T) ~config ~sl_mode ~spec_il ~check_output
                 input
             in
             (match outcome with
             | Task.Fail _ | Task.UnexpectedPass _ ->
                 Error (Error.TestRunError "test failed")
             | Task.Pass _ | Task.ExpectedFail _ | Task.Skipped -> Ok ())
         | true, None ->
             (* Use task defaults *)
             let summary =
               run_suite
                 (module T) ~config ~sl_mode ~spec_il ~verbose ~check_output
                 (T.collect ())
             in
             if summary.total = 0 then
               Error (Error.TestRunError "no tests discovered")
             else if Runner.summary_failed summary > 0 then
               Error
                 (Error.TestRunError
                    (Printf.sprintf "%d test(s) failed"
                       (Runner.summary_failed summary)))
             else Ok ()
         | _, Some dir ->
             (* Use explicit directory *)
             let summary =
               run_suite
                 (module T) ~config ~sl_mode ~spec_il ~verbose ~check_output
                 (T.collect ~dir ())
             in
             if summary.total = 0 then
               Error (Error.TestRunError "no tests discovered")
             else if Runner.summary_failed summary > 0 then
               Error
                 (Error.TestRunError
                    (Printf.sprintf "%d test(s) failed"
                       (Runner.summary_failed summary)))
             else Ok ()
       in
       match run () with
       | Ok () -> ()
       | Error e ->
           Format.eprintf "Error:\n  %s\n%!" (Runner.Error.string_of_error e);
           Stdlib.exit 1)

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
           Format.eprintf "Error:\n  %s\n%!" (Runner.Error.string_of_error e);
           Stdlib.exit 1)

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
  let make_coverage ?(on_no_validate = fun () -> ()) (tasks : packed_task list)
      =
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
       and spec_dir_arg =
         flag "--spec-dir" (optional string)
           ~doc:
             "DIR directory containing spec files (default: target's spec dir)"
       and max_slot_gap =
         flag "--max-slot-gap" (optional int)
           ~doc:"N skip inputs where block.slot - state.slot > N (e.g. 32)"
       and no_validate =
         flag "--no-validate" no_arg
           ~doc:" Skip state root validation (validate_result=false)"
       and check_output =
         flag "--check-post" no_arg
           ~doc:" compare successful output with sibling post.json"
       and require_all_tasks =
         flag "--require-all-tasks" no_arg
           ~doc:" fail if any configured task discovers zero tests"
       and official_fork =
         flag "--official-fork" (optional string)
           ~doc:
             "FORK validate the complete official manifest (capella or deneb)"
       and instrumentation_config = Cli_args.config_flags in
       fun () ->
         let open Runner in
         if no_validate then on_no_validate ();
         (* Handle --show-checkpoint: decode and display, then exit *)
         (* Normal coverage run *)
         let run () =
           let* official_manifest =
             match official_fork with
             | None -> Ok None
             | Some fork -> (
                 let fork = String.lowercase_ascii fork in
                 match official_counts fork with
                 | Some counts -> Ok (Some (fork, counts))
                 | None ->
                     Error
                       (Error.TestRunError
                          "--official-fork must be either capella or deneb"))
           in
           let* () =
             if check_output && spec_dir_arg = None then
               Error
                 (Error.TestRunError
                    "--check-post requires an explicit --spec-dir")
             else Ok ()
           in
           let* () =
             match official_manifest with
             | None -> Ok ()
             | Some _ when not check_output ->
                 Error
                   (Error.TestRunError
                      "--official-fork requires --check-post")
             | Some _ when no_validate ->
                 Error
                   (Error.TestRunError
                      "--official-fork cannot be combined with --no-validate")
             | Some _ when test_dir = None ->
                 Error
                   (Error.TestRunError
                      "--official-fork requires an explicit --test-dir")
             | Some _ -> Ok ()
           in
           let* () =
             if checkpoint_save_interval <= 0 then
               Error
                 (Error.TestRunError "--save-interval must be greater than zero")
             else Ok ()
           in
           let spec_files =
             let dir = Option.value spec_dir_arg ~default:Tgt.spec_dir in
             collect_spec_files dir
           in
           let* () =
             match official_manifest with
             | None -> Ok ()
             | Some (fork, _) ->
                 let expected_dir = "spec_" ^ fork in
                 if
                   List.for_all
                     (fun filename ->
                       Filename.basename (Filename.dirname filename)
                       = expected_dir)
                     spec_files
                 then Ok ()
                 else
                   Error
                     (Error.TestRunError
                        (Printf.sprintf
                           "--official-fork %s requires spec files from %s"
                           fork expected_dir))
           in
           let* () =
             match (official_manifest, test_dir) with
             | Some (fork, _), Some root ->
                 let marker = Filename.concat root ".fork" in
                 if Sys.file_exists marker then
                   (try
                      let channel = open_in marker in
                      let recorded =
                        Fun.protect
                          ~finally:(fun () -> close_in_noerr channel)
                          (fun () -> input_line channel |> String.trim)
                      in
                      if recorded = fork then Ok ()
                      else
                        Error
                          (Error.TestRunError
                             (Printf.sprintf
                                "test corpus fork marker is %s, expected %s"
                                recorded fork))
                    with
                   | Sys_error message ->
                       Error
                         (Error.TestRunError
                            (Printf.sprintf
                               "cannot read test corpus fork marker %s: %s"
                               marker message))
                   | End_of_file ->
                       Error
                         (Error.TestRunError
                            (Printf.sprintf
                               "test corpus fork marker is empty: %s" marker)))
                 else
                   Error
                     (Error.TestRunError
                        (Printf.sprintf
                           "official test corpus is missing fork marker: %s"
                           marker))
             | _ -> Ok ()
           in
           let* () =
             match (official_manifest, test_dir) with
             | Some (fork, expected_counts), Some root ->
                 let expected_total =
                   List.fold_left
                     (fun total (_, count) -> total + count)
                     0 expected_counts
                 in
                 validate_official_oracles ~root ~fork ~expected_total
                 |> Result.map_error (fun message ->
                        Error.TestRunError message)
             | _ -> Ok ()
           in
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
           let corpus_root = Option.value test_dir ~default:Tgt.test_dir in
           let canonical_corpus_root =
             try Unix.realpath corpus_root with Unix.Unix_error _ -> corpus_root
           in
           let checkpoint_run_signature =
             let checkpoint_enabled =
               Option.is_some checkpoint_output_file
               || Option.is_some checkpoint_resume_file
             in
             let binary_hash, corpus_hash =
               if checkpoint_enabled then (
                 Format.printf
                   "Fingerprinting executable and test corpus for safe \
                    checkpoint resume... %!";
                 let hashes =
                   (digest_file Sys.executable_name, digest_tree corpus_root)
                 in
                 Format.printf "done\n%!";
                 hashes)
               else ("checkpoint-disabled", "checkpoint-disabled")
             in
             let task_names =
               List.map
                 (fun (Pack (module Task)) -> Task.name)
                 tasks
               |> String.concat ","
             in
             let instrumentation =
               Instrumentation.Config.semantic_fingerprint
                 instrumentation_config
             in
             Printf.sprintf
               "coverage-v3;target=%s;sl=%b;check-post=%b;validate=%b;max-slot-gap=%s;tasks=%s;instrumentation=%s;binary=%s;corpus-root=%s;corpus=%s"
               Tgt.name sl_mode check_output (not no_validate)
               (match max_slot_gap with
               | None -> "none"
               | Some limit -> string_of_int limit)
               task_names instrumentation binary_hash canonical_corpus_root
               corpus_hash
           in
           let* results =
             run_target_coverage ~config:instrumentation_config ?test_dir
               ?max_slot_gap ~check_output ~checkpoint_config ~verbose ~sl_mode
               ~spec_files ~checkpoint_run_signature spec_il generic_tasks
           in
           (* Print summary for each input spec *)
           List.iter
             (fun { task_name; summary } ->
               let passed = Runner.summary_passed summary in
               let failed = Runner.summary_failed summary in
               let skipped_str =
                 if summary.skipped > 0 then
                   Printf.sprintf ", %d skipped" summary.skipped
                 else ""
               in
               Format.printf "%s: %d/%d passed, %d failed%s\n" task_name passed
                 summary.total failed skipped_str)
             results;
           let failed =
             List.fold_left
               (fun total { summary; _ } ->
                 total + Runner.summary_failed summary)
               0 results
           in
           let empty_tasks =
             List.filter (fun { summary; _ } -> summary.total = 0) results
           in
           let manifest_errors =
             match official_manifest with
             | None -> []
             | Some (_, expected_counts) ->
                 List.filter_map
                   (fun (task_name, expected) ->
                     match
                       List.find_opt
                         (fun result -> result.task_name = task_name)
                         results
                     with
                     | None -> Some (Printf.sprintf "%s is missing" task_name)
                     | Some { summary; _ } when summary.total <> expected ->
                         Some
                           (Printf.sprintf "%s has %d tests, expected %d"
                              task_name summary.total expected)
                     | Some _ -> None)
                   expected_counts
           in
           let skipped =
             List.fold_left
               (fun total { summary; _ } -> total + summary.skipped)
               0 results
           in
           (match official_manifest with
           | Some (fork, expected_counts) when manifest_errors = [] ->
               let expected_total =
                 List.fold_left
                   (fun total (_, count) -> total + count)
                   0 expected_counts
               in
               Format.printf "official-%s: manifest %d/%d discovered\n" fork
                 expected_total expected_total
           | _ -> ());
           if failed > 0 then
             Error
               (Error.TestRunError
                  (Printf.sprintf "%d official test(s) failed" failed))
           else if require_all_tasks && empty_tasks <> [] then
             Error
               (Error.TestRunError
                  (Printf.sprintf "No tests discovered for required task(s): %s"
                     (empty_tasks
                     |> List.map (fun { task_name; _ } -> task_name)
                     |> String.concat ", ")))
           else if manifest_errors <> [] then
             Error
               (Error.TestRunError
                  ("Official manifest mismatch: "
                  ^ String.concat "; " manifest_errors))
           else if official_manifest <> None && skipped > 0 then
             Error
               (Error.TestRunError
                  (Printf.sprintf
                     "Official validation skipped %d test(s); a full run must skip none"
                     skipped))
           else Ok ()
         in
         match run () with
         | Ok () -> ()
         | Error error ->
             Format.eprintf "Error:\n  %s\n%!"
               (Runner.Error.string_of_error error);
             Stdlib.exit 1)

  let make_checkpoint () =
    let report_command =
      Core.Command.basic ~summary:"Decode and display checkpoint contents"
        (let open Core.Command.Let_syntax in
         let open Core.Command.Param in
         let%map checkpoint_file = anon ("checkpoint-file" %: string)
         and instrumentation_config = Cli_args.config_flags
         and ignore_spec_mismatch =
           flag "--ignore-spec-mismatch" no_arg
             ~doc:" Skip spec version check (use when spec has changed)"
         and spec_dir_arg =
           flag "--spec-dir" (optional string)
             ~doc:
               "DIR directory containing spec files (default: target's spec \
                dir)"
         in
         fun () ->
           let open Runner in
           let run () =
             let spec_files =
               let dir = Option.value spec_dir_arg ~default:Tgt.spec_dir in
               collect_spec_files dir
             in
             let* spec = parse_spec_files spec_files in
             let* spec_il = elaborate spec in
             let* checkpoint =
               Checkpoint.verify_and_load ~file:checkpoint_file ~spec_files
                 ~verbose:true ~ignore_spec_mismatch ()
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
         and ignore_spec_mismatch =
           flag "--ignore-spec-mismatch" no_arg
             ~doc:" Skip spec version check (use when spec has changed)"
         and spec_dir_arg =
           flag "--spec-dir" (optional string)
             ~doc:
               "DIR directory containing spec files (default: target's spec \
                dir)"
         in
         fun () ->
           let open Runner in
           let run () =
             let spec_files =
               let dir = Option.value spec_dir_arg ~default:Tgt.spec_dir in
               collect_spec_files dir
             in
             let* checkpoint1 =
               Checkpoint.verify_and_load ~file:checkpoint_file1 ~spec_files
                 ~verbose:false ~ignore_spec_mismatch ()
             in
             let* checkpoint2 =
               Checkpoint.verify_and_load ~file:checkpoint_file2 ~spec_files
                 ~verbose:false ~ignore_spec_mismatch ()
             in
             let* merged =
               Checkpoint.merge ~ignore_spec_mismatch checkpoint1 checkpoint2
             in
             Checkpoint.save_to_file ~file:output_file merged;
             Format.printf "Merged checkpoint saved to: %s\n" output_file;
             Format.printf "  Checkpoint 1: %d tests\n"
               (List.length (Checkpoint.completed_test_inputs checkpoint1));
             Format.printf "  Checkpoint 2: %d tests\n"
               (List.length (Checkpoint.completed_test_inputs checkpoint2));
             Format.printf "  Merged: %d tests\n"
               (List.length (Checkpoint.completed_test_inputs merged));
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
       and coverage_level_flag =
         flag "--coverage-level"
           (optional_with_default 0 int)
           ~doc:
             "N select seeds with K-cover: each premise covered by at least N \
              seeds (0 = all, 1 = minimal/greedy)"
       and max_slot_gap =
         flag "--max-slot-gap"
           (optional_with_default 32 int)
           ~doc:
             "N max slot gap between state and block (default: 32, 0 to \
              disable)"
       and spec_dir_arg =
         flag "--spec-dir" (optional string)
           ~doc:
             "DIR directory containing spec files (default: target's spec dir)"
       in
       fun () ->
         let open Runner.Testgen in
         try
           (* Load coverage checkpoint *)
           let _checkpoint, coverage, _dependency =
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
             let spec_files =
               let dir = Option.value spec_dir_arg ~default:Tgt.spec_dir in
               collect_spec_files dir
             in
             let spec_result =
               let open Result in
               let ( let* ) = bind in
               let* spec = Runner.parse_spec_files spec_files in
               Runner.elaborate spec
             in
             let spec_il = match spec_result with Ok s -> s | Error _ -> [] in
             (* best effort *)

             (* Initialize static analysis for positive dependency handler *)
             let static_spec = Instrumentation_static.Static.IlSpec spec_il in
             Instrumentation_static.Type_tree.init static_spec;
             Instrumentation_static.Mutator_analysis.init static_spec;

             (* Try to resolve test_id to an existing pre.json path.
                1. Try test_id directly (handles absolute paths that still exist)
                2. Try Filename.concat test_path test_id (handles relative IDs)
                3. Try extracting relative portion after known category anchors
                   ("sanity/blocks/", "random/", "finality/") and joining with test_path *)
             let resolve_pre_path test_id test_path =
               let contains_substring haystack needle =
                 let hlen = String.length haystack in
                 let nlen = String.length needle in
                 if nlen = 0 then Some 0
                 else
                   let rec search i =
                     if i > hlen - nlen then None
                     else if String.sub haystack i nlen = needle then Some i
                     else search (i + 1)
                   in
                   search 0
               in
               let anchored_candidates =
                 let anchors = [ "sanity/blocks/"; "random/"; "finality/" ] in
                 List.filter_map
                   (fun anchor ->
                     match contains_substring test_id anchor with
                     | None -> None
                     | Some pos ->
                         let rel =
                           String.sub test_id pos (String.length test_id - pos)
                         in
                         Some (Filename.concat test_path rel))
                   anchors
               in
               let path_candidates =
                 test_id
                 :: Filename.concat test_path test_id
                 :: anchored_candidates
               in
               List.find_opt Sys.file_exists path_candidates
             in

             (* Helper to run positive analysis on a specific test case *)
             let analyze_test_case test_id target_uids =
               let open Instrumentation in
               (* Construct paths *)
               let pre_path =
                 match resolve_pre_path test_id test_path with
                 | Some p -> p
                 | None -> Filename.concat test_path test_id
               in
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
                         let parse_file ~provenance f t =
                           try
                             let json = Yojson.Safe.from_file f in
                             Interface.JSON.Parse.json_to_value ~provenance
                               tdenv t.it json
                             |> Result.to_option
                           with _ -> None
                         in

                         match
                           ( parse_file
                               ~provenance:(Some (Lang.Il.JsonState, []))
                               pre_path type_pre,
                             parse_file
                               ~provenance:(Some (Lang.Il.JsonBlock, []))
                               block_path type_block )
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
                         | _ ->
                             if not (Sys.file_exists pre_path) then
                               Format.printf "  Skipped: file not found: %s\n%!"
                                 pre_path
                             else if not (Sys.file_exists block_path) then
                               Format.printf "  Skipped: file not found: %s\n%!"
                                 block_path
                             else
                               Format.printf
                                 "  Skipped: JSON parse error for %s\n%!"
                                 pre_path;
                             None))
             in

             (* Resolve coverage_level: --coverage-level wins over --select-minimal *)
             let coverage_level =
               if coverage_level_flag > 0 then coverage_level_flag else 0
             in

             (* Use test-case-centric generation with checkpoint support *)
             Format.printf "Starting test-case-centric generation...\n%!";
             let results =
               Runner.Testgen.generate_tests_with_checkpoint ~test_dir:test_path
                 ~output_dir:output_path ~checkpoint_file:testgen_checkpoint
                 ~resume_file:testgen_resume ~save_interval ~filter_seeds
                 ~coverage_level ~max_slot_gap uids_to_generate coverage
                 analyze_test_case
             in
             ignore results;

             (* Verification if requested *)
             if verify then
               Format.printf
                 "Verification not yet implemented for test-case-centric mode\n\
                  %!"
         with e -> Format.eprintf "Error: %s\n" (Printexc.to_string e))
end
