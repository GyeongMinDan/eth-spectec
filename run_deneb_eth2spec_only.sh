#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

DENEB_ETH2SPECTEC_DIR="${DENEB_ETH2SPECTEC_DIR:-/workspace/spectec-core/ssz_deneb_03141641_3/testgen/spectec-generated}"
OUTPUT_BASE="${OUTPUT_BASE:-$ROOT_DIR/results_deneb/eth2spec_only}"
WORKFLOW="${WORKFLOW:-sequential}"
VERBOSE="${VERBOSE:-0}"

mkdir -p "$OUTPUT_BASE"

CMD=(
  python3 run_test_suite.py
  --eth2spec-only
  --test-suite "$DENEB_ETH2SPECTEC_DIR"
  --test-type state-transition
  --fork-version deneb
  --output-base "$OUTPUT_BASE"
  --converter-dir "$ROOT_DIR/Converter"
  --workflow "$WORKFLOW"
)

if [ "$VERBOSE" = "1" ]; then
  CMD+=( -v )
fi

echo "[Deneb eth2spec-only]"
echo "  suite    : $DENEB_ETH2SPECTEC_DIR"
echo "  output   : $OUTPUT_BASE"
echo "  workflow : $WORKFLOW"
echo "  verbose  : $VERBOSE"

echo
printf 'Running command:'
printf ' %q' "${CMD[@]}"
echo

action_output="$OUTPUT_BASE/run_deneb_eth2spec_only.command.txt"
printf '%q ' "${CMD[@]}" > "$action_output"
printf '\n' >> "$action_output"

exec "${CMD[@]}"
