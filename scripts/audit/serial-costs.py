#!/usr/bin/env python3
"""Per-suite costs from a serial (parallel-execution-off) run.

Reads `xcrun xcresulttool get test-results tests` for the given bundle and
writes build/audit/serial-costs.csv: suite, tests, sum_test_s, max_test_s,
failed. With parallel execution disabled, per-test durations are not inflated
by waiting on other tests, so the sums are usable as serialized cost.

Usage: python3 scripts/audit/serial-costs.py build/audit/serial.xcresult [--out ...]
"""
import argparse
import csv
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("per_file_costs", os.path.join(HERE, "per-file-costs.py"))
per_file_costs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(per_file_costs)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle")
    ap.add_argument("--out", default="build/audit/serial-costs.csv")
    ap.add_argument("--json", default=None, help="use a saved xcresulttool JSON instead of calling it")
    ap.add_argument("--log", default=None,
                    help="raw timed-xcodebuild log of the same run; adds wall_s per suite from Swift Testing's "
                         "`Suite X passed after N seconds` lines (millisecond precision, unlike xcresult durations)")
    args = ap.parse_args()

    suite_wall = {}
    if args.log:
        import re
        suite_re = re.compile(r"Suite (\S+) (?:passed|failed) after ([\d.]+) seconds")
        with open(args.log, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = suite_re.search(re.sub(r"\x1b\[[0-9;]*m", "", line))
                if m:
                    suite_wall[m.group(1)] = float(m.group(2))

    if args.json:
        data = json.load(open(args.json))
    else:
        data = json.loads(subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", args.bundle],
            check=True, capture_output=True, text=True).stdout)

    durations = per_file_costs.per_suite_durations(data)
    failed = {}

    def walk(node, suite):
        kind = node.get("nodeType")
        if kind == "Test Suite":
            suite = node.get("name")
        if kind == "Test Case" and node.get("result") not in ("Passed", "Skipped", None):
            failed[suite] = failed.get(suite, 0) + 1
        for child in node.get("children") or []:
            walk(child, suite)

    for root in data.get("testNodes", []):
        walk(root, None)

    rows = []
    for suite, ds in sorted(durations.items()):
        rows.append({"suite": suite, "tests": len(ds), "sum_test_s": round(sum(ds), 3),
                     "max_test_s": round(max(ds), 3) if ds else "", "failed": failed.get(suite, 0),
                     "wall_s": suite_wall.get(suite, "")})
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["suite", "tests", "sum_test_s", "max_test_s", "failed", "wall_s"])
        w.writeheader()
        w.writerows(rows)
    total = sum(r["sum_test_s"] for r in rows)
    wall_total = sum(v for v in suite_wall.values())
    print(f"wrote {args.out}: {len(rows)} suites, {sum(r['tests'] for r in rows)} tests, "
          f"summed test time {total:.1f}s, suite wall {wall_total:.1f}s, failed cases {sum(failed.values())}")
    key = (lambda r: -(r["wall_s"] or 0)) if suite_wall else (lambda r: -r["sum_test_s"])
    for r in sorted(rows, key=key)[:20]:
        wall = f"{r['wall_s']:8.2f}s wall" if r["wall_s"] != "" else f"{r['sum_test_s']:8.1f}s sum "
        print(f"  {wall}  {r['tests']:4d} tests  {r['suite']}")


if __name__ == "__main__":
    main()
