# (tool name)

(tool name) is a specification guided test generation framework.

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

### 2. Building the Project (TODO : Have to fix spectec command 2, 3, 4 for now it is temp)

**Use spectec-core executable:**

```bash
# Inside the container:
cd /workspace/spectec-core

make exe
```

This creates an executable `spectec-core` in the project root.
```bash
# Print IL representation
./spectec-core elab spec/spec_capella/*.spectec
```

### 3. Testing

```bash
make test
```

- Checks parsing, elaboration and structuring using the `examples/p4-concrete` spec corpus.
- Checks IL/SL interpreter coupled with the P4 parser using `tests/interp/p4-tests` files.

**Note:** This script must be run from the project root directory (where `Makefile` is located).

### 4. Run Converter scripts (eth2spec integration)

```bash
# Inside the container:
cd /workspace/spectec-core

# Make the spectec inputs (Example)
python3 Converter/generate_json_test_cases.py   Converter/OfficialTestSuite/capella/sanity/blocks/pyspec_tests   --fork capella  --output-dir eth-tests   -v
```

### 5. diff_testing.py

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

**measure the Consensus-SpecTec generated test cases:**

First, convert the Consensus-SpecTec-generated JSON test cases to SSZ.

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
  --output-base ./results/coverage_Consensus-SpecTec \
  --enable-coverage \
  --cleanup-after-report


# Generate accumulated coverage report (baseline + Consensus-SpecTec)
python3 diff_testing.py \
  --generate-final-coverage \
  ./results/coverage_sanity_block_test \
  ./results/coverage_random_test \
  ./results/coverage_finality_test \
  ./results/coverage_Consensus-SpecTec \
  --final-output-dir ./results/accumulated_coverage_report_with_Consensus-SpecTec
```
**2. Process results with analysis scripts:**

All results are stored in `/workspace/spectec-core/results/` inside the container. You can process them using the analysis scripts:

```bash
# Inside the container (continue from step 1):
cd /workspace/spectec-core

# Check results for mismatches
python3 check_results.py ./results/coverage_sanity_block_test
python3 check_results.py ./results/coverage_Consensus-SpecTec

# Command to generate a coverage(branch) measurement graph for the results
python3 make_coverage_figure.py \
  --input-dir ./results/accumulated_coverage_report \
  --output-dir ./results/coverage_figures \
  --format png

# Command to generate a graph comparing coverage(branch) between result sets
python3 make_compare_figure.py \
  --input-dir-1 ./results/accumulated_coverage_report \
  --input-dir-2 ./results/accumulated_coverage_report_with_Consensus-SpecTec \
  --output-dir ./results/final_compare_result \
  --format png
```
![Branch coverage comparison(Example)](./example_compare_image.png)


## Consensus-SpecTec

Consensus-SpecTec is the SpecTec formalization of the official [Ethereum Consensus Spec](https://github.com/ethereum/consensus-specs/tree/master/specs).
[consensus-spectec.md]

