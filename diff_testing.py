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


def parse_state_block(state_dir, block_dir, output_parent_dir):
    """
    state_dir와 block_dir에서 SSZ 파일 쌍을 찾아서 yield합니다.
    
    지원하는 파일 형태:
    1. pre.ssz + blocks_*.ssz 형태 (run_test_suite.py에서 사용)
    2. state_*.ssz + block_*.ssz 형태 (기존 형태)
    
    각 block에 대해 원본 pre/state에서 독립적으로 처리합니다.
    """
    tools = ["lighthouse", "prysm", "nimbus", "teku", "lodestar"]
    paths = {}

    for tool in tools:
        output_dir = os.path.join(output_parent_dir, f"{tool}/output")
        os.makedirs(output_dir, exist_ok=True)
        paths[tool] = {"output_dir": output_dir}

    # pre.ssz 파일 찾기 (run_test_suite.py 형태)
    pre_ssz = os.path.join(state_dir, "pre.ssz")
    if os.path.exists(pre_ssz):
        # blocks_*.ssz 파일들 찾기
        block_files = sorted([f for f in os.listdir(block_dir) if f.startswith("blocks_") and f.endswith(".ssz")])
        
        for block_file in block_files:
            # block 번호 추출 (blocks_0.ssz -> 0)
            block_index = block_file.replace("blocks_", "").replace(".ssz", "")
            block_path = os.path.join(block_dir, block_file)
            
            paths_per_pair = {
                tool: {
                    "output": os.path.join(paths[tool]["output_dir"], f"poststate_{block_index}.ssz"),
                }
                for tool in tools
            }
            
            yield pre_ssz, block_path, paths_per_pair
        return
    
    # 기존 형태: state_*.ssz + block_*.ssz
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
                    }
                    for tool in tools
                }

                yield state_path, block_path, paths_per_pair


def process_clients(state, block, paths, spectec_core_dir=None):
    """
    spectec-core 디렉터리 경로를 받아서 testing_clients 경로를 올바르게 설정
    """
    if spectec_core_dir is None:
        # 현재 스크립트 위치에서 spectec-core 디렉터리 찾기
        script_dir = Path(__file__).parent.resolve()
        spectec_core_dir = script_dir
    
    # testing_clients 경로 설정
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    
    # Lodestar transition.js 파일 경로 확인
    lodestar_transition = testing_clients_dir / "lodestar" / "transition.js"
    if not lodestar_transition.exists():
        # transition.js가 없으면 기본 경로 사용
        lodestar_transition = testing_clients_dir / "lodestar" / "transition"

    # Pure Capella config 경로 설정
    pure_capella_configs_dir = spectec_core_dir / "Converter" / "pure_capella_configs"
    lighthouse_testnet_dir = pure_capella_configs_dir / "lighthouse_testnet"
    # Note: teku_config and nimbus_config are not used (Teku uses CLI args, Nimbus uses code override)

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
                "verifyProposer=true",  # Enable signature verification (validate_result = true)
                "verifyStateRoot=true",  # Enable state root verification
            ]),
        Clients(
            "Lighthouse",
            str(testing_clients_dir / "lighthouse" / "target" / "release" / "lcli"),
            [
                "transition-blocks",
                "--pre-state-path", state,
                "--block-path", block,
                "--post-state-output-path", paths["lighthouse"]["output"],
                # Pure Capella config: CAPELLA_FORK_EPOCH = 0
                "--testnet-dir", str(lighthouse_testnet_dir),
                # validate_result = true: Signature verification enabled by default (BlockSignatureStrategy::VerifyIndividual)
                # State root verification also enabled by default
                # Cache builds: --exclude-cache-builds flag is NOT set (default: false)
                # This means caches will be built (line 314: if !config.exclude_cache_builds)
                # Note: Setting --exclude-cache-builds causes assertion failure: pre_state.all_caches_built()
                # Lighthouse requires caches to be built for state transition
            ]),
        Clients(
            "Prysm",
            str(testing_clients_dir / "prysm" / "bazel-bin" / "tools" / "pcli" / "pcli_" / "pcli"),
            [
                "state-transition",
                f"--block-path={block}",
                f"--pre-state-path={state}",
                f"--expected-post-state-path={paths['prysm']['output']}"
                # validate_result = true: Signature verification and state root verification enabled by default
            ]),
        Clients(
            "Nimbus",
            str(testing_clients_dir / "nimbus-eth2" / "ncli" / "ncli"),
            [
                "transition",
                state,
                block,
                paths["nimbus"]["output"],
                "true"  # Enable state root verification (validate_result = true: both signature and state root verification required)
            ]),
        Clients(
            "Teku",
            str(testing_clients_dir / "teku" / "build" / "install" / "teku" / "bin" / "teku"),
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
                # validate_result = true: Signature verification and state root verification enabled by default
            ]),

    ]

    for client in clients:
        try:
            print(f"\n[+] Running: {client.name}")

            if not client.available:
                raise FileNotFoundError(f"[X] Not available: {client.cmd_path}")

            client.state = state
            client.block = block

            print(f"[+] Command: {client.cmd_path} {' '.join(client.cmd_args)}")
            cmd = [str(client.cmd_path)] + client.cmd_args

            start_time = perf_counter()
            process = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            end_time = perf_counter()

            client.status_code = process.returncode
            client.output = process 
            client.timestamp = end_time - start_time
            
            #print(client.status_code)
            #print(client.output)
            
            print(f"[+] Execution time: {client.timestamp}")
            
            # 올바른 분류 기준 적용
            if process.returncode == 0:
                client.status_code = 0  # SUCCESS
            elif process.returncode < 0:
                client.status_code = 2  # UNHANDLED_EXCEPTION (시그널에 의한 종료)
            else:
                client.status_code = 1  # FAIL (1, 2, 3, 4... 모든 양수 에러)
            
            # Lodestar 특별 처리: stderr 파싱에 실패하면 2로 설정
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
                                    # stderr에서 파싱한 statusCode를 사용하되, 올바른 분류 적용
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
                                # stderr에서 파싱한 statusCode를 사용하되, 올바른 분류 적용
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


def state_transition(state_dir, block_dir, output_parent_dir, spectec_core_dir=None):
    """
    spectec_core_dir: spectec-core 디렉터리 경로 (testing_clients 경로를 찾기 위해 사용)
    Returns: successful_clients_by_index dict mapping index to list of successful client names
    """
    eth2_clients_results = []
    all_results = [] 
    all_times = []
    all_status  = []  
    successful_clients_by_index = {}

    for state, block, paths in parse_state_block(state_dir, block_dir, output_parent_dir):
        print(f"[+] Processing pair: {state} and {block}")
        eth2_clients = process_clients(state, block, paths, spectec_core_dir=spectec_core_dir)
        eth2_clients_results.extend(eth2_clients)
        print(f"\n\n")

        # Extract index from state or block filename
        if "pre.ssz" in state:
            # For pre.ssz format, extract from block filename
            block_file = os.path.basename(block)
            index = block_file.replace("blocks_", "").replace(".ssz", "")
        else:
            # For state_*.ssz format
            index = state.split("_")[-1].split(".")[0]
        
        pair_results = {'Pair #': index, 
                        'Successful Transition': [], 
                        'Handled Exception': [], 
                        'Unhandled Errors': []
                        }
        pair_times = {'Pair #': index}
        pair_status = {'Pair #': index}
        
        for client in eth2_clients:
            # parse logs before storing them in arrays, unnecessary portion of logs hinders readability
            parsed_log = parse_output(client)
            pair_results[client.name] = parsed_log
            labelled = f"{client.status_code}({STATUS_LABEL.get(client.status_code, 'UNKNOWN')})"
            pair_status[client.name] = labelled

            if(client.status_code == 0):
                pair_results['Successful Transition'].append(client.name)
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

def find_test_case_dirs(test_suite_dir):
    """
    테스트 스위트 디렉터리에서 모든 테스트 케이스 디렉터리를 찾습니다.
    각 테스트 케이스 디렉터리는 pre.ssz 파일을 포함해야 합니다.
    """
    test_suite_path = Path(test_suite_dir).resolve()
    test_case_dirs = []
    
    # pre.ssz 파일이 있는 모든 디렉터리 찾기
    for pre_file in test_suite_path.rglob("pre.ssz"):
        test_case_dirs.append(pre_file.parent)
    
    return sorted(test_case_dirs)


def main():
    """
    CLI 인터페이스: 로컬 SSZ 파일로 state transition 실행
    """
    parser = argparse.ArgumentParser(description="Differential testing tool for eth2-clients")
    
    
    parser.add_argument("--test-suite", type=str, default=None,
                       help="Test suite directory (e.g., Converter/OfficialTestSuite/sanity/_results). "
                            "If provided, automatically finds all test cases with pre.ssz files.")
    parser.add_argument("beaconstate_dir_path", nargs="?", default=None,
                       help="Path to beaconstate files dir (required if --test-suite is not used)")
    parser.add_argument("block_dir_path", nargs="?", default=None,
                       help="Path to block files dir (required if --test-suite is not used)")
    parser.add_argument("output", nargs="?", default=None,
                       help="Path to output directory (required if --test-suite is not used)")                   
    parser.add_argument("--output-base", type=str, default=None,
                       help="Base output directory when using --test-suite (default: test_suite_dir/client_results)")

    args = parser.parse_args()

    # spectec-core 디렉터리 찾기
    script_dir = Path(__file__).parent.resolve()
    
    start_time = perf_counter()
    
    # 테스트 스위트 모드
    if args.test_suite:
        test_suite_path = Path(args.test_suite).resolve()
        if not test_suite_path.exists():
            print(f"Error: Test suite directory not found: {test_suite_path}")
            sys.exit(1)
        
        # 모든 테스트 케이스 찾기
        test_case_dirs = find_test_case_dirs(args.test_suite)
        
        if not test_case_dirs:
            print(f"No test cases found in {test_suite_path}")
            print("Looking for directories containing pre.ssz files...")
            sys.exit(1)
        
        print(f"Found {len(test_case_dirs)} test case(s)")
        
        # 출력 디렉터리 설정
        if args.output_base:
            output_base = Path(args.output_base).resolve()
        else:
            output_base = test_suite_path / "client_results"
        
        # 각 테스트 케이스 처리
        total_passed = 0
        total_failed = 0
        
        for test_case_dir in test_case_dirs:
            # 테스트 케이스 이름 생성
            try:
                relative_path = test_case_dir.relative_to(test_suite_path)
                test_name = str(relative_path).replace(os.sep, "_").replace("/", "_")
            except ValueError:
                test_name = test_case_dir.name
            
            # 출력 디렉터리 설정
            output_dir = output_base / test_name
            
            print(f"\n{'='*60}")
            print(f"Processing test case: {test_name}")
            print(f"Directory: {test_case_dir}")
            print(f"Output: {output_dir}")
            print(f"{'='*60}")
            
            # state_transition 실행
            try:
                successful_clients_by_index = state_transition(
                    str(test_case_dir),
                    str(test_case_dir),
                    str(output_dir),
                    spectec_core_dir=script_dir
                )
                
                # SSZ 파일 비교 실행 (성공한 클라이언트만 비교)
                compare_ssz_files_in_output(str(output_dir), successful_clients_by_index)
                
                print(f"✓ Completed: {test_name}")
                total_passed += 1
            except Exception as e:
                print(f"✗ Failed: {test_name} - {e}")
                total_failed += 1
        
        # 요약
        print(f"\n{'='*60}")
        print("SUMMARY")
        print(f"{'='*60}")
        print(f"Total test cases: {len(test_case_dirs)}")
        print(f"Passed: {total_passed}")
        print(f"Failed: {total_failed}")
        print(f"Results directory: {output_base}")
        
    # 단일 디렉터리 모드 (기존 방식)
    else:
        if not args.beaconstate_dir_path or not args.block_dir_path or not args.output:
            parser.error("beaconstate_dir_path, block_dir_path, and output are required when --test-suite is not used")
        
        successful_clients_by_index = state_transition(
            args.beaconstate_dir_path,
            args.block_dir_path,
            args.output,
            spectec_core_dir=script_dir
        )
        
        # SSZ 파일 비교 실행 (성공한 클라이언트만 비교)
        compare_ssz_files_in_output(args.output, successful_clients_by_index)
    
    end_time = perf_counter()
    
    print(f"\n[+] Total process time (seconds) : {end_time - start_time}")

if __name__ == "__main__":
    main()

