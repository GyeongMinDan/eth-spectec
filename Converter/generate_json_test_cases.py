#!/usr/bin/env python3
"""
Generate JSON input/output test case pairs from the official Ethereum test suite.

This script processes test cases and generates (pre.json, block.json, post.json) triples
that can be used to test the SpecTec OCaml interpreter.

For block tests:
  - Generates (pre.json, block.json, post.json) triples
  - For single-block tests, uses existing post.ssz if available
  - For multi-block tests, generates intermediate post-states using eth2spec

For operations tests:
  - Generates (pre.json, operation.json, post.json) triples
  - Uses eth2spec operation processing functions (process_attestation, etc.)
  - Supports: attestation, deposit, proposer_slashing, attester_slashing,
    voluntary_exit, bls_to_execution_change, sync_aggregate, block_header,
    execution_payload, withdrawals

For epoch_processing tests:
  - Generates (pre.json, post.json) pairs
  - Uses eth2spec epoch processing functions (process_justification_and_finalization, etc.)
  - Supports: justification_and_finalization, inactivity_updates,
    rewards_and_penalties, registry_updates, slashings, eth1_data_reset,
    effective_balance_updates, slashings_reset, randao_mixes_reset,
    historical_summaries_update, participation_flag_updates
"""

import os
import sys
import subprocess
import argparse
import json
import shutil
from pathlib import Path
from typing import List, Tuple, Optional


class JsonTestCaseGenerator:
    def __init__(
        self,
        converter_dir: str,
        fork: str = "deneb",
    ):
        """
        Args:
            converter_dir: Converter directory path
            fork: deneb / capella (default: deneb)
        """
        self.converter_dir = Path(converter_dir).resolve()
        self.fork = fork
        
        # script paths
        self.snappy_decompressor = self.converter_dir / "snappyDecompressor.py"
        self.beacon_state_to_json = self.converter_dir / "SSZToJson" / "BeaconStateSSZToJson.py"
        self.signed_block_to_json = self.converter_dir / "SSZToJson" / "SignedBeaconBlockSSZToJson.py"
        self.eth2spec_result = self.converter_dir / "eth2specResult.py"
        self.eth2spec_operation_result = self.converter_dir / "eth2specOperationResult.py"
        self.eth2spec_epoch_processing_result = self.converter_dir / "eth2specEpochProcessingResult.py"
        
        # Operation type to SSZ→JSON converter script mapping
        self.operation_to_json_scripts = {
            'attestation': self.converter_dir / "SSZToJson" / "AttestationSSZToJson.py",
            'deposit': self.converter_dir / "SSZToJson" / "DepositSSZToJson.py",
            'proposer_slashing': self.converter_dir / "SSZToJson" / "ProposerSlashingSSZToJson.py",
            'attester_slashing': self.converter_dir / "SSZToJson" / "AttesterSlashingSSZToJson.py",
            'voluntary_exit': self.converter_dir / "SSZToJson" / "VoluntaryExitSSZToJson.py",
            'bls_to_execution_change': self.converter_dir / "SSZToJson" / "BLSToExecutionChangeSSZToJson.py",
            'sync_aggregate': self.converter_dir / "SSZToJson" / "SyncAggregateSSZToJson.py",
            'block_header': self.converter_dir / "SSZToJson" / "BeaconBlockHeaderSSZToJson.py", # Uses BeaconBlock
            'execution_payload': self.converter_dir / "SSZToJson" / "ExecutionPayloadSSZToJson.py",  # Uses BeaconBlockBody
            'withdrawals': self.converter_dir / "SSZToJson" / "WithdrawalSSZToJson.py",  # Uses ExecutionPayload
        }
        
        # consensus-specs path
        consensus_specs = self.converter_dir.parent / "consensus-specs"
        self.consensus_specs_path = consensus_specs / "tests" / "core" / "pyspec"
        
        # Epoch processing function name mapping (folder name -> function name)
        self.epoch_processing_functions = {
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
    
    def find_test_cases(self, test_suite_dir: str) -> List[Path]:
        """Find test case directories."""
        test_suite_path = Path(test_suite_dir).resolve()
        test_cases = []
        
        for pre_file in test_suite_path.rglob("pre.ssz_snappy"):
            test_cases.append(pre_file.parent)
        
        return sorted(test_cases)
    
    def decompress_snappy(self, input_file: Path, output_file: Path) -> bool:
        """Decompress snappy file."""
        try:
            result = subprocess.run(
                [sys.executable, str(self.snappy_decompressor), str(input_file), str(output_file)],
                capture_output=True,
                text=True,
                check=True
            )
            return True
        except subprocess.CalledProcessError as e:
            print(f"  ✗ Snappy decompression failed: {e.stderr}")
            return False
    
    def ssz_to_json(self, ssz_file: Path, json_file: Path, is_beacon_state: bool = True) -> bool:
        """Convert SSZ file to JSON."""
        try:
            if is_beacon_state:
                script = self.beacon_state_to_json
            else:
                script = self.signed_block_to_json
            
            type_module = f"eth2spec.{self.fork}.mainnet"
            
            result = subprocess.run(
                [sys.executable, str(script), 
                 "--type-module", type_module,
                 "--in", str(ssz_file), "--out", str(json_file)],
                capture_output=True,
                text=True,
                check=True
            )
            return True
        except subprocess.CalledProcessError as e:
            print(f"  ✗ SSZ to JSON conversion failed: {e.stderr}")
            return False
    
    def run_eth2spec(self, pre_ssz: Path, block_ssz: Path, output_ssz: Path) -> Tuple[bool, Optional[str]]:
        """Run eth2specResult.py."""
        try:
            env = os.environ.copy()
            if 'PYTHONPATH' in env:
                env['PYTHONPATH'] = str(self.consensus_specs_path) + os.pathsep + env['PYTHONPATH']
            else:
                env['PYTHONPATH'] = str(self.consensus_specs_path)
            
            result = subprocess.run(
                [sys.executable, str(self.eth2spec_result), 
                 "--pre", str(pre_ssz),
                 "--block", str(block_ssz),
                 "--out", str(output_ssz),
                 "--fork", self.fork],
                capture_output=True,
                text=True,
                check=True,
                env=env
            )
            return True, None
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else e.stdout
            return False, error_msg
    
    def run_eth2spec_operation(self, pre_ssz: Path, operation_ssz: Path, output_ssz: Path, operation_type: str) -> Tuple[bool, Optional[str]]:
        """Run eth2specOperationResult.py."""
        try:
            env = os.environ.copy()
            if 'PYTHONPATH' in env:
                env['PYTHONPATH'] = str(self.consensus_specs_path) + os.pathsep + env['PYTHONPATH']
            else:
                env['PYTHONPATH'] = str(self.consensus_specs_path)
            
            result = subprocess.run(
                [sys.executable, str(self.eth2spec_operation_result), 
                 "--pre", str(pre_ssz),
                 "--operation", str(operation_ssz),
                 "--out", str(output_ssz),
                 "--operation-type", operation_type,
                 "--fork", self.fork],
                capture_output=True,
                text=True,
                check=True,
                env=env
            )
            return True, None
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else e.stdout
            return False, error_msg
    
    def run_eth2spec_epoch_processing(self, pre_ssz: Path, output_ssz: Path, epoch_processing_type: str) -> Tuple[bool, Optional[str]]:
        """Run eth2specEpochProcessingResult.py."""
        try:
            env = os.environ.copy()
            if 'PYTHONPATH' in env:
                env['PYTHONPATH'] = str(self.consensus_specs_path) + os.pathsep + env['PYTHONPATH']
            else:
                env['PYTHONPATH'] = str(self.consensus_specs_path)
            
            result = subprocess.run(
                [sys.executable, str(self.eth2spec_epoch_processing_result), 
                 "--pre", str(pre_ssz),
                 "--out", str(output_ssz),
                 "--epoch-processing-type", epoch_processing_type,
                 "--fork", self.fork],
                capture_output=True,
                text=True,
                check=True,
                env=env
            )
            return True, None
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else e.stdout
            return False, error_msg
    
    def ssz_to_json_operation(self, ssz_file: Path, json_file: Path, operation_type: str) -> bool:
        """Convert operation SSZ file to JSON."""
        try:
            if operation_type not in self.operation_to_json_scripts:
                print(f"  ✗ Unknown operation type: {operation_type}")
                return False
            
            script = self.operation_to_json_scripts[operation_type]
            
            type_module = f"eth2spec.{self.fork}.mainnet"
            
            type_name_map = {
                'attestation': 'Attestation',
                'deposit': 'Deposit',
                'proposer_slashing': 'ProposerSlashing',
                'attester_slashing': 'AttesterSlashing',
                'voluntary_exit': 'SignedVoluntaryExit',
                'bls_to_execution_change': 'SignedBLSToExecutionChange',
                'sync_aggregate': 'SyncAggregate',
                'block_header': 'BeaconBlock', # block_header tests provide block.ssz_snappy (BeaconBlock)
                'execution_payload': 'BeaconBlockBody',  # execution_payload tests provide body.ssz_snappy (BeaconBlockBody)
                'withdrawals': 'ExecutionPayload',  # withdrawals tests provide execution_payload.ssz_snappy (ExecutionPayload)
            }
            type_name = type_name_map.get(operation_type, operation_type.capitalize())
            
            result = subprocess.run(
                [sys.executable, str(script), 
                 "--type-module", type_module,
                 "--type", type_name,
                 "--in", str(ssz_file), "--out", str(json_file)],
                capture_output=True,
                text=True,
                check=True
            )
            return True
        except subprocess.CalledProcessError as e:
            print(f"  ✗ SSZ to JSON conversion failed: {e.stderr}")
            return False
    
    def detect_test_type(self, test_case_dir: Path) -> str:
        """Detect test case type (block, operation, and epoch_processing)."""
        block_files = list(test_case_dir.glob("blocks_*.ssz_snappy"))
        if block_files:
            return "block"
        
        operation_file_names = {
            'execution_payload': 'body.ssz_snappy',
            'withdrawals': 'execution_payload.ssz_snappy',
            'block_header': 'block.ssz_snappy',  # block_header tests use block.ssz_snappy
            'bls_to_execution_change': 'address_change.ssz_snappy',  # bls_to_execution_change tests use address_change.ssz_snappy
        }
        
        operation_types = list(self.operation_to_json_scripts.keys())
        for op_type in operation_types:
            # Check for special file names first
            if op_type in operation_file_names:
                op_file = test_case_dir / operation_file_names[op_type]
                if op_file.exists():
                    return "operation"
            
            # Standard file name
            op_file = test_case_dir / f"{op_type}.ssz_snappy"
            if op_file.exists():
                return "operation"
        
        # Epoch processing test detection: pre.ssz_snappy exists, no operation/block files,
        # and parent's parent folder name is in epoch_processing function list
        pre_file = test_case_dir / "pre.ssz_snappy"
        if pre_file.exists():
            # Check parent's parent folder name (e.g., epoch_processing/justification_and_finalization/pyspec_tests/...)
            # test_case_dir.parent = pyspec_tests
            # test_case_dir.parent.parent = justification_and_finalization
            parent_name = test_case_dir.parent.parent.name
            if parent_name in self.epoch_processing_functions:
                return "epoch_processing"
        
        return "unknown"
    
    def find_operation_files(self, test_case_dir: Path) -> List[Tuple[str, Path]]:
        """Find operation files."""
        operation_files = []
        operation_types = list(self.operation_to_json_scripts.keys())
        
        # Special file name mappings for certain operation types
        operation_file_names = {
            'execution_payload': 'body.ssz_snappy',  # execution_payload tests use body.ssz_snappy
            'withdrawals': 'execution_payload.ssz_snappy',  # withdrawals tests use execution_payload.ssz_snappy
            'block_header': 'block.ssz_snappy',  # block_header tests use block.ssz_snappy
            'bls_to_execution_change': 'address_change.ssz_snappy',  # bls_to_execution_change tests use address_change.ssz_snappy
        }
        
        # Track which files have been matched by special file names
        matched_files = set()
        # Track which file names are special file names for other operations (to avoid conflicts)
        # Map: filename -> operation_type that uses it as special file name
        special_file_name_to_op = {name: op_type for op_type, name in operation_file_names.items()}
        
        for op_type in operation_types:
            # Check for special file names first
            if op_type in operation_file_names:
                op_file = test_case_dir / operation_file_names[op_type]
                if op_file.exists():
                    operation_files.append((op_type, op_file))
                    matched_files.add(op_file)
                    continue
            
            # Standard file name: {op_type}.ssz_snappy
            op_file = test_case_dir / f"{op_type}.ssz_snappy"
            if op_file.exists():
                # Skip if this file was already matched by a special file name
                if op_file in matched_files:
                    continue
                # Skip if this standard file name is a special file name for another operation type
                file_name = op_file.name
                if file_name in special_file_name_to_op and special_file_name_to_op[file_name] != op_type:
                    continue
                operation_files.append((op_type, op_file))
        
        # Sort by numeric order (e.g., attestation_0.ssz_snappy, attestation_1.ssz_snappy)
        if len(operation_files) == 0:
            # If not a single file, find files with numeric suffix
            for op_type in operation_types:
                # Skip special cases
                if op_type in operation_file_names:
                    continue
                    
                pattern_files = sorted(
                    test_case_dir.glob(f"{op_type}_*.ssz_snappy"),
                    key=lambda p: int(p.stem.replace(f"{op_type}_", "")) if p.stem.replace(f"{op_type}_", "").isdigit() else 0
                )
                for op_file in pattern_files:
                    operation_files.append((op_type, op_file))
        
        return sorted(operation_files, key=lambda x: (x[0], x[1].name))
    
    def process_test_case(
        self, 
        test_case_dir: Path, 
        output_dir: Path, 
        test_name: str,
        verbose: bool = False
    ) -> Tuple[int, int]:
        """
        Generates JSON test cases from a single test case.
        
        Returns:
            (generated_count, error_count)
        """
        if verbose:
            print(f"\n{'='*60}")
            print(f"Processing: {test_name}")
            print(f"Directory: {test_case_dir}")
            print(f"{'='*60}")
        
        test_type = self.detect_test_type(test_case_dir)
        
        if test_type == "block":
            return self.process_block_test_case(test_case_dir, output_dir, test_name, verbose)
        elif test_type == "operation":
            return self.process_operation_test_case(test_case_dir, output_dir, test_name, verbose)
        elif test_type == "epoch_processing":
            return self.process_epoch_processing_test_case(test_case_dir, output_dir, test_name, verbose)
        else:
            print(f"  ✗ Unknown test type (no blocks_*.ssz_snappy, operation files, or epoch_processing files found)")
            return 0, 1
    
    def process_block_test_case(
        self, 
        test_case_dir: Path, 
        output_dir: Path, 
        test_name: str,
        verbose: bool = False
    ) -> Tuple[int, int]:
        """
        Process block test case.
        
        Returns:
            (generated_count, error_count)
        """
        generated = 0
        errors = 0
        
        # 1. locate files
        pre_snappy = test_case_dir / "pre.ssz_snappy"
        if not pre_snappy.exists():
            print(f"  ✗ pre.ssz_snappy not found")
            return 0, 1
        
        block_snappy_files = sorted(
            test_case_dir.glob("blocks_*.ssz_snappy"),
            key=lambda p: int(p.stem.replace("blocks_", ""))
        )
        if not block_snappy_files:
            print(f"  ✗ No blocks_*.ssz_snappy files found")
            return 0, 1
        
        # check for existing post.ssz_snappy
        post_snappy = test_case_dir / "post.ssz_snappy"
        has_existing_post = post_snappy.exists()
        
        # create temporary work directory
        work_dir = output_dir / f".work_{test_name}"
        work_dir.mkdir(parents=True, exist_ok=True)
        
        try:
            # 2. Decompress snappy files
            if verbose:
                print("  Decompressing snappy files...")
            
            pre_ssz = work_dir / "pre.ssz"
            if not self.decompress_snappy(pre_snappy, pre_ssz):
                return 0, 1
            
            block_ssz_files = []
            for block_snappy in block_snappy_files:
                block_num = int(block_snappy.stem.replace("blocks_", ""))
                block_ssz = work_dir / f"blocks_{block_num}.ssz"
                if not self.decompress_snappy(block_snappy, block_ssz):
                    errors += 1
                    continue
                block_ssz_files.append((block_num, block_ssz))
            
            if not block_ssz_files:
                print(f"  ✗ Failed to decompress any block files")
                return 0, errors
            
            # Decompress existing post.ssz if available
            post_ssz = None
            if has_existing_post:
                post_ssz = work_dir / "post.ssz"
                if not self.decompress_snappy(post_snappy, post_ssz):
                    post_ssz = None
            
            # 3. SSZ -> JSON conversion and test case generation
            if verbose:
                print("  Converting to JSON and generating test cases...")
            
            # initial pre state
            initial_pre_ssz = pre_ssz
            initial_pre_json = work_dir / "pre.json"
            if not self.ssz_to_json(pre_ssz, initial_pre_json, is_beacon_state=True):
                return 0, 1
            
            # current pre state (for multi-block tests)
            current_pre_ssz = initial_pre_ssz
            current_pre_json = initial_pre_json
            
            is_single_block = len(block_ssz_files) == 1
            
            for i, (block_num, block_ssz) in enumerate(block_ssz_files):
                # convert block to JSON
                block_json = work_dir / f"blocks_{block_num}.json"
                if not self.ssz_to_json(block_ssz, block_json, is_beacon_state=False):
                    errors += 1
                    continue
                
                # post state generation
                post_json = None
                eth2spec_error = None
                
                if is_single_block and post_ssz:
                    # use existing post.ssz for single-block tests
                    post_json = work_dir / "post.json"
                    if not self.ssz_to_json(post_ssz, post_json, is_beacon_state=True):
                        errors += 1
                        continue
                else:
                    # otherwise, generate post state using eth2spec
                    generated_post_ssz = work_dir / f"post_{block_num}.ssz"
                    success, error = self.run_eth2spec(current_pre_ssz, block_ssz, generated_post_ssz)
                    
                    if success:
                        post_json = work_dir / f"post_{block_num}.json"
                        if not self.ssz_to_json(generated_post_ssz, post_json, is_beacon_state=True):
                            errors += 1
                            continue
                    else:
                        # eth2spec failed - this is a negative test
                        eth2spec_error = error
                
                # copy JSON files to output directory
                is_negative = eth2spec_error is not None
                test_type_dir = output_dir / ("negative" if is_negative else "positive")
                
                if is_single_block:
                    case_output_dir = test_type_dir / test_name
                else:
                    case_output_dir = test_type_dir / f"{test_name}_{block_num}"
                case_output_dir.mkdir(parents=True, exist_ok=True)
                
                # Copy files to output directory
                shutil.copy(current_pre_json, case_output_dir / "pre.json")
                shutil.copy(block_json, case_output_dir / "block.json")
                
                if is_negative:
                    # Write error.txt for negative tests
                    with open(case_output_dir / "error.txt", "w") as f:
                        f.write(eth2spec_error or "Unknown error")
                    if verbose:
                        print(f"  ✓ Generated (negative): {case_output_dir.name}")
                    # Stop processing further blocks for this test case
                    generated += 1
                    break
                else:
                    # Copy post.json for positive tests
                    shutil.copy(post_json, case_output_dir / "post.json")
                    if verbose:
                        print(f"  ✓ Generated (positive): {case_output_dir.name}")
                    
                    # Update pre state for next block (multi-block only)
                    if not is_single_block:
                        current_pre_ssz = work_dir / f"post_{block_num}.ssz"
                        current_pre_json = post_json
                    
                    generated += 1
        
        finally:
            # cleanup temporary work directory
            if work_dir.exists():
                shutil.rmtree(work_dir)
        
        return generated, errors
    
    def process_operation_test_case(
        self, 
        test_case_dir: Path, 
        output_dir: Path, 
        test_name: str,
        verbose: bool = False
    ) -> Tuple[int, int]:
        """
        Process operation test case.
        
        Returns:
            (generated_count, error_count)
        """
        generated = 0
        errors = 0
        
        # 1. locate files
        pre_snappy = test_case_dir / "pre.ssz_snappy"
        if not pre_snappy.exists():
            print(f"  ✗ pre.ssz_snappy not found")
            return 0, 1
        
        operation_files = self.find_operation_files(test_case_dir)
        if not operation_files:
            print(f"  ✗ No operation files found")
            return 0, 1
        
        # check for existing post.ssz_snappy
        post_snappy = test_case_dir / "post.ssz_snappy"
        has_existing_post = post_snappy.exists()
        
        # create temporary work directory
        work_dir = output_dir / f".work_{test_name}"
        work_dir.mkdir(parents=True, exist_ok=True)
        
        try:
            # 2. Decompress snappy files
            if verbose:
                print("  Decompressing snappy files...")
            
            pre_ssz = work_dir / "pre.ssz"
            if not self.decompress_snappy(pre_snappy, pre_ssz):
                return 0, 1
            
            operation_ssz_files = []
            for op_type, op_snappy in operation_files:
                op_ssz = work_dir / f"{op_type}.ssz"
                if not self.decompress_snappy(op_snappy, op_ssz):
                    errors += 1
                    continue
                operation_ssz_files.append((op_type, op_ssz))
            
            if not operation_ssz_files:
                print(f"  ✗ Failed to decompress any operation files")
                return 0, errors
            
            # Decompress existing post.ssz if available
            post_ssz = None
            if has_existing_post:
                post_ssz = work_dir / "post.ssz"
                if not self.decompress_snappy(post_snappy, post_ssz):
                    post_ssz = None
            
            # 3. SSZ -> JSON conversion and test case generation
            if verbose:
                print("  Converting to JSON and generating test cases...")
            
            # initial pre state
            initial_pre_ssz = pre_ssz
            initial_pre_json = work_dir / "pre.json"
            if not self.ssz_to_json(pre_ssz, initial_pre_json, is_beacon_state=True):
                return 0, 1
            
            # current pre state (for multi-operation tests)
            current_pre_ssz = initial_pre_ssz
            current_pre_json = initial_pre_json
            
            is_single_operation = len(operation_ssz_files) == 1
            
            for i, (op_type, op_ssz) in enumerate(operation_ssz_files):
                # convert operation to JSON
                op_json = work_dir / f"{op_type}.json"
                if not self.ssz_to_json_operation(op_ssz, op_json, op_type):
                    errors += 1
                    continue
                
                # post state generation
                post_json = None
                eth2spec_error = None
                
                if is_single_operation and post_ssz:
                    # use existing post.ssz for single-operation tests
                    post_json = work_dir / "post.json"
                    if not self.ssz_to_json(post_ssz, post_json, is_beacon_state=True):
                        errors += 1
                        continue
                else:
                    # otherwise, generate post state using eth2spec operation
                    # For execution_payload tests, copy execution.yaml file to work_dir
                    if op_type == 'execution_payload':
                        execution_yaml = test_case_dir / "execution.yaml"
                        if execution_yaml.exists():
                            shutil.copy(execution_yaml, work_dir / "execution.yaml")
                    
                    generated_post_ssz = work_dir / f"post_{i}.ssz"
                    success, error = self.run_eth2spec_operation(current_pre_ssz, op_ssz, generated_post_ssz, op_type)
                    
                    if success:
                        post_json = work_dir / f"post_{i}.json"
                        if not self.ssz_to_json(generated_post_ssz, post_json, is_beacon_state=True):
                            errors += 1
                            continue
                    else:
                        # eth2spec failed - this is a negative test
                        eth2spec_error = error
                
                # copy JSON files to output directory
                is_negative = eth2spec_error is not None
                test_type_dir = output_dir / ("negative" if is_negative else "positive")
                
                if is_single_operation:
                    case_output_dir = test_type_dir / test_name
                else:
                    case_output_dir = test_type_dir / f"{test_name}_{i}"
                case_output_dir.mkdir(parents=True, exist_ok=True)
                
                # Copy files to output directory
                shutil.copy(current_pre_json, case_output_dir / "pre.json")
                shutil.copy(op_json, case_output_dir / f"{op_type}.json")
                
                if is_negative:
                    # Write error.txt for negative tests
                    with open(case_output_dir / "error.txt", "w") as f:
                        f.write(eth2spec_error or "Unknown error")
                    if verbose:
                        print(f"  ✓ Generated (negative): {case_output_dir.name}")
                    # Stop processing further operations for this test case
                    generated += 1
                    break
                else:
                    # Copy post.json for positive tests
                    shutil.copy(post_json, case_output_dir / "post.json")
                    if verbose:
                        print(f"  ✓ Generated (positive): {case_output_dir.name}")
                    
                    # Update pre state for next operation (multi-operation only)
                    if not is_single_operation:
                        current_pre_ssz = work_dir / f"post_{i}.ssz"
                        current_pre_json = post_json
                    
                    generated += 1
        
        finally:
            # cleanup temporary work directory
            if work_dir.exists():
                shutil.rmtree(work_dir)
        
        return generated, errors
    
    def process_epoch_processing_test_case(
        self, 
        test_case_dir: Path, 
        output_dir: Path, 
        test_name: str,
        verbose: bool = False
    ) -> Tuple[int, int]:
        """
        Process epoch processing test case.
        
        Returns:
            (generated_count, error_count)
        """
        generated = 0
        errors = 0
        
        # 1. locate files
        pre_snappy = test_case_dir / "pre.ssz_snappy"
        if not pre_snappy.exists():
            print(f"  ✗ pre.ssz_snappy not found")
            return 0, 1
        
        post_snappy = test_case_dir / "post.ssz_snappy"
        has_existing_post = post_snappy.exists()
        
        # Extract epoch_processing type from parent's parent folder name
        # test_case_dir.parent = pyspec_tests
        # test_case_dir.parent.parent = justification_and_finalization
        epoch_processing_type = test_case_dir.parent.parent.name
        if epoch_processing_type not in self.epoch_processing_functions:
            print(f"  ✗ Unknown epoch processing type: {epoch_processing_type}")
            return 0, 1
        
        # create temporary work directory
        work_dir = output_dir / f".work_{test_name}"
        work_dir.mkdir(parents=True, exist_ok=True)
        
        try:
            # 2. Decompress snappy files
            if verbose:
                print("  Decompressing snappy files...")
            
            pre_ssz = work_dir / "pre.ssz"
            if not self.decompress_snappy(pre_snappy, pre_ssz):
                return 0, 1
            
            # Decompress existing post.ssz if available
            post_ssz = None
            if has_existing_post:
                post_ssz = work_dir / "post.ssz"
                if not self.decompress_snappy(post_snappy, post_ssz):
                    post_ssz = None
            
            # 3. SSZ -> JSON conversion and test case generation
            if verbose:
                print("  Converting to JSON and generating test cases...")
            
            # pre state
            pre_json = work_dir / "pre.json"
            if not self.ssz_to_json(pre_ssz, pre_json, is_beacon_state=True):
                return 0, 1
            
            # post state generation
            post_json = None
            eth2spec_error = None
            
            if post_ssz:
                # use existing post.ssz
                post_json = work_dir / "post.json"
                if not self.ssz_to_json(post_ssz, post_json, is_beacon_state=True):
                    errors += 1
            else:
                # otherwise, generate post state using eth2spec epoch processing
                generated_post_ssz = work_dir / "post.ssz"
                success, error = self.run_eth2spec_epoch_processing(pre_ssz, generated_post_ssz, epoch_processing_type)
                
                if success:
                    post_json = work_dir / "post.json"
                    if not self.ssz_to_json(generated_post_ssz, post_json, is_beacon_state=True):
                        errors += 1
                else:
                    # eth2spec failed - this is a negative test
                    eth2spec_error = error
            
            # copy JSON files to output directory
            is_negative = eth2spec_error is not None
            test_type_dir = output_dir / ("negative" if is_negative else "positive")
            
            case_output_dir = test_type_dir / test_name
            case_output_dir.mkdir(parents=True, exist_ok=True)
            
            # Copy files to output directory
            shutil.copy(pre_json, case_output_dir / "pre.json")
            
            if is_negative:
                # Write error.txt for negative tests
                with open(case_output_dir / "error.txt", "w") as f:
                    f.write(eth2spec_error or "Unknown error")
                if verbose:
                    print(f"  ✓ Generated (negative): {case_output_dir.name}")
            else:
                # Copy post.json for positive tests
                if post_json:
                    shutil.copy(post_json, case_output_dir / "post.json")
                if verbose:
                    print(f"  ✓ Generated (positive): {case_output_dir.name}")
            
            generated += 1
        
        finally:
            # cleanup temporary work directory
            if work_dir.exists():
                shutil.rmtree(work_dir)
        
        return generated, errors
    
    def generate(
        self, 
        test_suite_dir: str, 
        output_dir: str,
        test_filter: str = None,
        verbose: bool = False
    ) -> dict:
        """
        Generate JSON test cases from test suite.
        
        Args:
            test_suite_dir: Test suite directory
            output_dir: Output directory
            test_filter: Test case name filter (optional)
            verbose: Verbose output flag
        
        Returns:
            Result dictionary
        """
        test_suite_path = Path(test_suite_dir).resolve()
        output_path = Path(output_dir).resolve()
        output_path.mkdir(parents=True, exist_ok=True)
        
        # locate test case directories
        test_case_dirs = self.find_test_cases(test_suite_dir)
        
        if test_filter:
            test_case_dirs = [tc for tc in test_case_dirs if test_filter in tc.name]
        
        if not test_case_dirs:
            print(f"No test cases found in {test_suite_dir}")
            return {"total_dirs": 0, "generated": 0, "errors": 0}
        
        print(f"Found {len(test_case_dirs)} test case directory(ies)")
        
        total_generated = 0
        total_errors = 0
        
        for test_case_dir in test_case_dirs:
            # create unique test name based on relative path
            try:
                relative_path = test_case_dir.relative_to(test_suite_path)
                test_name = str(relative_path).replace(os.sep, "_").replace("/", "_")
            except ValueError:
                test_name = test_case_dir.name
            
            generated, errors = self.process_test_case(
                test_case_dir, output_path, test_name, verbose=verbose
            )
            total_generated += generated
            total_errors += errors
            
            if not verbose:
                status = "✓" if errors == 0 else "✗"
                print(f"{status} {test_name}: {generated} generated, {errors} errors")
        
        # print summary
        print(f"\n{'='*60}")
        print("SUMMARY")
        print(f"{'='*60}")
        print(f"Test case directories: {len(test_case_dirs)}")
        print(f"Generated test cases: {total_generated}")
        print(f"Errors: {total_errors}")
        print(f"Output directory: {output_path}")
        
        return {
            "total_dirs": len(test_case_dirs),
            "generated": total_generated,
            "errors": total_errors
        }


def main():
    parser = argparse.ArgumentParser(
        description="Generate JSON input/output test case pairs from the official Ethereum test suite"
    )
    parser.add_argument(
        "test_suite",
        help="Test suite directory (e.g., Converter/OfficialTestSuite/deneb/sanity)"
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Output directory for generated JSON test cases"
    )
    parser.add_argument(
        "--converter-dir",
        default=None,
        help="Path to Converter directory (default: auto-detect from script location)"
    )
    parser.add_argument(
        "--fork",
        default="deneb",
        choices=["deneb", "capella"],
        help="Fork name to use (default: deneb)"
    )
    parser.add_argument(
        "--filter",
        default=None,
        help="Filter test cases by name"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Verbose output"
    )
    
    args = parser.parse_args()
    
    # Auto-detect converter directory
    if args.converter_dir:
        converter_dir = Path(args.converter_dir).resolve()
    else:
        script_dir = Path(__file__).parent.resolve()
        converter_dir = script_dir
    
    # Create and run the generator
    generator = JsonTestCaseGenerator(
        converter_dir=str(converter_dir),
        fork=args.fork,
    )
    
    results = generator.generate(
        test_suite_dir=args.test_suite,
        output_dir=args.output_dir,
        test_filter=args.filter,
        verbose=args.verbose
    )
    
    # exit 1 if there were errors
    sys.exit(1 if results["errors"] > 0 else 0)


if __name__ == "__main__":
    main()
