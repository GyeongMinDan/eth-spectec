#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: tools/run_rq3_random_extreme_baselines.sh [OUTPUT_ROOT] [SEED_SHARDS]

Reproduce the paper's deterministic Capella RQ3 Random and Extreme controls.
Defaults:
  OUTPUT_ROOT  results/rq3-controls
  SEED_SHARDS  4

The command creates one 21,444-case raw suite and one slot-gap-filtered suite
for each strategy.  It is safe to resume interrupted raw generation.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi
if (( $# > 2 )); then
  usage >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
output_root=$(realpath -m "${1:-$repo_dir/results/rq3-controls}")
seed_shards=${2:-${SEED_SHARDS:-4}}

if [[ ! $seed_shards =~ ^[1-9][0-9]*$ ]]; then
  echo "SEED_SHARDS must be a positive integer: $seed_shards" >&2
  exit 2
fi

official_root="$repo_dir/Converter/OfficialTestSuite"
consensus_specs_dir="$repo_dir/consensus-specs"
seed_dir="$output_root/capella_seed581"
log_dir="$output_root/logs"
master_seed=SpecTrum-ASE2026-camera-ready-path-uniform-v1
expected_seed_manifest=544db4ae7f549159683ce9000ad49774bed225f9b614226584e7c4d9066850e9
expected_python_version=3.10.12

mkdir -p "$output_root" "$log_dir"

actual_python_version=$(python3 -c 'import platform; print(platform.python_version())')
if [[ $actual_python_version != "$expected_python_version" ]]; then
  echo "exact RQ3 reproduction requires Python $expected_python_version" >&2
  echo "current Python: $actual_python_version" >&2
  echo "run this command inside the pinned SpecTrum artifact image" >&2
  exit 1
fi

if [[ ! -f $seed_dir/summary.json ]]; then
  python3 "$script_dir/collect_capella_flattened_seed581.py" \
    --official-root "$official_root" \
    --consensus-specs-dir "$consensus_specs_dir" \
    --out-dir "$seed_dir" \
    --progress-every 10 \
    2>&1 | tee "$log_dir/collect_seed581.log"
else
  echo "using existing flattened seed cache: $seed_dir"
fi

actual_seed_manifest=$(sha256sum "$seed_dir/manifest.json" | awk '{print $1}')
if [[ $actual_seed_manifest != "$expected_seed_manifest" ]]; then
  echo "seed manifest SHA-256 mismatch" >&2
  echo "expected: $expected_seed_manifest" >&2
  echo "actual:   $actual_seed_manifest" >&2
  exit 1
fi

generate_strategy() {
  local strategy=$1
  local raw_dir="$output_root/$strategy/raw"
  local strategy_log="$log_dir/$strategy"
  mkdir -p "$strategy_log"

  local -a common=(
    python3 "$script_dir/generate_capella_path_uniform_baseline_pyspec.py"
    --strategy "$strategy"
    --seed-dir "$seed_dir"
    --out-dir "$raw_dir"
    --consensus-specs-dir "$consensus_specs_dir"
    --master-seed "$master_seed"
    --budget-profile paper-rq3
    --testing-max-slot-gap 32
    --max-random-value-attempts 16
    --max-index-retries 128
    --max-path-retries 1024
  )

  "${common[@]}" \
    --initialize-only --resume --progress-every 0 \
    >"$strategy_log/initialize.log" 2>&1

  local -a pids=()
  local shard_index
  for ((shard_index = 0; shard_index < seed_shards; shard_index++)); do
    "${common[@]}" \
      --seed-shard-count "$seed_shards" \
      --seed-shard-index "$shard_index" \
      --defer-finalize --resume --progress-every 25 \
      >"$strategy_log/shard_${shard_index}.log" 2>&1 &
    pids+=("$!")
  done

  local status=0
  local pid
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      status=1
    fi
  done
  if (( status != 0 )); then
    echo "$strategy generation failed; inspect $strategy_log" >&2
    return 1
  fi

  "${common[@]}" --resume --progress-every 50 \
    >"$strategy_log/finalize.log" 2>&1
  echo "$strategy raw generation complete: $raw_dir"
}

filter_strategy() {
  local strategy=$1
  local raw_dir="$output_root/$strategy/raw"
  local gap_dir="$output_root/$strategy/gap32"
  local strategy_log="$log_dir/$strategy"
  local -a verify=()

  if [[ -e $gap_dir ]]; then
    if [[ ! -f $gap_dir/slot_gap_filter_report.json ]]; then
      echo "refusing incomplete existing filtered directory: $gap_dir" >&2
      return 1
    fi
    verify+=(--verify-existing)
  fi

  python3 "$script_dir/filter_capella_suite_by_slot_gap.py" \
    --in-dir "$raw_dir" \
    --out-dir "$gap_dir" \
    --max-gap 32 \
    "${verify[@]}" \
    >"$strategy_log/filter_gap32.log" 2>&1
  echo "$strategy gap32 suite complete: $gap_dir"
}

# Run strategies sequentially so the default does not multiply memory and I/O
# pressure.  Each strategy is independently parallelized over seed shards.
for strategy in random extreme; do
  generate_strategy "$strategy"
  filter_strategy "$strategy"
done

python3 "$script_dir/validate_capella_rq3_baselines.py" "$output_root" \
  --report "$output_root/reproduction_report.json" \
  >"$log_dir/validate_reproduction.log" 2>&1

echo "RQ3 Random/Extreme reproduction complete: $output_root"
echo "validation report: $output_root/reproduction_report.json"
