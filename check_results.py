#!/usr/bin/env python3
"""
Script to check experiment results in node_result_mutated_case_* folders
Finds mismatch cases in Output_Status_*.csv files
(Cases where not all clients are SUCCESS and not all clients are FAIL)
"""

import os
import csv
import glob
import json
from pathlib import Path
from collections import defaultdict

def parse_status_value(value):
    """Parse status value and return status code (0, 1, 2, etc.)"""
    if not value or value.strip() == '':
        return None
    value = value.strip()
    # Handle formats like "0", "0(SUCCESS)", "1", "1(FAIL)", "2", "2(CRASH)", etc.
    if value.startswith('0'):
        return 0
    elif value.startswith('1'):
        return 1
    elif value.startswith('2'):
        return 2
    return None

def check_mismatch_cases(base_dir):
    """Find mismatch cases and crash cases in Output_Status_*.csv files"""
    mismatch_cases = []
    crash_cases = []
    # Recursively search for all Output_Status_*.csv files in the base directory
    pattern = os.path.join(base_dir, "**", "Output_Status_*.csv")
    files = glob.glob(pattern, recursive=True)
    print(f"\n=== Checking Output_Status files (total {len(files)} files) ===\n")
    
    clients = ['Lighthouse', 'Prysm', 'Nimbus', 'Teku', 'Lodestar']
    
    for file_path in sorted(files):
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                reader = csv.DictReader(f)
                for row_num, row in enumerate(reader, start=2):  # Start from after header
                    pair_num = row.get('Pair #', '')
                    
                    # Collect status codes for each client
                    client_statuses = {}
                    status_codes = []
                    
                    for client in clients:
                        value = row.get(client, '')
                        status_code = parse_status_value(value)
                        if status_code is not None:
                            client_statuses[client] = {
                                'status': status_code,
                                'value': value
                            }
                            status_codes.append(status_code)
                    
                    # Check if all clients have the same status code
                    unique_statuses = set(status_codes)
                    
                    # Check for crash cases (cases containing status code 2)
                    has_crash = 2 in unique_statuses
                    
                    # List of clients that crashed
                    crashed_clients = [client for client, info in client_statuses.items() if info['status'] == 2]
                    
                    case_data = {
                        'file': file_path,
                        'pair': pair_num,
                        'line': row_num,
                        'client_statuses': client_statuses,
                        'unique_statuses': sorted(unique_statuses),
                        'has_crash': has_crash,
                        'crashed_clients': crashed_clients
                    }
                    
                    # Track crash cases separately
                    if has_crash:
                        crash_cases.append(case_data)
                    
                    # Mismatch case: not all clients are SUCCESS(0) and not all clients are FAIL(1)
                    # i.e., some succeed and some fail, or there's a crash, or statuses differ
                    # Exclude cases where all clients are 0 or all clients are 1
                    if not (len(unique_statuses) == 1 and (0 in unique_statuses or 1 in unique_statuses)):
                        mismatch_cases.append(case_data)
        except Exception as e:
            print(f"Error occurred ({file_path}): {e}")
    
    return mismatch_cases, crash_cases

def get_status_label(status_code):
    """Convert status code to label"""
    labels = {
        0: "SUCCESS",
        1: "FAIL",
        2: "CRASH"
    }
    return labels.get(status_code, f"UNKNOWN({status_code})")

def main(base_dir):
    """Check mismatch cases in the specified directory"""
    # Convert to absolute path
    base_dir = os.path.abspath(base_dir)
    
    if not os.path.isdir(base_dir):
        print(f"Error: Directory does not exist: {base_dir}")
        return
    
    print("=" * 80)
    print("Starting experiment results check")
    print(f"Base directory: {base_dir}")
    print("=" * 80)
    
    # Check mismatch cases and crash cases
    mismatch_cases, crash_cases = check_mismatch_cases(base_dir)
    
    print(f"\n[Result] Mismatch cases: {len(mismatch_cases)} found")
    print("(Cases where not all clients are SUCCESS and not all clients are FAIL)")
    print(f"\n[Result] Crash cases: {len(crash_cases)} found")
    print("(Cases containing status code 2 (CRASH))")
    
    if mismatch_cases:
        print("\nCases with mismatches:")
        print("-" * 80)
        
        for case in mismatch_cases:
            rel_path = os.path.relpath(case['file'], base_dir)
            print(f"\nFile: {rel_path}")
            print(f"  Pair #{case['pair']} (Line {case['line']})")
            print(f"  Status codes: {', '.join(map(str, case['unique_statuses']))}")
            
            # Indicate crash occurrence
            if case['has_crash']:
                print(f"  ⚠️  Crash occurred: {', '.join(case['crashed_clients'])}")
            
            print(f"  Client statuses:")
            
            # Group and output by status code
            status_groups = defaultdict(list)
            for client, info in case['client_statuses'].items():
                status_groups[info['status']].append((client, info['value']))
            
            for status_code in sorted(status_groups.keys()):
                label = get_status_label(status_code)
                clients = status_groups[status_code]
                print(f"    [{label} ({status_code})]")
                for client, value in clients:
                    print(f"      - {client}: {value}")
    else:
        print("\nNo mismatch cases found.")
        print("(All clients have the same status in all cases)")
    
    # Output crash cases separately
    if crash_cases:
        print("\n\nCases with crashes:")
        print("-" * 80)
        
        for case in crash_cases:
            rel_path = os.path.relpath(case['file'], base_dir)
            print(f"\nFile: {rel_path}")
            print(f"  Pair #{case['pair']} (Line {case['line']})")
            print(f"  Crashed clients: {', '.join(case['crashed_clients'])}")
            print(f"  Client statuses:")
            
            for client, info in case['client_statuses'].items():
                label = get_status_label(info['status'])
                marker = "💥" if info['status'] == 2 else "  "
                print(f"    {marker} {client}: {label} ({info['status']}) - {info['value']}")
    else:
        print("\nNo crash cases found.")
    
    print("\n" + "=" * 80)
    print("Check completed")
    print("=" * 80)
    
    # Output summary
    print(f"\n[Summary]")
    print(f"  - Mismatch cases: {len(mismatch_cases)}")
    print(f"  - Crash cases: {len(crash_cases)}")
    
    # Statistics by status code
    if mismatch_cases:
        status_counts = defaultdict(int)
        for case in mismatch_cases:
            for status_code in case['unique_statuses']:
                status_counts[status_code] += 1
        
        print(f"\n  Statistics by status code:")
        for status_code in sorted(status_counts.keys()):
            label = get_status_label(status_code)
            print(f"    - {label} ({status_code}): included in {status_counts[status_code]} cases")
    
    # Statistics by crashed client
    if crash_cases:
        crash_client_counts = defaultdict(int)
        for case in crash_cases:
            for client in case['crashed_clients']:
                crash_client_counts[client] += 1
        
        print(f"\n  Statistics by crashed client:")
        for client in sorted(crash_client_counts.keys()):
            print(f"    - {client}: {crash_client_counts[client]} cases")
    
    # Save to JSON file (formatted nicely)
    if mismatch_cases or crash_cases:
        # Organize data structure for JSON output
        json_output = {
            'summary': {
                'total_mismatch_cases': len(mismatch_cases),
                'total_crash_cases': len(crash_cases),
                'status_code_statistics': {},
                'crash_client_statistics': {}
            },
            'mismatch_cases': [],
            'crash_cases': []
        }
        
        # Add statistics by status code
        status_counts = defaultdict(int)
        for case in mismatch_cases:
            for status_code in case['unique_statuses']:
                status_counts[status_code] += 1
        
        for status_code in sorted(status_counts.keys()):
            label = get_status_label(status_code)
            json_output['summary']['status_code_statistics'][label] = {
                'code': status_code,
                'count': status_counts[status_code]
            }
        
        # Add statistics by crashed client
        crash_client_counts = defaultdict(int)
        for case in crash_cases:
            for client in case['crashed_clients']:
                crash_client_counts[client] += 1
        
        for client in sorted(crash_client_counts.keys()):
            json_output['summary']['crash_client_statistics'][client] = crash_client_counts[client]
        
        # Organize mismatch case data
        for case in mismatch_cases:
            rel_path = os.path.relpath(case['file'], base_dir)
            
            # Format client statuses for better readability
            client_statuses_formatted = {}
            for client, info in case['client_statuses'].items():
                client_statuses_formatted[client] = {
                    'status_code': info['status'],
                    'status_label': get_status_label(info['status']),
                    'raw_value': info['value']
                }
            
            json_case = {
                'file': rel_path,
                'file_full_path': case['file'],
                'pair_number': case['pair'],
                'line_number': case['line'],
                'unique_status_codes': case['unique_statuses'],
                'unique_status_labels': [get_status_label(sc) for sc in case['unique_statuses']],
                'has_crash': case['has_crash'],
                'crashed_clients': case['crashed_clients'],
                'client_statuses': client_statuses_formatted
            }
            json_output['mismatch_cases'].append(json_case)
        
        # Organize crash case data
        for case in crash_cases:
            rel_path = os.path.relpath(case['file'], base_dir)
            
            # Format client statuses for better readability
            client_statuses_formatted = {}
            for client, info in case['client_statuses'].items():
                client_statuses_formatted[client] = {
                    'status_code': info['status'],
                    'status_label': get_status_label(info['status']),
                    'raw_value': info['value'],
                    'is_crashed': info['status'] == 2
                }
            
            json_case = {
                'file': rel_path,
                'file_full_path': case['file'],
                'pair_number': case['pair'],
                'line_number': case['line'],
                'crashed_clients': case['crashed_clients'],
                'crashed_client_count': len(case['crashed_clients']),
                'unique_status_codes': case['unique_statuses'],
                'unique_status_labels': [get_status_label(sc) for sc in case['unique_statuses']],
                'client_statuses': client_statuses_formatted
            }
            json_output['crash_cases'].append(json_case)
        
        # Save JSON file (formatted nicely)
        output_json_path = os.path.join(base_dir, "mismatch_cases_report.json")
        with open(output_json_path, 'w', encoding='utf-8') as f:
            json.dump(json_output, f, ensure_ascii=False, indent=2)
        
        print(f"\n[JSON Output]")
        print(f"  - Results saved to: {os.path.relpath(output_json_path, base_dir)}")
        print(f"  - Formatting: 2-space indent, UTF-8 encoding")
        print(f"  - Mismatch cases: {len(mismatch_cases)}")
        print(f"  - Crash cases: {len(crash_cases)}")

if __name__ == "__main__":
    import sys
    
    # Check command line arguments
    if len(sys.argv) > 1:
        if sys.argv[1] in ["-h", "--help"]:
            print("Usage:")
            print("  python check_results.py <directory>  # Check mismatch cases in specified directory")
            print("")
            print("This script searches for Output_Status_*.csv files recursively in the specified")
            print("directory and finds mismatch cases (where not all clients have the same status).")
        else:
            # Treat first argument as directory path
            main(sys.argv[1])
    else:
        print("Error: Directory path is required")
        print("Usage: python check_results.py <directory>")
        print("       python check_results.py --help  # Show usage information")

