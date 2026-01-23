#!/usr/bin/env python3
"""
Measure LOC differences between Capella and Deneb spec versions.
Counts non-empty lines only (excludes blank lines and whitespace-only lines).
"""

from pathlib import Path

def count_lines(filepath):
    """Count non-empty lines in a file (excludes blank lines, whitespace-only lines, and comments starting with ;;)."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return sum(1 for line in f if line.strip() and not line.strip().startswith(';;'))
    except Exception as e:
        print(f"Error reading {filepath}: {e}")
        return 0

def main():
    base_dir = Path(__file__).parent
    capella_dir = base_dir / "spec" / "spec_capella"
    deneb_dir = base_dir / "spec" / "spec_deneb"
    
    if not capella_dir.exists() or not deneb_dir.exists():
        print(f"Error: Directories not found")
        print(f"  Capella: {capella_dir}")
        print(f"  Deneb: {deneb_dir}")
        return
    
    # Get all .spectec files
    capella_files = sorted(capella_dir.glob("*.spectec"))
    deneb_files = sorted(deneb_dir.glob("*.spectec"))
    
    # Create mapping by filename
    capella_map = {f.name: f for f in capella_files}
    deneb_map = {f.name: f for f in deneb_files}
    
    all_files = sorted(set(capella_map.keys()) | set(deneb_map.keys()))
    
    total_capella_loc = 0
    total_deneb_loc = 0
    total_added = 0
    total_removed = 0
    changed_files = []
    
    print("=" * 80)
    print("Spec Diff Analysis: Capella vs Deneb")
    print("=" * 80)
    print()
    
    for filename in all_files:
        capella_file = capella_map.get(filename)
        deneb_file = deneb_map.get(filename)
        
        if capella_file and deneb_file:
            capella_loc = count_lines(capella_file)
            deneb_loc = count_lines(deneb_file)
            total_capella_loc += capella_loc
            total_deneb_loc += deneb_loc
            
            if capella_loc != deneb_loc:
                changed_files.append({
                    'filename': filename,
                    'capella': capella_loc,
                    'deneb': deneb_loc,
                    'net': deneb_loc - capella_loc
                })
        elif capella_file:
            loc = count_lines(capella_file)
            total_capella_loc += loc
            changed_files.append({
                'filename': filename,
                'capella': loc,
                'deneb': 0,
                'net': -loc
            })
        elif deneb_file:
            loc = count_lines(deneb_file)
            total_deneb_loc += loc
            changed_files.append({
                'filename': filename,
                'capella': 0,
                'deneb': loc,
                'net': loc
            })
    
    print("Summary:")
    print(f"  Capella total LOC: {total_capella_loc}")
    print(f"  Deneb total LOC:   {total_deneb_loc}")
    print(f"  Net change:        {total_deneb_loc - total_capella_loc:+d} lines")
    print()
    print("Note: Only non-empty lines are counted (blank lines and whitespace-only lines are excluded).")
    print()
    
    if changed_files:
        print(f"Changed files ({len(changed_files)}):")
        print("-" * 80)
        for f in sorted(changed_files, key=lambda x: abs(x['net']), reverse=True):
            print(f"  {f['filename']:40s}  Capella: {f['capella']:5d}  Deneb: {f['deneb']:5d}  Net: {f['net']:+6d}")
        print()

if __name__ == "__main__":
    main()
