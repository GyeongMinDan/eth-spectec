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

### 1. SSZ-byte Equivalence Checker (CompareResult.py)

Exact-byte comparison of SSZ files.

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

## Official Test Suite (OfficialTestSuite)

### Test Case Selection Criteria

The `OfficialTestSuite` directory contains test cases extracted from **Ethereum Consensus Spec Tests pinned at `v1.5.0`**.  
(We pin a specific tag to ensure reproducibility across machines and CI.)

**Why only `random/` and `sanity/blocks/`?**  
We focused on suites that:
- provide abundant **single-fork** block/state examples,
- have **stable, self-contained vectors** with clear `meta.yaml` rules,
- and are lightweight enough to keep this repo practical.

Other suites (e.g., full transition / fork-heavy scenarios) remain valid in the upstream repo, but are **out of scope** for this converter collection to keep the tooling simple and reproducible.

### meta.yaml Rules Understanding

Each test case defines the following rules through the `meta.yaml` file:

#### Version Selection Quick Rules (from `meta.yaml`)

- `post_fork: <fork>` → `post.ssz_snappy` **must** be decoded as `<post_fork>.BeaconState`.
- `fork_epoch: <int>` → upgrade at `fork_slot = fork_epoch * SLOTS_PER_EPOCH`.
- `fork_block: <int>` (optional):
  - present: `blocks_0..blocks_<fork_block>` = **pre-fork** `SignedBeaconBlock`, the rest = **post-fork**.
  - absent: **all** `blocks_i` are **post-fork** `SignedBeaconBlock`.
- **`pre.ssz_snappy`** is always the **immediate predecessor** fork of `post_fork`.  
  (e.g., `post_fork=capella` ⇒ `pre` is **Bellatrix** `BeaconState`.)

#### Why We Exclude Version-Transitioning Test Cases

To simplify the converter and avoid implementing on-the-fly **fork upgrade logic** (e.g., `upgrade_to_capella`) in this collection, we intentionally select **single-fork scenarios** only.

Concretely:
- We avoid cases that require switching `state_transition` rules mid-run.
- We skip cases that rely on `fork_block` to mix pre-fork and post-fork `SignedBeaconBlock` types.

> Note: The upstream spec/tests **do** support fork transitions correctly when you use the right types and upgrade functions. We're simply narrowing scope here for a clean JSON↔SSZ workflow.

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

Our runners map `bls_setting` to signature-verification flags (ON/OFF/ignored) and ignore `reveal_deadlines_setting` unless a legacy custody-game vector explicitly requires it.

### Selection Filters (non-transition, single-fork only)

We include a case **only if**:
- Folder path already fixes the fork version (e.g., `.../capella/...`).
- `meta.yaml` is **absent** or contains **only** general keys:
  - required: `blocks_count ≥ 1`
  - optional: `bls_setting` (0/1/2), `description`, `reveal_deadlines_setting`
- `meta.yaml` does **not** contain transition keys: `post_fork`, `fork_epoch`, `fork_block`.
- The required files exist:
  - `pre.ssz_snappy` (or `pre.ssz`)
  - `blocks_0.ssz_snappy ... blocks_{blocks_count-1}.ssz_snappy`
  - (optional) `post.ssz_snappy`

### Version Determination (Directory-Based)

**How is the fork version determined?**

The fork version is fixed by the **directory path** (e.g., `.../capella/...`), not by `meta.yaml` keys.

- All `blocks_i` are decoded as that fork's `SignedBeaconBlock`
- `pre.ssz`/`post.ssz` are decoded as **that fork's** `BeaconState`
- No version transitions within a single test case

**Example:** For a test case in `.../capella/...`:
- `pre.ssz` → Capella `BeaconState`
- `blocks_0.ssz` → Capella `SignedBeaconBlock`
- `post.ssz` → Capella `BeaconState`

This ensures **single-fork consistency** throughout each test case, avoiding the complexity of fork upgrade logic.

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