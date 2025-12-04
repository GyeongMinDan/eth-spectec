import argparse
import os
import sys

def compare_ssz_files(file1_path: str, file2_path: str) -> bool:
    """두 SSZ 파일의 바이트를 직접 비교합니다."""
    with open(file1_path, "rb") as f:
        ssz_bytes1 = f.read()
    
    with open(file2_path, "rb") as f:
        ssz_bytes2 = f.read()

    return ssz_bytes1 == ssz_bytes2

def main():
    # Usage : python CompareResult.py <file1> <file2>
    # Example: python CompareResult.py state1.ssz state2.ssz
    p = argparse.ArgumentParser(description="Compare two SSZ files for equality (byte-by-byte comparison).")
    p.add_argument("file1", help="First SSZ file path")
    p.add_argument("file2", help="Second SSZ file path")
    args = p.parse_args()

    try:
        are_equal = compare_ssz_files(args.file1, args.file2)
        
        if are_equal:
            print("SUCCESS: The two SSZ files are identical.")
            sys.exit(0)
        else:
            print("FAILURE: The two SSZ files are different.")
            sys.exit(1)
            
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
