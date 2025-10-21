# Converter Tools Collection

This directory contains tools for converting between SSZ (Simple Serialization) format and JSON format for Ethereum Beacon Chain.

## Directory Structure

```
Converter/
├── CompareResult.py              # SSZ file comparison tool
├── snappyDecompressor.py         # Snappy decompression tool
├── JsonToSSZ/                    # JSON → SSZ conversion tools
│   ├── BeaconStateJsonToSSZ.py
│   └── SignedBeaconBlockJsonToSSZ.py
├── SSZToJson/                    # SSZ → JSON conversion tools
│   ├── BeaconStateSSZToJson.py
│   └── SignedBeaconBlockSSZToJson.py
├── ExampleSSZ/                   # Example SSZ files
└── OfficialTestSuite/            # Official test suite
    ├── random/                   # Random test cases
    └── sanity/blocks/            # Sanity block test cases
```

## Tool Usage

### 1. SSZ File Comparison (CompareResult.py)

Compares whether two SSZ files are identical.

```bash
python CompareResult.py [--type-module <module_path>] [--type <type_name>] <file1> <file2>

# Example
python CompareResult.py --type-module eth2spec.capella.mainnet --type BeaconState state1.ssz state2.ssz
```

**Parameters:**
- `--type-module`: Python module path (default: `eth2spec.capella.mainnet`)
- `--type`: Type name (default: `BeaconState`)
- `file1`, `file2`: SSZ file paths to compare

### 2. Snappy Decompression (snappyDecompressor.py)

Decompresses files compressed with Snappy.

```bash
python snappyDecompressor.py <input_file> <output_file>

# Example
python snappyDecompressor.py compressed.ssz_snappy decompressed.ssz
```

### 3. JSON → SSZ Conversion

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

### 4. SSZ → JSON Conversion

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

## Official Test Suite (OfficialTestSuite)

### Test Case Selection Criteria

The `OfficialTestSuite` directory contains test cases extracted from [Ethereum Consensus Spec Tests v1.5.0](https://github.com/ethereum/consensus-spec-tests).

**Selected Test Categories:**
- `random/`: Random test cases
- `sanity/blocks/`: Sanity block test cases

### meta.yaml Rules Understanding

Each test case defines the following rules through the `meta.yaml` file:

#### Why We Exclude Version-Transitioning Test Cases

**Version Selection Issues:**
```yaml
post_fork: <fork>          # Post-fork rules (e.g., capella, deneb)
fork_epoch: <int>          # Epoch when fork activates
fork_block: <int>          # (Optional) Last pre-fork block index
```

**Block Processing Rules:**
- When `fork_block` is present:
  - `blocks_0` ~ `blocks_<fork_block>` → pre-fork SignedBeaconBlock
  - `blocks_<fork_block+1>` ~ → post-fork SignedBeaconBlock
- When `fork_block` is absent: All blocks are post-fork SignedBeaconBlock

**Why These Are Excluded:**
Test cases with version transitions (fork changes) are **not used** in this test suite because:

1. **SSZ Schema Incompatibility**: BeaconState and SignedBeaconBlock structures change between different fork versions (e.g., Bellatrix → Capella → Deneb)
2. **Decoding Failures**: When fork transitions occur, the SSZ format becomes incompatible, causing decoding failures
3. **Version-Specific Requirements**: Each fork version has different field structures, making it impossible to decode with a single schema

#### 1. Block Count
```yaml
blocks_count: <int>        # Number of block files to process
```

#### 2. BLS Signature Verification Settings
```yaml
bls_setting: <int>
# 0: BLS ON/OFF regardless (default)
# 1: BLS signature verification required
# 2: BLS signature verification ignored
```

### Capella Version Compatibility

The selected test cases are specifically chosen to obtain BeaconState and SignedBeaconBlock SSZ files compatible with the **Capella fork**. This ensures:

1. **Consistent Fork Version**: All tests follow Capella rules
2. **Compatible Data Structures**: SSZ format that matches Capella specification
3. **Validated Test Cases**: Test cases verified by the official Ethereum test suite

## Usage Examples

### Complete Workflow
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

## Dependencies

These tools require the following Python packages:
- `remerkleable`: SSZ serialization/deserialization
- `eth2spec`: Ethereum 2.0 specification implementation
- `snappy`: Snappy compression/decompression

## Important Notes

1. **Type Compatibility**: Use correct `--type-module` and `--type` parameters
2. **File Format**: SSZ files are binary format, so they must be opened in `rb` mode
3. **Memory Usage**: Large BeaconState files require sufficient memory