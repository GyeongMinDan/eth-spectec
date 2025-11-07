#!/usr/bin/env python3
"""
OfficialTestSuite 테스트 케이스에 대해 전체 워크플로우를 자동으로 실행하는 스크립트

워크플로우:
1. snappy 파일 압축 해제 (pre.ssz_snappy, blocks_*.ssz_snappy -> pre.ssz, blocks_*.ssz)
2. SSZ를 JSON으로 변환 (pre.ssz -> pre.json, blocks_*.ssz -> blocks_*.json)
3. Spectec 프로그램 실행
4. Spectec 결과를 SSZ로 변환 (spectec_output.json -> spectec_output.ssz)
5. eth2specResult.py 실행 (pre.ssz, blocks_*.ssz -> eth2specResult.ssz)
6. 결과 비교 (spectec_output.ssz vs eth2specResult.ssz)
"""

import os
import sys
import subprocess
import argparse
import glob
import tempfile
import shutil
from pathlib import Path
from typing import List, Tuple, Optional


class TestRunner:
    def __init__(self, converter_dir: str, spectec_bin: str, spec_dir: str = None):
        """
        Args:
            converter_dir: Converter 디렉터리 경로
            spectec_bin: Spectec 실행 파일 경로
            spec_dir: spec 파일들이 있는 디렉터리 (기본값: spectec-core/spec)
        """
        self.converter_dir = Path(converter_dir).resolve()
        self.spectec_bin = Path(spectec_bin).resolve()
        
        # 기본 경로 설정
        if spec_dir:
            self.spec_dir = Path(spec_dir).resolve()
        else:
            # spectec-core/spec 디렉터리 찾기
            spectec_core = self.converter_dir.parent
            self.spec_dir = spectec_core / "spec"
        
        # 스크립트 경로들
        self.snappy_decompressor = self.converter_dir / "snappyDecompressor.py"
        self.beacon_state_to_json = self.converter_dir / "SSZToJson" / "BeaconStateSSZToJson.py"
        self.signed_block_to_json = self.converter_dir / "SSZToJson" / "SignedBeaconBlockSSZToJson.py"
        self.json_to_ssz_script = self.converter_dir / "JsonToSSZ" / "BeaconStateJsonToSSZ.py"
        self.eth2spec_result = self.converter_dir / "ExampleSSZ" / "eth2specResult.py"
        self.compare_result = self.converter_dir / "CompareResult.py"
        
        # consensus-specs 경로 (eth2specResult.py에서 사용)
        consensus_specs = self.converter_dir.parent.parent / "consensus-specs"
        self.consensus_specs_path = consensus_specs / "tests" / "core" / "pyspec"
    
    def find_test_cases(self, test_suite_dir: str) -> List[Path]:
        """테스트 케이스 디렉터리들을 찾습니다."""
        test_suite_path = Path(test_suite_dir).resolve()
        test_cases = []
        
        # pre.ssz_snappy가 있는 디렉터리들을 찾습니다
        for pre_file in test_suite_path.rglob("pre.ssz_snappy"):
            test_cases.append(pre_file.parent)
        
        return sorted(test_cases)
    
    def decompress_snappy(self, input_file: Path, output_file: Path) -> bool:
        """snappy 파일을 압축 해제합니다."""
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
        """SSZ 파일을 JSON으로 변환합니다."""
        try:
            if is_beacon_state:
                script = self.beacon_state_to_json
            else:
                script = self.signed_block_to_json
            
            result = subprocess.run(
                [sys.executable, str(script), "--in", str(ssz_file), "--out", str(json_file)],
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
            result = subprocess.run(
                [sys.executable, str(self.json_to_ssz_script), "--in", str(json_file), "--out", str(ssz_file)],
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
            spec_files = sorted(self.spec_dir.glob("*.spectec"), key=lambda f: f.name)
            if not spec_files:
                return False, f"No .spectec files found in {self.spec_dir}"
            
            # spectec-core 디렉터리를 작업 디렉터리로 설정
            spectec_core_dir = self.spectec_bin.parent
            
            # 상대 경로로 변환 (spectec-core 디렉터리 기준)
            try:
                pre_json_rel = pre_json.relative_to(spectec_core_dir)
                block_json_rel = block_json.relative_to(spectec_core_dir)
                output_json_rel = output_json.relative_to(spectec_core_dir)
                spec_args = [f"spec/{f.name}" for f in spec_files]  # spec/*.spectec 형태, 파일명 순서대로
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
                "run-il"
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
                check=True
            )
            
            # stderr에 에러가 있는지 확인 (Spectec는 에러를 stderr에 출력)
            has_errors = False
            if result.stderr:
                # "Error:" 문자열이 있으면 컴파일 에러로 간주
                if "Error:" in result.stderr:
                    has_errors = True
                    if verbose:
                        print(f"    ⚠ Spectec compilation errors detected:")
                        # 에러 개수만 표시
                        error_count = result.stderr.count("Error:")
                        print(f"    ⚠ Found {error_count} error(s) in stderr")
                        # 처음 몇 줄만 표시
                        error_lines = result.stderr.split('\n')[:10]
                        for line in error_lines:
                            if "Error:" in line:
                                print(f"    ⚠   {line[:100]}")
                        if error_count > 10:
                            print(f"    ⚠   ... and {error_count - 10} more errors")
            
            if verbose:
                if result.stdout:
                    print(f"    stdout: {result.stdout[:200]}...")  # 처음 200자만
            
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
                 "--out", str(output_ssz)],
                capture_output=True,
                text=True,
                check=True,
                env=env
            )
            return True, None
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else e.stdout
            return False, error_msg
    
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
        
        # 4. Spectec 실행 (각 block을 원본 pre 상태에서 독립적으로 처리)
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
                spectec_errors[block_num] = error
                if verbose:
                    print(f"  ✗ Spectec failed: {error}")
                continue
            
            if verbose:
                print("  ✓ Spectec execution succeeded")
            
            # Spectec 결과를 SSZ로 변환
            if verbose:
                print(f"\n[Step 4] Converting Spectec output {block_num} to SSZ...")
            spectec_output_ssz = work_dir / f"spectec_output_{block_num}.ssz"
            if not self.json_to_ssz(spectec_output_json, spectec_output_ssz):
                return False, f"Failed to convert Spectec output {block_num} to SSZ"
            
            if verbose:
                print("  ✓ Spectec output converted to SSZ")
            
            spectec_results.append({
                "block_num": block_num,
                "ssz_path": spectec_output_ssz
            })
        
        # 5. eth2specResult.py 실행 (각 block을 원본 pre 상태에서 독립적으로 처리)
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
        help="Test suite directory (e.g., Converter/OfficialTestSuite/random or sanity)"
    )
    parser.add_argument(
        "--spectec-bin",
        required=True,
        help="Path to Spectec binary (e.g., ./spectec-core)"
    )
    parser.add_argument(
        "--converter-dir",
        default=None,
        help="Path to Converter directory (default: auto-detect from script location)"
    )
    parser.add_argument(
        "--spec-dir",
        default=None,
        help="Path to spec directory containing .spectec files (default: spectec-core/spec)"
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output directory for results (default: test_suite/_results)"
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
    
    args = parser.parse_args()
    
    # Converter 디렉터리 자동 감지
    if args.converter_dir:
        converter_dir = Path(args.converter_dir).resolve()
    else:
        # 스크립트 위치에서 자동 감지
        script_dir = Path(__file__).parent.resolve()
        converter_dir = script_dir
    
    # Spectec 바이너리 경로 확인
    spectec_bin = Path(args.spectec_bin).resolve()
    if not spectec_bin.exists():
        print(f"Error: Spectec binary not found: {spectec_bin}")
        sys.exit(1)
    
    # 디렉터리인 경우, 내부의 spectec-core 실행 파일을 찾습니다
    if spectec_bin.is_dir():
        # spectec-core/spectec-core 형태로 찾기
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
    
    # Runner 생성 및 실행
    runner = TestRunner(
        converter_dir=str(converter_dir),
        spectec_bin=str(spectec_bin),
        spec_dir=args.spec_dir
    )
    
    results = runner.run_tests(
        test_suite_dir=args.test_suite,
        output_dir=args.output_dir,
        verbose=args.verbose,
        test_filter=args.filter
    )
    
    # 실패한 테스트가 있으면 종료 코드 1
    sys.exit(1 if results["failed"] > 0 else 0)


if __name__ == "__main__":
    main()

