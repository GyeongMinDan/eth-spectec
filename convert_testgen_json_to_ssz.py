#!/usr/bin/env python3
"""
Convert JSON test cases from testgen directory to SSZ format for diff_testing.py

Input structure:
    <input-dir>/
        eth-tests-*/mut_*/pre.json
        <input-dir>/eth-tests-*/mut_*/block.json

Output structure:
    testgen/
        spectec-generated/
            mut_*/pre.ssz
            mut_*/blocks_0.ssz
"""

import os
import sys
import subprocess
import argparse
from pathlib import Path

# Add Converter to path
script_dir = Path(__file__).parent.resolve()
converter_dir = script_dir / "Converter"
json_to_ssz_dir = converter_dir / "JsonToSSZ"

# Import conversion scripts
sys.path.insert(0, str(json_to_ssz_dir))
sys.path.insert(0, str(converter_dir))

def convert_json_to_ssz(json_path, ssz_path, conversion_script, type_module="eth2spec.capella.mainnet", type_name=None):
    """
    Convert JSON file to SSZ using the specified conversion script.
    
    Args:
        json_path: Path to input JSON file
        ssz_path: Path to output SSZ file
        conversion_script: Path to conversion script (BeaconStateJsonToSSZ.py or SignedBeaconBlockJsonToSSZ.py)
        type_module: Python module path (default: eth2spec.capella.mainnet)
        type_name: Type name (default: None, uses script default)
    """
    if not os.path.exists(json_path):
        print(f"[!] JSON file not found: {json_path}")
        return False
    
    # Ensure output directory exists
    os.makedirs(os.path.dirname(ssz_path), exist_ok=True)
    
    # Build command
    cmd = [
        sys.executable,
        str(conversion_script),
        "--in", str(json_path),
        "--out", str(ssz_path),
        "--type-module", type_module
    ]
    
    if type_name:
        cmd.extend(["--type", type_name])
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True
        )
        print(f"[+] Converted: {json_path} -> {ssz_path}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"[!] Failed to convert {json_path}:")
        print(f"    stdout: {e.stdout}")
        print(f"    stderr: {e.stderr}")
        return False

def process_testgen_directory(input_testgen_dir, output_base_dir, dry_run=False):
    """
    Process all test cases in testgen directory.
    
    Args:
        input_testgen_dir: Direct path to testgen directory (e.g., testgen_01270309)
        output_base_dir: Base directory for output (will create testgen/ subdirectory)
        dry_run: If True, only print what would be done without actually converting
    """
    testgen_dir = Path(input_testgen_dir)
    output_base = Path(output_base_dir)
    
    # Paths to conversion scripts
    state_converter = json_to_ssz_dir / "BeaconStateJsonToSSZ.py"
    block_converter = json_to_ssz_dir / "SignedBeaconBlockJsonToSSZ.py"
    
    if not state_converter.exists():
        print(f"[!] State converter not found: {state_converter}")
        return
    
    if not block_converter.exists():
        print(f"[!] Block converter not found: {block_converter}")
        return
    
    # Check if testgen directory exists
    if not testgen_dir.exists():
        print(f"[!] Input directory not found: {testgen_dir}")
        return
    
    print(f"[+] Processing test cases from: {testgen_dir}")
    
    # Create output directory structure
    output_testgen = output_base / "testgen" / "spectec-generated"
    
    if not dry_run:
        output_testgen.mkdir(parents=True, exist_ok=True)
        print(f"[+] Output directory: {output_testgen}")
    
    # Find all test case directories
    test_case_dirs = []
    for item in testgen_dir.iterdir():
        if item.is_dir() and not item.name.startswith('.'):
            # Look for mut_* subdirectories
            for mut_dir in item.iterdir():
                if mut_dir.is_dir() and mut_dir.name.startswith('mut_'):
                    test_case_dirs.append((item, mut_dir))
    
    print(f"[+] Found {len(test_case_dirs)} test case directories")
    
    success_count = 0
    fail_count = 0
    
    # Process each test case
    for test_group_dir, mut_dir in test_case_dirs:
        mut_name = mut_dir.name
        test_group_name = test_group_dir.name  # e.g., "eth-tests-random_random_randomized_14_1_pre.json"
        pre_json = mut_dir / "pre.json"
        block_json = mut_dir / "block.json"
        
        # Create output directory for this test case
        # Include test group name to avoid conflicts when same mut_* name exists in multiple groups
        # Format: test_group_name/mut_name (e.g., "eth-tests-random_random_randomized_14_1_pre.json/mut_prem115_0_0")
        output_group_dir = output_testgen / test_group_name
        output_mut_dir = output_group_dir / mut_name
        
        if not pre_json.exists():
            print(f"[!] Missing pre.json in {mut_dir}")
            fail_count += 1
            continue
        
        if not block_json.exists():
            print(f"[!] Missing block.json in {mut_dir}")
            fail_count += 1
            continue
        
        # Output paths
        pre_ssz = output_mut_dir / "pre.ssz"
        block_ssz = output_mut_dir / "blocks_0.ssz"  # diff_testing.py expects blocks_0.ssz format
        
        if dry_run:
            print(f"[DRY RUN] Would convert:")
            print(f"  {pre_json} -> {pre_ssz}")
            print(f"  {block_json} -> {block_ssz}")
            print(f"  (from {test_group_name})")
            continue
        
        # Convert pre.json to pre.ssz
        if convert_json_to_ssz(
            pre_json,
            pre_ssz,
            state_converter,
            type_module="eth2spec.capella.mainnet",
            type_name="BeaconState"
        ):
            # Convert block.json to blocks_0.ssz
            if convert_json_to_ssz(
                block_json,
                block_ssz,
                block_converter,
                type_module="eth2spec.capella.mainnet",
                type_name="SignedBeaconBlock"
            ):
                success_count += 1
                print(f"[+] Successfully converted test case: {test_group_name}/{mut_name}")
            else:
                fail_count += 1
                # Remove partial output
                if pre_ssz.exists():
                    os.remove(pre_ssz)
        else:
            fail_count += 1
    
    print(f"\n[+] Conversion complete:")
    print(f"    Success: {success_count}")
    print(f"    Failed: {fail_count}")
    print(f"    Output directory: {output_testgen}")

def main():
    parser = argparse.ArgumentParser(
        description="Convert JSON test cases from testgen directory to SSZ format"
    )
    parser.add_argument(
        "--input-dir",
        type=str,
        required=True,
        help="Direct path to testgen directory (e.g., /path/to/testgen_01270309)"
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=str(script_dir),
        help="Base directory for output (default: spectec-core directory, creates testgen/ subdirectory)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be done without actually converting"
    )
    
    args = parser.parse_args()
    
    process_testgen_directory(args.input_dir, args.output_dir, dry_run=args.dry_run)

if __name__ == "__main__":
    main()
