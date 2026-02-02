#!/usr/bin/env python3
"""
Branch coverage comparison figure: two result directories side-by-side.

Reads two directories (same structure as final_coverage_epoch_slots), collects
branch coverage per client from each, and draws grouped bar charts:
- Figure 1A: Branch coverage (%) — 5 clients × 2 bars (result_1, result_2)
- Figure 1B: Instrumented branches (K) — 5 clients × 2 bars

Bar colors are by directory: result_1 (one color), result_2 (other color).
Legend shows result_1 and result_2.

Usage:
    python3 make_compare_figure.py --input-dir-1 <dir1> --input-dir-2 <dir2> --output-dir <out> --format <png|pdf|svg>

Examples:
    python3 make_compare_figure.py --input-dir-1 ./result_a --input-dir-2 ./result_b --output-dir ./figures --format png
"""

import re
import argparse
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np
from matplotlib import rcParams

CLIENTS = ["lighthouse", "prysm", "nimbus", "teku", "lodestar"]
CLIENT_DISPLAY_NAMES = {
    "prysm": "Prysm",
    "lighthouse": "Lighthouse",
    "teku": "Teku",
    "nimbus": "Nimbus",
    "lodestar": "Lodestar",
}


def parse_lodestar_branch_coverage(report_dir):
    html_file = report_dir / "index.html"
    if not html_file.exists():
        return None, None
    try:
        with open(html_file, "r", encoding="utf-8") as f:
            content = f.read()
        branches_match = re.search(
            r'<span class="strong">([\d.]+)%\s*</span>\s*<span class="quiet">Branches</span>',
            content,
        )
        fraction_match = re.search(
            r"<span class=\"quiet\">Branches</span>.*?<span class='fraction'>(\d+)/(\d+)</span>",
            content,
            re.DOTALL,
        )
        if branches_match and fraction_match:
            return float(branches_match.group(1)), int(fraction_match.group(2))
    except Exception as e:
        print(f"  Warning: Lodestar parse failed: {e}")
    return None, None


def parse_prysm_branch_coverage(report_dir):
    html_file = report_dir / "coverage.html"
    if not html_file.exists():
        return None, None
    try:
        with open(html_file, "r", encoding="utf-8") as f:
            content = ""
            for line in f:
                if "Overall Branch Coverage" in line:
                    content = line
                    for _ in range(5):
                        try:
                            content += next(f)
                        except StopIteration:
                            break
                    break
        if not content:
            return None, None
        coverage_match = re.search(r"Overall Branch Coverage.*?:\s*([\d.]+)%", content)
        fraction_match = re.search(
            r"Covered:\s*(\d+)/(\d+)\s*branches", content
        )
        if coverage_match and fraction_match:
            return float(coverage_match.group(1)), int(fraction_match.group(2))
        if coverage_match:
            return float(coverage_match.group(1)), None
    except Exception as e:
        print(f"  Warning: Prysm parse failed: {e}")
    return None, None


def parse_lighthouse_branch_coverage(report_dir):
    summary_file = report_dir / "summary.txt"
    if not summary_file.exists():
        return None, None
    try:
        with open(summary_file, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for line in reversed(lines):
            if line.strip().startswith("TOTAL"):
                parts = line.split()
                if len(parts) >= 3 and parts[-1].endswith("%"):
                    return float(parts[-1].rstrip("%")), int(parts[-3])
                break
    except Exception as e:
        print(f"  Warning: Lighthouse parse failed: {e}")
    return None, None


def parse_teku_branch_coverage(report_dir):
    import xml.etree.ElementTree as ET

    for name in ("coverage_filtered.xml", "coverage.xml"):
        xml_file = report_dir / name
        if not xml_file.exists():
            continue
        try:
            tree = ET.parse(xml_file)
            root = tree.getroot()
            for counter in root.findall("counter"):
                if counter.get("type") == "BRANCH":
                    missed = int(counter.get("missed", 0))
                    covered = int(counter.get("covered", 0))
                    total = missed + covered
                    return (covered / total * 100) if total else 0.0, total
        except Exception as e:
            print(f"  Warning: Teku parse failed: {e}")
    return None, None


def parse_nimbus_branch_coverage(report_dir):
    html_file = report_dir / "index.html"
    if not html_file.exists():
        return None, None
    try:
        with open(html_file, "r", encoding="utf-8") as f:
            content = f.read()
        m = re.search(
            r'<td class="headerItem">Branches:</td>.*?<td class="headerCovTableEntry">(\d+)</td>.*?<td class="headerCovTableEntry">(\d+)</td>.*?<td class="headerCovTableEntry[^"]*">([\d.]+)\s*%</td>',
            content,
            re.DOTALL,
        )
        if m:
            return float(m.group(3)), int(m.group(2))
    except Exception as e:
        print(f"  Warning: Nimbus parse failed: {e}")
    return None, None


rcParams["font.family"] = "serif"
rcParams["font.size"] = 10
rcParams["axes.labelsize"] = 11
rcParams["axes.titlesize"] = 12
rcParams["legend.fontsize"] = 9

# Two colors for the two result directories (result_1, result_2)
COLOR_RESULT_1 = "#1f77b4"
COLOR_RESULT_2 = "#ff7f0e"
# change this variables to show in figure (baseline , baseline + spectec)
LABEL_RESULT_1 = "baseline"
LABEL_RESULT_2 = "baseline + ETH2SpecTec's test cases"


def collect_coverage_data_one(results_dir):
    """Collect branch coverage from one directory. Returns dict[client] = (pct, total)."""
    results_path = Path(results_dir)
    coverage_data = {}
    for client in CLIENTS:
        report_dir = results_path / client / "report"
        if not report_dir.exists():
            continue
        if client == "lodestar":
            pct, total = parse_lodestar_branch_coverage(report_dir)
        elif client == "prysm":
            pct, total = parse_prysm_branch_coverage(report_dir)
        elif client == "lighthouse":
            pct, total = parse_lighthouse_branch_coverage(report_dir)
        elif client == "teku":
            pct, total = parse_teku_branch_coverage(report_dir)
        elif client == "nimbus":
            pct, total = parse_nimbus_branch_coverage(report_dir)
        else:
            continue
        if pct is not None:
            coverage_data[client] = (pct, total)
    return coverage_data


def create_figure_1a_compare(data1, data2, clients, output_path):
    """Figure 1A: Branch coverage (%) — grouped bars, result_1 vs result_2."""
    fig, ax = plt.subplots(figsize=(10, 6))

    x = np.arange(len(clients))
    width = 0.35

    vals1 = [data1.get(c, (None, None))[0] for c in clients]
    vals2 = [data2.get(c, (None, None))[0] for c in clients]
    # Use 0 for missing so bar doesn't show, or omit; we draw only valid
    y1 = [v if v is not None else 0 for v in vals1]
    y2 = [v if v is not None else 0 for v in vals2]

    bars1 = ax.bar(
        x - width / 2,
        y1,
        width,
        label=LABEL_RESULT_1,
        color=COLOR_RESULT_1,
        alpha=0.8,
        edgecolor="black",
        linewidth=1,
    )
    bars2 = ax.bar(
        x + width / 2,
        y2,
        width,
        label=LABEL_RESULT_2,
        color=COLOR_RESULT_2,
        alpha=0.8,
        edgecolor="black",
        linewidth=1,
    )

    all_vals = [v for v in y1 + y2 if v > 0]
    if all_vals:
        ax.set_ylim(max(0, min(all_vals) - 5), min(100, max(all_vals) + 5))
    ax.set_xlabel("Client", fontweight="bold")
    ax.set_ylabel("Branch Coverage (%)", fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels([CLIENT_DISPLAY_NAMES[c] for c in clients], rotation=0)
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3, axis="y")

    for bar, val in zip(bars1, vals1):
        if val is not None:
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height(),
                f"{val:.1f}%",
                ha="center",
                va="bottom",
                fontsize=9,
            )
    for bar, val in zip(bars2, vals2):
        if val is not None:
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height(),
                f"{val:.1f}%",
                ha="center",
                va="bottom",
                fontsize=9,
            )

    plt.tight_layout()
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"Saved Figure 1A: {output_path}")


def create_figure_1b_compare(data1, data2, clients, output_path):
    """Figure 1B: Instrumented branches (K) — grouped bars, result_1 vs result_2."""
    fig, ax = plt.subplots(figsize=(10, 6))

    x = np.arange(len(clients))
    width = 0.35

    def to_k(data, clist):
        out = []
        for c in clist:
            _, total = data.get(c, (None, None))
            if total is not None:
                out.append(total / 1000)
            else:
                out.append(0)
        return out

    y1 = to_k(data1, clients)
    y2 = to_k(data2, clients)

    bars1 = ax.bar(
        x - width / 2,
        y1,
        width,
        label=LABEL_RESULT_1,
        color=COLOR_RESULT_1,
        alpha=0.8,
        edgecolor="black",
        linewidth=1,
    )
    bars2 = ax.bar(
        x + width / 2,
        y2,
        width,
        label=LABEL_RESULT_2,
        color=COLOR_RESULT_2,
        alpha=0.8,
        edgecolor="black",
        linewidth=1,
    )

    ax.set_xlabel("Client", fontweight="bold")
    ax.set_ylabel("Instrumented Branches (K)", fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels([CLIENT_DISPLAY_NAMES[c] for c in clients], rotation=0)
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3, axis="y")

    for bar, val in zip(bars1, y1):
        if val > 0:
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height(),
                f"{val:.1f}",
                ha="center",
                va="bottom",
                fontsize=9,
            )
    for bar, val in zip(bars2, y2):
        if val > 0:
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height(),
                f"{val:.1f}",
                ha="center",
                va="bottom",
                fontsize=9,
            )

    plt.tight_layout()
    plt.savefig(output_path, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"Saved Figure 1B: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Compare branch coverage from two result directories (grouped bars, result_1 vs result_2)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 make_compare_figure.py --input-dir-1 ./result_a --input-dir-2 ./result_b --output-dir ./figures --format png
  python3 make_compare_figure.py --input-dir-1 ./final_coverage_epoch_slots --input-dir-2 ./other_run --output-dir ./figures --format pdf
        """,
    )
    parser.add_argument(
        "--input-dir-1",
        type=str,
        required=True,
        help="First result directory (same structure as final_coverage_epoch_slots); shown as result_1",
    )
    parser.add_argument(
        "--input-dir-2",
        type=str,
        required=True,
        help="Second result directory; shown as result_2",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        required=True,
        help="Output directory for generated figures",
    )
    parser.add_argument(
        "--format",
        type=str,
        required=True,
        choices=["png", "pdf", "svg"],
        help="Output format for figures",
    )
    args = parser.parse_args()

    def resolve_dir(path_str):
        p = Path(path_str)
        for base in [Path(__file__).parent, Path.cwd()]:
            candidate = base / path_str
            if candidate.exists() and candidate.is_dir():
                return candidate.resolve()
        if p.exists() and p.is_dir():
            return p.resolve()
        return None

    dir1 = resolve_dir(args.input_dir_1)
    dir2 = resolve_dir(args.input_dir_2)
    if dir1 is None:
        print(f"Error: Input directory not found: {args.input_dir_1}")
        return 1
    if dir2 is None:
        print(f"Error: Input directory not found: {args.input_dir_2}")
        return 1

    print("Collecting branch coverage from directory 1 (result_1):", dir1)
    data1 = collect_coverage_data_one(dir1)
    print("Collecting branch coverage from directory 2 (result_2):", dir2)
    data2 = collect_coverage_data_one(dir2)

    clients = [c for c in CLIENTS if c in data1 or c in data2]
    if not clients:
        print("Error: No client data in either directory")
        return 1

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    ext = args.format
    create_figure_1a_compare(
        data1, data2, clients, out_dir / f"figure_1a_branch_coverage_compare.{ext}"
    )
    create_figure_1b_compare(
        data1, data2, clients, out_dir / f"figure_1b_instrumented_branches_compare.{ext}"
    )

    print(f"\nFigures saved to: {out_dir}")
    return 0


if __name__ == "__main__":
    exit(main())