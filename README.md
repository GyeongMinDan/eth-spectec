# ETH-SpecTec

ETH-SpecTec is a SpecTec implementation of the official Ethereum 2.0 Consensus Spec. It extends [SpecTec-Core](https://github.com/kaist-plrg/spectec-core) with support for large byte values, and includes python scripts for conversion as well as a diff-testing framework for Ethereum 2.0 clients.

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

* Clone the repository with submodules:
  ```bash
  git clone --recursive https://github.com/GyeongMinDan/eth-spectec.git
  cd eth-spectec/spectec-core
  ```
  Or if you already cloned without `--recursive`:
  ```bash
  git submodule update --init --recursive
  cd spectec-core
  ```

**For Differential Testing:** We recommend using Docker for a reproducible environment. See the [Docker Setup](#1-docker-setup) section below for instructions. All client builds, dependencies, and coverage tools are automatically handled by the Dockerfile.


### Building the Project

```bash
make exe
```

This creates an executable `spectec-core` in the project root.

**Usage:**
```bash
cd spectec-core
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

**Note:** This script must be run from the `spectec-core` directory.


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

```bash
# Basic usage with coverage (results saved to local ./results directory)
docker run --rm -it \
  -v "$(pwd)/results:/workspace/spectec-core/results" \
  eth2test:coverage \
  bash -lc 'cd /workspace/spectec-core && python3 diff_testing.py \
    --test-suite Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests \
    --test-type state-transition \
    --workflow sequential \
    --fork-version capella \
    --output-base ./results/coverage_sanity_block_test \
    --enable-coverage \
    --cleanup-after-report'

# Test suite mode (independent mode, default)
docker run --rm -it \
  -v "$(pwd)/results:/workspace/spectec-core/results" \
  eth2test:coverage \
  bash -lc 'cd /workspace/spectec-core && python3 diff_testing.py \
    --test-suite Converter/OfficialTestSuite/capella/sanity/slots/pyspec_tests \
    --test-type sanity-slots \
    --fork-version capella \
    --output-base ./results/coverage_sanity_slot_test \
    --enable-coverage'

# Generate final accumulated coverage report (after running multiple test suites)
docker run --rm -it \
  -v "$(pwd)/results:/workspace/spectec-core/results" \
  eth2test:coverage \
  bash -lc 'cd /workspace/spectec-core && python3 diff_testing.py \
    --generate-final-coverage \
    ./results/coverage_suite1 \
    ./results/coverage_suite2 \
    --final-output-dir ./results/final_coverage_report'

# TODO! : It can be changed.
# To test spectec-generated test cases
docker run --rm -it \
  -v "$(pwd)/results:/workspace/spectec-core/results" \
  -v "$(pwd)/spectec_generated_tests:/workspace/spectec-core/spectec_generated_tests" \
  eth2test:coverage \
  bash -lc 'cd /workspace/spectec-core && python3 diff_testing.py \
    --test-suite spectec_generated_tests \
    --test-type state-transition \
    --workflow independent \
    --fork-version capella \
    --output-base ./results/spectec_generated_coverage \
    --enable-coverage \
    --cleanup-after-report'
```

**Options:**
- `--test-suite <dir>`: Test suite directory (automatically finds all subdirectories containing `pre.ssz` or `pre.ssz_snappy` files)
- `--test-type <type>`: Test type (`state-transition`, `sanity-slots`, `epoch-processing`, `operation`)
- `--fork-version <version>`: Fork version (`capella` or `deneb`)
- `--output-base <dir>`: (Optional) Base output directory (default: `test_suite_dir/client_results`)
- `--workflow <mode>`: Test workflow mode (`independent` or `sequential`, default: `independent`)
- `--enable-coverage`: Enable coverage measurement for all clients
- `--cleanup-after-report`: Delete original coverage data files after generating reports
- `--generate-final-coverage`: Generate accumulated coverage report from multiple test suite results
- `--final-output-dir <dir>`: Output directory for final accumulated coverage report

**Note:** When using `--test-suite` with `OfficialTestSuite` directories containing `.ssz_snappy` files, the script automatically:
1. Finds all test case directories containing `pre.ssz_snappy`
2. Decompresses `pre.ssz_snappy` and `blocks_*.ssz_snappy` files to `.ssz`
3. Runs differential testing on all clients
4. Compares results and generates reports

**Output:**
- Client output directories: `<output_dir>/<client_name>/output/poststate_*.ssz`
- Markdown report: `<output_dir>/report_eth2diff_*.md`
- CSV files:
  - `Output_Time_*.csv`: Execution time for each client
  - `Output_Status_*.csv`: Status code for each client
  - `Differences_*.csv`: SSZ file differences between clients (core result showing where clients disagree)
- Coverage reports (when `--enable-coverage` is used):
  - Per-test-case coverage: `<output_dir>/<test_case>/<client>/report/` # This feature is disabled in code.
  - Accumulated coverage: `<output_dir>/total-node-coverage/<client>/report/`
  - Final accumulated coverage: `<final_output_dir>/<client>/report/` (when using `--generate-final-coverage`)

**Note:** 
- SSZ file comparison across clients is always performed automatically
- The `Differences_*.csv` file is the primary result showing where clients disagree on state transition results
- **Teku behavior**: Teku creates empty SSZ files on failure. The script automatically removes these empty files to ensure accurate comparison results
- When using Docker, all output files are saved to the local `./results/` directory via volume mount
- Coverage data files are automatically cleaned up when `--cleanup-after-report` is used

**Prerequisites:**
- Build Docker image: `docker build -t eth2test:coverage --target coverage .`
- Test cases with `pre.ssz`/`pre.ssz_snappy` and `blocks_*.ssz`/`blocks_*.ssz_snappy` files

**Note:** This script requires the modified clients built by the Dockerfile. The modifications ensure compatibility across different client implementations for differential testing. The Docker environment provides a reproducible setup with all necessary dependencies and coverage tools pre-installed.

### License

ETH-SpecTec is released under the [Apache 2.0 license](LICENSE).
