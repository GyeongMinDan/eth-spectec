import sys
import os

# Add eth2spec to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../consensus-specs/tests/core/pyspec'))

from eth2spec.capella import mainnet as spec
from eth2spec.utils.ssz.ssz_impl import deserialize


def main():
    """Decode SSZ files, execute state_transition, and save result"""
    
    # Get script directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # Read pre.ssz (BeaconState)
    print("Reading pre.ssz (BeaconState)...")
    pre_ssz_path = os.path.join(script_dir, 'pre.ssz')
    with open(pre_ssz_path, 'rb') as f:
        state_data = f.read()
    state = deserialize(spec.BeaconState, state_data)
    print(f"  - State slot: {state.slot}")
    
    # Read blocks_0.ssz (SignedBeaconBlock)
    print("\nReading blocks_0.ssz (SignedBeaconBlock)...")
    blocks_ssz_path = os.path.join(script_dir, 'blocks_0.ssz')
    with open(blocks_ssz_path, 'rb') as f:
        block_data = f.read()
    signed_block = deserialize(spec.SignedBeaconBlock, block_data)
    print(f"  - Block slot: {signed_block.message.slot}")
    
    # Execute state_transition
    print("\nExecuting state_transition...")
    try:
        spec.state_transition(state, signed_block, validate_result=False)
        print("  ✓ State transition succeeded!")
    except Exception as e:
        print(f"  ✗ State transition failed: {e}")
        raise
    
    # Save postState to output_1.ssz
    print("\nSaving postState to output_1.ssz...")
    output_ssz_path = os.path.join(script_dir, 'output_1.ssz')
    post_state_ssz = state.encode_bytes()
    with open(output_ssz_path, 'wb') as f:
        f.write(post_state_ssz)
    print(f"  ✓ Saved to {output_ssz_path}")
    print(f"  - Post state slot: {state.slot}")


if __name__ == '__main__':
    main()

