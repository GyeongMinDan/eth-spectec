#!/usr/bin/env python3
"""Validate the deterministic Capella Random/Extreme RQ3 reproduction.

The generator performs SSZ serialization and deserialize/serialize round-trip
checks while creating every case.  This validator checks the campaign-level
contract: the RQ3 budget profile, contiguous case indices, no final no-ops,
the exact gap-32 subsets, and identical Random/Extreme selections.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


EXPECTED_RAW_CASES = 21_444
EXPECTED_GAP32_CASES = {"random": 20_557, "extreme": 20_670}
EXPECTED_PER_SEED_BUDGETS = {38: 77, 37: 374, 36: 130}
EXPECTED_MASTER_SEED = "SpecTrum-ASE2026-camera-ready-path-uniform-v1"
EXPECTED_SEED_MANIFEST_SHA256 = (
    "544db4ae7f549159683ce9000ad49774bed225f9b614226584e7c4d9066850e9"
)
EXPECTED_CONSENSUS_SPECS_COMMIT = "f96d3e7acf35125295d234da4b0c67591fdef49c"
EXPECTED_PYTHON_VERSION = "3.10.12"
EXPECTED_BUDGET_PHASES = [19_624, 1_820]
EXPECTED_STATE_PATHS = 65
EXPECTED_BLOCK_PATHS = 80
SELECTION_FIELDS = (
    "target_object",
    "normalized_path",
    "concrete_indices",
    "concrete_tokens",
    "ssz_type",
    "prng_case_seed",
    "prng_selection_seed",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate generated Capella RQ3 Random/Extreme suites"
    )
    parser.add_argument(
        "root",
        type=Path,
        help="root containing random/{raw,gap32} and extreme/{raw,gap32}",
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="output JSON report (default: ROOT/reproduction_report.json)",
    )
    return parser.parse_args()


def read_json(path: Path) -> Any:
    if not path.is_file():
        raise FileNotFoundError(path)
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def require_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def case_key(row: dict[str, Any]) -> tuple[str, int]:
    return row["seed_id"], int(row["case_index"])


def case_directory(root: Path, row: dict[str, Any]) -> Path:
    return root / row["seed_id"] / row["case_name"]


def validate_raw(
    root: Path, strategy: str
) -> tuple[list[dict[str, Any]], dict[tuple[str, int], dict[str, Any]], dict[str, Any]]:
    config = read_json(root / "generation_config.json")
    summary = read_json(root / "summary.json")
    universe = read_json(root / "path_universe.json")
    rows = read_json(root / "manifest.json")
    if not isinstance(rows, list):
        raise TypeError(f"manifest must be a list: {root / 'manifest.json'}")

    expected_config = {
        "strategy": strategy,
        "master_seed": EXPECTED_MASTER_SEED,
        "python_version": EXPECTED_PYTHON_VERSION,
        "consensus_specs_tag": "v1.6.0",
        "consensus_specs_commit": EXPECTED_CONSENSUS_SPECS_COMMIT,
        "eth2spec_version": "1.6.0",
        "seed_manifest_sha256": EXPECTED_SEED_MANIFEST_SHA256,
        "total_budget": EXPECTED_RAW_CASES,
        "budget_profile": "paper-rq3",
        "budget_phases": EXPECTED_BUDGET_PHASES,
        "state_path_count": EXPECTED_STATE_PATHS,
        "block_path_count": EXPECTED_BLOCK_PATHS,
        "combined_path_count": EXPECTED_STATE_PATHS + EXPECTED_BLOCK_PATHS,
        "mutation_unit": "one_normalized_atomic_path",
        "selection": "uniform_over_seed_realizable_normalized_paths",
        "block_scope": "SignedBeaconBlock.message_only",
        "slot_gap_policy": "record_only_filter_at_testing",
        "testing_max_slot_gap": 32,
    }
    for field, expected in expected_config.items():
        require_equal(config.get(field), expected, f"{strategy} config {field}")

    require_equal(
        universe.get("state_path_count"), EXPECTED_STATE_PATHS, f"{strategy} state paths"
    )
    require_equal(
        universe.get("block_path_count"), EXPECTED_BLOCK_PATHS, f"{strategy} block paths"
    )
    require_equal(
        universe.get("combined_path_count"),
        EXPECTED_STATE_PATHS + EXPECTED_BLOCK_PATHS,
        f"{strategy} combined paths",
    )
    require_equal(len(rows), EXPECTED_RAW_CASES, f"{strategy} raw manifest rows")
    require_equal(summary.get("attempted_cases"), EXPECTED_RAW_CASES, f"{strategy} attempts")
    require_equal(summary.get("successful_cases"), EXPECTED_RAW_CASES, f"{strategy} successes")
    require_equal(summary.get("serialization_failures"), 0, f"{strategy} failures")
    require_equal(summary.get("noop_final_cases"), 0, f"{strategy} final no-ops")
    require_equal(summary.get("attempt_accounting_ok"), True, f"{strategy} accounting")

    indexed: dict[tuple[str, int], dict[str, Any]] = {}
    per_seed: dict[str, list[int]] = defaultdict(list)
    for row in rows:
        key = case_key(row)
        if key in indexed:
            raise RuntimeError(f"duplicate {strategy} seed/case index: {key}")
        indexed[key] = row
        per_seed[key[0]].append(key[1])

        require_equal(row.get("strategy"), strategy, f"{strategy} row strategy {key}")
        require_equal(row.get("roundtrip_verified"), True, f"{strategy} roundtrip {key}")
        if row.get("old_value") == row.get("new_value"):
            raise RuntimeError(f"final no-op in {strategy}: {key}")
        if int(row["block_slot"]) - int(row["state_slot"]) != int(row["slot_gap"]):
            raise RuntimeError(f"slot-gap arithmetic mismatch in {strategy}: {key}")
        target = row.get("target_object")
        if target not in {"state", "block"}:
            raise RuntimeError(f"invalid target object in {strategy}: {key}: {target!r}")
        if not str(row.get("normalized_path", "")).startswith(target + "."):
            raise RuntimeError(f"target/path mismatch in {strategy}: {key}")
        if strategy == "extreme" and not row.get("extreme_candidate"):
            raise RuntimeError(f"missing extreme candidate label: {key}")

        directory = case_directory(root, row)
        for name in ("pre.ssz", "blocks_0.ssz", "mutation.json"):
            if not (directory / name).is_file():
                raise FileNotFoundError(directory / name)

    budget_histogram = Counter(len(indices) for indices in per_seed.values())
    require_equal(len(per_seed), 581, f"{strategy} seed count")
    require_equal(dict(budget_histogram), EXPECTED_PER_SEED_BUDGETS, f"{strategy} budgets")
    for seed_id, indices in per_seed.items():
        ordered = sorted(indices)
        require_equal(
            ordered,
            list(range(len(ordered))),
            f"{strategy} contiguous indices for {seed_id}",
        )

    details = {
        "raw_cases": len(rows),
        "seed_count": len(per_seed),
        "per_seed_budget_histogram": {
            str(count): seeds for count, seeds in sorted(budget_histogram.items())
        },
        "state_mutated_cases": summary.get("state_mutated_cases"),
        "block_mutated_cases": summary.get("block_mutated_cases"),
        "slot_gap_excluded_at_testing": summary.get("slot_gap_excluded_at_testing"),
    }
    return rows, indexed, details


def validate_gap32(
    root: Path,
    strategy: str,
    raw_rows: list[dict[str, Any]],
) -> dict[str, Any]:
    rows = read_json(root / "manifest.json")
    report = read_json(root / "slot_gap_filter_report.json")
    expected_rows = [row for row in raw_rows if int(row["slot_gap"]) <= 32]
    expected_keys = {case_key(row) for row in expected_rows}
    actual_keys = {case_key(row) for row in rows}

    require_equal(len(rows), EXPECTED_GAP32_CASES[strategy], f"{strategy} gap32 rows")
    require_equal(actual_keys, expected_keys, f"{strategy} exact gap32 subset")
    require_equal(report.get("max_gap"), 32, f"{strategy} gap bound")
    require_equal(report.get("total_cases"), EXPECTED_RAW_CASES, f"{strategy} filter total")
    require_equal(report.get("kept_cases"), len(rows), f"{strategy} filter kept")
    require_equal(
        report.get("excluded_cases"),
        EXPECTED_RAW_CASES - len(rows),
        f"{strategy} filter excluded",
    )
    if any(int(row["slot_gap"]) > 32 for row in rows):
        raise RuntimeError(f"slot_gap > 32 survived in {strategy} gap32 suite")

    for row in rows:
        directory = case_directory(root, row)
        if not (directory / "pre.ssz").is_file() or not (
            directory / "blocks_0.ssz"
        ).is_file():
            raise FileNotFoundError(directory)

    return {
        "kept_cases": len(rows),
        "excluded_cases": EXPECTED_RAW_CASES - len(rows),
        "kept_max_gap": report.get("kept_max_gap"),
        "excluded_min_gap": report.get("excluded_min_gap"),
    }


def selection_tuple(row: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(
        tuple(row[field]) if isinstance(row[field], list) else row[field]
        for field in SELECTION_FIELDS
    )


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    report_path = (args.report or root / "reproduction_report.json").resolve()

    raw: dict[str, list[dict[str, Any]]] = {}
    indexed: dict[str, dict[tuple[str, int], dict[str, Any]]] = {}
    result: dict[str, Any] = {
        "status": "complete",
        "passed": False,
        "expected_raw_budget_per_strategy": EXPECTED_RAW_CASES,
        "budget_profile": "paper-rq3",
        "budget_phases": EXPECTED_BUDGET_PHASES,
        "strategies": {},
    }

    for strategy in ("random", "extreme"):
        raw_root = root / strategy / "raw"
        gap_root = root / strategy / "gap32"
        rows, by_key, raw_details = validate_raw(raw_root, strategy)
        raw[strategy] = rows
        indexed[strategy] = by_key
        result["strategies"][strategy] = {
            "raw": raw_details,
            "gap32": validate_gap32(gap_root, strategy, rows),
        }

    require_equal(
        set(indexed["random"]), set(indexed["extreme"]), "Random/Extreme case keys"
    )
    mismatches: list[dict[str, Any]] = []
    for key in sorted(indexed["random"]):
        random_row = indexed["random"][key]
        extreme_row = indexed["extreme"][key]
        if selection_tuple(random_row) != selection_tuple(extreme_row):
            mismatches.append({"seed_id": key[0], "case_index": key[1]})
            if len(mismatches) >= 20:
                break
    if mismatches:
        raise RuntimeError(f"Random/Extreme selection mismatches: {mismatches}")

    result["random_extreme_selection"] = {
        "shared_cases": len(indexed["random"]),
        "exact_matches": len(indexed["random"]),
        "mismatches": 0,
        "fields": list(SELECTION_FIELDS),
    }
    result["passed"] = True
    atomic_write_json(report_path, result)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
