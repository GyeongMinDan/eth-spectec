#!/usr/bin/env python3
"""
Execute process_slots function for sanity/slots test cases.

This script processes slots test cases by executing process_slots(state, pre.slot + N)
where N is read from slots.yaml file.
"""

import sys
import os
import argparse
import yaml
from pathlib import Path

# Add eth2spec to path
script_dir = os.path.dirname(os.path.abspath(__file__))
consensus_specs_path = os.path.abspath(os.path.join(script_dir, '../consensus-specs/tests/core/pyspec'))
if consensus_specs_path not in sys.path:
    sys.path.insert(0, consensus_specs_path)

from eth2spec.utils.ssz.ssz_impl import deserialize


def read_slots_yaml(slots_yaml_path: str) -> int:
    """
    Read N value from slots.yaml file.
    
    Args:
        slots_yaml_path: Path to slots.yaml file
    
    Returns:
        N value (number of slots to process)
    """
    with open(slots_yaml_path, 'r') as f:
        content = f.read().strip()
        try:
            n = int(content.split()[0])
            return n
        except ValueError:
            raise ValueError(f"Failed to parse slots.yaml: expected a number, got '{content}'")


def main(pre_ssz_path, slots_yaml_path, output_ssz_path, fork="capella"):
    """Execute process_slots and save result"""
    
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
    
    # Read slots.yaml to get N value
    print(f"\nReading slots.yaml...")
    print(f"  - Path: {slots_yaml_path}")
    n = read_slots_yaml(slots_yaml_path)
    print(f"  - N (slots to process): {n}")
    
    # Calculate target slot: pre.slot + N
    target_slot = state.slot + n
    print(f"  - Target slot: {target_slot} (pre.slot + N)")
    
    # Execute process_slots
    print(f"\nExecuting process_slots(state, {target_slot})...")
    try:
        spec.process_slots(state, target_slot)
        print(f"  ✓ process_slots succeeded!")
    except Exception as e:
        print(f"  ✗ process_slots failed: {e}")
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
        description="Execute process_slots and save result"
    )
    parser.add_argument('--pre', dest='pre_ssz_path', required=True,
                       help='Path to pre.ssz file (BeaconState)')
    parser.add_argument('--slots-yaml', dest='slots_yaml_path', required=True,
                       help='Path to slots.yaml file')
    parser.add_argument('--out', dest='output_ssz_path', required=True,
                       help='Path to output SSZ file (BeaconState)')
    parser.add_argument('--fork', dest='fork', default='capella',
                       choices=['capella', 'deneb'],
                       help='Fork name to use (default: capella)')
    args = parser.parse_args()
    
    main(
        pre_ssz_path=args.pre_ssz_path,
        slots_yaml_path=args.slots_yaml_path,
        output_ssz_path=args.output_ssz_path,
        fork=args.fork
    )

