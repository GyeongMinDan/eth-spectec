#!/usr/bin/env python3
"""
Execute epoch processing functions (process_justification_and_finalization, etc.)
for epoch_processing test cases.

This script processes epoch_processing test cases by executing individual
epoch processing functions on a BeaconState.
"""

import sys
import os
import argparse

# Add eth2spec to path
script_dir = os.path.dirname(os.path.abspath(__file__))
consensus_specs_path = os.path.abspath(os.path.join(script_dir, '../consensus-specs/tests/core/pyspec'))
if consensus_specs_path not in sys.path:
    sys.path.insert(0, consensus_specs_path)

from eth2spec.utils.ssz.ssz_impl import deserialize

# Epoch processing function name mapping (folder name -> function name)
EPOCH_PROCESSING_FUNCTIONS = {
    'justification_and_finalization': 'process_justification_and_finalization',
    'inactivity_updates': 'process_inactivity_updates',
    'rewards_and_penalties': 'process_rewards_and_penalties',
    'registry_updates': 'process_registry_updates',
    'slashings': 'process_slashings',
    'eth1_data_reset': 'process_eth1_data_reset',
    'effective_balance_updates': 'process_effective_balance_updates',
    'slashings_reset': 'process_slashings_reset',
    'randao_mixes_reset': 'process_randao_mixes_reset',
    'historical_summaries_update': 'process_historical_summaries_update',
    'participation_flag_updates': 'process_participation_flag_updates',
}


def main(pre_ssz_path, output_ssz_path, epoch_processing_type, fork="capella"):
    """Execute epoch processing function and save result"""
    
    # Import the appropriate fork module
    if fork == "deneb":
        from eth2spec.deneb import mainnet as spec
    elif fork == "capella":
        from eth2spec.capella import mainnet as spec
    else:
        raise ValueError(f"Unsupported fork: {fork}. Supported forks: 'capella', 'deneb'")
    
    # Read pre.ssz (BeaconState)
    print(f"Reading pre.ssz (BeaconState) using {fork} fork...")
    print(f"  - Path: {pre_ssz_path}")
    with open(pre_ssz_path, 'rb') as f:
        state_data = f.read()
    state = deserialize(spec.BeaconState, state_data)
    print(f"  - State slot: {state.slot}")
    
    # Get epoch processing function name
    if epoch_processing_type not in EPOCH_PROCESSING_FUNCTIONS:
        raise ValueError(f"Unsupported epoch processing type: {epoch_processing_type}. "
                        f"Supported types: {list(EPOCH_PROCESSING_FUNCTIONS.keys())}")
    
    func_name = EPOCH_PROCESSING_FUNCTIONS[epoch_processing_type]
    
    # Get the processing function
    process_func = getattr(spec, func_name)
    
    # Execute the processing function
    print(f"\nExecuting {func_name}...")
    try:
        process_func(state)
        print(f"  ✓ {func_name} succeeded!")
    except Exception as e:
        print(f"  ✗ {func_name} failed: {e}")
        raise
    
    # Save postState to output SSZ
    print(f"\nSaving postState to {output_ssz_path}...")
    post_state_ssz = state.encode_bytes()
    with open(output_ssz_path, 'wb') as f:
        f.write(post_state_ssz)
    print(f"  ✓ Saved to {output_ssz_path}")
    print(f"  - Post state slot: {state.slot}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description="Execute epoch processing function and save result"
    )
    parser.add_argument('--pre', dest='pre_ssz_path', required=True,
                       help='Path to pre.ssz file (BeaconState)')
    parser.add_argument('--out', dest='output_ssz_path', required=True,
                       help='Path to output SSZ file (BeaconState)')
    parser.add_argument('--epoch-processing-type', dest='epoch_processing_type', required=True,
                       choices=list(EPOCH_PROCESSING_FUNCTIONS.keys()),
                       help='Type of epoch processing function to execute')
    parser.add_argument('--fork', dest='fork', default='capella',
                       choices=['capella', 'deneb'],
                       help='Fork name to use (default: capella)')
    args = parser.parse_args()
    
    main(
        pre_ssz_path=args.pre_ssz_path,
        output_ssz_path=args.output_ssz_path,
        epoch_processing_type=args.epoch_processing_type,
        fork=args.fork
    )

