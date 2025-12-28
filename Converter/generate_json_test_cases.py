#!/usr/bin/env python3
"""
Generate JSON input/output test case pairs from the official Ethereum test suite.

This script processes test cases and generates (pre.json, block.json, post.json) triples
that can be used to test the SpecTec OCaml interpreter.

For single-block tests, uses existing post.ssz if available.
For multi-block tests, generates intermediate post-states using eth2spec.
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
        
        # consensus-specs path
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
    
    def generate(
        self, 
        test_suite_dir: str, 
        output_dir: str,
        test_filter: str = None,
        verbose: bool = False
    ) -> dict:
        """
        테스트 스위트에서 JSON 테스트 케이스들을 생성합니다.
        
        Args:
            test_suite_dir: 테스트 스위트 디렉터리
            output_dir: 출력 디렉터리
            test_filter: 테스트 케이스 이름 필터 (옵션)
            verbose: 상세 출력 여부
        
        Returns:
            결과 딕셔너리
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
