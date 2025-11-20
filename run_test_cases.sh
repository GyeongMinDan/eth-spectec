#!/bin/bash

set -euo pipefail

spec_dir="/home/dan/eth2test/spectec-core"
base_results="Converter/OfficialTestSuite/random/random/pyspec_tests/_results"
cases=(4 6 7 8 15)

cd "$spec_dir"

for idx in "${cases[@]}"; do
  case_dir="${base_results}/randomized_${idx}"
  cmd=(./spectec-core run-sl spec/*.spectec
       --pre   "${case_dir}/pre.json"
       --block "${case_dir}/blocks_0.json"
       -o      "${case_dir}/spectec_output_0.json")
  echo ">>> running randomized_${idx}"
  set +e  # 에러가 나도 계속 진행
  "${cmd[@]}"
  exit_code=$?
  set -e
  if [ $exit_code -eq 0 ]; then
    echo "  ✓ randomized_${idx} succeeded"
  else
    echo "  ✗ randomized_${idx} failed (exit code: $exit_code)"
  fi
done

echo ">>> All test cases completed"

