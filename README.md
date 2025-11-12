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
  opam install dune bignum menhir core core_unix bisect_ppx
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

### Contributing

SpecTec-Core is an open-source project. Please feel free to contribute by opening issues or pull requests.

### License

SpecTec-Core is released under the [Apache 2.0 license](LICENSE).
