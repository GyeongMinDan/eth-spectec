#!/usr/bin/env python3
"""
OfficialTestSuite 테스트 케이스에 대해 전체 워크플로우를 자동으로 실행하는 스크립트

지원 워크플로우 모드:
1. independent (기본): 각 block을 원본 pre 상태에서 독립적으로 처리
   - 기존 run_test_suite.py의 동작 방식
2. sequential: pre -> blocks_0 -> postState_0 -> blocks_1 ... 순으로 연쇄 처리

공통 단계:
1. snappy 파일 압축 해제 (pre.ssz_snappy, blocks_*.ssz_snappy -> pre.ssz, blocks_*.ssz)
2. SSZ를 JSON으로 변환 (pre.ssz -> pre.json, blocks_*.ssz -> blocks_*.json)
3. Spectec 프로그램 실행
4. Spectec 결과를 SSZ로 변환 (spectec_output*.json -> spectec_output*.ssz)
5. eth2specResult.py 실행 (pre.ssz, blocks_*.ssz -> eth2specResult*.ssz)
6. 결과 비교 (spectec_output*.ssz vs eth2specResult*.ssz)
"""

import os
import sys
import csv
import hashlib
import subprocess
import argparse
import glob
import tempfile
import shutil
import time
import traceback
from pathlib import Path
from typing import List, Tuple, Optional


class TestRunner:
    def __init__(
        self,
        converter_dir: str,
        spectec_bin: str = None,
        spec_dir: str = None,
        run_mode: str = "run-il",
        workflow: str = "independent",
        fork: str = "deneb",
    ):
        """
        Args:
            converter_dir: Converter 디렉터리 경로
            spectec_bin: Spectec 실행 파일 경로
            spec_dir: spec 파일들이 있는 디렉터리 (기본값: spectec-core/spec/spec_{fork})
            run_mode: 실행 모드 ("run-il" 또는 "run-sl", 기본값: "run-il")
            workflow: 테스트 워크플로우 모드 ("independent" 또는 "sequential", 기본값: "independent")
            fork: 사용할 fork 이름 (예: "deneb", "capella", 기본값: "deneb")
        """
        self.converter_dir = Path(converter_dir).resolve()
        self.spectec_bin = Path(spectec_bin).resolve() if spectec_bin else None
        self.run_mode = run_mode
        self.workflow = workflow
        self.fork = fork
        
        # 기본 경로 설정
        if spec_dir:
            self.spec_dir = Path(spec_dir).resolve()
        else:
            # spectec-core/spec 디렉터리 찾기
            spectec_core = self.converter_dir.parent
            # spec_deneb 또는 spec_capella 같은 하위 디렉터리 사용
            self.spec_dir = spectec_core / "spec" / f"spec_{fork}"
        
        # 스크립트 경로들
        self.snappy_decompressor = self.converter_dir / "snappyDecompressor.py"
        self.beacon_state_to_json = self.converter_dir / "SSZToJson" / "BeaconStateSSZToJson.py"
        self.signed_block_to_json = self.converter_dir / "SSZToJson" / "SignedBeaconBlockSSZToJson.py"
        self.json_to_ssz_script = self.converter_dir / "JsonToSSZ" / "BeaconStateJsonToSSZ.py"
        self.eth2spec_result = self.converter_dir / "eth2specResult.py"
        self.compare_result = self.converter_dir / "CompareResult.py"
        
        # consensus-specs 경로 (eth2specResult.py에서 사용)
        # converter_dir이 Converter/이면, parent는 spectec-core/, 그 아래에 consensus-specs가 있음
        consensus_specs = self.converter_dir.parent / "consensus-specs"
        self.consensus_specs_path = consensus_specs / "tests" / "core" / "pyspec"
    
    def find_test_cases(self, test_suite_dir: str) -> List[Path]:
        """테스트 케이스 디렉터리들을 찾습니다."""
        test_suite_path = Path(test_suite_dir).resolve()
        test_cases = []
        
        # pre.ssz_snappy가 있는 디렉터리들을 찾습니다
        for pre_file in test_suite_path.rglob("pre.ssz_snappy"):
            test_cases.append(pre_file.parent)
        
        return sorted(test_cases)

    def find_state_transition_test_cases(self, test_suite_dir: str) -> List[Path]:
        """diff_testing.py와 유사한 방식으로 state-transition 테스트 케이스를 찾습니다."""
        test_suite_path = Path(test_suite_dir).resolve()
        test_case_dirs = []

        for pre_file in test_suite_path.rglob("pre.ssz_snappy"):
            parent = pre_file.parent
            parent_parts = parent.parts
            if any(part.startswith('_') for part in parent_parts):
                continue
            if "operations" in parent_parts or "epoch_processing" in parent_parts:
                continue
            if "sanity" in parent_parts and "slots" in parent_parts:
                continue
            test_case_dirs.append(parent)

        for pre_file in test_suite_path.rglob("pre.ssz"):
            parent = pre_file.parent
            parent_parts = parent.parts
            if any(part.startswith('_') for part in parent_parts):
                continue
            if parent in test_case_dirs:
                continue
            if "operations" in parent_parts or "epoch_processing" in parent_parts:
                continue
            if "sanity" in parent_parts and "slots" in parent_parts:
                continue
            test_case_dirs.append(parent)

        for pre_file in test_suite_path.rglob("pre_*.ssz"):
            parent = pre_file.parent
            parent_parts = parent.parts
            if any(part.startswith('_') for part in parent_parts):
                continue
            if parent in test_case_dirs:
                continue
            test_case_dirs.append(parent)

        return sorted(test_case_dirs)

    def iter_eth2spec_state_block_pairs(self, test_case_dir: Path, work_dir: Path) -> List[Tuple[Path, Path, str]]:
        """independent 모드용 state/block pair를 수집합니다."""
        pairs = []
        work_dir.mkdir(parents=True, exist_ok=True)

        pre_ssz = test_case_dir / "pre.ssz"
        pre_snappy = test_case_dir / "pre.ssz_snappy"
        decompressed_dir = None

        if pre_snappy.exists() and not pre_ssz.exists():
            decompressed_dir = work_dir / "_decompressed"
            pre_ssz = decompressed_dir / "pre.ssz"
            if not self.decompress_snappy(pre_snappy, pre_ssz):
                raise RuntimeError(f"Failed to decompress {pre_snappy}")

        if pre_ssz.exists():
            block_ssz_files = sorted(
                [p for p in test_case_dir.iterdir() if p.name.startswith("blocks_") and p.suffix == ".ssz"],
                key=lambda p: int(p.stem.replace("blocks_", "")) if p.stem.replace("blocks_", "").isdigit() else float('inf')
            )
            block_snappy_files = sorted(
                list(test_case_dir.glob("blocks_*.ssz_snappy")),
                key=lambda p: int(p.name.replace("blocks_", "").replace(".ssz_snappy", ""))
                if p.name.replace("blocks_", "").replace(".ssz_snappy", "").isdigit() else float('inf')
            )

            if block_snappy_files and not block_ssz_files:
                decompressed_dir = work_dir / "_decompressed"
                for block_snappy in block_snappy_files:
                    block_num = block_snappy.name.replace("blocks_", "").replace(".ssz_snappy", "")
                    block_ssz = decompressed_dir / f"blocks_{block_num}.ssz"
                    if not self.decompress_snappy(block_snappy, block_ssz):
                        raise RuntimeError(f"Failed to decompress {block_snappy}")
                    block_ssz_files.append(block_ssz)

            use_decompressed_blocks = decompressed_dir is not None and not (test_case_dir / "blocks_0.ssz").exists()

            for block_file in block_ssz_files:
                block_num = block_file.name.replace("blocks_", "").replace(".ssz", "")
                if use_decompressed_blocks and decompressed_dir is not None:
                    current_block = decompressed_dir / block_file.name
                else:
                    current_block = block_file

                if current_block.exists():
                    pairs.append((pre_ssz, current_block, block_num))

            return pairs

        pre_files = sorted(
            list(test_case_dir.glob("pre_*.ssz")),
            key=lambda p: int(p.name.replace("pre_", "").replace(".ssz", ""))
            if p.name.replace("pre_", "").replace(".ssz", "").isdigit() else float('inf')
        )
        if pre_files:
            block_file = None
            for candidate in ("blocks_0.ssz", "block_0.ssz"):
                candidate_path = test_case_dir / candidate
                if candidate_path.exists():
                    block_file = candidate_path
                    break

            if block_file is None:
                return pairs

            for pre_file in pre_files:
                state_index = pre_file.name.replace("pre_", "").replace(".ssz", "")
                pairs.append((pre_file, block_file, state_index))

        return pairs
    
    def decompress_snappy(self, input_file: Path, output_file: Path) -> bool:
        """snappy 파일을 압축 해제합니다."""
        try:
            output_file.parent.mkdir(parents=True, exist_ok=True)
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
        """SSZ 파일을 JSON으로 변환합니다."""
        try:
            if is_beacon_state:
                script = self.beacon_state_to_json
            else:
                script = self.signed_block_to_json
            
            # Fork에 맞는 type-module 지정
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
    
    def json_to_ssz(self, json_file: Path, ssz_file: Path) -> bool:
        """JSON 파일을 SSZ로 변환합니다."""
        try:
            # Fork에 맞는 type-module 지정
            type_module = f"eth2spec.{self.fork}.mainnet"
            
            result = subprocess.run(
                [sys.executable, str(self.json_to_ssz_script), 
                 "--type-module", type_module,
                 "--in", str(json_file), "--out", str(ssz_file)],
                capture_output=True,
                text=True,
                check=True
            )
            return True
        except subprocess.CalledProcessError as e:
            print(f"  ✗ JSON to SSZ conversion failed: {e.stderr}")
            return False
    
    def run_spectec(self, pre_json: Path, block_json: Path, output_json: Path, verbose: bool = False) -> Tuple[bool, Optional[str]]:
        """Spectec 프로그램을 실행합니다."""
        try:
            # spec 파일 찾기 및 파일명 순서대로 정렬
            # 하위 디렉터리도 재귀적으로 검색 (spec_deneb, spec_capella 등)
            spec_files = sorted(self.spec_dir.rglob("*.spectec"), key=lambda f: f.name)
            if not spec_files:
                return False, f"No .spectec files found in {self.spec_dir}"
            
            # spectec-core 디렉터리를 작업 디렉터리로 설정
            spectec_core_dir = self.spectec_bin.parent
            
            # 상대 경로로 변환 (spectec-core 디렉터리 기준)
            try:
                pre_json_rel = pre_json.relative_to(spectec_core_dir)
                block_json_rel = block_json.relative_to(spectec_core_dir)
                output_json_rel = output_json.relative_to(spectec_core_dir)
                # spec_deneb/00-types.spectec 같은 형태로 변환
                spec_args = [str(f.relative_to(spectec_core_dir)) for f in spec_files]
            except ValueError:
                # 상대 경로로 변환할 수 없으면 절대 경로 사용
                pre_json_rel = pre_json
                block_json_rel = block_json
                output_json_rel = output_json
                spec_args = [str(f) for f in spec_files]
            
            # 출력 디렉터리 생성
            output_json.parent.mkdir(parents=True, exist_ok=True)
            
            # spectec-core 디렉터리 기준으로 실행 파일 경로
            spectec_bin_rel = f"./{self.spectec_bin.name}"  # ./spectec-core
            
            cmd = [
                spectec_bin_rel,
                self.run_mode
            ] + spec_args + [
                "--pre", str(pre_json_rel),
                "--block", str(block_json_rel),
                "-o", str(output_json_rel)
            ]
            
            if verbose:
                print(f"    Command: {' '.join(cmd)}")
                print(f"    Working directory: {spectec_core_dir}")
            
            result = subprocess.run(
                cmd,
                cwd=str(spectec_core_dir),  # 작업 디렉터리를 spectec-core로 설정
                capture_output=True,
                text=True,
                check=True,
                timeout=7200  # Spectec 실행에 timeout 설정
            )
            
            # stderr에 에러가 있는지 확인 (Spectec는 에러를 stderr에 출력)
            has_errors = False
            if result.stderr:
                # "Error:" 문자열이 있으면 컴파일 에러로 간주
                if "Error:" in result.stderr or "error:" in result.stderr:
                    has_errors = True
                    if verbose:
                        print(f"    ⚠ Spectec compilation errors detected:")
                        # 에러 개수만 표시
                        error_count = result.stderr.count("Error:")
                        print(f"    ⚠ Found {error_count} error(s) in stderr")
                        # 모든 줄 표시
                        error_lines = result.stderr.split('\n')
                        for line in error_lines:
                            if "Error:" in line:
                                print(f"    ⚠   {line}")
            
            if verbose:
                if result.stdout:
                    print(f"    stdout: {result.stdout}")
            
            # 출력 파일이 실제로 생성되었는지 확인
            if not output_json.exists():
                error_msg = f"Spectec execution succeeded but output file was not created: {output_json}\n"
                if has_errors:
                    error_msg += f"Spectec had compilation errors (see stderr above)\n"
                error_msg += f"stdout: {result.stdout[:500]}\n"
                error_msg += f"stderr: {result.stderr[:500]}"
                return False, error_msg
            
            # 에러가 있어도 파일이 생성되었으면 경고만 표시
            if has_errors and verbose:
                print(f"    ⚠ Warning: Spectec had compilation errors but output file was created")
            
            return True, None
        except subprocess.TimeoutExpired as e:
            error_msg = f"Spectec execution timed out after 7200 seconds"
            if e.stdout:
                error_msg += f"\nstdout: {e.stdout[:500]}"
            if e.stderr:
                error_msg += f"\nstderr: {e.stderr[:500]}"
            return False, error_msg
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else e.stdout
            return False, error_msg
    
    def run_eth2spec(self, pre_ssz: Path, block_ssz: Path, output_ssz: Path) -> Tuple[bool, Optional[str]]:
        """eth2specResult.py를 실행합니다."""
        try:
            # consensus-specs 경로를 PYTHONPATH에 추가
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

    def run_eth2spec_direct(self, pre_ssz: Path, block_ssz: Path, output_ssz: Path, validate_result: bool = False) -> dict:
        """eth2spec를 현재 프로세스에서 직접 실행해 SUCCESS/FAIL/CRASH를 구분합니다."""
        start_time = time.perf_counter()

        if str(self.consensus_specs_path) not in sys.path:
            sys.path.insert(0, str(self.consensus_specs_path))

        try:
            from eth2spec.utils.ssz.ssz_impl import deserialize

            if self.fork == "deneb":
                from eth2spec.deneb import mainnet as spec
            elif self.fork == "capella":
                from eth2spec.capella import mainnet as spec
            else:
                raise ValueError(f"Unsupported fork: {self.fork}")

            with open(pre_ssz, 'rb') as f:
                state_data = f.read()
            state = deserialize(spec.BeaconState, state_data)

            with open(block_ssz, 'rb') as f:
                block_data = f.read()
            signed_block = deserialize(spec.SignedBeaconBlock, block_data)
        except Exception as e:
            return {
                "status": "CRASH",
                "time": time.perf_counter() - start_time,
                "error": str(e),
                "details": traceback.format_exc(),
                "output_path": str(output_ssz),
            }

        try:
            spec.state_transition(state, signed_block, validate_result=validate_result)
        except Exception as e:
            try:
                if output_ssz.exists():
                    output_ssz.unlink()
            except OSError:
                pass
            return {
                "status": "FAIL",
                "time": time.perf_counter() - start_time,
                "error": str(e),
                "details": traceback.format_exc(),
                "output_path": str(output_ssz),
            }

        try:
            output_ssz.parent.mkdir(parents=True, exist_ok=True)
            with open(output_ssz, 'wb') as f:
                f.write(state.encode_bytes())
        except Exception as e:
            return {
                "status": "CRASH",
                "time": time.perf_counter() - start_time,
                "error": str(e),
                "details": traceback.format_exc(),
                "output_path": str(output_ssz),
            }

        return {
            "status": "SUCCESS",
            "time": time.perf_counter() - start_time,
            "error": None,
            "details": "",
            "output_path": str(output_ssz),
        }

    def write_eth2spec_only_report(self, test_name: str, work_dir: Path, results: List[dict]) -> Path:
        report_path = work_dir / "eth2spec_report.md"
        lines = [f"# eth2spec-only Report: {test_name}", ""]

        for result in results:
            lines.append(f"## Pair {result['pair_index']}")
            lines.append("")
            lines.append(f"- Status: {result['status']}")
            lines.append(f"- Time: {result['time']:.6f}s")
            lines.append(f"- State: {result['state_path']}")
            lines.append(f"- Block: {result['block_path']}")
            lines.append(f"- Output: {result['output_path']}")
            if result.get('error'):
                lines.append(f"- Error: {result['error']}")
            lines.append("")
            if result.get('details'):
                lines.append("### Details")
                lines.append("")
                lines.append("```")
                lines.append(result['details'].strip())
                lines.append("```")
                lines.append("")

        report_path.write_text("\n".join(lines), encoding='utf-8')
        return report_path

    def write_eth2spec_only_summary(self, summary_path: Path, all_results: List[dict]) -> None:
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        with open(summary_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    'test', 'pair_index', 'status', 'state_path', 'block_path',
                    'output_path', 'time', 'error'
                ]
            )
            writer.writeheader()
            for result in all_results:
                writer.writerow({
                    'test': result['test'],
                    'pair_index': result['pair_index'],
                    'status': result['status'],
                    'state_path': result['state_path'],
                    'block_path': result['block_path'],
                    'output_path': result['output_path'],
                    'time': f"{result['time']:.6f}",
                    'error': result.get('error') or '',
                })

    def make_safe_output_dir_name(self, test_name: str, max_len: int = 120) -> str:
        """Keep original test_name for reports, but shorten on-disk directory names when needed."""
        safe_name = test_name.replace(os.sep, "_").replace("/", "_")
        if len(safe_name) <= max_len:
            return safe_name

        digest = hashlib.sha1(safe_name.encode('utf-8')).hexdigest()[:16]
        prefix_len = max(24, max_len - len(digest) - 1)
        return f"{safe_name[:prefix_len]}_{digest}"

    def process_test_case_eth2spec_only(self, test_case_dir: Path, work_dir: Path, test_name: str = None, verbose: bool = False) -> Tuple[bool, str, List[dict]]:
        """Spectec 없이 eth2spec state_transition만 실행하고 상태를 기록합니다."""
        if test_name is None:
            test_name = test_case_dir.name
        work_dir.mkdir(parents=True, exist_ok=True)

        pairs = self.iter_eth2spec_state_block_pairs(test_case_dir, work_dir)
        if not pairs:
            return False, f"No valid state/block pairs found in {test_case_dir}", []

        results = []
        sequential_stopped_at = None

        if self.workflow == "sequential":
            current_state = pairs[0][0]
            for idx, (_, block_ssz, pair_index) in enumerate(pairs):
                output_ssz = work_dir / f"eth2specResult_{pair_index}.ssz"
                if verbose:
                    print(f"\n[eth2spec-only:sequential] Running pair {pair_index}")
                    print(f"  pre: {current_state}")
                    print(f"  block: {block_ssz}")
                    print(f"  output: {output_ssz}")

                result = self.run_eth2spec_direct(current_state, block_ssz, output_ssz, validate_result=True)
                result.update({
                    "test": test_name,
                    "pair_index": pair_index,
                    "state_path": str(current_state),
                    "block_path": str(block_ssz),
                })
                results.append(result)

                print(f"  -> Pair {pair_index}: {result['status']}")
                if result.get('error'):
                    print(f"     Error: {result['error']}")

                if result['status'] == 'SUCCESS' and output_ssz.exists():
                    current_state = output_ssz
                    continue

                sequential_stopped_at = pair_index
                if verbose and idx + 1 < len(pairs):
                    print(f"  ! Stopping sequential execution at pair {pair_index}")
                break
        else:
            for pre_ssz, block_ssz, pair_index in pairs:
                output_ssz = work_dir / f"eth2specResult_{pair_index}.ssz"
                if verbose:
                    print(f"\n[eth2spec-only] Running pair {pair_index}")
                    print(f"  pre: {pre_ssz}")
                    print(f"  block: {block_ssz}")
                    print(f"  output: {output_ssz}")

                result = self.run_eth2spec_direct(pre_ssz, block_ssz, output_ssz, validate_result=True)
                result.update({
                    "test": test_name,
                    "pair_index": pair_index,
                    "state_path": str(pre_ssz),
                    "block_path": str(block_ssz),
                })
                results.append(result)

                print(f"  -> Pair {pair_index}: {result['status']}")
                if result.get('error'):
                    print(f"     Error: {result['error']}")

        report_path = self.write_eth2spec_only_report(test_name, work_dir, results)

        success_count = sum(1 for result in results if result['status'] == 'SUCCESS')
        fail_count = sum(1 for result in results if result['status'] == 'FAIL')
        crash_count = sum(1 for result in results if result['status'] == 'CRASH')
        message = (
            f"SUCCESS={success_count}, FAIL={fail_count}, CRASH={crash_count}, "
            f"report={report_path}"
        )
        if sequential_stopped_at is not None:
            message += f", stopped_at_pair={sequential_stopped_at}"
        return crash_count == 0, message, results

    def run_eth2spec_only_tests(self, test_suite_dir: str, output_dir: str = None, verbose: bool = False, test_filter: str = None) -> dict:
        """diff_testing.py 스타일로 테스트 스위트를 순회하며 eth2spec만 실행합니다."""
        test_suite_path = Path(test_suite_dir).resolve()

        if output_dir:
            output_path = Path(output_dir).resolve()
        else:
            output_path = test_suite_path / "_eth2spec_results"

        output_path.mkdir(parents=True, exist_ok=True)
        test_case_dirs = self.find_state_transition_test_cases(test_suite_dir)

        if test_filter:
            test_case_dirs = [tc for tc in test_case_dirs if test_filter in str(tc)]

        if not test_case_dirs:
            print(f"No state-transition test cases found in {test_suite_dir}")
            return {"total": 0, "passed": 0, "failed": 0, "results": []}

        print(f"Found {len(test_case_dirs)} state-transition test case directory(ies)")

        case_results = []
        all_pair_results = []
        passed = 0
        failed = 0

        for test_case_dir in test_case_dirs:
            try:
                relative_path = test_case_dir.relative_to(test_suite_path)
                test_name = str(relative_path).replace(os.sep, "_").replace("/", "_")
            except ValueError:
                test_name = test_case_dir.name

            work_dir = output_path / self.make_safe_output_dir_name(test_name)

            print(f"\n{'='*60}")
            print(f"Test: {test_name}")
            print(f"Path: {test_case_dir}")
            print(f"Output: {work_dir}")
            print(f"{'='*60}")

            success, message, pair_results = self.process_test_case_eth2spec_only(test_case_dir, work_dir, test_name=test_name, verbose=verbose)
            all_pair_results.extend(pair_results)

            if success:
                print(f"✓ PROCESSED: {message}")
                passed += 1
            else:
                print(f"✗ PROCESSED WITH CRASH: {message}")
                failed += 1

            case_results.append({
                'test': test_name,
                'success': success,
                'message': message,
                'work_dir': str(work_dir),
            })

        summary_path = output_path / 'eth2spec_summary.csv'
        self.write_eth2spec_only_summary(summary_path, all_pair_results)

        success_count = sum(1 for result in all_pair_results if result['status'] == 'SUCCESS')
        fail_count = sum(1 for result in all_pair_results if result['status'] == 'FAIL')
        crash_count = sum(1 for result in all_pair_results if result['status'] == 'CRASH')

        print(f"\n{'='*60}")
        print("ETH2SPEC-ONLY SUMMARY")
        print(f"{'='*60}")
        print(f"Test case directories: {len(test_case_dirs)}")
        print(f"Processed without crash: {passed}")
        print(f"Processed with crash: {failed}")
        print(f"Total pairs: {len(all_pair_results)}")
        print(f"SUCCESS: {success_count}")
        print(f"FAIL: {fail_count}")
        print(f"CRASH: {crash_count}")
        print(f"Results directory: {output_path}")
        print(f"CSV summary: {summary_path}")

        return {
            'total': len(all_pair_results),
            'directories': len(test_case_dirs),
            'passed': passed,
            'failed': failed,
            'success_count': success_count,
            'fail_count': fail_count,
            'crash_count': crash_count,
            'results': case_results,
        }
    
    def compare_results(self, file1: Path, file2: Path) -> bool:
        """두 SSZ 파일을 비교합니다."""
        try:
            result = subprocess.run(
                [sys.executable, str(self.compare_result), str(file1), str(file2)],
                capture_output=True,
                text=True,
                check=True
            )
            return True
        except subprocess.CalledProcessError:
            return False
    
    def process_test_case(self, test_case_dir: Path, work_dir: Path, verbose: bool = False) -> Tuple[bool, str]:
        """
        단일 테스트 케이스를 처리합니다.
        
        Returns:
            (success, message) 튜플
        """
        test_name = test_case_dir.name
        
        if verbose:
            print(f"\n{'='*60}")
            print(f"Processing test case: {test_name}")
            print(f"Directory: {test_case_dir}")
            print(f"{'='*60}")
        
        # 1. pre.ssz_snappy와 blocks_*.ssz_snappy 찾기
        pre_snappy = test_case_dir / "pre.ssz_snappy"
        if not pre_snappy.exists():
            return False, f"pre.ssz_snappy not found in {test_case_dir}"
        
        block_snappy_files = sorted(test_case_dir.glob("blocks_*.ssz_snappy"))
        if not block_snappy_files:
            return False, f"No blocks_*.ssz_snappy files found in {test_case_dir}"
        
        # 작업 디렉터리에 파일들 준비
        work_dir.mkdir(parents=True, exist_ok=True)
        
        # 2. Snappy 압축 해제
        if verbose:
            print("\n[Step 1] Decompressing snappy files...")
        pre_ssz = work_dir / "pre.ssz"
        if not self.decompress_snappy(pre_snappy, pre_ssz):
            return False, "Failed to decompress pre.ssz_snappy"
        
        block_ssz_files = []
        for block_snappy in block_snappy_files:
            block_num = block_snappy.stem.replace("blocks_", "").replace(".ssz_snappy", "")
            block_ssz = work_dir / f"blocks_{block_num}.ssz"
            if not self.decompress_snappy(block_snappy, block_ssz):
                return False, f"Failed to decompress {block_snappy.name}"
            block_ssz_files.append(block_ssz)
        
        if verbose:
            print("  ✓ All snappy files decompressed")
        
        # 3. SSZ를 JSON으로 변환
        if verbose:
            print("\n[Step 2] Converting SSZ to JSON...")
        pre_json = work_dir / "pre.json"
        if not self.ssz_to_json(pre_ssz, pre_json, is_beacon_state=True):
            return False, "Failed to convert pre.ssz to JSON"
        
        block_json_files = []
        for block_ssz in block_ssz_files:
            block_num = block_ssz.stem.replace("blocks_", "").replace(".ssz", "")
            block_json = work_dir / f"blocks_{block_num}.json"
            if not self.ssz_to_json(block_ssz, block_json, is_beacon_state=False):
                return False, f"Failed to convert {block_ssz.name} to JSON"
            block_json_files.append(block_json)
        
        if verbose:
            print("  ✓ All SSZ files converted to JSON")
        
        # 3. Spectec 실행 (각 block을 원본 pre 상태에서 독립적으로 처리)
        # Note: Spectec이 실패(timeout 포함)해도 5번(eth2spec), 6번(비교)은 계속 진행됨
        spectec_results = []  # 각 block의 결과를 저장
        spectec_errors = {}  # 각 block의 에러를 저장
        
        for block_json in block_json_files:
            block_num = block_json.stem.replace("blocks_", "").replace(".json", "")
            if verbose:
                print(f"\n[Step 3] Running Spectec with {block_json.name} (independent from pre)...")
            
            # 각 block은 원본 pre.json에서 시작 (독립적 처리)
            spectec_output_json = work_dir / f"spectec_output_{block_num}.json"
            success, error = self.run_spectec(pre_json, block_json, spectec_output_json, verbose=verbose)
            
            if not success:
                # Spectec 실패 시 에러 기록하고 다음 block으로 (4번 SSZ 변환은 자동 스킵)
                spectec_errors[block_num] = error
                if verbose:
                    print(f"  ✗ Spectec failed: {error}")
                    print(f"  → Step 4 (SSZ conversion) will be skipped for this block")
                continue
            
            if verbose:
                print("  ✓ Spectec execution succeeded")
            
            # 4. Spectec 결과를 SSZ로 변환 (Spectec이 성공한 경우에만 실행)
            if verbose:
                print(f"\n[Step 4] Converting Spectec output {block_num} to SSZ...")
            spectec_output_ssz = work_dir / f"spectec_output_{block_num}.ssz"
            if not self.json_to_ssz(spectec_output_json, spectec_output_ssz):
                # SSZ 변환 실패도 에러로 기록하되, 5번, 6번은 계속 진행
                spectec_errors[block_num] = f"Failed to convert Spectec output {block_num} to SSZ"
                if verbose:
                    print(f"  ✗ SSZ conversion failed")
                    print(f"  → Step 5 (eth2spec) and Step 6 (comparison) will continue")
                continue
            
            if verbose:
                print("  ✓ Spectec output converted to SSZ")
            
            spectec_results.append({
                "block_num": block_num,
                "ssz_path": spectec_output_ssz
            })
        
        # 5. eth2specResult.py 실행 (각 block을 원본 pre 상태에서 독립적으로 처리)
        # Note: Spectec이 실패해도 항상 실행됨 (비교를 위해 필요)
        eth2spec_results = []  # 각 block의 결과를 저장
        eth2spec_errors = {}  # 각 block의 에러를 저장
        
        for block_ssz in block_ssz_files:
            block_num = block_ssz.stem.replace("blocks_", "").replace(".ssz", "")
            if verbose:
                print(f"\n[Step 5] Running eth2specResult.py with {block_ssz.name} (independent from pre)...")
            
            # 각 block은 원본 pre.ssz에서 시작 (독립적 처리)
            eth2spec_output_ssz = work_dir / f"eth2specResult_{block_num}.ssz"
            success, error = self.run_eth2spec(pre_ssz, block_ssz, eth2spec_output_ssz)
            
            if not success:
                eth2spec_errors[block_num] = error
                if verbose:
                    print(f"  ✗ eth2specResult.py failed: {error}")
                continue
            
            if verbose:
                print("  ✓ eth2specResult.py execution succeeded")
            
            eth2spec_results.append({
                "block_num": block_num,
                "ssz_path": eth2spec_output_ssz
            })
        
        # 6. 에러 체크 및 결과 비교
        # Note: Spectec이 실패해도 항상 실행됨 (에러 일관성 확인 및 결과 비교)
        # 각 block에 대해 독립적으로 비교
        all_match = True
        mismatch_blocks = []
        error_mismatch_blocks = []
        
        # 모든 block 번호 수집
        all_block_nums = set()
        for res in spectec_results:
            all_block_nums.add(res["block_num"])
        for res in eth2spec_results:
            all_block_nums.add(res["block_num"])
        for block_num in spectec_errors.keys():
            all_block_nums.add(block_num)
        for block_num in eth2spec_errors.keys():
            all_block_nums.add(block_num)
        
        if verbose:
            print("\n[Step 6] Comparing results for each block...")
        
        for block_num in sorted(all_block_nums):
            spectec_res = next((r for r in spectec_results if r["block_num"] == block_num), None)
            eth2spec_res = next((r for r in eth2spec_results if r["block_num"] == block_num), None)
            spectec_error = spectec_errors.get(block_num)
            eth2spec_error = eth2spec_errors.get(block_num)
            
            if verbose:
                print(f"\n  Block {block_num}:")
            
            # 둘 다 실패한 경우
            if spectec_error and eth2spec_error:
                if verbose:
                    print(f"    Both Spectec and eth2spec failed (expected if consistent)")
                    print(f"    Spectec error: {spectec_error}")
                    print(f"    eth2spec error: {eth2spec_error}")
                # 에러 일관성은 간단하게 처리 (향후 개선 가능)
                continue
            
            # 하나만 실패한 경우 (불일치)
            elif spectec_error:
                all_match = False
                error_mismatch_blocks.append(block_num)
                if verbose:
                    print(f"    ✗ Spectec failed but eth2spec succeeded (inconsistent)")
                    print(f"    Spectec error: {spectec_error}")
            
            elif eth2spec_error:
                all_match = False
                error_mismatch_blocks.append(block_num)
                if verbose:
                    print(f"    ✗ eth2spec failed but Spectec succeeded (inconsistent)")
                    print(f"    eth2spec error: {eth2spec_error}")
            
            # 둘 다 성공한 경우 - 결과 비교 (postState 비교)
            elif spectec_res and eth2spec_res:
                if verbose:
                    print(f"    Comparing postState (BeaconState) results...")
                    print(f"      Spectec postState: {spectec_res['ssz_path']}")
                    print(f"      eth2spec postState: {eth2spec_res['ssz_path']}")
                
                if self.compare_results(spectec_res["ssz_path"], eth2spec_res["ssz_path"]):
                    if verbose:
                        print(f"    ✓ PostState results match!")
                else:
                    all_match = False
                    mismatch_blocks.append(block_num)
                    if verbose:
                        print(f"    ✗ PostState results do not match")
            
            # 하나만 성공한 경우 (이상한 경우)
            else:
                all_match = False
                error_mismatch_blocks.append(block_num)
                if verbose:
                    print(f"    ✗ Inconsistent state: one succeeded but the other has no result")
        
        # 최종 결과 반환
        if all_match:
            if verbose:
                print(f"\n  ✓ All {len(all_block_nums)} postState(s) match or consistently failed!")
            return True, f"All {len(all_block_nums)} postState(s) match or consistently failed"
        else:
            error_msg_parts = []
            if mismatch_blocks:
                error_msg_parts.append(f"PostState mismatch in block(s): {', '.join(mismatch_blocks)}")
            if error_mismatch_blocks:
                error_msg_parts.append(f"Error inconsistency in block(s): {', '.join(error_mismatch_blocks)}")
            return False, "; ".join(error_msg_parts)

    def process_test_case_sequential(self, test_case_dir: Path, work_dir: Path, verbose: bool = False) -> Tuple[bool, str]:
        """
        단일 테스트 케이스를 순차(sequential) 모드로 처리합니다.

        워크플로우(v2 연쇄 버전):
        1. snappy 파일 압축 해제
        2. SSZ를 JSON으로 변환
        3. Spectec를 pre -> blocks_0 -> postState_0 -> blocks_1 ... 순으로 연쇄 실행
        4. 각 Spectec postState를 SSZ로 변환
        5. eth2specResult.py를 동일한 방식으로 연쇄 실행
        6. 각 단계의 postState를 비교

        Returns:
            (success, message) 튜플
        """
        test_name = test_case_dir.name

        if verbose:
            print(f"\n{'='*60}")
            print(f"[sequential] Processing test case: {test_name}")
            print(f"Directory: {test_case_dir}")
            print(f"{'='*60}")

        # 1. pre.ssz_snappy와 blocks_*.ssz_snappy 찾기
        pre_snappy = test_case_dir / "pre.ssz_snappy"
        if not pre_snappy.exists():
            return False, f"pre.ssz_snappy not found in {test_case_dir}"

        # blocks_* 파일은 숫자 순서로 정렬 (lexicographic vs numeric 문제 방지)
        block_snappy_files = sorted(
            test_case_dir.glob("blocks_*.ssz_snappy"),
            key=lambda p: int(p.stem.replace("blocks_", ""))
        )
        if not block_snappy_files:
            return False, f"No blocks_*.ssz_snappy files found in {test_case_dir}"

        # 작업 디렉터리에 파일들 준비
        work_dir.mkdir(parents=True, exist_ok=True)

        # 2. Snappy 압축 해제
        if verbose:
            print("\n[Step 1] Decompressing snappy files...")
        pre_ssz = work_dir / "pre.ssz"
        if not self.decompress_snappy(pre_snappy, pre_ssz):
            return False, "Failed to decompress pre.ssz_snappy"

        block_ssz_files = []
        for block_snappy in block_snappy_files:
            block_num = block_snappy.stem.replace("blocks_", "").replace(".ssz_snappy", "")
            block_ssz = work_dir / f"blocks_{block_num}.ssz"
            if not self.decompress_snappy(block_snappy, block_ssz):
                return False, f"Failed to decompress {block_snappy.name}"
            block_ssz_files.append(block_ssz)

        if verbose:
            print("  ✓ All snappy files decompressed")

        # 3. SSZ를 JSON으로 변환
        if verbose:
            print("\n[Step 2] Converting SSZ to JSON...")
        pre_json = work_dir / "pre.json"
        if not self.ssz_to_json(pre_ssz, pre_json, is_beacon_state=True):
            return False, "Failed to convert pre.ssz to JSON"

        block_json_files = []
        for block_ssz in block_ssz_files:
            block_num = block_ssz.stem.replace("blocks_", "").replace(".ssz", "")
            block_json = work_dir / f"blocks_{block_num}.json"
            if not self.ssz_to_json(block_ssz, block_json, is_beacon_state=False):
                return False, f"Failed to convert {block_ssz.name} to JSON"
            block_json_files.append(block_json)

        if verbose:
            print("  ✓ All SSZ files converted to JSON")

        # 3. Spectec 실행 (이전 블록의 postState를 다음 블록의 pre로 연쇄 적용)
        spectec_results = []
        spectec_errors = {}
        spectec_current_pre = pre_json

        for idx, block_json in enumerate(block_json_files):
            block_num = block_json.stem.replace("blocks_", "").replace(".json", "")
            if verbose:
                if idx == 0:
                    print(f"\n[Step 3] Running Spectec with {block_json.name} (starting from initial pre)")
                else:
                    prev_block = block_json_files[idx - 1].stem.replace("blocks_", "").replace(".json", "")
                    print(f"\n[Step 3] Running Spectec with {block_json.name} (using postState from block {prev_block})")

            spectec_output_json = work_dir / f"spectec_output_{block_num}.json"
            success, error = self.run_spectec(spectec_current_pre, block_json, spectec_output_json, verbose=verbose)

            if not success:
                spectec_errors[block_num] = error
                # verbose가 아니어도 에러 메시지는 항상 출력
                print(f"  ✗ Spectec failed at block {block_num}: {error}")
                if verbose:
                    print(f"  → Sequential execution stopped at block {block_num}")
                else:
                    print(f"  → Sequential execution stopped at block {block_num}")
                    print(f"  → Use -v/--verbose flag for more details")
                break

            if verbose:
                print("  ✓ Spectec execution succeeded")

            spectec_current_pre = spectec_output_json  # 다음 블록의 pre로 사용

            if verbose:
                print(f"\n[Step 4] Converting Spectec output {block_num} to SSZ...")
            spectec_output_ssz = work_dir / f"spectec_output_{block_num}.ssz"
            if not self.json_to_ssz(spectec_output_json, spectec_output_ssz):
                spectec_errors[block_num] = f"Failed to convert Spectec output {block_num} to SSZ"
                if verbose:
                    print(f"  ✗ SSZ conversion failed (continuing for chained execution)")
                continue

            if verbose:
                print("  ✓ Spectec output converted to SSZ")

            spectec_results.append({
                "block_num": block_num,
                "ssz_path": spectec_output_ssz
            })

        # 5. eth2specResult.py 실행 (연쇄 적용)
        eth2spec_results = []
        eth2spec_errors = {}
        eth2spec_current_pre = pre_ssz

        for idx, block_ssz in enumerate(block_ssz_files):
            block_num = block_ssz.stem.replace("blocks_", "").replace(".ssz", "")
            if verbose:
                if idx == 0:
                    print(f"\n[Step 5] Running eth2specResult.py with {block_ssz.name} (starting from initial pre)")
                else:
                    prev_block = block_ssz_files[idx - 1].stem.replace("blocks_", "").replace(".ssz", "")
                    print(f"\n[Step 5] Running eth2specResult.py with {block_ssz.name} (using postState from block {prev_block})")

            eth2spec_output_ssz = work_dir / f"eth2specResult_{block_num}.ssz"
            success, error = self.run_eth2spec(eth2spec_current_pre, block_ssz, eth2spec_output_ssz)

            if not success:
                eth2spec_errors[block_num] = error
                if verbose:
                    print(f"  ✗ eth2specResult.py failed: {error}")
                    print(f"  → Sequential execution stopped at block {block_num}")
                break

            if verbose:
                print("  ✓ eth2specResult.py execution succeeded")

            eth2spec_current_pre = eth2spec_output_ssz  # 다음 블록의 pre로 사용

            eth2spec_results.append({
                "block_num": block_num,
                "ssz_path": eth2spec_output_ssz
            })

        # 6. 에러 체크 및 결과 비교
        # Note: Spectec이 실패해도 항상 실행됨 (에러 일관성 확인 및 결과 비교)
        # 각 block에 대해 독립적으로 비교
        all_match = True
        mismatch_blocks = []
        error_mismatch_blocks = []

        # 모든 block 번호 수집
        all_block_nums = set()
        for res in spectec_results:
            all_block_nums.add(res["block_num"])
        for res in eth2spec_results:
            all_block_nums.add(res["block_num"])
        for block_num in spectec_errors.keys():
            all_block_nums.add(block_num)
        for block_num in eth2spec_errors.keys():
            all_block_nums.add(block_num)

        if verbose:
            print("\n[Step 6] Comparing results for each block...")

        for block_num in sorted(all_block_nums):
            spectec_res = next((r for r in spectec_results if r["block_num"] == block_num), None)
            eth2spec_res = next((r for r in eth2spec_results if r["block_num"] == block_num), None)
            spectec_error = spectec_errors.get(block_num)
            eth2spec_error = eth2spec_errors.get(block_num)

            if verbose:
                print(f"\n  Block {block_num}:")

            # 둘 다 실패한 경우
            if spectec_error and eth2spec_error:
                if verbose:
                    print(f"    Both Spectec and eth2spec failed (expected if consistent)")
                    print(f"    Spectec error: {spectec_error}")
                    print(f"    eth2spec error: {eth2spec_error}")
                # 에러 일관성은 간단하게 처리 (향후 개선 가능)
                continue

            # 하나만 실패한 경우 (불일치)
            elif spectec_error:
                all_match = False
                error_mismatch_blocks.append(block_num)
                if verbose:
                    print(f"    ✗ Spectec failed but eth2spec succeeded (inconsistent)")
                    print(f"    Spectec error: {spectec_error}")

            elif eth2spec_error:
                all_match = False
                error_mismatch_blocks.append(block_num)
                if verbose:
                    print(f"    ✗ eth2spec failed but Spectec succeeded (inconsistent)")
                    print(f"    eth2spec error: {eth2spec_error}")

            # 둘 다 성공한 경우 - 결과 비교 (postState 비교)
            elif spectec_res and eth2spec_res:
                if verbose:
                    print(f"    Comparing postState (BeaconState) results...")
                    print(f"      Spectec postState: {spectec_res['ssz_path']}")
                    print(f"      eth2spec postState: {eth2spec_res['ssz_path']}")

                if self.compare_results(spectec_res["ssz_path"], eth2spec_res["ssz_path"]):
                    if verbose:
                        print(f"    ✓ PostState results match!")
                else:
                    all_match = False
                    mismatch_blocks.append(block_num)
                    if verbose:
                        print(f"    ✗ PostState results do not match")

            # 하나만 성공한 경우 (이상한 경우)
            else:
                all_match = False
                error_mismatch_blocks.append(block_num)
                if verbose:
                    print(f"    ✗ Inconsistent state: one succeeded but the other has no result")

        # 최종 결과 반환
        if all_match:
            if verbose:
                print(f"\n  ✓ All {len(all_block_nums)} postState(s) match or consistently failed!")
            return True, f"All {len(all_block_nums)} postState(s) match or consistently failed"
        else:
            error_msg_parts = []
            if mismatch_blocks:
                error_msg_parts.append(f"PostState mismatch in block(s): {', '.join(mismatch_blocks)}")
            if error_mismatch_blocks:
                error_msg_parts.append(f"Error inconsistency in block(s): {', '.join(error_mismatch_blocks)}")
            return False, "; ".join(error_msg_parts)
    
    def run_tests(self, test_suite_dir: str, output_dir: str = None, verbose: bool = False, 
                  test_filter: str = None) -> dict:
        """
        테스트 스위트를 실행합니다.
        
        Args:
            test_suite_dir: 테스트 스위트 디렉터리 (random 또는 sanity)
            output_dir: 결과를 저장할 디렉터리 (기본값: test_suite_dir/_results)
            verbose: 상세 출력 여부
            test_filter: 테스트 케이스 이름 필터 (예: "randomized_0")
        
        Returns:
            결과 딕셔너리
        """
        test_suite_path = Path(test_suite_dir).resolve()
        
        if output_dir:
            output_path = Path(output_dir).resolve()
        else:
            output_path = test_suite_path / "_results"
        
        output_path.mkdir(parents=True, exist_ok=True)
        
        # 테스트 케이스 찾기
        test_case_dirs = self.find_test_cases(test_suite_dir)
        
        if test_filter:
            test_case_dirs = [tc for tc in test_case_dirs if test_filter in tc.name]
        
        if not test_case_dirs:
            print(f"No test cases found in {test_suite_dir}")
            return {"total": 0, "passed": 0, "failed": 0, "results": []}
        
        # 실제 테스트 케이스 개수 계산 (각 폴더의 blocks_* 개수 합계)
        total_test_cases = 0
        for test_case_dir in test_case_dirs:
            block_files = list(test_case_dir.glob("blocks_*.ssz_snappy"))
            total_test_cases += len(block_files)
        
        print(f"Found {len(test_case_dirs)} test case directory(ies) with {total_test_cases} total test case(s) (pre + blocks combinations)")
        
        results = []
        passed = 0
        failed = 0
        
        for test_case_dir in test_case_dirs:
            # 테스트 케이스의 상대 경로를 사용하여 고유한 이름 생성
            # 예: random/random/pyspec_tests/randomized_0 -> random_pyspec_tests_randomized_0
            try:
                relative_path = test_case_dir.relative_to(test_suite_path)
                # 경로를 언더스코어로 연결하여 고유한 이름 생성
                test_name = str(relative_path).replace(os.sep, "_").replace("/", "_")
            except ValueError:
                # 상대 경로를 계산할 수 없는 경우 (절대 경로 등) 이름만 사용
                test_name = test_case_dir.name
            
            work_dir = output_path / test_name
            
            print(f"\n{'='*60}")
            print(f"Test: {test_name}")
            print(f"Path: {test_case_dir}")
            print(f"Output: {work_dir}")
            print(f"{'='*60}")

            if self.workflow == "sequential":
                success, message = self.process_test_case_sequential(test_case_dir, work_dir, verbose=verbose)
            else:
                success, message = self.process_test_case(test_case_dir, work_dir, verbose=verbose)
            
            if success:
                print(f"✓ PASSED: {message}")
                passed += 1
            else:
                print(f"✗ FAILED: {message}")
                failed += 1
            
            results.append({
                "test": test_name,
                "success": success,
                "message": message,
                "work_dir": str(work_dir)
            })
        
        # 요약 출력
        print(f"\n{'='*60}")
        print("SUMMARY")
        print(f"{'='*60}")
        print(f"Total test cases: {total_test_cases}")
        print(f"Test case directories: {len(test_case_dirs)}")
        print(f"Passed: {passed}")
        print(f"Failed: {failed}")
        print(f"Results directory: {output_path}")
        
        return {
            "total": total_test_cases,
            "directories": len(test_case_dirs),
            "passed": passed,
            "failed": failed,
            "results": results
        }


def main():
    parser = argparse.ArgumentParser(
        description="Run OfficialTestSuite test cases through the complete workflow"
    )
    parser.add_argument(
        "test_suite",
        nargs='?',
        help="Test suite directory (e.g., Converter/OfficialTestSuite/random or sanity)"
    )
    parser.add_argument(
        "--test-suite",
        dest="test_suite_option",
        default=None,
        help="Optional alias for the test suite directory."
    )
    parser.add_argument(
        "--test-type",
        default="state-transition",
        choices=["state-transition"],
        help="Only state-transition is supported for the eth2spec-only mode."
    )
    parser.add_argument(
        "--spectec-bin",
        required=False,
        help="Path to Spectec binary (e.g., ./spectec-core). Required unless --eth2spec-only is used."
    )
    parser.add_argument(
        "--converter-dir",
        default=None,
        help="Path to Converter directory (default: auto-detect from script location)"
    )
    parser.add_argument(
        "--spec-dir",
        default=None,
        help="Path to spec directory containing .spectec files (default: spectec-core/spec/spec_{fork})"
    )
    parser.add_argument(
        "--fork", "--fork-version",
        dest="fork",
        default="deneb",
        choices=["deneb", "capella"],
        help="Fork name to use (default: deneb). Spec files will be loaded from spec/spec_{fork}/"
    )
    parser.add_argument(
        "--output-dir", "--output-base",
        dest="output_dir",
        default=None,
        help="Output directory for results (default: test_suite/_results or test_suite/_eth2spec_results)"
    )
    parser.add_argument(
        "--filter",
        default=None,
        help="Filter test cases by name (e.g., 'randomized_0')"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Verbose output"
    )
    parser.add_argument(
        "--run-mode",
        default="run-il",
        choices=["run-il", "run-sl"],
        help="Execution mode: run-il or run-sl (default: run-il)"
    )
    parser.add_argument(
        "--workflow",
        default="independent",
        choices=["independent", "sequential"],
        help="Test workflow mode: independent (default) or sequential (v2-style chained execution)"
    )
    parser.add_argument(
        "--eth2spec-only",
        action="store_true",
        help="Run only eth2spec state_transition, record SUCCESS/FAIL/CRASH, and skip Spectec/comparison."
    )

    args = parser.parse_args()

    test_suite = args.test_suite_option or args.test_suite
    if not test_suite:
        print("Error: test_suite is required. Provide it positionally or with --test-suite.")
        sys.exit(1)

    # Converter 디렉터리 자동 감지
    if args.converter_dir:
        converter_dir = Path(args.converter_dir).resolve()
    else:
        script_dir = Path(__file__).parent.resolve()
        converter_dir = script_dir

    spectec_bin = None
    if not args.eth2spec_only:
        if not args.spectec_bin:
            print("Error: --spectec-bin is required unless --eth2spec-only is used")
            sys.exit(1)

        spectec_bin = Path(args.spectec_bin).resolve()
        if not spectec_bin.exists():
            print(f"Error: Spectec binary not found: {spectec_bin}")
            sys.exit(1)

        if spectec_bin.is_dir():
            potential_bin = spectec_bin / spectec_bin.name
            if potential_bin.exists() and potential_bin.is_file():
                spectec_bin = potential_bin
                print(f"Note: Found executable at {spectec_bin}")
            else:
                print(f"Error: Spectec binary path is a directory: {spectec_bin}")
                print(f"Please provide the path to the executable file, e.g., spectec-core/spectec-core")
                sys.exit(1)

        if not spectec_bin.is_file():
            print(f"Error: Spectec binary path is not a file: {spectec_bin}")
            sys.exit(1)

        if not os.access(spectec_bin, os.X_OK):
            print(f"Error: Spectec binary is not executable: {spectec_bin}")
            print(f"Please check file permissions or provide the correct executable path")
            sys.exit(1)

    runner = TestRunner(
        converter_dir=str(converter_dir),
        spectec_bin=str(spectec_bin) if spectec_bin else None,
        spec_dir=args.spec_dir,
        run_mode=args.run_mode,
        workflow=args.workflow,
        fork=args.fork,
    )

    start_time = time.perf_counter()
    if args.eth2spec_only:
        results = runner.run_eth2spec_only_tests(
            test_suite_dir=test_suite,
            output_dir=args.output_dir,
            verbose=args.verbose,
            test_filter=args.filter
        )
    else:
        results = runner.run_tests(
            test_suite_dir=test_suite,
            output_dir=args.output_dir,
            verbose=args.verbose,
            test_filter=args.filter
        )
    end_time = time.perf_counter()
    elapsed = end_time - start_time
    print(f"\nTotal elapsed time: {elapsed:.2f} seconds")

    sys.exit(1 if results["failed"] > 0 else 0)


if __name__ == "__main__":
    main()

