#!/usr/bin/env python3
"""
Flatten the public Capella full-block consensus tests into 581 seed pairs.

The input universe is deliberately limited to these three public
``OfficialTestSuite/capella`` full-block roots:

* ``finality/pyspec_tests``
* ``random/random/pyspec_tests``
* ``sanity/blocks/pyspec_tests``

For every numeric ``blocks_I.ssz_snappy`` file, the collector writes the state
immediately before block I and that ``SignedBeaconBlock`` as:

    OUT/SEED_ID/pre.ssz
    OUT/SEED_ID/block.ssz

Multi-block tests are replayed sequentially with the generated eth2spec v1.6.0
Capella pyspec.  BLS verification is disabled as a replay optimization, while
all other state-transition validation remains enabled.  Positive tests are
checked byte-for-byte against their official final ``post.ssz_snappy``.  For a
negative test (no official post), its final block pair is collected but the
known-invalid final transition is not attempted.

No SpecTrum-generated input, premise, provenance, or target data is read.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


TARGET_CONSENSUS_SPECS_TAG = "v1.6.0"
TARGET_ETH2SPEC_VERSION = "1.6.0"
EXPECTED_SEED_COUNT = 581

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OFFICIAL_ROOT = ROOT / "Converter/OfficialTestSuite"
DEFAULT_CONSENSUS_SPECS_DIR = ROOT / "consensus-specs"
DEFAULT_OUT_DIR = ROOT / "results/rq3/capella_seed581"

BLOCK_RE = re.compile(r"^blocks_(0|[1-9][0-9]*)\.ssz_snappy$")


@dataclass(frozen=True)
class SuiteSpec:
    name: str
    relative_root: Path
    seed_prefix: str


SUITES = (
    SuiteSpec(
        name="finality",
        relative_root=Path("capella/finality/pyspec_tests"),
        seed_prefix="finality_finality_",
    ),
    SuiteSpec(
        name="random",
        relative_root=Path("capella/random/random/pyspec_tests"),
        seed_prefix="random_random_",
    ),
    SuiteSpec(
        name="sanity/blocks",
        relative_root=Path("capella/sanity/blocks/pyspec_tests"),
        seed_prefix="sanity_sanity_blocks_",
    ),
)


@dataclass(frozen=True)
class OfficialTest:
    suite: SuiteSpec
    name: str
    directory: Path
    relative_directory: Path
    pre_path: Path
    block_paths: tuple[Path, ...]
    post_path: Path | None

    @property
    def block_count(self) -> int:
        return len(self.block_paths)

    @property
    def expected_valid(self) -> bool:
        return self.post_path is not None


@dataclass(frozen=True)
class SeedPlan:
    seed_id: str
    test: OfficialTest
    block_index: int

    @property
    def block_path(self) -> Path:
        return self.test.block_paths[self.block_index]


@dataclass(frozen=True)
class PyspecEnvironment:
    spec: Any
    serialize: Any
    deserialize: Any
    git_commit: str


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hex_root(value: Any) -> str:
    return "0x" + bytes(value).hex()


def git_output(repo: Path, *args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(repo), *args],
            stderr=subprocess.STDOUT,
            text=True,
        ).strip()
    except subprocess.CalledProcessError as exc:
        detail = exc.output.strip()
        raise RuntimeError(f"git check failed for {repo}: {detail}") from exc


def verify_pyspec_version(consensus_specs_dir: Path) -> str:
    if not consensus_specs_dir.is_dir():
        raise FileNotFoundError(f"missing consensus-specs directory: {consensus_specs_dir}")

    version_path = consensus_specs_dir / "tests/core/pyspec/eth2spec/VERSION.txt"
    if not version_path.is_file():
        raise FileNotFoundError(f"missing eth2spec version file: {version_path}")

    tag = git_output(consensus_specs_dir, "describe", "--tags", "--exact-match", "HEAD")
    version = version_path.read_text().strip()
    if tag != TARGET_CONSENSUS_SPECS_TAG or version != TARGET_ETH2SPEC_VERSION:
        raise RuntimeError(
            "consensus-specs version mismatch: "
            f"tag={tag!r}, eth2spec={version!r}; expected "
            f"{TARGET_CONSENSUS_SPECS_TAG!r}/{TARGET_ETH2SPEC_VERSION!r}"
        )
    return git_output(consensus_specs_dir, "rev-parse", "HEAD")


def import_pyspec(consensus_specs_dir: Path) -> PyspecEnvironment:
    """Import the generated Capella pyspec and disable only signature checks."""

    git_commit = verify_pyspec_version(consensus_specs_dir)
    pyspec_dir = consensus_specs_dir / "tests/core/pyspec"
    generated_module = pyspec_dir / "eth2spec/capella/mainnet.py"
    if not generated_module.is_file():
        raise FileNotFoundError(f"missing generated Capella pyspec: {generated_module}")

    sys.path.insert(0, str(pyspec_dir))
    from eth2spec.capella import mainnet as spec  # noqa: PLC0415
    from eth2spec.utils import bls  # noqa: PLC0415
    from eth2spec.utils.ssz.ssz_impl import deserialize, serialize  # noqa: PLC0415

    loaded_module = Path(spec.__file__).resolve()
    if loaded_module != generated_module.resolve():
        raise RuntimeError(
            f"loaded Capella pyspec from {loaded_module}, expected {generated_module.resolve()}"
        )

    # Keep non-verification group operations enabled: process_sync_aggregate
    # may need AggregatePKs even when signature verification is skipped.  The
    # generic bls_active=False switch returns a deliberately non-curve stub
    # pubkey there, which the Capella >50%-participation fast path then tries to
    # decode.  Stub only the three signature-verification entry points instead.
    # They do not affect state; all non-BLS assertions and the final post-state
    # byte comparison remain enabled.
    bls.bls_active = True
    bls.Verify = lambda *_args, **_kwargs: True
    bls.AggregateVerify = lambda *_args, **_kwargs: True
    bls.FastAggregateVerify = lambda *_args, **_kwargs: True
    return PyspecEnvironment(
        spec=spec,
        serialize=serialize,
        deserialize=deserialize,
        git_commit=git_commit,
    )


def numeric_block_paths(test_dir: Path) -> tuple[Path, ...]:
    indexed: list[tuple[int, Path]] = []
    for child in test_dir.iterdir():
        if not child.is_file():
            continue
        match = BLOCK_RE.fullmatch(child.name)
        if match is not None:
            indexed.append((int(match.group(1)), child))

    indexed.sort(key=lambda pair: pair[0])
    indices = [index for index, _ in indexed]
    if not indices:
        raise RuntimeError(f"official test has no numeric blocks_I input: {test_dir}")
    expected = list(range(len(indices)))
    if indices != expected:
        raise RuntimeError(
            f"official block indices are not contiguous from zero in {test_dir}: "
            f"got {indices}, expected {expected}"
        )
    return tuple(path for _, path in indexed)


def discover_suite(official_root: Path, suite: SuiteSpec) -> list[OfficialTest]:
    suite_root = official_root / suite.relative_root
    if not suite_root.is_dir():
        raise FileNotFoundError(f"missing official suite root: {suite_root}")

    tests: list[OfficialTest] = []
    for test_dir in sorted(
        (path for path in suite_root.iterdir() if path.is_dir()),
        key=lambda path: path.name,
    ):
        pre_path = test_dir / "pre.ssz_snappy"
        if not pre_path.is_file():
            raise FileNotFoundError(f"missing official pre state: {pre_path}")
        post_candidate = test_dir / "post.ssz_snappy"
        tests.append(
            OfficialTest(
                suite=suite,
                name=test_dir.name,
                directory=test_dir,
                relative_directory=test_dir.relative_to(official_root),
                pre_path=pre_path,
                block_paths=numeric_block_paths(test_dir),
                post_path=post_candidate if post_candidate.is_file() else None,
            )
        )
    if not tests:
        raise RuntimeError(f"official suite root has no test directories: {suite_root}")
    return tests


def make_seed_id(test: OfficialTest, block_index: int) -> str:
    if not 0 <= block_index < test.block_count:
        raise IndexError(
            f"block index {block_index} outside test {test.name} with {test.block_count} blocks"
        )
    # Match the historical eth-tests flattened-seed convention: a one-block
    # test carries no redundant _0; every block of a multi-block test does.
    suffix = "" if test.block_count == 1 else f"_{block_index}"
    return f"eth-tests-{test.suite.seed_prefix}{test.name}{suffix}_pre.json"


def discover_seed_plans(
    official_root: Path,
    *,
    expected_count: int = EXPECTED_SEED_COUNT,
) -> tuple[list[OfficialTest], list[SeedPlan]]:
    if not official_root.is_dir():
        raise FileNotFoundError(f"missing OfficialTestSuite root: {official_root}")

    tests = [test for suite in SUITES for test in discover_suite(official_root, suite)]
    plans = [
        SeedPlan(seed_id=make_seed_id(test, block_index), test=test, block_index=block_index)
        for test in tests
        for block_index in range(test.block_count)
    ]
    plans.sort(key=lambda plan: plan.seed_id)

    duplicate_ids = sorted(
        seed_id for seed_id, count in Counter(plan.seed_id for plan in plans).items() if count > 1
    )
    if duplicate_ids:
        raise RuntimeError(f"duplicate flattened seed IDs: {duplicate_ids}")
    if len(plans) != expected_count:
        raise RuntimeError(
            f"expected exactly {expected_count} flattened Capella seed pairs, got {len(plans)}"
        )
    return tests, plans


def snappy_decompress(path: Path) -> bytes:
    try:
        import snappy  # noqa: PLC0415
    except ImportError as exc:
        raise RuntimeError(
            "python-snappy is required to read OfficialTestSuite *.ssz_snappy files"
        ) from exc
    try:
        return snappy.decompress(path.read_bytes())
    except Exception as exc:
        raise RuntimeError(f"failed to Snappy-decompress {path}: {exc}") from exc


def canonical_deserialize(env: PyspecEnvironment, typ: Any, raw: bytes, source: Path) -> Any:
    try:
        value = env.deserialize(typ, raw)
    except Exception as exc:
        raise RuntimeError(f"failed to deserialize {source} as {typ.__name__}: {exc}") from exc
    encoded = env.serialize(value)
    if encoded != raw:
        raise RuntimeError(f"non-canonical SSZ round-trip for {source}")
    return value


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        with temporary.open("wb") as destination:
            destination.write(data)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write(path, (json.dumps(value, indent=2, sort_keys=False) + "\n").encode())


def persist_seed_pair(seed_dir: Path, pre_bytes: bytes, block_bytes: bytes) -> str:
    """Write a pair atomically, or verify that an interrupted run wrote it already."""

    seed_dir.mkdir(parents=True, exist_ok=True)
    status: list[str] = []
    for name, expected in (("pre.ssz", pre_bytes), ("block.ssz", block_bytes)):
        destination = seed_dir / name
        if destination.exists():
            if not destination.is_file() or destination.read_bytes() != expected:
                raise RuntimeError(
                    f"resume conflict: existing output does not match replayed bytes: {destination}"
                )
            status.append("verified")
        else:
            atomic_write(destination, expected)
            status.append("written")
    return "resumed" if status == ["verified", "verified"] else "written"


def safe_fresh_remove(out_dir: Path) -> None:
    resolved = out_dir.resolve()
    forbidden = {Path("/"), Path.home().resolve(), Path.cwd().resolve()}
    if resolved in forbidden or len(resolved.parts) < 3:
        raise RuntimeError(f"refusing unsafe --fresh removal target: {resolved}")
    if resolved.exists():
        if not resolved.is_dir():
            raise RuntimeError(f"output path exists and is not a directory: {resolved}")
        shutil.rmtree(resolved)


def prepare_output(
    out_dir: Path,
    *,
    fresh: bool,
    collector_identity: dict[str, Any],
) -> None:
    if fresh:
        safe_fresh_remove(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    marker_path = out_dir / ".capella_flattened_seed581.json"
    if marker_path.exists():
        try:
            existing = json.loads(marker_path.read_text())
        except Exception as exc:
            raise RuntimeError(f"cannot read existing collector marker: {marker_path}") from exc
        if existing != collector_identity:
            raise RuntimeError(
                f"resume configuration conflicts with {marker_path}; use a new --out-dir or --fresh"
            )
    elif any(out_dir.iterdir()):
        raise RuntimeError(
            f"refusing to mix collector output into non-empty unmarked directory {out_dir}; "
            "use --fresh to replace it"
        )
    else:
        atomic_write_json(marker_path, collector_identity)


def relative_source(path: Path, official_root: Path) -> str:
    return str(path.relative_to(official_root))


def transition(env: PyspecEnvironment, state: Any, signed_block: Any, source: Path) -> None:
    try:
        # validate_result deliberately remains True.  Only the BLS signature
        # verification entry points were stubbed in import_pyspec().
        env.spec.state_transition(state, signed_block, validate_result=True)
    except Exception as exc:
        raise RuntimeError(f"pyspec transition failed for {source}: {exc}") from exc


def replay_test(
    env: PyspecEnvironment,
    test: OfficialTest,
    official_root: Path,
    out_dir: Path,
) -> tuple[list[dict[str, Any]], Counter[str]]:
    pre_raw = snappy_decompress(test.pre_path)
    state = canonical_deserialize(env, env.spec.BeaconState, pre_raw, test.pre_path)
    source_pre_snappy_sha256 = sha256_file(test.pre_path)

    rows: list[dict[str, Any]] = []
    write_statuses: Counter[str] = Counter()
    for block_index, block_path in enumerate(test.block_paths):
        current_pre = env.serialize(state)
        block_raw = snappy_decompress(block_path)
        signed_block = canonical_deserialize(
            env, env.spec.SignedBeaconBlock, block_raw, block_path
        )
        seed_id = make_seed_id(test, block_index)

        state_slot = int(state.slot)
        block_slot = int(signed_block.message.slot)
        is_final = block_index == test.block_count - 1
        invalid_final = is_final and not test.expected_valid
        expected_outcome = "invalid" if invalid_final else "valid"

        write_statuses[persist_seed_pair(out_dir / seed_id, current_pre, block_raw)] += 1
        row: dict[str, Any] = {
            "seed_id": seed_id,
            "seed_name": seed_id,
            "suite": test.suite.name,
            "official_test_name": test.name,
            "official_test_dir": str(test.relative_directory),
            "block_index": block_index,
            "block_count": test.block_count,
            "is_final_block": is_final,
            "expected_outcome": expected_outcome,
            "transition_applied": not invalid_final,
            "pre_origin": (
                f"official:{relative_source(test.pre_path, official_root)}"
                if block_index == 0
                else f"pyspec-v1.6.0:state-after-blocks_{block_index - 1}"
            ),
            "block_origin": f"official:{relative_source(block_path, official_root)}",
            "pre_ssz": f"{seed_id}/pre.ssz",
            "block_ssz": f"{seed_id}/block.ssz",
            "pre_size": len(current_pre),
            "block_size": len(block_raw),
            "pre_sha256": sha256_bytes(current_pre),
            "block_sha256": sha256_bytes(block_raw),
            "pre_state_root": hex_root(env.spec.hash_tree_root(state)),
            "signed_block_root": hex_root(env.spec.hash_tree_root(signed_block)),
            "block_message_root": hex_root(env.spec.hash_tree_root(signed_block.message)),
            "state_slot": state_slot,
            "block_slot": block_slot,
            "slot_gap": block_slot - state_slot,
            "source_pre_snappy_sha256": source_pre_snappy_sha256,
            "source_block_snappy_sha256": sha256_file(block_path),
        }
        rows.append(row)

        if invalid_final:
            continue

        transition(env, state, signed_block, block_path)
        row["post_state_root"] = hex_root(env.spec.hash_tree_root(state))
        row["post_slot"] = int(state.slot)

        if is_final:
            if test.post_path is None:  # Defensive; invalid finals continue above.
                raise AssertionError(f"missing positive post path for {test.directory}")
            expected_post_raw = snappy_decompress(test.post_path)
            expected_post = canonical_deserialize(
                env, env.spec.BeaconState, expected_post_raw, test.post_path
            )
            actual_post_raw = env.serialize(state)
            if actual_post_raw != expected_post_raw:
                raise RuntimeError(
                    "positive final post mismatch after sequential pyspec replay: "
                    f"{test.directory}; actual_sha256={sha256_bytes(actual_post_raw)}, "
                    f"expected_sha256={sha256_bytes(expected_post_raw)}"
                )
            row["official_final_post_compared"] = True
            row["official_final_post_sha256"] = sha256_bytes(expected_post_raw)
            row["official_final_post_state_root"] = hex_root(
                env.spec.hash_tree_root(expected_post)
            )

    return rows, write_statuses


def suite_block_counts(tests: Iterable[OfficialTest]) -> dict[str, int]:
    counts: Counter[str] = Counter()
    for test in tests:
        counts[test.suite.name] += test.block_count
    return {suite.name: counts[suite.name] for suite in SUITES}


def suite_test_counts(tests: Iterable[OfficialTest]) -> dict[str, int]:
    counts = Counter(test.suite.name for test in tests)
    return {suite.name: counts[suite.name] for suite in SUITES}


def write_manifests(
    out_dir: Path,
    rows: list[dict[str, Any]],
    summary: dict[str, Any],
) -> None:
    ordered = sorted(rows, key=lambda row: row["seed_id"])
    if len(ordered) != EXPECTED_SEED_COUNT:
        raise RuntimeError(
            f"refusing to write incomplete manifest: {len(ordered)} != {EXPECTED_SEED_COUNT}"
        )
    atomic_write_json(out_dir / "manifest.json", ordered)
    jsonl = b"".join(
        (json.dumps(row, separators=(",", ":"), sort_keys=False) + "\n").encode()
        for row in ordered
    )
    atomic_write(out_dir / "manifest.jsonl", jsonl)
    atomic_write_json(out_dir / "summary.json", summary)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect all 581 flattened Capella full-block seed pairs"
    )
    parser.add_argument("--official-root", type=Path, default=DEFAULT_OFFICIAL_ROOT)
    parser.add_argument(
        "--consensus-specs-dir", type=Path, default=DEFAULT_CONSENSUS_SPECS_DIR
    )
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument(
        "--fresh",
        action="store_true",
        help="remove and recreate --out-dir; otherwise an identical interrupted run is resumed",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="only discover and assert the exact 581-pair input universe",
    )
    parser.add_argument(
        "--progress-every",
        type=int,
        default=10,
        help="print replay progress every N official test directories (0 disables it)",
    )
    args = parser.parse_args(argv)
    if args.progress_every < 0:
        parser.error("--progress-every must be non-negative")
    if args.dry_run and args.fresh:
        parser.error("--dry-run and --fresh cannot be combined")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    official_root = args.official_root.resolve()
    consensus_specs_dir = args.consensus_specs_dir.resolve()
    out_dir = args.out_dir.resolve()

    tests, plans = discover_seed_plans(official_root)
    block_counts = suite_block_counts(tests)
    test_counts = suite_test_counts(tests)
    positive_tests = sum(test.expected_valid for test in tests)
    invalid_tests = len(tests) - positive_tests
    print(
        f"discovered {len(plans)} flattened pairs from {len(tests)} official tests: "
        + ", ".join(f"{name}={count}" for name, count in block_counts.items())
    )
    print(f"positive tests={positive_tests}, invalid-final tests={invalid_tests}")
    if args.dry_run:
        return 0

    env = import_pyspec(consensus_specs_dir)
    collector_identity = {
        "format": "capella-flattened-public-full-block-seeds-v1",
        "official_root": str(official_root),
        "consensus_specs_dir": str(consensus_specs_dir),
        "consensus_specs_tag": TARGET_CONSENSUS_SPECS_TAG,
        "eth2spec_version": TARGET_ETH2SPEC_VERSION,
        "consensus_specs_git_commit": env.git_commit,
        "expected_seed_count": EXPECTED_SEED_COUNT,
        "suite_roots": [str(suite.relative_root) for suite in SUITES],
    }
    prepare_output(out_dir, fresh=args.fresh, collector_identity=collector_identity)

    rows: list[dict[str, Any]] = []
    write_statuses: Counter[str] = Counter()
    ordered_tests = sorted(tests, key=lambda test: (test.suite.name, test.name))
    for test_number, test in enumerate(ordered_tests, start=1):
        test_rows, test_statuses = replay_test(env, test, official_root, out_dir)
        rows.extend(test_rows)
        write_statuses.update(test_statuses)
        if args.progress_every and (
            test_number % args.progress_every == 0 or test_number == len(ordered_tests)
        ):
            print(
                f"replayed tests {test_number}/{len(ordered_tests)}; "
                f"flattened pairs {len(rows)}/{EXPECTED_SEED_COUNT}"
            )

    if len(rows) != EXPECTED_SEED_COUNT:
        raise RuntimeError(f"replayed {len(rows)} pairs, expected {EXPECTED_SEED_COUNT}")
    if len({row["seed_id"] for row in rows}) != EXPECTED_SEED_COUNT:
        raise RuntimeError("replay produced duplicate seed IDs")

    summary = {
        **collector_identity,
        "output_dir": str(out_dir),
        "official_test_count": len(tests),
        "seed_count": len(rows),
        "suite_test_counts": test_counts,
        "suite_seed_counts": block_counts,
        "positive_test_count": positive_tests,
        "invalid_final_test_count": invalid_tests,
        "positive_final_posts_compared": sum(
            bool(row.get("official_final_post_compared")) for row in rows
        ),
        "invalid_final_pairs_collected_without_transition": sum(
            row["expected_outcome"] == "invalid" and not row["transition_applied"]
            for row in rows
        ),
        "bls_validation_enabled_during_replay": False,
        "state_transition_validate_result": True,
        "manifest_order": "seed_id_lexicographic",
    }
    write_manifests(out_dir, rows, summary)
    print(
        f"collected and verified {len(rows)} Capella seed pairs in {out_dir}; "
        f"status={dict(sorted(write_statuses.items()))}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
