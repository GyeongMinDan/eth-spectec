#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

CLIENT_DIRS = ["lighthouse", "prysm", "nimbus", "teku", "lodestar", "eth2spec"]
DISPLAY_NAMES = {
    "lighthouse": "Lighthouse",
    "prysm": "Prysm",
    "nimbus": "Nimbus",
    "teku": "Teku",
    "lodestar": "Lodestar",
    "eth2spec": "Eth2spec",
}

SCRIPT_DIR = Path(__file__).resolve().parent
PYSPEC = SCRIPT_DIR / "consensus-specs" / "tests" / "core" / "pyspec"
if str(PYSPEC) not in sys.path:
    sys.path.insert(0, str(PYSPEC))

from eth2spec.capella.mainnet import BeaconState as CapellaBeaconState  # noqa: E402
from remerkleable.basic import boolean, bit, uint8, uint16, uint32, uint64, uint128, uint256  # noqa: E402
from remerkleable.byte_arrays import ByteVector, ByteList  # noqa: E402
from remerkleable.bitfields import Bitlist, Bitvector  # noqa: E402
from remerkleable.complex import Container, List, Vector  # noqa: E402

BASIC_INT_TYPES = (uint8, uint16, uint32, uint64, uint128, uint256)
BASIC_BOOL_TYPES = (boolean, bit)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check postState mismatches from a single diff_testing result root, including Eth2spec."
    )
    parser.add_argument("base_dir", help="Root directory containing result folders with Output_Status_*.csv")
    parser.add_argument(
        "--output-json",
        default=None,
        help="Path to save JSON report (default: <base_dir>/poststate_mismatches_report.json)",
    )
    parser.add_argument(
        "--relpath-list",
        default=None,
        help="Optional text file of relative case paths/names to include",
    )
    parser.add_argument(
        "--skip-structural-diff",
        action="store_true",
        help="Skip detailed BeaconState structural diffs",
    )
    parser.add_argument(
        "--max-structural-diffs",
        type=int,
        default=40,
        help="Maximum structural diff lines per representative comparison (0 or less = unlimited)",
    )
    parser.add_argument(
        "--hex-max",
        type=int,
        default=64,
        help="Maximum displayed hex length in structural diff summaries",
    )
    return parser.parse_args()


def load_relpath_list(path: Path | None) -> set[str] | None:
    if path is None:
        return None
    allowed: set[str] = set()
    with path.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            allowed.add(line.replace("\\", "/").replace("/", "_"))
    return allowed


def discover_case_dirs(base_dir: Path) -> list[Path]:
    case_dirs: set[Path] = set()
    for status_csv in base_dir.rglob("Output_Status_*.csv"):
        case_dirs.add(status_csv.parent)
    return sorted(case_dirs)


def collect_indices(case_dir: Path) -> set[str]:
    indices: set[str] = set()
    for client in CLIENT_DIRS:
        out = case_dir / client / "output"
        if not out.is_dir():
            continue
        for p in out.glob("poststate_*.ssz"):
            stem = p.stem
            if stem.startswith("poststate_"):
                indices.add(stem[len("poststate_"):])
    return indices


def load_poststates(case_dir: Path, index: str) -> tuple[dict[str, bytes], dict[str, str]]:
    blobs: dict[str, bytes] = {}
    paths: dict[str, str] = {}
    for client in CLIENT_DIRS:
        path = case_dir / client / "output" / f"poststate_{index}.ssz"
        if not path.is_file() or path.stat().st_size == 0:
            continue
        blobs[client] = path.read_bytes()
        paths[client] = str(path.resolve())
    return blobs, paths


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _to_hex(b: bytes) -> str:
    return "0x" + b.hex()


def bitfield_to_bool_list(v) -> list[bool]:
    return [bool(v.get(i)) for i in range(v.length())]


def view_to_jsonable(v: Any) -> Any:
    if isinstance(v, Container):
        return {fname: view_to_jsonable(getattr(v, fname)) for fname in v.fields()}
    if isinstance(v, (Vector, List)):
        return [view_to_jsonable(e) for e in v]
    if isinstance(v, (ByteVector, ByteList)):
        return _to_hex(bytes(v))
    if isinstance(v, (Bitvector, Bitlist)):
        return bitfield_to_bool_list(v)
    if isinstance(v, BASIC_INT_TYPES):
        return int(v)
    if isinstance(v, BASIC_BOOL_TYPES):
        return bool(v)
    if isinstance(v, (int, bool)):
        return v
    if isinstance(v, (bytes, bytearray, memoryview)):
        return _to_hex(bytes(v))
    if v is None:
        return None
    get = getattr(v, "get", None)
    if callable(get):
        try:
            return view_to_jsonable(get())
        except Exception:
            pass
    return str(v)


def decode_ssz(path: str) -> Any:
    with open(path, "rb") as f:
        raw = f.read()
    view = CapellaBeaconState.decode_bytes(raw)
    return view_to_jsonable(view)


def _fmt_val(x: Any, hex_max: int) -> str:
    if isinstance(x, str) and x.startswith("0x") and len(x) > hex_max + 2:
        return x[: hex_max + 2] + f"…({len(x) - 2} hex chars)"
    if isinstance(x, list) and len(x) > 24:
        return f"[len={len(x)}] …"
    try:
        s = json.dumps(x, ensure_ascii=False)
    except TypeError:
        s = repr(x)
    if len(s) > 200:
        return s[:200] + "…"
    return s


def _diff_limit_reached(out: list[str], max_reports: int) -> bool:
    return max_reports > 0 and len(out) >= max_reports


def diff_jsonable(a: Any, b: Any, path: str, out: list[str], max_reports: int, hex_max: int) -> None:
    if _diff_limit_reached(out, max_reports):
        return

    if type(a) is not type(b):
        out.append(f"{path}: type differs {type(a).__name__} vs {type(b).__name__}")
        out.append(f"  A: {_fmt_val(a, hex_max)}")
        out.append(f"  B: {_fmt_val(b, hex_max)}")
        return

    if isinstance(a, dict):
        keys = sorted(set(a) | set(b))
        for key in keys:
            if _diff_limit_reached(out, max_reports):
                return
            current_path = f"{path}.{key}" if path else key
            if key not in a:
                out.append(f"{current_path}: only in B")
                continue
            if key not in b:
                out.append(f"{current_path}: only in A")
                continue
            diff_jsonable(a[key], b[key], current_path, out, max_reports, hex_max)
        return

    if isinstance(a, list):
        if len(a) != len(b):
            out.append(f"{path}: list length differs len(A)={len(a)} len(B)={len(b)}")
            return
        for i, (left, right) in enumerate(zip(a, b)):
            if _diff_limit_reached(out, max_reports):
                return
            if left == right:
                continue
            diff_jsonable(left, right, f"{path}[{i}]", out, max_reports, hex_max)
        return

    if a != b:
        out.append(f"{path}:")
        out.append(f"  A: {_fmt_val(a, hex_max)}")
        out.append(f"  B: {_fmt_val(b, hex_max)}")


def structural_diff_ssz_paths(path_a: str, path_b: str, max_diffs: int = 0, hex_max: int = 64) -> list[str]:
    left = decode_ssz(path_a)
    right = decode_ssz(path_b)
    out: list[str] = []
    diff_jsonable(left, right, "", out, max_diffs, hex_max)
    return out


def build_case_record(
    case_dir: Path,
    index: str,
    max_structural_diffs: int,
    hex_max: int,
    skip_structural_diff: bool,
) -> dict[str, Any] | None:
    blobs, paths = load_poststates(case_dir, index)
    present = [client for client in CLIENT_DIRS if client in blobs]
    missing = [client for client in CLIENT_DIRS if client not in blobs]

    if len(present) < 2:
        return None

    groups: dict[str, list[str]] = defaultdict(list)
    for client, data in blobs.items():
        groups[sha256_hex(data)].append(client)

    if len(groups) == 1:
        return None

    sorted_groups = sorted(groups.items(), key=lambda item: min(CLIENT_DIRS.index(c) for c in item[1]))
    record: dict[str, Any] = {
        "case_dir": str(case_dir.resolve()),
        "case_name": case_dir.name,
        "index": index,
        "status": "multiple_byte_groups",
        "present": [DISPLAY_NAMES[c] for c in present],
        "missing": [DISPLAY_NAMES[c] for c in missing],
        "actor_paths": {DISPLAY_NAMES[c]: paths[c] for c in present},
        "byte_groups": [
            {
                "sha256": full_hash,
                "sha256_prefix16": full_hash[:16],
                "actors": [DISPLAY_NAMES[c] for c in sorted(clients, key=CLIENT_DIRS.index)],
            }
            for full_hash, clients in sorted_groups
        ],
        "pairwise_byte_mismatches": [],
        "structural_diffs": [],
    }

    for i in range(len(present)):
        for j in range(i + 1, len(present)):
            a = present[i]
            b = present[j]
            if blobs[a] != blobs[b]:
                record["pairwise_byte_mismatches"].append(f"{DISPLAY_NAMES[a]} != {DISPLAY_NAMES[b]}")

    if not skip_structural_diff:
        ref_hash, ref_clients = sorted_groups[0]
        ref_actor = sorted(ref_clients, key=CLIENT_DIRS.index)[0]
        ref_path = case_dir / ref_actor / "output" / f"poststate_{index}.ssz"
        for other_hash, other_clients in sorted_groups[1:]:
            other_actor = sorted(other_clients, key=CLIENT_DIRS.index)[0]
            other_path = case_dir / other_actor / "output" / f"poststate_{index}.ssz"
            entry = {
                "reference_group_actors": [DISPLAY_NAMES[c] for c in sorted(ref_clients, key=CLIENT_DIRS.index)],
                "other_group_actors": [DISPLAY_NAMES[c] for c in sorted(other_clients, key=CLIENT_DIRS.index)],
                "representative_a": DISPLAY_NAMES[ref_actor],
                "representative_b": DISPLAY_NAMES[other_actor],
                "reference_sha256_prefix16": ref_hash[:16],
                "other_sha256_prefix16": other_hash[:16],
                "path_a": str(ref_path.resolve()),
                "path_b": str(other_path.resolve()),
            }
            try:
                entry["diff_lines"] = structural_diff_ssz_paths(
                    str(ref_path), str(other_path), max_structural_diffs, hex_max
                )
                entry["ok"] = True
                entry["error"] = None
            except Exception as exc:
                entry["diff_lines"] = []
                entry["ok"] = False
                entry["error"] = str(exc)
            record["structural_diffs"].append(entry)

    return record


def main() -> None:
    args = parse_args()
    base_dir = Path(args.base_dir).resolve()
    if not base_dir.is_dir():
        raise SystemExit(f"Not a directory: {base_dir}")

    allowed_tests = load_relpath_list(Path(args.relpath_list).resolve()) if args.relpath_list else None
    output_json = Path(args.output_json).resolve() if args.output_json else (base_dir / "poststate_mismatches_report.json")

    if not args.skip_structural_diff and not PYSPEC.is_dir():
        raise SystemExit(f"consensus-specs pyspec path not found: {PYSPEC}")

    records: list[dict[str, Any]] = []
    for case_dir in discover_case_dirs(base_dir):
        case_key = case_dir.relative_to(base_dir).as_posix().replace("/", "_")
        if allowed_tests is not None and case_key not in allowed_tests and case_dir.name not in allowed_tests:
            continue
        for index in sorted(collect_indices(case_dir), key=lambda x: int(x) if str(x).isdigit() else x):
            record = build_case_record(
                case_dir=case_dir,
                index=index,
                max_structural_diffs=args.max_structural_diffs,
                hex_max=args.hex_max,
                skip_structural_diff=args.skip_structural_diff,
            )
            if record is not None:
                records.append(record)

    payload = {
        "summary": {
            "base_dir": str(base_dir),
            "poststate_mismatch_count": len(records),
            "actors": [DISPLAY_NAMES[c] for c in CLIENT_DIRS],
            "structural_diff_enabled": not args.skip_structural_diff,
            "max_structural_diffs": args.max_structural_diffs,
            "hex_max": args.hex_max,
        },
        "poststate_mismatches": records,
    }

    output_json.parent.mkdir(parents=True, exist_ok=True)
    with output_json.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    print("=" * 80)
    print("check_postState completed")
    print("=" * 80)
    print(f"base_dir: {base_dir}")
    if args.relpath_list:
        print(f"relpath filter: {Path(args.relpath_list).resolve()}")
    print(f"poststate mismatches: {len(records)}")
    print(f"json: {output_json}")


if __name__ == "__main__":
    main()
