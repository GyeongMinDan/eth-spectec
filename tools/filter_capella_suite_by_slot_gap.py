#!/usr/bin/env python3
"""
Create or verify a Capella suite filtered by an exact slot-gap bound.

All slot arithmetic and JSON handling use Python ``int`` so Capella uint64 values remain exact.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import shutil
from pathlib import Path
from typing import Any, Iterable


BEACON_STATE_SLOT_OFFSET = 8 + 32
SIGNED_BLOCK_MESSAGE_OFFSET_POSITION = 0
SIGNED_BLOCK_FIXED_LENGTH = 4 + 96


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--metadata-dir", type=Path)
    parser.add_argument("--max-gap", type=int, default=32)
    parser.add_argument(
        "--verify-existing",
        action="store_true",
        help="verify an already materialized filtered suite instead of creating it",
    )
    return parser.parse_args()


def case_dirs(root: Path) -> list[tuple[str, str, Path]]:
    result: list[tuple[str, str, Path]] = []
    for seed_dir in sorted(item for item in root.iterdir() if item.is_dir()):
        for case_dir in sorted(item for item in seed_dir.iterdir() if item.is_dir()):
            if (case_dir / "pre.ssz").is_file() and (case_dir / "blocks_0.ssz").is_file():
                result.append((seed_dir.name, case_dir.name, case_dir))
    return result


def read_exact_slots(case_dir: Path) -> tuple[int, int]:
    with (case_dir / "pre.ssz").open("rb") as state_file:
        state_file.seek(BEACON_STATE_SLOT_OFFSET)
        state_slot_bytes = state_file.read(8)
    if len(state_slot_bytes) != 8:
        raise ValueError(f"truncated BeaconState SSZ: {case_dir / 'pre.ssz'}")
    state_slot = int.from_bytes(state_slot_bytes, "little", signed=False)

    with (case_dir / "blocks_0.ssz").open("rb") as block_file:
        fixed = block_file.read(SIGNED_BLOCK_FIXED_LENGTH + 8)
    if len(fixed) < SIGNED_BLOCK_FIXED_LENGTH + 8:
        raise ValueError(f"truncated SignedBeaconBlock SSZ: {case_dir / 'blocks_0.ssz'}")
    message_offset = int.from_bytes(
        fixed[SIGNED_BLOCK_MESSAGE_OFFSET_POSITION : SIGNED_BLOCK_MESSAGE_OFFSET_POSITION + 4],
        "little",
        signed=False,
    )
    if message_offset != SIGNED_BLOCK_FIXED_LENGTH:
        raise ValueError(
            f"unexpected SignedBeaconBlock.message offset {message_offset}, "
            f"expected {SIGNED_BLOCK_FIXED_LENGTH}: {case_dir / 'blocks_0.ssz'}"
        )
    block_slot = int.from_bytes(fixed[message_offset : message_offset + 8], "little", signed=False)
    return state_slot, block_slot


def link_or_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)
    except OSError as error:
        if error.errno not in (errno.EXDEV, errno.EPERM, errno.EACCES):
            raise
        shutil.copy2(source, destination)


def write_json_atomic(path: Path, value: Any) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def write_jsonl_atomic(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as output:
        for row in rows:
            output.write(json.dumps(row, separators=(",", ":"), ensure_ascii=False))
            output.write("\n")
    temporary.replace(path)


def main() -> None:
    args = parse_args()
    metadata_dir = args.metadata_dir or args.out_dir
    raw_rows: list[dict[str, Any]] = json.loads(
        (args.in_dir / "manifest.json").read_text(encoding="utf-8")
    )
    manifest_by_id = {
        (row["seed_name"], row["case_name"]): row for row in raw_rows
    }
    if len(manifest_by_id) != len(raw_rows):
        raise RuntimeError("duplicate (seed_name, case_name) entries in raw manifest")

    all_cases = case_dirs(args.in_dir)
    if len(all_cases) != len(raw_rows):
        raise RuntimeError(
            f"raw case/manifest count mismatch: cases={len(all_cases)}, manifest={len(raw_rows)}"
        )

    kept_ids: set[tuple[str, str]] = set()
    excluded_records: list[dict[str, Any]] = []
    for seed_name, case_name, source_dir in all_cases:
        case_id = (seed_name, case_name)
        row = manifest_by_id.get(case_id)
        if row is None:
            raise RuntimeError(f"case missing from raw manifest: {seed_name}/{case_name}")
        state_slot, block_slot = read_exact_slots(source_dir)
        gap = block_slot - state_slot
        recorded = (int(row["state_slot"]), int(row["block_slot"]), int(row["slot_gap"]))
        if recorded != (state_slot, block_slot, gap):
            raise RuntimeError(
                f"raw manifest slot mismatch for {seed_name}/{case_name}: "
                f"manifest={recorded}, SSZ={(state_slot, block_slot, gap)}"
            )

        if gap > args.max_gap:
            excluded_records.append(
                {
                    "seedName": seed_name,
                    "caseName": case_name,
                    "caseDir": str(source_dir),
                    "stateSlot": state_slot,
                    "blockSlot": block_slot,
                    "gap": gap,
                }
            )
            continue

        kept_ids.add(case_id)
        if not args.verify_existing:
            destination_dir = args.out_dir / seed_name / case_name
            for source in sorted(item for item in source_dir.iterdir() if item.is_file()):
                link_or_copy(source, destination_dir / source.name)

    expected_ids = kept_ids
    if args.verify_existing:
        actual_ids = {(seed, case) for seed, case, _path in case_dirs(args.out_dir)}
        if actual_ids != expected_ids:
            missing = sorted(expected_ids - actual_ids)[:10]
            unexpected = sorted(actual_ids - expected_ids)[:10]
            raise RuntimeError(
                f"filtered suite mismatch: missing={missing}, unexpected={unexpected}"
            )

    kept_rows = [
        row for row in raw_rows if (row["seed_name"], row["case_name"]) in kept_ids
    ]
    kept_gaps = [int(row["slot_gap"]) for row in kept_rows]
    excluded_gaps = [record["gap"] for record in excluded_records]
    report = {
        "input_dir": str(args.in_dir),
        "output_dir": str(args.out_dir),
        "max_gap": args.max_gap,
        "filter_condition": f"exclude slot_gap > {args.max_gap}; keep slot_gap <= {args.max_gap}",
        "integer_encoding": "exact Python JSON integers; no JavaScript Number narrowing",
        "slot_source": "exact uint64 values read from SSZ with Python int.from_bytes",
        "total_cases": len(raw_rows),
        "kept_cases": len(kept_rows),
        "excluded_cases": len(excluded_records),
        "kept_max_gap": max(kept_gaps),
        "kept_at_max_gap": sum(gap == args.max_gap for gap in kept_gaps),
        "excluded_min_gap": min(excluded_gaps) if excluded_gaps else None,
        "excluded": excluded_records,
    }

    metadata_dir.mkdir(parents=True, exist_ok=True)
    write_json_atomic(metadata_dir / "manifest.json", kept_rows)
    write_jsonl_atomic(metadata_dir / "manifest.jsonl", kept_rows)
    write_json_atomic(metadata_dir / "slot_gap_filter_report.json", report)
    print(
        json.dumps(
            {
                "total": len(raw_rows),
                "kept": len(kept_rows),
                "excluded": len(excluded_records),
                "kept_max_gap": report["kept_max_gap"],
                "kept_at_max_gap": report["kept_at_max_gap"],
                "excluded_min_gap": report["excluded_min_gap"],
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
