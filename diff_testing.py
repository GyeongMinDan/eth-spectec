# Note : This script diffs the behavior and coverage of eth2 clients.

import os
import sys
import io
import subprocess
import argparse
import csv
import re
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from time import perf_counter
from pathlib import Path
from datetime import datetime
from collections import defaultdict

MERGE_CHUNK_SIZE = 500

STATUS_LABEL = {
    0: "SUCCESS",
    1: "FAIL",
    2: "UNHANDLED_EXCEPTION"
}

CLIENT_DISPLAY_ORDER = [
    "Lighthouse",
    "Prysm",
    "Nimbus",
    "Teku",
    "Lodestar",
    "Eth2spec",
]

BASE_CLIENT_TOOLS = ["lighthouse", "prysm", "nimbus", "teku", "lodestar"]
STATE_TRANSITION_TOOLS = BASE_CLIENT_TOOLS + ["eth2spec"]


def _client_csv_fieldnames(rows):
    present = set()
    for row in rows:
        present.update(row.keys())
    ordered_clients = [name for name in CLIENT_DISPLAY_ORDER if name in present]
    return ["Pair #"] + ordered_clients

# Lighthouse coverage report scope (noise reduction)
# We intentionally apply filtering ONLY at report generation time (llvm-cov),
# after merging raw coverage data (llvm-profdata). This matches the Nimbus
# approach: merge first to preserve full information, then filter for a
# consistent, well-defined scope.
#
# Scope A: keep only core state-transition related crates.
# 
# INCLUDED (kept in report):
#   - consensus/     : Core consensus state-transition logic
#   - crypto/         : Cryptographic primitives (BLS signatures, etc.)
#   - lcli/           : Lighthouse CLI tool (entry point for state-transition)
#
# EXCLUDED (filtered out from report):
#   - beacon_node/    : Beacon node operational logic (not core state-transition)
#   - common/         : Infrastructure code (logging, metrics, config)
#   - lighthouse/     : Environment setup code
#   - target/         : Build artifacts
#   - .cargo, rustc/  : Rust toolchain sources
#
LIGHTHOUSE_CORE_IGNORE_PATTERNS = [
    ".*(/|^)lighthouse/beacon_node/.*",            # Beacon node operational logic
    ".*(/|^)lighthouse/common/.*",                 # Top-level common/ infrastructure only
    ".*(/|^)lighthouse/lighthouse/environment/.*", # Environment setup code
    ".*(/|^)lighthouse/lighthouse/(?!consensus/|crypto/|lcli/).*",  # lighthouse/ but NOT lighthouse/consensus/, lighthouse/crypto/, lighthouse/lcli/
    ".*(/|^)lighthouse/target/.*",                 # Build artifacts
    ".*(/|^)\\.cargo/.*",                          # Rust toolchain sources (.cargo directory)
    ".*(/|^)rustc/.*",                             # Rust toolchain sources
    ".*(/|^)root/.*",                              # Root directory (often contains .cargo registry)
]

# Teku coverage report scope (noise reduction)
# We intentionally apply filtering ONLY at report generation time (after XML generation),
# after merging raw coverage data (.exec files). This matches the Nimbus/Lighthouse
# approach: merge first to preserve full information, then filter for a consistent,
# well-defined scope.
#
# INCLUDED (kept in report):
#   - tech/pegasys/teku/spec/**           : Core consensus state-transition logic
#   - tech/pegasys/teku/infrastructure/ssz/** : SSZ encoding/decoding (required for state-transition)
#   - tech/pegasys/teku/bls/**            : BLS signature verification (required for state-transition)
#
# EXCLUDED (filtered out from report):
#   - tech/pegasys/teku/beaconrestapi/** : REST API handlers
#   - tech/pegasys/teku/api/**            : API layer
#   - tech/pegasys/teku/networking/**    : Networking layer
#   - tech/pegasys/teku/services/**       : Node services
#   - tech/pegasys/teku/validator/**     : Validator client
#   - tech/pegasys/teku/storage/**       : Storage layer
#   - tech/pegasys/teku/ethereum/executionclient/** : Execution client integration
#   - tech/pegasys/teku/ethereum/executionlayer/**  : Execution layer
#   - tech/pegasys/teku/infrastructure/json/**      : JSON infrastructure
#   - tech/pegasys/teku/infrastructure/logging/**  : Logging infrastructure
#   - tech/pegasys/teku/infrastructure/metrics/**   : Metrics infrastructure
#   - tech/pegasys/teku/infrastructure/http/**      : HTTP infrastructure
#   - tech/pegasys/teku/infrastructure/restapi/**  : REST API infrastructure
#   - tech/pegasys/teku/infrastructure/async/**     : Async infrastructure
#
# Filtering is done by parsing JaCoCo XML report and keeping only packages that start
# with one of the included prefixes, then regenerating HTML report from filtered XML.
TEKU_CORE_INCLUDE_PREFIXES = (
    "tech/pegasys/teku/spec",
    "tech/pegasys/teku/infrastructure/ssz",
    "tech/pegasys/teku/bls",
    "tech/pegasys/teku/cli",
)

# Nimbus coverage report scope (noise reduction)
# We intentionally apply filtering ONLY at report generation time (after lcov capture),
# after merging raw coverage data (.gcda files). This matches the Lighthouse/TeKu
# approach: merge first to preserve full information, then filter for a consistent,
# well-defined scope.
#
# INCLUDED (kept in report):
#   - beacon_chain/**                    : Core consensus state-transition logic
#   - ncli/**                            : Nimbus CLI tool (entry point for state-transition)
#   - vendor/nim-blscurve/**             : BLS signature verification (required for state-transition)
#   - vendor/nim-ssz-serialization/**    : SSZ encoding/decoding (required for state-transition)
#
# EXCLUDED (filtered out from report):
#   - vendor/** (except nim-blscurve, nim-ssz-serialization) : Other third-party libraries
#   - nimcache/**      : Build cache artifacts
#   - research/**      : Research code
#   - generated_not_to_break_here : Generated files
#   - usr/**           : System headers
#   - System paths     : /usr/, /nimbus-eth2/, etc.
#
# Filtering is done by parsing lcov coverage.info file and keeping only files
# that start with one of the included prefixes, then regenerating the info file.
NIMBUS_CORE_INCLUDE_PREFIXES = (
    "beacon_chain/",
    "ncli/",
    "vendor/nim-blscurve/",
    "vendor/nim-ssz-serialization/",
)

# Prysm coverage report scope (noise reduction)
# We intentionally apply filtering ONLY at report generation time (after coverage.txt generation),
# after merging raw coverage data (covcounters.* files). This matches the Lighthouse/TeKu/Nimbus
# approach: merge first to preserve full information, then filter for a consistent,
# well-defined scope.
#
# INCLUDED (kept in report):
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/core/**  : Core consensus state-transition logic
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/state/** : State management
#   - github.com/OffchainLabs/prysm/v7/consensus-types/**    : Consensus type definitions
#   - github.com/OffchainLabs/prysm/v7/encoding/ssz/**      : SSZ encoding/decoding
#   - github.com/OffchainLabs/prysm/v7/crypto/bls/**        : BLS signature verification
#   - github.com/OffchainLabs/prysm/v7/config/params         : Configuration parameters (features excluded)
#   - github.com/OffchainLabs/prysm/v7/tools/pcli           : Prysm CLI tool (entry point for state-transition)
#
# EXCLUDED (filtered out from report):
#   - github.com/OffchainLabs/prysm/v7/proto/**             : Protocol buffer generated code
#   - github.com/OffchainLabs/prysm/v7/testing/**           : Testing utilities
#   - github.com/OffchainLabs/prysm/v7/runtime/**           : Runtime infrastructure
#   - github.com/OffchainLabs/prysm/v7/monitoring/**        : Monitoring
#   - github.com/OffchainLabs/prysm/v7/cmd/**                : Other command-line tools (pcli excluded)
#   - github.com/OffchainLabs/prysm/v7/io/**                 : File I/O infrastructure
#   - github.com/OffchainLabs/prysm/v7/time/**               : Time utilities
#   - github.com/OffchainLabs/prysm/v7/container/**          : Container data structures
#   - github.com/OffchainLabs/prysm/v7/cache/**              : Cache infrastructure
#   - github.com/OffchainLabs/prysm/v7/math/**               : Math utilities
#   - github.com/OffchainLabs/prysm/v7/async/**              : Async processing infrastructure
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/blockchain/** : Blockchain operational logic
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/cache/**     : Cache
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/db/**        : Database
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/operations/** : Operational logic
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/p2p/**       : P2P networking
#   - github.com/OffchainLabs/prysm/v7/beacon-chain/slasher/**   : Slasher logic
#   - github.com/OffchainLabs/prysm/v7/config/features           : Feature flags (params only)
#   - github.com/OffchainLabs/prysm/v7/encoding/bytesutil         : Byte utilities (ssz only)
#   - github.com/OffchainLabs/prysm/v7/crypto/hash/**            : Hash functions (bls only)
#
# Filtering is done by parsing Go coverage.txt file and keeping only files that belong to
# one of the included packages, then regenerating HTML report from filtered coverage.txt.
PRYSM_CORE_INCLUDE_PREFIXES = (
    "github.com/OffchainLabs/prysm/v7/beacon-chain/core",
    "github.com/OffchainLabs/prysm/v7/beacon-chain/state",
    "github.com/OffchainLabs/prysm/v7/consensus-types",
    "github.com/OffchainLabs/prysm/v7/encoding/ssz",
    "github.com/OffchainLabs/prysm/v7/crypto/bls",
    "github.com/OffchainLabs/prysm/v7/config/params",
    "github.com/OffchainLabs/prysm/v7/tools/pcli",
)

class Clients:
    def __init__(self, name, cmd_path, cmd_args):
        self.name = name
        self.cmd_path = Path(cmd_path)
        self.cmd_args = cmd_args
        self.state = None
        self.block = None
        self.output = None
        self.status_code = None
        self.timestamp = None
        self.available = self.cmd_path.exists()

    def log_stderr(self):
        if self.output:
            if self.output.stderr.strip() != "":
                print(f"[+] {self.output.stderr.strip()}")

    def log_stdout(self):
        if self.output:
            if self.output.stdout.strip() != "":
                print(f"[+] {self.output.stdout.strip()}")

    def log_status(self):
        if self.status_code is not None:
            status_message = f"[+] Exited with status code: {self.status_code}"
            if self.status_code == 0:
                print(f"{status_message} (Success)")
            else:
                print(f"{status_message} (Failure)")
        else:
            print("[+] Process terminated by signal")

    def log(self):
        self.log_status()
        self.log_stdout()
        self.log_stderr()


def decompress_snappy(converter_dir, input_file, output_file):
    """
    Decompress snappy file.
    
    Args:
        converter_dir: Converter directory path
        input_file: Input snappy file path
        output_file: Output SSZ file path
    """
    snappy_decompressor = Path(converter_dir) / "Converter" / "snappyDecompressor.py"
    if not snappy_decompressor.exists():
        # Fallback: script is in spectec-core directory
        snappy_decompressor = Path(converter_dir) / "snappyDecompressor.py"
    
    try:
        result = subprocess.run(
            [sys.executable, str(snappy_decompressor), str(input_file), str(output_file)],
            capture_output=True,
            text=True,
            check=True
        )
        return True
    except subprocess.CalledProcessError as e:
        print(f"  ✗ Snappy decompression failed: {e.stderr}")
        return False


def parse_state_block(state_dir, block_dir, output_parent_dir, converter_dir=None):
    """
    Find SSZ file pairs from state_dir and block_dir and yield them.
    
    Supported file formats:
    1. pre.ssz_snappy + blocks_*.ssz_snappy (OfficialTestSuite original)
    2. pre.ssz + blocks_*.ssz (used by run_test_suite.py)
    3. pre_*.ssz + blocks_0.ssz (state mutation tool output)
    4. state_*.ssz + block_*.ssz (legacy format)
    
    .ssz_snappy files are automatically converted to .ssz.
    Each block is processed independently from the original pre/state.
    """
    tools = STATE_TRANSITION_TOOLS
    paths = {}

    for tool in tools:
        output_dir = os.path.join(output_parent_dir, f"{tool}/output")
        os.makedirs(output_dir, exist_ok=True)
        paths[tool] = {
            "output_dir": output_dir,
            "cov_output_base": os.path.join(output_parent_dir, f"{tool}")  # Base for cov_output_{index}
        }

    # Find pre.ssz or pre.ssz_snappy file
    pre_ssz = os.path.join(state_dir, "pre.ssz")
    pre_snappy = os.path.join(state_dir, "pre.ssz_snappy")
    
    needs_decompression = False
    decompressed_dir = None
    
    # Convert .ssz_snappy to .ssz if needed
    if os.path.exists(pre_snappy) and not os.path.exists(pre_ssz):
        needs_decompression = True
        decompressed_dir = os.path.join(output_parent_dir, "_decompressed")
        os.makedirs(decompressed_dir, exist_ok=True)
        
        if converter_dir is None:
            script_dir = Path(__file__).parent.resolve()
            converter_dir = script_dir
        
        decompressed_pre = os.path.join(decompressed_dir, "pre.ssz")
        print(f"[+] Decompressing {pre_snappy} -> {decompressed_pre}")
        if not decompress_snappy(converter_dir, pre_snappy, decompressed_pre):
            print(f"[!] Failed to decompress pre.ssz_snappy, skipping...")
            if decompressed_dir and os.path.exists(decompressed_dir) and not os.listdir(decompressed_dir):
                os.rmdir(decompressed_dir)
            return
        if os.path.exists(decompressed_pre):
            print(f"[+] Successfully decompressed pre.ssz to {decompressed_pre}")
        pre_ssz = decompressed_pre
    
    if os.path.exists(pre_ssz):
        # Find blocks_*.ssz or blocks_*.ssz_snappy files (sorted numerically)
        block_ssz_files = sorted(
            [f for f in os.listdir(block_dir) if f.startswith("blocks_") and f.endswith(".ssz")],
            key=lambda f: int(f.replace("blocks_", "").replace(".ssz", "")) if f.replace("blocks_", "").replace(".ssz", "").isdigit() else float('inf')
        )
        block_snappy_files = sorted(
            [f for f in os.listdir(block_dir) if f.startswith("blocks_") and f.endswith(".ssz_snappy")],
            key=lambda f: int(f.replace("blocks_", "").replace(".ssz_snappy", "")) if f.replace("blocks_", "").replace(".ssz_snappy", "").isdigit() else float('inf')
        )
        
        # Convert .ssz_snappy to .ssz if needed
        if block_snappy_files and not block_ssz_files:
            if not needs_decompression:
                decompressed_dir = os.path.join(output_parent_dir, "_decompressed")
                os.makedirs(decompressed_dir, exist_ok=True)
                needs_decompression = True
            
            if converter_dir is None:
                script_dir = Path(__file__).parent.resolve()
                converter_dir = script_dir
            
            for block_snappy_file in block_snappy_files:
                block_num = block_snappy_file.replace("blocks_", "").replace(".ssz_snappy", "")
                block_snappy_path = os.path.join(block_dir, block_snappy_file)
                decompressed_block = os.path.join(decompressed_dir, f"blocks_{block_num}.ssz")
                print(f"[+] Decompressing {block_snappy_file} -> blocks_{block_num}.ssz")
                if not decompress_snappy(converter_dir, block_snappy_path, decompressed_block):
                    print(f"[!] Failed to decompress {block_snappy_file}, skipping...")
                    continue
                if os.path.exists(decompressed_block):
                    print(f"[+] Successfully decompressed {block_snappy_file} to {decompressed_block}")
                block_ssz_files.append(f"blocks_{block_num}.ssz")
        
        use_decompressed = (decompressed_dir is not None and decompressed_dir in pre_ssz) or (block_snappy_files and not os.path.exists(os.path.join(block_dir, "blocks_0.ssz")))
        
        for block_file in block_ssz_files:
            block_index = block_file.replace("blocks_", "").replace(".ssz", "")
            
            if use_decompressed and decompressed_dir is not None and os.path.exists(os.path.join(decompressed_dir, block_file)):
                block_path = os.path.join(decompressed_dir, block_file)
            else:
                block_path = os.path.join(block_dir, block_file)
            
            if not os.path.exists(block_path):
                continue
            
            paths_per_pair = {
                tool: {
                    "output": os.path.join(paths[tool]["output_dir"], f"poststate_{block_index}.ssz"),
                    "cov_output": os.path.join(paths[tool]["cov_output_base"], f"cov_output_{block_index}")
                }
                for tool in tools
            }
            
            # Create independent cov_output directory for each block
            for tool in tools:
                os.makedirs(paths_per_pair[tool]["cov_output"], exist_ok=True)
            
            yield pre_ssz, block_path, paths_per_pair
        return
    
    # New format: pre_*.ssz (multiple mutated states) + blocks_0.ssz (single block)
    # For state mutation generated cases
    pre_files = sorted(
        [f for f in os.listdir(state_dir) if f.startswith("pre_") and f.endswith(".ssz")],
        key=lambda f: int(f.replace("pre_", "").replace(".ssz", "")) if f.replace("pre_", "").replace(".ssz", "").isdigit() else float('inf')
    )
    
    if pre_files:
        # Find blocks_0.ssz file (single original block)
        block_file = None
        for bf in ["blocks_0.ssz", "block_0.ssz"]:
            if os.path.exists(os.path.join(block_dir, bf)):
                block_file = bf
                break
        
        if block_file:
            block_path = os.path.join(block_dir, block_file)
            
            for pre_file in pre_files:
                state_index = pre_file.replace("pre_", "").replace(".ssz", "")
                state_path = os.path.join(state_dir, pre_file)
                
                paths_per_pair = {
                    tool: {
                        "output": os.path.join(paths[tool]["output_dir"], f"poststate_{state_index}.ssz"),
                        "cov_output": os.path.join(paths[tool]["cov_output_base"], f"cov_output_{state_index}")
                    }
                    for tool in tools
                }
                
                # Create independent cov_output directory for each state
                for tool in tools:
                    os.makedirs(paths_per_pair[tool]["cov_output"], exist_ok=True)
                
                yield state_path, block_path, paths_per_pair
            return
    
    # Legacy format: state_*.ssz + block_*.ssz
    for state_file in os.listdir(state_dir):
        if state_file.endswith(".ssz"):
            state_index = state_file.split("_")[-1].split(".")[0]
            block_file = next(
                (file for file in os.listdir(block_dir) if file.endswith(f"_{state_index}.ssz")),
                None
            )

            if block_file:
                state_path = os.path.join(state_dir, state_file)
                block_path = os.path.join(block_dir, block_file)

                paths_per_pair = {
                    tool: {
                        "output": os.path.join(paths[tool]["output_dir"], f"poststate_{state_index}.ssz"),
                        "cov_output": os.path.join(paths[tool]["cov_output_base"], f"cov_output_{state_index}")
                    }
                    for tool in tools
                }

                # Create independent cov_output directory for each state
                for tool in tools:
                    os.makedirs(paths_per_pair[tool]["cov_output"], exist_ok=True)

                yield state_path, block_path, paths_per_pair


def parse_operation(test_case_dir, output_parent_dir, converter_dir=None):
    """
    Find operation test cases from test_case_dir and yield them.
    
    Supported file formats:
    1. pre.ssz_snappy + <operation_type>.ssz_snappy (OfficialTestSuite original)
    2. pre.ssz + <operation_type>.ssz (already converted format)
    
    Operation type is extracted from:
    - Directory name (e.g., operations/attestation/pyspec_tests/... -> "attestation")
    - Or operation file name (e.g., attestation.ssz, block.ssz, etc.)
    
    .ssz_snappy files are automatically converted to .ssz.
    """
    tools = STATE_TRANSITION_TOOLS
    paths = {}
    
    for tool in tools:
        output_dir = os.path.join(output_parent_dir, f"{tool}/output")
        os.makedirs(output_dir, exist_ok=True)
        paths[tool] = {
            "output_dir": output_dir,
            "cov_output_base": os.path.join(output_parent_dir, f"{tool}")
        }
    
    # Find pre.ssz or pre.ssz_snappy file
    pre_ssz = os.path.join(test_case_dir, "pre.ssz")
    pre_snappy = os.path.join(test_case_dir, "pre.ssz_snappy")
    
    needs_decompression = False
    decompressed_dir = None
    
    # Convert .ssz_snappy to .ssz if needed
    if os.path.exists(pre_snappy) and not os.path.exists(pre_ssz):
        needs_decompression = True
        decompressed_dir = os.path.join(output_parent_dir, "_decompressed")
        os.makedirs(decompressed_dir, exist_ok=True)
        
        if converter_dir is None:
            script_dir = Path(__file__).parent.resolve()
            converter_dir = script_dir
        
        decompressed_pre = os.path.join(decompressed_dir, "pre.ssz")
        print(f"[+] Decompressing {pre_snappy} -> {decompressed_pre}")
        if not decompress_snappy(converter_dir, pre_snappy, decompressed_pre):
            print(f"[!] Failed to decompress pre.ssz_snappy, skipping...")
            if decompressed_dir and os.path.exists(decompressed_dir) and not os.listdir(decompressed_dir):
                os.rmdir(decompressed_dir)
            return
        if os.path.exists(decompressed_pre):
            print(f"[+] Successfully decompressed pre.ssz to {decompressed_pre}")
        pre_ssz = decompressed_pre
    
    if not os.path.exists(pre_ssz):
        return
    
    # Determine operation type from directory path or file name
    # Try to extract from path: operations/attestation/pyspec_tests/... -> "attestation"
    operation_type = None
    test_case_path_parts = Path(test_case_dir).parts
    if "operations" in test_case_path_parts:
        ops_idx = test_case_path_parts.index("operations")
        if ops_idx + 1 < len(test_case_path_parts):
            operation_type = test_case_path_parts[ops_idx + 1]
            # Normalize operation type names (e.g., "withdrawals" -> "withdrawal")
            if operation_type == "withdrawals":
                operation_type = "withdrawal"
    
    # If not found in path, try to find operation file
    operation_file_map = {
        "attestation": ["attestation.ssz", "attestation.ssz_snappy"],
        "attester_slashing": ["attester_slashing.ssz", "attester_slashing.ssz_snappy"],
        "proposer_slashing": ["proposer_slashing.ssz", "proposer_slashing.ssz_snappy"],
        "block_header": ["block.ssz", "block.ssz_snappy", "block_header.ssz", "block_header.ssz_snappy"],
        "deposit": ["deposit.ssz", "deposit.ssz_snappy"],
        "voluntary_exit": ["voluntary_exit.ssz", "voluntary_exit.ssz_snappy"],
        "sync_aggregate": ["sync_aggregate.ssz", "sync_aggregate.ssz_snappy"],
        "execution_payload": ["body.ssz", "body.ssz_snappy", "execution_payload.ssz", "execution_payload.ssz_snappy"],
        "bls_to_execution_change": ["address_change.ssz", "address_change.ssz_snappy", "bls_to_execution_change.ssz", "bls_to_execution_change.ssz_snappy"],
        "withdrawal": ["withdrawal.ssz", "withdrawal.ssz_snappy", "execution_payload.ssz", "execution_payload.ssz_snappy"],
    }
    
    # Find operation file
    operation_file = None
    found_operation_type = None
    
    if operation_type and operation_type in operation_file_map:
        # Try files for this operation type
        for op_file in operation_file_map[operation_type]:
            op_path = os.path.join(test_case_dir, op_file)
            if os.path.exists(op_path):
                operation_file = op_file
                found_operation_type = operation_type
                break
    
    # If not found, search all possible operation files
    if not operation_file:
        for op_type, file_names in operation_file_map.items():
            for op_file in file_names:
                op_path = os.path.join(test_case_dir, op_file)
                if os.path.exists(op_path):
                    operation_file = op_file
                    found_operation_type = op_type
                    break
            if operation_file:
                break
    
    if not operation_file or not found_operation_type:
        print(f"[!] No operation file found in {test_case_dir}")
        return
    
    # Handle .ssz_snappy operation file
    operation_path = os.path.join(test_case_dir, operation_file)
    if operation_file.endswith(".ssz_snappy"):
        if not needs_decompression:
            decompressed_dir = os.path.join(output_parent_dir, "_decompressed")
            os.makedirs(decompressed_dir, exist_ok=True)
            needs_decompression = True
        
        if converter_dir is None:
            script_dir = Path(__file__).parent.resolve()
            converter_dir = script_dir
        
        # Extract base name without extension
        op_base = operation_file.replace(".ssz_snappy", "")
        decompressed_op = os.path.join(decompressed_dir, f"{op_base}.ssz")
        print(f"[+] Decompressing {operation_file} -> {op_base}.ssz")
        if not decompress_snappy(converter_dir, operation_path, decompressed_op):
            print(f"[!] Failed to decompress {operation_file}, skipping...")
            return
        if os.path.exists(decompressed_op):
            print(f"[+] Successfully decompressed {operation_file} to {decompressed_op}")
        operation_path = decompressed_op
    
    # Generate index from test case directory name
    test_case_name = os.path.basename(test_case_dir)
    
    paths_per_test = {
        tool: {
            "output": os.path.join(paths[tool]["output_dir"], f"poststate_{test_case_name}.ssz"),
            "cov_output": os.path.join(paths[tool]["cov_output_base"], f"cov_output_{test_case_name}")
        }
        for tool in tools
    }
    
    # Create independent cov_output directory for each test case
    for tool in tools:
        os.makedirs(paths_per_test[tool]["cov_output"], exist_ok=True)
    
    # For execution_payload operation, parse execution.yaml to get execution_valid value
    execution_valid = None
    if found_operation_type == "execution_payload":
        execution_yaml_path = os.path.join(test_case_dir, "execution.yaml")
        if os.path.exists(execution_yaml_path):
            try:
                with open(execution_yaml_path, 'r') as f:
                    content = f.read().strip()
                    # Parse YAML-like format: {execution_valid: true} or {execution_valid: false}
                    if 'execution_valid: true' in content or 'execution_valid: True' in content:
                        execution_valid = True
                    elif 'execution_valid: false' in content or 'execution_valid: False' in content:
                        execution_valid = False
                    else:
                        # Try parsing as actual YAML
                        import yaml
                        yaml_data = yaml.safe_load(content)
                        if isinstance(yaml_data, dict) and 'execution_valid' in yaml_data:
                            execution_valid = bool(yaml_data['execution_valid'])
                if execution_valid is not None:
                    print(f"[+] Parsed execution_valid={execution_valid} from {execution_yaml_path}")
                else:
                    print(f"[!] Could not parse execution_valid from {execution_yaml_path}, defaulting to valid")
                    execution_valid = True  # Default to valid if parsing fails
            except Exception as e:
                print(f"[!] Error parsing execution.yaml: {e}, defaulting to valid")
                execution_valid = True  # Default to valid on error
        else:
            print(f"[!] execution.yaml not found in {test_case_dir}, defaulting to valid")
            execution_valid = True  # Default to valid if file doesn't exist
    
    yield pre_ssz, operation_path, found_operation_type, paths_per_test, execution_valid


def parse_epoch_processing(test_case_dir, output_parent_dir, converter_dir=None):
    """
    Find epoch-processing test cases from test_case_dir and yield them.
    
    Supported file formats:
    1. pre.ssz_snappy (OfficialTestSuite original)
    2. pre.ssz (already converted format)
    
    Epoch processing type is extracted from directory path:
    - epoch_processing/justification_and_finalization/pyspec_tests/... -> "justification_and_finalization"
    
    .ssz_snappy files are automatically converted to .ssz.
    """
    tools = STATE_TRANSITION_TOOLS
    paths = {}
    
    for tool in tools:
        output_dir = os.path.join(output_parent_dir, f"{tool}/output")
        os.makedirs(output_dir, exist_ok=True)
        paths[tool] = {
            "output_dir": output_dir,
            "cov_output_base": os.path.join(output_parent_dir, f"{tool}")
        }
    
    # Find pre.ssz or pre.ssz_snappy file
    pre_ssz = os.path.join(test_case_dir, "pre.ssz")
    pre_snappy = os.path.join(test_case_dir, "pre.ssz_snappy")
    
    needs_decompression = False
    decompressed_dir = None
    
    # Convert .ssz_snappy to .ssz if needed
    if os.path.exists(pre_snappy) and not os.path.exists(pre_ssz):
        needs_decompression = True
        decompressed_dir = os.path.join(output_parent_dir, "_decompressed")
        os.makedirs(decompressed_dir, exist_ok=True)
        
        if converter_dir is None:
            script_dir = Path(__file__).parent.resolve()
            converter_dir = script_dir
        
        decompressed_pre = os.path.join(decompressed_dir, "pre.ssz")
        print(f"[+] Decompressing {pre_snappy} -> {decompressed_pre}")
        if not decompress_snappy(converter_dir, pre_snappy, decompressed_pre):
            print(f"[!] Failed to decompress pre.ssz_snappy, skipping...")
            if decompressed_dir and os.path.exists(decompressed_dir) and not os.listdir(decompressed_dir):
                os.rmdir(decompressed_dir)
            return
        if os.path.exists(decompressed_pre):
            print(f"[+] Successfully decompressed pre.ssz to {decompressed_pre}")
        pre_ssz = decompressed_pre
    
    if not os.path.exists(pre_ssz):
        return
    
    # Determine epoch processing type from directory path
    # Try to extract from path: epoch_processing/justification_and_finalization/pyspec_tests/... -> "justification_and_finalization"
    epoch_processing_type = None
    test_case_path_parts = Path(test_case_dir).parts
    if "epoch_processing" in test_case_path_parts:
        epoch_idx = test_case_path_parts.index("epoch_processing")
        if epoch_idx + 1 < len(test_case_path_parts):
            epoch_processing_type = test_case_path_parts[epoch_idx + 1]
    
    if not epoch_processing_type:
        print(f"[!] Could not determine epoch processing type from path: {test_case_dir}")
        return
    
    # Generate index from test case directory name
    test_case_name = os.path.basename(test_case_dir)
    
    paths_per_test = {
        tool: {
            "output": os.path.join(paths[tool]["output_dir"], f"poststate_{test_case_name}.ssz"),
            "cov_output": os.path.join(paths[tool]["cov_output_base"], f"cov_output_{test_case_name}")
        }
        for tool in tools
    }
    
    # Create independent cov_output directory for each test case
    for tool in tools:
        os.makedirs(paths_per_test[tool]["cov_output"], exist_ok=True)
    
    yield pre_ssz, epoch_processing_type, paths_per_test


def parse_sanity_slots(test_case_dir, output_parent_dir, converter_dir=None):
    """
    Find sanity-slots test cases from test_case_dir and yield them.
    
    Supported file formats:
    1. pre.ssz_snappy + slots.yaml (OfficialTestSuite original)
    2. pre.ssz + slots.yaml (already converted format)
    
    Slot value is read from slots.yaml file.
    
    .ssz_snappy files are automatically converted to .ssz.
    """
    import yaml
    
    tools = STATE_TRANSITION_TOOLS
    paths = {}
    
    for tool in tools:
        output_dir = os.path.join(output_parent_dir, f"{tool}/output")
        os.makedirs(output_dir, exist_ok=True)
        paths[tool] = {
            "output_dir": output_dir,
            "cov_output_base": os.path.join(output_parent_dir, f"{tool}")
        }
    
    # Find pre.ssz or pre.ssz_snappy file
    pre_ssz = os.path.join(test_case_dir, "pre.ssz")
    pre_snappy = os.path.join(test_case_dir, "pre.ssz_snappy")
    
    needs_decompression = False
    decompressed_dir = None
    
    # Convert .ssz_snappy to .ssz if needed
    if os.path.exists(pre_snappy) and not os.path.exists(pre_ssz):
        needs_decompression = True
        decompressed_dir = os.path.join(output_parent_dir, "_decompressed")
        os.makedirs(decompressed_dir, exist_ok=True)
        
        if converter_dir is None:
            script_dir = Path(__file__).parent.resolve()
            converter_dir = script_dir
        
        decompressed_pre = os.path.join(decompressed_dir, "pre.ssz")
        print(f"[+] Decompressing {pre_snappy} -> {decompressed_pre}")
        if not decompress_snappy(converter_dir, pre_snappy, decompressed_pre):
            print(f"[!] Failed to decompress pre.ssz_snappy, skipping...")
            if decompressed_dir and os.path.exists(decompressed_dir) and not os.listdir(decompressed_dir):
                os.rmdir(decompressed_dir)
            return
        if os.path.exists(decompressed_pre):
            print(f"[+] Successfully decompressed pre.ssz to {decompressed_pre}")
        pre_ssz = decompressed_pre
    
    if not os.path.exists(pre_ssz):
        return
    
    # Find slots.yaml file
    slots_yaml = os.path.join(test_case_dir, "slots.yaml")
    if not os.path.exists(slots_yaml):
        print(f"[!] No slots.yaml file found in {test_case_dir}")
        return
    
    # Read slot value from YAML
    try:
        with open(slots_yaml, 'r') as f:
            slot_value = yaml.safe_load(f)
            # Handle both single integer and list format
            if isinstance(slot_value, list) and len(slot_value) > 0:
                slot_value = slot_value[0]
            elif isinstance(slot_value, (int, str)):
                slot_value = int(slot_value)
            else:
                print(f"[!] Invalid slot value in {slots_yaml}: {slot_value}")
                return
    except Exception as e:
        print(f"[!] Failed to read slots.yaml: {e}")
        return
    
    # Generate index from test case directory name
    test_case_name = os.path.basename(test_case_dir)
    
    paths_per_test = {
        tool: {
            "output": os.path.join(paths[tool]["output_dir"], f"poststate_{test_case_name}.ssz"),
            "cov_output": os.path.join(paths[tool]["cov_output_base"], f"cov_output_{test_case_name}")
        }
        for tool in tools
    }
    
    # Create independent cov_output directory for each test case
    for tool in tools:
        os.makedirs(paths_per_test[tool]["cov_output"], exist_ok=True)
    
    yield pre_ssz, slot_value, paths_per_test


def process_clients(state, block, paths, spectec_core_dir=None, enable_coverage=False, fork_version="capella"):
    """
    Process clients with proper testing_clients path setup.
    
    Args:
        state: Pre-state SSZ file path
        block: Block SSZ file path
        paths: Output path dictionary (includes output and cov_output paths for each client)
        spectec_core_dir: spectec-core directory path
        enable_coverage: Enable coverage measurement
    """
    if spectec_core_dir is None:
        script_dir = Path(__file__).parent.resolve()
        spectec_core_dir = script_dir

    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    eth2spec_result = Path(spectec_core_dir) / "Converter" / "eth2specResult.py"
    consensus_specs_path = Path(spectec_core_dir) / "consensus-specs" / "tests" / "core" / "pyspec"
    eth2spec_mainnet = consensus_specs_path / "eth2spec" / fork_version / "mainnet.py"

    # Check Lodestar transition.js file path
    lodestar_transition = testing_clients_dir / "lodestar" / "transition.js"
    if not lodestar_transition.exists():
        lodestar_transition = testing_clients_dir / "lodestar" / "transition"

    # Pure config path setup (version-specific)
    if fork_version == "deneb":
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_deneb_configs"
        if not pure_configs_dir.exists():
            # Fallback to capella configs if deneb configs don't exist
            pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    else:  # capella
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    lighthouse_testnet_dir = pure_configs_dir / "lighthouse_testnet"
    # Note: teku_config and nimbus_config are not used (Teku uses CLI args, Nimbus uses code override)

    # Coverage data directory setup (from paths)
    coverage_dirs = {}
    if enable_coverage:
        for client_name in STATE_TRANSITION_TOOLS:
            if client_name in paths and "cov_output" in paths[client_name]:
                coverage_dirs[client_name] = Path(paths[client_name]["cov_output"])
                coverage_dirs[client_name].mkdir(parents=True, exist_ok=True)

    # Client binary paths: use separate binaries in coverage mode (single binary supports both capella and deneb)
    if enable_coverage:
        prysm_binary = testing_clients_dir / "prysm" / "pcli-cov"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli-cov"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku-cov" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli-cov"
    else:
        prysm_binary = testing_clients_dir / "prysm" / "bazel-bin" / "tools" / "pcli" / "pcli_" / "pcli"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli"

    clients = [
        Clients(
            "Lodestar",
            "/usr/bin/node",
            [
                "--max-old-space-size=16384",
                str(lodestar_transition),
                "state-transition",  # Command name
                state,
                block,
                paths["lodestar"]["output"],
                "--verifyProposer=false",  # validate_result = false: Skip block signature verification
                "--verifyStateRoot=false",  # validate_result = false: Skip state root verification
                f"--fork-version={fork_version}",
            ]),
        Clients(
            "Lighthouse",
            str(lighthouse_binary),
            [
                "transition-blocks",
                "--pre-state-path", state,
                "--block-path", block,
                "--post-state-output-path", paths["lighthouse"]["output"],
                # Pure config: fork epochs set to 0
                "--testnet-dir", str(lighthouse_testnet_dir),
                # validate_result = false (via modified_code): Skip block signature and state root verification
                # Block signature: skipped in transition_blocks.rs (SkipBlockSignatureOnly)
                # State root: skipped in transition_blocks.rs (commented out)
                # RANDAO and attestation signatures: still verified
            ]),
        Clients(
            "Prysm",
            str(prysm_binary),
            [
                "state-transition",
                f"--block-path={block}",
                f"--pre-state-path={state}",
                f"--expected-post-state-path={paths['prysm']['output']}"
                # validate_result = false (via modified_code): Skip block signature and state root verification
                # Block signature: skipped in main.go debugStateTransition (filtered out from verify set)
                # State root: skipped in main.go (commented out)
                # RANDAO and attestation signatures: still verified
            ]),
        Clients(
            "Nimbus",
            str(nimbus_binary),
            [
                "transition",
                state,
                block,
                paths["nimbus"]["output"],
                "false"  # validate_result = false: Skip state root verification (also skips block signature verification)
            ]),
        Clients(
            "Teku",
            str(teku_binary),
            [
                "transition",
                "blocks",
                "--pre", state,
                "--post", paths["teku"]["output"],
                block,
                # Pure config: fork epochs set to 0
                "--Xnetwork-altair-fork-epoch=0",
                "--Xnetwork-bellatrix-fork-epoch=0",
                "--Xnetwork-capella-fork-epoch=0",
                f"--Xnetwork-deneb-fork-epoch={'0' if fork_version == 'deneb' else '75520'}",
                # validate_result = false (via modified_code): Skip block signature and state root verification
                # Block signature: skipped in AbstractBlockProcessor.java (verifyBlockSignature commented out)
                # State root: skipped in AbstractBlockProcessor.java (validatePostState commented out)
                # RANDAO and attestation signatures: still verified via BLSSignatureVerifier.SIMPLE
            ]),
        Clients(
            "Eth2spec",
            sys.executable,
            [
                str(eth2spec_result),
                "--pre", state,
                "--block", block,
                "--out", paths["eth2spec"]["output"],
                "--fork", fork_version,
            ]),
    ]

    for client in clients:
        cmd = [str(client.cmd_path)] + [str(arg) for arg in client.cmd_args]
        try:
            start_time = perf_counter()

            print(f"\n[+] Running: {client.name}")

            if not client.available:
                raise FileNotFoundError(f"[X] Not available: {client.cmd_path}")

            client.state = state
            client.block = block

            # Setup coverage environment variables
            env = os.environ.copy()
            if client.name == "Nimbus":
                env["FORK_VERSION"] = fork_version
            elif client.name == "Eth2spec":
                existing_pythonpath = env.get("PYTHONPATH")
                env["PYTHONPATH"] = (
                    str(consensus_specs_path)
                    if not existing_pythonpath
                    else str(consensus_specs_path) + os.pathsep + existing_pythonpath
                )

            if enable_coverage:
                if client.name == "Prysm":
                    env["GOCOVERDIR"] = str(coverage_dirs["prysm"])
                    print(f"[+] Coverage enabled: GOCOVERDIR={env['GOCOVERDIR']}")

                elif client.name == "Lighthouse":
                    profile_file = coverage_dirs["lighthouse"] / f"lighthouse-cov-%p-%m.profraw"
                    env["LLVM_PROFILE_FILE"] = str(profile_file)
                    print(f"[+] Coverage enabled: LLVM_PROFILE_FILE={env['LLVM_PROFILE_FILE']}")

                elif client.name == "Teku":
                    jacoco_agent_path = testing_clients_dir / "jacoco" / "jacocoagent.jar"
                    jacoco_exec = coverage_dirs["teku"] / "teku-coverage.exec"

                    if jacoco_agent_path.exists():
                        env["JAVA_OPTS"] = f"-javaagent:{jacoco_agent_path}=destfile={jacoco_exec}"
                        print(f"[+] Coverage enabled: JAVA_OPTS={env['JAVA_OPTS']}")
                    else:
                        print(f"[!] Warning: JaCoCo agent not found at {jacoco_agent_path}")

                elif client.name == "Nimbus":
                    nimbus_src = testing_clients_dir / "nimbus-eth2"
                    nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"

                    if nimbus_gcda_dir.exists():
                        for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                            try:
                                gcda_file.unlink()
                            except OSError:
                                pass
                    print(f"[+] Coverage enabled: gcov will auto-generate .gcda files in build directory")

                elif client.name == "Lodestar":
                    lodestar_dir = testing_clients_dir / "lodestar"
                    coverage_report_dir = coverage_dirs["lodestar"] / "report"
                    coverage_temp_dir = coverage_dirs["lodestar"]
                    coverage_report_dir.mkdir(parents=True, exist_ok=True)
                    coverage_temp_dir.mkdir(parents=True, exist_ok=True)

                    original_cmd_path = str(client.cmd_path)
                    original_cmd_args = [str(arg) for arg in client.cmd_args]
                    c8_args = [
                        "c8",
                        "--all",
                        "--reporter=text",
                        "--reporter=html",
                        f"--report-dir={coverage_report_dir}",
                        f"--temp-directory={coverage_temp_dir}",
                        "--exclude-node-modules=false",
                        "--extension=.js",
                        "--include=node_modules/@lodestar/**/*.js",
                        "--include=node_modules/@chainsafe/**/*.js",
                        "--exclude=**/transition.js",
                        "--exclude=**/generateCachedStateCapella.js",
                        original_cmd_path,
                    ] + original_cmd_args

                    client.cmd_path = "npx"
                    client.cmd_args = c8_args
                    cmd = ["npx"] + c8_args

                    print(f"[+] Coverage enabled: c8 with report-dir={coverage_report_dir}")
                    print(f"[+] Coverage temp-directory: {coverage_temp_dir}")
                    print(f"[+] Coverage command: npx {' '.join(c8_args)}")

                elif client.name == "Eth2spec":
                    coverage_data = coverage_dirs["eth2spec"] / ".coverage"
                    coverage_args = [
                        "-m",
                        "coverage",
                        "run",
                        "--branch",
                        "--data-file",
                        str(coverage_data),
                        "--include",
                        str(eth2spec_mainnet),
                    ] + [str(arg) for arg in client.cmd_args]
                    client.cmd_args = coverage_args
                    cmd = [str(client.cmd_path)] + coverage_args
                    print(f"[+] Coverage enabled: coverage.py data-file={coverage_data}")
                    print(f"[+] Coverage include target: {eth2spec_mainnet}")

            print(f"[+] Command: {client.cmd_path} {' '.join(str(arg) for arg in client.cmd_args)}")

            if client.name == "Lodestar" and enable_coverage:
                cwd = str(testing_clients_dir / "lodestar")
            else:
                cwd = None

            process = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                cwd=cwd,
            )
            end_time = perf_counter()

            client.status_code = process.returncode
            client.output = process
            client.timestamp = end_time - start_time

            print(f"[+] Execution time: {client.timestamp}")

            if process.returncode == 0:
                client.status_code = 0
            elif process.returncode < 0:
                client.status_code = 2
            else:
                client.status_code = 1

            if client.name == "Lodestar":
                try:
                    if client.output.stderr != '':
                        try:
                            import json
                            json_start = client.output.stderr.find('{')
                            if json_start != -1:
                                json_end = client.output.stderr.rfind('}') + 1
                                if json_end > json_start:
                                    json_str = client.output.stderr[json_start:json_end]
                                    error_obj = json.loads(json_str)
                                    status_code = error_obj.get('statusCode', 1)
                                    output_string = error_obj.get('output', '')
                                    if status_code == 0:
                                        client.status_code = 0
                                    elif status_code < 0:
                                        client.status_code = 2
                                    else:
                                        client.status_code = 1
                                    client.output.stderr = output_string
                                    continue
                        except Exception:
                            pass

                        status_code_match = re.search(r"statusCode: \s*(\d+)", client.output.stderr)
                        if status_code_match:
                            status_code = int(status_code_match.group(1))
                            output_match = re.search(r"output: \s*'(.*?)'", client.output.stderr, re.DOTALL)
                            if output_match:
                                output_string = output_match.group(1)
                                if status_code == 0:
                                    client.status_code = 0
                                elif status_code < 0:
                                    client.status_code = 2
                                else:
                                    client.status_code = 1
                                client.output.stderr = output_string
                except Exception:
                    client.status_code = 2

            client.log()

            if client.name == "Nimbus" and enable_coverage:
                nimbus_src = testing_clients_dir / "nimbus-eth2"
                nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                nimbus_coverage_dir = coverage_dirs.get("nimbus")

                if nimbus_coverage_dir and nimbus_gcda_dir.exists():
                    target_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
                    target_gcda_dir.mkdir(parents=True, exist_ok=True)

                    import shutil
                    for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                        relative_path = gcda_file.relative_to(nimbus_gcda_dir)
                        target_file = target_gcda_dir / relative_path
                        target_file.parent.mkdir(parents=True, exist_ok=True)
                        try:
                            shutil.copy2(gcda_file, target_file)
                        except Exception as e:
                            print(f"[!] Failed to copy .gcda file {gcda_file}: {e}")
                    print(f"[+] Copied .gcda files to {target_gcda_dir} (will use original .gcno files for consistent measurement scope)")

            if client.name == "Teku" and client.status_code != 0:
                output_path = paths.get("teku", {}).get("output")
                if output_path and os.path.exists(output_path):
                    file_size = os.path.getsize(output_path)
                    if file_size == 0:
                        os.remove(output_path)
                        print(f"[+] Removed empty Teku output file: {output_path}")

            if client.name == "Eth2spec" and client.status_code != 0:
                output_path = paths.get("eth2spec", {}).get("output")
                if output_path and os.path.exists(output_path) and os.path.getsize(output_path) == 0:
                    os.remove(output_path)
                    print(f"[+] Removed empty Eth2spec output file: {output_path}")

        except Exception as e:
            end_time = perf_counter()
            client.timestamp = end_time - start_time
            client.status_code = 2
            if client.output is None:
                client.output = subprocess.CompletedProcess(args=cmd, returncode=2, stdout='', stderr=str(e))

            print(f"[+] Execution time: {client.timestamp}")
            print(f"[+] Exited with status code: {client.status_code} (Failure)")
            print(f"[+] {client.name} failed: {client.output.stderr}")
    return clients

def process_clients_sanity_slots(state, slot_value, paths, spectec_core_dir=None, enable_coverage=False, fork_version="capella"):
    """
    Process clients with sanity-slots command.
    
    Args:
        state: Pre-state SSZ file path
        slot_value: Target slot value (integer)
        paths: Output path dictionary (includes output and cov_output paths for each client)
        spectec_core_dir: spectec-core directory path
        enable_coverage: Enable coverage measurement
    """
    if spectec_core_dir is None:
        script_dir = Path(__file__).parent.resolve()
        spectec_core_dir = script_dir
    
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    
    # Check Lodestar transition.js file path
    lodestar_transition = testing_clients_dir / "lodestar" / "transition.js"
    if not lodestar_transition.exists():
        lodestar_transition = testing_clients_dir / "lodestar" / "transition"

    # Pure config path setup (version-specific)
    if fork_version == "deneb":
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_deneb_configs"
        if not pure_configs_dir.exists():
            # Fallback to capella configs if deneb configs don't exist
            pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    else:  # capella
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    lighthouse_testnet_dir = pure_configs_dir / "lighthouse_testnet"

    # Coverage data directory setup (from paths)
    coverage_dirs = {}
    if enable_coverage:
        for client_name in ["prysm", "lighthouse", "teku", "nimbus", "lodestar"]:
            if client_name in paths and "cov_output" in paths[client_name]:
                coverage_dirs[client_name] = Path(paths[client_name]["cov_output"])
                coverage_dirs[client_name].mkdir(parents=True, exist_ok=True)
    
    # Client binary paths: use separate binaries in coverage mode (single binary supports both capella and deneb)
    if enable_coverage:
        prysm_binary = testing_clients_dir / "prysm" / "pcli-cov"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli-cov"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku-cov" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli-cov"
    else:
        prysm_binary = testing_clients_dir / "prysm" / "bazel-bin" / "tools" / "pcli" / "pcli_" / "pcli"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli"

    clients = [
        Clients(
            "Lodestar",
            "/usr/bin/node",
            [
                "--max-old-space-size=16384",
                str(lodestar_transition),
                "sanity-slots",
                f"--pre-state-path={state}",
                f"--slot={slot_value}",
                f"--post-state-output-path={paths['lodestar']['output']}",
                f"--fork-version={fork_version}",
            ]),
        Clients(
            "Lighthouse",
            str(lighthouse_binary),
            [
                "sanity-slots",
                "--pre-state-path", state,
                "--slots", str(slot_value),
                "--post-state-output-path", paths["lighthouse"]["output"],
                "--testnet-dir", str(lighthouse_testnet_dir),
            ]),
        Clients(
            "Prysm",
            str(prysm_binary),
            [
                "sanity-slots",
                f"--pre-state-path={state}",
                f"--slot={slot_value}",
                f"--post-state-output-path={paths['prysm']['output']}",
            ]),
        Clients(
            "Nimbus",
            str(nimbus_binary),
            [
                "sanity_slots",
                state,
                str(slot_value),
                paths["nimbus"]["output"],
            ]),
        Clients(
            "Teku",
            str(teku_binary),
            [
                "transition",
                "slots",
                "--pre", state,
                "--post", paths["teku"]["output"],
                "--delta",  # Interpret slot_value as delta from pre-state (default=true, but explicit for clarity)
                str(slot_value),  # Positional parameter: number of slots (delta from pre-state)
                "--Xnetwork-altair-fork-epoch=0",
                "--Xnetwork-bellatrix-fork-epoch=0",
                "--Xnetwork-capella-fork-epoch=0",
                f"--Xnetwork-deneb-fork-epoch={'0' if fork_version == 'deneb' else '75520'}",
            ]),
    ]

    # Use the same client processing logic as process_clients
    for client in clients:
        try:
            start_time = perf_counter()
            
            print(f"\n[+] Running: {client.name}")

            if not client.available:
                raise FileNotFoundError(f"[X] Not available: {client.cmd_path}")

            client.state = state
            client.block = None  # No block for sanity-slots

            print(f"[+] Command: {client.cmd_path} {' '.join(str(arg) for arg in client.cmd_args)}")
            cmd = [str(client.cmd_path)] + [str(arg) for arg in client.cmd_args]

            # Setup coverage environment variables (same as process_clients)
            env = os.environ.copy()
            # Set FORK_VERSION environment variable for Nimbus
            if client.name == "Nimbus":
                env["FORK_VERSION"] = fork_version
            if enable_coverage:
                client_name_lower = client.name.lower()
                
                if client.name == "Prysm":
                    env["GOCOVERDIR"] = str(coverage_dirs["prysm"])
                    print(f"[+] Coverage enabled: GOCOVERDIR={env['GOCOVERDIR']}")
                
                elif client.name == "Lighthouse":
                    profile_file = coverage_dirs["lighthouse"] / f"lighthouse-cov-%p-%m.profraw"
                    env["LLVM_PROFILE_FILE"] = str(profile_file)
                    print(f"[+] Coverage enabled: LLVM_PROFILE_FILE={env['LLVM_PROFILE_FILE']}")
                
                elif client.name == "Teku":
                    jacoco_agent_path = testing_clients_dir / "jacoco" / "jacocoagent.jar"
                    jacoco_exec = coverage_dirs["teku"] / "teku-coverage.exec"
                    
                    if jacoco_agent_path.exists():
                        env["JAVA_OPTS"] = f"-javaagent:{jacoco_agent_path}=destfile={jacoco_exec}"
                        print(f"[+] Coverage enabled: JAVA_OPTS={env['JAVA_OPTS']}")
                    else:
                        print(f"[!] Warning: JaCoCo agent not found at {jacoco_agent_path}")
                
                elif client.name == "Nimbus":
                    # Nim/C: gcov automatically generates .gcda files, no special env var needed
                    # For independent coverage per test case, initialize .gcda files before execution
                    # and copy them after execution
                    nimbus_src = testing_clients_dir / "nimbus-eth2"
                    nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                    
                    # Delete existing .gcda files before execution (for independent measurement)
                    if nimbus_gcda_dir.exists():
                        for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                            try:
                                gcda_file.unlink()
                            except:
                                pass
                    print(f"[+] Coverage enabled: gcov will auto-generate .gcda files in build directory")
                
                elif client.name == "Lodestar":
                    # Node.js: Use c8 for coverage measurement
                    # c8 collects coverage at runtime, so wrap the command with c8
                    lodestar_dir = testing_clients_dir / "lodestar"
                    coverage_report_dir = coverage_dirs["lodestar"] / "report"
                    coverage_temp_dir = coverage_dirs["lodestar"]  # JSON file storage location
                    coverage_report_dir.mkdir(parents=True, exist_ok=True)
                    coverage_temp_dir.mkdir(parents=True, exist_ok=True)
                    
                    # Wrap original node command with c8
                    original_cmd_path = str(client.cmd_path)
                    original_cmd_args = [str(arg) for arg in client.cmd_args]
                    
                    # c8 options:
                    # --exclude-node-modules=false: include node_modules (excluded by default)
                    # --temp-directory: specify coverage JSON file storage location
                    # --include: only include Lodestar code (exclude transition.js wrapper)
                    c8_args = [
                        "c8",
                        "--all",
                        "--reporter=text",
                        "--reporter=html",
                        f"--report-dir={coverage_report_dir}",
                        f"--temp-directory={coverage_temp_dir}",
                        "--exclude-node-modules=false",
                        "--extension=.js",
                        "--include=node_modules/@lodestar/**/*.js",
                        "--include=node_modules/@chainsafe/**/*.js",
                        "--exclude=**/transition.js",
                        "--exclude=**/generateCachedStateCapella.js",
                        original_cmd_path,  # node path
                    ] + original_cmd_args  # original arguments (all converted to strings)
                    
                    # Execute c8 using npx
                    client.cmd_path = "npx"
                    client.cmd_args = c8_args
                    cmd = ["npx"] + c8_args
                    
                    print(f"[+] Coverage enabled: c8 with report-dir={coverage_report_dir}")
                    print(f"[+] Coverage temp-directory: {coverage_temp_dir}")
                    print(f"[+] Coverage command: npx {' '.join(c8_args)}")

            # Set cwd (only for Lodestar coverage mode)
            if client.name == "Lodestar" and enable_coverage:
                cwd = str(testing_clients_dir / "lodestar")
            else:
                cwd = None

            client.output = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                env=env,
                cwd=cwd,
            )
            client.status_code = client.output.returncode
            end_time = perf_counter()
            client.timestamp = end_time - start_time

            if client.status_code == 0:
                print(f"[+] Execution time: {client.timestamp}")
                print(f"[+] Exited with status code: {client.status_code} (Success)")
            else:
                print(f"[+] Execution time: {client.timestamp}")
                print(f"[+] Exited with status code: {client.status_code} (Failure)")
            
            client.log()
            
            # Nimbus: Copy .gcda files for independent coverage per test case
            if client.name == "Nimbus" and enable_coverage:
                nimbus_src = testing_clients_dir / "nimbus-eth2"
                nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                nimbus_coverage_dir = coverage_dirs.get("nimbus")
                
                if nimbus_coverage_dir and nimbus_gcda_dir.exists():
                    target_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
                    target_gcda_dir.mkdir(parents=True, exist_ok=True)
                    
                    import shutil
                    for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                        relative_path = gcda_file.relative_to(nimbus_gcda_dir)
                        target_file = target_gcda_dir / relative_path
                        target_file.parent.mkdir(parents=True, exist_ok=True)
                        try:
                            shutil.copy2(gcda_file, target_file)
                        except Exception as e:
                            print(f"[!] Failed to copy .gcda file {gcda_file}: {e}")
                    print(f"[+] Copied .gcda files to {target_gcda_dir}")
            
            # Teku: Delete empty output files
            if client.name == "Teku" and client.status_code != 0:
                output_path = paths.get("teku", {}).get("output")
                if output_path and os.path.exists(output_path):
                    file_size = os.path.getsize(output_path)
                    if file_size == 0:
                        os.remove(output_path)
                        print(f"[+] Removed empty Teku output file: {output_path}")

        except Exception as e:
            end_time = perf_counter()
            client.timestamp = end_time - start_time
            
            if client.output is None:
                client.output = subprocess.CompletedProcess(args=cmd, returncode=2, stdout='', stderr=str(e))

            print(f"[+] Execution time: {client.timestamp}")
            print(f"[+] Exited with status code: {client.status_code} (Failure)")
            print(f"[+] {client.name} failed: {client.output.stderr}")
    return clients


def process_clients_operation(state, operation, operation_type, paths, spectec_core_dir=None, enable_coverage=False, fork_version="capella", execution_valid=None):
    """
    Process clients with operation command.
    
    Args:
        state: Pre-state SSZ file path
        operation: Operation SSZ file path
        operation_type: Operation type (attestation, block_header, etc.)
        paths: Output path dictionary (includes output and cov_output paths for each client)
        spectec_core_dir: spectec-core directory path
        enable_coverage: Enable coverage measurement
        fork_version: Fork version (capella or deneb)
        execution_valid: For execution_payload operation: whether execution payload is valid (True/False/None)
    """
    if spectec_core_dir is None:
        script_dir = Path(__file__).parent.resolve()
        spectec_core_dir = script_dir
    
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    
    # Check Lodestar transition.js file path
    lodestar_transition = testing_clients_dir / "lodestar" / "transition.js"
    if not lodestar_transition.exists():
        lodestar_transition = testing_clients_dir / "lodestar" / "transition"

    # Pure config path setup (version-specific)
    if fork_version == "deneb":
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_deneb_configs"
        if not pure_configs_dir.exists():
            # Fallback to capella configs if deneb configs don't exist
            pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    else:  # capella
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    lighthouse_testnet_dir = pure_configs_dir / "lighthouse_testnet"

    # Coverage data directory setup (from paths)
    coverage_dirs = {}
    if enable_coverage:
        for client_name in ["prysm", "lighthouse", "teku", "nimbus", "lodestar"]:
            if client_name in paths and "cov_output" in paths[client_name]:
                coverage_dirs[client_name] = Path(paths[client_name]["cov_output"])
                coverage_dirs[client_name].mkdir(parents=True, exist_ok=True)
    
    # Client binary paths: use separate binaries in coverage mode
    if enable_coverage:
        prysm_binary = testing_clients_dir / "prysm" / "pcli-cov"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli-cov"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku-cov" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli-cov"
    else:
        prysm_binary = testing_clients_dir / "prysm" / "bazel-bin" / "tools" / "pcli" / "pcli_" / "pcli"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli"

    # Map operation type names for specific clients
    # Lighthouse uses "sync_committee" instead of "sync_aggregate", and "withdrawals" instead of "withdrawal"
    # Prysm uses "withdrawals" instead of "withdrawal"
    lighthouse_operation_type = operation_type
    if operation_type == "sync_aggregate":
        lighthouse_operation_type = "sync_committee"
    elif operation_type == "withdrawal":
        lighthouse_operation_type = "withdrawals"
    
    prysm_operation_type = operation_type
    if operation_type == "withdrawal":
        prysm_operation_type = "withdrawals"

    # Build Lodestar command arguments
    lodestar_args = [
        "--max-old-space-size=16384",
        str(lodestar_transition),
        "operation",
        f"--pre-state-path={state}",
        f"--operation-path={operation}",
        f"--operation-type={operation_type}",
        f"--post-state-output-path={paths['lodestar']['output']}",
        f"--fork-version={fork_version}",
    ]
    # Add execution_valid flag for execution_payload operation
    if operation_type == "execution_payload" and execution_valid is not None:
        lodestar_args.append(f"--execution-valid={'true' if execution_valid else 'false'}")
    
    # Build Lighthouse command arguments
    lighthouse_args = [
        "operation",
        "--operation-type", lighthouse_operation_type,
        "--pre-state-path", state,
        "--operation-path", operation,
        "--post-state-output-path", paths["lighthouse"]["output"],
        "--testnet-dir", str(lighthouse_testnet_dir),
    ]
    # Add execution_valid flag for execution_payload operation
    if operation_type == "execution_payload" and execution_valid is not None:
        lighthouse_args.extend(["--execution-valid", "true" if execution_valid else "false"])
    
    # Build Prysm command arguments
    prysm_args = [
        "operation",
        f"--operation-type={prysm_operation_type}",
        f"--pre-state-path={state}",
        f"--operation-path={operation}",
        f"--post-state-output-path={paths['prysm']['output']}",
    ]
    # Add execution_valid flag for execution_payload operation
    if operation_type == "execution_payload" and execution_valid is not None:
        prysm_args.append(f"--execution-valid={'true' if execution_valid else 'false'}")
    
    # Build Nimbus command arguments
    # Note: confutils has issues with options in operation command, so we use environment variable
    nimbus_args = [
        "operation",
        state,
        operation_type,
        operation,
        paths["nimbus"]["output"],
    ]
    
    # Build Teku command arguments
    teku_args = [
        "transition",
        "operation",
        operation_type,
        "--pre", state,
        "--operation-data", operation,
        "--post", paths["teku"]["output"],
        "--Xnetwork-altair-fork-epoch=0",
        "--Xnetwork-bellatrix-fork-epoch=0",
        "--Xnetwork-capella-fork-epoch=0",
        f"--Xnetwork-deneb-fork-epoch={'0' if fork_version == 'deneb' else '75520'}",
    ]
    # Add execution_valid flag for execution_payload operation
    if operation_type == "execution_payload" and execution_valid is not None:
        teku_args.extend(["--execution-valid", "true" if execution_valid else "false"])
    
    clients = [
        Clients(
            "Lodestar",
            "/usr/bin/node",
            lodestar_args),
        Clients(
            "Lighthouse",
            str(lighthouse_binary),
            lighthouse_args),
        Clients(
            "Prysm",
            str(prysm_binary),
            prysm_args),
        Clients(
            "Nimbus",
            str(nimbus_binary),
            nimbus_args),
        Clients(
            "Teku",
            str(teku_binary),
            teku_args),
    ]

    # Use the same client processing logic as process_clients
    for client in clients:
        try:
            start_time = perf_counter()
            
            print(f"\n[+] Running: {client.name}")

            if not client.available:
                raise FileNotFoundError(f"[X] Not available: {client.cmd_path}")

            client.state = state
            client.block = operation  # Store operation path in block field for compatibility

            print(f"[+] Command: {client.cmd_path} {' '.join(str(arg) for arg in client.cmd_args)}")
            cmd = [str(client.cmd_path)] + [str(arg) for arg in client.cmd_args]

            # Setup coverage environment variables (same as process_clients)
            env = os.environ.copy()
            
            # Set FORK_VERSION environment variable for Nimbus
            if client.name == "Nimbus":
                env["FORK_VERSION"] = fork_version
            
            # Set EXECUTION_VALID environment variable for Nimbus execution_payload operation
            if client.name == "Nimbus" and operation_type == "execution_payload" and execution_valid is not None:
                env["EXECUTION_VALID"] = "true" if execution_valid else "false"
            elif client.name == "Nimbus" and operation_type == "execution_payload":
                env["EXECUTION_VALID"] = "true"  # default
            
            if enable_coverage:
                client_name_lower = client.name.lower()
                
                if client.name == "Prysm":
                    env["GOCOVERDIR"] = str(coverage_dirs["prysm"])
                    print(f"[+] Coverage enabled: GOCOVERDIR={env['GOCOVERDIR']}")
                
                elif client.name == "Lighthouse":
                    profile_file = coverage_dirs["lighthouse"] / f"lighthouse-cov-%p-%m.profraw"
                    env["LLVM_PROFILE_FILE"] = str(profile_file)
                    print(f"[+] Coverage enabled: LLVM_PROFILE_FILE={env['LLVM_PROFILE_FILE']}")
                
                elif client.name == "Teku":
                    jacoco_agent_path = testing_clients_dir / "jacoco" / "jacocoagent.jar"
                    jacoco_exec = coverage_dirs["teku"] / "teku-coverage.exec"
                    
                    if jacoco_agent_path.exists():
                        env["JAVA_OPTS"] = f"-javaagent:{jacoco_agent_path}=destfile={jacoco_exec}"
                        print(f"[+] Coverage enabled: JAVA_OPTS={env['JAVA_OPTS']}")
                    else:
                        print(f"[!] Warning: JaCoCo agent not found at {jacoco_agent_path}")
                
                elif client.name == "Nimbus":
                    nimbus_src = testing_clients_dir / "nimbus-eth2"
                    nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                    
                    if nimbus_gcda_dir.exists():
                        for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                            try:
                                gcda_file.unlink()
                            except:
                                pass
                    print(f"[+] Coverage enabled: gcov will auto-generate .gcda files in build directory")
                
                elif client.name == "Lodestar":
                    lodestar_dir = testing_clients_dir / "lodestar"
                    coverage_report_dir = coverage_dirs["lodestar"] / "report"
                    coverage_temp_dir = coverage_dirs["lodestar"]
                    coverage_report_dir.mkdir(parents=True, exist_ok=True)
                    coverage_temp_dir.mkdir(parents=True, exist_ok=True)
                    
                    original_cmd_path = str(client.cmd_path)
                    original_cmd_args = [str(arg) for arg in client.cmd_args]
                    
                    c8_args = [
                        "c8",
                        "--all",
                        "--reporter=text",
                        "--reporter=html",
                        f"--report-dir={coverage_report_dir}",
                        f"--temp-directory={coverage_temp_dir}",
                        "--exclude-node-modules=false",
                        "--extension=.js",
                        "--include=node_modules/@lodestar/**/*.js",
                        "--include=node_modules/@chainsafe/**/*.js",
                        "--exclude=**/transition.js",
                        "--exclude=**/generateCachedStateCapella.js",
                        original_cmd_path,
                    ] + original_cmd_args
                    
                    client.cmd_path = "npx"
                    client.cmd_args = c8_args
                    cmd = ["npx"] + c8_args
                    
                    print(f"[+] Coverage enabled: c8 with report-dir={coverage_report_dir}")

            # Set cwd (only for Lodestar coverage mode)
            if client.name == "Lodestar" and enable_coverage:
                cwd = str(testing_clients_dir / "lodestar")
            else:
                cwd = None

            process = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                cwd=cwd,
            )
            end_time = perf_counter()

            client.status_code = process.returncode
            client.output = process 
            client.timestamp = end_time - start_time
            
            print(f"[+] Execution time: {client.timestamp}")
            
            # Apply correct classification criteria
            if process.returncode == 0:
                client.status_code = 0  # SUCCESS
            elif process.returncode < 0:
                client.status_code = 2  # UNHANDLED_EXCEPTION
            else:
                client.status_code = 1  # FAIL
            
            # Lodestar special handling
            if client.name == "Lodestar":
                try:
                    if client.output.stderr != '':
                        try:
                            import json
                            json_start = client.output.stderr.find('{')
                            if json_start != -1:
                                json_end = client.output.stderr.rfind('}') + 1
                                if json_end > json_start:
                                    json_str = client.output.stderr[json_start:json_end]
                                    error_obj = json.loads(json_str)
                                    status_code = error_obj.get('statusCode', 1)
                                    output_string = error_obj.get('output', '')
                                    if status_code == 0:
                                        client.status_code = 0
                                    elif status_code < 0:
                                        client.status_code = 2
                                    else:
                                        client.status_code = 1
                                    client.output.stderr = output_string
                                    continue
                        except:
                            pass
                        
                        status_code_match = re.search(r"statusCode: \s*(\d+)", client.output.stderr)
                        if status_code_match:
                            status_code = int(status_code_match.group(1))
                            output_match = re.search(r"output: \s*'(.*?)'", client.output.stderr, re.DOTALL)
                            if output_match:
                                output_string = output_match.group(1)
                                if status_code == 0:
                                    client.status_code = 0
                                elif status_code < 0:
                                    client.status_code = 2
                                else:
                                    client.status_code = 1
                                client.output.stderr = output_string
                except Exception as e:
                    client.status_code = 2

            client.log()
            
            # Nimbus: Copy .gcda files for independent coverage per test case
            if client.name == "Nimbus" and enable_coverage:
                nimbus_src = testing_clients_dir / "nimbus-eth2"
                nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                nimbus_coverage_dir = coverage_dirs.get("nimbus")
                
                if nimbus_coverage_dir and nimbus_gcda_dir.exists():
                    target_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
                    target_gcda_dir.mkdir(parents=True, exist_ok=True)
                    
                    import shutil
                    for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                        relative_path = gcda_file.relative_to(nimbus_gcda_dir)
                        target_file = target_gcda_dir / relative_path
                        target_file.parent.mkdir(parents=True, exist_ok=True)
                        try:
                            shutil.copy2(gcda_file, target_file)
                        except Exception as e:
                            print(f"[!] Failed to copy .gcda file {gcda_file}: {e}")
                    print(f"[+] Copied .gcda files to {target_gcda_dir}")
            
            # Teku: Delete empty output files
            if client.name == "Teku" and client.status_code != 0:
                output_path = paths.get("teku", {}).get("output")
                if output_path and os.path.exists(output_path):
                    file_size = os.path.getsize(output_path)
                    if file_size == 0:
                        os.remove(output_path)
                        print(f"[+] Removed empty Teku output file: {output_path}")

        except Exception as e:
            end_time = perf_counter()
            client.timestamp = end_time - start_time
            
            if client.output is None:
                client.output = subprocess.CompletedProcess(args=cmd, returncode=2, stdout='', stderr=str(e))

            print(f"[+] Execution time: {client.timestamp}")
            print(f"[+] Exited with status code: {client.status_code} (Failure)")
            print(f"[+] {client.name} failed: {client.output.stderr}")
    return clients


def process_clients_epoch_processing(state, epoch_processing_type, paths, spectec_core_dir=None, enable_coverage=False, fork_version="capella"):
    """
    Process clients with epoch-processing command.
    
    Args:
        state: Pre-state SSZ file path
        epoch_processing_type: Epoch processing type (justification_and_finalization, etc.)
        paths: Output path dictionary (includes output and cov_output paths for each client)
        spectec_core_dir: spectec-core directory path
        enable_coverage: Enable coverage measurement
    """
    if spectec_core_dir is None:
        script_dir = Path(__file__).parent.resolve()
        spectec_core_dir = script_dir
    
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    
    # Check Lodestar transition.js file path
    lodestar_transition = testing_clients_dir / "lodestar" / "transition.js"
    if not lodestar_transition.exists():
        lodestar_transition = testing_clients_dir / "lodestar" / "transition"

    # Pure config path setup (version-specific)
    if fork_version == "deneb":
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_deneb_configs"
        if not pure_configs_dir.exists():
            # Fallback to capella configs if deneb configs don't exist
            pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    else:  # capella
        pure_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    lighthouse_testnet_dir = pure_configs_dir / "lighthouse_testnet"

    # Coverage data directory setup (from paths)
    coverage_dirs = {}
    if enable_coverage:
        for client_name in ["prysm", "lighthouse", "teku", "nimbus", "lodestar"]:
            if client_name in paths and "cov_output" in paths[client_name]:
                coverage_dirs[client_name] = Path(paths[client_name]["cov_output"])
                coverage_dirs[client_name].mkdir(parents=True, exist_ok=True)
    
    # Client binary paths: use separate binaries in coverage mode (single binary supports both capella and deneb)
    if enable_coverage:
        prysm_binary = testing_clients_dir / "prysm" / "pcli-cov"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli-cov"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku-cov" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli-cov"
    else:
        prysm_binary = testing_clients_dir / "prysm" / "bazel-bin" / "tools" / "pcli" / "pcli_" / "pcli"
        lighthouse_binary = testing_clients_dir / "lighthouse" / "target" / "release" / "lcli"
        teku_binary = testing_clients_dir / "teku" / "build" / "install" / "teku" / "bin" / "teku"
        nimbus_binary = testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli"

    clients = [
        Clients(
            "Lodestar",
            "/usr/bin/node",
            [
                "--max-old-space-size=16384",
                str(lodestar_transition),
                "epoch-processing",
                f"--pre-state-path={state}",
                f"--epoch-processing-type={epoch_processing_type}",
                f"--post-state-output-path={paths['lodestar']['output']}",
                f"--fork-version={fork_version}",
            ]),
        Clients(
            "Lighthouse",
            str(lighthouse_binary),
            [
                "epoch-processing",
                "--epoch-processing-type", epoch_processing_type,
                "--pre-state-path", state,
                "--post-state-output-path", paths["lighthouse"]["output"],
                "--testnet-dir", str(lighthouse_testnet_dir),
            ]),
        Clients(
            "Prysm",
            str(prysm_binary),
            [
                "epoch-processing",
                f"--epoch-processing-type={epoch_processing_type}",
                f"--pre-state-path={state}",
                f"--post-state-output-path={paths['prysm']['output']}",
            ]),
        Clients(
            "Nimbus",
            str(nimbus_binary),
            [
                "epoch_processing",  # Nimbus uses underscore, not hyphen
                state,
                epoch_processing_type,
                paths["nimbus"]["output"],
            ]),
        Clients(
            "Teku",
            str(teku_binary),
            [
                "transition",
                "epoch-processing",
                epoch_processing_type,
                "--pre", state,
                "--post", paths["teku"]["output"],
                "--Xnetwork-altair-fork-epoch=0",
                "--Xnetwork-bellatrix-fork-epoch=0",
                "--Xnetwork-capella-fork-epoch=0",
                f"--Xnetwork-deneb-fork-epoch={'0' if fork_version == 'deneb' else '75520'}",
            ]),
    ]

    # Use the same client processing logic as process_clients
    for client in clients:
        try:
            start_time = perf_counter()
            
            print(f"\n[+] Running: {client.name}")

            if not client.available:
                raise FileNotFoundError(f"[X] Not available: {client.cmd_path}")

            client.state = state
            client.block = None  # No block for epoch-processing

            print(f"[+] Command: {client.cmd_path} {' '.join(str(arg) for arg in client.cmd_args)}")
            cmd = [str(client.cmd_path)] + [str(arg) for arg in client.cmd_args]

            # Setup coverage environment variables (same as process_clients)
            env = os.environ.copy()
            # Set FORK_VERSION environment variable for Nimbus
            if client.name == "Nimbus":
                env["FORK_VERSION"] = fork_version
            if enable_coverage:
                client_name_lower = client.name.lower()
                
                if client.name == "Prysm":
                    env["GOCOVERDIR"] = str(coverage_dirs["prysm"])
                    print(f"[+] Coverage enabled: GOCOVERDIR={env['GOCOVERDIR']}")
                
                elif client.name == "Lighthouse":
                    profile_file = coverage_dirs["lighthouse"] / f"lighthouse-cov-%p-%m.profraw"
                    env["LLVM_PROFILE_FILE"] = str(profile_file)
                    print(f"[+] Coverage enabled: LLVM_PROFILE_FILE={env['LLVM_PROFILE_FILE']}")
                
                elif client.name == "Teku":
                    jacoco_agent_path = testing_clients_dir / "jacoco" / "jacocoagent.jar"
                    jacoco_exec = coverage_dirs["teku"] / "teku-coverage.exec"
                    
                    if jacoco_agent_path.exists():
                        env["JAVA_OPTS"] = f"-javaagent:{jacoco_agent_path}=destfile={jacoco_exec}"
                        print(f"[+] Coverage enabled: JAVA_OPTS={env['JAVA_OPTS']}")
                    else:
                        print(f"[!] Warning: JaCoCo agent not found at {jacoco_agent_path}")
                
                elif client.name == "Nimbus":
                    nimbus_src = testing_clients_dir / "nimbus-eth2"
                    nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                    
                    if nimbus_gcda_dir.exists():
                        for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                            try:
                                gcda_file.unlink()
                            except:
                                pass
                    print(f"[+] Coverage enabled: gcov will auto-generate .gcda files in build directory")
                
                elif client.name == "Lodestar":
                    lodestar_dir = testing_clients_dir / "lodestar"
                    coverage_report_dir = coverage_dirs["lodestar"] / "report"
                    coverage_temp_dir = coverage_dirs["lodestar"]
                    coverage_report_dir.mkdir(parents=True, exist_ok=True)
                    coverage_temp_dir.mkdir(parents=True, exist_ok=True)
                    
                    original_cmd_path = str(client.cmd_path)
                    original_cmd_args = [str(arg) for arg in client.cmd_args]
                    
                    c8_args = [
                        "c8",
                        "--all",
                        "--reporter=text",
                        "--reporter=html",
                        f"--report-dir={coverage_report_dir}",
                        f"--temp-directory={coverage_temp_dir}",
                        "--exclude-node-modules=false",
                        "--extension=.js",
                        "--include=node_modules/@lodestar/**/*.js",
                        "--include=node_modules/@chainsafe/**/*.js",
                        "--exclude=**/transition.js",
                        "--exclude=**/generateCachedStateCapella.js",
                        original_cmd_path,
                    ] + original_cmd_args
                    
                    client.cmd_path = "npx"
                    client.cmd_args = c8_args
                    cmd = ["npx"] + c8_args
                    
                    print(f"[+] Coverage enabled: c8 with report-dir={coverage_report_dir}")

            # Set cwd (only for Lodestar coverage mode)
            if client.name == "Lodestar" and enable_coverage:
                cwd = str(testing_clients_dir / "lodestar")
            else:
                cwd = None

            process = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                cwd=cwd,
            )
            end_time = perf_counter()

            client.status_code = process.returncode
            client.output = process 
            client.timestamp = end_time - start_time
            
            print(f"[+] Execution time: {client.timestamp}")
            
            # Apply correct classification criteria
            if process.returncode == 0:
                client.status_code = 0  # SUCCESS
            elif process.returncode < 0:
                client.status_code = 2  # UNHANDLED_EXCEPTION
            else:
                client.status_code = 1  # FAIL
            
            # Lodestar special handling
            if client.name == "Lodestar":
                try:
                    if client.output.stderr != '':
                        try:
                            import json
                            json_start = client.output.stderr.find('{')
                            if json_start != -1:
                                json_end = client.output.stderr.rfind('}') + 1
                                if json_end > json_start:
                                    json_str = client.output.stderr[json_start:json_end]
                                    error_obj = json.loads(json_str)
                                    status_code = error_obj.get('statusCode', 1)
                                    output_string = error_obj.get('output', '')
                                    if status_code == 0:
                                        client.status_code = 0
                                    elif status_code < 0:
                                        client.status_code = 2
                                    else:
                                        client.status_code = 1
                                    client.output.stderr = output_string
                                    continue
                        except:
                            pass
                        
                        status_code_match = re.search(r"statusCode: \s*(\d+)", client.output.stderr)
                        if status_code_match:
                            status_code = int(status_code_match.group(1))
                            output_match = re.search(r"output: \s*'(.*?)'", client.output.stderr, re.DOTALL)
                            if output_match:
                                output_string = output_match.group(1)
                                if status_code == 0:
                                    client.status_code = 0
                                elif status_code < 0:
                                    client.status_code = 2
                                else:
                                    client.status_code = 1
                                client.output.stderr = output_string
                except Exception as e:
                    client.status_code = 2

            client.log()
            
            # Nimbus: Copy .gcda files for independent coverage per test case
            if client.name == "Nimbus" and enable_coverage:
                nimbus_src = testing_clients_dir / "nimbus-eth2"
                nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                nimbus_coverage_dir = coverage_dirs.get("nimbus")
                
                if nimbus_coverage_dir and nimbus_gcda_dir.exists():
                    target_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
                    target_gcda_dir.mkdir(parents=True, exist_ok=True)
                    
                    import shutil
                    for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                        relative_path = gcda_file.relative_to(nimbus_gcda_dir)
                        target_file = target_gcda_dir / relative_path
                        target_file.parent.mkdir(parents=True, exist_ok=True)
                        try:
                            shutil.copy2(gcda_file, target_file)
                        except Exception as e:
                            print(f"[!] Failed to copy .gcda file {gcda_file}: {e}")
                    print(f"[+] Copied .gcda files to {target_gcda_dir}")
            
            # Teku: Delete empty output files
            if client.name == "Teku" and client.status_code != 0:
                output_path = paths.get("teku", {}).get("output")
                if output_path and os.path.exists(output_path):
                    file_size = os.path.getsize(output_path)
                    if file_size == 0:
                        os.remove(output_path)
                        print(f"[+] Removed empty Teku output file: {output_path}")

        except Exception as e:
            end_time = perf_counter()
            client.timestamp = end_time - start_time
            
            if client.output is None:
                client.output = subprocess.CompletedProcess(args=cmd, returncode=2, stdout='', stderr=str(e))

            print(f"[+] Execution time: {client.timestamp}")
            print(f"[+] Exited with status code: {client.status_code} (Failure)")
            print(f"[+] {client.name} failed: {client.output.stderr}")
    return clients

def create_report(clients, output_dir):
    
    report_dir = Path(output_dir) #report_dir = Path(output_dir) / "reports"
    #report_dir.mkdir(parents=True, exist_ok=True)

    # title
    now = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    report_name = f"report_eth2diff_{now}.md"
    report_path = report_dir / report_name

    # body
    results = ""
    for client in clients:
        cmd = f"{client.cmd_path} {' '.join(str(arg) for arg in client.cmd_args)}"
        results += f"## {client.name}\n\n"
        results += f"### State: {client.state} \n###   Block: {client.block} \n\n"
        results += f"### Command\n\n```\n{cmd}\n```\n\n"
        results += f"### Time Spent: {client.timestamp}\n\n"
        results += f"### Status Code: {client.status_code}\n\n"
        if client.output:
            results += f"### STDOUT\n\n```\n{client.output.stdout.strip()}\n```\n\n"
            results += f"### LOG\n\n```\n{client.output.stderr.strip()}\n```\n\n"

    report_content = f"# Differential Testing Report\n\n{results}"

    with open(report_path, "w") as report_file:
        report_file.write(report_content)

    print(f"[+] Report saved at {report_path}")


def parse_prysm_output(output):

    lines = output.splitlines()
    parsed_lines = []
    for line in lines:
        if 'level=info' in line: # skips level=info, does not contain interesting message
            continue  
        parsed_lines.append(line.strip())
    return ' '.join(parsed_lines)


def parse_nimbus_output(output):

    ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]') # Erase ANSI characters
    output = ansi_escape.sub('', output)

    lines = output.strip().splitlines()
    if lines:
        return lines[-1].strip()
    else:
        return ''


def parse_teku_output(output):

    lines = output.strip().splitlines()
    parsed_lines = []

    timestamp_pattern = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')
    start_log = False

    for line in lines:
        if timestamp_pattern.match(line):
            if not start_log:
                continue  # Skip timestamped lines, do not contain interesting message
        else:
            start_log = True  # Start capturing once non-timestamped lines appear

        if start_log:
            
            # Skip debug messages (where the error occurred)
            if ' at ' in line:
                parsed_lines.append(line.split(' at ')[0].strip())
                break
            elif '\tat ' in line:
                parsed_lines.append(line.split('\tat ')[0].strip())
                break
            else:
                parsed_lines.append(line.strip())

    return ' '.join(parsed_lines)


def parse_output(client):

    if client.status_code == 0:
        return "SUCCESSFUL(RETURN POSTSTATE)"
    else:
        output = client.output.stdout + client.output.stderr

        if client.name == "Prysm":
            return parse_prysm_output(output)
        elif client.name == "Nimbus":
            return parse_nimbus_output(output)
        elif client.name == "Teku":
            return parse_teku_output(output)
        else:
            # For Lighthouse and Lodestar, return the raw output, no need for additional parsing
            return output.strip()


def create_csv_time(all_results, output_parent_dir):

    time_decimal_places = 4

    now = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    csv_file_path = Path(output_parent_dir) / f'Output_Time_{now}.csv'

    def _sort_key(item):
        idx = str(item['Pair #'])
        return (0, int(idx)) if idx.isdigit() else (1, idx.lower())

    all_results = sorted(all_results, key=_sort_key)
    fieldnames = _client_csv_fieldnames(all_results)
    client_columns = fieldnames[1:]

    total_times = defaultdict(float)
    for result in all_results:
        for client in client_columns:
            if client in result and isinstance(result[client], (int, float)):
                total_times[client] += result[client]

    total_row = {'Pair #': 'Total'}
    total_row.update({client: f"{total_times[client]:.{time_decimal_places}f}" for client in client_columns})

    with open(csv_file_path, mode='w', newline='', encoding='utf-8') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        for result in all_results:
            formatted_result = {
                key: f"{value:.{time_decimal_places}f}" if isinstance(value, (int, float)) else value
                for key, value in result.items()
            }
            writer.writerow(formatted_result)
        writer.writerow(total_row)

    print(f"[+] CSV log saved at {csv_file_path}")


def state_transition(state_dir, block_dir, output_parent_dir, spectec_core_dir=None, workflow="independent", enable_coverage=False, fork_version="capella"):
    """
    Args:
        spectec_core_dir: spectec-core directory path (used to find testing_clients path)
        workflow: "independent" (default) or "sequential" mode
        enable_coverage: Enable coverage measurement
    Returns:
        successful_clients_by_index: dict mapping index to list of successful client names
    """
    eth2_clients_results = []
    all_results = [] 
    all_times = []
    all_status  = []  
    successful_clients_by_index = {}

    if workflow == "sequential":
        # Sequential mode: pre -> blocks_0 -> postState_0 -> blocks_1 -> ...
        # Collect all blocks first
        block_pairs = list(parse_state_block(state_dir, block_dir, output_parent_dir, converter_dir=spectec_core_dir))
        
        if not block_pairs:
            return successful_clients_by_index
        
        # Store original pre state of first block
        initial_state, first_block, first_paths = block_pairs[0]
        current_state = initial_state
        
        for idx, (_, block, paths) in enumerate(block_pairs):
            block_file = os.path.basename(block)
            block_index = block_file.replace("blocks_", "").replace(".ssz", "")
            
            if idx == 0:
                print(f"[+] Processing pair (sequential): {current_state} and {block} (starting from initial pre)")
            else:
                prev_block_file = os.path.basename(block_pairs[idx-1][1])
                prev_index = prev_block_file.replace("blocks_", "").replace(".ssz", "")
                print(f"[+] Processing pair (sequential): {current_state} and {block} (using postState from block {prev_index})")
            
            eth2_clients = process_clients(current_state, block, paths, spectec_core_dir=spectec_core_dir, enable_coverage=enable_coverage, fork_version=fork_version)
            eth2_clients_results.extend(eth2_clients)
            print(f"\n\n")

            pair_results = {'Pair #': block_index, 
                            'Successful Transition': [], 
                            'Handled Exception': [], 
                            'Unhandled Errors': []
                            }
            pair_times = {'Pair #': block_index}
            pair_status = {'Pair #': block_index}
            
            for client in eth2_clients:
                parsed_log = parse_output(client)
                pair_results[client.name] = parsed_log
                labelled = f"{client.status_code}({STATUS_LABEL.get(client.status_code, 'UNKNOWN')})"
                pair_status[client.name] = labelled

                if(client.status_code == 0):
                    pair_results['Successful Transition'].append(client.name.lower())
                if(client.status_code == 1):
                    pair_results['Handled Exception'].append(client.name)
                if(client.status_code == 2):
                    pair_results['Unhandled Errors'].append(client.name)

                pair_times[client.name] = client.timestamp

            # Store successful clients for this index
            if pair_results['Successful Transition']:
                successful_clients_by_index[block_index] = pair_results['Successful Transition']

            all_results.append(pair_results)
            all_times.append(pair_times)
            all_status.append(pair_status)
            
            # Determine postState to use as pre for next block (select from successful clients)
            # All clients should produce the same result, so use the first successful client's output
            next_state = None
            for client in eth2_clients:
                # client.name starts with uppercase (e.g., "Lighthouse", "Prysm"), paths keys are lowercase
                client_key = client.name.lower()
                if client.status_code == 0 and client_key in paths and os.path.exists(paths[client_key]["output"]):
                    next_state = paths[client_key]["output"]
                    break
            
            if next_state is None:
                print(f"[!] No successful client output found for block {block_index}, stopping sequential execution")
                break
            
            current_state = next_state
    else:
        # Independent mode (default): process each block independently from original pre state
        for state, block, paths in parse_state_block(state_dir, block_dir, output_parent_dir, converter_dir=spectec_core_dir):
            print(f"[+] Processing pair: {state} and {block}")
            eth2_clients = process_clients(state, block, paths, spectec_core_dir=spectec_core_dir, enable_coverage=enable_coverage, fork_version=fork_version)
            eth2_clients_results.extend(eth2_clients)
            print(f"\n\n")

            # Extract index from state or block filename
            if state and "pre.ssz" in state:
                # For pre.ssz format, extract from block filename
                block_file = os.path.basename(block)
                index = block_file.replace("blocks_", "").replace(".ssz", "")
            elif state:
                # For state_*.ssz format
                index = state.split("_")[-1].split(".")[0]
            else:
                # Fallback: extract from block filename if state is None
                block_file = os.path.basename(block)
                index = block_file.replace("blocks_", "").replace(".ssz", "")
            
            pair_results = {'Pair #': index, 
                            'Successful Transition': [], 
                            'Handled Exception': [], 
                            'Unhandled Errors': []
                            }
            pair_times = {'Pair #': index}
            pair_status = {'Pair #': index}
            
            for client in eth2_clients:
                # Parse logs before storing in arrays (unnecessary portions hinder readability)
                parsed_log = parse_output(client)
                pair_results[client.name] = parsed_log
                labelled = f"{client.status_code}({STATUS_LABEL.get(client.status_code, 'UNKNOWN')})"
                pair_status[client.name] = labelled

                if(client.status_code == 0):
                    pair_results['Successful Transition'].append(client.name.lower())
                if(client.status_code == 1):
                    pair_results['Handled Exception'].append(client.name)
                if(client.status_code == 2):
                    pair_results['Unhandled Errors'].append(client.name)

                pair_times[client.name] = client.timestamp

            # Store successful clients for this index
            if pair_results['Successful Transition']:
                successful_clients_by_index[index] = pair_results['Successful Transition']

            all_results.append(pair_results)
            all_times.append(pair_times)
            all_status.append(pair_status) 

    # Store reports and CSV files
    create_report(eth2_clients_results, output_parent_dir)
    #print(all_results)
    create_csv_time(all_times, output_parent_dir)
    create_csv_status(all_status, output_parent_dir)
    
    # Note: _decompressed directory is kept for debugging/verification purposes
    # The decompressed .ssz files remain in _decompressed/ directory
    
    return successful_clients_by_index


def operation(test_case_dir, output_parent_dir, spectec_core_dir=None, enable_coverage=False, fork_version="capella"):
    """
    Execute operation tests.
    
    Args:
        test_case_dir: Test case directory containing pre.ssz and operation file
        output_parent_dir: Output directory
        spectec_core_dir: spectec-core directory path
        enable_coverage: Enable coverage measurement
    Returns:
        successful_clients_by_index: dict mapping index to list of successful client names
    """
    eth2_clients_results = []
    all_results = []
    all_times = []
    all_status = []
    successful_clients_by_index = {}
    
    for state, operation_path, operation_type, paths, execution_valid in parse_operation(test_case_dir, output_parent_dir, converter_dir=spectec_core_dir):
        print(f"[+] Processing operation: {state} + {operation_path} (type: {operation_type})")
        eth2_clients = process_clients_operation(state, operation_path, operation_type, paths, spectec_core_dir=spectec_core_dir, enable_coverage=enable_coverage, fork_version=fork_version, execution_valid=execution_valid)
        eth2_clients_results.extend(eth2_clients)
        print(f"\n\n")
        
        # Extract index from test case directory name
        test_case_name = os.path.basename(test_case_dir)
        
        pair_results = {
            'Pair #': test_case_name,
            'Successful Transition': [],
            'Handled Exception': [],
            'Unhandled Errors': []
        }
        pair_times = {'Pair #': test_case_name}
        pair_status = {'Pair #': test_case_name}
        
        for client in eth2_clients:
            parsed_log = parse_output(client)
            pair_results[client.name] = parsed_log
            labelled = f"{client.status_code}({STATUS_LABEL.get(client.status_code, 'UNKNOWN')})"
            pair_status[client.name] = labelled
            
            if client.status_code == 0:
                pair_results['Successful Transition'].append(client.name.lower())
            if client.status_code == 1:
                pair_results['Handled Exception'].append(client.name)
            if client.status_code == 2:
                pair_results['Unhandled Errors'].append(client.name)
            
            pair_times[client.name] = client.timestamp
        
        # Store successful clients
        if pair_results['Successful Transition']:
            successful_clients_by_index[test_case_name] = pair_results['Successful Transition']
        
        all_results.append(pair_results)
        all_times.append(pair_times)
        all_status.append(pair_status)
    
    # Store reports and CSV files
    create_report(eth2_clients_results, output_parent_dir)
    create_csv_time(all_times, output_parent_dir)
    create_csv_status(all_status, output_parent_dir)
    
    return successful_clients_by_index


def epoch_processing(test_case_dir, output_parent_dir, spectec_core_dir=None, enable_coverage=False, fork_version="capella"):
    """
    Execute epoch-processing tests.
    
    Args:
        test_case_dir: Test case directory containing pre.ssz
        output_parent_dir: Output directory
        spectec_core_dir: spectec-core directory path
        enable_coverage: Enable coverage measurement
    Returns:
        successful_clients_by_index: dict mapping index to list of successful client names
    """
    eth2_clients_results = []
    all_results = []
    all_times = []
    all_status = []
    successful_clients_by_index = {}
    
    for state, epoch_processing_type, paths in parse_epoch_processing(test_case_dir, output_parent_dir, converter_dir=spectec_core_dir):
        print(f"[+] Processing epoch-processing: {state} (type: {epoch_processing_type})")
        eth2_clients = process_clients_epoch_processing(state, epoch_processing_type, paths, spectec_core_dir=spectec_core_dir, enable_coverage=enable_coverage, fork_version=fork_version)
        eth2_clients_results.extend(eth2_clients)
        print(f"\n\n")
        
        # Extract index from test case directory name
        test_case_name = os.path.basename(test_case_dir)
        
        pair_results = {
            'Pair #': test_case_name,
            'Successful Transition': [],
            'Handled Exception': [],
            'Unhandled Errors': []
        }
        pair_times = {'Pair #': test_case_name}
        pair_status = {'Pair #': test_case_name}
        
        for client in eth2_clients:
            parsed_log = parse_output(client)
            pair_results[client.name] = parsed_log
            labelled = f"{client.status_code}({STATUS_LABEL.get(client.status_code, 'UNKNOWN')})"
            pair_status[client.name] = labelled
            
            if client.status_code == 0:
                pair_results['Successful Transition'].append(client.name.lower())
            if client.status_code == 1:
                pair_results['Handled Exception'].append(client.name)
            if client.status_code == 2:
                pair_results['Unhandled Errors'].append(client.name)
            
            pair_times[client.name] = client.timestamp
        
        # Store successful clients
        if pair_results['Successful Transition']:
            successful_clients_by_index[test_case_name] = pair_results['Successful Transition']
        
        all_results.append(pair_results)
        all_times.append(pair_times)
        all_status.append(pair_status)
    
    # Store reports and CSV files
    create_report(eth2_clients_results, output_parent_dir)
    create_csv_time(all_times, output_parent_dir)
    create_csv_status(all_status, output_parent_dir)
    
    return successful_clients_by_index


def sanity_slots(test_case_dir, output_parent_dir, spectec_core_dir=None, enable_coverage=False, fork_version="capella"):
    """
    Execute sanity-slots tests.
    
    Args:
        test_case_dir: Test case directory containing pre.ssz and slots.yaml
        output_parent_dir: Output directory
        spectec_core_dir: spectec-core directory path
        enable_coverage: Enable coverage measurement
    Returns:
        successful_clients_by_index: dict mapping index to list of successful client names
    """
    eth2_clients_results = []
    all_results = []
    all_times = []
    all_status = []
    successful_clients_by_index = {}
    
    for state, slot_value, paths in parse_sanity_slots(test_case_dir, output_parent_dir, converter_dir=spectec_core_dir):
        print(f"[+] Processing sanity-slots: {state} (slot: {slot_value})")
        eth2_clients = process_clients_sanity_slots(state, slot_value, paths, spectec_core_dir=spectec_core_dir, enable_coverage=enable_coverage, fork_version=fork_version)
        eth2_clients_results.extend(eth2_clients)
        print(f"\n\n")
        
        # Extract index from test case directory name
        test_case_name = os.path.basename(test_case_dir)
        
        pair_results = {
            'Pair #': test_case_name,
            'Successful Transition': [],
            'Handled Exception': [],
            'Unhandled Errors': []
        }
        pair_times = {'Pair #': test_case_name}
        pair_status = {'Pair #': test_case_name}
        
        for client in eth2_clients:
            parsed_log = parse_output(client)
            pair_results[client.name] = parsed_log
            labelled = f"{client.status_code}({STATUS_LABEL.get(client.status_code, 'UNKNOWN')})"
            pair_status[client.name] = labelled
            
            if client.status_code == 0:
                pair_results['Successful Transition'].append(client.name.lower())
            if client.status_code == 1:
                pair_results['Handled Exception'].append(client.name)
            if client.status_code == 2:
                pair_results['Unhandled Errors'].append(client.name)
            
            pair_times[client.name] = client.timestamp
        
        # Store successful clients
        if pair_results['Successful Transition']:
            successful_clients_by_index[test_case_name] = pair_results['Successful Transition']
        
        all_results.append(pair_results)
        all_times.append(pair_times)
        all_status.append(pair_status)
    
    # Store reports and CSV files
    create_report(eth2_clients_results, output_parent_dir)
    create_csv_time(all_times, output_parent_dir)
    create_csv_status(all_status, output_parent_dir)
    
    return successful_clients_by_index

#################################################################################

MAX_ERROR_MSG_LEN = 3000

def truncate_error_msg(msg, max_len=MAX_ERROR_MSG_LEN):
    if len(msg) > max_len:
        return msg[:max_len] + '... (truncated)'
    return msg

def create_csv_differences(differences_results, output_parent_dir):
    """
    Save SSZ file comparison differences to a CSV file.
    
    Parameters:
    - differences_results: List of dictionaries containing comparison results.
    - output_parent_dir: Path to save the CSV file.
    """
    now = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    csv_file_path = Path(output_parent_dir) / f'Differences_{now}.csv'
    fieldnames = ['Index', 'Differences']

    with open(csv_file_path, mode='w', newline='', encoding='utf-8') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for result in differences_results:
            writer.writerow(result)

    print(f"[+] CSV differences log saved at {csv_file_path}")

def create_csv_status(all_status, output_parent_dir):
    
    now = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    csv_file_path = Path(output_parent_dir) / f'Output_Status_{now}.csv'

    def _sort_key(item):
        idx = str(item['Pair #'])
        return (0, int(idx)) if idx.isdigit() else (1, idx.lower())

    all_status = sorted(all_status, key=_sort_key)
    fieldnames = _client_csv_fieldnames(all_status)

    with open(csv_file_path, mode='w', newline='', encoding='utf-8') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for row in all_status:
            writer.writerow(row)

    print(f"[+] CSV status log saved at {csv_file_path}")


# Function to read binary content of a file
def read_binary_file(file_path):
    with open(file_path, 'rb') as file:
        return file.read()

# Compare SSZ files across clients and save results to CSV
def compare_ssz_files_in_output(output_parent_dir, successful_clients_by_index=None):
    """
    Compare SSZ files across clients. Only compares postState files from successful clients.
    
    Parameters:
    - output_parent_dir: Directory containing client output directories
    - successful_clients_by_index: Dict mapping index to list of successful client names.
                                  If None, compares all existing files (backward compatibility).
    """
    tools = STATE_TRANSITION_TOOLS
    output_dirs = {tool: os.path.join(output_parent_dir, tool, "output") for tool in tools}

    # Get all indices from the output directories
    indices = set()
    for tool, output_dir in output_dirs.items():
        if os.path.exists(output_dir):
            for file in os.listdir(output_dir):
                if file.startswith("poststate_") and file.endswith(".ssz"):
                    # Extract index: remove "poststate_" prefix and ".ssz" suffix
                    # e.g., "poststate_effective_balance_hysteresis.ssz" -> "effective_balance_hysteresis"
                    index = file.replace("poststate_", "").replace(".ssz", "")
                    indices.add(index)

    # Prepare the results for CSV
    results = []

    # Compare files for each index
    for index in sorted(indices):
        print(f"\nComparing SSZ files for index {index}:")
        client_files = {}
        
        # Determine which clients to compare for this index
        if successful_clients_by_index and index in successful_clients_by_index:
            clients_to_check = successful_clients_by_index[index]
        else:
            # Backward compatibility: check all clients if no success info provided
            clients_to_check = tools

        # Gather files for the current index (only from successful clients)
        for tool in clients_to_check:
            output_dir = output_dirs.get(tool)
            if not output_dir or not os.path.exists(output_dir):
                continue
            file_path = os.path.join(output_dir, f"poststate_{index}.ssz")
            if os.path.exists(file_path):
                file_size = os.path.getsize(file_path)
                # Skip empty files (shouldn't happen for successful clients, but safety check)
                if file_size > 0:
                    client_files[tool] = read_binary_file(file_path)
                else:
                    print(f"[!] Empty file for client {tool}: {file_path}")
            else:
                print(f"[!] File not found for client {tool}: {file_path}")

        # Compare files (only among successful clients)
        differences = []
        clients = list(client_files.keys())
        
        if len(clients) < 2:
            # Need at least 2 successful clients to compare
            if len(clients) == 0:
                differences.append("No successful clients")
            elif len(clients) == 1:
                differences.append(f"Only {clients[0]} succeeded")
        else:
            for i in range(len(clients)):
                for j in range(i + 1, len(clients)):
                    client_a = clients[i]
                    client_b = clients[j]
                    if client_files[client_a] != client_files[client_b]:
                        differences.append(f"{client_a} vs {client_b}")

        # Store results
        results.append({
            "Index": index,
            "Differences": ", ".join(differences) if differences else "None"
        })

    # Save results to CSV
    create_csv_differences(results, output_parent_dir)

def generate_coverage_reports_per_testcase(output_dir, spectec_core_dir, cleanup_after_report=False):
    """
    Generate HTML coverage reports by analyzing coverage data per test case.
    Creates reports for each independent cov_output_{index} directory per block/state index.
    
    Args:
        output_dir: Test case output directory (e.g., node_result_mutated_case_insight_with_log/invalid_all_zeroed_sig)
        spectec_core_dir: spectec-core directory path
        cleanup_after_report: Delete original coverage data after generating reports
    """
    output_path = Path(output_dir)
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    
    print(f"\n{'='*60}")
    print(f"Generating Coverage Reports for: {output_path.name}")
    print(f"{'='*60}\n")
    
    # Find and process cov_output_* directories for each client
    clients = BASE_CLIENT_TOOLS + ["eth2spec"]
    
    for client in clients:
        client_dir = output_path / client
        if not client_dir.exists():
            continue
        
        # Find directories matching cov_output_{index} pattern
        cov_dirs = sorted([d for d in client_dir.iterdir() if d.is_dir() and d.name.startswith("cov_output_")])
        
        if not cov_dirs:
            continue
        
        print(f"\n[+] Processing {client.capitalize()} coverage ({len(cov_dirs)} test case(s))...")
        
        for cov_dir in cov_dirs:
            index = cov_dir.name.replace("cov_output_", "")
            print(f"  - Generating report for index {index}...")
            
            if client == "prysm":
                _generate_prysm_report(cov_dir, testing_clients_dir)
            elif client == "lighthouse":
                _generate_lighthouse_report(cov_dir, testing_clients_dir)
            elif client == "teku":
                _generate_teku_report(cov_dir, testing_clients_dir)
            elif client == "nimbus":
                _generate_nimbus_report(cov_dir, testing_clients_dir)
            elif client == "lodestar":
                _generate_lodestar_report(cov_dir, testing_clients_dir)
            elif client == "eth2spec":
                _generate_eth2spec_report(cov_dir, testing_clients_dir)
            
            # Delete original data after report generation (optional)
            if cleanup_after_report:
                _cleanup_coverage_data(cov_dir, client)
    
    print(f"\n{'='*60}")
    print(f"Coverage reports saved in: {output_path}")
    print(f"{'='*60}\n")


def _generate_prysm_report(prysm_coverage_dir, testing_clients_dir):
    """Generate Prysm (Go) coverage report"""
    if not prysm_coverage_dir.exists():
        return
    
    # Check if coverage data files exist
    cov_files = list(prysm_coverage_dir.glob("covcounters.*"))
    if not cov_files:
        return
    
    prysm_report_dir = prysm_coverage_dir / "report"
    prysm_report_dir.mkdir(exist_ok=True)
    prysm_dir = testing_clients_dir / "prysm"
    
    try:
        # Convert to text format using go tool covdata textfmt
        coverage_txt_raw = prysm_report_dir / "coverage_raw.txt"
        subprocess.run(
            ["go", "tool", "covdata", "textfmt", f"-i={prysm_coverage_dir}", f"-o={coverage_txt_raw}"],
            check=True,
            capture_output=True,
            text=True
        )
        
        # Filter to keep only core state-transition packages
        # This is done AFTER merging original coverage data, matching Lighthouse/TeKu/Nimbus approach
        coverage_txt = prysm_report_dir / "coverage.txt"
        _filter_prysm_coverage_txt(coverage_txt_raw, coverage_txt)
        
        # Generate HTML report using go tool cover (run from Prysm directory)
        coverage_html = prysm_report_dir / "coverage.html"
        # Calculate relative paths from Prysm directory
        rel_coverage_txt = Path(os.path.relpath(coverage_txt, prysm_dir))
        rel_coverage_html = Path(os.path.relpath(coverage_html, prysm_dir))
        
        subprocess.run(
            ["go", "tool", "cover", f"-html={rel_coverage_txt}", f"-o={rel_coverage_html}"],
            check=True,
            capture_output=True,
            text=True,
            cwd=str(prysm_dir)  # Run from Prysm directory (go.mod required)
        )
        
        # Generate branch coverage report using go-bcov
        import shutil
        # Try to find go-bcov: first in PATH, then in GOPATH/bin
        go_bcov = shutil.which("go-bcov")
        if not go_bcov:
            # Try to find in GOPATH/bin
            try:
                go_path_result = subprocess.run(
                    ["go", "env", "GOPATH"],
                    capture_output=True,
                    text=True,
                    check=True
                )
                gopath = go_path_result.stdout.strip()
                if gopath:
                    go_bcov_candidate = Path(gopath) / "bin" / "go-bcov"
                    if go_bcov_candidate.exists():
                        go_bcov = str(go_bcov_candidate)
            except (subprocess.CalledProcessError, FileNotFoundError):
                pass
        
        # Also try $HOME/go/bin/go-bcov as fallback
        if not go_bcov:
            home_go_bin = Path.home() / "go" / "bin" / "go-bcov"
            if home_go_bin.exists():
                go_bcov = str(home_go_bin)
        
        coverage_xml = None
        branch_coverage_stats = None
        
        if go_bcov:
            try:
                coverage_xml = prysm_report_dir / "coverage_bcov.xml"
                with open(coverage_txt, "rb") as fin, open(coverage_xml, "wb") as fout:
                    subprocess.run(
                        [go_bcov, "-format", "sonar-cover-report"],
                        stdin=fin,
                        stdout=fout,
                        stderr=subprocess.PIPE,  # Capture stderr for error messages
                        check=True,
                        cwd=str(prysm_dir)  # Source AST parsing/package loading requires repo root
                    )
                print(f"    ✓ Branch coverage report: {coverage_xml}")
                
                # Parse XML to extract branch coverage statistics
                branch_coverage_stats = _parse_bcov_xml(coverage_xml)
            except subprocess.CalledProcessError as e:
                print(f"    ⚠ go-bcov failed: {e}")
                if e.stderr:
                    print(f"    ℹ Error: {e.stderr}")
            except FileNotFoundError:
                print(f"    ⚠ go-bcov not found in PATH")
        else:
            print(f"    ⚠ go-bcov not found in PATH. Install: go install github.com/alx99/go-bcov@v1")
        
        # Calculate overall coverage statistics and add to HTML (including branch coverage)
        _add_prysm_coverage_stats(coverage_txt, coverage_html, prysm_dir, prysm_coverage_dir, branch_coverage_stats)
        
        print(f"    ✓ Report: {prysm_report_dir / 'coverage.html'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")


def _parse_bcov_xml(xml_path):
    """Parse go-bcov XML to extract branch coverage statistics
    
    Returns:
        dict with keys: 'total_branches', 'covered_branches', 'branch_coverage_pct'
        or None if parsing fails
    """
    try:
        import xml.etree.ElementTree as ET
        
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        # SonarQube generic coverage report format
        # <coverage version="...">
        #   <file path="...">
        #     <lineToCover lineNumber="..." covered="true/false" branchesToCover="..." coveredBranches="..."/>
        #   </file>
        # </coverage>
        
        total_branches = 0
        covered_branches = 0
        
        for file_elem in root.findall('.//file'):
            for line_elem in file_elem.findall('.//lineToCover'):
                branches_to_cover = line_elem.get('branchesToCover')
                covered_branches_attr = line_elem.get('coveredBranches')
                
                if branches_to_cover:
                    try:
                        branches = int(branches_to_cover)
                        total_branches += branches
                        
                        if covered_branches_attr:
                            covered = int(covered_branches_attr)
                            covered_branches += covered
                    except (ValueError, TypeError):
                        pass
        
        branch_coverage_pct = 0.0
        if total_branches > 0:
            branch_coverage_pct = (covered_branches / total_branches) * 100.0
        
        return {
            'total_branches': total_branches,
            'covered_branches': covered_branches,
            'branch_coverage_pct': branch_coverage_pct
        }
    except Exception as e:
        print(f"    ⚠ Failed to parse go-bcov XML: {e}")
        return None


def _add_prysm_coverage_stats(coverage_txt, coverage_html, prysm_dir, prysm_coverage_dir, branch_coverage_stats=None):
    """Add overall statistics to Prysm HTML report (including branch coverage if available)"""
    try:
        # Collect package statistics using go tool covdata percent
        # Use absolute path for coverage directory to avoid path resolution issues
        abs_coverage_dir = Path(prysm_coverage_dir).resolve()
        result = subprocess.run(
            ["go", "tool", "covdata", "percent", f"-i={abs_coverage_dir}"],
            cwd=str(prysm_dir),
            capture_output=True,
            text=True,
            check=True
        )
        
        # Parse package statistics
        # Format: "package_name    coverage: XX.X% of statements"
        package_stats = []
        for line in result.stdout.strip().split('\n'):
            if 'coverage:' in line:
                parts = line.split()
                package = parts[0].strip()
                coverage = parts[-3]  # "XX.X%" (parts[-2] is "of", parts[-1] is "statements")
                package_stats.append((package, coverage))
        
        # Calculate overall statement coverage using go tool cover -func
        # Use absolute path for coverage.txt to avoid path resolution issues
        abs_coverage_txt = Path(coverage_txt).resolve()
        func_result = subprocess.run(
            ["go", "tool", "cover", f"-func={abs_coverage_txt}"],
            cwd=str(prysm_dir),
            capture_output=True,
            text=True,
            check=True
        )
        
        # Extract "total: (statements) XX.X%" from last line
        total_coverage = 0.0
        lines = func_result.stdout.strip().split('\n')
        if lines:
            last_line = lines[-1]
            if last_line.startswith('total:'):
                # Format: "total: (statements) 11.3%"
                coverage_str = last_line.split()[-1].rstrip('%')
                total_coverage = float(coverage_str)
        
        # Add statistics box to HTML
        with open(coverage_html, 'r') as f:
            html_content = f.read()
        
        # Check if statistics already exist (avoid duplicate insertion)
        if 'Overall Statement Coverage' in html_content:
            # Statistics already added, skip
            return
        
        # Generate statistics box HTML
        branch_info = ""
        if branch_coverage_stats:
            branch_pct = branch_coverage_stats['branch_coverage_pct']
            covered = branch_coverage_stats['covered_branches']
            total = branch_coverage_stats['total_branches']
            branch_info = f'''
        <div style="background:#2d8659;color:#fff;padding:20px;margin:20px;border-radius:5px;">
            <h2 style="margin:0 0 10px 0;">Overall Branch Coverage (go-bcov derived): {branch_pct:.1f}%</h2>
            <div style="font-size:14px;">
                Covered: {covered}/{total} branches (calculated by go-bcov from AST analysis)
            </div>
            <div style="font-size:12px;margin-top:5px;opacity:0.9;">
                Note: This is syntactic branch coverage (if/switch) derived from AST parsing, not Go-native branch coverage.
            </div>
        </div>
        '''
        
        stats_html = f'''
        <div style="background:#375eab;color:#fff;padding:20px;margin:20px;border-radius:5px;">
            <h2 style="margin:0 0 10px 0;">Overall Statement Coverage: {total_coverage:.1f}%</h2>
            <div style="font-size:14px;">
                (Calculated by Go official tool: go tool cover -func)
            </div>
        </div>
        {branch_info}
        <div style="margin:20px;max-height:300px;overflow-y:auto;border:1px solid #ccc;padding:10px;border-radius:5px;">
            <h3>Package Coverage</h3>
            <table style="width:100%;border-collapse:collapse;">
                <tr style="background:#f0f0f0;font-weight:bold;">
                    <td style="padding:5px;border-bottom:1px solid #ccc;">Package</td>
                    <td style="padding:5px;border-bottom:1px solid #ccc;text-align:right;">Coverage</td>
                </tr>
        '''
        
        for package, coverage in package_stats:
            stats_html += f'''
                <tr>
                    <td style="padding:5px;border-bottom:1px solid #eee;font-family:monospace;font-size:11px;">{package}</td>
                    <td style="padding:5px;border-bottom:1px solid #eee;text-align:right;">{coverage}</td>
                </tr>
            '''
        
        stats_html += '''
            </table>
        </div>
        '''
        
        # Insert statistics box after <div id="content">
        html_content = html_content.replace(
            '<div id="content">',
            f'<div id="content">{stats_html}'
        )
        
        with open(coverage_html, 'w') as f:
            f.write(html_content)
            
    except Exception as e:
        print(f"    ⚠ Could not add statistics: {e}")


def _generate_lighthouse_report(lighthouse_coverage_dir, testing_clients_dir):
    """Generate Lighthouse (Rust) coverage report using llvm-cov
    
    Rust source-based coverage provides the following metrics:
    - Region Coverage: conditional branch coverage (if/match etc.)
    - Function Coverage: function call status
    - Instantiation Coverage: generic/macro instances
    - Line Coverage: line execution status
    
    Note: "Branches" column always shows 0/0 (LLVM IR branches are not collected).
          Conditional branches are measured as "Region Coverage".
    """
    if not lighthouse_coverage_dir.exists():
        return
    
    # Check if .profraw files exist
    profraw_files = list(lighthouse_coverage_dir.glob("*.profraw"))
    if not profraw_files:
        return
    
    lighthouse_report_dir = lighthouse_coverage_dir / "report"
    lighthouse_report_dir.mkdir(exist_ok=True)
    lighthouse_src = testing_clients_dir / "lighthouse"
    lighthouse_binary = lighthouse_src / "target" / "release" / "lcli-cov"
    
    try:
        # Find Rust toolchain llvm-tools path
        rustc_result = subprocess.run(
            ["rustc", "--print", "sysroot"],
            capture_output=True,
            text=True,
            check=True
        )
        sysroot = Path(rustc_result.stdout.strip())
        llvm_tools_dir = sysroot / "lib" / "rustlib" / "x86_64-unknown-linux-gnu" / "bin"
        llvm_profdata = llvm_tools_dir / "llvm-profdata"
        llvm_cov = llvm_tools_dir / "llvm-cov"
        
        if not llvm_profdata.exists() or not llvm_cov.exists():
            print(f"    ✗ llvm-tools not found. Install with: rustup component add llvm-tools-preview")
            return
        
        # 1. Convert profraw to profdata
        profdata_file = lighthouse_report_dir / "lighthouse.profdata"
        subprocess.run(
            [
                str(llvm_profdata), "merge", "-sparse",
                *[str(f) for f in profraw_files],
                "-o", str(profdata_file)
            ],
            check=True,
            capture_output=True,
            text=True
        )
        
        # 2. Generate HTML report with branch coverage
        html_dir = lighthouse_report_dir / "html"
        html_dir.mkdir(exist_ok=True)
        cmd_show = [
            str(llvm_cov), "show",
            str(lighthouse_binary),
            f"--instr-profile={profdata_file}",
            "--format=html",
            f"--output-dir={html_dir}",
            "--show-line-counts-or-regions",
            "--show-branches=count",  # Show branch coverage with execution counts
            "--show-instantiations"
        ]
        # Add each exclude pattern separately
        for pattern in LIGHTHOUSE_CORE_IGNORE_PATTERNS:
            cmd_show.extend(["--ignore-filename-regex", pattern])
        
        subprocess.run(
            cmd_show,
            check=True,
            capture_output=True,
            text=True
        )
        
        # 3. Generate text summary with branch coverage
        summary_file = lighthouse_report_dir / "summary.txt"
        cmd_report = [
            str(llvm_cov), "report",
            str(lighthouse_binary),
            f"--instr-profile={profdata_file}",
            "--show-branch-summary",  # Show branch condition statistics in summary table
            "--show-instantiation-summary"
        ]
        # Add each exclude pattern separately
        for pattern in LIGHTHOUSE_CORE_IGNORE_PATTERNS:
            cmd_report.extend(["--ignore-filename-regex", pattern])
        
        result = subprocess.run(
            cmd_report,
            capture_output=True,
            text=True,
            check=True
        )
        with open(summary_file, 'w') as f:
            f.write(result.stdout)
        
        print(f"    ✓ Report: {html_dir / 'index.html'}")
        print(f"    ✓ Summary: {summary_file}")
        
        # Remove .profraw files remaining in testing_clients/lighthouse/ after report generation
        lighthouse_root_profraw_files = list(lighthouse_src.glob("*.profraw"))
        if lighthouse_root_profraw_files:
            for profraw_file in lighthouse_root_profraw_files:
                try:
                    profraw_file.unlink()
                    print(f"    ✓ Removed original profraw file: {profraw_file.name}")
                except Exception as e:
                    print(f"    ⚠ Warning: Failed to remove {profraw_file.name}: {e}")
        
    except FileNotFoundError as e:
        print(f"    ✗ Tool not found: {e}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")



def _generate_teku_report(teku_coverage_dir, testing_clients_dir):
    """Generate Teku (Java) coverage report"""
    teku_exec = teku_coverage_dir / "teku-coverage.exec"
    if not teku_exec.exists():
        return

    teku_report_dir = teku_coverage_dir / "report"
    teku_report_dir.mkdir(exist_ok=True)

    try:
        if not _generate_teku_filtered_report_from_exec(teku_exec, teku_report_dir, testing_clients_dir):
            return
        print(f"    ✓ Report: {teku_report_dir / 'index.html'}")
        print(f"    ✓ CSV: {teku_report_dir / 'coverage.csv'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")


def _collect_teku_report_inputs(testing_clients_dir):
    """Collect Teku JaCoCo inputs shared by all report-generation modes."""
    jacoco_cli = testing_clients_dir / "jacoco" / "jacococli.jar"
    if not jacoco_cli.exists():
        print(f"    ✗ JaCoCo CLI not found at {jacoco_cli}")
        return None

    teku_lib_dir = testing_clients_dir / "teku" / "build" / "install" / "teku-cov" / "lib"
    teku_jars = sorted(teku_lib_dir.glob("teku-*.jar"))
    if not teku_jars:
        print(f"    ✗ No Teku jar files found in {teku_lib_dir}")
        return None

    classfiles_args = []
    for jar in teku_jars:
        classfiles_args.extend(["--classfiles", str(jar)])

    teku_root = testing_clients_dir / "teku"
    teku_source_roots = sorted(src_dir for src_dir in teku_root.rglob("src/main/java") if src_dir.is_dir())
    if not teku_source_roots:
        print("    ⚠ Warning: No Teku source directories found; source-level drill-down may be incomplete")

    sourcefiles_args = []
    for src_dir in teku_source_roots:
        sourcefiles_args.extend(["--sourcefiles", str(src_dir)])

    return {
        "jacoco_cli": jacoco_cli,
        "classfiles_args": classfiles_args,
        "sourcefiles_args": sourcefiles_args,
        "teku_source_roots": teku_source_roots,
    }


def _generate_teku_filtered_report_from_exec(exec_file, report_dir, testing_clients_dir):
    """Generate filtered Teku XML, HTML, and CSV reports from one exec file."""
    report_inputs = _collect_teku_report_inputs(testing_clients_dir)
    if report_inputs is None:
        return False

    report_dir.mkdir(parents=True, exist_ok=True)

    xml_report = report_dir / "coverage.xml"
    subprocess.run(
        [
            "java", "-jar", str(report_inputs["jacoco_cli"]),
            "report", str(exec_file),
        ] + report_inputs["classfiles_args"] + report_inputs["sourcefiles_args"] + [
            "--xml", str(xml_report)
        ],
        check=True,
        capture_output=True,
        text=True
    )

    filtered_xml = report_dir / "coverage_filtered.xml"
    _filter_teku_xml_report(xml_report, filtered_xml)
    _generate_teku_html_from_filtered_xml(filtered_xml, report_dir, report_inputs["teku_source_roots"])
    _generate_teku_csv_from_filtered_xml(filtered_xml, report_dir / "coverage.csv")
    return True


def _filter_nimbus_lcov_report(lcov_input, lcov_output, nimbus_src):
    """Filter Nimbus lcov coverage.info file to keep only core state-transition packages
    
    This function filters the lcov report by keeping only files that start with
    one of the NIMBUS_CORE_INCLUDE_PREFIXES. This is done AFTER merging original
    coverage data, matching the Lighthouse/TeKu approach.
    """
    try:
        output_lines = []
        current_record = []
        current_file = None
        should_include = False
        included_count = 0
        excluded_count = 0
        
        nimbus_src_str = str(nimbus_src)
        
        with open(lcov_input, 'r') as f:
            for line in f:
                if line.startswith('SF:'):
                    # Start of a new file record
                    # Save previous record if it should be included
                    if current_file is not None and should_include:
                        output_lines.extend(current_record)
                        output_lines.append('end_of_record\n')
                        included_count += 1
                    elif current_file is not None:
                        excluded_count += 1
                    
                    # Start new record
                    current_record = [line]
                    current_file = line[3:].strip()
                    
                    # Check if file should be included
                    # Extract relative path (remove absolute prefix if exists)
                    rel_path = current_file
                    
                    # Normalize path separators
                    rel_path = rel_path.replace('\\', '/')
                    
                    # Try to extract relative path from nimbus_src
                    if nimbus_src_str in current_file:
                        # Extract path relative to nimbus_src
                        idx = current_file.find(nimbus_src_str)
                        if idx != -1:
                            rel_path = current_file[idx + len(nimbus_src_str):].lstrip('/')
                    elif '/nimbus-eth2/' in current_file:
                        # Fallback: try to extract after nimbus-eth2
                        parts = current_file.split('/nimbus-eth2/')
                        if len(parts) > 1:
                            rel_path = parts[-1]
                    
                    # Exclude system paths
                    if current_file.startswith('/usr/') or current_file.startswith('/nimbus-eth2/') or '/usr/' in current_file:
                        should_include = False
                    else:
                        # Check if path starts with one of the included prefixes
                        should_include = any(rel_path.startswith(prefix) for prefix in NIMBUS_CORE_INCLUDE_PREFIXES)
                
                elif line.startswith('end_of_record'):
                    # End of current record
                    if should_include:
                        output_lines.extend(current_record)
                        output_lines.append(line)
                        included_count += 1
                    else:
                        excluded_count += 1
                    current_record = []
                    current_file = None
                    should_include = False
                
                else:
                    # Part of current record
                    if current_file is not None:
                        current_record.append(line)
        
        # Handle last record if file doesn't end with end_of_record
        if current_file is not None:
            if should_include:
                output_lines.extend(current_record)
                output_lines.append('end_of_record\n')
                included_count += 1
            else:
                excluded_count += 1
        
        # Check if we have any valid records
        if not output_lines:
            print(f"    ⚠ Warning: Filtered lcov file is empty (included: {included_count}, excluded: {excluded_count})")
            print(f"    ℹ This might indicate that no files matched the inclusion criteria")
            print(f"    ℹ Inclusion prefixes: {NIMBUS_CORE_INCLUDE_PREFIXES}")
            # Don't create empty file - genhtml will fail
            # Instead, create a minimal valid lcov file with a dummy record
            output_lines = [
                "TN:\n",
                "SF:dummy\n",
                "FN:1,dummy\n",
                "FNDA:0,dummy\n",
                "FNF:1\n",
                "FNH:0\n",
                "end_of_record\n"
            ]
            print(f"    ⚠ Created minimal lcov file to prevent genhtml error")
        
        # Write filtered lcov file
        with open(lcov_output, 'w') as f:
            f.writelines(output_lines)
        
        if included_count > 0:
            print(f"    ℹ Filtered lcov: {included_count} files included, {excluded_count} files excluded")
        
    except Exception as e:
        print(f"    ⚠ Warning: Failed to filter Nimbus lcov report: {e}")
        import traceback
        traceback.print_exc()
        # Fallback: copy original lcov file
        import shutil
        shutil.copy2(lcov_input, lcov_output)


def _filter_teku_xml_report(xml_input, xml_output):
    """Filter Teku JaCoCo XML report to keep only core state-transition packages
    
    This function filters the XML report by keeping only packages that start with
    one of the TEKU_CORE_INCLUDE_PREFIXES. This is done AFTER merging original
    coverage data, matching the Nimbus/Lighthouse approach.
    
    IMPORTANT: After filtering packages, we must recalculate root-level counters
    by summing counters from remaining packages. Root-level counters represent
    the total, so they must be updated to reflect only filtered packages.
    """
    import xml.etree.ElementTree as ET
    
    try:
        tree = ET.parse(xml_input)
        root = tree.getroot()
        
        # Find all package elements and collect ones to remove
        packages_to_remove = []
        for package in root.findall(".//package"):
            package_name = package.get("name", "")
            
            # Check if package should be included
            should_include = any(package_name.startswith(prefix) for prefix in TEKU_CORE_INCLUDE_PREFIXES)
            
            if not should_include:
                packages_to_remove.append(package)
        
        # Remove excluded packages (packages are direct children of root in JaCoCo XML)
        for package in packages_to_remove:
            root.remove(package)
        
        # Recalculate root-level counters from remaining packages
        # Root-level counters must reflect only the filtered packages
        total_instructions_missed = 0
        total_instructions_covered = 0
        total_branches_missed = 0
        total_branches_covered = 0
        total_lines_missed = 0
        total_lines_covered = 0
        
        # Sum counters from all remaining packages
        for package in root.findall("package"):
            # Find package-level counters (direct children of package)
            for counter in package.findall("counter"):
                counter_type = counter.get("type")
                missed = int(counter.get("missed", 0))
                covered = int(counter.get("covered", 0))
                
                if counter_type == "INSTRUCTION":
                    total_instructions_missed += missed
                    total_instructions_covered += covered
                elif counter_type == "BRANCH":
                    total_branches_missed += missed
                    total_branches_covered += covered
                elif counter_type == "LINE":
                    total_lines_missed += missed
                    total_lines_covered += covered
        
        # Remove existing root-level counters
        for counter in root.findall("counter"):
            root.remove(counter)
        
        # Add updated root-level counters
        if total_instructions_missed > 0 or total_instructions_covered > 0:
            counter_elem = ET.Element("counter", type="INSTRUCTION", 
                                     missed=str(total_instructions_missed),
                                     covered=str(total_instructions_covered))
            root.insert(0, counter_elem)
        
        if total_branches_missed > 0 or total_branches_covered > 0:
            counter_elem = ET.Element("counter", type="BRANCH",
                                     missed=str(total_branches_missed),
                                     covered=str(total_branches_covered))
            root.insert(1, counter_elem)
        
        if total_lines_missed > 0 or total_lines_covered > 0:
            counter_elem = ET.Element("counter", type="LINE",
                                     missed=str(total_lines_missed),
                                     covered=str(total_lines_covered))
            root.insert(2, counter_elem)
        
        # Write filtered XML
        tree.write(xml_output, encoding="UTF-8", xml_declaration=True)
        
    except Exception as e:
        print(f"    ⚠ Warning: Failed to filter Teku XML report: {e}")
        import traceback
        traceback.print_exc()
        # Fallback: copy original XML
        import shutil
        shutil.copy2(xml_input, xml_output)




def _teku_counter_map(element):
    """Return direct-child JaCoCo counters keyed by type."""
    counters = {}
    for counter in element.findall("counter"):
        counters[counter.get("type", "")] = (
            int(counter.get("missed", 0)),
            int(counter.get("covered", 0)),
        )
    return counters


def _teku_counter_triplet(counter_map, counter_type):
    missed, covered = counter_map.get(counter_type, (0, 0))
    return missed, covered, missed + covered


def _teku_percent(covered, total):
    if total <= 0:
        return "n/a"
    return f"{(covered / total) * 100.0:.1f}%"


def _teku_display_counter(counter_map, counter_type):
    missed, covered, total = _teku_counter_triplet(counter_map, counter_type)
    if total == 0:
        return "0/0 (n/a)"
    return f"{covered}/{total} ({_teku_percent(covered, total)})"


def _teku_row_class(counter_map):
    _, covered, total = _teku_counter_triplet(counter_map, "LINE")
    if total == 0:
        return "teku-na"
    if covered == 0:
        return "teku-bad"
    if covered == total:
        return "teku-good"
    return "teku-mid"


def _teku_package_dir(package_name):
    return Path(package_name) if package_name else Path("default-package")


def _teku_package_label(package_name):
    return package_name if package_name else "(default package)"


def _teku_source_page_name(source_name):
    return f"{source_name}.html"


def _teku_source_rel_path(package_name, source_name):
    if package_name:
        return (Path(package_name) / source_name).as_posix()
    return Path(source_name).as_posix()


def _teku_rel_link(target_path, current_path):
    return Path(os.path.relpath(target_path, start=current_path.parent)).as_posix()


def _build_teku_source_lookup(teku_source_roots):
    lookup = {}
    for src_root in teku_source_roots:
        for java_file in src_root.rglob("*.java"):
            rel_path = java_file.relative_to(src_root).as_posix()
            lookup.setdefault(rel_path, java_file)
    return lookup


def _teku_report_css():
    return """
body { font-family: Arial, sans-serif; margin: 24px; color: #222; }
a { color: #0b57d0; text-decoration: none; }
a:hover { text-decoration: underline; }
.breadcrumbs { margin-bottom: 18px; font-size: 14px; }
.summary { display: flex; gap: 12px; flex-wrap: wrap; margin: 18px 0 24px; }
.card { border: 1px solid #d0d7de; border-radius: 8px; padding: 12px 14px; min-width: 180px; background: #f8fafc; }
.card h2 { margin: 0 0 8px; font-size: 14px; }
.card .value { font-size: 20px; font-weight: bold; }
.note { margin: 18px 0; padding: 12px 14px; border-left: 4px solid #b7791f; background: #fff7e6; }
table.coverage { width: 100%; border-collapse: collapse; margin-top: 12px; }
table.coverage th, table.coverage td { border: 1px solid #d0d7de; padding: 8px 10px; vertical-align: top; }
table.coverage th { background: #f6f8fa; text-align: left; }
tr.teku-good { background: #edf7ed; }
tr.teku-mid { background: #fff8db; }
tr.teku-bad { background: #fdecec; }
tr.teku-na { background: #f6f8fa; }
.src-table { width: 100%; border-collapse: collapse; margin-top: 16px; }
.src-table th, .src-table td { border: 1px solid #e5e7eb; padding: 0; }
.src-table th { padding: 8px 10px; background: #f6f8fa; text-align: left; }
.src-line-no { width: 72px; text-align: right; padding: 0 10px; color: #6a737d; background: #f6f8fa; }
.src-counter { width: 110px; text-align: right; padding: 0 10px; white-space: nowrap; }
.src-code { font-family: monospace; white-space: pre; padding: 0 10px; }
tr.src-full td { background: #edf7ed; }
tr.src-partial td { background: #fff8db; }
tr.src-missed td { background: #fdecec; }
tr.src-none td { background: #ffffff; }
.footer { margin-top: 24px; color: #6a737d; font-size: 12px; }
"""


def _teku_render_page(title, breadcrumbs, body_html):
    breadcrumb_html = " / ".join(
        f"<a href='{href}'>{html.escape(label)}</a>" if href else html.escape(label)
        for label, href in breadcrumbs
    )
    return f"""<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>
    <title>{html.escape(title)}</title>
    <style type="text/css">{_teku_report_css()}</style>
</head>
<body>
    <div class="breadcrumbs">{breadcrumb_html}</div>
    <h1>{html.escape(title)}</h1>
    {body_html}
    <div class="footer">Generated from filtered JaCoCo XML report (core Teku state-transition scope).</div>
</body>
</html>
"""


def _teku_source_line_class(line_data):
    if line_data is None:
        return "src-none"
    if line_data["ci"] == 0 and line_data["cb"] == 0:
        return "src-missed"
    if line_data["mi"] > 0 or line_data["mb"] > 0:
        return "src-partial"
    return "src-full"


def _write_teku_package_index(package_data, root_index_path):
    package_index_path = package_data["package_index_path"]
    rows = []
    missing_sources = 0
    for source_data in package_data["sourcefiles"]:
        if source_data["source_path"] is None:
            missing_sources += 1
        row_class = _teku_row_class(source_data["counters"])
        href = html.escape(_teku_rel_link(source_data["page_path"], package_index_path))
        label = html.escape(source_data["name"])
        instructions = html.escape(_teku_display_counter(source_data["counters"], "INSTRUCTION"))
        branches = html.escape(_teku_display_counter(source_data["counters"], "BRANCH"))
        lines = html.escape(_teku_display_counter(source_data["counters"], "LINE"))
        rows.append(
            f"<tr class='{row_class}'><td><a href='{href}'>{label}</a></td>"
            f"<td>{instructions}</td><td>{branches}</td><td>{lines}</td></tr>"
        )

    note_html = ""
    if missing_sources:
        note_html = (
            f'<div class="note">{missing_sources} source file(s) could not be resolved on disk. '
            'Coverage counters are still shown, but those files may not include highlighted source text.</div>'
        )

    empty_row = '<tr><td colspan="4">No source files in filtered package.</td></tr>'
    body_html = (
        '<div class="summary">'
        f'<div class="card"><h2>Source Files</h2><div class="value">{len(package_data["sourcefiles"])}</div></div>'
        f'<div class="card"><h2>Instructions</h2><div class="value">{html.escape(_teku_display_counter(package_data["counters"], "INSTRUCTION"))}</div></div>'
        f'<div class="card"><h2>Branches</h2><div class="value">{html.escape(_teku_display_counter(package_data["counters"], "BRANCH"))}</div></div>'
        f'<div class="card"><h2>Lines</h2><div class="value">{html.escape(_teku_display_counter(package_data["counters"], "LINE"))}</div></div>'
        '</div>'
        + note_html +
        '<table class="coverage">'
        '<thead><tr><th>Source File</th><th>Instructions</th><th>Branches</th><th>Lines</th></tr></thead>'
        f'<tbody>{"".join(rows) or empty_row}</tbody>'
        '</table>'
    )

    page_html = _teku_render_page(
        f'Teku Coverage: {_teku_package_label(package_data["name"])}',
        [
            ("Teku Coverage", html.escape(_teku_rel_link(root_index_path, package_index_path))),
            (_teku_package_label(package_data["name"]), None),
        ],
        body_html,
    )
    with open(package_index_path, 'w', encoding='utf-8') as f:
        f.write(page_html)


def _write_teku_source_file_report(package_data, source_data, root_index_path):
    page_path = source_data["page_path"]
    package_index_path = package_data["package_index_path"]
    source_lines = []
    if source_data["source_path"] is not None and source_data["source_path"].exists():
        source_lines = source_data["source_path"].read_text(encoding='utf-8', errors='replace').splitlines()

    max_line_no = max(len(source_lines), max(source_data["line_map"], default=0))
    line_rows = []
    for line_number in range(1, max_line_no + 1):
        line_data = source_data["line_map"].get(line_number)
        instr_text = "-"
        branch_text = "-"
        if line_data is not None:
            instr_total = line_data["mi"] + line_data["ci"]
            instr_text = f'{line_data["ci"]}/{instr_total}' if instr_total else '0/0'
            branch_total = line_data["mb"] + line_data["cb"]
            branch_text = '-' if branch_total == 0 else f'{line_data["cb"]}/{branch_total}'
        source_text = source_lines[line_number - 1] if line_number <= len(source_lines) else ""
        source_text = source_text.replace("	", "    ")
        row_class = _teku_source_line_class(line_data)
        line_rows.append(
            f"<tr class='{row_class}'><td class='src-line-no'>{line_number}</td>"
            f"<td class='src-counter'>{html.escape(instr_text)}</td>"
            f"<td class='src-counter'>{html.escape(branch_text)}</td>"
            f"<td class='src-code'>{html.escape(source_text)}</td></tr>"
        )

    if source_data["source_path"] is None:
        note_html = (
            '<div class="note">Source file could not be resolved from the Teku source tree. '
            'This page still shows line counters extracted from JaCoCo XML.</div>'
        )
    else:
        note_html = f'<div class="note">Source path: {html.escape(str(source_data["source_path"]))}</div>'

    empty_row = '<tr><td colspan="4">No line coverage data available.</td></tr>'
    body_html = (
        '<div class="summary">'
        f'<div class="card"><h2>Instructions</h2><div class="value">{html.escape(_teku_display_counter(source_data["counters"], "INSTRUCTION"))}</div></div>'
        f'<div class="card"><h2>Branches</h2><div class="value">{html.escape(_teku_display_counter(source_data["counters"], "BRANCH"))}</div></div>'
        f'<div class="card"><h2>Lines</h2><div class="value">{html.escape(_teku_display_counter(source_data["counters"], "LINE"))}</div></div>'
        '</div>'
        + note_html +
        '<table class="src-table">'
        '<thead><tr><th>Line</th><th>Instructions</th><th>Branches</th><th>Source</th></tr></thead>'
        f'<tbody>{"".join(line_rows) or empty_row}</tbody>'
        '</table>'
    )

    page_html = _teku_render_page(
        f'Teku Coverage: {_teku_package_label(package_data["name"])} / {source_data["name"]}',
        [
            ("Teku Coverage", html.escape(_teku_rel_link(root_index_path, page_path))),
            (_teku_package_label(package_data["name"]), html.escape(_teku_rel_link(package_index_path, page_path))),
            (source_data["name"], None),
        ],
        body_html,
    )
    with open(page_path, 'w', encoding='utf-8') as f:
        f.write(page_html)


def _generate_teku_html_from_filtered_xml(filtered_xml, output_dir, teku_source_roots):
    """Generate root, package, and source-file HTML pages from filtered JaCoCo XML."""
    import xml.etree.ElementTree as ET

    try:
        tree = ET.parse(filtered_xml)
        root = tree.getroot()
        source_lookup = _build_teku_source_lookup(teku_source_roots)
        root_index_path = output_dir / "index.html"

        packages = []
        for package in sorted(root.findall("package"), key=lambda elem: elem.get("name", "")):
            package_name = package.get("name", "")
            package_dir = output_dir / _teku_package_dir(package_name)
            package_dir.mkdir(parents=True, exist_ok=True)
            package_index_path = package_dir / "index.html"

            sourcefiles = []
            for source_elem in sorted(package.findall("sourcefile"), key=lambda elem: elem.get("name", "")):
                source_name = source_elem.get("name", "")
                source_page_path = package_dir / _teku_source_page_name(source_name)
                source_rel_path = _teku_source_rel_path(package_name, source_name)
                line_map = {}
                for line in source_elem.findall("line"):
                    line_number = int(line.get("nr", 0))
                    line_map[line_number] = {
                        "mi": int(line.get("mi", 0)),
                        "ci": int(line.get("ci", 0)),
                        "mb": int(line.get("mb", 0)),
                        "cb": int(line.get("cb", 0)),
                    }
                sourcefiles.append(
                    {
                        "name": source_name,
                        "page_path": source_page_path,
                        "source_path": source_lookup.get(source_rel_path),
                        "line_map": line_map,
                        "counters": _teku_counter_map(source_elem),
                    }
                )

            package_data = {
                "name": package_name,
                "package_index_path": package_index_path,
                "sourcefiles": sourcefiles,
                "counters": _teku_counter_map(package),
            }
            packages.append(package_data)

        for package_data in packages:
            _write_teku_package_index(package_data, root_index_path)
            for source_data in package_data["sourcefiles"]:
                _write_teku_source_file_report(package_data, source_data, root_index_path)

        root_rows = []
        for package_data in packages:
            row_class = _teku_row_class(package_data["counters"])
            href = html.escape(_teku_rel_link(package_data["package_index_path"], root_index_path))
            label = html.escape(_teku_package_label(package_data["name"]))
            instructions = html.escape(_teku_display_counter(package_data["counters"], "INSTRUCTION"))
            branches = html.escape(_teku_display_counter(package_data["counters"], "BRANCH"))
            lines = html.escape(_teku_display_counter(package_data["counters"], "LINE"))
            root_rows.append(
                f"<tr class='{row_class}'><td><a href='{href}'>{label}</a></td>"
                f"<td>{len(package_data['sourcefiles'])}</td><td>{instructions}</td><td>{branches}</td><td>{lines}</td></tr>"
            )

        root_counters = _teku_counter_map(root)
        empty_row = '<tr><td colspan="5">No packages matched the Teku filter scope.</td></tr>'
        body_html = (
            '<div class="summary">'
            f'<div class="card"><h2>Packages</h2><div class="value">{len(packages)}</div></div>'
            f'<div class="card"><h2>Instructions</h2><div class="value">{html.escape(_teku_display_counter(root_counters, "INSTRUCTION"))}</div></div>'
            f'<div class="card"><h2>Branches</h2><div class="value">{html.escape(_teku_display_counter(root_counters, "BRANCH"))}</div></div>'
            f'<div class="card"><h2>Lines</h2><div class="value">{html.escape(_teku_display_counter(root_counters, "LINE"))}</div></div>'
            '</div>'
            '<table class="coverage">'
            '<thead><tr><th>Package</th><th>Source Files</th><th>Instructions</th><th>Branches</th><th>Lines</th></tr></thead>'
            f'<tbody>{"".join(root_rows) or empty_row}</tbody>'
            '</table>'
        )

        page_html = _teku_render_page(
            'Teku Coverage Report (Filtered - Core State-Transition Only)',
            [("Teku Coverage", None)],
            body_html,
        )
        with open(root_index_path, 'w', encoding='utf-8') as f:
            f.write(page_html)

    except Exception as e:
        print(f"    ⚠ Warning: Failed to generate HTML from filtered XML: {e}")
        import traceback
        traceback.print_exc()


def _generate_teku_csv_from_filtered_xml(filtered_xml, csv_file):
    """Generate CSV report from filtered JaCoCo XML file"""
    import xml.etree.ElementTree as ET
    import csv
    
    try:
        tree = ET.parse(filtered_xml)
        root = tree.getroot()
        
        with open(csv_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(['Package', 'Class', 'Instructions Missed', 'Instructions Covered', 'Branches Missed', 'Branches Covered', 'Lines Missed', 'Lines Covered'])
            
            for package in root.findall(".//package"):
                pkg_name = package.get("name", "")
                
                for class_elem in package.findall(".//class"):
                    class_name = class_elem.get("name", "")
                    
                    # Get counters for this class
                    instructions_missed = 0
                    instructions_covered = 0
                    branches_missed = 0
                    branches_covered = 0
                    lines_missed = 0
                    lines_covered = 0
                    
                    for counter in class_elem.findall(".//counter[@type='INSTRUCTION']"):
                        instructions_missed += int(counter.get("missed", 0))
                        instructions_covered += int(counter.get("covered", 0))
                    
                    for counter in class_elem.findall(".//counter[@type='BRANCH']"):
                        branches_missed += int(counter.get("missed", 0))
                        branches_covered += int(counter.get("covered", 0))
                    
                    for counter in class_elem.findall(".//counter[@type='LINE']"):
                        lines_missed += int(counter.get("missed", 0))
                        lines_covered += int(counter.get("covered", 0))
                    
                    writer.writerow([
                        pkg_name,
                        class_name,
                        instructions_missed,
                        instructions_covered,
                        branches_missed,
                        branches_covered,
                        lines_missed,
                        lines_covered
                    ])
        
    except Exception as e:
        print(f"    ⚠ Warning: Failed to generate CSV from filtered XML: {e}")
        import traceback
        traceback.print_exc()


def _filter_prysm_coverage_txt(coverage_txt_input, coverage_txt_output):
    """Filter Prysm Go coverage.txt file to keep only core state-transition packages
    
    This function filters the Go coverage.txt report by keeping only files that belong to
    one of the PRYSM_CORE_INCLUDE_PREFIXES. This is done AFTER merging original
    coverage data, matching the Lighthouse/TeKu/Nimbus approach.
    
    Go coverage.txt format:
    mode: set
    github.com/OffchainLabs/prysm/v7/beacon-chain/core/blocks.go:10.118,12.15 2 0
    """
    try:
        output_lines = []
        
        with open(coverage_txt_input, 'r') as f:
            for line in f:
                # Keep mode line
                if line.startswith('mode:'):
                    output_lines.append(line)
                    continue
                
                # Skip empty lines
                if line.strip() == '':
                    continue
                
                # Parse coverage line: path.go:start.end,start.end statements covered
                # Example: github.com/OffchainLabs/prysm/v7/beacon-chain/core/blocks.go:10.118,12.15 2 0
                parts = line.split()
                if len(parts) >= 3:
                    file_path = parts[0]
                    
                    # Extract package path (everything before the last /)
                    if ':' in file_path:
                        file_path_only = file_path.split(':')[0]
                        if '/' in file_path_only:
                            # Check if file belongs to an included package
                            should_include = False
                            
                            # Special handling for config/params (exclude config/features)
                            if file_path_only.startswith("github.com/OffchainLabs/prysm/v7/config/params"):
                                should_include = True
                            elif file_path_only.startswith("github.com/OffchainLabs/prysm/v7/config/features"):
                                should_include = False
                            else:
                                # Check if path starts with any included prefix
                                should_include = any(file_path_only.startswith(prefix) for prefix in PRYSM_CORE_INCLUDE_PREFIXES)
                            
                            if should_include:
                                output_lines.append(line)
        
        # Write filtered coverage.txt file
        with open(coverage_txt_output, 'w') as f:
            f.writelines(output_lines)
        
    except Exception as e:
        print(f"    ⚠ Warning: Failed to filter Prysm coverage.txt: {e}")
        # Fallback: copy original coverage.txt
        import shutil
        shutil.copy2(coverage_txt_input, coverage_txt_output)


def _generate_nimbus_report(nimbus_coverage_dir, testing_clients_dir):
    """Generate Nimbus (Nim/C with gcov) coverage report
    Uses .gcda files from cov_output_{index} directory for independent coverage per test case
    """
    nimbus_src = testing_clients_dir / "nimbus-eth2"
    if not nimbus_src.exists():
        return
    
    nimbus_report_dir = nimbus_coverage_dir / "report"
    nimbus_report_dir.mkdir(parents=True, exist_ok=True)
    
    # Check if copied .gcda files exist in cov_output_{index} directory
    nimbus_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
    
    try:
        # Check lcov command
        subprocess.run(["lcov", "--version"], check=True, capture_output=True)
        
        # Collect coverage information using lcov
        coverage_info = nimbus_report_dir / "coverage.info"
        
        # Use cov_output_{index} directory if .gcda files exist, otherwise use original nimcache (backward compatibility)
        nimbus_cov_nimcache_root = nimbus_coverage_dir / "nimcache"
        if nimbus_cov_nimcache_root.exists() and any(nimbus_cov_nimcache_root.rglob("*.gcda")):
            # If copied .gcda files exist: use .gcda from this directory and .gcno from original nimcache
            # .gcno files are generated at compile time, so reference from original nimcache for consistent measurement scope
            # .gcda files differ per test case, so use from cov_output_{index}
            capture_dir = nimbus_cov_nimcache_root
            original_nimcache = nimbus_src / "nimcache"
            
            import shutil
            
            # Clear capture_dir completely before report generation to remove residual .gcno files
            # This ensures each report uses exactly the same .gcno set for fixed LOC
            # .gcda files are already in capture_dir, so backup and restore
            gcda_backup = {}
            if capture_dir.exists():
                # Backup .gcda files (execution data for each test case)
                for gcda_file in capture_dir.rglob("*.gcda"):
                    relative_path = gcda_file.relative_to(nimbus_cov_nimcache_root)
                    gcda_backup[relative_path] = gcda_file.read_bytes()
                
                # Delete capture_dir (remove all files to start clean)
                shutil.rmtree(capture_dir, ignore_errors=True)
            
            capture_dir.mkdir(parents=True, exist_ok=True)
            
            # Copy all .gcno files from original nimcache to capture_dir (overwrite unconditionally)
            # .gcno and .gcda relative paths must match for lcov to match correctly
            if original_nimcache.exists():
                # Copy all .gcno files (relative path: debug/ncli/.../*.gcno)
                for gcno_file in original_nimcache.rglob("*.gcno"):
                    relative_path = gcno_file.relative_to(original_nimcache)
                    target_gcno = capture_dir / relative_path
                    target_gcno.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(gcno_file, target_gcno)
            
            # Restore backed up .gcda files (relative path: debug/ncli/.../*.gcda)
            # This ensures .gcno and .gcda are in the same relative path for accurate lcov matching
            for relative_path, gcda_data in gcda_backup.items():
                target_gcda = capture_dir / relative_path
                target_gcda.parent.mkdir(parents=True, exist_ok=True)
                target_gcda.write_bytes(gcda_data)
            
            subprocess.run(
                [
                    "lcov", "--capture",
                    "--directory", str(capture_dir),
                    "--base-directory", str(nimbus_src),
                    "--output-file", str(coverage_info),
                    "--rc", "lcov_branch_coverage=1"  # Enable branch coverage collection
                ],
                check=True,
                capture_output=True,
                text=True
            )
        else:
            # Legacy method: scan entire nimbus_src
            subprocess.run(
                [
                    "lcov", "--capture",
                    "--directory", str(nimbus_src),
                    "--output-file", str(coverage_info),
                    "--rc", "lcov_branch_coverage=1"  # Enable branch coverage collection
                ],
                check=True,
                capture_output=True,
                text=True
            )
        
        # Filter to keep only core state-transition packages (beacon_chain/, ncli/)
        # This is done AFTER merging original coverage data, matching Lighthouse/TeKu approach
        coverage_clean = nimbus_report_dir / "coverage_clean.info"
        _filter_nimbus_lcov_report(coverage_info, coverage_clean, nimbus_src)
        
        # Generate HTML report using genhtml (using filtered coverage_clean.info)
        # Enable branch coverage display with --branch-coverage option
        subprocess.run(
            [
                "genhtml", str(coverage_clean),
                "--output-directory", str(nimbus_report_dir),
                "--branch-coverage"
            ],
            check=True,
            capture_output=True,
            text=True
        )
        print(f"    ✓ Report: {nimbus_report_dir / 'index.html'}")
    except FileNotFoundError:
        print(f"    ✗ lcov/genhtml not found. Install with: apt-get install lcov")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")


def _generate_lodestar_report(lodestar_coverage_dir, testing_clients_dir):
    """Generate Lodestar (Node.js) coverage report using c8
    
    c8 generates reports at runtime, but if the report is empty or not properly generated,
    regenerate the report using JSON files from temp-directory.
    """
    if not lodestar_coverage_dir.exists():
        return
    
    lodestar_dir = testing_clients_dir / "lodestar"
    lodestar_report_dir = lodestar_coverage_dir / "report"
    lodestar_temp_dir = lodestar_coverage_dir  # JSON file storage location
    
    # Check if coverage JSON files exist in temp-directory
    coverage_json_files = list(lodestar_temp_dir.glob("coverage-*.json"))
    if not coverage_json_files:
        print(f"    ✗ No coverage JSON files found in {lodestar_temp_dir}")
        return
    
    # Check if HTML report already exists
    html_index = lodestar_report_dir / "index.html"
    needs_regeneration = False
    
    if html_index.exists():
        # Check if report is empty (Unknown% or 0/0 cases)
        try:
            with open(html_index, 'r') as f:
                content = f.read()
                if 'Unknown%' in content or '0/0' in content:
                    needs_regeneration = True
                    print(f"    ℹ Existing report is empty, regenerating...")
        except:
            needs_regeneration = True
    else:
        needs_regeneration = True
        lodestar_report_dir.mkdir(parents=True, exist_ok=True)
    
    # Regenerate report if needed
    if needs_regeneration:
        try:
            # Regenerate report using c8 report command
            # Read JSON files from temp-directory to generate report
            # Increase Node.js memory limit for large JSON file processing
            env = os.environ.copy()
            env["NODE_OPTIONS"] = "--max-old-space-size=16384"  # 8GB heap size
            subprocess.run(
                [
                    "npx", "c8", "report",
                    "--merge-async",
                    f"--temp-directory={lodestar_temp_dir}",
                    "--reporter=html",
                    "--reporter=text",
                    f"--report-dir={lodestar_report_dir}",
                    "--exclude-node-modules=false",
                    "--extension=.js",
                    "--include=node_modules/@lodestar/**/*.js",
                    "--include=node_modules/@chainsafe/**/*.js",
                    "--exclude=**/transition.js",
                    "--exclude=**/generateCachedStateCapella.js",
                ],
                cwd=str(lodestar_dir),
                env=env,
                check=True,
                capture_output=True,
                text=True
            )
            print(f"    ✓ Report regenerated: {html_index}")
        except subprocess.CalledProcessError as e:
            print(f"    ✗ Failed to regenerate report: {e}")
            if e.stderr:
                print(f"    ℹ Error: {e.stderr}")
            return
    
    # Final report check and statistics output
    if html_index.exists():
        print(f"    ✓ Report: {html_index}")
        
        # Check coverage-summary.json
        summary_json = lodestar_report_dir / "coverage-summary.json"
        if summary_json.exists():
            try:
                import json
                with open(summary_json, 'r') as f:
                    summary = json.load(f)
                    # Output overall statistics
                    if 'total' in summary:
                        total = summary['total']
                        lines_pct = total.get('lines', {}).get('pct', 0)
                        statements_pct = total.get('statements', {}).get('pct', 0)
                        functions_pct = total.get('functions', {}).get('pct', 0)
                        branches_pct = total.get('branches', {}).get('pct', 0)
                        print(f"    ℹ Coverage Summary:")
                        print(f"       Lines: {lines_pct:.1f}%")
                        print(f"       Statements: {statements_pct:.1f}%")
                        print(f"       Functions: {functions_pct:.1f}%")
                        print(f"       Branches: {branches_pct:.1f}%")
            except Exception as e:
                print(f"    ⚠ Could not read coverage summary: {e}")
    else:
        print(f"    ✗ HTML report not found: {html_index}")
        print(f"    ℹ Check if coverage JSON files contain actual file paths (not just node:internal/*)")

def _write_eth2spec_coverage_reports(coverage_data_file, report_dir):
    """Generate text, HTML, and JSON coverage artifacts for eth2spec."""
    report_dir.mkdir(parents=True, exist_ok=True)
    html_dir = report_dir / "html"
    html_dir.mkdir(parents=True, exist_ok=True)

    try:
        report_result = subprocess.run(
            [
                sys.executable,
                "-m",
                "coverage",
                "report",
                "--data-file",
                str(coverage_data_file),
                "-m",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        (report_dir / "report.txt").write_text(report_result.stdout, encoding="utf-8")

        subprocess.run(
            [
                sys.executable,
                "-m",
                "coverage",
                "html",
                "--data-file",
                str(coverage_data_file),
                "-d",
                str(html_dir),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        subprocess.run(
            [
                sys.executable,
                "-m",
                "coverage",
                "json",
                "--data-file",
                str(coverage_data_file),
                "--pretty-print",
                "-o",
                str(report_dir / "coverage.json"),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        print(f"    ✓ Report: {report_dir / 'report.txt'}")
        print(f"    ✓ HTML: {html_dir / 'index.html'}")
        print(f"    ✓ JSON: {report_dir / 'coverage.json'}")
    except FileNotFoundError:
        print("    ✗ coverage.py not found. Install with: pip install coverage")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")



def _generate_eth2spec_report(eth2spec_coverage_dir, testing_clients_dir):
    """Generate eth2spec (Python) coverage report."""
    coverage_file = eth2spec_coverage_dir / ".coverage"
    if not coverage_file.exists():
        return
    _write_eth2spec_coverage_reports(coverage_file, eth2spec_coverage_dir / "report")



def _merge_eth2spec_coverage(cov_dirs, output_dir, testing_clients_dir):
    """Merge eth2spec coverage data from multiple test cases."""
    coverage_files = [cov_dir / ".coverage" for cov_dir in cov_dirs if (cov_dir / ".coverage").exists()]
    if not coverage_files:
        print("    ✗ No eth2spec coverage data files found")
        return

    merged_cov_dir = output_dir / "merged_coverage"
    merged_cov_dir.mkdir(exist_ok=True)
    merged_data_file = merged_cov_dir / ".coverage"

    try:
        subprocess.run(
            [
                sys.executable,
                "-m",
                "coverage",
                "combine",
                "--keep",
                "--data-file",
                str(merged_data_file),
            ] + [str(file) for file in coverage_files],
            check=True,
            capture_output=True,
            text=True,
        )
        _write_eth2spec_coverage_reports(merged_data_file, output_dir / "report")
    except FileNotFoundError:
        print("    ✗ coverage.py not found. Install with: pip install coverage")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")



def _merge_final_eth2spec_coverage(merged_coverage_dirs, output_dir, testing_clients_dir):
    """Merge eth2spec coverage data from multiple test suites."""
    coverage_files = [merged_dir / ".coverage" for merged_dir in merged_coverage_dirs if (merged_dir / ".coverage").exists()]
    if not coverage_files:
        print("    ✗ No merged eth2spec coverage data files found")
        return

    final_merged_cov_dir = output_dir / "merged_coverage"
    final_merged_cov_dir.mkdir(exist_ok=True)
    final_merged_data = final_merged_cov_dir / ".coverage"

    try:
        subprocess.run(
            [
                sys.executable,
                "-m",
                "coverage",
                "combine",
                "--keep",
                "--data-file",
                str(final_merged_data),
            ] + [str(file) for file in coverage_files],
            check=True,
            capture_output=True,
            text=True,
        )
        _write_eth2spec_coverage_reports(final_merged_data, output_dir / "report")
    except FileNotFoundError:
        print("    ✗ coverage.py not found. Install with: pip install coverage")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def generate_accumulated_coverage_report(output_base_dir, spectec_core_dir, cleanup_after_report=False):
    """
    Generate accumulated coverage report for entire test suite.
    Collects coverage data from all test cases and merges them into a single report per client.
    
    Args:
        output_base_dir: Base output directory (e.g., node_sanity_slots)
        spectec_core_dir: spectec-core directory path
        cleanup_after_report: Delete original coverage data after generating reports
    """
    output_base_path = Path(output_base_dir)
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    
    print(f"\n{'='*60}")
    print(f"Generating Accumulated Coverage Reports")
    print(f"{'='*60}\n")
    
    # Create total-node-coverage directory
    total_coverage_dir = output_base_path / "total-node-coverage"
    total_coverage_dir.mkdir(exist_ok=True)
    
    clients = BASE_CLIENT_TOOLS + ["eth2spec"]
    
    for client in clients:
        print(f"\n[+] Processing accumulated {client.capitalize()} coverage...")
        
        # Find all test case directories
        test_case_dirs = [d for d in output_base_path.iterdir() if d.is_dir() and not d.name.startswith("total-node-coverage")]
        
        # Collect all coverage data directories for this client
        client_cov_dirs = []
        for test_case_dir in test_case_dirs:
            client_dir = test_case_dir / client
            if client_dir.exists():
                cov_dirs = sorted([d for d in client_dir.iterdir() if d.is_dir() and d.name.startswith("cov_output_")])
                client_cov_dirs.extend(cov_dirs)
        
        if not client_cov_dirs:
            print(f"  ⚠ No coverage data found for {client}")
            continue
        
        print(f"  ℹ Found {len(client_cov_dirs)} test case(s) with coverage data")
        
        # Create client-specific output directory
        client_output_dir = total_coverage_dir / client
        client_output_dir.mkdir(exist_ok=True)
        
        # Merge and generate report based on client type
        if client == "prysm":
            _merge_prysm_coverage(client_cov_dirs, client_output_dir, testing_clients_dir)
        elif client == "lighthouse":
            _merge_lighthouse_coverage(client_cov_dirs, client_output_dir, testing_clients_dir)
        elif client == "teku":
            _merge_teku_coverage(client_cov_dirs, client_output_dir, testing_clients_dir)
        elif client == "nimbus":
            _merge_nimbus_coverage(client_cov_dirs, client_output_dir, testing_clients_dir)
        elif client == "lodestar":
            _merge_lodestar_coverage(client_cov_dirs, client_output_dir, testing_clients_dir)
        elif client == "eth2spec":
            _merge_eth2spec_coverage(client_cov_dirs, client_output_dir, testing_clients_dir)
        
        # Cleanup original data if requested
        if cleanup_after_report:
            for cov_dir in client_cov_dirs:
                _cleanup_coverage_data(cov_dir, client)
    
    print(f"\n{'='*60}")
    print(f"Accumulated coverage reports saved in: {total_coverage_dir}")
    print(f"{'='*60}\n")


def generate_final_accumulated_coverage_report(test_suite_output_dirs, final_output_dir, spectec_core_dir):
    """
    Generate final accumulated coverage report by merging coverage data from multiple test suites.
    
    This function collects merged coverage data from each test suite's total-node-coverage directory
    and merges them into a single final report per client.
    
    Args:
        test_suite_output_dirs: List of test suite output directories (e.g., ["./coverage_epoch_processing", "./coverage_operation", ...])
        final_output_dir: Final output directory for merged coverage reports
        spectec_core_dir: spectec-core directory path
    """
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    final_output_path = Path(final_output_dir)
    final_output_path.mkdir(parents=True, exist_ok=True)
    
    print(f"\n{'='*60}")
    print(f"Generating Final Accumulated Coverage Reports")
    print(f"{'='*60}\n")
    print(f"Test suites: {len(test_suite_output_dirs)}")
    for suite_dir in test_suite_output_dirs:
        print(f"  - {suite_dir}")
    print(f"Final output: {final_output_path}\n")
    
    clients = BASE_CLIENT_TOOLS + ["eth2spec"]
    
    for client in clients:
        print(f"\n[+] Processing final accumulated {client.capitalize()} coverage...")
        
        # Collect merged_coverage directories from all test suites
        # Note: Nimbus uses "report" directory instead of "merged_coverage"
        merged_coverage_dirs = []
        for suite_dir in test_suite_output_dirs:
            suite_path = Path(suite_dir)
            if client == "nimbus":
                # Nimbus stores coverage in report directory, not merged_coverage
                total_coverage_dir = suite_path / "total-node-coverage" / client / "report"
                if total_coverage_dir.exists():
                    merged_coverage_dirs.append(total_coverage_dir)
                    print(f"  ✓ Found: {suite_path.name}/total-node-coverage/{client}/report")
            else:
                # Other clients use merged_coverage directory
                total_coverage_dir = suite_path / "total-node-coverage" / client / "merged_coverage"
                if total_coverage_dir.exists():
                    merged_coverage_dirs.append(total_coverage_dir)
                    print(f"  ✓ Found: {suite_path.name}/total-node-coverage/{client}/merged_coverage")
        
        if not merged_coverage_dirs:
            print(f"  ⚠ No merged coverage data found for {client}")
            continue
        
        print(f"  ℹ Merging {len(merged_coverage_dirs)} test suite(s)")
        
        # Create client-specific output directory
        client_output_dir = final_output_path / client
        client_output_dir.mkdir(exist_ok=True)
        
        # Merge and generate report based on client type
        if client == "prysm":
            _merge_final_prysm_coverage(merged_coverage_dirs, client_output_dir, testing_clients_dir)
        elif client == "lighthouse":
            _merge_final_lighthouse_coverage(merged_coverage_dirs, client_output_dir, testing_clients_dir)
        elif client == "teku":
            _merge_final_teku_coverage(merged_coverage_dirs, client_output_dir, testing_clients_dir)
        elif client == "nimbus":
            _merge_final_nimbus_coverage(merged_coverage_dirs, client_output_dir, testing_clients_dir)
        elif client == "lodestar":
            _merge_final_lodestar_coverage(merged_coverage_dirs, client_output_dir, testing_clients_dir)
        elif client == "eth2spec":
            _merge_final_eth2spec_coverage(merged_coverage_dirs, client_output_dir, testing_clients_dir)
    
    print(f"\n{'='*60}")
    print(f"Final accumulated coverage reports saved in: {final_output_path}")
    print(f"{'='*60}\n")


def _merge_final_prysm_coverage(merged_coverage_dirs, output_dir, testing_clients_dir):
    """Merge Prysm coverage data from multiple test suites (already merged data)"""
    if not merged_coverage_dirs:
        print(f"    ✗ No merged coverage directories found")
        return
    
    # Create final merged coverage directory
    final_merged_cov_dir = output_dir / "merged_coverage"
    final_merged_cov_dir.mkdir(exist_ok=True)
    
    try:
        _merge_prysm_cov_dirs(merged_coverage_dirs, final_merged_cov_dir)
        
        # Generate report from merged data
        _generate_prysm_report(final_merged_cov_dir, testing_clients_dir)
        
        # Move report to output_dir
        report_dir = final_merged_cov_dir / "report"
        if report_dir.exists():
            final_report_dir = output_dir / "report"
            if final_report_dir.exists():
                shutil.rmtree(final_report_dir)
            shutil.move(str(report_dir), str(final_report_dir))
            
            # Ensure statistics are added to the final report
            # (in case they weren't added during _generate_prysm_report)
            coverage_txt = final_report_dir / "coverage.txt"
            coverage_html = final_report_dir / "coverage.html"
            coverage_xml = final_report_dir / "coverage_bcov.xml"
            
            branch_coverage_stats = None
            if coverage_xml.exists():
                branch_coverage_stats = _parse_bcov_xml(coverage_xml)
            
            if coverage_txt.exists() and coverage_html.exists():
                prysm_dir = testing_clients_dir / "prysm"
                _add_prysm_coverage_stats(coverage_txt, coverage_html, prysm_dir, final_merged_cov_dir, branch_coverage_stats)
            
            print(f"    ✓ Final accumulated report: {final_report_dir / 'coverage.html'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _merge_final_lighthouse_coverage(merged_coverage_dirs, output_dir, testing_clients_dir):
    """Merge Lighthouse coverage data from multiple test suites (already merged profdata files)"""
    # Collect all merged.profdata files
    all_profdata_files = []
    for merged_dir in merged_coverage_dirs:
        profdata_file = merged_dir / "merged.profdata"
        if profdata_file.exists():
            all_profdata_files.append(profdata_file)
        else:
            # Debug: check what files exist in merged_dir
            print(f"    ℹ Checking {merged_dir}: exists={merged_dir.exists()}")
            if merged_dir.exists():
                files = list(merged_dir.iterdir())
                print(f"    ℹ Files in {merged_dir.name}: {[f.name for f in files]}")
    
    if not all_profdata_files:
        print(f"    ✗ No merged.profdata files found in merged_coverage directories")
        print(f"    ℹ Searched {len(merged_coverage_dirs)} directory(ies)")
        return
    
    # Create final merged coverage directory
    final_merged_cov_dir = output_dir / "merged_coverage"
    final_merged_cov_dir.mkdir(exist_ok=True)
    final_merged_profdata = final_merged_cov_dir / "merged.profdata"
    
    try:
        # Find llvm-profdata
        rustc_result = subprocess.run(
            ["rustc", "--print", "sysroot"],
            capture_output=True,
            text=True,
            check=True
        )
        sysroot = Path(rustc_result.stdout.strip())
        llvm_tools_dir = sysroot / "lib" / "rustlib" / "x86_64-unknown-linux-gnu" / "bin"
        llvm_profdata = llvm_tools_dir / "llvm-profdata"
        
        if not llvm_profdata.exists():
            print(f"    ✗ llvm-profdata not found")
            return
        
        _merge_lighthouse_profdata_inputs(all_profdata_files, final_merged_profdata, llvm_profdata)
        
        # Verify merged profdata was created
        if not final_merged_profdata.exists():
            print(f"    ✗ Failed to create merged.profdata at {final_merged_profdata}")
            return
        
        print(f"    ℹ Created merged.profdata: {final_merged_profdata}")
        
        # Generate report from merged profdata
        lighthouse_src = testing_clients_dir / "lighthouse"
        lighthouse_binary = lighthouse_src / "target" / "release" / "lcli-cov"
        
        if not lighthouse_binary.exists():
            print(f"    ✗ Lighthouse binary not found: {lighthouse_binary}")
            return
        
        llvm_cov = llvm_tools_dir / "llvm-cov"
        if not llvm_cov.exists():
            print(f"    ✗ llvm-cov not found")
            return
        
        report_dir = output_dir / "report"
        report_dir.mkdir(exist_ok=True)
        html_dir = report_dir / "html"
        html_dir.mkdir(exist_ok=True)
        
        # Generate HTML report with branch coverage
        # Use absolute paths for profdata and output directory
        cmd_show = [
            str(llvm_cov),
            "show",
            str(lighthouse_binary),
            f"--instr-profile={final_merged_profdata.resolve()}",
            "--format=html",
            f"--output-dir={html_dir.resolve()}",
            "--show-line-counts-or-regions",
            "--show-branches=count",
            "--show-instantiations",
        ]
        # Add each exclude pattern separately
        for pattern in LIGHTHOUSE_CORE_IGNORE_PATTERNS:
            cmd_show.extend(["--ignore-filename-regex", pattern])
        
        subprocess.run(
            cmd_show,
            check=True,
            capture_output=True,
            text=True,
            cwd=str(lighthouse_src)
        )
        
        # Generate text summary with branch coverage
        summary_file = report_dir / "summary.txt"
        cmd_report = [
            str(llvm_cov),
            "report",
            str(lighthouse_binary),
            f"--instr-profile={final_merged_profdata.resolve()}",
            "--show-branch-summary",
        ]
        # Add each exclude pattern separately
        for pattern in LIGHTHOUSE_CORE_IGNORE_PATTERNS:
            cmd_report.extend(["--ignore-filename-regex", pattern])
        
        result = subprocess.run(
            cmd_report,
            check=True,
            capture_output=True,
            text=True,
            cwd=str(lighthouse_src)
        )
        
        with open(summary_file, 'w') as f:
            f.write(result.stdout)
        
        print(f"    ✓ Final accumulated report: {html_dir / 'index.html'}")
        print(f"    ✓ Summary: {summary_file}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")



def _merge_final_teku_coverage(merged_coverage_dirs, output_dir, testing_clients_dir):
    """Merge Teku coverage data from multiple test suites (already merged exec files)"""
    # Collect all teku-coverage-merged.exec files
    all_exec_files = []
    for merged_dir in merged_coverage_dirs:
        exec_file = merged_dir / "teku-coverage-merged.exec"
        if exec_file.exists():
            all_exec_files.append(exec_file)

    if not all_exec_files:
        print(f"    ✗ No teku-coverage-merged.exec files found")
        return

    # Create final merged coverage directory
    final_merged_cov_dir = output_dir / "merged_coverage"
    final_merged_cov_dir.mkdir(exist_ok=True)

    jacoco_cli = testing_clients_dir / "jacoco" / "jacococli.jar"
    if not jacoco_cli.exists():
        print(f"    ✗ JaCoCo CLI not found at {jacoco_cli}")
        return

    try:
        # Merge exec files using JaCoCo CLI
        final_merged_exec = final_merged_cov_dir / "teku-coverage-merged.exec"
        _merge_teku_exec_files(all_exec_files, final_merged_exec, jacoco_cli)

        report_dir = output_dir / "report"
        if not _generate_teku_filtered_report_from_exec(final_merged_exec, report_dir, testing_clients_dir):
            return

        print(f"    ✓ Final accumulated report: {report_dir / 'index.html'}")
        print(f"    ✓ Final accumulated CSV: {report_dir / 'coverage.csv'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _merge_final_nimbus_coverage(merged_coverage_dirs, output_dir, testing_clients_dir):
    """Merge Nimbus coverage data from multiple test suites (already merged info files)"""
    nimbus_src = testing_clients_dir / "nimbus-eth2"
    if not nimbus_src.exists():
        return
    
    # Collect coverage.info files from report directories
    # Note: merged_coverage_dirs contains report directories for Nimbus
    all_coverage_infos = []
    for report_dir in merged_coverage_dirs:
        # merged_coverage_dirs for Nimbus are already report directories
        coverage_info = report_dir / "coverage.info"
        if coverage_info.exists() and coverage_info.stat().st_size > 0:
            all_coverage_infos.append(coverage_info)
            print(f"    ℹ Found: {coverage_info}")
        else:
            # Debug: check what files exist in report_dir
            if report_dir.exists():
                files = list(report_dir.iterdir())
                print(f"    ℹ Files in {report_dir.name}: {[f.name for f in files]}")
    
    if not all_coverage_infos:
        print(f"    ✗ No coverage.info or merged.info files found")
        print(f"    ℹ Searched {len(merged_coverage_dirs)} directory(ies)")
        return
    
    try:
        report_dir = output_dir / "report"
        report_dir.mkdir(exist_ok=True)
        final_merged_coverage_info = report_dir / "coverage.info"
        
        _merge_nimbus_info_files(all_coverage_infos, final_merged_coverage_info)
        
        # Filter to keep only core state-transition packages (beacon_chain/, ncli/)
        # This is done AFTER merging original coverage data, matching Lighthouse/TeKu/Prysm approach
        coverage_clean = report_dir / "coverage_clean.info"
        _filter_nimbus_lcov_report(final_merged_coverage_info, coverage_clean, nimbus_src)
        
        # Generate HTML report with branch coverage
        subprocess.run(
            [
                "genhtml",
                str(coverage_clean),
                "--output-directory", str(report_dir),
                "--prefix", str(nimbus_src),
                "--branch-coverage",
            ],
            check=True,
            capture_output=True,
            text=True
        )
        
        print(f"    ✓ Final accumulated report: {report_dir / 'index.html'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _merge_final_lodestar_coverage(merged_coverage_dirs, output_dir, testing_clients_dir):
    """Merge Lodestar coverage data from multiple test suites (already merged JSON files)"""
    # Collect all JSON files from merged_coverage directories
    all_json_files = []
    for merged_dir in merged_coverage_dirs:
        json_files = list(merged_dir.glob("coverage-*.json"))
        all_json_files.extend(json_files)
        if not json_files:
            # Debug: check what files exist in merged_dir
            print(f"    ℹ Checking {merged_dir}: exists={merged_dir.exists()}")
            if merged_dir.exists():
                files = list(merged_dir.iterdir())
                print(f"    ℹ Files in {merged_dir.name}: {[f.name for f in files]}")
    
    if not all_json_files:
        print(f"    ✗ No coverage JSON files found in merged_coverage directories")
        print(f"    ℹ Searched {len(merged_coverage_dirs)} directory(ies)")
        return
    
    lodestar_dir = testing_clients_dir / "lodestar"
    report_dir = output_dir / "report"
    report_dir.mkdir(exist_ok=True)
    report_json_dir = output_dir / "report_json"
    report_json_dir.mkdir(exist_ok=True)
    
    # Create final merged coverage directory
    final_merged_cov_dir = output_dir / "merged_coverage"
    final_merged_cov_dir.mkdir(parents=True, exist_ok=True)
    
    # Copy all JSON files to final merged directory
    for i, json_file in enumerate(all_json_files):
        shutil.copy2(json_file, final_merged_cov_dir / f"coverage-{i:06d}.json")
    
    # Verify files were copied
    copied_files = list(final_merged_cov_dir.glob("coverage-*.json"))
    if not copied_files:
        print(f"    ✗ Failed to copy JSON files to {final_merged_cov_dir}")
        return
    print(f"    ℹ Copied {len(copied_files)} JSON file(s) to merged_coverage directory")
    
    try:
        # Merge and generate report using c8
        # Use --clean=false to prevent c8 from deleting temp files
        # Use absolute paths since c8 runs from lodestar directory
        # Increase Node.js memory limit for large JSON file processing (1822+ files)
        env = os.environ.copy()
        env["NODE_OPTIONS"] = "--max-old-space-size=65536"  
        common_args = [
            "npx", "c8", "report",
            "--merge-async",
            f"--temp-directory={final_merged_cov_dir.resolve()}",
            "--exclude-node-modules=false",
            "--extension=.js",
            "--include=node_modules/@lodestar/**/*.js",
            "--include=node_modules/@chainsafe/**/*.js",
            "--exclude=**/transition.js",
            "--exclude=**/generateCachedStateCapella.js",
            "--clean=false",
        ]
        subprocess.run(
            common_args + [
                "--reporter=html",
                "--reporter=text",
                f"--report-dir={report_dir.resolve()}",
            ],
            cwd=str(lodestar_dir),
            env=env,
            check=True,
            capture_output=True,
            text=True
        )
        subprocess.run(
            common_args + [
                "--reporter=json",
                f"--report-dir={report_json_dir.resolve()}",
            ],
            cwd=str(lodestar_dir),
            env=env,
            check=True,
            capture_output=True,
            text=True
        )
        
        print(f"    ✓ Final accumulated report: {report_dir / 'index.html'}")
        print(f"    ✓ Final accumulated JSON: {report_json_dir / 'coverage-final.json'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _merge_prysm_coverage(cov_dirs, output_dir, testing_clients_dir):
    """Merge Prysm coverage data from multiple test cases"""
    # Collect all covcounters.* and covmeta.* files from original directories
    all_cov_dirs = []
    for cov_dir in cov_dirs:
        if cov_dir.exists():
            all_cov_dirs.append(cov_dir)
    
    if not all_cov_dirs:
        print(f"    ✗ No coverage data directories found")
        return
    
    # Create merged coverage directory
    merged_cov_dir = output_dir / "merged_coverage"
    merged_cov_dir.mkdir(exist_ok=True)
    
    # Merge using go tool covdata merge - use original directories directly
    try:
        _merge_prysm_cov_dirs(all_cov_dirs, merged_cov_dir)
        
        # Generate report from merged data (no filtering for test suite accumulation)
        prysm_report_dir = output_dir / "report"
        prysm_report_dir.mkdir(exist_ok=True)
        prysm_dir = testing_clients_dir / "prysm"
        
        # Convert to text format using go tool covdata textfmt (no filtering)
        coverage_txt = prysm_report_dir / "coverage.txt"
        subprocess.run(
            ["go", "tool", "covdata", "textfmt", f"-i={merged_cov_dir}", f"-o={coverage_txt}"],
            check=True,
            capture_output=True,
            text=True
        )
        
        # Generate HTML report using go tool cover (run from Prysm directory)
        coverage_html = prysm_report_dir / "coverage.html"
        rel_coverage_txt = Path(os.path.relpath(coverage_txt, prysm_dir))
        rel_coverage_html = Path(os.path.relpath(coverage_html, prysm_dir))
        
        subprocess.run(
            ["go", "tool", "cover", f"-html={rel_coverage_txt}", f"-o={rel_coverage_html}"],
            check=True,
            capture_output=True,
            text=True,
            cwd=str(prysm_dir)  # Run from Prysm directory (go.mod required)
        )
        
        print(f"    ✓ Accumulated report: {coverage_html}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _merge_lighthouse_coverage(cov_dirs, output_dir, testing_clients_dir):
    """Merge Lighthouse coverage data from multiple test cases"""
    # First, try to find already-converted profdata files from individual reports
    all_profdata_files = []
    for cov_dir in cov_dirs:
        if cov_dir.exists():
            report_dir = cov_dir / "report"
            if report_dir.exists():
                profdata_file = report_dir / "lighthouse.profdata"
                if profdata_file.exists():
                    all_profdata_files.append(profdata_file)
    
    # If we have profdata files, merge them directly
    if all_profdata_files:
        try:
            merged_cov_dir = output_dir / "merged_coverage"
            merged_cov_dir.mkdir(exist_ok=True)
            merged_profdata = merged_cov_dir / "merged.profdata"
            
            # Find llvm-profdata
            rustc_result = subprocess.run(
                ["rustc", "--print", "sysroot"],
                capture_output=True,
                text=True,
                check=True
            )
            sysroot = Path(rustc_result.stdout.strip())
            llvm_tools_dir = sysroot / "lib" / "rustlib" / "x86_64-unknown-linux-gnu" / "bin"
            llvm_profdata = llvm_tools_dir / "llvm-profdata"
            
            if not llvm_profdata.exists():
                print(f"    ✗ llvm-profdata not found")
                all_profdata_files = []  # Fall through to profraw approach
            else:
                _merge_lighthouse_profdata_inputs(all_profdata_files, merged_profdata, llvm_profdata)
        except subprocess.CalledProcessError as e:
            print(f"    ⚠ Failed to merge profdata files, trying profraw approach: {e}")
            all_profdata_files = []
    
    # Fallback: Collect and merge .profraw files
    if not all_profdata_files:
        all_profraw_files = []
        for cov_dir in cov_dirs:
            if cov_dir.exists():
                profraw_files = list(cov_dir.glob("*.profraw"))
                all_profraw_files.extend(profraw_files)
        
        if not all_profraw_files:
            print(f"    ✗ No .profraw or .profdata files found")
            return
        
        # Create merged coverage directory
        merged_cov_dir = output_dir / "merged_coverage"
        merged_cov_dir.mkdir(exist_ok=True)
        
        # Merge using llvm-profdata merge - use original files directly
        try:
            merged_profdata = merged_cov_dir / "merged.profdata"
            
            # Find llvm-profdata
            rustc_result = subprocess.run(
                ["rustc", "--print", "sysroot"],
                capture_output=True,
                text=True,
                check=True
            )
            sysroot = Path(rustc_result.stdout.strip())
            llvm_tools_dir = sysroot / "lib" / "rustlib" / "x86_64-unknown-linux-gnu" / "bin"
            llvm_profdata = llvm_tools_dir / "llvm-profdata"
            
            if not llvm_profdata.exists():
                print(f"    ✗ llvm-profdata not found")
                return
            
            _merge_lighthouse_profdata_inputs(all_profraw_files, merged_profdata, llvm_profdata)
        except subprocess.CalledProcessError as e:
            print(f"    ✗ Failed to merge profraw files: {e}")
            if e.stderr:
                print(f"    ℹ Error: {e.stderr}")
            return
    
    # Generate report from merged profdata
    try:
        
        # Generate report from merged data
        # Create a temporary cov_output structure for _generate_lighthouse_report
        temp_cov_dir = merged_cov_dir / "temp_cov"
        temp_cov_dir.mkdir(exist_ok=True)
        import shutil
        shutil.copy2(merged_profdata, temp_cov_dir / "merged.profraw")
        
        # We need to modify _generate_lighthouse_report to accept merged profdata
        # For now, create a wrapper that uses the merged profdata directly
        lighthouse_src = testing_clients_dir / "lighthouse"
        lighthouse_binary = lighthouse_src / "target" / "release" / "lcli-cov"
        
        if not lighthouse_binary.exists():
            print(f"    ✗ Lighthouse binary not found: {lighthouse_binary}")
            return
        
        # Find Rust toolchain llvm-tools path
        rustc_result = subprocess.run(
            ["rustc", "--print", "sysroot"],
            capture_output=True,
            text=True,
            check=True
        )
        sysroot = Path(rustc_result.stdout.strip())
        llvm_tools = sysroot / "lib" / "rustlib" / "x86_64-unknown-linux-gnu" / "bin"
        llvm_cov = llvm_tools / "llvm-cov"
        
        if not llvm_cov.exists():
            print(f"    ✗ llvm-cov not found at {llvm_cov}")
            return
        
        report_dir = output_dir / "report"
        report_dir.mkdir(exist_ok=True)
        html_dir = report_dir / "html"
        html_dir.mkdir(exist_ok=True)
        
        # Generate HTML report using llvm-cov with branch coverage.
        # Apply the same filtering policy as final accumulated coverage so
        # single-suite accumulated reports and final reports are consistent.
        cmd_show = [
            str(llvm_cov),
            "show",
            str(lighthouse_binary),
            f"--instr-profile={merged_profdata}",
            "--format=html",
            f"--output-dir={html_dir}",
            "--show-line-counts-or-regions",
            "--show-branches=count",  # Show branch coverage with execution counts
            "--show-instantiations",
        ]
        for pattern in LIGHTHOUSE_CORE_IGNORE_PATTERNS:
            cmd_show.extend(["--ignore-filename-regex", pattern])

        subprocess.run(
            cmd_show,
            check=True,
            capture_output=True,
            text=True,
            cwd=str(lighthouse_src)
        )
        
        # Generate text summary with the same filtering policy.
        summary_file = report_dir / "summary.txt"
        cmd_report = [
            str(llvm_cov),
            "report",
            str(lighthouse_binary),
            f"--instr-profile={merged_profdata}",
            "--show-branch-summary",  # Show branch condition statistics in summary table
        ]
        for pattern in LIGHTHOUSE_CORE_IGNORE_PATTERNS:
            cmd_report.extend(["--ignore-filename-regex", pattern])

        result = subprocess.run(
            cmd_report,
            check=True,
            capture_output=True,
            text=True,
            cwd=str(lighthouse_src)
        )
        
        with open(summary_file, 'w') as f:
            f.write(result.stdout)
        
        print(f"    ✓ Accumulated report: {html_dir / 'index.html'}")
        print(f"    ✓ Summary: {summary_file}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")



def _merge_teku_coverage(cov_dirs, output_dir, testing_clients_dir):
    """Merge Teku coverage data from multiple test cases"""
    # Collect all teku-coverage.exec files
    all_exec_files = []
    for cov_dir in cov_dirs:
        exec_file = cov_dir / "teku-coverage.exec"
        if exec_file.exists():
            all_exec_files.append(exec_file)

    if not all_exec_files:
        print(f"    ✗ No teku-coverage.exec files found")
        return

    # Create merged coverage directory
    merged_cov_dir = output_dir / "merged_coverage"
    merged_cov_dir.mkdir(exist_ok=True)

    jacoco_cli = testing_clients_dir / "jacoco" / "jacococli.jar"
    if not jacoco_cli.exists():
        print(f"    ✗ JaCoCo CLI not found at {jacoco_cli}")
        return

    try:
        # Merge exec files using JaCoCo CLI
        merged_exec = merged_cov_dir / "teku-coverage-merged.exec"
        _merge_teku_exec_files(all_exec_files, merged_exec, jacoco_cli)

        report_dir = output_dir / "report"
        if not _generate_teku_filtered_report_from_exec(merged_exec, report_dir, testing_clients_dir):
            return

        print(f"    ✓ Accumulated report: {report_dir / 'index.html'}")
        print(f"    ✓ Accumulated CSV: {report_dir / 'coverage.csv'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _merge_nimbus_coverage(cov_dirs, output_dir, testing_clients_dir):
    """Merge Nimbus coverage data from multiple test cases"""
    nimbus_src = testing_clients_dir / "nimbus-eth2"
    if not nimbus_src.exists():
        return
    
    # Collect all coverage info files from individual test cases (if they exist)
    # Otherwise, collect .gcda files and merge them
    all_coverage_infos = []
    for cov_dir in cov_dirs:
        # Check if individual test case already has coverage.info
        # cov_dir is like: node_sanity_slots/pyspec_tests_slots_1/nimbus/cov_output_slots_1
        # report dir would be: node_sanity_slots/pyspec_tests_slots_1/nimbus/report
        client_dir = cov_dir.parent if cov_dir.parent else None
        if client_dir:
            test_case_report_dir = client_dir / "report"
            if test_case_report_dir.exists():
                coverage_info = test_case_report_dir / "coverage.info"
                if coverage_info.exists() and coverage_info.stat().st_size > 0:
                    all_coverage_infos.append(coverage_info)
    
    # If we have coverage.info files, merge them using lcov
    if all_coverage_infos:
        try:
            report_dir = output_dir / "report"
            report_dir.mkdir(exist_ok=True)
            merged_coverage_info = report_dir / "coverage.info"
            
            _merge_nimbus_info_files(all_coverage_infos, merged_coverage_info)
            
            # Filter to keep only core state-transition packages (exclude generated_not_to_break_here etc.)
            # genhtml fails if lcov references non-existent paths like Nim's generated_not_to_break_here
            coverage_clean = report_dir / "coverage_clean.info"
            _filter_nimbus_lcov_report(merged_coverage_info, coverage_clean, nimbus_src)
            
            # Generate HTML report with branch coverage (using filtered coverage)
            subprocess.run(
                [
                    "genhtml",
                    str(coverage_clean),
                    "--output-directory", str(report_dir),
                    "--prefix", str(nimbus_src),
                    "--branch-coverage",
                ],
                check=True,
                capture_output=True,
                text=True
            )
            
            print(f"    ✓ Accumulated report: {report_dir / 'index.html'}")
            return
        except subprocess.CalledProcessError as e:
            print(f"    ⚠ Failed to merge coverage.info files, trying .gcda approach: {e}")
    
    # Fallback: Collect all .gcda files and generate coverage from scratch
    # Need to copy .gcno files from original nimcache to match .gcda files
    all_gcda_dirs = []
    for cov_dir in cov_dirs:
        nimcache_dir = cov_dir / "nimcache"
        if nimcache_dir.exists():
            all_gcda_dirs.append(nimcache_dir)
    
    if not all_gcda_dirs:
        print(f"    ✗ No .gcda files found")
        return
    
    try:
        # Check lcov command
        subprocess.run(["lcov", "--version"], check=True, capture_output=True)
        
        report_dir = output_dir / "report"
        report_dir.mkdir(exist_ok=True)
        coverage_info = report_dir / "coverage.info"
        
        # Use original nimcache for .gcno files (generated at compile time)
        original_nimcache = nimbus_src / "nimcache"
        
        if not original_nimcache.exists():
            print(f"    ✗ Original nimcache not found: {original_nimcache}")
            return
        
        # Collect coverage from all directories and merge.
        # Each gcda_dir -> temp_coverage_i.info conversion is independent, so
        # we parallelize only this phase and keep the final merge deterministic.
        requested_jobs = int(os.environ.get("NIMBUS_COVERAGE_JOBS", "8"))
        max_jobs = os.cpu_count() or 1
        jobs = max(1, min(requested_jobs, max_jobs, len(all_gcda_dirs)))
        print(f"    ℹ Nimbus coverage capture jobs: {jobs}")

        temp_info_files = []
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = [
                executor.submit(
                    _capture_nimbus_case_coverage,
                    i,
                    gcda_dir,
                    original_nimcache,
                    report_dir,
                    nimbus_src,
                )
                for i, gcda_dir in enumerate(all_gcda_dirs)
            ]

            for future in as_completed(futures):
                temp_info = future.result()
                if temp_info is not None:
                    temp_info_files.append(temp_info)
        
        if not temp_info_files:
            print(f"    ✗ No valid coverage data collected")
            return
        
        temp_info_files = sorted(temp_info_files)
        _merge_nimbus_info_files(temp_info_files, coverage_info)
        
        # Clean up temp files
        for temp_info in temp_info_files:
            temp_info.unlink()
        
        # Filter to exclude generated_not_to_break_here etc. before genhtml
        coverage_clean = report_dir / "coverage_clean.info"
        _filter_nimbus_lcov_report(coverage_info, coverage_clean, nimbus_src)
        
        # Generate HTML report with branch coverage (using filtered coverage)
        subprocess.run(
            [
                "genhtml",
                str(coverage_clean),
                "--output-directory", str(report_dir),
                "--prefix", str(nimbus_src),
                "--branch-coverage",  # Enable branch coverage display
            ],
            check=True,
            capture_output=True,
            text=True
        )
        
        print(f"    ✓ Accumulated report: {report_dir / 'index.html'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _chunk_list(items, chunk_size=MERGE_CHUNK_SIZE):
    """Yield fixed-size chunks from a list-like sequence."""
    for i in range(0, len(items), chunk_size):
        yield items[i:i + chunk_size]


def _merge_prysm_cov_dirs(input_dirs, output_dir):
    """Merge Prysm coverage directories without exceeding ARG_MAX."""
    current_inputs = [Path(d).resolve() for d in input_dirs]
    output_dir = Path(output_dir).resolve()

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    temp_root = output_dir.parent / "_tmp_prysm_merge"
    if temp_root.exists():
        shutil.rmtree(temp_root)
    temp_root.mkdir(parents=True, exist_ok=True)

    try:
        level = 0
        while len(current_inputs) > MERGE_CHUNK_SIZE:
            next_inputs = []
            level_dir = temp_root / f"level_{level}"
            level_dir.mkdir(parents=True, exist_ok=True)

            for index, chunk in enumerate(_chunk_list(current_inputs)):
                chunk_output = level_dir / f"merge_{index}"
                chunk_output.mkdir(parents=True, exist_ok=True)
                subprocess.run(
                    [
                        "go", "tool", "covdata", "merge",
                        f"-i={','.join(str(d) for d in chunk)}",
                        f"-o={chunk_output}"
                    ],
                    check=True,
                    capture_output=True,
                    text=True
                )
                next_inputs.append(chunk_output)

            current_inputs = next_inputs
            level += 1

        subprocess.run(
            [
                "go", "tool", "covdata", "merge",
                f"-i={','.join(str(d) for d in current_inputs)}",
                f"-o={output_dir}"
            ],
            check=True,
            capture_output=True,
            text=True
        )
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def _merge_lighthouse_profdata_inputs(input_files, output_file, llvm_profdata):
    """Merge Lighthouse profraw/profdata inputs without exceeding ARG_MAX."""
    current_inputs = [Path(f).resolve() for f in input_files]
    output_file = Path(output_file).resolve()
    llvm_profdata = Path(llvm_profdata).resolve()

    if output_file.exists():
        output_file.unlink()

    temp_root = output_file.parent / "_tmp_lighthouse_merge"
    if temp_root.exists():
        shutil.rmtree(temp_root)
    temp_root.mkdir(parents=True, exist_ok=True)

    try:
        level = 0
        while len(current_inputs) > MERGE_CHUNK_SIZE:
            next_inputs = []
            level_dir = temp_root / f"level_{level}"
            level_dir.mkdir(parents=True, exist_ok=True)

            for index, chunk in enumerate(_chunk_list(current_inputs)):
                chunk_output = level_dir / f"merge_{index}.profdata"
                subprocess.run(
                    [str(llvm_profdata), "merge", "-sparse", "-o", str(chunk_output)] +
                    [str(f) for f in chunk],
                    check=True,
                    capture_output=True,
                    text=True
                )
                next_inputs.append(chunk_output)

            current_inputs = next_inputs
            level += 1

        subprocess.run(
            [str(llvm_profdata), "merge", "-sparse", "-o", str(output_file)] +
            [str(f) for f in current_inputs],
            check=True,
            capture_output=True,
            text=True
        )
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def _merge_teku_exec_files(input_files, output_file, jacoco_cli):
    """Merge Teku exec files without exceeding ARG_MAX."""
    current_inputs = [Path(f).resolve() for f in input_files]
    output_file = Path(output_file).resolve()
    jacoco_cli = Path(jacoco_cli).resolve()

    if output_file.exists():
        output_file.unlink()

    temp_root = output_file.parent / "_tmp_teku_merge"
    if temp_root.exists():
        shutil.rmtree(temp_root)
    temp_root.mkdir(parents=True, exist_ok=True)

    try:
        level = 0
        while len(current_inputs) > MERGE_CHUNK_SIZE:
            next_inputs = []
            level_dir = temp_root / f"level_{level}"
            level_dir.mkdir(parents=True, exist_ok=True)

            for index, chunk in enumerate(_chunk_list(current_inputs)):
                chunk_output = level_dir / f"merge_{index}.exec"
                subprocess.run(
                    ["java", "-jar", str(jacoco_cli), "merge"] +
                    [str(f) for f in chunk] +
                    ["--destfile", str(chunk_output)],
                    check=True,
                    capture_output=True,
                    text=True
                )
                next_inputs.append(chunk_output)

            current_inputs = next_inputs
            level += 1

        subprocess.run(
            ["java", "-jar", str(jacoco_cli), "merge"] +
            [str(f) for f in current_inputs] +
            ["--destfile", str(output_file)],
            check=True,
            capture_output=True,
            text=True
        )
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def _merge_nimbus_info_files(info_files, output_file):
    """Merge Nimbus lcov info files without exceeding ARG_MAX."""
    current_inputs = [Path(f).resolve() for f in info_files]
    output_file = Path(output_file).resolve()

    if output_file.exists():
        output_file.unlink()

    temp_root = output_file.parent / "_tmp_nimbus_merge"
    if temp_root.exists():
        shutil.rmtree(temp_root)
    temp_root.mkdir(parents=True, exist_ok=True)

    try:
        level = 0
        while len(current_inputs) > MERGE_CHUNK_SIZE:
            next_inputs = []
            level_dir = temp_root / f"level_{level}"
            level_dir.mkdir(parents=True, exist_ok=True)

            for index, chunk in enumerate(_chunk_list(current_inputs)):
                chunk_output = level_dir / f"merge_{index}.info"
                lcov_args = ["lcov", "--rc", "lcov_branch_coverage=1"]
                for info in chunk:
                    lcov_args.extend(["-a", str(info)])
                lcov_args.extend(["-o", str(chunk_output)])
                subprocess.run(
                    lcov_args,
                    check=True,
                    capture_output=True,
                    text=True
                )
                next_inputs.append(chunk_output)

            current_inputs = next_inputs
            level += 1

        lcov_args = ["lcov", "--rc", "lcov_branch_coverage=1"]
        for info in current_inputs:
            lcov_args.extend(["-a", str(info)])
        lcov_args.extend(["-o", str(output_file)])
        subprocess.run(
            lcov_args,
            check=True,
            capture_output=True,
            text=True
        )
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def _capture_nimbus_case_coverage(index, gcda_dir, original_nimcache, report_dir, nimbus_src):
    """Convert one Nimbus test case's gcda files into a temp lcov info file."""
    gcda_dir = Path(gcda_dir).resolve()
    original_nimcache = Path(original_nimcache).resolve()
    report_dir = Path(report_dir).resolve()
    nimbus_src = Path(nimbus_src).resolve()

    temp_info = report_dir / f"temp_coverage_{index}.info"
    temp_capture_dir = report_dir / f"temp_capture_{index}"

    if temp_capture_dir.exists():
        shutil.rmtree(temp_capture_dir)
    temp_capture_dir.mkdir(parents=True, exist_ok=True)

    try:
        for gcno_file in original_nimcache.rglob("*.gcno"):
            relative_path = gcno_file.relative_to(original_nimcache)
            target_gcno = temp_capture_dir / relative_path
            target_gcno.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(gcno_file, target_gcno)

        for gcda_file in gcda_dir.rglob("*.gcda"):
            relative_path = gcda_file.relative_to(gcda_dir)
            target_gcda = temp_capture_dir / relative_path
            target_gcda.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(gcda_file, target_gcda)

        subprocess.run(
            [
                "lcov",
                "--capture",
                "--directory", str(temp_capture_dir),
                "--output-file", str(temp_info),
                "--base-directory", str(nimbus_src),
                "--rc", "lcov_branch_coverage=1"
            ],
            check=True,
            capture_output=True,
            text=True
        )

        if temp_info.exists() and temp_info.stat().st_size > 0:
            return temp_info

        print(f"    ⚠ Warning: Empty coverage info generated from {gcda_dir.name}")
        return None
    except subprocess.CalledProcessError as e:
        print(f"    ⚠ Warning: Failed to capture coverage from {gcda_dir.name}: {e.stderr if e.stderr else 'Unknown error'}")
        return None
    finally:
        shutil.rmtree(temp_capture_dir, ignore_errors=True)


def _merge_lodestar_coverage(cov_dirs, output_dir, testing_clients_dir):
    """Merge Lodestar coverage data from multiple test cases"""
    # Collect all coverage JSON files
    all_json_files = []
    for cov_dir in cov_dirs:
        json_files = list(cov_dir.glob("coverage-*.json"))
        all_json_files.extend(json_files)
    
    if not all_json_files:
        print(f"    ✗ No coverage JSON files found")
        return
    
    lodestar_dir = testing_clients_dir / "lodestar"
    report_dir = output_dir / "report"
    report_dir.mkdir(exist_ok=True)
    report_json_dir = output_dir / "report_json"
    report_json_dir.mkdir(exist_ok=True)
    
    # Create merged coverage directory
    merged_cov_dir = output_dir / "merged_coverage"
    merged_cov_dir.mkdir(exist_ok=True)
    
    # Copy all JSON files to merged directory
    import shutil
    for i, json_file in enumerate(all_json_files):
        shutil.copy2(json_file, merged_cov_dir / f"coverage-{i:06d}.json")
    
    try:
        # Merge and generate report using c8
        # Increase Node.js memory limit for large JSON file processing
        env = os.environ.copy()
        env["NODE_OPTIONS"] = "--max-old-space-size=65536"  
        common_args = [
            "npx", "c8", "report",
            "--merge-async",
            f"--temp-directory={merged_cov_dir}",
            "--exclude-node-modules=false",
            "--extension=.js",
            "--include=node_modules/@lodestar/**/*.js",
            "--include=node_modules/@chainsafe/**/*.js",
            "--exclude=**/transition.js",
            "--exclude=**/generateCachedStateCapella.js",
            "--clean=false",
        ]
        subprocess.run(
            common_args + [
                "--reporter=html",
                "--reporter=text",
                f"--report-dir={report_dir}",
            ],
            cwd=str(lodestar_dir),
            env=env,
            check=True,
            capture_output=True,
            text=True
        )
        subprocess.run(
            common_args + [
                "--reporter=json",
                f"--report-dir={report_json_dir}",
            ],
            cwd=str(lodestar_dir),
            env=env,
            check=True,
            capture_output=True,
            text=True
        )
        
        print(f"    ✓ Accumulated report: {report_dir / 'index.html'}")
        print(f"    ✓ Accumulated JSON: {report_json_dir / 'coverage-final.json'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed to merge coverage: {e}")
        if e.stderr:
            print(f"    ℹ Error: {e.stderr}")


def _cleanup_coverage_data(cov_dir, client):
    """Delete original coverage measurement data after report generation
    
    Args:
        cov_dir: cov_output_{index} directory
        client: Client name (prysm, lighthouse, teku, nimbus, lodestar)
    """
    import shutil
    
    try:
        if client == "prysm":
            # Prysm: Delete covcounters.* files (original coverage data)
            for cov_file in cov_dir.glob("covcounters.*"):
                cov_file.unlink()
                print(f"    ✓ Removed: {cov_file.name}")
            # Prysm: Also delete covmeta.* files (metadata files, unnecessary after report generation)
            for covmeta_file in cov_dir.glob("covmeta.*"):
                covmeta_file.unlink()
                print(f"    ✓ Removed: {covmeta_file.name}")
        
        elif client == "lighthouse":
            # Lighthouse: Delete *.profraw files (original data)
            for profraw_file in cov_dir.glob("*.profraw"):
                profraw_file.unlink()
                print(f"    ✓ Removed: {profraw_file.name}")
            # Lighthouse: Also delete report/lighthouse.profdata file (intermediate file, unnecessary after report generation)
            profdata_file = cov_dir / "report" / "lighthouse.profdata"
            if profdata_file.exists():
                profdata_file.unlink()
                print(f"    ✓ Removed: report/{profdata_file.name}")
        
        elif client == "teku":
            # Teku: Delete teku-coverage.exec file
            exec_file = cov_dir / "teku-coverage.exec"
            if exec_file.exists():
                exec_file.unlink()
                print(f"    ✓ Removed: {exec_file.name}")
        
        elif client == "nimbus":
            # Nimbus: Delete entire nimcache directory
            nimcache_dir = cov_dir / "nimcache"
            if nimcache_dir.exists():
                shutil.rmtree(nimcache_dir)
                print(f"    ✓ Removed: {nimcache_dir.name}/")
        
        elif client == "lodestar":
            # Lodestar: Delete coverage-*.json files (keep report directory)
            for json_file in cov_dir.glob("coverage-*.json"):
                json_file.unlink()
                print(f"    ✓ Removed: {json_file.name}")

        elif client == "eth2spec":
            coverage_file = cov_dir / ".coverage"
            if coverage_file.exists():
                coverage_file.unlink()
                print(f"    ✓ Removed: {coverage_file.name}")
    
    except Exception as e:
        print(f"    ⚠ Warning: Failed to cleanup coverage data: {e}")


def find_test_case_dirs(test_suite_dir, test_type="state-transition"):
    """
    Find test case directories based on test type.
    
    Args:
        test_suite_dir: Test suite directory path
        test_type: "state-transition", "operation", or "epoch-processing"
    """
    test_suite_path = Path(test_suite_dir).resolve()
    test_case_dirs = []
    
    # Find all directories containing pre.ssz_snappy files (OfficialTestSuite original format)
    for pre_file in test_suite_path.rglob("pre.ssz_snappy"):
        parent = pre_file.parent
        # Exclude output directories: exclude if any part of path starts with _
        parent_parts = parent.parts
        if any(part.startswith('_') for part in parent_parts):
            continue
        
        # Filter by test type
        if test_type == "operation":
            # For operation, check if directory is under operations/ path
            if "operations" not in parent_parts:
                continue
        elif test_type == "epoch-processing":
            # For epoch-processing, check if directory is under epoch_processing/ path
            if "epoch_processing" not in parent_parts:
                continue
        elif test_type == "sanity-slots":
            # For sanity-slots, check if directory is under sanity/slots/ path
            if "sanity" not in parent_parts or "slots" not in parent_parts:
                continue
        elif test_type == "state-transition":
            # For state-transition, exclude operations, epoch_processing, and sanity/slots (but include sanity/blocks, random, finality)
            if "operations" in parent_parts or "epoch_processing" in parent_parts:
                continue
            # Exclude sanity/slots (handled by sanity-slots test type)
            if "sanity" in parent_parts and "slots" in parent_parts:
                continue
        
        test_case_dirs.append(parent)
    
    # Find all directories containing pre.ssz files (already converted format)
    for pre_file in test_suite_path.rglob("pre.ssz"):
        parent = pre_file.parent
        # Remove duplicates and exclude output directories
        parent_parts = parent.parts
        if any(part.startswith('_') for part in parent_parts):
            continue
        
        if parent in test_case_dirs:
            continue
        
        # Filter by test type
        if test_type == "operation":
            if "operations" not in parent_parts:
                continue
        elif test_type == "epoch-processing":
            if "epoch_processing" not in parent_parts:
                continue
        elif test_type == "sanity-slots":
            # For sanity-slots, check if directory is under sanity/slots/ path
            if "sanity" not in parent_parts or "slots" not in parent_parts:
                continue
        elif test_type == "state-transition":
            # For state-transition, exclude operations, epoch_processing, and sanity/slots (but include sanity/blocks, random, finality)
            if "operations" in parent_parts or "epoch_processing" in parent_parts:
                continue
            # Exclude sanity/slots (handled by sanity-slots test type)
            if "sanity" in parent_parts and "slots" in parent_parts:
                continue
        
        test_case_dirs.append(parent)
    
    # Find all directories containing pre_*.ssz files (state mutation format)
    # Only for state-transition
    if test_type == "state-transition":
        for pre_file in test_suite_path.rglob("pre_*.ssz"):
            parent = pre_file.parent
            # Remove duplicates and exclude output directories
            parent_parts = parent.parts
            if any(part.startswith('_') for part in parent_parts):
                continue
            
            if parent in test_case_dirs:
                continue
            
            test_case_dirs.append(parent)
    
    return sorted(test_case_dirs)


def main():
    """
    CLI interface: execute state transition with local SSZ files
    """
    parser = argparse.ArgumentParser(description="Differential testing tool for eth2-clients")
    
    
    parser.add_argument("--test-suite", type=str, default=None,
                       help="Test suite directory (e.g., Converter/OfficialTestSuite/random). "
                            "If provided, automatically finds all test cases with pre.ssz or pre.ssz_snappy files. "
                            ".ssz_snappy files are automatically decompressed to .ssz.")
    parser.add_argument("--test-type", type=str, default="state-transition",
                       choices=["state-transition", "operation", "epoch-processing", "sanity-slots"],
                       help="Type of test to run: state-transition (default), operation, epoch-processing, or sanity-slots")
    parser.add_argument("--fork-version", type=str, default="capella",
                       choices=["capella", "deneb"],
                       help="Fork version to use: capella (default) or deneb")
    parser.add_argument("beaconstate_dir_path", nargs="?", default=None,
                       help="Path to beaconstate files dir (required if --test-suite is not used)")
    parser.add_argument("block_dir_path", nargs="?", default=None,
                       help="Path to block files dir (required if --test-suite is not used, ignored for epoch-processing)")
    parser.add_argument("output", nargs="?", default=None,
                       help="Path to output directory (required if --test-suite is not used)")                   
    parser.add_argument("--output-base", type=str, default=None,
                       help="Base output directory when using --test-suite (default: test_suite_dir/client_results)")
    parser.add_argument("--workflow", type=str, default="independent",
                       choices=["independent", "sequential"],
                       help="Test workflow mode: independent (default) or sequential (chained execution)")
    parser.add_argument("--enable-coverage", action="store_true",
                       help="Enable code coverage measurement for all clients. "
                            "Coverage data will be saved in <output_dir>/<client>/cov_output/ for each test case.")
    parser.add_argument("--cleanup-after-report", action="store_true",
                       help="Delete original coverage measurement data after generating reports. "
                            "This saves disk space but prevents regenerating reports later.")
    parser.add_argument("--generate-final-coverage", nargs="+", metavar="OUTPUT_DIR",
                       help="Generate final accumulated coverage report by merging coverage data from multiple test suites. "
                            "Provide one or more test suite output directories (e.g., ./coverage_epoch_processing ./coverage_operation). "
                            "This option requires --final-output-dir to specify where the final report should be saved.")
    parser.add_argument("--final-output-dir", type=str, default=None,
                       help="Output directory for final accumulated coverage report (required when using --generate-final-coverage)")

    args = parser.parse_args()
    
    # Handle --generate-final-coverage mode (standalone mode)
    if args.generate_final_coverage:
        if not args.final_output_dir:
            parser.error("--final-output-dir is required when using --generate-final-coverage")
        
        script_dir = Path(__file__).parent.resolve()
        generate_final_accumulated_coverage_report(
            args.generate_final_coverage,
            args.final_output_dir,
            script_dir
        )
        sys.exit(0)

    # Find spectec-core directory
    script_dir = Path(__file__).parent.resolve()
    
    start_time = perf_counter()
    
    # Test suite mode
    if args.test_suite:
        test_suite_path = Path(args.test_suite).resolve()
        if not test_suite_path.exists():
            print(f"Error: Test suite directory not found: {test_suite_path}")
            sys.exit(1)
        
        # Find all test cases
        test_case_dirs = find_test_case_dirs(args.test_suite, test_type=args.test_type)
        
        if not test_case_dirs:
            print(f"No test cases found in {test_suite_path}")
            print("Looking for directories containing pre.ssz or pre.ssz_snappy files...")
            sys.exit(1)
        
        print(f"Found {len(test_case_dirs)} test case(s)")
        
        # Set output directory
        if args.output_base:
            output_base = Path(args.output_base).resolve()
        else:
            output_base = test_suite_path / "client_results"
        
        # Process each test case
        total_passed = 0
        total_failed = 0
        
        for test_case_dir in test_case_dirs:
            # Generate test case name
            try:
                relative_path = test_case_dir.relative_to(test_suite_path)
                test_name = str(relative_path).replace(os.sep, "_").replace("/", "_")
            except ValueError:
                test_name = test_case_dir.name
            
            # Set output directory
            output_dir = output_base / test_name
            
            print(f"\n{'='*60}")
            print(f"Processing test case: {test_name}")
            print(f"Directory: {test_case_dir}")
            print(f"Output: {output_dir}")
            print(f"{'='*60}")
            
            # Execute test based on test type
            try:
                if args.test_type == "state-transition":
                    successful_clients_by_index = state_transition(
                        str(test_case_dir),
                        str(test_case_dir),
                        str(output_dir),
                        spectec_core_dir=script_dir,
                        workflow=args.workflow,
                        enable_coverage=args.enable_coverage,
                        fork_version=args.fork_version
                    )
                elif args.test_type == "operation":
                    successful_clients_by_index = operation(
                        str(test_case_dir),
                        str(output_dir),
                        spectec_core_dir=script_dir,
                        enable_coverage=args.enable_coverage,
                        fork_version=args.fork_version
                    )
                elif args.test_type == "epoch-processing":
                    successful_clients_by_index = epoch_processing(
                        str(test_case_dir),
                        str(output_dir),
                        spectec_core_dir=script_dir,
                        enable_coverage=args.enable_coverage,
                        fork_version=args.fork_version
                    )
                elif args.test_type == "sanity-slots":
                    successful_clients_by_index = sanity_slots(
                        str(test_case_dir),
                        str(output_dir),
                        spectec_core_dir=script_dir,
                        enable_coverage=args.enable_coverage,
                        fork_version=args.fork_version
                    )
                else:
                    print(f"✗ Unknown test type: {args.test_type}")
                    total_failed += 1
                    continue
                
                # Execute SSZ file comparison (only compare successful clients)
                compare_ssz_files_in_output(str(output_dir), successful_clients_by_index)
                
                # Note: Individual test case coverage reports are skipped when generating accumulated reports
                # Uncomment the line below if you want both individual and accumulated reports
                # if args.enable_coverage:
                #     generate_coverage_reports_per_testcase(str(output_dir), script_dir, cleanup_after_report=False)
                
                print(f"✓ Completed: {test_name}")
                total_passed += 1
            except Exception as e:
                print(f"✗ Failed: {test_name} - {e}")
                total_failed += 1
        
        # Generate accumulated coverage report for entire test suite
        if args.enable_coverage:
            generate_accumulated_coverage_report(str(output_base), script_dir, cleanup_after_report=args.cleanup_after_report)
        
        # Summary
        print(f"\n{'='*60}")
        print("SUMMARY")
        print(f"{'='*60}")
        print(f"Total test cases: {len(test_case_dirs)}")
        print(f"Passed: {total_passed}")
        print(f"Failed: {total_failed}")
        print(f"Results directory: {output_base}")
        
    # Single directory mode (legacy method)
    else:
        if not args.beaconstate_dir_path or not args.output:
            parser.error("beaconstate_dir_path and output are required when --test-suite is not used")
        
        if args.test_type == "state-transition":
            if not args.block_dir_path:
                parser.error("block_dir_path is required for state-transition test type")
            successful_clients_by_index = state_transition(
                args.beaconstate_dir_path,
                args.block_dir_path,
                args.output,
                spectec_core_dir=script_dir,
                workflow=args.workflow,
                enable_coverage=args.enable_coverage,
                fork_version=args.fork_version
            )
        elif args.test_type == "operation":
            # For operation, beaconstate_dir_path is the test case directory
            successful_clients_by_index = operation(
                args.beaconstate_dir_path,
                args.output,
                spectec_core_dir=script_dir,
                enable_coverage=args.enable_coverage,
                fork_version=args.fork_version
            )
        elif args.test_type == "epoch-processing":
            # For epoch-processing, beaconstate_dir_path is the test case directory
            successful_clients_by_index = epoch_processing(
                args.beaconstate_dir_path,
                args.output,
                spectec_core_dir=script_dir,
                enable_coverage=args.enable_coverage,
                fork_version=args.fork_version
            )
        elif args.test_type == "sanity-slots":
            # For sanity-slots, beaconstate_dir_path is the test case directory
            successful_clients_by_index = sanity_slots(
                args.beaconstate_dir_path,
                args.output,
                spectec_core_dir=script_dir,
                enable_coverage=args.enable_coverage,
                fork_version=args.fork_version
            )
        else:
            parser.error(f"Unknown test type: {args.test_type}")
        
        # Execute SSZ file comparison (only compare successful clients)
        compare_ssz_files_in_output(args.output, successful_clients_by_index)
        
        # Generate coverage reports (per test case)
        if args.enable_coverage:
            generate_coverage_reports_per_testcase(args.output, script_dir, cleanup_after_report=args.cleanup_after_report)
    
    end_time = perf_counter()
    
    print(f"\n[+] Total process time (seconds) : {end_time - start_time}")

if __name__ == "__main__":
    main()
