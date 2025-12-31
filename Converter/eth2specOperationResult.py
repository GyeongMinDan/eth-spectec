#!/usr/bin/env python3
"""
Execute operation processing functions (process_attestation, process_deposit, etc.)
for operations test cases.

This script is similar to eth2specResult.py but handles individual operations
instead of full state_transition.
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


class MockExecutionEngine:
    """ExecutionEngine that returns execution_valid value from execution.yaml"""
    def __init__(self, execution_valid: bool):
        self.execution_valid = execution_valid
    
    def notify_new_payload(self, execution_payload) -> bool:
        return self.execution_valid
    
    def notify_forkchoice_updated(self, head_block_hash, safe_block_hash, finalized_block_hash, payload_attributes):
        pass
    
    def get_payload(self, payload_id):
        raise NotImplementedError("no default block production")
    
    def is_valid_block_hash(self, execution_payload) -> bool:
        return True
    
    def verify_and_notify_new_payload(self, new_payload_request) -> bool:
        return self.execution_valid


def get_execution_engine_for_test(operation_ssz_path: str, spec) -> object:
    """
    Read execution.yaml file to check execution_valid value and return appropriate ExecutionEngine.
    
    Args:
        operation_ssz_path: Path to operation SSZ file (e.g., body.ssz)
        spec: eth2spec module
    
    Returns:
        ExecutionEngine instance
    """
    operation_ssz_file = Path(operation_ssz_path)
    execution_yaml_path = operation_ssz_file.parent / "execution.yaml"
    
    if execution_yaml_path.exists():
        try:
            with open(execution_yaml_path, 'r') as f:
                execution_config = yaml.safe_load(f)
                execution_valid = execution_config.get('execution_valid', True)
                print(f"  Reading execution.yaml: execution_valid = {execution_valid}")
                return MockExecutionEngine(execution_valid)
        except Exception as e:
            print(f"  Warning: Failed to read execution.yaml: {e}")
            print(f"  Using default EXECUTION_ENGINE (execution_valid = True)")
            return spec.EXECUTION_ENGINE
    else:
        return spec.EXECUTION_ENGINE


# Operation type to function name mapping
OPERATION_FUNCTIONS = {
    'attestation': 'process_attestation',
    'deposit': 'process_deposit',
    'proposer_slashing': 'process_proposer_slashing',
    'attester_slashing': 'process_attester_slashing',
    'voluntary_exit': 'process_voluntary_exit',
    'bls_to_execution_change': 'process_bls_to_execution_change',
    'sync_aggregate': 'process_sync_aggregate',
    'block_header': 'process_block_header',
    'execution_payload': 'process_execution_payload',
    'withdrawals': 'process_withdrawals',
}

# Operation type to SSZ type name mapping
OPERATION_TYPES = {
    'attestation': 'Attestation',
    'deposit': 'Deposit',
    'proposer_slashing': 'ProposerSlashing',
    'attester_slashing': 'AttesterSlashing',
    'voluntary_exit': 'SignedVoluntaryExit',
    'bls_to_execution_change': 'SignedBLSToExecutionChange',
    'sync_aggregate': 'SyncAggregate',
    'block_header': 'BeaconBlock', # block_header tests provide block.ssz_snappy (BeaconBlock)
    'execution_payload': 'BeaconBlockBody',  # execution_payload tests provide body.ssz_snappy
    'withdrawals': 'ExecutionPayload',  # withdrawals tests provide execution_payload.ssz_snappy
}


def main(pre_ssz_path, operation_ssz_path, output_ssz_path, operation_type, fork="capella"):
    """Execute operation processing function and save result"""
    
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
    
    # Get operation type and function
    if operation_type not in OPERATION_FUNCTIONS:
        raise ValueError(f"Unsupported operation type: {operation_type}. "
                        f"Supported types: {list(OPERATION_FUNCTIONS.keys())}")
    
    func_name = OPERATION_FUNCTIONS[operation_type]
    type_name = OPERATION_TYPES[operation_type]
    
    # Read operation SSZ
    print(f"\nReading {operation_type} SSZ ({type_name}) using {fork} fork...")
    print(f"  - Path: {operation_ssz_path}")
    with open(operation_ssz_path, 'rb') as f:
        operation_data = f.read()
    
    # Deserialize operation
    operation_type_class = getattr(spec, type_name)
    operation = deserialize(operation_type_class, operation_data)
    print(f"  - Operation type: {type_name}")
    
    # Get the processing function
    process_func = getattr(spec, func_name)
    
    # Execute the processing function
    print(f"\nExecuting {func_name}...")
    try:
        if operation_type == 'execution_payload':
            # process_execution_payload(state, body, EXECUTION_ENGINE)
            # Read execution_valid value from execution.yaml and create ExecutionEngine
            execution_engine = get_execution_engine_for_test(operation_ssz_path, spec)
            process_func(state, operation, execution_engine)
        elif operation_type == 'withdrawals':
            # process_withdrawals(state, ExecutionPayload)
            process_func(state, operation)
        else:
            # Other operations: process_*(state, operation)
            process_func(state, operation)
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
        description="Execute operation processing function and save result"
    )
    parser.add_argument('--pre', dest='pre_ssz_path', required=True,
                       help='Path to pre.ssz file (BeaconState)')
    parser.add_argument('--operation', dest='operation_ssz_path', required=True,
                       help='Path to operation SSZ file (e.g., attestation.ssz)')
    parser.add_argument('--out', dest='output_ssz_path', required=True,
                       help='Path to output SSZ file (BeaconState)')
    parser.add_argument('--operation-type', dest='operation_type', required=True,
                       choices=list(OPERATION_FUNCTIONS.keys()),
                       help='Type of operation to process (attestation, deposit, etc.)')
    parser.add_argument('--fork', dest='fork', default='capella',
                       choices=['capella', 'deneb'],
                       help='Fork name to use (default: capella)')
    args = parser.parse_args()
    
    main(
        pre_ssz_path=args.pre_ssz_path,
        operation_ssz_path=args.operation_ssz_path,
        output_ssz_path=args.output_ssz_path,
        operation_type=args.operation_type,
        fork=args.fork
    )

