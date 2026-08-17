# SpecTrum Artifact

Artifact for **"SpecTrum: Specification-Guided Differential Fuzzing for Ethereum Consensus Clients."**

It contains **Consensus-SpecTec** (the Ethereum consensus spec mechanized in SpecTec), the SpecTec compiler/interpreter, the specification-guided test generator, the deterministic Random/Extreme control generators, the differential-testing harness over six implementations (Lighthouse, Lodestar, Nimbus, Prysm, Teku, and the reference `eth2spec`), and the analysis scripts.

- **[Part A: Getting Started](#part-a-getting-started):** install and smoke test in under 30 minutes.
- **[Part B: Step-by-Step](#part-b-step-by-step):** reproduce each research question, keyed to the paper's claims and tables.
- **[Part C: Reuse and extension](#part-c-reuse-and-extension):** the directory layout and how to extend the pipeline to new forks, clients, and specifications.

Read [`REQUIREMENTS.md`](REQUIREMENTS.md) first. The artifact targets **x86-64 (amd64)**. Licensing: [`LICENSE`](LICENSE) (first-party, Apache-2.0) and [`NOTICE`](NOTICE) (bundled clients).

---

# Part A: Getting Started

## A.1 Prerequisites

An amd64 Linux Docker host with ~80 to 120 GB free disk (see [`REQUIREMENTS.md`](REQUIREMENTS.md)). No other host software is needed. The complete RQ3 control-generation run in [B.8](#b8-rq3-contribution-of-specification-guidance-c5) additionally needs at least 120 GB free on its output filesystem, beyond the space used by the Docker image.

## A.2 Obtain the image

```bash
# Recommended: load the self-contained tarball shipped with the artifact
docker load -i spectrum-image.tar.gz

# Or pull the Docker Hub mirror
docker pull kaistplrg/spectrum:ase2026.2
```

To build the image yourself (not needed for evaluation), see [C.2](#c2-build-from-source).

## A.3 Start the container

```bash
docker run -it --name spectrum kaistplrg/spectrum:ase2026.2 /bin/bash
cd /workspace/spectec-core
```

All commands below run **inside the container** from `/workspace/spectec-core`.

**Hosts with >255 CPUs.** Teku derives thread-pool sizes from the visible CPU count and rejects values above 255. If you hit this limit, restrict the CPUs the container sees:

```bash
docker run -it --cpuset-cpus=0-15 --name spectrum kaistplrg/spectrum:ase2026.2 /bin/bash
```

## A.4 Smoke test (< 30 min)

**1. Validate Consensus-SpecTec** (5 single-block cases, ~1 min). Convert to JSON, then validate state roots with `eth coverage` (without `--no-validate`):

```bash
CASES="empty_block_transition bls_change deposit_in_block attester_slashing full_random_operations_0"
SRC=Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests
mkdir -p smoke-suite/sanity/blocks/pyspec_tests
for c in $CASES; do cp -r "$SRC/$c" smoke-suite/sanity/blocks/pyspec_tests/; done

python3 Converter/generate_json_test_cases.py \
  smoke-suite/sanity/blocks/pyspec_tests --fork capella --output-dir smoke-tests -v

./spectec-core eth coverage -v \
  --spec-dir spec/spec_capella --test-dir smoke-tests \
  --node-coverage.level summary --max-slot-gap 32 \
  --checkpoint smoke.ckpt --node-coverage.output smoke.txt
```

Expect `state_transition: 5/5 passed, 0 failed`.

**2. Differential test the same 5 cases** across the six implementations (~20 s, reuses `smoke-suite/` from step 1):

```bash
python3 diff_testing.py \
  --test-suite smoke-suite/sanity/blocks/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/smoke_diff

python3 check_results.py ./results/smoke_diff
```

Expect 0 mismatch and 0 crash cases (all six implementations agreed). Proceed to Part B.

---

# Part B: Step-by-Step

## B.1 Claims map

| # | Claim | Paper | Section |
| --- | --- | --- | --- |
| C1 | Consensus-SpecTec passes 910 official tests | §4 | [B.3](#b3-validate-consensus-spectec-c1) |
| C2 | 27 divergences (4 Class-A, 23 Class-B), 6 categories | Table 1 | [B.6](#b6-rq1-bug-finding-effectiveness-c2) |
| C3 | Premise coverage 46.3% → 91.1% | §7.2 | [B.7 Spec Coverage](#spec-coverage-c3) |
| C4 | Code-coverage gains modest, complementary | Table 2 | [B.7 Implementation Coverage](#implementation-coverage-c4) |
| C5 | Under an equal budget, SpecTrum finds 27 divergences vs. Random's 12 and Extreme's 16 | Table 3 | [B.8](#b8-rq3-contribution-of-specification-guidance-c5) |
| C6 | All 27 reproduce under Deneb, ~26-line cross-fork extension | §7.4 | [B.9](#b9-rq4-cross-fork-reproducibility-c6) |

Research questions (verbatim):

> **RQ1.** Can SpecTrum uncover cross-client divergence cases?
> **RQ2.** What does premise coverage reveal that code coverage does not?
> **RQ3.** Does SpecTrum outperform unguided mutation under an equal budget?
> **RQ4.** Do bugs in shared logic affect multiple forks?

## B.2 Contents

- [B.3 Validate Consensus-SpecTec (C1)](#b3-validate-consensus-spectec-c1)
- [B.4 Preparation: SSZ to JSON](#b4-preparation-ssz-to-json)
- [B.5 Test generation](#b5-test-generation)
- [B.6 RQ1: Bug-finding effectiveness (C2)](#b6-rq1-bug-finding-effectiveness-c2)
- [B.7 RQ2: Diagnostic power of premise coverage (C3, C4)](#b7-rq2-diagnostic-power-of-premise-coverage-c3-c4)
- [B.8 RQ3: Contribution of specification guidance (C5)](#b8-rq3-contribution-of-specification-guidance-c5)
- [B.9 RQ4: Cross-fork reproducibility (C6)](#b9-rq4-cross-fork-reproducibility-c6)

## B.3 Validate Consensus-SpecTec (C1)

The paper validates Consensus-SpecTec against 910 official tests: 581 state-transition tests plus 329 unit tests (epoch processing, operations, sanity slots). Each test runs through the interpreter and is checked against its expected output. The full run takes roughly 10 to 12 hours.

**State-transition tests (581).** Convert the state-transition suites ([B.4](#b4-preparation-ssz-to-json)), then run `eth coverage` without `--no-validate`:

```bash
./spectec-core eth coverage -v \
  --spec-dir spec/spec_capella --test-dir capella-tests \
  --node-coverage.level summary --max-slot-gap 32 \
  --checkpoint validate.ckpt --node-coverage.output validate.txt
```

`--max-slot-gap 32` skips 18 cases whose block is far ahead of the pre-state slot, each case taking around 20~30x compared to a single-slot transition, and reports `state_transition: 563/581 passed, 0 failed, 18 skipped` in roughly half the time. Raising the cutoff (e.g., `--max-slot-gap 512`) validates all 581 and reports `581/581 passed, 0 failed`; this is the full run quoted above. The A.4 smoke test runs a 5-case subset (~1 min).

**Unit tests (329).** Each unit category has its own `eth run` subcommand (the default spec dir is the target fork's, so `--spec` is not needed). Convert the unit suites, then validate each category:

```bash
SUITE=Converter/OfficialTestSuite/capella

# Convert the unit suites to JSON
for d in $SUITE/epoch_processing/*/ $SUITE/operations/*/ $SUITE/sanity/slots; do
  python3 Converter/generate_json_test_cases.py "$d/pyspec_tests" --fork capella --output-dir capella-tests
done

# Epoch processing (subcommand:directory; two names differ)
for m in justification:justification_and_finalization rewards:rewards_and_penalties \
         inactivity-updates:inactivity_updates registry-updates:registry_updates \
         slashings:slashings eth1-data-reset:eth1_data_reset \
         effective-balance-updates:effective_balance_updates slashings-reset:slashings_reset \
         randao-mixes-reset:randao_mixes_reset historical-summaries-update:historical_summaries_update \
         participation-flag-updates:participation_flag_updates; do
  ./spectec-core eth run epoch ${m%%:*} --suite-dir capella-tests/epoch_processing/${m##*:}
done

# Operations (subcommand is the directory name with underscores written as hyphens)
for op in attestation attester_slashing block_header bls_to_execution_change deposit \
          execution_payload proposer_slashing sync_aggregate voluntary_exit withdrawals; do
  ./spectec-core eth run operations ${op//_/-} --suite-dir capella-tests/operations/$op
done

# Sanity slots
./spectec-core eth run slots --suite-dir capella-tests/sanity/slots
```

Each run prints `N/N passed, 0 failed`.

## B.4 Preparation: SSZ to JSON

Official tests are SSZ, `spectec-core` consumes JSON. Convert the three Capella state-transition suites used in the paper:

```bash
for suite in sanity/blocks random/random finality; do
  python3 Converter/generate_json_test_cases.py \
    Converter/OfficialTestSuite/capella/$suite/pyspec_tests \
    --fork capella --output-dir capella-tests -v
done
```

Multi-block inputs run `eth2spec` to produce `post.json`. Invalid cases save the `eth2spec` error to `error.txt`.

## B.5 Test generation

**Note.** The provided `.ckpt` files carry an older spec hash because we trimmed comments, not the spec. `testgen` loads them directly. The `checkpoint` utilities ([B.7](#spec-coverage-c3)) need `--ignore-spec-mismatch`, already included below.

Generate Capella tests from the provided baseline checkpoint and target premises, then convert the mutated JSON back to SSZ:

```bash
./spectec-core eth testgen \
  --spec-dir spec/spec_capella \
  --coverage testgen_data/capella/baseline.ckpt \
  --premises-file testgen_data/capella/target_premises.txt \
  --test-dir capella-tests \
  --output capella-testgen \
  --coverage-level 7

python3 convert_testgen_json_to_ssz.py \
  --input-dir ./capella-testgen \
  --fork capella \
  --output-dir ./capella-testgen-ssz
```

Converted tests are saved in `./capella-testgen-ssz/testgen/spectec-generated`.

## B.6 RQ1: Bug-finding effectiveness (C2)

Reproduces **Table 1**. `diff_testing.py` runs each input across all six implementations and compares outcomes and post-states (accept/reject disagreement, post-state disagreement, crash). Test generation is deterministic. The divergent cases, after deduplication, are the 27 of Table 1 (4 Class-A consensus failures, 23 Class-B liveness failures, 6 root-cause categories).

Run the three official suites and the generated suite:

```bash
for out in coverage_sanity_block_test:sanity/blocks \
           coverage_random_test:random/random \
           coverage_finality_test:finality; do
  name=${out%%:*}; suite=${out##*:}
  python3 diff_testing.py \
    --test-suite Converter/OfficialTestSuite/capella/$suite/pyspec_tests \
    --test-type state-transition --workflow sequential \
    --fork-version capella --output-base ./results/$name \
    --enable-coverage --cleanup-after-report
done

python3 diff_testing.py \
  --test-suite ./capella-testgen-ssz/testgen/spectec-generated \
  --test-type state-transition --workflow sequential \
  --fork-version capella --output-base ./results/coverage_SpecTrum \
  --enable-coverage --cleanup-after-report
```

Inspect divergences:

```bash
python3 check_results.py ./results/coverage_SpecTrum
python3 check_postState.py ./results/coverage_SpecTrum --fork-version capella
```

`check_results.py` summarizes mismatches/failures/crashes from `Output_Status_*.csv`. `check_postState.py` compares `poststate_*.ssz` across implementations. Differing post-states on an accepted block are the Class-A failures.

## B.7 RQ2: Diagnostic power of premise coverage (C3, C4)

Two complementary measurements: spec-level premise coverage (§7.2) and implementation-level code coverage (Table 2).

### Baseline premise coverage

From scratch (multiple hours, precomputed inputs provided):

```bash
nohup ./spectec-core eth coverage -v \
  --spec-dir spec/spec_capella --test-dir capella-tests \
  --checkpoint capella-baseline.ckpt --save-interval 1 \
  --node-coverage.level full --no-validate --max-slot-gap 32 \
  --node-coverage.output capella-baseline.txt
```

This run takes multiple hours, so the precomputed result ships under `testgen_data/capella/`:

- `baseline.ckpt`. Serialized baseline coverage (which seed reached which premise). Consumed by `testgen` (B.5) and replayed by `checkpoint report`.
- `baseline.txt`. The baseline premise-coverage report.
- `target_premises.txt`. The audited falsifiable premises `testgen` targets, with tautologies, closing branches, and out-of-scope premises removed.
- `baseline+testgen.ckpt`, `baseline+testgen.txt`. Coverage after adding the generated tests (the combined premise coverage of §7.2).

### Spec coverage (C3)

Reproduces the premise-coverage result of §7.2 (130/281 = 46.3% → 256/281 = 91.1%).

Some generated JSON tests fail SSZ conversion (e.g. variable-length arrays where SSZ expects a fixed vector). Filter them for a fair comparison, then measure coverage:

```bash
python3 filter_tests.py capella-testgen \
  capella-testgen-ssz/testgen/spectec-generated capella-testgen-filtered

nohup ./spectec-core eth coverage -v \
  --spec-dir spec/spec_capella --test-dir capella-testgen-filtered \
  --checkpoint capella-testgen.ckpt --save-interval 1 \
  --node-coverage.level full --no-validate --max-slot-gap 32 \
  --node-coverage.output capella-testgen.txt
```

The precomputed `baseline.txt` and `baseline+testgen.txt` are the raw premise-coverage reports, in which falsified premises rise from 130/392 to 256/392. The 46.3% → 91.1% figures restrict this to the 281 falsifiable premises (392 minus the 111 unfalsifiable of §5), giving 130/281 → 256/281. Every falsified premise lies inside the falsifiable set, so the restriction moves the denominator only. The per-premise classification behind the split is `testgen_data/capella/premise_classification.tsv`.

Checkpoint utilities:

```bash
./spectec-core eth checkpoint merge file1.ckpt file2.ckpt \
  --output file1+2.ckpt --spec-dir spec/spec_capella --ignore-spec-mismatch

./spectec-core eth checkpoint report capella-testgen.ckpt \
  --node-coverage.level full --spec-dir spec/spec_capella --ignore-spec-mismatch
```

`--save-interval` controls checkpoint frequency. `--resume intermediate.ckpt` resumes a run.

### Implementation coverage (C4)

Reproduces **Table 2** (modest per-client line/branch gains, premise and code coverage are complementary). Build the accumulated coverage reports with and without the generated tests, then compare:

```bash
python3 diff_testing.py --generate-final-coverage \
  ./results/coverage_sanity_block_test ./results/coverage_random_test \
  ./results/coverage_finality_test \
  --final-output-dir ./results/accumulated_coverage_report

python3 diff_testing.py --generate-final-coverage \
  ./results/coverage_sanity_block_test ./results/coverage_random_test \
  ./results/coverage_finality_test ./results/coverage_SpecTrum \
  --final-output-dir ./results/accumulated_coverage_report_with_SpecTrum

python3 compare_state_transition_coverage.py \
  ./results/accumulated_coverage_report \
  ./results/accumulated_coverage_report_with_SpecTrum
```

The reported per-client line/branch deltas are the Base vs. Combined columns of Table 2.

## B.8 RQ3: Contribution of specification guidance (C5)

Reproduces **Table 3**. Random and Extreme are unguided controls over the same 581 Capella state-transition seed pairs used by SpecTrum. They use only the public SSZ type structure: neither reads SpecTrum premises, provenance, or target information. Both select the same realizable normalized field path and concrete indices; Random assigns a seeded type-valid PRNG value, while Extreme draws from a seeded boundary-value pool. Each case mutates one atomic SSZ path in either `BeaconState` or `SignedBeaconBlock.message` (the outer `SignedBeaconBlock.signature` is excluded).

### Generate the Random and Extreme controls

Run the complete generation pipeline inside the artifact container from `/workspace/spectec-core`:

```bash
./tools/run_rq3_random_extreme_baselines.sh ./results/rq3-controls 4
```

The final argument is the number of parallel seed workers; changing it does not change the generated cases. The script:

1. Sequentially replays the public `finality`, `random/random`, and `sanity/blocks` suites to flatten exactly 581 `(BeaconState, SignedBeaconBlock)` seed pairs.
2. Derives 65 `BeaconState` and 80 `BeaconBlock` normalized atomic paths from the Capella v1.6.0 SSZ schema.
3. Generates one deterministic 21,444-case raw suite for each strategy.
4. Builds the testing suites by excluding only cases with `block.message.slot - state.slot > 32` (a gap of exactly 32 is retained).
5. Validates the case counts, slot-gap subsets, and Random/Extreme path-selection equality.

The output is:

```text
results/rq3-controls/
├── capella_seed581/
├── random/
│   ├── raw/                 # 21,444 generated cases
│   └── gap32/               # 20,557 testing-ready cases
├── extreme/
│   ├── raw/                 # 21,444 generated cases
│   └── gap32/               # 20,670 testing-ready cases
├── logs/
└── reproduction_report.json
```

A successful run ends with `RQ3 Random/Extreme reproduction complete`; `reproduction_report.json` contains `"passed": true` and confirms 21,444 exact Random/Extreme path-selection matches.

To execute the controls, use `random/gap32` or `extreme/gap32` as `--test-suite` in the `diff_testing.py` workflow from [B.6](#b6-rq1-bug-finding-effectiveness-c2); all other Capella arguments are unchanged. The precomputed combined premise-coverage reports used for Table 3 are `testgen_data/capella/baseline+random.txt` and `testgen_data/capella/baseline+extreme.txt` (with the corresponding `.ckpt` files). They report 193 and 187 falsified premises, respectively, compared with 130 for the official-test baseline and 256 for SpecTrum. As in [B.7](#spec-coverage-c3), Table 3 restricts the denominator to the 281 classified falsifiable premises; the numerators are unchanged.

## B.9 RQ4: Cross-fork reproducibility (C6)

Reproduces §7.4: all 27 divergences recur under Deneb, and extending Consensus-SpecTec Capella to Deneb inserts ~26 lines (~1%) across 10 of 22 files.

The Deneb mechanization is under `spec/spec_deneb/`. Its diff against `spec/spec_capella/` spans those 10 files, with 26 net insertions. Deneb checkpoints and premises ship under `testgen_data/deneb/`.

The RQ4 pipeline is identical to RQ1 with fork-specific inputs swapped:

| Capella | Deneb |
| --- | --- |
| `--fork capella` / `--fork-version capella` | `--fork deneb` / `--fork-version deneb` |
| `spec/spec_capella` | `spec/spec_deneb` |
| `Converter/OfficialTestSuite/capella/...` | `Converter/OfficialTestSuite/deneb/...` |
| `testgen_data/capella/...` | `testgen_data/deneb/...` |
| `capella` fork args in `generate_json_test_cases.py`, `convert_testgen_json_to_ssz.py`, `diff_testing.py` | `deneb` |

The pipeline itself is unchanged. Only fork directories, checkpoints, premises, and flags differ. That is the maintainability result of C6.

---

# Part C: Reuse and extension

The pipeline is fork-agnostic and client-pluggable. This part documents the directory layout, how to rebuild the image, and the three extension points: a new fork, a new client, and a different specification.

## C.1 Directory structure

```
artifact-eval/
├── README.md, STATUS.md, REQUIREMENTS.md, LICENSE, NOTICE, AUTHORS
├── Dockerfile                       Reproducible build of the full environment
├── Makefile                         Build the spectec-core binary (make exe)
│
├── spec/                            Consensus-SpecTec mechanization, one dir per fork
│   ├── spec_capella/                22 .spectec files
│   └── spec_deneb/
│
├── spectec/                         Fork-agnostic SpecTec toolchain (OCaml)
│   ├── bin/                         CLI entry point (spectec-core)
│   ├── lib/                         Compiler, interpreter, generator, coverage
│   ├── targets/                     Ethereum and P4 target definitions
│   └── test/                        Elaboration, structuring, interpreter tests
│
├── Converter/                       SSZ <-> JSON conversion and official suites
│   ├── OfficialTestSuite/           capella/ and deneb/ official tests (SSZ)
│   ├── generate_json_test_cases.py
│   └── ...
│
├── tools/                           Deterministic RQ3 control generation
│   ├── collect_capella_flattened_seed581.py
│   ├── generate_capella_path_uniform_baseline_pyspec.py
│   ├── filter_capella_suite_by_slot_gap.py
│   ├── run_rq3_random_extreme_baselines.sh
│   └── validate_capella_rq3_baselines.py
│
├── modified_code/                   Per-client patches, one dir per client
│   └── lighthouse/ prysm/ nimbus/ teku/ lodestar/
│
├── testgen_data/                    Precomputed checkpoints and target premises
│   ├── capella/                     baseline.*, baseline+testgen.*, baseline+random.*, baseline+extreme.*,
│   │                                target_premises.txt, premise_classification.tsv
│   └── deneb/
│
├── diff_testing.py                  Six-implementation differential harness
├── check_results.py                 Summarize divergences (Output_Status_*.csv)
├── check_postState.py               Compare post-states (poststate_*.ssz)
├── compare_state_transition_coverage.py   Per-client coverage deltas
├── filter_tests.py                  Drop SSZ-invalid generated tests
└── convert_testgen_json_to_ssz.py   Generated JSON -> SSZ
```

## C.2 Build from source

Required only to extend the artifact (C.3 to C.5).

```bash
docker build -t kaistplrg/spectrum:ase2026.2 .
```

Best-effort: the build needs network access and takes hours on a 16-core machine. It clones the five upstream repositories at the commits pinned in `REQUIREMENTS.md`, so results are stable, but package mirrors and GitHub can still fail transiently.

## C.3 Add a new fork

The pipeline does not change across forks. Only fork-specific inputs and flags do, as the Capella-to-Deneb swap table in [B.9](#b9-rq4-cross-fork-reproducibility-c6) shows. To target a new fork, supply the matching inputs:

- `spec/spec_<fork>/`, the Consensus-SpecTec mechanization for the fork.
- `testgen_data/<fork>/`, a baseline checkpoint and a `target_premises.txt`.
- `Converter/OfficialTestSuite/<fork>/`, the official suites in SSZ form.
- The `eth2spec` build for the fork (produced by the image from `consensus-specs`).

Then pass `--spec-dir spec/spec_<fork>`, `--fork <fork>`, and `--fork-version <fork>` to the commands in Part B. The shipped Deneb mechanization shows the scale: its diff against Capella is about 26 lines (~1%).

## C.4 Add a new client

Each client is integrated at three points, mirroring the five existing clients:

1. **Register.** Add the tool name to `BASE_CLIENT_TOOLS` in `diff_testing.py`.
2. **Patch.** If the client does not provide a separate state-transition entrypoint, patch and add the patched code to `modified_code/<client>/` following the existing per-client directories.
3. **Build.** Add a `Dockerfile` stage that clones the client at a pinned tag, builds it, and applies the patch.

To include the client in the Table 2 coverage rows, also add its source-filter block (the `*_CORE_INCLUDE_PREFIXES` and `*_IGNORE_PATTERNS` definitions in `diff_testing.py`).

## C.5 Retarget the toolchain to a different specification

The `spectec-core eth` command group is the reuse API. Its subcommands (defined in `spectec/bin/main.ml` and `spectec/bin/targets/eth.ml`) operate over any spec directory:

- `coverage` measures premise coverage for a spec and test directory.
- `testgen` generates tests from a baseline checkpoint and a premises file.
- `checkpoint merge` / `checkpoint report` combine and summarize coverage checkpoints.

The main knobs are `--spec-dir`, `--premises-file`, `--coverage`, `--node-coverage.level`, `--save-interval`, and `--resume`. Premise coverage and the generator are general extensions to SpecTec, which may be applied to any SpecTec mechanization.
