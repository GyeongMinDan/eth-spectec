# Converter Tools Collection

This directory contains tools for converting between SSZ (Simple Serialization) format and JSON format for Ethereum Beacon Chain.

## Directory Structure

```
Converter/
├── CompareResult.py              # SSZ file comparison tool
├── snappyDecompressor.py         # Snappy decompression tool
├── eth2specResult.py             # eth2spec state transition execution tool
├── generate_json_test_cases.py   # Official SSZ vector → SpecTec JSON generator
├── JsonToSSZ/                    # JSON → SSZ conversion tools
│   ├── BeaconStateJsonToSSZ.py
│   └── SignedBeaconBlockJsonToSSZ.py
├── SSZToJson/                    # SSZ → JSON conversion tools
│   ├── BeaconStateSSZToJson.py
│   └── SignedBeaconBlockSSZToJson.py
├── ExampleSSZ/                   # Example SSZ files
├── pure_capella_configs/         # Pure Capella network configurations
│   └── lighthouse_testnet/       # Lighthouse testnet config for pure Capella
│       ├── config.yaml          # Network config with fork epochs set to 0
│       └── deposit_contract_block.txt
└── OfficialTestSuite/            # Official test suite
    ├── capella/                  # Capella fork test cases
    │   ├── random/               # Random test cases
    │   ├── sanity/               # Block and slot test cases
    │   ├── finality/             # Finality test cases
    │   ├── operations/           # Operation test cases
    │   └── epoch_processing/     # Epoch-processing test cases
    └── deneb/                    # Deneb fork test cases
        ├── random/               # Random test cases
        ├── sanity/               # Block and slot test cases
        ├── finality/             # Finality test cases
        ├── operations/           # Operation test cases
        └── epoch_processing/     # Epoch-processing test cases
```

## Pure Capella Network Configuration

The `pure_capella_configs/` directory contains network configuration files for differential testing. These configurations ensure all clients use the same fork schedule for consistent comparison.

### Lighthouse Testnet Config (`pure_capella_configs/lighthouse_testnet/`)

This directory contains a custom Lighthouse testnet configuration that sets all fork epochs to 0 for a "pure Capella" network:

- **`config.yaml`**: Mainnet-based configuration with:
  - `ALTAIR_FORK_EPOCH: 0`
  - `BELLATRIX_FORK_EPOCH: 0`
  - `CAPELLA_FORK_EPOCH: 0`
  - `DENEB_FORK_EPOCH: 75520` (maintains epoch difference from Capella)

**Purpose**: This configuration is used by `diff_testing.py` when running Lighthouse client for differential testing. It ensures Lighthouse uses the same pure Capella fork schedule as other clients (Prysm, Nimbus, Teku, Lodestar), which are configured through code modifications or CLI arguments.

**Usage**: The `diff_testing.py` script automatically uses this configuration via the `--testnet-dir` flag when executing Lighthouse's `lcli transition-blocks` command.

**Note**: Other clients (Prysm, Nimbus, Teku, Lodestar) use different methods to achieve the same pure Capella configuration:
- **Prysm**: Code modification in `main.go`
- **Nimbus**: Code modification in `ncli.nim`
- **Teku**: CLI arguments (`--Xnetwork-*-fork-epoch=0`)
- **Lodestar**: Code modification in `transition.js`

See `CLIENT_CODE_MODIFICATIONS.md` for details on how each client is configured.

## Tool Usage

### 1. SSZ-byte Equivalence Checker (CompareResult.py)

Exact-byte comparison of SSZ files. Performs a simple byte-by-byte comparison without deserialization.

```bash
python CompareResult.py <file1> <file2>

# Example
python CompareResult.py state1.ssz state2.ssz
```

**Parameters:**
- `file1`, `file2`: SSZ file paths to compare

**Note:** This tool performs a direct byte-by-byte comparison of the SSZ files. No fork information or type information is required since it only compares the raw bytes.

### 2. Snappy Decompression (snappyDecompressor.py)

Decompresses .ssz_snappy files (supports both Snappy framed and raw; if already uncompressed, bytes are passed through).

```bash
python snappyDecompressor.py <input_file> <output_file>

# Example
python snappyDecompressor.py compressed.ssz_snappy decompressed.ssz
```

### 3. SSZ → JSON Conversion

#### BeaconState SSZ → JSON
```bash
python SSZToJson/BeaconStateSSZToJson.py --in <input_ssz> --out <output_json> [--type-module <module>] [--type <type_name>]

# Example
python SSZToJson/BeaconStateSSZToJson.py --in beaconstate.ssz --out beaconstate.json
```

#### SignedBeaconBlock SSZ → JSON
```bash
python SSZToJson/SignedBeaconBlockSSZToJson.py --in <input_ssz> --out <output_json> [--type-module <module>] [--type <type_name>]

# Example
python SSZToJson/SignedBeaconBlockSSZToJson.py --in block.ssz --out block.json
```

### 4. JSON → SSZ Conversion

#### BeaconState JSON → SSZ
```bash
python JsonToSSZ/BeaconStateJsonToSSZ.py --in <input_json> --out <output_ssz> [--type-module <module>] [--type <type_name>]

# Example
python JsonToSSZ/BeaconStateJsonToSSZ.py --in beaconstate.json --out beaconstate.ssz
```

#### SignedBeaconBlock JSON → SSZ
```bash
python JsonToSSZ/SignedBeaconBlockJsonToSSZ.py --in <input_json> --out <output_ssz> [--type-module <module>] [--type <type_name>]

# Example
python JsonToSSZ/SignedBeaconBlockJsonToSSZ.py --in block.json --out block.ssz
```

### 5. eth2spec State Transition (eth2specResult.py)

Executes state transition using eth2spec and saves the result as an SSZ file.

```bash
python eth2specResult.py --pre <pre_ssz> --block <block_ssz> --out <output_ssz> [--fork <fork>]

# Example (using Capella, default)
python eth2specResult.py --pre pre.ssz --block blocks_0.ssz --out eth2specResult.ssz

# Example (using Deneb)
python eth2specResult.py --pre pre.ssz --block blocks_0.ssz --out eth2specResult.ssz --fork deneb
```

**Parameters:**
- `--pre`: Path to pre-state SSZ file (BeaconState)
- `--block`: Path to block SSZ file (SignedBeaconBlock)
- `--out`: Path to output SSZ file (default: eth2specResult.ssz)
- `--fork`: Fork name to use (`capella` or `deneb`, default: `capella`)

**Note:** This script uses eth2spec from the `consensus-specs/tests/core/pyspec` path.

### 6. Official Test Input Generator (`generate_json_test_cases.py`)

Run the generator from the repository root to convert the official SSZ vectors
into the JSON test inputs consumed by `spectec-core`.

```bash
# Capella
python3 Converter/generate_json_test_cases.py \
  Converter/OfficialTestSuite/capella \
  --fork capella \
  --output-dir generated-tests/capella \
  --verbose

# Deneb
python3 Converter/generate_json_test_cases.py \
  Converter/OfficialTestSuite/deneb \
  --fork deneb \
  --output-dir generated-tests/deneb \
  --verbose
```

Arguments and options:

- `test_suite`: source directory searched recursively for official test cases
- `--fork {capella,deneb}`: fork used to process the source vectors
- `--output-dir`: directory where the generated JSON cases are written
- `--filter <name>`: generate only cases whose source directory matches the
  given name
- `-v`, `--verbose`: print per-case progress

Generated cases are grouped below the output directory by test type, including
`random`, `finality`, `sanity`, `operations`, and
`epoch_processing`. Use a different output directory for each fork.

For local execution outside the Docker image, initialize the pinned
`consensus-specs` submodule and generate the PySpec modules first:

```bash
git submodule update --init --recursive consensus-specs
(cd consensus-specs && make _pyspec)
```

## Usage Examples

### Basic Conversion Workflow
```bash
# 1. Extract SSZ files from official tests
# 2. Decompress Snappy files
python snappyDecompressor.py pre.ssz_snappy pre.ssz
python snappyDecompressor.py post.ssz_snappy post.ssz

# 3. SSZ → JSON conversion
python SSZToJson/BeaconStateSSZToJson.py --in pre.ssz --out pre.json
python SSZToJson/BeaconStateSSZToJson.py --in post.ssz --out post.json

# 4. JSON → SSZ conversion (verification)
python JsonToSSZ/BeaconStateJsonToSSZ.py --in pre.json --out pre_converted.ssz

# 5. Compare results
python CompareResult.py pre.ssz pre_converted.ssz
```

### eth2spec State Transition
```bash
# Execute state transition using eth2spec (Capella, default)
python eth2specResult.py --pre pre.ssz --block blocks_0.ssz --out eth2specResult.ssz

# Execute state transition using eth2spec (Deneb)
python eth2specResult.py --pre pre.ssz --block blocks_0.ssz --out eth2specResult.ssz --fork deneb
```

## Dependencies

These tools require the following Python packages:
- `remerkleable`: SSZ serialization/deserialization
- `eth2spec`: Ethereum 2.0 specification implementation
- `snappy`: Snappy compression/decompression
- `PyYAML`: operation metadata and slot-test configuration

## Important Notes

1. **Type Compatibility**: Use correct `--type-module` and `--type` parameters
2. **File Format**: SSZ files are binary format, so they must be opened in `rb` mode
3. **Memory Usage**: Large BeaconState files require sufficient memory
