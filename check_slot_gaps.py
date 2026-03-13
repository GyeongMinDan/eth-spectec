#!/usr/bin/env python3
"""Check slot gaps (block.slot - state.slot) across a test directory.

Usage:
    python check_slot_gaps.py <test_dir> [--max-gap N]

Each subdirectory of <test_dir> should contain pre.json and block.json.
Reports tests whose gap exceeds --max-gap (default: 32).
"""

import json
import os
import sys
import argparse


def get_slot(data, *paths):
    """Try each path in order; return the first int found, or None."""
    for path in paths:
        node = data
        for key in path:
            if not isinstance(node, dict):
                node = None
                break
            node = node.get(key)
        if node is not None:
            try:
                return int(node)
            except (ValueError, TypeError):
                pass
    return None


def check_test(test_dir):
    pre_path = os.path.join(test_dir, "pre.json")
    block_path = os.path.join(test_dir, "block.json")
    if not os.path.exists(pre_path) or not os.path.exists(block_path):
        return None

    with open(pre_path) as f:
        pre = json.load(f)
    with open(block_path) as f:
        block = json.load(f)

    state_slot = get_slot(pre, ["slot"])
    block_slot = get_slot(block, ["message", "slot"], ["slot"])

    if state_slot is None or block_slot is None:
        return None

    return block_slot - state_slot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("test_dir", help="Directory containing test subdirectories")
    parser.add_argument("--max-gap", type=int, default=32,
                        help="Report tests exceeding this gap (default: 32)")
    args = parser.parse_args()

    entries = sorted(os.listdir(args.test_dir))
    results = []
    errors = []

    for name in entries:
        path = os.path.join(args.test_dir, name)
        if not os.path.isdir(path):
            continue
        gap = check_test(path)
        if gap is None:
            errors.append(name)
        else:
            results.append((name, gap))

    over_limit = [(name, gap) for name, gap in results if gap > args.max_gap]
    within_limit = [(name, gap) for name, gap in results if gap <= args.max_gap]

    print(f"Tests checked : {len(results)}")
    print(f"Within limit  : {len(within_limit)}  (gap <= {args.max_gap})")
    print(f"Over limit    : {len(over_limit)}  (gap > {args.max_gap})")
    if errors:
        print(f"Skipped       : {len(errors)}  (missing pre.json or block.json)")

    if within_limit:
        print(f"\nTests within limit (gap <= {args.max_gap}):")
        for name, gap in sorted(within_limit, key=lambda x: x[1]):
            print(f"  {gap:>6}  {name}")

    if over_limit:
        print(f"\nTests over limit (gap > {args.max_gap}):")
        for name, gap in sorted(over_limit, key=lambda x: -x[1]):
            print(f"  {gap:>6}  {name}")


if __name__ == "__main__":
    main()
