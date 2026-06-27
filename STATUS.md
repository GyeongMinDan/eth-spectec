# STATUS

We apply for three ASE 2026 badges: Available, Functional, and Reusable.

## Available

Deposited on Zenodo with a permanent DOI. The record holds the full artifact: documentation, `Dockerfile` plus source, and a self-contained pre-built image (`docker save` tarball). GitHub and Docker Hub are convenience mirrors only. The Zenodo deposit is the archival copy of record.

## Functional

- **Documented.** `README.md` has a Getting Started guide with a <30 min smoke test, plus step-by-step reproduction in which every step is keyed to a paper claim (the C1 to C5 claims map in README Part B.1).
- **Complete.** Includes Consensus-SpecTec (Capella and Deneb), the extended SpecTec toolchain, the test generator, the six-implementation differential harness, the analysis scripts, and precomputed coverage checkpoints (`testgen_data/`).
- **Exercisable, with verification and validation.** Consensus-SpecTec is validated against the 910 official tests (`make test`). The differential pipeline reproduces the divergence and coverage results reported in the paper.

### Claims reproduced

| Claim | Paper | Reproduced by |
| --- | --- | --- |
| Consensus-SpecTec passes 910 official tests | §4 | `make test` |
| 24 divergences (10 Class-A, 14 Class-B), 6 categories | Table 1 | RQ1 (`diff_testing.py`, `check_results.py`, `check_postState.py`) |
| Premise coverage 61.8% → 91.2% (66.0% → 97.4% excl. unattempted) | Table 2 | RQ2 (`spectec-core eth coverage`) |
| Code coverage modest increment | Table 3 | RQ2 (`diff_testing.py --enable-coverage`, `compare_state_transition_coverage.py`) |
| All 24 divergences reproduce under Deneb, cross-fork extension ~28 lines (~1%) | §7.3 | RQ3 (pipeline on `spec/spec_deneb`) |

### Not directly reproduced

- Absolute runtimes (paper used an AMD Ryzen 9 9950X / 128 GB RAM, makes no claims on runtime). Other hardware should yield the same results at different speeds.

## Reusable

- **Modular boundaries.** The mechanization (`spec/spec_<fork>/`), the fork-agnostic toolchain (`spectec/`), and the harness (`diff_testing.py` with per-client patches under `modified_code/<client>/`) are separate. Adding a fork, client, or test suite can be done by touching one of them. README Part C documents how.
- **Standalone components.** Consensus-SpecTec runs as a reference oracle by itself. Premise coverage, the checkpoint tooling, and the generator (driven by `--spec-dir` and `--premises-file`) work for any SpecTec mechanization.
- **Cross-fork extension.** Retargeting Capella to Deneb is about 28 lines (RQ3). Both forks are included. Extending to a new fork or a new version requires minimal effort.
- **Pinned and licensed.** Toolchain and client versions are pinned in `Dockerfile` and `NOTICE`. First-party code is Apache-2.0, and each bundled client keeps its own license.
