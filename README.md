(tool name)
(tool name) is a specification guided test generation framework.

## Testing Scripts

### 1. Docker Setup

**Environment:**
- **Base Image:** Ubuntu 22.04 LTS
- **Requirements:** Docker installed on your system
- **Platform:** Linux (x86_64), macOS, or Windows with WSL2

The Dockerfile provides a reproducible, isolated environment for building and testing Ethereum 2.0 implementations used by `diff_testing.py` (Lighthouse, Prysm, Nimbus, Teku, Lodestar, plus the Python `eth2spec` executable spec) with coverage instrumentation support.

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
   - OCaml and build tools (for spectec-core executable)
2. Sets up the environment for building spectec-core executable:
   - Installs OCaml compiler and opam package manager
   - Configures build environment for spectec-core
3. Clones and builds client implementations:
   - Lighthouse (v8.0.1)
   - Prysm (v7.0.0)
   - Nimbus (v25.11.1)
   - Teku (25.11.1)
   - Lodestar (v1.36.0 @state-transition)
4. Applies code modifications for differential testing compatibility (see `modified_code/` directory for client-specific changes)
5. Builds both base binaries and coverage-instrumented binaries

**Build Docker Images:**

```bash
# Build base environment (clones and builds original clients)
docker build -t eth2test:base --target base .

# Build with coverage binaries (recommended for coverage testing)
docker build -t eth2test:coverage --target coverage .
```

### diff_testing.py

Performs differential testing across six Ethereum 2.0 implementations (Lighthouse, Prysm, Nimbus, Teku, Lodestar, Eth2spec) by running state transitions and comparing results.

**Features:**
- Automatically decompresses `.ssz_snappy` files to `.ssz` (no manual conversion needed)
- Supports both `OfficialTestSuite` directories (with `.ssz_snappy` files) and already-decompressed directories (with `.ssz` files)
- Compares postState SSZ files across all successful implementations
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

Execute differential testing with all six implementations. All implementations receive the same input and produce state-transition results and coverage data.

Note : All this command is example, if you want to change, then check your command.
**measure the baseline (official test suite):**
```bash
# Interactive shell - all operations run inside container
docker run -it --name eth2test-workspace eth2test:coverage

# Inside the container:
cd /workspace/spectec-core


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
  --test-suite Converter/OfficialTestSuite/capella/finality/pyspec_tests \
  --test-type state-transition \
  --workflow sequential \
  --fork-version capella \
  --output-base ./results/coverage_finality_test \
  --enable-coverage \
  --cleanup-after-report

# Generate accumulated coverage report (after running multiple test suites)
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  ./results/coverage_finality_test \
  --final-output-dir ./results/accumulated_coverage_report
```

**measure the ETH2SpecTec generated test cases:**

First, convert the ETH2SpecTec-generated JSON test cases to SSZ.

```bash
cd /workspace/spectec-core
python3 convert_testgen_json_to_ssz.py \
  --input-dir ./testgen_01280645 \
  --fork capella \
  --output-dir ./your_path
```

After conversion, run diff testing using the generated SSZ tests located at `./your_path/testgen/spectec-generated/...`.

```bash
cd /workspace/spectec-core
python3 diff_testing.py \
  --test-suite ./your_path/testgen/spectec-generated \
  --test-type state-transition \
  --fork-version capella \
  --output-base ./results/coverage_ETH2SpecTec \
  --enable-coverage \
  --cleanup-after-report


# Generate accumulated coverage report (baseline + ETH2SpecTec)
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  ./results/coverage_finality_test \
  ./results/coverage_ETH2SpecTec \
  --final-output-dir ./results/accumulated_coverage_report_with_ETH2SpecTec
```
**2. Process results with analysis scripts:**

All results are stored in `/workspace/spectec-core/results/` inside the container. For the artifact branch, keep `check_results.py` as the analysis script used to inspect `Output_Status_*.csv` files produced by `diff_testing.py`.

```bash
# Inside the container (continue from step 1):
cd /workspace/spectec-core

# Check results for mismatches / crashes in the 6-implementation comparison
python3 check_results.py ./results/coverage_sanity_block_test
python3 check_results.py ./results/coverage_ETH2SpecTec
```

`check_results.py` reads the CSV header dynamically, so it is compatible with both the current 6-column output (`Lighthouse`, `Prysm`, `Nimbus`, `Teku`, `Lodestar`, `Eth2spec`) and 5-client result folders.

To compare accumulated coverage totals between a baseline run and a variant run, use `compare_state_transition_coverage.py`

```bash
# Compare baseline accumulated coverage vs baseline + ETH2SpecTec accumulated coverage
python3 compare_state_transition_coverage.py   ./results/accumulated_coverage_report   ./results/accumulated_coverage_report_with_ETH2SpecTec
```

The text output format is:

```text
<Lighthouse>
line coverage : A / B -> C / D (delta covered +X, delta total +Y)
branch coverage : E / F -> G / H (delta covered +M, delta total +N)
```


Consensus-SpecTec is the SpecTec formalization of the official [Ethereum Consensus Spec](https://github.com/ethereum/consensus-specs/tree/master/specs).
[consensus-spectec.md]
