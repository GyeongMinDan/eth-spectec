import sys
import os

# Add eth2spec to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../consensus-specs/tests/core/pyspec'))

from eth2spec.capella import mainnet as spec
from eth2spec.utils.ssz.ssz_impl import deserialize, hash_tree_root


def test_state_transition():
    """Test state_transition with SSZ files"""
    
    # Get script directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # Read pre.ssz (BeaconState)
    print("Reading pre.ssz (BeaconState)...")
    pre_ssz_path = os.path.join(script_dir, 'pre.ssz')
    with open(pre_ssz_path, 'rb') as f:
        state_data = f.read()
    state = deserialize(spec.BeaconState, state_data)
    print(f"  - State slot: {state.slot}")
    print(f"  - Validators count: {len(state.validators)}")
    
    # Read blocks_0.ssz (SignedBeaconBlock)
    print("\nReading blocks_0.ssz (SignedBeaconBlock)...")
    blocks_ssz_path = os.path.join(script_dir, 'blocks_0.ssz')
    with open(blocks_ssz_path, 'rb') as f:
        block_data = f.read()
    signed_block = deserialize(spec.SignedBeaconBlock, block_data)
    print(f"  - Block slot: {signed_block.message.slot}")
    print(f"  - Proposer index: {signed_block.message.proposer_index}")
    
    # Calculate state root before transition
    state_root_before = hash_tree_root(state)
    print(f"\nState root before transition: {state_root_before.hex()}")
    
    # Debug: Check proposer index calculation
    print("\n=== Debug: Proposer Index Calculation ===")
    print(f"State slot (before Process_slots): {state.slot}")
    
    # Execute Process_slots first (like in Spectec)
    spec.process_slots(state, signed_block.message.slot)
    print(f"State slot (after Process_slots): {state.slot}")
    
    # Detailed debug: step by step calculation
    print("\n--- Step-by-step calculation ---")
    epoch = spec.get_current_epoch(state)
    print(f"Current epoch: {epoch}")
    
    # Get seed
    seed_base = spec.get_seed(state, epoch, spec.DOMAIN_BEACON_PROPOSER)
    print(f"Seed base (bytes32): {seed_base.hex()}")
    print(f"Seed base (int): {int.from_bytes(seed_base, 'big')}")
    
    # Hash with slot
    slot_bytes = state.slot.to_bytes(8, 'little')
    seed_bytes = seed_base
    msg_bytes = seed_bytes + slot_bytes
    h = spec.hash(msg_bytes)
    print(f"Hash (seed + slot) (bytes32): {h.hex()}")
    print(f"Hash (seed + slot) (int): {int.from_bytes(h, 'big')}")
    
    # Get active validators
    active_indices = spec.get_active_validator_indices(state, epoch)
    print(f"Active validator indices count: {len(active_indices)}")
    print(f"First 10 indices: {active_indices[:10]}")
    
    # Calculate proposer index with detailed logging
    # Use hash(seed + slot) as seed for compute_proposer_index (not seed_base!)
    print("\n--- Computing proposer index (using hash(seed+slot) as seed) ---")
    print(f"Using hash(seed+slot) as seed for compute_proposer_index")
    print(f"This hash: {h.hex()}")
    print(f"This hash (int): {int.from_bytes(h, 'big')}")
    
    total = len(active_indices)
    print(f"\n--- Iterations (using hash(seed+slot) as seed) ---")
    for i in range(min(20, total * 2)):  # Check first 20 iterations
        index_mod = i % total
        # IMPORTANT: Use hash(seed+slot), not seed_base!
        shuffled_index = spec.compute_shuffled_index(index_mod, total, h)
        candidate = active_indices[shuffled_index]
        
        # Calculate random byte
        chunk = i // 32
        chunk_bytes = chunk.to_bytes(8, 'little')
        hash_input = h + chunk_bytes  # Use h (hash(seed+slot)), not seed_bytes
        hash_result = spec.hash(hash_input)
        byte_index = i % 32
        random_byte = hash_result[byte_index]
        
        # Get validator
        validator = state.validators[candidate]
        effective_balance = validator.effective_balance
        
        # Check break condition
        # MAX_RANDOM_BYTE = 255 (uint8 max)
        max_random_byte = 255
        left = effective_balance * max_random_byte
        right = spec.MAX_EFFECTIVE_BALANCE * random_byte
        condition_met = left >= right
        
        print(f"i={i}: candidate={candidate}, shuffled={shuffled_index}, "
              f"effective={effective_balance}, random_byte={random_byte}, "
              f"condition={condition_met} ({left} >= {right})")
        
        if condition_met:
            print(f"  → BREAK at i={i}, returning candidate={candidate}")
            break
    
    # Calculate proposer index after Process_slots (like in Spectec)
    calculated_proposer = spec.get_beacon_proposer_index(state)
    print(f"\nCalculated proposer_index: {calculated_proposer}")
    print(f"Block's proposer_index: {signed_block.message.proposer_index}")
    print(f"Match: {calculated_proposer == signed_block.message.proposer_index}")
    
    # Reload state for actual state_transition (since we modified it above)
    with open(pre_ssz_path, 'rb') as f:
        state_data = f.read()
    state = deserialize(spec.BeaconState, state_data)
    
    # Execute state_transition
    print("\nExecuting state_transition...")
    try:
        spec.state_transition(state, signed_block, validate_result=False)
        print("  ✓ State transition succeeded!")
    except Exception as e:
        print(f"  ✗ State transition failed: {e}")
        return False
    
    # Calculate state root after transition
    state_root_after = hash_tree_root(state)
    print(f"\nState root after transition: {state_root_after.hex()}")
    
    # Compare with block's expected state root
    block_state_root = signed_block.message.state_root
    print(f"Block's expected state root: {block_state_root.hex()}")
    
    if state_root_after == block_state_root:
        print("\n✓ State root matches! Validation passed.")
        return True
    else:
        print("\n✗ State root mismatch! Validation failed.")
        return False


if __name__ == '__main__':
    result = test_state_transition()
    sys.exit(0 if result else 1)

