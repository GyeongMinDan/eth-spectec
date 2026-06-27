# REQUIREMENTS

## Architecture

**x86-64 (amd64) only.** The image fetches amd64-specific toolchains (Go, Nim, Bazel, OpenJDK) and clients built for x86-64.

> **Apple Silicon / ARM:** runs only under emulation (`docker run --platform linux/amd64 ...`), which is slow and may break some client builds. An x86-64 host is strongly recommended.

## Host software

- **Docker** 20.10+ (or Podman) able to load and run amd64 Linux images.
- Nothing else. Every toolchain lives inside the container.

## Hardware

| Resource | Minimum | Recommended |
| --- | --- | --- |
| CPU | 8 cores | 16 cores |
| RAM | 16 GB | 32 GB+ |
| Disk | 80 GB free | 120 GB free |

Paper experiments ran on an AMD Ryzen 9 9950X (16 cores) / 128 GB RAM.

## Network

The **pre-built image runs offline**. Network is needed only to *build* the image from the `Dockerfile`.

## Pinned versions

| Component | Version | Component | Version |
| --- | --- | --- | --- |
| Ubuntu | 22.04 | Lighthouse | v8.0.1 |
| OCaml / opam | 5.1.0 | Prysm | v7.0.0 |
| Rust nightly | 2026-01-15 | Teku | 25.11.1 |
| Go | 1.24.2 | Nimbus-eth2 | v25.11.1 |
| Java (OpenJDK) | 21 | Lodestar | 1.36.0 |
| Nim | 1.6.20 | consensus-specs / eth2spec | v1.6.0 (f96d3e7) |
| Node.js | 20 | Bazel | 7.4.1 |

## Expected runtimes (paper hardware, longer on smaller machines)

| Step | Scope | Time |
| --- | --- | --- |
| Smoke test (validate + diff on 5 single-block cases) | 5 cases | ~2 min |
| Consensus-SpecTec validation (`eth coverage`, full state-transition suites) | 581 state-transition tests | hours (finality expands to many block-steps) |
| Baseline premise coverage (from scratch) | full Capella | hours (precomputed in `testgen_data/`) |
| Test generation | 65 premises | min to hours |
| RQ1 differential testing | per suite | min to hours |
| RQ2 / RQ3 coverage runs | full suites | hours (precomputed in `testgen_data/`) |

Precomputed checkpoints (`testgen_data/capella/`, `testgen_data/deneb/`) keep evaluation within a day without re-running the multi-hour stages.
