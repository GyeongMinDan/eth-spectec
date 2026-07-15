import argparse
import shutil
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description="Filter valid JSON tests.")
    parser.add_argument("json_dir", type=Path)
    parser.add_argument("ssz_dir", type=Path)
    parser.add_argument("out_dir", type=Path)
    args = parser.parse_args()

    total_tests = 0
    valid_tests = 0

    # .glob("*/*") grabs the mutation_id directories directly
    for mut_dir in args.json_dir.glob("*/*"):
        if mut_dir.is_dir():
            total_tests += 1
            
            # Extract names to rebuild the path
            seed_name = mut_dir.parent.name
            mut_name = mut_dir.name
            
            expected_ssz = args.ssz_dir / seed_name / mut_name / "pre.ssz"
            
            if expected_ssz.is_file():
                dest = args.out_dir / seed_name / mut_name
                
                # Ensure the seed_name folder exists in the out_dir first
                dest.parent.mkdir(parents=True, exist_ok=True)
                
                # Copy the mutation folder over
                shutil.copytree(mut_dir, dest, dirs_exist_ok=True) 
                valid_tests += 1

    filtered_tests = total_tests - valid_tests

    print("\n--- Filtering Complete ---")
    print(f"1) Total tests:     {total_tests}")
    print(f"2) Filtered out:    {filtered_tests}")
    print(f"3) Valid remaining: {valid_tests}")

if __name__ == "__main__":
    main()
