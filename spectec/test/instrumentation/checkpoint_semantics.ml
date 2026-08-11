module Instrumentation = Instrumentation
module Config = Instrumentation.Config
module Positive = Instrumentation.Dependency.Positive
module Checkpoint = Runner.Checkpoint

let fail message = raise (Failure message)

let expect_equal description left right =
  if left <> right then
    fail
      (Printf.sprintf "%s\nleft:  %s\nright: %s" description left right)

let expect_different description left right =
  if left = right then fail (description ^ ": fingerprints unexpectedly match")

let fingerprint config = Config.semantic_fingerprint config

let make_config output target_uids =
  Config.
    {
      trace =
        Some
          Instrumentation.Trace.
            { level = Summary; output = Instrumentation.Output.file output };
      profile =
        Some
          Instrumentation.Profile.
            { output = Instrumentation.Output.file output };
      branch_coverage =
        Some
          Instrumentation.Branch_coverage.
            { level = Summary; output = Instrumentation.Output.file output };
      node_coverage =
        Some
          Instrumentation.Node_coverage_il.
            {
              level = Summary;
              output = Instrumentation.Output.file output;
              track_seeds = true;
            };
      dep_pos =
        Some
          Positive.
            {
              level = Summary;
              output = Instrumentation.Output.file output;
              target_uids;
            };
    }

let test_semantic_fingerprint () =
  let first = make_config "first.out" (Some [ 9; 3; 9 ]) in
  let same_semantics = make_config "second.out" (Some [ 3; 9 ]) in
  expect_equal
    "output filenames and target UID order/duplicates must be ignored"
    (fingerprint first) (fingerprint same_semantics);
  let changed_level =
    {
      first with
      trace =
        Some
          Instrumentation.Trace.
            { level = Full; output = Instrumentation.Output.file "first.out" };
    }
  in
  expect_different "trace level is semantic" (fingerprint first)
    (fingerprint changed_level);
  let changed_track_seeds =
    match first.node_coverage with
    | None -> fail "test setup omitted node coverage"
    | Some node ->
        { first with node_coverage = Some { node with track_seeds = false } }
  in
  expect_different "node track-seeds is semantic" (fingerprint first)
    (fingerprint changed_track_seeds);
  let changed_targets = make_config "first.out" (Some [ 3; 10 ]) in
  expect_different "dependency targets are semantic" (fingerprint first)
    (fingerprint changed_targets);
  let default_targets = make_config "first.out" None in
  expect_different "default and explicit dependency targets differ"
    (fingerprint first) (fingerprint default_targets)

let test_positive_restore () =
  let mutation : Positive.sym_mutation =
    {
      target_path = None;
      suggestion = Positive.Unknown (Lang.Il.Value.nat Bigint.zero);
    }
  in
  let expected : Positive.result =
    { per_test_sym_mutations = [ (42, [ ("case-a", [ mutation ]) ]) ] }
  in
  Positive.restore expected;
  let snapshot = Positive.get_result () in
  if snapshot <> expected then fail "Positive.restore did not restore mutation data";
  Positive.restore { per_test_sym_mutations = [] };
  if (Positive.get_result ()).per_test_sym_mutations <> [] then
    fail "Positive.restore did not replace prior mutation data";
  Positive.restore snapshot;
  if Positive.get_result () <> expected then
    fail "Positive checkpoint data did not survive reset and restore"

let empty_coverage : Checkpoint.coverage =
  {
    branch = None;
    node_il = None;
    node_sl = None;
    dependency = None;
    testgen = None;
  }

let make_checkpoint signature completed_inputs : Checkpoint.t =
  {
    spec_hash = "same-spec";
    completed_inputs =
      Checkpoint.make_run_marker signature
      :: List.map Checkpoint.make_success_entry completed_inputs;
    coverage = empty_coverage;
    timestamp = 0.;
  }

let merge_exn left right =
  match Checkpoint.merge left right with
  | Ok checkpoint -> checkpoint
  | Error _ -> fail "compatible checkpoint merge unexpectedly failed"

let test_checkpoint_merge_run_markers () =
  let first = make_checkpoint "run-a" [ "task\000case-a" ] in
  let same_run = make_checkpoint "run-a" [ "task\000case-b" ] in
  let resumable = merge_exn first same_run in
  if not (Checkpoint.has_run_signature resumable ~signature:"run-a") then
    fail "same-run checkpoint merge lost its resumable signature";
  let other_run = make_checkpoint "run-b" [ "task\000case-c" ] in
  let report_only = merge_exn first other_run in
  if
    Checkpoint.has_run_signature report_only ~signature:"run-a"
    || Checkpoint.has_run_signature report_only ~signature:"run-b"
  then
    fail "cross-run checkpoint merge remained resumable";
  if List.length (Checkpoint.completed_test_inputs report_only) <> 2 then
    fail "cross-run checkpoint merge lost completed test IDs"

let () =
  test_semantic_fingerprint ();
  test_positive_restore ();
  test_checkpoint_merge_run_markers ()
