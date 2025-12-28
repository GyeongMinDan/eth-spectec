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
    snappy 파일을 압축 해제합니다.
    
    Args:
        converter_dir: Converter 디렉터리 경로
        input_file: 입력 snappy 파일 경로
        output_file: 출력 SSZ 파일 경로
    """
    snappy_decompressor = Path(converter_dir) / "Converter" / "snappyDecompressor.py"
    if not snappy_decompressor.exists():
        # 스크립트가 spectec-core 디렉터리에 있는 경우
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
    state_dir와 block_dir에서 SSZ 파일 쌍을 찾아서 yield합니다.
    
    지원하는 파일 형태:
    1. pre.ssz_snappy + blocks_*.ssz_snappy 형태 (OfficialTestSuite 원본)
    2. pre.ssz + blocks_*.ssz 형태 (run_test_suite.py에서 사용)
    3. pre_*.ssz + blocks_0.ssz 형태 (state mutation 도구 출력)
    4. state_*.ssz + block_*.ssz 형태 (기존 형태)
    
    .ssz_snappy 파일이 있으면 자동으로 .ssz로 변환합니다.
    각 block에 대해 원본 pre/state에서 독립적으로 처리합니다.
    """
    tools = ["lighthouse", "prysm", "nimbus", "teku", "lodestar"]
    paths = {}

    for tool in tools:
        output_dir = os.path.join(output_parent_dir, f"{tool}/output")
        os.makedirs(output_dir, exist_ok=True)
        paths[tool] = {
            "output_dir": output_dir,
            "cov_output_base": os.path.join(output_parent_dir, f"{tool}")  # cov_output_{index} 생성을 위한 base
        }

    # pre.ssz 또는 pre.ssz_snappy 파일 찾기
    pre_ssz = os.path.join(state_dir, "pre.ssz")
    pre_snappy = os.path.join(state_dir, "pre.ssz_snappy")
    
    # 변환이 필요한지 확인
    needs_decompression = False
    decompressed_dir = None
    
    # .ssz_snappy 파일이 있으면 .ssz로 변환
    if os.path.exists(pre_snappy) and not os.path.exists(pre_ssz):
        needs_decompression = True
        # 변환된 파일들을 저장할 임시 디렉터리 (output_parent_dir 내부)
        decompressed_dir = os.path.join(output_parent_dir, "_decompressed")
        os.makedirs(decompressed_dir, exist_ok=True)
        
        if converter_dir is None:
            # 스크립트 위치에서 spectec-core 디렉터리 찾기
            script_dir = Path(__file__).parent.resolve()
            converter_dir = script_dir
        
        decompressed_pre = os.path.join(decompressed_dir, "pre.ssz")
        print(f"[+] Decompressing {pre_snappy} -> {decompressed_pre}")
        if not decompress_snappy(converter_dir, pre_snappy, decompressed_pre):
            print(f"[!] Failed to decompress pre.ssz_snappy, skipping...")
            # 실패 시 빈 디렉터리 정리
            if decompressed_dir and os.path.exists(decompressed_dir) and not os.listdir(decompressed_dir):
                os.rmdir(decompressed_dir)
            return
        if os.path.exists(decompressed_pre):
            print(f"[+] Successfully decompressed pre.ssz to {decompressed_pre}")
        pre_ssz = decompressed_pre
    
    if os.path.exists(pre_ssz):
        # blocks_*.ssz 또는 blocks_*.ssz_snappy 파일들 찾기 (숫자 순서로 정렬)
        block_ssz_files = sorted(
            [f for f in os.listdir(block_dir) if f.startswith("blocks_") and f.endswith(".ssz")],
            key=lambda f: int(f.replace("blocks_", "").replace(".ssz", "")) if f.replace("blocks_", "").replace(".ssz", "").isdigit() else float('inf')
        )
        block_snappy_files = sorted(
            [f for f in os.listdir(block_dir) if f.startswith("blocks_") and f.endswith(".ssz_snappy")],
            key=lambda f: int(f.replace("blocks_", "").replace(".ssz_snappy", "")) if f.replace("blocks_", "").replace(".ssz_snappy", "").isdigit() else float('inf')
        )
        
        # .ssz_snappy 파일이 있으면 .ssz로 변환
        if block_snappy_files and not block_ssz_files:
            # 변환이 필요한데 디렉터리가 없으면 생성
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
        
        # 변환된 파일 경로 결정
        use_decompressed = (decompressed_dir is not None and decompressed_dir in pre_ssz) or (block_snappy_files and not os.path.exists(os.path.join(block_dir, "blocks_0.ssz")))
        
        for block_file in block_ssz_files:
            block_index = block_file.replace("blocks_", "").replace(".ssz", "")
            
            # 변환된 파일이면 decompressed_dir에서, 아니면 원본 디렉터리에서 찾기
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
            
            # 각 block마다 독립적인 cov_output 디렉토리 생성
            for tool in tools:
                os.makedirs(paths_per_pair[tool]["cov_output"], exist_ok=True)
            
            yield pre_ssz, block_path, paths_per_pair
        return
    
    # 새 형태: pre_*.ssz (여러 mutated states) + blocks_0.ssz (하나의 block)
    # state mutation으로 생성된 케이스용
    pre_files = sorted(
        [f for f in os.listdir(state_dir) if f.startswith("pre_") and f.endswith(".ssz")],
        key=lambda f: int(f.replace("pre_", "").replace(".ssz", "")) if f.replace("pre_", "").replace(".ssz", "").isdigit() else float('inf')
    )
    
    if pre_files:
        # blocks_0.ssz 파일 찾기 (하나의 원본 block)
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
                
                # 각 state마다 독립적인 cov_output 디렉토리 생성
                for tool in tools:
                    os.makedirs(paths_per_pair[tool]["cov_output"], exist_ok=True)
                
                yield state_path, block_path, paths_per_pair
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
                        "cov_output": os.path.join(paths[tool]["cov_output_base"], f"cov_output_{state_index}")
                    }
                    for tool in tools
                }

                # 각 state마다 독립적인 cov_output 디렉토리 생성
                for tool in tools:
                    os.makedirs(paths_per_pair[tool]["cov_output"], exist_ok=True)

                yield state_path, block_path, paths_per_pair


def process_clients(state, block, paths, spectec_core_dir=None, enable_coverage=False):
    """
    spectec-core 디렉터리 경로를 받아서 testing_clients 경로를 올바르게 설정
    
    Args:
        state: pre-state SSZ 파일 경로
        block: block SSZ 파일 경로
        paths: 출력 경로 딕셔너리 (각 클라이언트의 output, cov_output 경로 포함)
        spectec_core_dir: spectec-core 디렉터리 경로
        enable_coverage: 커버리지 측정 활성화 여부
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

    # 커버리지 데이터 디렉토리 설정 (paths에서 가져옴)
    coverage_dirs = {}
    if enable_coverage:
        # 각 클라이언트별 커버리지 디렉토리는 paths에 이미 포함되어 있음
        for client_name in ["prysm", "lighthouse", "teku", "nimbus", "lodestar"]:
            if client_name in paths and "cov_output" in paths[client_name]:
                coverage_dirs[client_name] = Path(paths[client_name]["cov_output"])
                coverage_dirs[client_name].mkdir(parents=True, exist_ok=True)
    
    # 클라이언트 바이너리 경로: 커버리지 모드일 때는 별도 바이너리 사용
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
            # start_time을 try 블록 시작 부분에서 초기화 (예외 발생 시 참조 가능하도록)
            start_time = perf_counter()
            
            print(f"\n[+] Running: {client.name}")

            if not client.available:
                raise FileNotFoundError(f"[X] Not available: {client.cmd_path}")

            client.state = state
            client.block = block

            print(f"[+] Command: {client.cmd_path} {' '.join(str(arg) for arg in client.cmd_args)}")
            # 모든 인자를 문자열로 변환 (Path 객체가 포함될 수 있음)
            cmd = [str(client.cmd_path)] + [str(arg) for arg in client.cmd_args]

            # 커버리지 환경변수 설정
            env = os.environ.copy()
            if enable_coverage:
                client_name_lower = client.name.lower()
                
                if client.name == "Prysm":
                    # Go: GOCOVERDIR 환경변수 설정
                    env["GOCOVERDIR"] = str(coverage_dirs["prysm"])
                    print(f"[+] Coverage enabled: GOCOVERDIR={env['GOCOVERDIR']}")
                
                elif client.name == "Lighthouse":
                    # Rust: LLVM_PROFILE_FILE 환경변수 설정
                    profile_file = coverage_dirs["lighthouse"] / f"lighthouse-cov-%p-%m.profraw"
                    env["LLVM_PROFILE_FILE"] = str(profile_file)
                    print(f"[+] Coverage enabled: LLVM_PROFILE_FILE={env['LLVM_PROFILE_FILE']}")
                
                elif client.name == "Teku":
                    # Java: JaCoCo agent를 JAVA_OPTS로 주입
                    jacoco_agent_path = testing_clients_dir / "jacoco" / "jacocoagent.jar"
                    jacoco_exec = coverage_dirs["teku"] / "teku-coverage.exec"
                    
                    if jacoco_agent_path.exists():
                        env["JAVA_OPTS"] = f"-javaagent:{jacoco_agent_path}=destfile={jacoco_exec}"
                        print(f"[+] Coverage enabled: JAVA_OPTS={env['JAVA_OPTS']}")
                    else:
                        print(f"[!] Warning: JaCoCo agent not found at {jacoco_agent_path}")
                        print(f"[!] Download from: https://www.jacoco.org/jacoco/trunk/doc/agent.html")
                
                elif client.name == "Nimbus":
                    # Nim/C: gcov는 자동으로 .gcda 파일을 생성하므로 특별한 환경변수 불필요
                    # 각 test case마다 독립적인 커버리지를 측정하기 위해
                    # 실행 전에 .gcda 파일을 초기화하고, 실행 후에 복사합니다
                    nimbus_src = testing_clients_dir / "nimbus-eth2"
                    nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                    
                    # 실행 전에 기존 .gcda 파일 삭제 (독립적인 측정을 위해)
                    if nimbus_gcda_dir.exists():
                        for gcda_file in nimbus_gcda_dir.rglob("*.gcda"):
                            try:
                                gcda_file.unlink()
                            except:
                                pass
                    print(f"[+] Coverage enabled: gcov will auto-generate .gcda files in build directory")
                
                elif client.name == "Lodestar":
                    # Node.js: c8을 사용하여 커버리지 측정
                    # c8은 실행 시점에 커버리지를 수집하므로 명령어를 c8로 감싸야 함
                    lodestar_dir = testing_clients_dir / "lodestar"
                    coverage_report_dir = coverage_dirs["lodestar"] / "report"
                    coverage_temp_dir = coverage_dirs["lodestar"]  # JSON 파일 저장 위치
                    coverage_report_dir.mkdir(parents=True, exist_ok=True)
                    coverage_temp_dir.mkdir(parents=True, exist_ok=True)
                    
                    # 원래 node 명령을 c8으로 감싸기
                    # npx c8 --all --reporter=text --reporter=html --report-dir=<coverage_dir> --temp-directory=<temp_dir> --exclude-node-modules=false --include="node_modules/@lodestar/**" node <original_args>
                    original_cmd_path = str(client.cmd_path)
                    # 모든 인자를 문자열로 변환 (Path 객체가 포함될 수 있음)
                    original_cmd_args = [str(arg) for arg in client.cmd_args]
                    
                    # c8 옵션 추가
                    # --exclude-node-modules=false: node_modules를 포함하도록 설정 (기본적으로 제외됨)
                    # --temp-directory: 커버리지 JSON 파일 저장 위치 명시
                    # --include: Lodestar 코드만 포함 (transition.js는 래퍼이므로 제외)
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
                        original_cmd_path,  # node 경로
                    ] + original_cmd_args  # 원래 인자들 (모두 문자열로 변환됨)
                    
                    # npx를 사용하여 c8 실행
                    client.cmd_path = "npx"
                    client.cmd_args = c8_args
                    cmd = ["npx"] + c8_args
                    
                    print(f"[+] Coverage enabled: c8 with report-dir={coverage_report_dir}")
                    print(f"[+] Coverage temp-directory: {coverage_temp_dir}")
                    print(f"[+] Coverage command: npx {' '.join(c8_args)}")

            # cwd 설정 (Lodestar 커버리지 모드일 때만 lodestar 디렉토리로 설정)
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
            
            # Nimbus: 각 test case마다 독립적인 커버리지를 위해 .gcda 파일을 복사
            if client.name == "Nimbus" and enable_coverage:
                nimbus_src = testing_clients_dir / "nimbus-eth2"
                nimbus_gcda_dir = nimbus_src / "nimcache" / "debug" / "ncli"
                nimbus_coverage_dir = coverage_dirs.get("nimbus")
                
                if nimbus_coverage_dir and nimbus_gcda_dir.exists():
                    # cov_output_{index} 디렉토리에 nimcache 구조를 그대로 복사
                    target_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
                    target_gcda_dir.mkdir(parents=True, exist_ok=True)
                    
                    # .gcda 파일만 복사 (각 테스트 케이스마다 독립적)
                    # .gcno 파일은 리포트 생성 시 원본 nimcache에서 가져와서 일관된 측정 범위 보장
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
    spectec_core_dir: spectec-core 디렉터리 경로 (testing_clients 경로를 찾기 위해 사용)
    workflow: "independent" (기본) 또는 "sequential" 모드
    enable_coverage: 커버리지 측정 활성화 여부
    Returns: successful_clients_by_index dict mapping index to list of successful client names
    """
    eth2_clients_results = []
    all_results = [] 
    all_times = []
    all_status  = []  
    successful_clients_by_index = {}

    if workflow == "sequential":
        # Sequential 모드: pre -> blocks_0 -> postState_0 -> blocks_1 -> ...
        # 모든 block을 먼저 수집
        block_pairs = list(parse_state_block(state_dir, block_dir, output_parent_dir, converter_dir=spectec_core_dir))
        
        if not block_pairs:
            return successful_clients_by_index
        
        # 첫 번째 block의 원본 pre 상태 저장
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
            
            # 다음 block의 pre로 사용할 postState 결정 (성공한 클라이언트 중 하나 선택)
            # 모든 클라이언트가 같은 결과를 생성해야 하므로 첫 번째 성공한 클라이언트의 결과 사용
            next_state = None
            for client in eth2_clients:
                # client.name은 "Lighthouse", "Prysm" 등 대문자로 시작, paths 키는 소문자
                client_key = client.name.lower()
                if client.status_code == 0 and client_key in paths and os.path.exists(paths[client_key]["output"]):
                    next_state = paths[client_key]["output"]
                    break
            
            if next_state is None:
                print(f"[!] No successful client output found for block {block_index}, stopping sequential execution")
                break
            
            current_state = next_state
    else:
        # Independent 모드 (기본): 각 block을 원본 pre 상태에서 독립적으로 처리
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
                # parse logs before storing them in arrays, unnecessary portion of logs hinders readability
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
    테스트 케이스별 커버리지 데이터를 분석하여 HTML 리포트 생성
    각 block/state index마다 독립적인 cov_output_{index} 디렉토리의 리포트를 생성
    
    Args:
        output_dir: 테스트 케이스 출력 디렉토리 (예: node_result_mutated_case_insight_with_log/invalid_all_zeroed_sig)
        spectec_core_dir: spectec-core 디렉토리 경로
        cleanup_after_report: 리포트 생성 후 원본 커버리지 데이터 삭제 여부
    """
    output_path = Path(output_dir)
    testing_clients_dir = Path(spectec_core_dir) / "testing_clients"
    
    print(f"\n{'='*60}")
    print(f"Generating Coverage Reports for: {output_path.name}")
    print(f"{'='*60}\n")
    
    # 각 클라이언트의 cov_output_* 디렉토리들을 찾아서 처리
    clients = ["prysm", "lighthouse", "teku", "nimbus", "lodestar"]
    
    for client in clients:
        client_dir = output_path / client
        if not client_dir.exists():
            continue
        
        # cov_output_{index} 형태의 디렉토리 찾기
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
            
            # 리포트 생성 후 원본 데이터 삭제 (옵션)
            if cleanup_after_report:
                _cleanup_coverage_data(cov_dir, client)
    
    print(f"\n{'='*60}")
    print(f"Coverage reports saved in: {output_path}")
    print(f"{'='*60}\n")


def _generate_prysm_report(prysm_coverage_dir, testing_clients_dir):
    """Prysm (Go) 커버리지 리포트 생성"""
    if not prysm_coverage_dir.exists():
        return
    
    # 커버리지 데이터 파일이 있는지 확인
    cov_files = list(prysm_coverage_dir.glob("covcounters.*"))
    if not cov_files:
        return
    
    prysm_report_dir = prysm_coverage_dir / "report"
    prysm_report_dir.mkdir(exist_ok=True)
    prysm_dir = testing_clients_dir / "prysm"
    
    try:
        # go tool covdata textfmt로 텍스트 포맷 변환
        coverage_txt = prysm_report_dir / "coverage.txt"
        subprocess.run(
            ["go", "tool", "covdata", "textfmt", f"-i={prysm_coverage_dir}", f"-o={coverage_txt}"],
            check=True,
            capture_output=True,
            text=True
        )
        
        # go tool cover로 HTML 리포트 생성 (Prysm 디렉토리에서 실행)
        coverage_html = prysm_report_dir / "coverage.html"
        # Prysm 디렉토리 기준 상대 경로 계산
        rel_coverage_txt = Path(os.path.relpath(coverage_txt, prysm_dir))
        rel_coverage_html = Path(os.path.relpath(coverage_html, prysm_dir))
        
        subprocess.run(
            ["go", "tool", "cover", f"-html={rel_coverage_txt}", f"-o={rel_coverage_html}"],
            check=True,
            capture_output=True,
            text=True,
            cwd=str(prysm_dir)  # Prysm 디렉토리에서 실행 (go.mod 필요)
        )
        
        # 전체 커버리지 통계 계산 및 HTML에 추가
        _add_prysm_coverage_stats(coverage_txt, coverage_html, prysm_dir, prysm_coverage_dir)
        
        print(f"    ✓ Report: {prysm_report_dir / 'coverage.html'}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")


def _add_prysm_coverage_stats(coverage_txt, coverage_html, prysm_dir, prysm_coverage_dir):
    """Prysm HTML 리포트에 전체 통계 추가"""
    try:
        # go tool covdata percent로 패키지별 통계 수집
        result = subprocess.run(
            ["go", "tool", "covdata", "percent", f"-i={prysm_coverage_dir}"],
            cwd=str(prysm_dir),
            capture_output=True,
            text=True,
            check=True
        )
        
        # 패키지별 통계 파싱
        # 형식: "package_name    coverage: XX.X% of statements"
        package_stats = []
        for line in result.stdout.strip().split('\n'):
            if 'coverage:' in line:
                parts = line.split()
                package = parts[0].strip()
                coverage = parts[-3]  # "XX.X%" (parts[-2]는 "of", parts[-1]은 "statements")
                package_stats.append((package, coverage))
        
        # go tool cover -func로 전체 statement coverage 계산
        func_result = subprocess.run(
            ["go", "tool", "cover", f"-func={coverage_txt}"],
            cwd=str(prysm_dir),
            capture_output=True,
            text=True,
            check=True
        )
        
        # 마지막 줄에서 "total: (statements) XX.X%" 추출
        total_coverage = 0.0
        lines = func_result.stdout.strip().split('\n')
        if lines:
            last_line = lines[-1]
            if last_line.startswith('total:'):
                # "total: (statements) 11.3%" 형식
                coverage_str = last_line.split()[-1].rstrip('%')
                total_coverage = float(coverage_str)
        
        # HTML에 통계 박스 추가
        with open(coverage_html, 'r') as f:
            html_content = f.read()
        
        # 통계 박스 HTML 생성
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
        
        # <div id="content"> 다음에 통계 박스 삽입
        html_content = html_content.replace(
            '<div id="content">',
            f'<div id="content">{stats_html}'
        )
        
        with open(coverage_html, 'w') as f:
            f.write(html_content)
            
    except Exception as e:
        print(f"    ⚠ Could not add statistics: {e}")


def _generate_lighthouse_report(lighthouse_coverage_dir, testing_clients_dir):
    """Lighthouse (Rust) 커버리지 리포트 생성 (llvm-cov 사용)
    
    Rust source-based coverage는 다음 메트릭을 제공:
    - Region Coverage: 조건 분기 커버리지 (if/match 등)
    - Function Coverage: 함수 호출 여부
    - Instantiation Coverage: 제네릭/매크로 인스턴스
    - Line Coverage: 라인 실행 여부
    
    주의: "Branches" 컬럼은 항상 0/0으로 표시됨 (LLVM IR branch는 수집 안됨).
          조건 분기는 "Region Coverage"로 측정됨.
    """
    if not lighthouse_coverage_dir.exists():
        return
    
    # .profraw 파일이 있는지 확인
    profraw_files = list(lighthouse_coverage_dir.glob("*.profraw"))
    if not profraw_files:
        return
    
    lighthouse_report_dir = lighthouse_coverage_dir / "report"
    lighthouse_report_dir.mkdir(exist_ok=True)
    lighthouse_src = testing_clients_dir / "lighthouse"
    lighthouse_binary = lighthouse_src / "target" / "release" / "lcli-cov"
    
    try:
        # Rust toolchain의 llvm-tools 경로 찾기
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
        
        # 1. profraw를 profdata로 변환
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
        
        # 2. HTML 리포트 생성
        html_dir = lighthouse_report_dir / "html"
        html_dir.mkdir(exist_ok=True)
        subprocess.run(
            [
                str(llvm_cov), "show",
                str(lighthouse_binary),
                f"--instr-profile={profdata_file}",
                "--format=html",
                f"--output-dir={html_dir}",
                "--ignore-filename-regex=/.cargo",
                "--show-line-counts-or-regions",
                "--show-instantiations"
            ],
            check=True,
            capture_output=True,
            text=True
        )
        
        # 3. 텍스트 요약 생성
        summary_file = lighthouse_report_dir / "summary.txt"
        result = subprocess.run(
            [
                str(llvm_cov), "report",
                str(lighthouse_binary),
                f"--instr-profile={profdata_file}",
                "--ignore-filename-regex=/.cargo",
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
        
    except FileNotFoundError as e:
        print(f"    ✗ Tool not found: {e}")
    except subprocess.CalledProcessError as e:
        print(f"    ✗ Failed: {e}")


def _generate_teku_report(teku_coverage_dir, testing_clients_dir):
    """Teku (Java) 커버리지 리포트 생성"""
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
        # Teku jar 파일들만 찾기 (teku-*.jar)
        teku_lib_dir = testing_clients_dir / "teku" / "build" / "install" / "teku-cov" / "lib"
        teku_jars = list(teku_lib_dir.glob("teku-*.jar"))
        
        if not teku_jars:
            print(f"    ✗ No Teku jar files found in {teku_lib_dir}")
            return
        
        # 각 jar 파일에 대해 --classfiles 추가
        classfiles_args = []
        for jar in teku_jars:
            classfiles_args.extend(["--classfiles", str(jar)])
        
        subprocess.run(
            [
                "java", "-jar", str(jacoco_cli),
                "report", str(teku_exec),
            ] + classfiles_args + [
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
    """Nimbus (Nim/C with gcov) 커버리지 리포트 생성
    각 test case마다 독립적인 커버리지를 위해 cov_output_{index} 디렉토리의 .gcda 파일을 사용
    """
    nimbus_src = testing_clients_dir / "nimbus-eth2"
    if not nimbus_src.exists():
        return
    
    nimbus_report_dir = nimbus_coverage_dir / "report"
    nimbus_report_dir.mkdir(parents=True, exist_ok=True)
    
    # cov_output_{index} 디렉토리에 복사된 .gcda 파일이 있는지 확인
    nimbus_gcda_dir = nimbus_coverage_dir / "nimcache" / "debug" / "ncli"
    
    try:
        # lcov 명령어 확인
        subprocess.run(["lcov", "--version"], check=True, capture_output=True)
        
        # lcov로 커버리지 정보 수집
        coverage_info = nimbus_report_dir / "coverage.info"
        
        # cov_output_{index} 디렉토리에 .gcda 파일이 있으면 해당 디렉토리 사용
        # 없으면 원본 nimcache 디렉토리 사용 (하위 호환성)
        nimbus_cov_nimcache_root = nimbus_coverage_dir / "nimcache"
        if nimbus_cov_nimcache_root.exists() and any(nimbus_cov_nimcache_root.rglob("*.gcda")):
            # 복사된 .gcda 파일이 있는 경우: 해당 디렉토리의 .gcda와 원본 nimcache의 .gcno를 함께 사용
            # .gcno 파일은 컴파일 시 생성되므로 원본 nimcache에서 참조하여 일관된 측정 범위 보장
            # .gcda 파일은 각 테스트 케이스마다 다르므로 cov_output_{index}에서 사용
            capture_dir = nimbus_cov_nimcache_root
            original_nimcache = nimbus_src / "nimcache"
            
            import shutil
            
            # 리포트 생성 전에 capture_dir를 완전히 비워서 잔여 .gcno 파일 제거
            # 이렇게 하면 각 리포트마다 정확히 동일한 .gcno 집합을 사용하여 LOC 고정
            # .gcda 파일은 이미 capture_dir에 있으므로 백업 후 복원
            gcda_backup = {}
            if capture_dir.exists():
                # .gcda 파일 백업 (각 테스트 케이스의 실행 데이터)
                for gcda_file in capture_dir.rglob("*.gcda"):
                    relative_path = gcda_file.relative_to(nimbus_cov_nimcache_root)
                    gcda_backup[relative_path] = gcda_file.read_bytes()
                
                # capture_dir 삭제 (모든 파일 제거하여 깨끗한 상태로 시작)
                shutil.rmtree(capture_dir, ignore_errors=True)
            
            capture_dir.mkdir(parents=True, exist_ok=True)
            
            # 원본 nimcache의 .gcno 파일들을 capture_dir에 전체 복사 (조건 없이 덮어쓰기)
            # .gcno와 .gcda의 상대 경로가 일치해야 lcov가 매칭 가능
            if original_nimcache.exists():
                # .gcno 파일 전체 복사 (상대 경로: debug/ncli/.../*.gcno)
                for gcno_file in original_nimcache.rglob("*.gcno"):
                    relative_path = gcno_file.relative_to(original_nimcache)
                    target_gcno = capture_dir / relative_path
                    target_gcno.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(gcno_file, target_gcno)
            
            # 백업한 .gcda 파일 복원 (상대 경로: debug/ncli/.../*.gcda)
            # 이렇게 하면 .gcno와 .gcda가 같은 상대 경로에 있어서 lcov가 정확히 매칭
            for relative_path, gcda_data in gcda_backup.items():
                target_gcda = capture_dir / relative_path
                target_gcda.parent.mkdir(parents=True, exist_ok=True)
                target_gcda.write_bytes(gcda_data)
            
            subprocess.run(
                [
                    "lcov", "--capture",
                    "--directory", str(capture_dir),
                    "--base-directory", str(nimbus_src),
                    "--output-file", str(coverage_info)
                ],
                check=True,
                capture_output=True,
                text=True
            )
        else:
            # 기존 방식: nimbus_src 전체를 스캔
            subprocess.run(
                [
                    "lcov", "--capture",
                    "--directory", str(nimbus_src),
                    "--output-file", str(coverage_info)
                ],
                check=True,
                capture_output=True,
                text=True
            )
        
        # generated_not_to_break_here -> 존재하지 않는 파일 필터링 (lcov 에러 남..)
        coverage_clean = nimbus_report_dir / "coverage_clean.info"
        with open(coverage_info, 'r') as infile, open(coverage_clean, 'w') as outfile:
            for line in infile:
                if 'generated_not_to_break_here' not in line:
                    outfile.write(line)
        
        # genhtml로 HTML 리포트 생성 (필터링된 coverage_clean.info 사용)
        subprocess.run(
            [
                "genhtml", str(coverage_clean),
                "--output-directory", str(nimbus_report_dir)
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
    """Lodestar (Node.js) 커버리지 리포트 생성 (c8 사용)
    
    c8이 실행 시점에 리포트를 생성하지만, 리포트가 비어있거나 제대로 생성되지 않았다면
    temp-directory의 JSON 파일들을 사용하여 리포트를 재생성합니다.
    """
    if not lodestar_coverage_dir.exists():
        return
    
    lodestar_dir = testing_clients_dir / "lodestar"
    lodestar_report_dir = lodestar_coverage_dir / "report"
    lodestar_temp_dir = lodestar_coverage_dir  # JSON 파일이 저장된 위치
    
    # temp-directory에 coverage JSON 파일이 있는지 확인
    coverage_json_files = list(lodestar_temp_dir.glob("coverage-*.json"))
    if not coverage_json_files:
        print(f"    ✗ No coverage JSON files found in {lodestar_temp_dir}")
        return
    
    # HTML 리포트가 이미 존재하는지 확인
    html_index = lodestar_report_dir / "index.html"
    needs_regeneration = False
    
    if html_index.exists():
        # 리포트가 비어있는지 확인 (Unknown% 또는 0/0인 경우)
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
    
    # 리포트 재생성이 필요한 경우
    if needs_regeneration:
        try:
            # c8 report 명령으로 리포트 재생성
            # temp-directory의 JSON 파일들을 읽어서 리포트 생성
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
    
    # 최종 리포트 확인 및 통계 출력
    if html_index.exists():
        print(f"    ✓ Report: {html_index}")
        
        # coverage-summary.json 확인
        summary_json = lodestar_report_dir / "coverage-summary.json"
        if summary_json.exists():
            try:
                import json
                with open(summary_json, 'r') as f:
                    summary = json.load(f)
                    # 전체 통계 출력
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
    """리포트 생성 후 원본 커버리지 측정 데이터 삭제
    
    Args:
        cov_dir: cov_output_{index} 디렉토리
        client: 클라이언트 이름 (prysm, lighthouse, teku, nimbus, lodestar)
    """
    import shutil
    
    try:
        if client == "prysm":
            # Prysm: covcounters.* 파일 삭제 (원본 커버리지 데이터)
            for cov_file in cov_dir.glob("covcounters.*"):
                cov_file.unlink()
                print(f"    ✓ Removed: {cov_file.name}")
            # Prysm: covmeta.* 파일도 삭제 (메타데이터 파일, 리포트 생성 후 불필요)
            for covmeta_file in cov_dir.glob("covmeta.*"):
                covmeta_file.unlink()
                print(f"    ✓ Removed: {covmeta_file.name}")
        
        elif client == "lighthouse":
            # Lighthouse: *.profraw 파일 삭제 (원본 데이터)
            for profraw_file in cov_dir.glob("*.profraw"):
                profraw_file.unlink()
                print(f"    ✓ Removed: {profraw_file.name}")
            # Lighthouse: report/lighthouse.profdata 파일도 삭제 (중간 파일, 리포트 생성 후 불필요)
            profdata_file = cov_dir / "report" / "lighthouse.profdata"
            if profdata_file.exists():
                profdata_file.unlink()
                print(f"    ✓ Removed: report/{profdata_file.name}")
        
        elif client == "teku":
            # Teku: teku-coverage.exec 파일 삭제
            exec_file = cov_dir / "teku-coverage.exec"
            if exec_file.exists():
                exec_file.unlink()
                print(f"    ✓ Removed: {exec_file.name}")
        
        elif client == "nimbus":
            # Nimbus: nimcache 디렉토리 전체 삭제
            nimcache_dir = cov_dir / "nimcache"
            if nimcache_dir.exists():
                shutil.rmtree(nimcache_dir)
                print(f"    ✓ Removed: {nimcache_dir.name}/")
        
        elif client == "lodestar":
            # Lodestar: coverage-*.json 파일 삭제 (report 디렉토리는 유지)
            for json_file in cov_dir.glob("coverage-*.json"):
                json_file.unlink()
                print(f"    ✓ Removed: {json_file.name}")
    
    except Exception as e:
        print(f"    ⚠ Warning: Failed to cleanup coverage data: {e}")


def find_test_case_dirs(test_suite_dir):
    test_suite_path = Path(test_suite_dir).resolve()
    test_case_dirs = []
    
    # pre.ssz_snappy 파일이 있는 모든 디렉터리 찾기 (OfficialTestSuite 원본 형태)
    for pre_file in test_suite_path.rglob("pre.ssz_snappy"):
        parent = pre_file.parent
        # 출력 디렉터리 제외: 경로의 어느 부분이든 _로 시작하는 디렉터리 이름이 있으면 제외
        # 예: .../_sanity_independent/... 또는 .../_results/... 등
        parent_parts = parent.parts
        if not any(part.startswith('_') for part in parent_parts):
            test_case_dirs.append(parent)
    
    # pre.ssz 파일이 있는 모든 디렉터리 찾기 (이미 변환된 형태)
    for pre_file in test_suite_path.rglob("pre.ssz"):
        parent = pre_file.parent
        # 중복 제거 및 출력 디렉터리 제외
        parent_parts = parent.parts
        if parent not in test_case_dirs and not any(part.startswith('_') for part in parent_parts):
            test_case_dirs.append(parent)
    
    # pre_*.ssz 파일이 있는 모든 디렉터리 찾기 (state mutation 형태)
    for pre_file in test_suite_path.rglob("pre_*.ssz"):
        parent = pre_file.parent
        # 중복 제거 및 출력 디렉터리 제외
        parent_parts = parent.parts
        if parent not in test_case_dirs and not any(part.startswith('_') for part in parent_parts):
            test_case_dirs.append(parent)
    
    return sorted(test_case_dirs)


def main():
    """
    CLI 인터페이스: 로컬 SSZ 파일로 state transition 실행
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
            print("Looking for directories containing pre.ssz or pre.ssz_snappy files...")
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
                    spectec_core_dir=script_dir,
                    workflow=args.workflow,
                    enable_coverage=args.enable_coverage
                )
                
                # SSZ 파일 비교 실행 (성공한 클라이언트만 비교)
                compare_ssz_files_in_output(str(output_dir), successful_clients_by_index)
                
                # 커버리지 리포트 생성 (각 테스트 케이스별로)
                if args.enable_coverage:
                    generate_coverage_reports_per_testcase(str(output_dir), script_dir, cleanup_after_report=args.cleanup_after_report)
                
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
            spectec_core_dir=script_dir,
            workflow=args.workflow,
            enable_coverage=args.enable_coverage
        )
        
        # SSZ 파일 비교 실행 (성공한 클라이언트만 비교)
        compare_ssz_files_in_output(args.output, successful_clients_by_index)
        
        # 커버리지 리포트 생성 (각 테스트 케이스별로)
        if args.enable_coverage:
            generate_coverage_reports_per_testcase(args.output, script_dir, cleanup_after_report=args.cleanup_after_report)
    
    end_time = perf_counter()
    
    print(f"\n[+] Total process time (seconds) : {end_time - start_time}")

if __name__ == "__main__":
    main()

