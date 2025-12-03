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
  cd eth-spectec
  ```
  Or if you already cloned without `--recursive`:
  ```bash
  git submodule update --init --recursive
  ```

* Configure sparse-checkout for consensus-specs submodule (to download only necessary files):
  ```bash
  cd consensus-specs
  git sparse-checkout init --cone
  git sparse-checkout set tests/core/pyspec specs/ configs/ presets/ pysetup/ sync/ .
  cd ..
  ```
 The directories `configs/`, `presets/`, `pysetup/`, and `sync/` are required for building.

* Install `uv` (if you already got this, you can skip it):
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
  Or on macOS with Homebrew:
  ```bash
  brew install uv
  ```

* Build the Python specification files (required for mainnet.py, minimal.py):
  ```bash
  cd consensus-specs
  make _pyspec
  cd ..
  ```
  This generates the `mainnet.py` and `minimal.py` files needed by the Converter scripts.
  
  **Note:** `make _pyspec` runs inside the `consensus-specs/.venv` virtual environment (created by `uv sync`). The generated files are used by Converter scripts which run in your system Python environment. The virtual environment is only needed for building, not for running the Converter scripts.

* Install Python dependencies:
  ```bash
  pip install -r requirements.txt
  ```
  This installs `remerkleable` which is required for SSZ serialization/deserialization.


### Building the Project

```bash
make exe
```

This creates an executable `spectec-core` in the project root.

## Testing Scripts

### 1. init_beaconnode.sh

**Environment:**
- Tested on: Ubuntu 22.04 LTS (WSL2, x86_64)
- Minimum requirement: Debian/Ubuntu-based Linux with `apt` package manager
- Recommended: Ubuntu 22.04 LTS or later (OpenJDK 21 is required, which may require additional setup on Ubuntu 20.04)

Sets up and builds all Ethereum 2.0 client implementations (Lighthouse, Prysm, Nimbus, Teku, Lodestar) for differential testing. This script automatically applies necessary code modifications and rebuilds the clients.

**Usage:**
```bash
cd spectec-core
bash init_beaconnode.sh
```
### Testing
```bash
make test
```

- Checks parsing, elaboration and structuring using the `examples/p4-concrete` spec corpus.
- Checks IL/SL interpreter coupled with the P4 parser using `tests/interp/p4-tests` files.

**Note:** This script must be run from the `spectec-core` directory.

**What it does:**
1. Installs dependencies (Rust, Java, Bazel, Node.js, etc.)
2. Clones and builds client implementations:
   - Lighthouse (v8.0.0)
   - Prysm (v7.0.0)
   - Nimbus (v25.11.0)
   - Teku (25.11.0)
   - Lodestar (v1.36.0)
3. Applies code modifications for differential testing compatibility:
   - **Lighthouse**: 
     - Comments out cache-related assertions (all_caches_built, indexed attestation cache)
     - Adds state root verification (compares computed post-state root with block's state root)
   - **Prysm**: 
     - Adds pure Capella config as default network configuration
     - Adds post-state saving functionality
     - Adds state root verification (compares computed post-state root with block's state root)
   - **Nimbus**: 
     - Overrides fork epochs for pure Capella network (CAPELLA_FORK_EPOCH = 0)
   - **Lodestar**: 
     - Comments out `postState.commit()` calls
4. Rebuilds clients after modifications

**Note:** After running this script, all clients are ready for differential testing. You only need test cases (pre.ssz and blocks_*.ssz files) to run `diff_testing.py`.

**Code Modifications:** See [CLIENT_CODE_MODIFICATIONS.md](CLIENT_CODE_MODIFICATIONS.md) for detailed information about the code changes applied to each client.

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

**Usage:**
```bash
# Test suite mode (independent mode, default)
python diff_testing.py --test-suite Converter/OfficialTestSuite/random

# Test suite mode (sequential mode, chained execution)
python diff_testing.py --test-suite Converter/OfficialTestSuite/random --workflow sequential

# Test suite mode with custom output directory
python diff_testing.py --test-suite Converter/OfficialTestSuite/random --output-base custom_client_results

# Single directory mode (requires already-decompressed .ssz files)
python diff_testing.py <beaconstate_dir> <block_dir> <output_dir>

# Single directory mode with sequential workflow
python diff_testing.py <beaconstate_dir> <block_dir> <output_dir> --workflow sequential
```

**Options:**
- `--test-suite <dir>`: Test suite directory (automatically finds all subdirectories containing `pre.ssz` or `pre.ssz_snappy` files)
- `--output-base <dir>`: (Optional) Base output directory (default: `test_suite_dir/client_results`)
- `--workflow <mode>`: Test workflow mode (`independent` or `sequential`, default: `independent`)

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

**Note:** 
- SSZ file comparison across clients is always performed automatically
- The `Differences_*.csv` file is the primary result showing where clients disagree on state transition results
- **Teku behavior**: Teku creates empty SSZ files on failure. The script automatically removes these empty files to ensure accurate comparison results.

**Prerequisites:**
- Run `init_beaconnode.sh` first to build all clients
- Test cases with `pre.ssz`/`pre.ssz_snappy` and `blocks_*.ssz`/`blocks_*.ssz_snappy` files

**Note:** This script requires the modified clients built by `init_beaconnode.sh`. The modifications ensure compatibility across different client implementations for differential testing.

### License

ETH-SpecTec is released under the [Apache 2.0 license](LICENSE).
