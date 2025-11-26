# SpecTec-Core

A spec programming framework.
SpecTec was originally developed for WebAssembly (Wasm-SpecTec), then adapted/generalized for P4 (P4-SpecTec). SpecTec Core is a stripped down version of P4-SpecTec's algorithmic flavor, meant to serve as a base for adaptation to other languages or domains.

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

### Structure

SpecTec-Core currently consists of three main components.
* SpecTec EL is the surface language in which the spec is authored.
* SpecTec IL (internal language). EL -> IL conversion is called "elaboration". Elaboration makes the spec more algorithmic and unambiguous.
* An interpreter backend for IL.
  * Needs to be coupled with a parser that converts an input file into a SpecTec IL value to properly produce output.

### Commands
```bash
# elaborate a SpecTec spec
./spectec-core elab spec/*.spectec
```

## Testing Scripts

### 1. init_beaconnode.sh

Sets up and builds all Ethereum 2.0 client implementations (Lighthouse, Prysm, Nimbus, Teku, Lodestar) for differential testing. This script automatically applies necessary code modifications and rebuilds the clients.

**Usage:**
```bash
cd spectec-core
bash init_beaconnode.sh
```

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
   - Lighthouse: Comments out cache-related assertions
   - Prysm: Adds pure Capella config and post-state saving
   - Nimbus: Overrides fork epochs for pure Capella network
   - Lodestar: Comments out `postState.commit()` calls
4. Rebuilds clients after modifications

**Note:** After running this script, all clients are ready for differential testing. You only need test cases (pre.ssz and blocks_*.ssz files) to run `diff_testing.py`.

**Code Modifications:** See [CLIENT_CODE_MODIFICATIONS.md](CLIENT_CODE_MODIFICATIONS.md) for detailed information about the code changes applied to each client.

### 2. diff_testing.py

Performs differential testing across multiple Ethereum 2.0 clients by running state transitions and comparing results.

**Usage:**
```bash
# Single directory mode
python diff_testing.py <beaconstate_dir> <block_dir> <output_dir>

# Test suite mode (automatically processes all test cases)
python diff_testing.py --test-suite <test_suite_dir> --output-base <output_dir>

# Examples
python diff_testing.py --test-suite Converter/OfficialTestSuite/sanity/blocks/pyspec_tests/_results
python diff_testing.py --test-suite Converter/OfficialTestSuite/random/pyspec_tests/_results
```

**Options:**
- `--test-suite <dir>`: Test suite directory (automatically finds all subdirectories containing pre.ssz files)
- `--output-base <dir>`: (Optional) Base output directory (default: test_suite_dir/client_results)

**Output:**
- Post-state SSZ files for each client
- **Differences CSV** (`Differences_*.csv`): **Core result** - Shows which client pairs produce different SSZ outputs (binary comparison)
- **Status CSV** (`Output_Status_*.csv`): Success/failure status for each client per test case
- **Time CSV** (`Output_Time_*.csv`): Execution time for each client per test case
- **Markdown reports** (`report_eth2diff_*.md`): Detailed logs with commands, stdout, and stderr for each client

**Note:** 
- SSZ file comparison across clients is always performed automatically
- The `Differences_*.csv` file is the primary result showing where clients disagree on state transition results
- **Teku behavior**: Teku creates empty SSZ files on failure. The script automatically removes these empty files to ensure accurate comparison results.

**Prerequisites:**
- Run `init_beaconnode.sh` first to build all clients
- Test cases with `pre.ssz` and `blocks_*.ssz` files

**Note:** This script requires the modified clients built by `init_beaconnode.sh`. The modifications ensure compatibility across different client implementations for differential testing.

### Contributing

SpecTec-Core is an open-source project. Please feel free to contribute by opening issues or pull requests.

### License

SpecTec-Core is released under the [Apache 2.0 license](LICENSE).
