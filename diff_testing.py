import os
import sys
import io
import subprocess
import argparse
import csv
import re
from time import perf_counter
from pathlib import Path
from datetime import datetime
from collections import defaultdict

STATUS_LABEL = {
    0: "SUCCESS",
    1: "FAIL",
    2: "UNHANDLED_EXCEPTION"
}

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
    tools = ["lighthouse", "prysm", "nimbus", "teku", "lodestar"]
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


def process_clients(state, block, paths, spectec_core_dir=None, enable_coverage=False):
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
    
    # Check Lodestar transition.js file path
    lodestar_transition = testing_clients_dir / "lodestar" / "transition.js"
    if not lodestar_transition.exists():
        lodestar_transition = testing_clients_dir / "lodestar" / "transition"

    # Pure Capella config path setup
    pure_capella_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    lighthouse_testnet_dir = pure_capella_configs_dir / "lighthouse_testnet"
    # Note: teku_config and nimbus_config are not used (Teku uses CLI args, Nimbus uses code override)

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

    clients = [
        Clients(
            "Lodestar",
            "/usr/bin/node",
            [
                "--max-old-space-size=4096",
                str(lodestar_transition),
                state,
                block,
                paths["lodestar"]["output"],
                "verifyProposer=false",  # validate_result = false: Skip block signature verification
                "verifyStateRoot=false",  # validate_result = false: Skip state root verification
            ]),
        Clients(
            "Lighthouse",
            str(lighthouse_binary),
            [
                "transition-blocks",
                "--pre-state-path", state,
                "--block-path", block,
                "--post-state-output-path", paths["lighthouse"]["output"],
                # Pure Capella config: CAPELLA_FORK_EPOCH = 0
                "--testnet-dir", str(lighthouse_testnet_dir),
                # validate_result = true: Enable signature verification and state root verification
                # Signature verification is enabled by default (no --no-signature-verification flag)
                # State root verification is enabled in code (CLIENT_CODE_MODIFICATIONS.md Modification 3)
            ]),
        Clients(
            "Prysm",
            str(prysm_binary),
            [
                "state-transition",
                f"--block-path={block}",
                f"--pre-state-path={state}",
                f"--expected-post-state-path={paths['prysm']['output']}"
                # validate_result = true: Signature verification and state root verification enabled in code
                # (CLIENT_CODE_MODIFICATIONS.md Modification 3)
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
                # Pure Capella config: fork epochs set to 0
                "--Xnetwork-altair-fork-epoch=0",
                "--Xnetwork-bellatrix-fork-epoch=0",
                "--Xnetwork-capella-fork-epoch=0",
                "--Xnetwork-deneb-fork-epoch=75520",
                # validate_result = true: Signature verification and state root verification enabled
                # Note: Teku uses BLSSignatureVerifier.SIMPLE for signature verification
                # State root verification is enabled in code (CLIENT_CODE_MODIFICATIONS.md)
            ]),

    ]

    for client in clients:
        try:
            start_time = perf_counter()
            
            print(f"\n[+] Running: {client.name}")

            if not client.available:
                raise FileNotFoundError(f"[X] Not available: {client.cmd_path}")

            client.state = state
            client.block = block

            print(f"[+] Command: {client.cmd_path} {' '.join(str(arg) for arg in client.cmd_args)}")
            # Convert all arguments to strings (Path objects may be included)
            cmd = [str(client.cmd_path)] + [str(arg) for arg in client.cmd_args]

            # Setup coverage environment variables
            env = os.environ.copy()
            if enable_coverage:
                client_name_lower = client.name.lower()
                
                if client.name == "Prysm":
                    # Go: Set GOCOVERDIR environment variable
                    env["GOCOVERDIR"] = str(coverage_dirs["prysm"])
                    print(f"[+] Coverage enabled: GOCOVERDIR={env['GOCOVERDIR']}")
                
                elif client.name == "Lighthouse":
                    # Rust: Set LLVM_PROFILE_FILE environment variable
                    profile_file = coverage_dirs["lighthouse"] / f"lighthouse-cov-%p-%m.profraw"
                    env["LLVM_PROFILE_FILE"] = str(profile_file)
                    print(f"[+] Coverage enabled: LLVM_PROFILE_FILE={env['LLVM_PROFILE_FILE']}")
                
                elif client.name == "Teku":
                    # Java: Inject JaCoCo agent via JAVA_OPTS
                    jacoco_agent_path = testing_clients_dir / "jacoco" / "jacocoagent.jar"
                    jacoco_exec = coverage_dirs["teku"] / "teku-coverage.exec"
                    
                    if jacoco_agent_path.exists():
                        env["JAVA_OPTS"] = f"-javaagent:{jacoco_agent_path}=destfile={jacoco_exec}"
                        print(f"[+] Coverage enabled: JAVA_OPTS={env['JAVA_OPTS']}")
                    else:
                        print(f"[!] Warning: JaCoCo agent not found at {jacoco_agent_path}")
                        print(f"[!] Download from: https://www.jacoco.org/jacoco/trunk/doc/agent.html")
                
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
            
            #print(client.status_code)
            #print(client.output)
            
            print(f"[+] Execution time: {client.timestamp}")
            
            # Apply correct classification criteria
            if process.returncode == 0:
                client.status_code = 0  # SUCCESS
            elif process.returncode < 0:
                client.status_code = 2  # UNHANDLED_EXCEPTION (terminated by signal)
            else:
                client.status_code = 1  # FAIL (all positive error codes: 1, 2, 3, 4...)
            
            # Lodestar special handling: set to 2 if stderr parsing fails
            if client.name == "Lodestar":
                try:
                    # Handled exception
                    if client.output.stderr!='':
                        #print(f"Are you sure? {client.output.stderr}")
                        # Try to parse as JSON first (for stack traces)
                        try:
                            import json
                            # Find JSON object in stderr
                            json_start = client.output.stderr.find('{')
                            if json_start != -1:
                                json_end = client.output.stderr.rfind('}') + 1
                                if json_end > json_start:
                                    json_str = client.output.stderr[json_start:json_end]
                                    error_obj = json.loads(json_str)
                                    status_code = error_obj.get('statusCode', 1)
                                    output_string = error_obj.get('output', '')
                                    # Use statusCode parsed from stderr, but apply correct classification
                                    if status_code == 0:
                                        client.status_code = 0  # SUCCESS
                                    elif status_code < 0:
                                        client.status_code = 2  # UNHANDLED_EXCEPTION
                                    else:
                                        client.status_code = 1  # FAIL
                                    client.output.stderr = output_string
                                    continue
                        except:
                            pass
                        
                        # Fallback to old regex pattern
                        status_code_match = re.search(r"statusCode: \s*(\d+)", client.output.stderr)
                        if status_code_match:
                            status_code = int(status_code_match.group(1))
                            output_match = re.search(r"output: \s*'(.*?)'", client.output.stderr, re.DOTALL)
                            if output_match:
                                output_string = output_match.group(1)
                                # Use statusCode parsed from stderr, but apply correct classification
                                if status_code == 0:
                                    client.status_code = 0  # SUCCESS
                                elif status_code < 0:
                                    client.status_code = 2  # UNHANDLED_EXCEPTION
                                else:
                                    client.status_code = 1  # FAIL
                                client.output.stderr = output_string
                        
                # Unhandled exception
                except Exception as e:
                    #print(f"[!] Failed to extract Lodestar output: {e}")
                    client.status_code = 2

            client.log()
            
            # Nimbus: Copy .gcda files for independent coverage per test case
            if client.name == "Nimbus" and enable_coverage:
                nimbus_src = testing_clients_dir / "nimbus-eth2"
                nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                nimbus_coverage_dir = coverage_dirs.get("nimbus")
                
                if nimbus_coverage_dir and nimbus_gcda_dir.exists():
                    # Copy nimcache structure to cov_output_{index} directory
                    target_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
                    target_gcda_dir.mkdir(parents=True, exist_ok=True)
                    
                    # Copy only .gcda files (independent per test case)
                    # .gcno files are taken from original nimcache during report generation for consistent measurement scope
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
            
            # Teku: Delete empty output files (Teku creates empty files on failure)
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
        cmd = f"{client.cmd_path} {' '.join(client.cmd_args)}"
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
    fieldnames = ['Pair #', 'Lighthouse', 'Prysm', 'Nimbus', 'Teku', 'Lodestar']

    def _sort_key(item):
        idx = str(item['Pair #'])
        return (0, int(idx)) if idx.isdigit() else (1, idx.lower())

    all_results = sorted(all_results, key=_sort_key)

    total_times = defaultdict(float)
    for result in all_results:
        for client in ['Lighthouse', 'Prysm', 'Nimbus', 'Teku', 'Lodestar']:
            if client in result and isinstance(result[client], (int, float)): 
                total_times[client] += result[client]

    # Append Total
    total_row = {'Pair #': 'Total'}
    total_row.update({client: f"{total_times[client]:.{time_decimal_places}f}" for client in ['Lighthouse', 'Prysm', 'Nimbus', 'Teku', 'Lodestar']})

    with open(csv_file_path, mode='w', newline='', encoding='utf-8') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        for result in all_results:
            formatted_result = {
                key: f"{value:.{time_decimal_places}f}" if isinstance(value, (int, float)) else value
                for key, value in result.items()
            }
            writer.writerow(result)
        writer.writerow(total_row)

    print(f"[+] CSV log saved at {csv_file_path}")


def state_transition(state_dir, block_dir, output_parent_dir, spectec_core_dir=None, workflow="independent", enable_coverage=False):
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
            
            eth2_clients = process_clients(current_state, block, paths, spectec_core_dir=spectec_core_dir, enable_coverage=enable_coverage)
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
            eth2_clients = process_clients(state, block, paths, spectec_core_dir=spectec_core_dir, enable_coverage=enable_coverage)
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

    fieldnames = ['Pair #', 'Lighthouse', 'Prysm', 'Nimbus', 'Teku', 'Lodestar']

    def _sort_key(item):
        idx = str(item['Pair #'])
        return (0, int(idx)) if idx.isdigit() else (1, idx.lower())

    all_status = sorted(all_status, key=_sort_key)

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
    tools = ["lighthouse", "prysm", "nimbus", "teku", "lodestar"]
    output_dirs = {tool: os.path.join(output_parent_dir, tool, "output") for tool in tools}

    # Get all indices from the output directories
    indices = set()
    for tool, output_dir in output_dirs.items():
        if os.path.exists(output_dir):
            for file in os.listdir(output_dir):
                if file.startswith("poststate_") and file.endswith(".ssz"):
                    index = file.split("_")[-1].split(".")[0]
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
    clients = ["prysm", "lighthouse", "teku", "nimbus", "lodestar"]
    
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
        coverage_txt = prysm_report_dir / "coverage.txt"
        subprocess.run(
            ["go", "tool", "covdata", "textfmt", f"-i={prysm_coverage_dir}", f"-o={coverage_txt}"],
            check=True,
            capture_output=True,
            text=True
        )
        
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
        
        # Calculate overall coverage statistics and add to HTML
        _add_prysm_coverage_stats(coverage_txt, coverage_html, prysm_dir, prysm_coverage_dir)
        
        print(f"    ✓ Report: {prysm_report_dir / 'coverage.html'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")


def _add_prysm_coverage_stats(coverage_txt, coverage_html, prysm_dir, prysm_coverage_dir):
    """Add overall statistics to Prysm HTML report"""
    try:
        # Collect package statistics using go tool covdata percent
        result = subprocess.run(
            ["go", "tool", "covdata", "percent", f"-i={prysm_coverage_dir}"],
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
        func_result = subprocess.run(
            ["go", "tool", "cover", f"-func={coverage_txt}"],
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
        
        # Generate statistics box HTML
        stats_html = f'''
        <div style="background:#375eab;color:#fff;padding:20px;margin:20px;border-radius:5px;">
            <h2 style="margin:0 0 10px 0;">Overall Statement Coverage: {total_coverage:.1f}%</h2>
            <div style="font-size:14px;">
                (Calculated by Go official tool: go tool cover -func)
            </div>
        </div>
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
        
        # 2. Generate HTML report
        html_dir = lighthouse_report_dir / "html"
        html_dir.mkdir(exist_ok=True)
        subprocess.run(
            [
                str(llvm_cov), "show",
                str(lighthouse_binary),
                f"--instr-profile={profdata_file}",
                "--format=html",
                f"--output-dir={html_dir}",
                "--ignore-filename-regex=/.cargo|rustc/",
                "--show-line-counts-or-regions",
                "--show-instantiations"
            ],
            check=True,
            capture_output=True,
            text=True
        )
        
        # 3. Generate text summary
        summary_file = lighthouse_report_dir / "summary.txt"
        result = subprocess.run(
            [
                str(llvm_cov), "report",
                str(lighthouse_binary),
                f"--instr-profile={profdata_file}",
                "--ignore-filename-regex=/.cargo|rustc/",
                "--show-instantiation-summary"
            ],
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
    
    jacoco_cli = testing_clients_dir / "jacoco" / "jacococli.jar"
    if not jacoco_cli.exists():
        print(f"    ✗ JaCoCo CLI not found at {jacoco_cli}")
        return
    
    try:
        # Find only Teku jar files (teku-*.jar)
        teku_lib_dir = testing_clients_dir / "teku" / "build" / "install" / "teku-cov" / "lib"
        teku_jars = list(teku_lib_dir.glob("teku-*.jar"))
        
        if not teku_jars:
            print(f"    ✗ No Teku jar files found in {teku_lib_dir}")
            return
        
        # Add --classfiles for each jar file
        classfiles_args = []
        for jar in teku_jars:
            classfiles_args.extend(["--classfiles", str(jar)])
        
        # Find Teku source directories (multi-module Gradle project)
        teku_root = testing_clients_dir / "teku"
        # Find src/main/java directory for each module
        source_dirs = []
        for src_dir in teku_root.rglob("src/main/java"):
            if src_dir.is_dir():
                source_dirs.append(str(src_dir))
        
        # Add --sourcefiles option (for source file mapping)
        sourcefiles_args = []
        if source_dirs:
            for src_dir in source_dirs:
                sourcefiles_args.extend(["--sourcefiles", src_dir])
        else:
            print(f"    ⚠ Warning: No source directories found, source code mapping may not work")
        
        subprocess.run(
            [
                "java", "-jar", str(jacoco_cli),
                "report", str(teku_exec),
            ] + classfiles_args + sourcefiles_args + [
                "--html", str(teku_report_dir)
            ],
            check=True,
            capture_output=True,
            text=True
        )
        print(f"    ✓ Report: {teku_report_dir / 'index.html'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")


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
        
        # Filter generated_not_to_break_here -> non-existent files (lcov error remains...)
        coverage_clean = nimbus_report_dir / "coverage_clean.info"
        with open(coverage_info, 'r') as infile, open(coverage_clean, 'w') as outfile:
            for line in infile:
                if 'generated_not_to_break_here' not in line:
                    outfile.write(line)
        
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
            subprocess.run(
                [
                    "npx", "c8", "report",
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
    
    except Exception as e:
        print(f"    ⚠ Warning: Failed to cleanup coverage data: {e}")


def find_test_case_dirs(test_suite_dir):
    test_suite_path = Path(test_suite_dir).resolve()
    test_case_dirs = []
    
    # Find all directories containing pre.ssz_snappy files (OfficialTestSuite original format)
    for pre_file in test_suite_path.rglob("pre.ssz_snappy"):
        parent = pre_file.parent
        # Exclude output directories: exclude if any part of path starts with _
        # Examples: .../_sanity_independent/... or .../_results/... etc.
        parent_parts = parent.parts
        if not any(part.startswith('_') for part in parent_parts):
            test_case_dirs.append(parent)
    
    # Find all directories containing pre.ssz files (already converted format)
    for pre_file in test_suite_path.rglob("pre.ssz"):
        parent = pre_file.parent
        # Remove duplicates and exclude output directories
        parent_parts = parent.parts
        if parent not in test_case_dirs and not any(part.startswith('_') for part in parent_parts):
            test_case_dirs.append(parent)
    
    # Find all directories containing pre_*.ssz files (state mutation format)
    for pre_file in test_suite_path.rglob("pre_*.ssz"):
        parent = pre_file.parent
        # Remove duplicates and exclude output directories
        parent_parts = parent.parts
        if parent not in test_case_dirs and not any(part.startswith('_') for part in parent_parts):
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
    parser.add_argument("beaconstate_dir_path", nargs="?", default=None,
                       help="Path to beaconstate files dir (required if --test-suite is not used)")
    parser.add_argument("block_dir_path", nargs="?", default=None,
                       help="Path to block files dir (required if --test-suite is not used)")
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

    args = parser.parse_args()

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
        test_case_dirs = find_test_case_dirs(args.test_suite)
        
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
            
            # Execute state_transition
            try:
                successful_clients_by_index = state_transition(
                    str(test_case_dir),
                    str(test_case_dir),
                    str(output_dir),
                    spectec_core_dir=script_dir,
                    workflow=args.workflow,
                    enable_coverage=args.enable_coverage
                )
                
                # Execute SSZ file comparison (only compare successful clients)
                compare_ssz_files_in_output(str(output_dir), successful_clients_by_index)
                
                # Generate coverage reports (per test case)
                if args.enable_coverage:
                    generate_coverage_reports_per_testcase(str(output_dir), script_dir, cleanup_after_report=args.cleanup_after_report)
                
                print(f"✓ Completed: {test_name}")
                total_passed += 1
            except Exception as e:
                print(f"✗ Failed: {test_name} - {e}")
                total_failed += 1
        
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
        if not args.beaconstate_dir_path or not args.block_dir_path or not args.output:
            parser.error("beaconstate_dir_path, block_dir_path, and output are required when --test-suite is not used")
        
        successful_clients_by_index = state_transition(
            args.beaconstate_dir_path,
            args.block_dir_path,
            args.output,
            spectec_core_dir=script_dir,
            workflow=args.workflow,
            enable_coverage=args.enable_coverage
        )
        
        # Execute SSZ file comparison (only compare successful clients)
        compare_ssz_files_in_output(args.output, successful_clients_by_index)
        
        # Generate coverage reports (per test case)
        if args.enable_coverage:
            generate_coverage_reports_per_testcase(args.output, script_dir, cleanup_after_report=args.cleanup_after_report)
    
    end_time = perf_counter()
    
    print(f"\n[+] Total process time (seconds) : {end_time - start_time}")

if __name__ == "__main__":
    main()

