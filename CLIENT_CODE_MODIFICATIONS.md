# Client Code Modifications Summary

This document summarizes the internal code modifications made to each node implementation for the 5-node testing tool setup.

**Note**: If you want to check the code please refer to init_beaconnode.sh.

---

## 1. Lighthouse

**File**: `testing_clients/lighthouse/lcli/src/transition_blocks.rs`

### Modification 1: Comment out all_caches_built() assertion
- **Location**: Line 346-353
- **Original Code**:
  ```rust
  // Slot and epoch processing should keep the caches fully primed.
  assert!(pre_state.all_caches_built());
  ```
- **Modified Code**:
  ```rust
  // Slot and epoch processing should keep the caches fully primed.
  // For external spec-tests (raw SSZ from consensus-specs), this assertion may fail
  // because complete_state_advance can invalidate some caches in certain cases.
  // We skip this assertion for differential testing compatibility with other clients.
  // The caches will be rebuilt below anyway, so this doesn't affect state transition correctness.
  // assert!(pre_state.all_caches_built());
  if !pre_state.all_caches_built() {
      debug!("Caches not fully built after slot processing; rebuilding caches");
  }
  ```
- **Purpose**: Handle cases where caches are invalidated after `complete_state_advance` in raw spec-tests environments, causing assertion failures
- **Impact**: Caches are rebuilt below, so this does not affect state transition correctness

### Modification 2: Comment out indexed attestation cache assertion
- **Location**: Line 395-411
- **Original Code**:
  ```rust
  // Signature verification should prime the indexed attestation cache.
  assert_eq!(
      ctxt.num_cached_indexed_attestations(),
      block.message().body().attestations_len()
  );
  ```
- **Modified Code**:
  ```rust
  // Signature verification should prime the indexed attestation cache.
  // For external spec-tests (raw SSZ from consensus-specs), this assertion may fail
  // because duplicate or special-case attestations may not all be cached.
  // We skip this assertion for differential testing compatibility with other clients.
  // The cache state doesn't affect state transition correctness.
  // assert_eq!(
  //     ctxt.num_cached_indexed_attestations(),
  //     block.message().body().attestations_len()
  // );
  let cached_count = ctxt.num_cached_indexed_attestations();
  let block_attestations_count = block.message().body().attestations_len();
  if cached_count != block_attestations_count {
      debug!(
          "Indexed attestation cache count mismatch: cached={}, block={}",
          cached_count, block_attestations_count
      );
  }
  ```
- **Purpose**: Handle errors that occur during caching
- **Impact**: Cache state does not affect state transition correctness

These adjustments are applied only to the testing build of the `lcli transition-blocks` tool; the production Lighthouse beacon node is not modified.

---

## 2. Prysm

**File**: `testing_clients/prysm/tools/pcli/main.go`

### Modification 1: Add pure Capella config (default network)
- **Location**: Line 227-239
- **Description**: When no `--network` flag is provided, we modify `pcli` so that it derives a “pure Capella” configuration from `params.MainnetConfig()` (Altair/Bellatrix/Capella fork epochs set to 0, Deneb to 75520), calls `cfg.InitializeForkSchedule()`, and then activates the config via `params.SetActive(cfg)`.
- **Purpose**: Ensure the default execution path of `pcli` matches the pure Capella test conditions
- **Impact**: The default behavior of the `pcli` tool uses the pure Capella config instead of the mainnet config

### Modification 2: Add post state saving code
- **Location**: Line 301-316
- **Added Code**:
  ```go
  // Store the post state to the expectedPostStatePath if provided.
  if expectedPostStatePath != "" {
      // Serialize the postState to SSZ format.
      postStateData, err := postState.MarshalSSZ()
      if err != nil {
          log.Fatal(err)
      }

      // Write the serialized data to the specified path.
      err = os.WriteFile(expectedPostStatePath, postStateData, 0644)
      if err != nil {
          log.Fatal(err)
      }

      log.Infof("Post state successfully written to %s", expectedPostStatePath)
  }
  ```
- **Purpose**: Save post state as SSZ file after state transition to enable comparison with other nodes
- **Modification Method**: Automatically inserted via awk command in `init_beaconnode.sh`

All Prysm changes are limited to the `pcli` testing tool; the Prysm beacon node remains unmodified.

---

## 3. Nimbus

**File**: `testing_clients/nimbus-eth2/ncli/ncli.nim`

### Modification: Override fork epochs for pure Capella network
- **Location**: Line 137-145 (doTransition), Line 186-194 (doSlots)
- **Original Code**:
  ```nim
  let cfg = getRuntimeConfig(conf.eth2Network)
  ```
- **Modified Code**:
  ```nim
  let cfgBase = getRuntimeConfig(conf.eth2Network)
  # Override fork epochs for pure Capella network (CAPELLA_FORK_EPOCH = 0)
  cfg = block:
    var c = cfgBase
    c.ALTAIR_FORK_EPOCH = Epoch(0)
    c.BELLATRIX_FORK_EPOCH = Epoch(0)
    c.CAPELLA_FORK_EPOCH = Epoch(0)
    c.DENEB_FORK_EPOCH = Epoch(75520)
    c
  ```
- **Purpose**: Override fork epochs to create a pure Capella network configuration (CAPELLA_FORK_EPOCH = 0) for differential testing
- **Impact**: Both `doTransition` and `doSlots` functions use the modified configuration
- **Additional Change**: Added import for datatypes (Line 14) to access Epoch type

This modification affects only the `ncli` CLI tool; the Nimbus beacon node is not modified.

---

## 4. Teku

**No Code Modifications**

- **Post state saving**: Already implemented via `--post` option (`TransitionCommand.java` Line 143, 164)
- **Signature verification**: Already enabled via `BLSSignatureVerifier.SIMPLE` (`TransitionCommand.java` Line 93)
- **State root verification**: Enabled by default
- CLI arguments only: Fork epoch settings (`--Xnetwork-altair-fork-epoch=0`, etc.)
- File: Teku source code (no modifications)
- Usage: Pass fork epoch arguments to `teku transition blocks` command in `diff_testing.py`

---

## Summary

| Node | Code Modified | Modified File | Modifications |
|------|---------------|---------------|---------------|
| **Lighthouse** | ✅ | `lcli/src/transition_blocks.rs` | 1. Comment out all_caches_built() assertion<br>2. Comment out indexed attestation cache assertion<br> |
| **Prysm** | ✅ | `tools/pcli/main.go` | 1. Add pure Capella config (default network)<br>2. Add post state saving code |
| **Nimbus** | ✅ | `ncli/ncli.nim` | Override fork epochs for pure Capella network |
| **Teku** | ❌ | - | CLI arguments only |
| **Lodestar** | Separate | `transition.js`, `generateCachedStateCapella.js` | Custom implementation (excluded) |

---

## Capella Network Configuration

All clients are configured to use the same pure Capella network settings (CAPELLA_FORK_EPOCH = 0) for consistent differential testing. The methods used for each client are:

| Node | Configuration Method | Details |
|------|---------------------|---------|
| **Lighthouse** | Config file | Uses `--testnet-dir` pointing to `Converter/pure_capella_configs/lighthouse_testnet/` which contains `config.yaml` with fork epochs set to 0 |
| **Prysm** | Code modification | Modified `main.go` to use pure Capella config as default when no network is specified (Line 227-239) |
| **Nimbus** | Code modification | Modified `ncli.nim` to override fork epochs programmatically in `doTransition` and `doSlots` functions (Line 137-145, 186-194) |
| **Teku** | CLI arguments | Uses `--Xnetwork-*-fork-epoch=0` command-line arguments (no code modification needed) |
| **Lodestar** | Code modification | Hardcoded pure Capella config in `transition.js` (Line 364-370) |

**Note**: The `Converter/pure_capella_configs/` directory contains only the Lighthouse testnet config.
---

## Modification Rationale

1. **Lighthouse assertion comments**:
   - Lighthouse's `lcli transition-blocks` is designed with the assumption that "caches are already fully built"
   - However, we use raw SSZ files directly from consensus-specs, so this assumption is not always satisfied
   - Therefore, we comment out these sanity check assertions to make the tool work in raw spec-tests environments
   - **BlockSignatureStrategy**: The original code already uses `NoVerification`, which is the correct setting. When `no_signature_verification = false`, signatures are already verified via `verify_entire_block`, so `per_block_processing` uses `NoVerification` to avoid double verification.
   - These changes are scoped strictly to the `lcli` CLI tool we use for testing; the Lighthouse beacon node is untouched.

2. **Prysm (pcli) adjustments**:
   - `pcli state-transition` now defaults to a pure Capella config when no network is specified
   - Added functionality to save post state as an SSZ file for comparison with other nodes
   - Only the `pcli` CLI tool is modified; the Prysm beacon node is untouched.

3. **Nimbus (ncli) fork epoch override**:
   - Nimbus's `ncli` does not support fork epoch configuration via CLI arguments
   - We override the fork epochs programmatically for pure Capella network (CAPELLA_FORK_EPOCH = 0) in both `doTransition` and `doSlots`
   - The change is limited to `ncli`; the Nimbus beacon node is not modified.

4. **Teku**:
   - Post state saving and signature verification features are already implemented, so no code modifications are needed
   - CLI arguments (fork epoch settings) provide all necessary functionality
