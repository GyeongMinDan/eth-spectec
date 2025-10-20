import argparse
import importlib
import sys
from typing import Any

def compare_ssz_files(file1_path: str, file2_path: str, type_module: str, type_name: str) -> bool:
    mod = importlib.import_module(type_module)
    typ = getattr(mod, type_name, None)
    if typ is None:
        raise SystemExit(f"Type {type_name!r} not found in module {type_module!r}")

    with open(file1_path, "rb") as f:
        ssz_bytes1 = f.read()
    
    with open(file2_path, "rb") as f:
        ssz_bytes2 = f.read()

    try:
        view1 = typ.decode_bytes(ssz_bytes1)
        view2 = typ.decode_bytes(ssz_bytes2)
    except Exception as e:
        raise SystemExit(f"Failed to deserialize SSZ files: {e}")

    return view1 == view2

def main():
    # Usage : python CompareResult.py [--type-module <module_path>] [--type <type_name>] <file1> <file2>
    # Example: python CompareResult.py --type-module eth2spec.capella.mainnet --type BeaconState state1.ssz state2.ssz
    p = argparse.ArgumentParser(description="Compare two SSZ files for equality.")
    p.add_argument("--type-module", default="eth2spec.capella.mainnet", help="Python module path containing the remerkleable type (default: eth2spec.capella.mainnet)")
    p.add_argument("--type", dest="type_name", default="BeaconState", help="Type name inside the module (default: BeaconState)")
    p.add_argument("file1", help="First SSZ file path")
    p.add_argument("file2", help="Second SSZ file path")
    args = p.parse_args()

    try:
        are_equal = compare_ssz_files(args.file1, args.file2, args.type_module, args.type_name)
        
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
