#!/usr/bin/env python3
"""
Branch coverage figure generation script for eth2 client comparison.

Generates branch coverage figures from final_coverage_epoch_slots reports:
- Figure 1A: Branch coverage comparison across clients
- Figure 1B: Instrumented branch scope size (denominator) comparison

Usage:
    python3 make_coverage_figure.py --input-dir <input_dir> --output-dir <output_dir> --format <format>
    
    Run without arguments to see detailed usage information:
    python3 make_coverage_figure.py
    
Examples:
    # Generate PNG figures
    python3 make_coverage_figure.py --input-dir ./final_coverage_epoch_slots --output-dir ./figures --format png
    
    # Generate PDF figures
    python3 make_coverage_figure.py --input-dir ./final_coverage_epoch_slots --output-dir ./my_figures --format pdf
    
    # Generate SVG figures
    python3 make_coverage_figure.py --input-dir ./final_coverage_epoch_slots --output-dir ./figures --format svg
    
Required packages:
    pip install matplotlib numpy
    
Input directory structure:
    final_coverage_epoch_slots/
        lighthouse/report/summary.txt
        prysm/report/coverage.html
        teku/report/index.html
        nimbus/report/index.html
        lodestar/report/index.html
"""

import os
import re
import json
import argparse
from pathlib import Path
from collections import defaultdict
from html.parser import HTMLParser
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
from matplotlib import rcParams

# Set font for publication-quality figures
rcParams['font.family'] = 'serif'
rcParams['font.sans-serif'] = ['DejaVu Sans', 'Arial', 'Helvetica']
rcParams['font.size'] = 10
rcParams['axes.labelsize'] = 11
rcParams['axes.titlesize'] = 12
rcParams['xtick.labelsize'] = 10
rcParams['ytick.labelsize'] = 10
rcParams['legend.fontsize'] = 9
rcParams['figure.titlesize'] = 14

CLIENTS = ["lighthouse", "prysm", "nimbus", "teku", "lodestar"]
CLIENT_DISPLAY_NAMES = {
    "prysm": "Prysm",
    "lighthouse": "Lighthouse",
    "teku": "Teku",
    "nimbus": "Nimbus",
    "lodestar": "Lodestar"
}


def parse_lodestar_branch_coverage(report_dir):
    """Parse Lodestar (c8) branch coverage from HTML report."""
    html_file = report_dir / "index.html"
    if not html_file.exists():
        return None, None
    
    try:
        with open(html_file, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find Branches coverage: <span class="strong">50.26% </span> and <span class='fraction'>193/384</span>
        branches_match = re.search(r'<span class="strong">([\d.]+)%\s*</span>\s*<span class="quiet">Branches</span>', content)
        fraction_match = re.search(r'<span class="quiet">Branches</span>.*?<span class=\'fraction\'>(\d+)/(\d+)</span>', content, re.DOTALL)
        
        if branches_match and fraction_match:
            coverage_pct = float(branches_match.group(1))
            covered = int(fraction_match.group(1))
            total = int(fraction_match.group(2))
            return coverage_pct, total
    except Exception as e:
        print(f"  Warning: Failed to parse Lodestar branch coverage: {e}")
    
    return None, None


def parse_prysm_branch_coverage(report_dir):
    """Parse Prysm (Go) branch coverage from HTML report.
    
    Go branch coverage format:
    - HTML: Contains "Overall Branch Coverage (go-bcov derived): X.X%" and "Covered: Y/Z branches"
    """
    html_file = report_dir / "coverage.html"
    
    if not html_file.exists():
        return None, None
    
    try:
        # Get percentage and total from HTML
        # Use chunked reading for large files
        with open(html_file, 'r', encoding='utf-8') as f:
            # Read in chunks to find the branch coverage section
            content = ""
            found_section = False
            for line in f:
                if 'Overall Branch Coverage' in line:
                    found_section = True
                    content = line
                    # Read a few more lines to get the full section
                    for _ in range(5):
                        try:
                            content += next(f)
                        except StopIteration:
                            break
                    break
        
        if not found_section:
            return None, None
        
        # Parse: "Overall Branch Coverage (go-bcov derived): 1.5%"
        coverage_match = re.search(r'Overall Branch Coverage.*?:\s*([\d.]+)%', content)
        # Parse: "Covered: 190/12282 branches"
        fraction_match = re.search(r'Covered:\s*(\d+)/(\d+)\s*branches', content)
        
        if coverage_match and fraction_match:
            coverage_pct = float(coverage_match.group(1))
            covered = int(fraction_match.group(1))
            total = int(fraction_match.group(2))
            return coverage_pct, total
        elif coverage_match:
            # If we only have percentage, return it without total
            coverage_pct = float(coverage_match.group(1))
            return coverage_pct, None
            
    except Exception as e:
        print(f"  Warning: Failed to parse Prysm branch coverage: {e}")
    
    return None, None


def parse_lighthouse_branch_coverage(report_dir):
    """Parse Lighthouse (Rust/llvm-cov) branch coverage from summary.txt.
    
    Format: TOTAL <regions_total> <regions_missed> <regions_cover>% <funcs_total> <funcs_missed> <funcs_exec>% <lines_total> <lines_missed> <lines_cover>% <branches_total> <branches_missed> <branches_cover>%
    Example: TOTAL 99435 95365 4.09% 8760 8422 3.86% 76827 73537 4.28% 2459 2307 6.18%
    """
    summary_file = report_dir / "summary.txt"
    if not summary_file.exists():
        return None, None
    
    try:
        with open(summary_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        # Find TOTAL line at the end
        for line in reversed(lines):
            if line.strip().startswith('TOTAL'):
                parts = line.split()
                # Branch coverage is the last 3 columns: <branches_total> <branches_missed> <branches_cover>%
                # Count from the end: last is percentage, second-to-last is missed, third-to-last is total
                if len(parts) >= 3:
                    try:
                        # Last element should be the percentage
                        if parts[-1].endswith('%'):
                            coverage_pct = float(parts[-1].rstrip('%'))
                            # Third-to-last should be total branches
                            total_branches = int(parts[-3])
                            return coverage_pct, total_branches
                    except (ValueError, IndexError) as e:
                        print(f"  Warning: Failed to parse branch coverage from TOTAL line: {e}")
                        print(f"    Line: {line.strip()}")
                        print(f"    Parts: {parts}")
                break
    except Exception as e:
        print(f"  Warning: Failed to parse Lighthouse branch coverage: {e}")
    
    return None, None


def parse_teku_branch_coverage(report_dir):
    """Parse Teku (JaCoCo) branch coverage from coverage.xml.
    
    JaCoCo coverage.xml format:
    - Root level has <counter type="BRANCH"> with missed and covered attributes
    - Total branches = missed + covered
    - Coverage % = covered / (missed + covered) * 100
    """
    xml_file = report_dir / "coverage.xml"
    if not xml_file.exists():
        return None, None
    
    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(xml_file)
        root = tree.getroot()
        
        # Find BRANCH counter at root level (total coverage)
        branch_counter = None
        for counter in root.findall('counter'):
            if counter.get('type') == 'BRANCH':
                branch_counter = counter
                break
        
        if branch_counter is not None:
            missed = int(branch_counter.get('missed', 0))
            covered = int(branch_counter.get('covered', 0))
            total = missed + covered
            if total > 0:
                coverage_pct = (covered / total * 100)
                return coverage_pct, total
            else:
                return 0.0, 0
    except Exception as e:
        print(f"  Warning: Failed to parse Teku branch coverage from XML: {e}")
        import traceback
        traceback.print_exc()
    
    return None, None


def parse_nimbus_branch_coverage(report_dir):
    """Parse Nimbus (lcov) branch coverage from HTML report."""
    html_file = report_dir / "index.html"
    if not html_file.exists():
        return None, None
    
    try:
        with open(html_file, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # LCOV HTML format: "Branches:" row with "Hit / Total" and percentage
        # Format: <td class="headerItem">Branches:</td><td class="headerCovTableEntry">4359</td><td class="headerCovTableEntry">108044</td><td class="headerCovTableEntryLo">4.0 %</td>
        branches_match = re.search(r'<td class="headerItem">Branches:</td>.*?<td class="headerCovTableEntry">(\d+)</td>.*?<td class="headerCovTableEntry">(\d+)</td>.*?<td class="headerCovTableEntry[^"]*">([\d.]+)\s*%</td>', content, re.DOTALL)
        if branches_match:
            covered = int(branches_match.group(1))
            total = int(branches_match.group(2))
            coverage_pct = float(branches_match.group(3))
            return coverage_pct, total
    except Exception as e:
        print(f"  Warning: Failed to parse Nimbus branch coverage: {e}")
    
    return None, None


def collect_coverage_data(results_dir):
    """
    Collect branch coverage data from final_coverage_epoch_slots directory.
    
    Directory structure:
        results_dir/
            lighthouse/report/
            prysm/report/
            teku/report/
            nimbus/report/
            lodestar/report/
    
    Returns:
        coverage_data: dict[client] = (coverage_pct, total_branches)
        clients: sorted list of client names with data
    """
    results_path = Path(results_dir)
    coverage_data = {}
    
    print(f"Scanning branch coverage reports in: {results_path}")
    
    # Collect data for each client
    for client in CLIENTS:
        client_path = results_path / client
        report_dir = client_path / "report"
        
        if not report_dir.exists():
            print(f"  {client}: report directory not found")
            continue
        
        print(f"\nProcessing: {client}")
        
        # Parse branch coverage based on client type
        if client == "lodestar":
            coverage_pct, total = parse_lodestar_branch_coverage(report_dir)
        elif client == "prysm":
            coverage_pct, total = parse_prysm_branch_coverage(report_dir)
        elif client == "lighthouse":
            coverage_pct, total = parse_lighthouse_branch_coverage(report_dir)
        elif client == "teku":
            coverage_pct, total = parse_teku_branch_coverage(report_dir)
        elif client == "nimbus":
            coverage_pct, total = parse_nimbus_branch_coverage(report_dir)
        else:
            continue
        
        if coverage_pct is not None:
            coverage_data[client] = (coverage_pct, total)
            print(f"  Branch coverage: {coverage_pct:.1f}%", end="")
            if total:
                print(f" ({total} branches)")
            else:
                print()
        else:
            print(f"  Failed to parse branch coverage")
    
    # Keep clients in CLIENTS order (not sorted alphabetically)
    clients = [c for c in CLIENTS if c in coverage_data]
    print(f"\nFound branch coverage data for {len(clients)} client(s)")
    
    return coverage_data, clients


def create_figure_1a(coverage_data, clients, output_path):
    """Create Figure 1A: Branch coverage comparison across clients."""
    fig, ax = plt.subplots(figsize=(10, 6))
    fig.suptitle('Figure 1A: Branch Coverage Comparison', fontsize=14, fontweight='bold')
    
    colors = {
        'prysm': '#1f77b4',
        'lighthouse': '#ff7f0e',
        'teku': '#2ca02c',
        'nimbus': '#d62728',
        'lodestar': '#9467bd'
    }
    
    # Collect coverage percentages for each client
    labels = []
    values = []
    bar_colors = []
    
    for client in clients:
        if client in coverage_data:
            coverage_pct, total = coverage_data[client]
            labels.append(CLIENT_DISPLAY_NAMES[client])
            values.append(coverage_pct)
            bar_colors.append(colors.get(client, '#888888'))
    
    if not labels:
        ax.text(0.5, 0.5, 'No data available', ha='center', va='center', transform=ax.transAxes)
        plt.tight_layout()
        plt.savefig(output_path, dpi=300, bbox_inches='tight')
        print(f"Saved Figure 1A: {output_path} (no data)")
        return
    
    x_pos = np.arange(len(labels))
    bars = ax.bar(x_pos, values, color=bar_colors, alpha=0.7, edgecolor='black', linewidth=1)
    
    # Set y-axis range
    y_min = max(0, min(values) - 5)
    y_max = min(100, max(values) + 5)
    ax.set_ylim(y_min, y_max)
    
    ax.set_xlabel('Client', fontweight='bold')
    ax.set_ylabel('Branch Coverage (%)', fontweight='bold')
    ax.set_xticks(x_pos)
    ax.set_xticklabels(labels, rotation=0)
    ax.grid(True, alpha=0.3, axis='y')
    
    # Add value labels on bars
    for bar, val in zip(bars, values):
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
                f'{val:.1f}%',
                ha='center', va='bottom', fontweight='bold', fontsize=10)
    
    plt.tight_layout()
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"\nSaved Figure 1A: {output_path}")


def create_figure_1b(coverage_data, clients, output_path):
    """Create Figure 1B: Instrumented branch scope size (denominator) comparison.
    
    Shows the number of instrumented branches (denominator) for each client.
    This helps explain why coverage percentages differ across clients.
    """
    fig, ax = plt.subplots(figsize=(10, 6))
    
    colors = {
        'prysm': '#1f77b4',
        'lighthouse': '#ff7f0e',
        'teku': '#2ca02c',
        'nimbus': '#d62728',
        'lodestar': '#9467bd'
    }
    
    labels = []
    values = []
    bar_colors = []
    
    for client in clients:
        if client in coverage_data:
            coverage_pct, total = coverage_data[client]
            if total is not None:
                labels.append(CLIENT_DISPLAY_NAMES[client])
                values.append(total / 1000)  # Convert to K (thousands)
                bar_colors.append(colors.get(client, '#888888'))
    
    if not labels:
        ax.text(0.5, 0.5, 'No data available', ha='center', va='center', transform=ax.transAxes)
        plt.tight_layout()
        plt.savefig(output_path, dpi=300, bbox_inches='tight')
        print(f"Saved Figure 1B: {output_path} (no data)")
        return
    
    x_pos = np.arange(len(labels))
    bars = ax.bar(x_pos, values, color=bar_colors, alpha=0.7, edgecolor='black', linewidth=1)
    
    ax.set_xlabel('Client', fontweight='bold')
    ax.set_ylabel('Instrumented Branches (K)', fontweight='bold')
    ax.set_title('Figure 1B: Instrumented Branch Scope Size Comparison\n(Total branches measured in cumulative coverage)', 
                 fontweight='bold', fontsize=12)
    ax.set_xticks(x_pos)
    ax.set_xticklabels(labels, rotation=0)
    ax.grid(True, alpha=0.3, axis='y')
    
    # Add value labels on bars
    for bar, val in zip(bars, values):
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
                f'{val:.1f}',
                ha='center', va='bottom', fontweight='bold', fontsize=10)
    
    # Add note about missing clients
    missing_clients = [CLIENT_DISPLAY_NAMES[c] for c in CLIENTS if c not in clients]
    if missing_clients:
        note_text = f"Note: {', '.join(missing_clients)} data not available"
        ax.text(0.02, 0.98, note_text, transform=ax.transAxes, 
                verticalalignment='top', fontsize=9, style='italic',
                bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))
    
    plt.tight_layout()
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"Saved Figure 1B: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate coverage figures from final_coverage_epoch_slots reports",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 make_coverage_figure.py --input-dir ./final_coverage_epoch_slots --output-dir ./figures --format png
  python3 make_coverage_figure.py --input-dir ./final_coverage_epoch_slots --output-dir ./my_figures --format pdf
  python3 make_coverage_figure.py --input-dir ./final_coverage_epoch_slots --format svg

Required packages:
  pip install matplotlib numpy
        """
    )
    parser.add_argument(
        "--input-dir",
        type=str,
        required=True,
        help="Path to final_coverage_epoch_slots directory containing client coverage reports"
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        required=True,
        help="Output directory for generated figures"
    )
    parser.add_argument(
        "--format",
        type=str,
        required=True,
        choices=["png", "pdf", "svg"],
        help="Output format for figures (png, pdf, or svg)"
    )
    
    args = parser.parse_args()
    
    # Resolve input directory (try relative to script location first, then current directory)
    script_dir = Path(__file__).parent
    input_dir_candidates = [
        script_dir / args.input_dir,
        Path(args.input_dir).resolve(),
        Path.cwd() / args.input_dir
    ]
    
    results_path = None
    for candidate in input_dir_candidates:
        if candidate.exists() and candidate.is_dir():
            results_path = candidate.resolve()
            break
    
    if results_path is None:
        print(f"Error: Input directory not found: {args.input_dir}")
        print(f"  Tried:")
        for candidate in input_dir_candidates:
            print(f"    - {candidate}")
        return 1
    
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Collect coverage data
    print("=" * 60)
    print("Collecting branch coverage data...")
    print("=" * 60)
    coverage_data, clients = collect_coverage_data(results_path)
    
    if not clients:
        print("Error: No client coverage data found")
        return 1
    
    # Create figures
    print("\n" + "=" * 60)
    print("Generating figures...")
    print("=" * 60)
    
    fig1a_path = output_dir / f"figure_1a_branch_coverage.{args.format}"
    fig1b_path = output_dir / f"figure_1b_instrumented_branches.{args.format}"
    
    create_figure_1a(coverage_data, clients, fig1a_path)
    create_figure_1b(coverage_data, clients, fig1b_path)
    
    # Print summary statistics
    print("\n" + "=" * 60)
    print("Summary Statistics")
    print("=" * 60)
    for client in clients:
        if client in coverage_data:
            coverage_pct, total = coverage_data[client]
            print(f"\n{CLIENT_DISPLAY_NAMES[client]}:")
            print(f"  Branch Coverage: {coverage_pct:.1f}%")
            if total is not None:
                print(f"  Instrumented Branches: {total:,} ({total/1000:.1f}K)")
    
    print(f"\nFigures saved to: {output_dir}")
    return 0


if __name__ == "__main__":
    exit(main())
