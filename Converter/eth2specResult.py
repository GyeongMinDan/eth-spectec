import sys
import os
import argparse
import importlib

# Add eth2spec to path
# Get the absolute path to ensure it works from any directory
script_dir = os.path.dirname(os.path.abspath(__file__))
# Updated path: Converter -> spectec-core -> consensus-specs
consensus_specs_path = os.path.abspath(os.path.join(script_dir, '../consensus-specs/tests/core/pyspec'))
if consensus_specs_path not in sys.path:
    sys.path.insert(0, consensus_specs_path)

from eth2spec.utils.ssz.ssz_impl import deserialize


def main(pre_ssz_path=None, blocks_ssz_path=None, output_ssz_path=None, fork="capella"):
    """Decode SSZ files, execute state_transition, and save result"""
    
    supported_forks = ("phase0", "altair", "bellatrix", "capella", "deneb", "electra")
    if fork not in supported_forks:
        raise ValueError(f"Unsupported fork: {fork}. Supported forks: {', '.join(supported_forks)}")
    spec = importlib.import_module(f"eth2spec.{fork}.mainnet")
    
    # If paths are not provided, use default behavior (backward compatibility)
    if pre_ssz_path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        pre_ssz_path = os.path.join(script_dir, 'pre.ssz')
    
    if blocks_ssz_path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        blocks_ssz_path = os.path.join(script_dir, 'blocks_0.ssz')
    
    if output_ssz_path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        output_ssz_path = os.path.join(script_dir, 'eth2specResult.ssz')
    
    # Read pre.ssz (BeaconState)
    print(f"Reading pre.ssz (BeaconState) using {fork} fork...")
    print(f"  - Path: {pre_ssz_path}")
    with open(pre_ssz_path, 'rb') as f:
        state_data = f.read()
    state = deserialize(spec.BeaconState, state_data)
    print(f"  - State slot: {state.slot}")
    
    # Read blocks_*.ssz (SignedBeaconBlock)
    print(f"\nReading blocks SSZ (SignedBeaconBlock) using {fork} fork...")
    print(f"  - Path: {blocks_ssz_path}")
    with open(blocks_ssz_path, 'rb') as f:
        block_data = f.read()
    signed_block = deserialize(spec.SignedBeaconBlock, block_data)
    print(f"  - Block slot: {signed_block.message.slot}")
    
    # Execute state_transition
    print("\nExecuting state_transition...")
    try:
        spec.state_transition(state, signed_block, validate_result=True)
        print("  ✓ State transition succeeded!")
    except Exception as e:
        print(f"  ✗ State transition failed: {e}")
        raise
    
    # Save postState to output SSZ
    print(f"\nSaving postState to {output_ssz_path}...")
    post_state_ssz = state.encode_bytes()
    with open(output_ssz_path, 'wb') as f:
        f.write(post_state_ssz)
    print(f"  ✓ Saved to {output_ssz_path}")
    print(f"  - Post state slot: {state.slot}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Execute state_transition and save result")
    parser.add_argument('--pre', dest='pre_ssz_path', help='Path to pre.ssz file')
    parser.add_argument('--block', dest='blocks_ssz_path', help='Path to blocks_*.ssz file')
    parser.add_argument('--out', dest='output_ssz_path', help='Path to output SSZ file')
    parser.add_argument('--fork', dest='fork', default='capella',
                        choices=['phase0', 'altair', 'bellatrix', 'capella', 'deneb', 'electra'],
                        help='Fork name to use (default: capella)')
    args = parser.parse_args()
    
    main(
        pre_ssz_path=args.pre_ssz_path,
        blocks_ssz_path=args.blocks_ssz_path,
        output_ssz_path=args.output_ssz_path,
        fork=args.fork
    )
