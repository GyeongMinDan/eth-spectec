# validate_result Modifications Guide

이 문서는 `validate_result=true`와 `validate_result=false` 설정에 따른 각 노드별 코드 수정사항을 정리합니다.

---

## 📋 개요

### validate_result의 의미

- **`validate_result=true`** (기본값): 모든 서명 검증 및 state root 검증 수행
  - 블록 서명 검증 ✅
  - State root 검증 ✅
  - RANDAO 서명 검증 ✅
  - Attestation 서명 검증 ✅
  - 기타 서명 검증 (Proposer Slashing, Attester Slashing, Voluntary Exit, BLS to Execution Change) ✅

- **`validate_result=false`**: 블록 서명과 state root 검증만 스킵
  - 블록 서명 검증 ❌
  - State root 검증 ❌
  - RANDAO 서명 검증 ✅
  - Attestation 서명 검증 ✅
  - 기타 서명 검증 (Proposer Slashing, Attester Slashing, Voluntary Exit, BLS to Execution Change) ✅

**참고**: `validate_result=false`는 블록 제안자(block proposer)의 관점에서 변형된 블록을 테스트하기 위한 모드입니다. 블록 서명과 state root는 제안자가 생성하는 것이므로, 이 두 가지만 스킵하고 나머지 검증은 수행합니다.

---

## 🔄 validate_result=true → validate_result=false 변경 가이드

### 1. Lodestar

**파일**: `spectec-core/diff_testing.py`

#### validate_result=true (원본)
```python
"verifyProposer=true",  # Enable signature verification
"verifyStateRoot=true",  # Enable state root verification
```

#### validate_result=false (수정)
```python
"verifyProposer=false",  # validate_result = false: Skip block signature verification
"verifyStateRoot=false",  # validate_result = false: Skip state root verification
```

**위치**: Line 252-253

**설명**: Lodestar의 `transition.js`는 CLI 인자로 `verifyProposer`와 `verifyStateRoot`를 받아서 블록 서명과 state root 검증을 제어합니다.

---

### 2. Nimbus

**파일**: `spectec-core/diff_testing.py`

#### validate_result=true (원본)
```python
"true"  # Enable state root verification (both signature and state root verification enabled)
```

#### validate_result=false (수정)
```python
"false"  # validate_result = false: Skip state root verification (also skips block signature verification)
```

**위치**: Line 288

**설명**: Nimbus의 `ncli transition`은 마지막 인자로 `verifyStateRoot`를 받습니다. `false`로 설정하면 state root 검증과 블록 서명 검증이 모두 스킵됩니다.

**참고**: Nimbus 코드에서 `skipStateRootValidation`이 설정되면 블록 서명 검증도 함께 스킵됩니다 (`state_transition.nim` Line 335-336).

---

### 3. Teku

**파일**: `spectec-core/testing_clients/teku/ethereum/spec/src/main/java/tech/pegasys/teku/spec/logic/common/block/AbstractBlockProcessor.java`

#### validate_result=true (원본)
```java
// validate_result = true: Verify block signature and state root
return BlockValidationResult.allOf(
    () -> verifyBlockSignatures(preState, block, indexedAttestationCache, signatureVerifier),
    () -> validatePostState(postState, block));
```

```java
return BlockValidationResult.allOf(
    // validate_result = true: Verify block signature
    () -> verifyBlockSignature(preState, block, signatureVerifier),
    () -> verifyAttestationSignatures(...),
    () -> verifyRandao(...),
    () -> verifyProposerSlashings(...),
    () -> verifyVoluntaryExits(...));
```

#### validate_result=false (수정)
```java
// validate_result = false: Skip state root verification, but verify signatures (RANDAO, attestations, etc.)
// verifyBlockSignatures will skip block signature but verify other signatures
return BlockValidationResult.allOf(
    () -> verifyBlockSignatures(preState, block, indexedAttestationCache, signatureVerifier)
    // () -> validatePostState(postState, block)  // Skip state root verification for validate_result = false
);
```

```java
// validate_result = false: Skip block signature verification, but verify other signatures (RANDAO, attestations, etc.)
return BlockValidationResult.allOf(
    // () -> verifyBlockSignature(preState, block, signatureVerifier),  // Skip block signature for validate_result = false
    () ->
        verifyAttestationSignatures(
            preState, blockBody.getAttestations(), signatureVerifier, indexedAttestationCache),
    () -> verifyRandao(preState, blockMessage, signatureVerifier),
    () ->
        verifyProposerSlashings(preState, blockBody.getProposerSlashings(), signatureVerifier),
    () -> verifyVoluntaryExits(preState, blockBody.getVoluntaryExits(), signatureVerifier));
```

**위치**: 
- Line 222-228: `validateBlockPostProcessing` 메서드 - `verifyBlockSignatures`는 호출하되 `validatePostState`만 주석처리
- Line 240-248: `verifyBlockSignatures` 메서드 - `verifyBlockSignature`만 주석처리

**설명**: 
- `validateBlockPostProcessing`에서 `verifyBlockSignatures`는 호출하여 RANDAO, attestation 등의 서명 검증을 수행합니다.
- `validatePostState`만 주석처리하여 state root 검증을 스킵합니다.
- `verifyBlockSignatures` 내부에서는 블록 서명 검증(`verifyBlockSignature`)만 주석처리하고, 나머지 서명 검증은 모두 수행합니다.

---

### 4. Prysm

**파일 1**: `spectec-core/testing_clients/prysm/tools/pcli/main.go`

#### validate_result=true (원본)
```go
// Execute per block transition.
set, st, err := transition.ProcessBlockNoVerifyAnySig(ctx, st, signed)
if err != nil {
    return st, errors.Wrap(err, "could not process block")
}
var valid bool
valid, err = set.VerifyVerbosely()
if err != nil {
    return st, errors.Wrap(err, "could not batch verify signature")
}
if !valid {
    return st, errors.New("signature in block failed to verify")
}
return st, nil
```

```go
// Verify that the computed post-state root matches the state root in the block
blockStateRoot := block.Block().StateRoot()
if !bytes.Equal(postRoot[:], blockStateRoot[:]) {
    log.Fatalf("State root mismatch! Block contains %#x, but computed post-state root is %#x", blockStateRoot, postRoot)
}
```

#### validate_result=false (수정)
```go
// Execute per block transition.
// validate_result = false: Skip block signature verification, but verify RANDAO and attestation signatures
set, st, err := transition.ProcessBlockNoVerifyAnySig(ctx, st, signed)
if err != nil {
    return st, errors.Wrap(err, "could not process block")
}
// validate_result = false: Only verify RANDAO and attestation signatures, skip block signature
// Create a new set excluding block signatures by filtering descriptions
filteredSet := bls.NewSet()
for i := 0; i < len(set.Signatures); i++ {
    desc := set.Descriptions[i]
    // Skip block signature, verify all other signatures (RANDAO, attestations, etc.)
    if !strings.Contains(desc, "block") && !strings.Contains(desc, "Block") {
        filteredSet.Signatures = append(filteredSet.Signatures, set.Signatures[i])
        filteredSet.PublicKeys = append(filteredSet.PublicKeys, set.PublicKeys[i])
        filteredSet.Messages = append(filteredSet.Messages, set.Messages[i])
        filteredSet.Descriptions = append(filteredSet.Descriptions, desc)
    }
}
// Verify only non-block signatures
if len(filteredSet.Signatures) > 0 {
    valid, err := filteredSet.VerifyVerbosely()
    if err != nil {
        return st, errors.Wrap(err, "could not batch verify signature")
    }
    if !valid {
        return st, errors.New("signature in block failed to verify")
    }
}
return st, nil
```

```go
// validate_result = false: Skip state root verification
// Verify that the computed post-state root matches the state root in the block
// blockStateRoot := block.Block().StateRoot()
// if !bytes.Equal(postRoot[:], blockStateRoot[:]) {
//     log.Fatalf("State root mismatch! Block contains %#x, but computed post-state root is %#x", blockStateRoot, postRoot)
// }
```

**위치**: 
- Line 461-489: `debugStateTransition` 함수 내 서명 검증 로직
- Line 304-308: State root 검증 주석처리

**파일 2**: `spectec-core/testing_clients/prysm/beacon-chain/core/transition/transition_no_verify_sig.go`

#### validate_result=true (원본)
```go
randaoReveal := signed.Block().Body().RandaoReveal()
state, err = b.ProcessRandaoNoVerify(state, randaoReveal[:])
if err != nil {
    tracing.AnnotateError(span, err)
    return nil, errors.Wrap(err, "could not verify and process randao")
}
```

#### validate_result=false (수정)
```go
// validate_result = false: Verify RANDAO signature (block signature is skipped in main.go)
state, err = b.ProcessRandao(ctx, state, signed)
if err != nil {
    tracing.AnnotateError(span, err)
    return nil, errors.Wrap(err, "could not verify and process randao")
}
```

**위치**: Line 343-348

**설명**: 
- `ProcessBlockNoVerifyAnySig`는 모든 서명을 수집만 하고 검증하지 않습니다.
- 원본 `debugStateTransition`은 `set.VerifyVerbosely()`로 모든 서명을 검증합니다.
- `validate_result=false`에서는 블록 서명만 필터링하여 제외하고, 나머지 서명(RANDAO, attestation 등)은 검증합니다.
- RANDAO 서명 검증을 위해 `ProcessRandaoNoVerify`를 `ProcessRandao`로 변경합니다.

**필요한 import 추가**:
- `BUILD.bazel`에 `//crypto/bls:go_default_library` 의존성 추가

---

### 5. Lighthouse

**파일 1**: `spectec-core/testing_clients/lighthouse/consensus/state_processing/src/per_block_processing.rs`

#### validate_result=true (원본)
```rust
pub enum BlockSignatureStrategy {
    /// Do not validate any signature. Use with caution.
    NoVerification,
    /// Validate each signature individually, as its object is being processed.
    VerifyIndividual,
    /// Validate only the randao reveal signature.
    VerifyRandao,
    /// Verify all signatures in bulk at the beginning of block processing.
    VerifyBulk,
}
```

```rust
let verify_signatures = match block_signature_strategy {
    BlockSignatureStrategy::VerifyBulk => {
        // Verify all signatures in the block at once.
        block_verify!(...);
        VerifySignatures::False
    }
    BlockSignatureStrategy::VerifyIndividual => VerifySignatures::True,
    BlockSignatureStrategy::NoVerification => VerifySignatures::False,
    BlockSignatureStrategy::VerifyRandao => VerifySignatures::False,
};

if verify_signatures.is_true() {
    verify_block_signature(state, signed_block, ctxt, spec)?;
}
```

#### validate_result=false (수정)
```rust
pub enum BlockSignatureStrategy {
    /// Do not validate any signature. Use with caution.
    NoVerification,
    /// Validate each signature individually, as its object is being processed.
    VerifyIndividual,
    /// Validate only the randao reveal signature.
    VerifyRandao,
    /// Verify all signatures in bulk at the beginning of block processing.
    VerifyBulk,
    /// Skip block signature verification only, but verify all other signatures (RANDAO, attestations, etc.)
    SkipBlockSignatureOnly,
}
```

```rust
let verify_signatures = match block_signature_strategy {
    BlockSignatureStrategy::VerifyBulk => {
        // Verify all signatures in the block at once.
        block_verify!(...);
        VerifySignatures::False
    }
    BlockSignatureStrategy::VerifyIndividual => VerifySignatures::True,
    BlockSignatureStrategy::NoVerification => VerifySignatures::False,
    BlockSignatureStrategy::VerifyRandao => VerifySignatures::False,
    BlockSignatureStrategy::SkipBlockSignatureOnly => {
        // validate_result = false: Skip block signature, but verify other signatures
        VerifySignatures::True
    }
};

// validate_result = false: Skip block signature verification when SkipBlockSignatureOnly
if verify_signatures.is_true() && block_signature_strategy != BlockSignatureStrategy::SkipBlockSignatureOnly {
    verify_block_signature(state, signed_block, ctxt, spec)?;
}
```

**위치**: 
- Line 55-64: `BlockSignatureStrategy` enum에 `SkipBlockSignatureOnly` variant 추가
- Line 127-147: `verify_signatures` 매칭 로직 수정
- Line 157-159: 블록 서명 검증 조건 수정

**파일 2**: `spectec-core/testing_clients/lighthouse/lcli/src/transition_blocks.rs`

#### validate_result=true (원본)
```rust
if !config.no_signature_verification {
    // Verify all signatures in bulk
    BlockSignatureVerifier::verify_entire_block(...)?;
}

per_block_processing(
    &mut pre_state,
    &block,
    BlockSignatureStrategy::NoVerification,  // All signatures already verified above
    VerifyBlockRoot::True,
    &mut ctxt,
    spec,
)?;

if !config.exclude_post_block_thc {
    let post_state_root = pre_state.update_tree_hash_cache()?;
    let block_state_root = block.state_root();
    if post_state_root != block_state_root {
        return Err(format!("State root mismatch! ..."));
    }
}
```

#### validate_result=false (수정)
```rust
// validate_result = false: Use SkipBlockSignatureOnly to skip block signature but verify other signatures
let block_signature_strategy = if config.no_signature_verification {
    // --no-signature-verification: Skip all signatures (for backward compatibility)
    BlockSignatureStrategy::NoVerification
} else {
    // validate_result = false: Skip block signature only, verify RANDAO and attestation signatures
    BlockSignatureStrategy::SkipBlockSignatureOnly
};

per_block_processing(
    &mut pre_state,
    &block,
    block_signature_strategy,
    VerifyBlockRoot::True,
    &mut ctxt,
    spec,
)?;

// validate_result = false: Skip state root verification
// if !config.exclude_post_block_thc {
//     let post_state_root = pre_state.update_tree_hash_cache()?;
//     let block_state_root = block.state_root();
//     if post_state_root != block_state_root {
//         return Err(format!("State root mismatch! ..."));
//     }
// }
```

**위치**: 
- Line 370-377: `block_signature_strategy` 결정 로직
- Line 420-423: `per_block_processing` 호출
- Line 431-447: State root 검증 주석처리

**설명**: 
- `SkipBlockSignatureOnly` enum variant를 추가하여 블록 서명만 스킵하고 다른 서명은 검증하도록 합니다.
- `per_block_processing` 내부에서 `SkipBlockSignatureOnly`일 때는 블록 서명 검증을 스킵하지만, `verify_signatures`는 `True`로 설정되어 RANDAO, attestation 등의 서명은 검증됩니다.

**사용하지 않는 import 제거**:
- `BlockSignatureVerifier` import 제거
- `Cow` import 제거
- `validator_pubkey_cache` 파라미터를 `_validator_pubkey_cache`로 변경

---

## 📝 요약 테이블

| 노드 | validate_result=true | validate_result=false |
|------|---------------------|----------------------|
| **Lodestar** | `verifyProposer=true`<br>`verifyStateRoot=true` | `verifyProposer=false`<br>`verifyStateRoot=false` |
| **Nimbus** | `"true"` (마지막 인자) | `"false"` (마지막 인자) |
| **Teku** | 블록 서명 검증 ✅<br>State root 검증 ✅ | 블록 서명 검증 주석처리<br>State root 검증 주석처리 |
| **Prysm** | `set.VerifyVerbosely()` (모든 서명)<br>State root 검증 ✅ | 블록 서명 필터링 제외<br>State root 검증 주석처리<br>`ProcessRandao` 사용 |
| **Lighthouse** | `VerifyBulk` 또는 `NoVerification`<br>State root 검증 ✅ | `SkipBlockSignatureOnly` enum 추가<br>State root 검증 주석처리 |

---

## 🔍 검증 체크리스트

### validate_result=false 설정 시 확인사항

- [ ] **블록 서명 검증**: 모든 노드에서 스킵됨
- [ ] **State root 검증**: 모든 노드에서 스킵됨
- [ ] **RANDAO 서명 검증**: 모든 노드에서 수행됨
- [ ] **Attestation 서명 검증**: 모든 노드에서 수행됨
- [ ] **Proposer Slashing 서명 검증**: 모든 노드에서 수행됨
- [ ] **Attester Slashing 서명 검증**: 모든 노드에서 수행됨
- [ ] **Voluntary Exit 서명 검증**: 모든 노드에서 수행됨
- [ ] **BLS to Execution Change 서명 검증**: 모든 노드에서 수행됨

---

## 🚨 주의사항

1. **Prysm**: `BUILD.bazel`에 `//crypto/bls:go_default_library` 의존성이 필요합니다.
2. **Lighthouse**: 사용하지 않는 import를 제거해야 빌드 warning이 발생하지 않습니다.
3. **Nimbus**: `skipStateRootValidation`이 설정되면 블록 서명 검증도 함께 스킵됩니다.
4. **Teku**: `verifyBlockSignatures` 전체를 주석처리하면 안 되고, `verifyBlockSignature`만 주석처리해야 합니다.

---
