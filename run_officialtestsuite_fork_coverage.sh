#!/usr/bin/env bash

set -euo pipefail

# OfficialTestSuite-only sequential state-transition coverage pipeline.
#
# Optional environment:
#   FORKS="phase0 altair bellatrix capella deneb electra"
#   SUITES="sanity random finality"
#   RESULTS_ROOT="./results_officialtestsuite_forks"
#   NIMBUS_COVERAGE_JOBS=8
#   CLEANUP_AFTER_REPORT=1
#   RUN_FORK_FINAL_MERGE=1
#   RUN_ALL_FINAL_MERGE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

FORKS="${FORKS:-phase0 altair bellatrix capella deneb electra}"
SUITES="${SUITES:-sanity random finality}"
RESULTS_ROOT="${RESULTS_ROOT:-./results_officialtestsuite_forks}"
export NIMBUS_COVERAGE_JOBS="${NIMBUS_COVERAGE_JOBS:-8}"
CLEANUP_AFTER_REPORT="${CLEANUP_AFTER_REPORT:-1}"
RUN_FORK_FINAL_MERGE="${RUN_FORK_FINAL_MERGE:-1}"
RUN_ALL_FINAL_MERGE="${RUN_ALL_FINAL_MERGE:-1}"

mkdir -p "$RESULTS_ROOT"

cleanup_arg=()
if [ "$CLEANUP_AFTER_REPORT" = "1" ]; then
  cleanup_arg=(--cleanup-after-report)
fi

suite_path() {
  local fork="$1"
  local suite="$2"

  case "$suite" in
    sanity)
      printf "Converter/OfficialTestSuite/%s/sanity/blocks/pyspec_tests" "$fork"
      ;;
    random)
      printf "Converter/OfficialTestSuite/%s/random/random/pyspec_tests" "$fork"
      ;;
    finality)
      local direct="Converter/OfficialTestSuite/$fork/finality/pyspec_tests"
      local nested="Converter/OfficialTestSuite/$fork/finality/finality/pyspec_tests"
      if [ -d "$direct" ]; then
        printf "%s" "$direct"
      else
        printf "%s" "$nested"
      fi
      ;;
    *)
      echo "unknown suite: $suite" >&2
      exit 2
      ;;
  esac
}

run_suite() {
  local fork="$1"
  local suite="$2"
  local input_path="$3"
  local output_base="$4"

  if [ ! -d "$input_path" ]; then
    echo "[skip] missing $fork $suite suite: $input_path"
    return 0
  fi

  if [ -d "$output_base/total-node-coverage" ]; then
    echo "[skip] completed $fork $suite suite: $output_base"
    return 0
  fi

  if [ -d "$output_base" ]; then
    local backup="${output_base}.incomplete_$(date +%Y%m%d_%H%M%S)"
    echo "[resume] moving incomplete $fork $suite output to $backup"
    mv "$output_base" "$backup"
  fi

  python3 diff_testing.py \
    --test-suite "$input_path" \
    --test-type state-transition \
    --workflow sequential \
    --fork-version "$fork" \
    --output-base "$output_base" \
    --enable-coverage \
    "${cleanup_arg[@]}"
}

final_merge() {
  local final_output="$1"
  shift

  python3 diff_testing.py \
    --generate-final-coverage \
    "$@" \
    --final-output-dir "$final_output"
}

all_suite_outputs=()

for fork in $FORKS; do
  fork_result_dir="$RESULTS_ROOT/$fork"
  mkdir -p "$fork_result_dir"

  fork_suite_outputs=()
  for suite in $SUITES; do
    input_path="$(suite_path "$fork" "$suite")"
    output_base="$fork_result_dir/coverage_${suite}_test"
    echo "[$fork] $suite: $input_path"
    run_suite "$fork" "$suite" "$input_path" "$output_base"
    if [ -d "$output_base" ]; then
      fork_suite_outputs+=("$output_base")
      all_suite_outputs+=("$output_base")
    fi
  done

  if [ "$RUN_FORK_FINAL_MERGE" = "1" ] && [ "${#fork_suite_outputs[@]}" -gt 0 ]; then
    final_merge "$fork_result_dir/accumulated_coverage_report_official" "${fork_suite_outputs[@]}"
  fi
done

if [ "$RUN_ALL_FINAL_MERGE" = "1" ] && [ "${#all_suite_outputs[@]}" -gt 0 ]; then
  final_merge "$RESULTS_ROOT/accumulated_coverage_report_all_forks_official" "${all_suite_outputs[@]}"
fi

echo "OfficialTestSuite fork coverage pipeline completed."
echo "All-fork report: $RESULTS_ROOT/accumulated_coverage_report_all_forks_official"
