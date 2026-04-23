#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


PathMatcher = Callable[[str], bool]


@dataclass(frozen=True)
class CoverageTotals:
    covered_primary: int = 0
    total_primary: int = 0
    covered_branch: int = 0
    total_branch: int = 0

    def add(self, other: "CoverageTotals") -> "CoverageTotals":
        return CoverageTotals(
            covered_primary=self.covered_primary + other.covered_primary,
            total_primary=self.total_primary + other.total_primary,
            covered_branch=self.covered_branch + other.covered_branch,
            total_branch=self.total_branch + other.total_branch,
        )


@dataclass(frozen=True)
class ClientConfig:
    name: str
    primary_label: str
    report_dir: str
    parser: Callable[[Path, PathMatcher], CoverageTotals]
    matcher: PathMatcher


REPO_ROOT = Path(__file__).resolve().parent


def _candidate_workspace_roots(coverage_root: Path | None = None) -> list[Path]:
    seeds: list[Path] = [REPO_ROOT, Path.cwd()]
    if coverage_root is not None:
        seeds.extend([coverage_root, coverage_root.parent, coverage_root.parent.parent])

    out: list[Path] = []
    seen: set[Path] = set()
    for seed in seeds:
        for candidate in [seed, *seed.parents[:4]]:
            if candidate not in seen:
                seen.add(candidate)
                out.append(candidate)
    return out


def _discover_dir(coverage_root: Path | None, suffix: str) -> Path | None:
    suffix_path = Path(suffix)
    for base in _candidate_workspace_roots(coverage_root):
        direct = base / suffix_path
        if direct.exists():
            return direct
        nested = base / 'spectec-core' / suffix_path
        if nested.exists():
            return nested
    return None


def _require_discovered_dir(coverage_root: Path | None, suffix: str, label: str) -> Path:
    path = _discover_dir(coverage_root, suffix)
    if path is None:
        raise FileNotFoundError(f'missing {label}: expected to find {suffix} near {REPO_ROOT} or {coverage_root}')
    return path


def _discover_lighthouse_html_root(report_dir: Path) -> Path:
    coverage_dir = report_dir / 'html' / 'coverage'
    preferred = coverage_dir / 'workspace/spectec-core/testing_clients/lighthouse'
    if preferred.exists():
        return preferred
    for path in coverage_dir.rglob('lighthouse'):
        if path.is_dir() and path.parent.name == 'testing_clients':
            return path
    raise FileNotFoundError(f'missing Lighthouse html coverage tree under {coverage_dir}')


def normalize_path(path: str) -> str:
    return path.replace("\\", "/")



def make_matcher(
    include_prefixes: Iterable[str] = (),
    include_exact: Iterable[str] = (),
    include_regexes: Iterable[str] = (),
    exclude_prefixes: Iterable[str] = (),
    exclude_exact: Iterable[str] = (),
    exclude_regexes: Iterable[str] = (),
) -> PathMatcher:
    include_prefixes = tuple(normalize_path(p) for p in include_prefixes)
    include_exact = set(normalize_path(p) for p in include_exact)
    include_regexes = tuple(re.compile(p) for p in include_regexes)
    exclude_prefixes = tuple(normalize_path(p) for p in exclude_prefixes)
    exclude_exact = set(normalize_path(p) for p in exclude_exact)
    exclude_regexes = tuple(re.compile(p) for p in exclude_regexes)

    def matcher(path: str) -> bool:
        norm = normalize_path(path)
        include_hit = (
            norm in include_exact
            or any(norm.startswith(prefix) for prefix in include_prefixes)
            or any(regex.search(norm) for regex in include_regexes)
        )
        if not include_hit:
            return False
        if norm in exclude_exact:
            return False
        if any(norm.startswith(prefix) for prefix in exclude_prefixes):
            return False
        if any(regex.search(norm) for regex in exclude_regexes):
            return False
        return True

    return matcher


# ---------------------------------------------------------------------------
# Existing file-scoped parsers
# ---------------------------------------------------------------------------


def parse_lighthouse(report_dir: Path, matcher: PathMatcher) -> CoverageTotals:
    summary_path = report_dir / "summary.txt"
    totals = CoverageTotals()

    for raw_line in summary_path.read_text().splitlines():
        line = raw_line.strip()
        if (
            not line
            or line.startswith("Filename")
            or line.startswith("---")
            or raw_line.startswith(" ")
        ):
            continue
        parts = raw_line.split()
        if len(parts) < 13:
            continue

        file_path = normalize_path(parts[0])
        anchor = file_path.find("consensus/state_processing/src/")
        if anchor != -1:
            file_path = file_path[anchor:]
        if not matcher(file_path):
            continue

        regions = int(parts[1])
        missed_regions = int(parts[2])
        branches = int(parts[10])
        missed_branches = int(parts[11])

        totals = totals.add(
            CoverageTotals(
                covered_primary=regions - missed_regions,
                total_primary=regions,
                covered_branch=branches - missed_branches,
                total_branch=branches,
            )
        )

    return totals



def parse_prysm(report_dir: Path, matcher: PathMatcher) -> CoverageTotals:
    stmt_totals = CoverageTotals()
    coverage_txt = report_dir / "coverage.txt"
    for raw_line in coverage_txt.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("mode:"):
            continue
        try:
            location, num_statements, count = line.rsplit(" ", 2)
        except ValueError:
            continue

        module_path = location.split(":", 1)[0]
        anchor = module_path.find("beacon-chain/")
        if anchor == -1:
            continue
        file_path = normalize_path(module_path[anchor:])
        if not matcher(file_path):
            continue

        statement_count = int(num_statements)
        covered = int(count) > 0
        stmt_totals = stmt_totals.add(
            CoverageTotals(
                covered_primary=statement_count if covered else 0,
                total_primary=statement_count,
            )
        )

    branch_totals = CoverageTotals()
    xml_path = report_dir / "coverage_bcov.xml"
    tree = ET.parse(xml_path)
    root = tree.getroot()
    for file_elem in root.findall("file"):
        file_path = normalize_path(file_elem.attrib["path"])
        if not matcher(file_path):
            continue

        for line_elem in file_elem.findall("lineToCover"):
            branches_to_cover = int(line_elem.attrib.get("branchesToCover", "0"))
            covered_branches = int(line_elem.attrib.get("coveredBranches", "0"))
            branch_totals = branch_totals.add(
                CoverageTotals(
                    covered_branch=covered_branches,
                    total_branch=branches_to_cover,
                )
            )

    return CoverageTotals(
        covered_primary=stmt_totals.covered_primary,
        total_primary=stmt_totals.total_primary,
        covered_branch=branch_totals.covered_branch,
        total_branch=branch_totals.total_branch,
    )



def parse_lcov(report_dir: Path, matcher: PathMatcher) -> CoverageTotals:
    info_path = report_dir / "coverage.info"
    totals = CoverageTotals()

    current_file: str | None = None
    lf = lh = brf = brh = 0

    def flush() -> None:
        nonlocal totals, current_file, lf, lh, brf, brh
        if current_file and matcher(current_file):
            totals = totals.add(
                CoverageTotals(
                    covered_primary=lh,
                    total_primary=lf,
                    covered_branch=brh,
                    total_branch=brf,
                )
            )
        current_file = None
        lf = lh = brf = brh = 0

    for raw_line in info_path.read_text().splitlines():
        line = raw_line.strip()
        if line.startswith("SF:"):
            flush()
            current_file = normalize_path(line[3:])
        elif line.startswith("LF:"):
            lf = int(line[3:])
        elif line.startswith("LH:"):
            lh = int(line[3:])
        elif line.startswith("BRF:"):
            brf = int(line[4:])
        elif line.startswith("BRH:"):
            brh = int(line[4:])
        elif line == "end_of_record":
            flush()

    flush()
    return totals



def parse_teku(report_dir: Path, matcher: PathMatcher) -> CoverageTotals:
    xml_path = report_dir / "coverage.xml"
    totals = CoverageTotals()
    package_stack: list[str] = []

    for event, elem in ET.iterparse(xml_path, events=("start", "end")):
        if event == "start" and elem.tag == "package":
            package_stack.append(normalize_path(elem.attrib["name"]))
            continue

        if event == "end" and elem.tag == "sourcefile":
            package_name = package_stack[-1] if package_stack else ""
            file_path = f"{package_name}/{elem.attrib['name']}" if package_name else elem.attrib["name"]
            file_path = normalize_path(file_path)
            if matcher(file_path):
                line_counter = None
                branch_counter = None
                for counter in elem.findall("counter"):
                    counter_type = counter.attrib["type"]
                    if counter_type == "LINE":
                        line_counter = counter
                    elif counter_type == "BRANCH":
                        branch_counter = counter

                if line_counter is not None:
                    covered_lines = int(line_counter.attrib["covered"])
                    missed_lines = int(line_counter.attrib["missed"])
                    totals = totals.add(
                        CoverageTotals(
                            covered_primary=covered_lines,
                            total_primary=covered_lines + missed_lines,
                        )
                    )

                if branch_counter is not None:
                    covered_branches = int(branch_counter.attrib["covered"])
                    missed_branches = int(branch_counter.attrib["missed"])
                    totals = totals.add(
                        CoverageTotals(
                            covered_branch=covered_branches,
                            total_branch=covered_branches + missed_branches,
                        )
                    )

            elem.clear()
            continue

        if event == "end" and elem.tag == "package":
            if package_stack:
                package_stack.pop()
            elem.clear()

    return totals


LODSTAR_STATEMENT_RE = re.compile(
    r"<span class=\"quiet\">Statements</span>\s*<span class='fraction'>(\d+)/(\d+)</span>"
)
LODSTAR_BRANCH_RE = re.compile(
    r"<span class=\"quiet\">Branches</span>\s*<span class='fraction'>(\d+)/(\d+)</span>"
)


def parse_lodestar(report_dir: Path, matcher: PathMatcher) -> CoverageTotals:
    src_dir = report_dir / "@lodestar/state-transition/src"
    totals = CoverageTotals()

    for html_path in sorted(src_dir.rglob("*.ts.html")):
        rel_path = normalize_path(str(html_path.relative_to(report_dir)))
        if not matcher(rel_path):
            continue

        text = html_path.read_text(errors="ignore")
        statement_match = LODSTAR_STATEMENT_RE.search(text)
        branch_match = LODSTAR_BRANCH_RE.search(text)
        if not statement_match or not branch_match:
            continue

        covered_statements, total_statements = map(int, statement_match.groups())
        covered_branches, total_branches = map(int, branch_match.groups())
        totals = totals.add(
            CoverageTotals(
                covered_primary=covered_statements,
                total_primary=total_statements,
                covered_branch=covered_branches,
                total_branch=total_branches,
            )
        )

    return totals


LODESTAR_COVERAGE_FINAL_PREFIX = "/node_modules/@lodestar/state-transition/src/"


def _lodestar_report_json_path(report_dir: Path) -> Path:
    return report_dir.parent / "report_json" / "coverage-final.json"


def _lodestar_norm_key(full_key: str, matcher: PathMatcher) -> str | None:
    anchor = full_key.find(LODESTAR_COVERAGE_FINAL_PREFIX)
    if anchor == -1:
        return None
    rel = "@lodestar/state-transition/src/" + full_key[anchor + len(LODESTAR_COVERAGE_FINAL_PREFIX) :]
    rel_html = rel + ".html"
    return rel_html if matcher(rel_html) else None


def _lodestar_branch_map(data: dict, full_key: str) -> dict[tuple, int]:
    out: dict[tuple, int] = {}
    for branch_id, meta in data[full_key]["branchMap"].items():
        loc = meta["loc"]
        sig = (
            meta["type"],
            (loc["start"]["line"], loc["start"]["column"]),
            (loc["end"]["line"], loc["end"]["column"]),
        )
        hits = data[full_key]["b"][branch_id]
        out[sig] = 1 if any(h > 0 for h in hits) else 0
    return out


def parse_lodestar_intersection(report_dir: Path, other_report_dir: Path, matcher: PathMatcher) -> CoverageTotals:
    totals = parse_lodestar(report_dir, matcher)

    current_json_path = _lodestar_report_json_path(report_dir)
    other_json_path = _lodestar_report_json_path(other_report_dir)
    if not current_json_path.exists():
        raise FileNotFoundError(f"missing Lodestar coverage-final.json: {current_json_path}")
    if not other_json_path.exists():
        raise FileNotFoundError(f"missing Lodestar coverage-final.json: {other_json_path}")

    current_data = json.loads(current_json_path.read_text())
    other_data = json.loads(other_json_path.read_text())

    current_keys = {
        norm: full_key
        for full_key in current_data
        if (norm := _lodestar_norm_key(full_key, matcher)) is not None
    }
    other_keys = {
        norm: full_key
        for full_key in other_data
        if (norm := _lodestar_norm_key(full_key, matcher)) is not None
    }

    covered_branch = 0
    total_branch = 0

    for rel_path in sorted(set(current_keys) & set(other_keys)):
        current_branches = _lodestar_branch_map(current_data, current_keys[rel_path])
        other_branches = _lodestar_branch_map(other_data, other_keys[rel_path])
        common_sigs = set(current_branches) & set(other_branches)
        total_branch += len(common_sigs)
        covered_branch += sum(current_branches[sig] for sig in common_sigs)

    return CoverageTotals(
        covered_primary=totals.covered_primary,
        total_primary=totals.total_primary,
        covered_branch=covered_branch,
        total_branch=total_branch,
    )


# ---------------------------------------------------------------------------
# Current file-level matchers
# ---------------------------------------------------------------------------


def lighthouse_matcher() -> PathMatcher:
    return make_matcher(
        include_prefixes=("consensus/state_processing/src/",),
        exclude_prefixes=(
            "consensus/state_processing/src/upgrade/",
        ),
        exclude_exact=(
            "consensus/state_processing/src/all_caches.rs",
            "consensus/state_processing/src/block_replayer.rs",
            "consensus/state_processing/src/consensus_context.rs",
            "consensus/state_processing/src/epoch_cache.rs",
            "consensus/state_processing/src/genesis.rs",
            "consensus/state_processing/src/lib.rs",
            "consensus/state_processing/src/macros.rs",
            "consensus/state_processing/src/metrics.rs",
            "consensus/state_processing/src/upgrade.rs",
            "consensus/state_processing/src/common/deposit_data_tree.rs",
            "consensus/state_processing/src/per_block_processing/block_signature_verifier.rs",
            "consensus/state_processing/src/per_block_processing/signature_sets.rs",
            "consensus/state_processing/src/per_block_processing/tests.rs",
            "consensus/state_processing/src/per_epoch_processing/tests.rs",
        ),
        exclude_regexes=(r"/errors\.rs$", r"/epoch_processing_summary\.rs$"),
    )



def prysm_matcher() -> PathMatcher:
    return make_matcher(
        include_prefixes=(
            "beacon-chain/core/transition/",
            "beacon-chain/core/blocks/",
            "beacon-chain/core/epoch/",
            "beacon-chain/core/helpers/",
            "beacon-chain/core/validators/",
            "beacon-chain/core/time/",
            "beacon-chain/core/altair/",
            "beacon-chain/core/capella/",
            "beacon-chain/core/deneb/",
            "beacon-chain/core/electra/",
            "beacon-chain/core/fulu/",
        ),
        exclude_prefixes=(
            "beacon-chain/core/transition/interop/",
        ),
        exclude_regexes=(
            r"_test\.go$",
            r"/testdata/",
            r"/BUILD\.bazel$",
            r"/skip_slot_cache\.go$",
            r"/trailing_slot_state_cache\.go$",
            r"/log\.go$",
            r"/metrics\.go$",
            r"/signature\.go$",
            r"/upgrade\.go$",
            r"/weak_subjectivity\.go$",
        ),
    )



def nimbus_matcher() -> PathMatcher:
    return make_matcher(
        include_regexes=(
            r"/beacon_chain/spec/state_transition\.nim$",
            r"/beacon_chain/spec/state_transition_block\.nim$",
            r"/beacon_chain/spec/state_transition_epoch\.nim$",
            r"/beacon_chain/spec/helpers\.nim$",
            r"/beacon_chain/spec/validator\.nim$",
            r"/beacon_chain/spec/beaconstate\.nim$",
        )
    )



def teku_matcher() -> PathMatcher:
    return make_matcher(
        include_exact=(
            "tech/pegasys/teku/spec/logic/StateTransition.java",
        ),
        include_prefixes=(
            "tech/pegasys/teku/spec/logic/common/block/",
            "tech/pegasys/teku/spec/logic/common/helpers/",
            "tech/pegasys/teku/spec/logic/common/operations/validation/",
            "tech/pegasys/teku/spec/logic/common/statetransition/epoch/",
            "tech/pegasys/teku/spec/logic/versions/",
        ),
        exclude_regexes=(
            r"/blockvalidator/",
            r"/results/",
            r"/OperationSignatureVerifier\.java$",
            r"/StateTransitionException\.java$",
            r"/ExecutionPayloadValidationResult\.java$",
        ),
    )



def lodestar_matcher() -> PathMatcher:
    return make_matcher(
        include_exact=(
            "@lodestar/state-transition/src/stateTransition.ts.html",
            "@lodestar/state-transition/src/slot/index.ts.html",
            "@lodestar/state-transition/src/block/index.ts.html",
            "@lodestar/state-transition/src/epoch/index.ts.html",
            "@lodestar/state-transition/src/block/initiateValidatorExit.ts.html",
            "@lodestar/state-transition/src/block/isValidIndexedAttestation.ts.html",
            "@lodestar/state-transition/src/block/slashValidator.ts.html",
            "@lodestar/state-transition/src/epoch/computeUnrealizedCheckpoints.ts.html",
            "@lodestar/state-transition/src/epoch/getAttestationDeltas.ts.html",
            "@lodestar/state-transition/src/epoch/getRewardsAndPenalties.ts.html",
            "@lodestar/state-transition/src/util/attestation.ts.html",
            "@lodestar/state-transition/src/util/attesterStatus.ts.html",
            "@lodestar/state-transition/src/util/balance.ts.html",
            "@lodestar/state-transition/src/util/blockRoot.ts.html",
            "@lodestar/state-transition/src/util/deposit.ts.html",
            "@lodestar/state-transition/src/util/epoch.ts.html",
            "@lodestar/state-transition/src/util/execution.ts.html",
            "@lodestar/state-transition/src/util/finality.ts.html",
            "@lodestar/state-transition/src/util/slot.ts.html",
            "@lodestar/state-transition/src/util/syncCommittee.ts.html",
            "@lodestar/state-transition/src/util/validator.ts.html",
        ),
        include_regexes=(
            r"@lodestar/state-transition/src/block/process.*\.ts\.html$",
            r"@lodestar/state-transition/src/epoch/process.*\.ts\.html$",
        ),
        exclude_prefixes=(
            "@lodestar/state-transition/src/cache/",
            "@lodestar/state-transition/src/signatureSets/",
            "@lodestar/state-transition/src/util/loadState/",
            "@lodestar/state-transition/src/constants/",
        ),
        exclude_exact=(
            "@lodestar/state-transition/src/metrics.ts.html",
            "@lodestar/state-transition/src/block/externalData.ts.html",
            "@lodestar/state-transition/src/block/types.ts.html",
            "@lodestar/state-transition/src/util/aggregator.ts.html",
            "@lodestar/state-transition/src/util/array.ts.html",
            "@lodestar/state-transition/src/util/blindedBlock.ts.html",
            "@lodestar/state-transition/src/util/calculateCommitteeAssignments.ts.html",
            "@lodestar/state-transition/src/util/computeAnchorCheckpoint.ts.html",
            "@lodestar/state-transition/src/util/domain.ts.html",
            "@lodestar/state-transition/src/util/genesis.ts.html",
            "@lodestar/state-transition/src/util/interop.ts.html",
            "@lodestar/state-transition/src/util/rootCache.ts.html",
            "@lodestar/state-transition/src/util/seed.ts.html",
            "@lodestar/state-transition/src/util/shufflingDecisionRoot.ts.html",
            "@lodestar/state-transition/src/util/signatureSets.ts.html",
            "@lodestar/state-transition/src/util/signingRoot.ts.html",
            "@lodestar/state-transition/src/util/sszBytes.ts.html",
            "@lodestar/state-transition/src/util/weakSubjectivity.ts.html",
        ),
    )


def eth2spec_matcher() -> PathMatcher:
    return make_matcher(
        include_regexes=(
            r"(^|.*/)eth2spec/(phase0|altair|bellatrix|capella|deneb|electra)/mainnet\.py$",
        ),
    )



def _resolve_eth2spec_report_dir(report_dir: Path) -> Path:
    candidates = [
        report_dir,
        report_dir / "report",
        report_dir.parent,
        report_dir.parent / "report",
    ]

    seen: set[Path] = set()
    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate in seen:
            continue
        seen.add(candidate)
        if (candidate / "coverage.json").exists():
            return candidate

    raise FileNotFoundError(
        f"missing Eth2spec coverage.json under {report_dir} or nearby flat/report layouts"
    )



def _eth2spec_report_entries(report_dir: Path, matcher: PathMatcher) -> list[tuple[str, dict]]:
    report_root = _resolve_eth2spec_report_dir(report_dir)
    json_path = report_root / "coverage.json"
    if not json_path.exists():
        raise FileNotFoundError(f"missing Eth2spec coverage.json: {json_path}")

    data = json.loads(json_path.read_text())
    entries: list[tuple[str, dict]] = []
    for file_path, info in data.get("files", {}).items():
        norm = normalize_path(file_path)
        rel = norm
        anchor = norm.find("/eth2spec/")
        if anchor != -1:
            rel = norm[anchor + 1 :]
        if matcher(norm) or matcher(rel):
            entries.append((norm, info))

    if not entries:
        raise FileNotFoundError(f"missing Eth2spec mainnet.py entry in {json_path}")
    return entries



def parse_eth2spec(report_dir: Path, matcher: PathMatcher) -> CoverageTotals:
    totals = CoverageTotals()
    for _, info in _eth2spec_report_entries(report_dir, matcher):
        summary = info.get("summary", {})
        totals = totals.add(
            CoverageTotals(
                covered_primary=int(summary.get("covered_lines", 0)),
                total_primary=int(summary.get("num_statements", 0)),
                covered_branch=int(summary.get("covered_branches", 0)),
                total_branch=int(summary.get("num_branches", 0)),
            )
        )
    return totals


CLIENTS = (
    ClientConfig(
        name="Lighthouse",
        primary_label="line",
        report_dir="lighthouse/report",
        parser=parse_lighthouse,
        matcher=lighthouse_matcher(),
    ),
    ClientConfig(
        name="Prysm",
        primary_label="statement",
        report_dir="prysm/report",
        parser=parse_prysm,
        matcher=prysm_matcher(),
    ),
    ClientConfig(
        name="Nimbus",
        primary_label="line",
        report_dir="nimbus/report",
        parser=parse_lcov,
        matcher=nimbus_matcher(),
    ),
    ClientConfig(
        name="Teku",
        primary_label="line",
        report_dir="teku/report",
        parser=parse_teku,
        matcher=teku_matcher(),
    ),
    ClientConfig(
        name="Lodestar",
        primary_label="statement",
        report_dir="lodestar/report",
        parser=parse_lodestar,
        matcher=lodestar_matcher(),
    ),
    ClientConfig(
        name="Eth2spec",
        primary_label="line",
        report_dir="eth2spec",
        parser=parse_eth2spec,
        matcher=eth2spec_matcher(),
    ),
)



def _resolve_client_root(root: Path) -> Path:
    direct_has_client = any((root / client.report_dir).exists() for client in CLIENTS)
    nested = root / "total-node-coverage"
    nested_has_client = any((nested / client.report_dir).exists() for client in CLIENTS)

    if direct_has_client:
        return root
    if nested_has_client:
        return nested
    return root



def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare baseline vs variant state-transition coverage on a fixed scope."
    )
    parser.add_argument(
        "baseline_root",
        help="Path to baseline accumulated coverage root or its total-node-coverage subdirectory",
    )
    parser.add_argument(
        "variant_root",
        help="Path to comparison accumulated coverage root or its total-node-coverage subdirectory",
    )
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser.parse_args()



def _totals_for(client: ClientConfig, coverage_root: Path, other_root: Path | None) -> CoverageTotals:
    report_dir = coverage_root / client.report_dir
    if client.name == "Lodestar" and other_root is not None:
        return parse_lodestar_intersection(report_dir, other_root / client.report_dir, client.matcher)
    return client.parser(report_dir, client.matcher)



def main() -> int:
    args = parse_args()
    baseline_root = _resolve_client_root(Path(args.baseline_root).resolve())
    variant_root = _resolve_client_root(Path(args.variant_root).resolve())

    rows = []
    for client in CLIENTS:
        baseline_report_dir = baseline_root / client.report_dir
        variant_report_dir = variant_root / client.report_dir
        if not baseline_report_dir.exists() and not variant_report_dir.exists():
            continue
        if not baseline_report_dir.exists() or not variant_report_dir.exists():
            missing = baseline_report_dir if not baseline_report_dir.exists() else variant_report_dir
            raise FileNotFoundError(f"missing report directory for {client.name}: {missing}")

        baseline = _totals_for(client, baseline_root, variant_root)
        variant = _totals_for(client, variant_root, baseline_root)
        rows.append(
            {
                "client": client.name,
                "primary_label": client.primary_label,
                "baseline": {
                    "covered_primary": baseline.covered_primary,
                    "total_primary": baseline.total_primary,
                    "covered_branch": baseline.covered_branch,
                    "total_branch": baseline.total_branch,
                },
                "variant": {
                    "covered_primary": variant.covered_primary,
                    "total_primary": variant.total_primary,
                    "covered_branch": variant.covered_branch,
                    "total_branch": variant.total_branch,
                },
                "delta": {
                    "covered_primary": variant.covered_primary - baseline.covered_primary,
                    "total_primary": variant.total_primary - baseline.total_primary,
                    "covered_branch": variant.covered_branch - baseline.covered_branch,
                    "total_branch": variant.total_branch - baseline.total_branch,
                },
            }
        )

    if args.format == "json":
        print(json.dumps(rows, indent=2))
        return 0

    for row in rows:
        print(f"<{row['client']}>")
        print(
            f"{row['primary_label']} coverage : "
            f"{row['baseline']['covered_primary']} / {row['baseline']['total_primary']} -> "
            f"{row['variant']['covered_primary']} / {row['variant']['total_primary']} "
            f"(delta covered {row['delta']['covered_primary']:+d}, delta total {row['delta']['total_primary']:+d})"
        )
        print(
            f"branch coverage : "
            f"{row['baseline']['covered_branch']} / {row['baseline']['total_branch']} -> "
            f"{row['variant']['covered_branch']} / {row['variant']['total_branch']} "
            f"(delta covered {row['delta']['covered_branch']:+d}, delta total {row['delta']['total_branch']:+d})"
        )
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
