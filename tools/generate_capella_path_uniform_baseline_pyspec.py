#!/usr/bin/env python3
"""
Generate deterministic Capella path-uniform random/extreme baselines.

This is deliberately separate from the historical concrete-leaf-uniform
generator.  Its selection universe is derived only from the public v1.6.0 SSZ
types.  Random and extreme runs share every selection, index-resolution,
no-op, serialization, and logging path; only ``ValueStrategy.candidates`` is
injected.

Suite layout (compatible with ``diff_testing.py``)::

    OUT/SEED/CASE/pre.ssz
    OUT/SEED/CASE/blocks_0.ssz
    OUT/SEED/CASE/mutation.json

Slot gaps greater than 32 are recorded, not rejected.  They are excluded only
when the testing-ready suite is built.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import platform
import random
import shutil
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, Protocol


TARGET_CONSENSUS_SPECS_TAG = "v1.6.0"
TARGET_ETH2SPEC_VERSION = "1.6.0"
GENERATOR_VERSION = "capella-path-uniform-camera-ready-v1"
DEFAULT_MASTER_SEED = "SpecTrum-ASE2026-camera-ready-path-uniform-v1"

TOTAL_BUDGET = 19_624
PAPER_RQ3_ADDITIONAL_BUDGET = 1_820
PAPER_RQ3_BUDGET_PHASES = (TOTAL_BUDGET, PAPER_RQ3_ADDITIONAL_BUDGET)
PAPER_RQ3_TOTAL_BUDGET = sum(PAPER_RQ3_BUDGET_PHASES)
EXPECTED_SEED_COUNT = 581
EXPECTED_STATE_PATH_COUNT = 65
DEFAULT_TESTING_MAX_SLOT_GAP = 32

STAR = "*"

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONSENSUS_SPECS_DIR = ROOT / "consensus-specs"
DEFAULT_SEED_DIR = ROOT / "results/rq3/capella_seed581"


class NoValueCandidates(Exception):
    """The selected unit cannot change while preserving its current shape."""


class SerializationFailure(Exception):
    """A typed candidate could not be serialized or round-tripped."""

    def __init__(self, message: str, details: dict[str, Any]):
        super().__init__(message)
        self.details = details


@dataclass(frozen=True)
class PathSpec:
    root: str
    tokens: tuple[str, ...]
    typ: type

    @property
    def normalized(self) -> str:
        text = self.root
        for token in self.tokens:
            if token == STAR:
                text += "[*]"
            else:
                text += f".{token}"
        return text


@dataclass(frozen=True)
class ValueCandidate:
    label: str
    value: Any


@dataclass(frozen=True)
class ResolvedPath:
    tokens: tuple[str | int, ...]
    indices: tuple[int, ...]
    retries: int


class ValueStrategy(Protocol):
    name: str

    def candidates(
        self,
        env: dict[str, Any],
        typ: type,
        old_value: Any,
        rng: random.Random,
        max_random_attempts: int,
    ) -> Iterable[ValueCandidate]:
        ...


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a deterministic v1.6.0 Capella path-uniform baseline"
    )
    parser.add_argument("--strategy", required=True, choices=["random", "extreme"])
    parser.add_argument("--seed-dir", type=Path, default=DEFAULT_SEED_DIR)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument(
        "--consensus-specs-dir", type=Path, default=DEFAULT_CONSENSUS_SPECS_DIR
    )
    parser.add_argument("--master-seed", default=DEFAULT_MASTER_SEED)
    parser.add_argument(
        "--budget-profile",
        choices=["paper-rq3", "uniform"],
        help=(
            "budget allocation profile; with neither this option nor "
            "--total-budget, defaults to paper-rq3"
        ),
    )
    parser.add_argument(
        "--total-budget",
        type=int,
        help=(
            "custom total attempts for the uniform profile; specifying this "
            "without --budget-profile selects uniform allocation"
        ),
    )
    parser.add_argument(
        "--case-index-starts",
        type=Path,
        help=(
            "optional JSON mapping from seed id to the first case index for this "
            "campaign; seed_case_counts.json from a preceding campaign is also "
            "accepted and continues after each expected_attempts value"
        ),
    )
    parser.add_argument("--testing-max-slot-gap", type=int, default=32)
    parser.add_argument("--max-random-value-attempts", type=int, default=16)
    parser.add_argument("--max-index-retries", type=int, default=128)
    parser.add_argument("--max-path-retries", type=int, default=1024)
    parser.add_argument("--limit-seeds", type=int)
    parser.add_argument("--limit-cases-per-seed", type=int)
    parser.add_argument(
        "--progress-every",
        type=int,
        default=10,
        help="print seed progress every N seeds (0 disables per-seed progress)",
    )
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--seed-shard-count",
        type=int,
        default=1,
        help="number of deterministic seed-level worker shards",
    )
    parser.add_argument(
        "--seed-shard-index",
        type=int,
        default=0,
        help="zero-based worker shard index (rows are selected as rows[index::count])",
    )
    parser.add_argument(
        "--defer-finalize",
        action="store_true",
        help="skip shared root manifests/summaries; use for parallel shards",
    )
    parser.add_argument(
        "--initialize-only",
        action="store_true",
        help="write or validate immutable root configuration and exit",
    )
    args = parser.parse_args()
    if args.budget_profile is None:
        args.budget_profile = "uniform" if args.total_budget is not None else "paper-rq3"
    if args.budget_profile == "paper-rq3":
        if args.total_budget not in (None, PAPER_RQ3_TOTAL_BUDGET):
            parser.error(
                "--budget-profile paper-rq3 has a fixed total budget of "
                f"{PAPER_RQ3_TOTAL_BUDGET}"
            )
        if args.case_index_starts is not None:
            parser.error("--case-index-starts cannot be combined with paper-rq3")
        args.total_budget = PAPER_RQ3_TOTAL_BUDGET
    else:
        args.total_budget = TOTAL_BUDGET if args.total_budget is None else args.total_budget
    if args.progress_every < 0:
        parser.error("--progress-every must be non-negative")
    if args.total_budget <= 0:
        parser.error("--total-budget must be positive")
    if args.seed_shard_count < 1:
        parser.error("--seed-shard-count must be at least 1")
    if not 0 <= args.seed_shard_index < args.seed_shard_count:
        parser.error(
            "--seed-shard-index must be in [0, --seed-shard-count)"
        )
    if args.seed_shard_count > 1 and not (
        args.defer_finalize or args.initialize_only or args.dry_run
    ):
        parser.error(
            "multi-shard generation requires --defer-finalize; run a normal "
            "non-sharded --resume command afterward to finalize"
        )
    if args.initialize_only and args.dry_run:
        parser.error("--initialize-only cannot be combined with --dry-run")
    return args


def require_file(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(path)


def require_dir(path: Path) -> None:
    if not path.is_dir():
        raise FileNotFoundError(path)


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            f.write("\n")
    os.replace(tmp, path)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git_output(repo: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), *args],
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()


def verify_consensus_specs_version(consensus_specs_dir: Path) -> dict[str, str]:
    require_dir(consensus_specs_dir)
    tag = git_output(consensus_specs_dir, "describe", "--tags", "--exact-match", "HEAD")
    commit = git_output(consensus_specs_dir, "rev-parse", "HEAD")
    version_path = consensus_specs_dir / "tests/core/pyspec/eth2spec/VERSION.txt"
    require_file(version_path)
    eth2spec_version = version_path.read_text(encoding="utf-8").strip()
    if tag != TARGET_CONSENSUS_SPECS_TAG or eth2spec_version != TARGET_ETH2SPEC_VERSION:
        raise RuntimeError(
            "consensus-specs version mismatch: "
            f"tag={tag!r}, VERSION.txt={eth2spec_version!r}; expected "
            f"{TARGET_CONSENSUS_SPECS_TAG}/{TARGET_ETH2SPEC_VERSION}"
        )
    return {"tag": tag, "commit": commit, "eth2spec_version": eth2spec_version}


def import_pyspec(consensus_specs_dir: Path) -> dict[str, Any]:
    pyspec_dir = consensus_specs_dir / "tests/core/pyspec"
    require_file(pyspec_dir / "eth2spec/capella/mainnet.py")
    sys.path.insert(0, str(pyspec_dir))

    from eth2spec.capella import mainnet as spec  # noqa: PLC0415
    from eth2spec.utils.ssz.ssz_impl import deserialize, serialize  # noqa: PLC0415
    from eth2spec.utils.ssz.ssz_typing import (  # noqa: PLC0415
        Bitlist,
        Bitvector,
        ByteList,
        ByteVector,
        Container,
        List,
        Vector,
        boolean,
        byte,
        uint,
    )

    return {
        "spec": spec,
        "deserialize": deserialize,
        "serialize": serialize,
        "Bitlist": Bitlist,
        "Bitvector": Bitvector,
        "ByteList": ByteList,
        "ByteVector": ByteVector,
        "Container": Container,
        "List": List,
        "Vector": Vector,
        "boolean": boolean,
        "byte": byte,
        "uint": uint,
    }


def is_atomic_type(env: dict[str, Any], typ: type) -> bool:
    return issubclass(
        typ,
        (
            env["boolean"],
            env["byte"],
            env["uint"],
            env["ByteVector"],
            env["ByteList"],
            env["Bitvector"],
            env["Bitlist"],
        ),
    )


def is_container_type(env: dict[str, Any], typ: type) -> bool:
    return issubclass(typ, env["Container"])


def is_indexed_sequence_type(env: dict[str, Any], typ: type) -> bool:
    if is_atomic_type(env, typ):
        return False
    return issubclass(typ, (env["List"], env["Vector"]))


def enumerate_paths(
    env: dict[str, Any],
    typ: type,
    root: str,
    tokens: tuple[str, ...] = (),
) -> list[PathSpec]:
    """Statically enumerate normalized atomic paths from an SSZ type."""
    if is_atomic_type(env, typ):
        return [PathSpec(root=root, tokens=tokens, typ=typ)]
    if is_container_type(env, typ):
        paths: list[PathSpec] = []
        for field_name, field_typ in typ.fields().items():
            paths.extend(
                enumerate_paths(env, field_typ, root, (*tokens, field_name))
            )
        return paths
    if is_indexed_sequence_type(env, typ):
        return enumerate_paths(env, typ.element_cls(), root, (*tokens, STAR))
    raise TypeError(f"unsupported SSZ type in path enumeration: {typ}")


def build_path_universe(
    env: dict[str, Any],
) -> tuple[list[PathSpec], list[PathSpec], list[PathSpec]]:
    spec = env["spec"]
    state_paths = enumerate_paths(env, spec.BeaconState, "state")
    block_paths = enumerate_paths(env, spec.BeaconBlock, "block")
    if len(state_paths) != EXPECTED_STATE_PATH_COUNT:
        raise AssertionError(
            f"Capella BeaconState path count must be 65, got {len(state_paths)}"
        )
    universe = [*state_paths, *block_paths]
    normalized = [path.normalized for path in universe]
    if len(normalized) != len(set(normalized)):
        raise AssertionError("duplicate normalized paths in the SSZ universe")
    return state_paths, block_paths, universe


def path_is_realizable(root: Any, tokens: tuple[str, ...], offset: int = 0) -> bool:
    if offset == len(tokens):
        return True
    token = tokens[offset]
    if token != STAR:
        return path_is_realizable(getattr(root, token), tokens, offset + 1)
    for index in range(len(root)):
        if path_is_realizable(root[index], tokens, offset + 1):
            return True
    return False


def realizable_paths(
    universe: list[PathSpec], state: Any, signed_block: Any
) -> tuple[list[PathSpec], list[str]]:
    roots = {"state": state, "block": signed_block.message}
    included: list[PathSpec] = []
    excluded: list[str] = []
    for path in universe:
        if path_is_realizable(roots[path.root], path.tokens):
            included.append(path)
        else:
            excluded.append(path.normalized)
    return included, excluded


def resolve_indices(
    root: Any,
    tokens: tuple[str, ...],
    rng: random.Random,
    max_retries: int,
) -> tuple[ResolvedPath | None, int]:
    """Resolve stars outside-in, retrying the enclosing index on empty inners."""
    retries = 0

    def walk(
        current: Any,
        offset: int,
        concrete: tuple[str | int, ...],
        indices: tuple[int, ...],
    ) -> tuple[tuple[str | int, ...], tuple[int, ...]] | None:
        nonlocal retries
        if offset == len(tokens):
            return concrete, indices
        token = tokens[offset]
        if token != STAR:
            return walk(
                getattr(current, token),
                offset + 1,
                (*concrete, token),
                indices,
            )
        length = len(current)
        if length == 0:
            return None
        for attempt in range(max_retries + 1):
            index = rng.randrange(length)
            result = walk(
                current[index],
                offset + 1,
                (*concrete, index),
                (*indices, index),
            )
            if result is not None:
                return result
            if attempt < max_retries:
                retries += 1
        return None

    result = walk(root, 0, (), ())
    if result is None:
        return None, retries
    concrete, indices = result
    return ResolvedPath(tokens=concrete, indices=indices, retries=retries), retries


def get_at(root: Any, tokens: tuple[str | int, ...]) -> Any:
    current = root
    for token in tokens:
        current = current[token] if isinstance(token, int) else getattr(current, token)
    return current


def set_at(root: Any, tokens: tuple[str | int, ...], value: Any) -> None:
    if not tokens:
        raise ValueError("top-level replacement is not supported")
    parent = get_at(root, tokens[:-1])
    last = tokens[-1]
    if isinstance(last, int):
        parent[last] = value
    else:
        setattr(parent, last, value)


def random_bytes(rng: random.Random, length: int) -> bytes:
    return bytes(rng.getrandbits(8) for _ in range(length))


def random_bits(rng: random.Random, length: int) -> list[bool]:
    return [bool(rng.getrandbits(1)) for _ in range(length)]


class RandomValueStrategy:
    name = "random"

    def gen_value(
        self, env: dict[str, Any], typ: type, old_value: Any, rng: random.Random
    ) -> ValueCandidate:
        if issubclass(typ, env["boolean"]):
            return ValueCandidate("uniform_boolean", typ(bool(rng.getrandbits(1))))
        if issubclass(typ, (env["byte"], env["uint"])):
            bits = typ.type_byte_length() * 8
            return ValueCandidate("uniform_uint", typ(rng.randrange(1 << bits)))
        if issubclass(typ, env["ByteVector"]):
            return ValueCandidate(
                "uniform_bytes", typ(random_bytes(rng, typ.vector_length()))
            )
        if issubclass(typ, env["ByteList"]):
            return ValueCandidate(
                "uniform_bytes_same_length", typ(random_bytes(rng, len(old_value)))
            )
        if issubclass(typ, env["Bitvector"]):
            return ValueCandidate(
                "uniform_bits",
                typ.from_obj(random_bits(rng, typ.vector_length())),
            )
        if issubclass(typ, env["Bitlist"]):
            return ValueCandidate(
                "uniform_bits_same_length",
                typ.from_obj(random_bits(rng, len(old_value))),
            )
        raise TypeError(f"unsupported random atomic SSZ type: {typ.type_repr()}")

    def candidates(
        self,
        env: dict[str, Any],
        typ: type,
        old_value: Any,
        rng: random.Random,
        max_random_attempts: int,
    ) -> Iterator[ValueCandidate]:
        for _ in range(max_random_attempts):
            yield self.gen_value(env, typ, old_value, rng)


class ExtremeValueStrategy:
    name = "extreme"

    @staticmethod
    def deduplicate_pool(
        env: dict[str, Any], candidates: list[ValueCandidate]
    ) -> list[ValueCandidate]:
        """Treat the documented extreme pool as a set of candidate values.

        Boundary formulas can coincide (for example, ``old + 1 == 1`` when
        ``old == 0``), and both patterns for a zero-length variable-size unit
        have the same encoding.  Keeping duplicate encodings would bias the
        uniform pool selection and cause a nominally different label to retry
        an identical value.
        """
        unique: list[ValueCandidate] = []
        seen: set[bytes] = set()
        for candidate in candidates:
            encoded = env["serialize"](candidate.value)
            if encoded not in seen:
                seen.add(encoded)
                unique.append(candidate)
        return unique

    def candidate_pool(
        self, env: dict[str, Any], typ: type, old_value: Any
    ) -> list[ValueCandidate]:
        if issubclass(typ, env["boolean"]):
            return [ValueCandidate("bool_flip", typ(not bool(old_value)))]
        if issubclass(typ, (env["byte"], env["uint"])):
            bits = typ.type_byte_length() * 8
            maximum = (1 << bits) - 1
            old = int(old_value)
            raw: list[tuple[str, int]] = [
                ("zero", 0),
                ("one", 1),
                ("max_minus_one", maximum - 1),
                ("max", maximum),
            ]
            if old > 0:
                raw.append(("old_minus_one", old - 1))
            if old < maximum:
                raw.append(("old_plus_one", old + 1))
            return self.deduplicate_pool(
                env, [ValueCandidate(label, typ(value)) for label, value in raw]
            )
        if issubclass(typ, env["ByteVector"]):
            length = typ.vector_length()
            return self.deduplicate_pool(env, [
                ValueCandidate("all_0x00", typ(bytes([0x00]) * length)),
                ValueCandidate("all_0xff", typ(bytes([0xFF]) * length)),
            ])
        if issubclass(typ, env["ByteList"]):
            length = len(old_value)
            return self.deduplicate_pool(env, [
                ValueCandidate("all_0x00", typ(bytes([0x00]) * length)),
                ValueCandidate("all_0xff", typ(bytes([0xFF]) * length)),
            ])
        if issubclass(typ, env["Bitvector"]):
            length = typ.vector_length()
            return self.deduplicate_pool(env, [
                ValueCandidate("all_false", typ.from_obj([False] * length)),
                ValueCandidate("all_true", typ.from_obj([True] * length)),
            ])
        if issubclass(typ, env["Bitlist"]):
            length = len(old_value)
            return self.deduplicate_pool(env, [
                ValueCandidate("all_false", typ.from_obj([False] * length)),
                ValueCandidate("all_true", typ.from_obj([True] * length)),
            ])
        raise TypeError(f"unsupported extreme atomic SSZ type: {typ.type_repr()}")

    def gen_value(
        self, env: dict[str, Any], typ: type, old_value: Any, rng: random.Random
    ) -> ValueCandidate:
        pool = self.candidate_pool(env, typ, old_value)
        if not pool:
            raise NoValueCandidates(typ.type_repr())
        return pool[rng.randrange(len(pool))]

    def candidates(
        self,
        env: dict[str, Any],
        typ: type,
        old_value: Any,
        rng: random.Random,
        max_random_attempts: int,
    ) -> Iterator[ValueCandidate]:
        del max_random_attempts
        pool = self.candidate_pool(env, typ, old_value)
        rng.shuffle(pool)
        yield from pool


def jsonable_value(env: dict[str, Any], value: Any) -> Any:
    if isinstance(value, env["boolean"]):
        return bool(value)
    if isinstance(value, (env["byte"], env["uint"])):
        return str(int(value))
    if isinstance(value, bytes):
        return "0x" + bytes(value).hex()
    if isinstance(value, (env["Bitvector"], env["Bitlist"])):
        return "0x" + env["serialize"](value).hex()
    return str(value)


def derive_seed(*parts: str) -> str:
    h = hashlib.sha256()
    for part in parts:
        encoded = part.encode("utf-8")
        h.update(len(encoded).to_bytes(8, "big"))
        h.update(encoded)
    return h.hexdigest()


def make_rng(seed_hex: str) -> random.Random:
    return random.Random(int(seed_hex, 16))


def uniform_budget_by_seed(seed_ids: list[str], total_budget: int) -> dict[str, int]:
    if len(seed_ids) != EXPECTED_SEED_COUNT:
        raise AssertionError(
            f"expected {EXPECTED_SEED_COUNT} seed ids, got {len(seed_ids)}"
        )
    if total_budget <= 0:
        raise ValueError("total_budget must be positive")
    base, remainder = divmod(total_budget, len(seed_ids))
    return {
        seed_id: base + (1 if index < remainder else 0)
        for index, seed_id in enumerate(sorted(seed_ids))
    }


def budget_by_seed(
    seed_ids: list[str],
    total_budget: int = TOTAL_BUDGET,
    budget_profile: str = "uniform",
) -> dict[str, int]:
    if budget_profile == "uniform":
        return uniform_budget_by_seed(seed_ids, total_budget)
    if budget_profile != "paper-rq3":
        raise ValueError(f"unknown budget profile: {budget_profile}")
    if total_budget != PAPER_RQ3_TOTAL_BUDGET:
        raise ValueError(
            f"paper-rq3 budget must be {PAPER_RQ3_TOTAL_BUDGET}, got {total_budget}"
        )

    # The paper-rq3 profile combines two deterministic, individually uniform
    # per-seed allocations into one contiguous 21,444-case campaign.
    budgets = {seed_id: 0 for seed_id in seed_ids}
    for phase_budget in PAPER_RQ3_BUDGET_PHASES:
        phase = uniform_budget_by_seed(seed_ids, phase_budget)
        for seed_id in seed_ids:
            budgets[seed_id] += phase[seed_id]
    if sum(budgets.values()) != PAPER_RQ3_TOTAL_BUDGET:
        raise AssertionError("paper-rq3 per-seed budget accounting failed")
    return budgets


def seed_shard_rows(
    selected_rows: list[dict[str, Any]], shard_count: int, shard_index: int
) -> list[dict[str, Any]]:
    """Return a deterministic, disjoint seed-level slice of logical rows."""
    if shard_count < 1:
        raise ValueError("shard_count must be at least 1")
    if not 0 <= shard_index < shard_count:
        raise ValueError("shard_index must be in [0, shard_count)")
    return selected_rows[shard_index::shard_count]


def load_seed_manifest(seed_dir: Path) -> tuple[list[dict[str, Any]], str]:
    manifest_path = seed_dir / "manifest.json"
    require_file(manifest_path)
    value = read_json(manifest_path)
    rows = value["seeds"] if isinstance(value, dict) and "seeds" in value else value
    if not isinstance(rows, list):
        raise TypeError(f"seed manifest must be a list: {manifest_path}")
    normalized: list[dict[str, Any]] = []
    for row in rows:
        seed_id = row.get("seed_id") or row.get("seed_name")
        if not seed_id:
            raise KeyError(f"seed row has no seed_id/seed_name: {row}")
        normalized.append({**row, "seed_id": seed_id})
    normalized.sort(key=lambda row: row["seed_id"])
    return normalized, sha256_file(manifest_path)


def load_case_index_starts(
    path: Path | None, seed_ids: list[str]
) -> tuple[dict[str, int], str | None]:
    if path is None:
        return {seed_id: 0 for seed_id in seed_ids}, None

    require_file(path)
    raw = read_json(path)
    if isinstance(raw, dict) and "case_index_starts" in raw:
        raw = raw["case_index_starts"]
    if not isinstance(raw, dict):
        raise TypeError(f"case-index starts must be a JSON object: {path}")

    expected_ids = set(seed_ids)
    actual_ids = set(raw)
    if actual_ids != expected_ids:
        missing = sorted(expected_ids - actual_ids)[:10]
        unexpected = sorted(actual_ids - expected_ids)[:10]
        raise RuntimeError(
            f"case-index starts seed mismatch: missing={missing}, "
            f"unexpected={unexpected}"
        )

    starts: dict[str, int] = {}
    for seed_id in seed_ids:
        entry = raw[seed_id]
        if isinstance(entry, dict):
            if "case_index_start" in entry:
                entry = entry["case_index_start"]
            elif "expected_attempts" in entry:
                entry = entry["expected_attempts"]
            elif "attempts" in entry:
                entry = entry["attempts"]
            else:
                raise KeyError(
                    f"case-index start row for {seed_id} has no supported value"
                )
        if isinstance(entry, bool) or not isinstance(entry, int) or entry < 0:
            raise ValueError(
                f"case-index start for {seed_id} must be a non-negative integer"
            )
        starts[seed_id] = entry
    return starts, sha256_file(path)


def seed_paths(seed_dir: Path, seed_id: str) -> tuple[Path, Path]:
    base = seed_dir / seed_id
    pre = base / "pre.ssz"
    block = base / "block.ssz"
    require_file(pre)
    require_file(block)
    return pre, block


def link_or_copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(src, dst)
    except OSError as exc:
        if exc.errno not in (errno.EXDEV, errno.EPERM, errno.EACCES):
            raise
        shutil.copy2(src, dst)


def path_universe_json(
    state_paths: list[PathSpec], block_paths: list[PathSpec]
) -> dict[str, Any]:
    paths = [*state_paths, *block_paths]
    return {
        "state_path_count": len(state_paths),
        "block_path_count": len(block_paths),
        "combined_path_count": len(paths),
        "paths": [
            {
                "universe_index": index,
                "root": path.root,
                "normalized_path": path.normalized,
                "ssz_type": path.typ.type_repr(),
                "index_depth": path.tokens.count(STAR),
            }
            for index, path in enumerate(paths)
        ],
    }


def generate_case(
    *,
    env: dict[str, Any],
    strategy: ValueStrategy,
    master_seed: str,
    seed_id: str,
    case_index: int,
    state: Any,
    signed_block: Any,
    original_pre: bytes,
    original_block: bytes,
    paths: list[PathSpec],
    max_random_attempts: int,
    max_index_retries: int,
    max_path_retries: int,
    max_slot_gap: int,
) -> tuple[bytes, bytes, dict[str, Any]]:
    serialize = env["serialize"]
    deserialize = env["deserialize"]
    spec = env["spec"]

    case_seed = derive_seed(GENERATOR_VERSION, master_seed, seed_id, str(case_index))
    selection_seed = derive_seed(case_seed, "selection")
    value_seed = derive_seed(case_seed, "value", strategy.name)
    selection_rng = make_rng(selection_seed)
    value_rng = make_rng(value_seed)

    retries_noop = 0
    retries_index = 0
    retries_path_index = 0
    retries_path_noop = 0
    roots = {"state": state, "block": signed_block.message}

    def serialization_failure_details(
        *,
        path: PathSpec,
        resolved: ResolvedPath,
        old_value: Any,
        candidate: ValueCandidate,
        path_attempt: int,
        error: str,
    ) -> dict[str, Any]:
        details: dict[str, Any] = {
            "seed_id": seed_id,
            "strategy": strategy.name,
            "case_index": case_index,
            "target_object": path.root,
            "normalized_path": path.normalized,
            "concrete_indices": list(resolved.indices),
            "concrete_tokens": list(resolved.tokens),
            "ssz_type": path.typ.type_repr(),
            "old_value": jsonable_value(env, old_value),
            "new_value": jsonable_value(env, candidate.value),
            "candidate": candidate.label,
            "retries_noop": retries_noop,
            "retries_index": retries_index,
            "retries_path": retries_path_index + retries_path_noop,
            "retries_path_index": retries_path_index,
            "retries_path_noop": retries_path_noop,
            "retries_slot_gap": 0,
            "path_attempt": path_attempt,
            "prng_case_seed": case_seed,
            "prng_selection_seed": selection_seed,
            "prng_value_seed": value_seed,
            "prng_engine": "python.random.MT19937",
            "slot_gap_policy": "record_only_filter_at_testing",
            "error": error,
        }
        if strategy.name == "extreme":
            details["extreme_candidate"] = candidate.label
        return details

    for path_attempt in range(max_path_retries + 1):
        path = paths[selection_rng.randrange(len(paths))]
        resolved, index_retries = resolve_indices(
            roots[path.root], path.tokens, selection_rng, max_index_retries
        )
        retries_index += index_retries
        if resolved is None:
            retries_path_index += 1
            continue
        target_root = roots[path.root]
        old_value = get_at(target_root, resolved.tokens)
        produced_candidate = False

        for candidate in strategy.candidates(
            env, path.typ, old_value, value_rng, max_random_attempts
        ):
            produced_candidate = True
            new_pre = original_pre
            new_block = original_block
            state_slot = int(state.slot)
            block_slot = int(signed_block.message.slot)
            set_at(target_root, resolved.tokens, candidate.value)
            try:
                if path.root == "state":
                    new_pre = serialize(state)
                else:
                    new_block = serialize(signed_block)
                state_slot = int(state.slot)
                block_slot = int(signed_block.message.slot)
            except Exception as exc:
                details = serialization_failure_details(
                    path=path,
                    resolved=resolved,
                    old_value=old_value,
                    candidate=candidate,
                    path_attempt=path_attempt,
                    error=f"{type(exc).__name__}: {exc}",
                )
                raise SerializationFailure(str(exc), details) from exc
            finally:
                set_at(target_root, resolved.tokens, old_value)

            if new_pre == original_pre and new_block == original_block:
                retries_noop += 1
                continue

            try:
                if path.root == "state":
                    if serialize(deserialize(spec.BeaconState, new_pre)) != new_pre:
                        raise ValueError("BeaconState round-trip changed bytes")
                else:
                    if serialize(deserialize(spec.SignedBeaconBlock, new_block)) != new_block:
                        raise ValueError("SignedBeaconBlock round-trip changed bytes")
            except Exception as exc:
                details = serialization_failure_details(
                    path=path,
                    resolved=resolved,
                    old_value=old_value,
                    candidate=candidate,
                    path_attempt=path_attempt,
                    error=f"round-trip {type(exc).__name__}: {exc}",
                )
                raise SerializationFailure(str(exc), details) from exc

            gap = block_slot - state_slot
            record: dict[str, Any] = {
                "case_id": "",
                "seed_id": seed_id,
                "seed_name": seed_id,
                "strategy": strategy.name,
                "case_index": case_index,
                "target_object": path.root,
                "normalized_path": path.normalized,
                "concrete_indices": list(resolved.indices),
                "concrete_tokens": list(resolved.tokens),
                "ssz_type": path.typ.type_repr(),
                "old_value": jsonable_value(env, old_value),
                "new_value": jsonable_value(env, candidate.value),
                "retries_noop": retries_noop,
                "retries_index": retries_index,
                "retries_path": retries_path_index + retries_path_noop,
                "retries_path_index": retries_path_index,
                "retries_path_noop": retries_path_noop,
                "retries_slot_gap": 0,
                "path_attempt": path_attempt,
                "prng_case_seed": case_seed,
                "prng_selection_seed": selection_seed,
                "prng_value_seed": value_seed,
                "prng_engine": "python.random.MT19937",
                "state_slot": state_slot,
                "block_slot": block_slot,
                "slot_gap": gap,
                "slot_gap_exceeds_32": gap > DEFAULT_TESTING_MAX_SLOT_GAP,
                "slot_gap_exceeds_testing_max": gap > max_slot_gap,
                "slot_gap_policy": "record_only_filter_at_testing",
                "roundtrip_verified": True,
                "pre_sha256": sha256_bytes(new_pre),
                "block_sha256": sha256_bytes(new_block),
            }
            if strategy.name == "extreme":
                record["extreme_candidate"] = candidate.label
            return new_pre, new_block, record

        if not produced_candidate:
            raise NoValueCandidates(path.typ.type_repr())
        retries_path_noop += 1

    raise RuntimeError(
        f"failed to generate {strategy.name} case for {seed_id}/{case_index} "
        f"after {max_path_retries + 1} path attempts"
    )


def case_name(strategy: str, index: int, target: str) -> str:
    return f"{strategy}_path_uniform_{index:06d}_{target}"


def write_case(
    out_dir: Path,
    seed_id: str,
    record: dict[str, Any],
    new_pre: bytes,
    new_block: bytes,
    seed_pre_path: Path,
    seed_block_path: Path,
) -> dict[str, Any]:
    name = case_name(record["strategy"], record["case_index"], record["target_object"])
    seed_out = out_dir / seed_id
    final_dir = seed_out / name
    tmp_dir = seed_out / ("." + name + ".tmp")
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.mkdir(parents=True)

    pre_out = tmp_dir / "pre.ssz"
    block_out = tmp_dir / "blocks_0.ssz"
    if record["target_object"] == "state":
        pre_out.write_bytes(new_pre)
        link_or_copy(seed_block_path, block_out)
    else:
        link_or_copy(seed_pre_path, pre_out)
        block_out.write_bytes(new_block)

    record = {
        **record,
        "case_name": name,
        "case_id": f"{seed_id}/{name}",
        "pre_ssz": f"{seed_id}/{name}/pre.ssz",
        "block_ssz": f"{seed_id}/{name}/blocks_0.ssz",
    }
    write_json(tmp_dir / "mutation.json", record)
    if final_dir.exists():
        shutil.rmtree(final_dir)
    os.replace(tmp_dir, final_dir)
    return record


def load_existing_case(
    out_dir: Path, seed_id: str, strategy: str, index: int
) -> dict[str, Any] | None:
    seed_out = out_dir / seed_id
    if not seed_out.is_dir():
        return None
    matches = sorted(seed_out.glob(f"{strategy}_path_uniform_{index:06d}_*/mutation.json"))
    if not matches:
        return None
    if len(matches) != 1:
        raise RuntimeError(
            f"resume found multiple cases for {seed_id}/{strategy}/{index}: {matches}"
        )
    record = read_json(matches[0])
    case_dir = matches[0].parent
    pre_path = case_dir / "pre.ssz"
    block_path = case_dir / "blocks_0.ssz"
    required_identity = {
        "seed_id": seed_id,
        "strategy": strategy,
        "case_index": index,
        "case_name": case_dir.name,
        "case_id": f"{seed_id}/{case_dir.name}",
    }
    for key, expected in required_identity.items():
        if record.get(key) != expected:
            raise RuntimeError(
                f"resume case identity mismatch in {matches[0]}: "
                f"{key}={record.get(key)!r}, expected {expected!r}"
            )
    for path, hash_key in ((pre_path, "pre_sha256"), (block_path, "block_sha256")):
        require_file(path)
        actual_hash = sha256_file(path)
        if record.get(hash_key) != actual_hash:
            raise RuntimeError(
                f"resume case hash mismatch for {path}: "
                f"manifest={record.get(hash_key)!r}, actual={actual_hash!r}"
            )
    return record


def rebuild_manifests(
    out_dir: Path, seed_ids: list[str]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    for seed_id in seed_ids:
        seed_out = out_dir / seed_id
        if not seed_out.is_dir():
            continue
        for mutation in sorted(seed_out.glob("*/mutation.json")):
            records.append(read_json(mutation))
        for failure in sorted(seed_out.glob("*.failure.json")):
            failures.append(read_json(failure))
    records.sort(key=lambda row: (row["seed_id"], int(row["case_index"])))
    failures.sort(key=lambda row: (row["seed_id"], int(row["case_index"])))
    write_jsonl(out_dir / "manifest.jsonl", records)
    write_json(out_dir / "manifest.json", records)
    write_jsonl(out_dir / "serialization_failures.jsonl", failures)
    return records, failures


def expected_config(
    *,
    args: argparse.Namespace,
    version: dict[str, str],
    seed_manifest_sha256: str,
    state_path_count: int,
    block_path_count: int,
    selected_seed_count: int,
    budgets: dict[str, int],
    case_index_starts: dict[str, int],
    case_index_starts_sha256: str | None,
) -> dict[str, Any]:
    remainder = args.total_budget % EXPECTED_SEED_COUNT
    budget_histogram = dict(sorted(Counter(budgets.values()).items()))
    return {
        "generator_version": GENERATOR_VERSION,
        "strategy": args.strategy,
        "master_seed": args.master_seed,
        "prng_engine": "python.random.MT19937",
        "python_version": platform.python_version(),
        "consensus_specs_tag": version["tag"],
        "consensus_specs_commit": version["commit"],
        "eth2spec_version": version["eth2spec_version"],
        "seed_dir": str(args.seed_dir.resolve()),
        "seed_manifest_sha256": seed_manifest_sha256,
        "seed_count": EXPECTED_SEED_COUNT,
        "selected_seed_count": selected_seed_count,
        "total_budget": args.total_budget,
        "budget_profile": args.budget_profile,
        "budget_phases": (
            list(PAPER_RQ3_BUDGET_PHASES)
            if args.budget_profile == "paper-rq3"
            else [args.total_budget]
        ),
        "per_seed_budget_histogram": {
            str(case_count): seed_count
            for case_count, seed_count in budget_histogram.items()
        },
        "extra_budget_seed_count": (
            remainder if args.budget_profile == "uniform" else None
        ),
        "case_index_policy": (
            "paper_rq3_zero_based_contiguous"
            if args.budget_profile == "paper-rq3"
            else (
                "explicit_per_seed_continuation"
                if any(case_index_starts.values())
                else "zero_based_per_seed"
            )
        ),
        "case_index_starts_source": (
            str(args.case_index_starts.resolve())
            if args.case_index_starts is not None
            else None
        ),
        "case_index_starts_source_sha256": case_index_starts_sha256,
        "case_index_starts": case_index_starts,
        "state_path_count": state_path_count,
        "block_path_count": block_path_count,
        "combined_path_count": state_path_count + block_path_count,
        "mutation_unit": "one_normalized_atomic_path",
        "selection": "uniform_over_seed_realizable_normalized_paths",
        "block_scope": "SignedBeaconBlock.message_only",
        "slot_gap_policy": "record_only_filter_at_testing",
        "testing_max_slot_gap": args.testing_max_slot_gap,
        "max_random_value_attempts": args.max_random_value_attempts,
        "max_index_retries": args.max_index_retries,
        "max_path_retries": args.max_path_retries,
        "limit_seeds": args.limit_seeds,
        "limit_cases_per_seed": args.limit_cases_per_seed,
    }


def verify_or_prepare_output(
    out_dir: Path, config: dict[str, Any], resume: bool
) -> None:
    config_path = out_dir / "generation_config.json"
    if out_dir.exists() and any(out_dir.iterdir()):
        if not resume:
            raise RuntimeError(f"output is non-empty; pass --resume: {out_dir}")
        require_file(config_path)
        old = read_json(config_path)
        if old != config:
            raise RuntimeError(
                "resume configuration differs from existing generation_config.json"
            )
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    write_json(config_path, config)


def verify_or_write_static_json(path: Path, value: Any, *, may_create: bool) -> None:
    """Validate immutable shared metadata, or create it before workers start."""
    if path.is_file():
        old = read_json(path)
        if old != value:
            raise RuntimeError(f"shared metadata differs from existing file: {path}")
        return
    if not may_create:
        raise RuntimeError(
            f"missing shared metadata {path}; run --initialize-only before shards"
        )
    write_json(path, value)


def prng_metadata(master_seed: str) -> dict[str, str]:
    return {
        "master_seed": master_seed,
        "case_seed_derivation": (
            "sha256(length-prefixed generator_version, master_seed, seed_id, case_index)"
        ),
        "selection_stream": "sha256(case_seed, selection)",
        "value_stream": "sha256(case_seed, value, strategy)",
        "engine": "python.random.MT19937",
    }


def summarize(
    *,
    records: list[dict[str, Any]],
    failures: list[dict[str, Any]],
    budgets: dict[str, int],
    selected_seed_ids: list[str],
    excluded: dict[str, list[str]],
    state_path_count: int,
    block_path_count: int,
    testing_max_gap: int,
    case_index_starts: dict[str, int],
) -> dict[str, Any]:
    target_counts = Counter(row["target_object"] for row in records)
    histogram = Counter(row["normalized_path"] for row in records)
    per_seed_generated = Counter(row["seed_id"] for row in records)
    per_seed_failed = Counter(row["seed_id"] for row in failures)
    attempted = sum(budgets[seed_id] for seed_id in selected_seed_ids)
    gap_excluded = [
        row for row in records if int(row["slot_gap"]) > testing_max_gap
    ]
    summary = {
        "attempted_cases": attempted,
        "successful_cases": len(records),
        "serialization_failures": len(failures),
        "attempt_accounting_ok": attempted == len(records) + len(failures),
        "seed_count": len(selected_seed_ids),
        "state_path_count": state_path_count,
        "block_path_count": block_path_count,
        "combined_path_count": state_path_count + block_path_count,
        "state_mutated_cases": target_counts["state"],
        "block_mutated_cases": target_counts["block"],
        "testing_max_slot_gap": testing_max_gap,
        "testing_eligible_cases": len(records) - len(gap_excluded),
        "slot_gap_excluded_at_testing": len(gap_excluded),
        "slot_gap_policy": "record_only_filter_at_testing",
        "noop_final_cases": 0,
        "total_retries_noop": sum(int(row["retries_noop"]) for row in records),
        "total_retries_index": sum(int(row["retries_index"]) for row in records),
        "total_retries_path": sum(int(row["retries_path"]) for row in records),
        "path_histogram": dict(sorted(histogram.items())),
    }
    case_counts = {
        seed_id: {
            "expected_attempts": budgets[seed_id],
            "case_index_start": case_index_starts[seed_id],
            "case_index_end_exclusive": (
                case_index_starts[seed_id] + budgets[seed_id]
            ),
            "successful": per_seed_generated[seed_id],
            "serialization_failures": per_seed_failed[seed_id],
            "attempts": per_seed_generated[seed_id] + per_seed_failed[seed_id],
        }
        for seed_id in selected_seed_ids
    }
    return {"summary": summary, "case_counts": case_counts, "excluded": excluded}


def main() -> int:
    args = parse_args()
    require_dir(args.seed_dir)
    version = verify_consensus_specs_version(args.consensus_specs_dir)
    env = import_pyspec(args.consensus_specs_dir)
    state_paths, block_paths, universe = build_path_universe(env)
    seed_rows, seed_manifest_sha256 = load_seed_manifest(args.seed_dir)
    all_seed_ids = [row["seed_id"] for row in seed_rows]
    if len(all_seed_ids) != EXPECTED_SEED_COUNT or len(set(all_seed_ids)) != EXPECTED_SEED_COUNT:
        raise AssertionError(
            f"seed manifest must contain {EXPECTED_SEED_COUNT} unique seeds, got "
            f"{len(all_seed_ids)}/{len(set(all_seed_ids))}"
        )
    budgets = budget_by_seed(
        all_seed_ids,
        args.total_budget,
        budget_profile=args.budget_profile,
    )
    case_index_starts, case_index_starts_sha256 = load_case_index_starts(
        args.case_index_starts, all_seed_ids
    )
    selected_rows = seed_rows
    if args.limit_seeds is not None:
        selected_rows = selected_rows[: args.limit_seeds]
    selected_seed_ids = [row["seed_id"] for row in selected_rows]
    work_rows = seed_shard_rows(
        selected_rows, args.seed_shard_count, args.seed_shard_index
    )
    if args.limit_cases_per_seed is not None:
        budgets = {
            seed_id: min(budgets[seed_id], args.limit_cases_per_seed)
            for seed_id in all_seed_ids
        }

    print(
        f"SSZ paths: state={len(state_paths)} block={len(block_paths)} "
        f"combined={len(universe)}",
        flush=True,
    )
    print(
        f"Seeds: selected={len(selected_seed_ids)}/{len(all_seed_ids)}; "
        f"attempts={sum(budgets[s] for s in selected_seed_ids)}",
        flush=True,
    )
    print(
        f"Seed shard: index={args.seed_shard_index}/{args.seed_shard_count}; "
        f"work_seeds={len(work_rows)}",
        flush=True,
    )

    config = expected_config(
        args=args,
        version=version,
        seed_manifest_sha256=seed_manifest_sha256,
        state_path_count=len(state_paths),
        block_path_count=len(block_paths),
        selected_seed_count=len(selected_seed_ids),
        budgets=budgets,
        case_index_starts=case_index_starts,
        case_index_starts_sha256=case_index_starts_sha256,
    )
    if not args.dry_run:
        verify_or_prepare_output(args.out_dir, config, args.resume)
        may_create_static = args.initialize_only or args.seed_shard_count == 1
        verify_or_write_static_json(
            args.out_dir / "path_universe.json",
            path_universe_json(state_paths, block_paths),
            may_create=may_create_static,
        )
        verify_or_write_static_json(
            args.out_dir / "prng.json",
            prng_metadata(args.master_seed),
            may_create=may_create_static,
        )
        verify_or_write_static_json(
            args.out_dir / "case_index_starts.json",
            {"case_index_starts": case_index_starts},
            may_create=may_create_static,
        )

    if args.initialize_only:
        print(f"Initialized shared output metadata: {args.out_dir}", flush=True)
        return 0

    deserialize = env["deserialize"]
    serialize = env["serialize"]
    spec = env["spec"]
    strategy: ValueStrategy = (
        RandomValueStrategy() if args.strategy == "random" else ExtremeValueStrategy()
    )
    excluded_by_seed: dict[str, list[str]] = {}

    for seed_number, row in enumerate(work_rows, start=1):
        seed_id = row["seed_id"]
        pre_path, block_path = seed_paths(args.seed_dir, seed_id)
        pre_bytes = pre_path.read_bytes()
        block_bytes = block_path.read_bytes()
        for label, raw, hash_key in (
            ("pre", pre_bytes, "pre_sha256"),
            ("block", block_bytes, "block_sha256"),
        ):
            expected_hash = row.get(hash_key)
            if not isinstance(expected_hash, str):
                raise RuntimeError(
                    f"seed manifest row {seed_id} is missing required {hash_key}"
                )
            actual_hash = sha256_bytes(raw)
            if actual_hash != expected_hash:
                raise RuntimeError(
                    f"seed {label} hash mismatch for {seed_id}: "
                    f"manifest={expected_hash}, actual={actual_hash}"
                )
        state = deserialize(spec.BeaconState, pre_bytes)
        signed_block = deserialize(spec.SignedBeaconBlock, block_bytes)
        if serialize(state) != pre_bytes or serialize(signed_block) != block_bytes:
            raise AssertionError(f"seed SSZ round-trip mismatch: {seed_id}")
        realizable, excluded = realizable_paths(universe, state, signed_block)
        if not realizable:
            raise AssertionError(f"seed has no realizable paths: {seed_id}")
        excluded_by_seed[seed_id] = excluded
        budget = budgets[seed_id]
        case_index_start = case_index_starts[seed_id]
        if args.progress_every and (
            seed_number == 1
            or seed_number % args.progress_every == 0
            or seed_number == len(work_rows)
        ):
            print(
                f"[{seed_number:03d}/{len(work_rows):03d}] {seed_id}: "
                f"budget={budget} case_index_start={case_index_start} "
                f"realizable={len(realizable)} excluded={len(excluded)}",
                flush=True,
            )
        if args.dry_run:
            continue

        (args.out_dir / seed_id).mkdir(parents=True, exist_ok=True)
        for index in range(case_index_start, case_index_start + budget):
            if args.resume:
                existing = load_existing_case(args.out_dir, seed_id, args.strategy, index)
                failure_path = args.out_dir / seed_id / f"{index:06d}.failure.json"
                if failure_path.is_file():
                    failure = read_json(failure_path)
                    expected_failure_identity = {
                        "seed_id": seed_id,
                        "strategy": args.strategy,
                        "case_index": index,
                        "status": "serialization_failure",
                    }
                    for key, expected in expected_failure_identity.items():
                        if failure.get(key) != expected:
                            raise RuntimeError(
                                f"resume failure identity mismatch in {failure_path}: "
                                f"{key}={failure.get(key)!r}, expected {expected!r}"
                            )
                if existing is not None or failure_path.is_file():
                    continue
            try:
                new_pre, new_block, record = generate_case(
                    env=env,
                    strategy=strategy,
                    master_seed=args.master_seed,
                    seed_id=seed_id,
                    case_index=index,
                    state=state,
                    signed_block=signed_block,
                    original_pre=pre_bytes,
                    original_block=block_bytes,
                    paths=realizable,
                    max_random_attempts=args.max_random_value_attempts,
                    max_index_retries=args.max_index_retries,
                    max_path_retries=args.max_path_retries,
                    max_slot_gap=args.testing_max_slot_gap,
                )
                write_case(
                    args.out_dir,
                    seed_id,
                    record,
                    new_pre,
                    new_block,
                    pre_path,
                    block_path,
                )
            except SerializationFailure as exc:
                failure = {
                    **exc.details,
                    "case_id": f"{seed_id}/{index:06d}",
                    "status": "serialization_failure",
                }
                write_json(
                    args.out_dir / seed_id / f"{index:06d}.failure.json", failure
                )

    if args.dry_run:
        print(
            json.dumps(
                {
                    **config,
                    "attempted_cases": sum(budgets[s] for s in selected_seed_ids),
                    "seed_shard_count": args.seed_shard_count,
                    "seed_shard_index": args.seed_shard_index,
                    "work_seed_count": len(work_rows),
                    "excluded_paths_per_seed": excluded_by_seed,
                },
                indent=2,
            )
        )
        return 0

    if args.defer_finalize:
        print(
            f"Deferred root finalization for shard "
            f"{args.seed_shard_index}/{args.seed_shard_count}: "
            f"completed {len(work_rows)} seed directories",
            flush=True,
        )
        return 0

    write_json(args.out_dir / "excluded_paths_per_seed.json", excluded_by_seed)
    records, failures = rebuild_manifests(args.out_dir, selected_seed_ids)
    result = summarize(
        records=records,
        failures=failures,
        budgets=budgets,
        selected_seed_ids=selected_seed_ids,
        excluded=excluded_by_seed,
        state_path_count=len(state_paths),
        block_path_count=len(block_paths),
        testing_max_gap=args.testing_max_slot_gap,
        case_index_starts=case_index_starts,
    )
    write_json(args.out_dir / "summary.json", result["summary"])
    write_json(args.out_dir / "seed_case_counts.json", result["case_counts"])
    write_json(args.out_dir / "path_histogram.json", result["summary"]["path_histogram"])
    eligible = [
        row["case_id"]
        for row in records
        if int(row["slot_gap"]) <= args.testing_max_slot_gap
    ]
    excluded_cases = [
        row["case_id"]
        for row in records
        if int(row["slot_gap"]) > args.testing_max_slot_gap
    ]
    (args.out_dir / "testing_eligible_cases.txt").write_text(
        "".join(f"{case_id}\n" for case_id in eligible), encoding="utf-8"
    )
    (args.out_dir / "slot_gap_excluded_cases.txt").write_text(
        "".join(f"{case_id}\n" for case_id in excluded_cases), encoding="utf-8"
    )
    print(json.dumps(result["summary"], indent=2), flush=True)
    if not result["summary"]["attempt_accounting_ok"]:
        raise RuntimeError("attempt accounting failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
