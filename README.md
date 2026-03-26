# SpecTrum Artifact Guide

This repository contains the `spectec-core` pipeline used in the artifact, together with the differential testing and coverage-measurement scripts used for the paper experiments.

Consensus-SpecTec is the SpecTec formalization of the official [Ethereum Consensus Spec](https://github.com/ethereum/consensus-specs/tree/master/specs).

## Table of Contents

- [Setup](#setup)
- [Preparation (SSZ -> JSON)](#preparation-ssz---json)
- [RQ1: Bug-finding Effectiveness](#rq1-bug-finding-effectiveness)
  - [Test Generation](#test-generation)
  - [Differential Testing](#differential-testing)
- [RQ2: Diagnostic Power of Premise Coverage](#rq2-diagnostic-power-of-premise-coverage)
  - [Spec Coverage](#spec-coverage)
  - [Implementation Coverage](#implementation-coverage)
- [RQ3: Cross-Fork Bug Reproducibility and Maintainability](#rq3-cross-fork-bug-reproducibility-and-maintainability)
  - [Switching Capella Commands to Deneb](#switching-capella-commands-to-deneb)

## Setup

Build the artifact Docker image from the repository root.

```bash
docker build -t eth2test-artifact:coverage .
```

Run the container and move into the project directory.

```bash
docker run -it --name eth2test-artifact-test \
  eth2test-artifact:coverage /bin/bash

cd /workspace/spectec-core
```

All commands below are intended to be executed inside the container from `/workspace/spectec-core` unless stated otherwise.

## Preparation (SSZ -> JSON)

The official Ethereum consensus tests are supplied in SSZ format. To run them against `spectec-core`, they must first be converted to JSON.

Three Capella state-transition directories are used in the paper workflow: `sanity/blocks`, `random/random`, and `finality/finality`.

```bash
python3 Converter/generate_json_test_cases.py \
  Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests \
  --fork capella \
  --output-dir capella-tests -v

python3 Converter/generate_json_test_cases.py \
  Converter/OfficialTestSuite/capella/random/random/pyspec_tests \
  --fork capella \
  --output-dir capella-tests -v

python3 Converter/generate_json_test_cases.py \
  Converter/OfficialTestSuite/capella/finality/finality/pyspec_tests \
  --fork capella \
  --output-dir capella-tests -v
```

For multi-block inputs, the converter runs `eth2spec` to generate `post.json`. For invalid cases, the error message produced by `eth2spec` is saved as `error.txt`.

## RQ1: Bug-finding Effectiveness

RQ1 in the paper is:

> **Bug-finding effectiveness.** Can the framework uncover cross-client divergence cases?

The artifact reproduces RQ1 in two stages: generating tests from uncovered premises, then running differential testing across the six implementations.

## Test Generation

### Baseline premise coverage

From-scratch baseline premise coverage can be measured with:

```bash
nohup ./spectec-core eth coverage -v \
  --spec-dir spec/spec_capella \
  --test-dir capella-tests \
  --checkpoint capella-baseline.ckpt \
  --save-interval 1 \
  --node-coverage.level full \
  --no-validate \
  --max-slot-gap 32 \
  --node-coverage.output capella-baseline.txt
```

This run may take multiple hours. The artifact therefore also provides precomputed Capella baseline coverage inputs:

- `testgen_data/capella/novalidate/baseline.ckpt`
- `testgen_data/capella/novalidate/baseline.txt`
- `testgen_data/capella/target_premises.txt`

### Generate tests from target premises

Using the provided baseline checkpoint and audited target premises, generate Capella tests with:

```bash
./spectec-core eth testgen \
  --spec-dir spec/spec_capella \
  --coverage testgen_data/capella/novalidate/baseline.ckpt \
  --premises-file testgen_data/capella/target_premises.txt \
  --test-dir capella-tests \
  --output capella-testgen \
  --coverage-level 7
```

### Convert generated JSON tests back to SSZ

The generator emits mutated JSON tests. To run them through the differential testing pipeline, convert them back to SSZ.

```bash
python3 convert_testgen_json_to_ssz.py \
  --input-dir ./capella-testgen \
  --fork capella \
  --output-dir ./capella-testgen-ssz
```

The converted SSZ tests will be placed under `./capella-testgen-ssz/testgen/spectec-generated`.

## Differential Testing

`diff_testing.py` runs the same state-transition inputs across Lighthouse, Prysm, Nimbus, Teku, Lodestar, and `eth2spec`, then compares outcomes and post-states.

For the official Capella baseline suites, run:

```bash
python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_sanity_block_test \
  --enable-coverage \
  --cleanup-after-report

python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/random/random/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_random_test \
  --enable-coverage \
  --cleanup-after-report

python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/finality/finality/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_finality_test \
  --enable-coverage \
  --cleanup-after-report
```

To run the generated test suite, use:

```bash
python3 diff_testing.py \
  --test-suite ./capella-testgen-ssz/testgen/spectec-generated \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_SpecTrum \
  --enable-coverage \
  --cleanup-after-report
```

To inspect the differential-testing outputs:

```bash
python3 check_results.py ./results/coverage_SpecTrum

python3 check_postState.py ./results/coverage_SpecTrum --fork-version capella
```

`check_results.py` summarizes mismatches, failures, and crashes from `Output_Status_*.csv`. `check_postState.py` compares the generated `poststate_*.ssz` files across implementations.

## RQ2: Diagnostic Power of Premise Coverage

RQ2 in the paper is:

> **Diagnostic power of premise coverage.** What does premise coverage reveal that code-level coverage metrics do not?

The artifact supports two complementary measurements for RQ2: specification-level premise coverage and implementation-level code coverage.

## Spec Coverage

```bash
nohup ./spectec-core eth coverage -v \
  --spec-dir spec/spec_capella \
  --test-dir capella-tests \
  --checkpoint capella-baseline.ckpt \
  --save-interval 1 \
  --node-coverage.level full \
  --no-validate \
  --max-slot-gap 32 \
  --node-coverage.output capella-baseline.txt
```

```bash
nohup ./spectec-core eth coverage -v \
  --spec-dir spec/spec_capella \
  --test-dir capella-testgen \
  --checkpoint capella-testgen.ckpt \
  --save-interval 1 \
  --node-coverage.level full \
  --no-validate \
  --max-slot-gap 32 \
  --node-coverage.output capella-testgen.txt
```

The second command is the generated-test coverage pass. In the paper workflow, this stage was run after filtering out ill-formed generated cases. For artifact inspection, the repository also includes precomputed coverage artifacts under `testgen_data/capella/`, including:

- `cov_baseline.ckpt`
- `cov_testgen.ckpt`
- `cov_baseline+testgen.ckpt`
- `coverage.txt`
- `coverage_both.txt`
- `cov_testgen.txt`

Useful checkpoint utilities are:

```bash
./spectec-core eth checkpoint merge file1.ckpt file2.ckpt \
  --output file1+2.ckpt \
  --spec-dir spec/spec_capella

./spectec-core eth checkpoint report capella-testgen.ckpt \
  --node-coverage.level full \
  --spec-dir spec/spec_capella
```

The `--save-interval` flag controls how often intermediate coverage state is written to the checkpoint. Coverage can also be resumed with `--resume intermediate.ckpt`.

## Implementation Coverage

Implementation coverage is measured with `diff_testing.py --enable-coverage`, which produces per-client coverage reports for the official suites and the generated suite.

First, build the baseline accumulated implementation-coverage report from the three official Capella suites:

```bash
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  ./results/coverage_finality_test \
  --final-output-dir ./results/accumulated_coverage_report
```

Next, build the combined report that adds the generated tests:

```bash
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  ./results/coverage_finality_test \
  ./results/coverage_SpecTrum \
  --final-output-dir ./results/accumulated_coverage_report_with_SpecTrum
```

Then compare the baseline and combined accumulated reports:

```bash
python3 compare_state_transition_coverage.py \
  ./results/accumulated_coverage_report \
  ./results/accumulated_coverage_report_with_SpecTrum
```

This script reports per-client line and branch deltas between the baseline and combined test suites.

## RQ3: Cross-Fork Bug Reproducibility and Maintainability

RQ3 in the paper is:

> **Cross-fork bug reproducibility and maintainability.** Do bugs in shared logic affect multiple forks?

The RQ3 workflow reuses the same pipeline as RQ1, but switches the fork-specific inputs from Capella to Deneb.

The repository already contains Deneb coverage and checkpoint data under `testgen_data/deneb/`, including baseline and combined checkpoints and Deneb target-premise files.

## Switching Capella Commands to Deneb

To rerun the RQ1 pipeline for Deneb, apply the following replacements.

- Replace every `capella` fork argument with `deneb` in `Converter/generate_json_test_cases.py`, `convert_testgen_json_to_ssz.py`, and `diff_testing.py`.
- Replace `--fork-version capella` with `--fork-version deneb`.
- Replace `--fork capella` with `--fork deneb`.
- Replace `spec/spec_capella` with `spec/spec_deneb`.
- Replace `Converter/OfficialTestSuite/capella/...` with the corresponding `Converter/OfficialTestSuite/deneb/...` directories.
- Replace Capella checkpoint and premise inputs in `testgen_data/capella/...` with the Deneb files in `testgen_data/deneb/...`.

In other words, the pipeline itself does not change: only the fork-specific directories, checkpoint files, target-premise files, and fork flags change.
