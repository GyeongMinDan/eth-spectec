import json
from pathlib import Path

def check_slots(root_path, threshold=32):
    root = Path(root_path)
    
    # Matches seed_name/mutation_id
    for folder in root.glob("*/*"):
        if not folder.is_dir():
            continue
            
        block_file = folder / "block.json"
        pre_file = folder / "pre.json"
        
        if block_file.exists() and pre_file.exists():
            try:
                with open(block_file) as b, open(pre_file) as p:
                    b_data = json.load(b)
                    p_data = json.load(p)
                    
                    # Access the specific fields
                    # Using .get() or nested keys as per your structure
                    b_slot = b_data['message']['slot']
                    p_slot = p_data['slot']
                    
                    if abs(b_slot - p_slot) > threshold:
                        print(f"{folder}")
                        
            except (KeyError, json.JSONDecodeError, TypeError):
                # Skips malformed JSONs or missing keys
                continue

if __name__ == "__main__":
    import sys
    # Run as: python3 script.py .
    path = sys.argv[1] if len(sys.argv) > 1 else "."
    check_slots(path)
