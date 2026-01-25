# ETH-SpecTec

ETH-SpecTec is a SpecTec implementation of the official Ethereum 2.0 Consensus Spec. It extends [SpecTec-Core](https://github.com/kaist-plrg/spectec-core) with support for large byte values, and includes python scripts for conversion as well as a diff-testing framework for Ethereum 2.0 clients.

# TEMP (TODO : Have to fix)
See the [Docker Setup](#1-docker-setup) section below for instructions. All subjects are automatically handled by the Dockerfile.

### Installation

* Install `opam` version 2.0.5 or higher.
  ```bash
  apt-get install opam
  opam init
  ```

* Create OCaml switch for version 5.1.0
  Install `dune` version 3.16.1, `bignum` version v0.17.0, `menhir` version 20240715, `core` version v0.17.1, `core_unix` version v0.17.0, and `bisect_ppx` version 2.8.3 via `opam`.
  ```bash
  opam switch create 5.1.0
  eval $(opam env)
  opam install dune bignum menhir core core_unix bisect_ppx yojson digestif bls12-381 bls12-381-signature
  ```


### Building the Project

```bash
make exe
```

This creates an executable `spectec-core` in the project root.

**Usage:**
```bash
# print out the IL representation of a SpecTec spec
./spectec-core elab spec/*.spectec
# print the SL representation of a SpecTec spec
./spectec-core struct spec/*.spectec

## P4-specific commands

# parse a P4 program to an IL value (-r to do a roundtrip test)
./spectec-core p4parse spec/*.spectec -i tests/interp/p4-tests/includes -p target/file.p4 [-r]

# run a P4 program based on SpecTec IL/SL
./spectec-core p4 typecheck -i tests/interp/p4-tests/includes -p target/file.p4
./spectec-core p4 typecheck -i tests/interp/p4-tests/includes -p target/file.p4 --sl
```

### Testing
```bash
make test
```

- Checks parsing, elaboration and structuring using the `examples/p4-concrete` spec corpus.
- Checks IL/SL interpreter coupled with the P4 parser using `tests/interp/p4-tests` files.

**Note:** This script must be run from the project root directory (where `Makefile` is located).


## Testing Scripts

### 1. Docker Setup

**Environment:**
- **Base Image:** Ubuntu 22.04 LTS
- **Requirements:** Docker installed on your system
- **Platform:** Linux (x86_64), macOS, or Windows with WSL2

The Dockerfile provides a reproducible, isolated environment for building and testing all Ethereum 2.0 client implementations (Lighthouse, Prysm, Nimbus, Teku, Lodestar) with coverage instrumentation support.

**What it does:**
1. Installs all required dependencies:
   - Rust (stable + nightly with llvm-tools-preview)
   - Go 1.24.2 (for Prysm)
   - Java 21 (OpenJDK for Teku)
   - Bazel 7.4.1 (for Prysm)
   - Node.js 20 (for Lodestar)
   - Nim 1.6.20 (for Nimbus)
   - Python 3 with dependencies (including snappy for decompression)
   - Coverage tools: lcov, go-bcov, llvm-profdata, JaCoCo, c8
2. Clones and builds client implementations:
   - Lighthouse (v8.0.0)
   - Prysm (v7.0.0)
   - Nimbus (v25.11.0)
   - Teku (25.11.0)
   - Lodestar (v1.36.0)
3. Applies code modifications for differential testing compatibility (see `modified_code/` directory for client-specific changes)
4. Builds both base binaries and coverage-instrumented binaries

**Build Docker Images:**

```bash
# Build base environment (clones and builds original clients)
docker build -t eth2test:base --target base .

# Build with coverage binaries (recommended for coverage testing)
docker build -t eth2test:coverage --target coverage .
```

**Note:** The build process takes a significant amount of time (approximately 6000s on MacBook Pro 19) as it builds all clients from source. Docker layer caching will speed up subsequent builds if only code changes are made.

**Note:** After building the Docker image, all clients are ready for differential testing. You only need test cases (pre.ssz and blocks_*.ssz files) to run `diff_testing.py`.

### 2. diff_testing.py

Performs differential testing across multiple Ethereum 2.0 clients (Lighthouse, Prysm, Nimbus, Teku, Lodestar) by running state transitions and comparing results.

**Features:**
- Automatically decompresses `.ssz_snappy` files to `.ssz` (no manual conversion needed)
- Supports both `OfficialTestSuite` directories (with `.ssz_snappy` files) and already-decompressed directories (with `.ssz` files)
- Compares postState SSZ files across all successful clients
- Generates detailed reports (Markdown) and CSV files (execution time, status, differences)
- Supports two workflow modes: **independent** (default) and **sequential** (chained execution)

**Workflow Modes:**

- **independent** (default)  
  Each block is processed **independently** from the original `pre` state:
  - All blocks start from the same original `pre` state
  - Each block's postState is computed independently
  - Useful for testing individual block transitions

- **sequential**  
  Blocks are applied **sequentially**: `pre → blocks_0 → postState_0 → blocks_1 → postState_1 → ...`:
  - First block starts from original `pre` state
  - Subsequent blocks use the previous block's postState as their pre state
  - Useful for testing chained state transitions across multiple blocks

**Usage (Docker):**

All operations run entirely inside the Docker container.

**1. Run diff_testing.py (Differential Testing):**

Execute differential testing with all client implementations. All clients receive the same input and produce state-transition results and coverage data.

```bash
# Interactive shell - all operations run inside container
docker run -it --name eth2test-workspace eth2test:coverage

# Inside the container:
cd /workspace/spectec-core

# Run differential testing with coverage (state-transition, sequential workflow)
python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_sanity_block_test \
  --enable-coverage \
  --cleanup-after-report

# Run differential testing with coverage (state-transition, sequential workflow)
python3 diff_testing.py \
  --test-suite Converter/OfficialTestSuite/capella/random/random/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_random_test \
  --enable-coverage \
  --cleanup-after-report

# Generate accumulated coverage report (after running multiple test suites)
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  --final-output-dir ./results/accumulated_coverage_report
```

**2. Process results with analysis scripts:**

All results are stored in `/workspace/spectec-core/results/` inside the container. You can process them using the analysis scripts:

```bash
# Inside the container (continue from step 1):
cd /workspace/spectec-core

# Generate coverage figures
python3 make_coverage_figure.py \
  --input-dir ./results/accumulated_coverage_report \
  --output-dir ./results/coverage_figures

# Check results for mismatches
python3 check_results.py ./results/coverage_sanity_block_test
```

# TODO : Have to add spectec related command
**3. Use spectec-core executable :**
```bash
# Inside the container:
cd /workspace/spectec-core

# Print IL representation
./spectec-core elab spec/*.spectec

# Run tests
make test
```

**4. Run Converter scripts (eth2spec integration):**

```bash
# Inside the container:
cd /workspace/spectec-core

# Make the spectec inputs (Example)
python3 Converter/generate_json_test_cases.py   Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests   --fork capella  --output-dir eth-tests   -v
```


### License

SpecTrum is released under the [Apache 2.0 license](LICENSE).
