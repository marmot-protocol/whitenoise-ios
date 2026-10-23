#!/usr/bin/env python3
"""Per-suite costs from a serial (parallel-execution-off) run.

Reads `xcrun xcresulttool get test-results tests` for the given bundle and
writes build/audit/serial-costs.csv: suite, framework, tests, sum_test_s,
max_test_s, failed, wall_s. With parallel execution disabled, per-test
durations are not inflated by waiting on other tests, so the sums are usable
as serialized cost — but xcresult rounds them to whole seconds, so prefer
`wall_s`, which `--log` fills from the raw timed-xcodebuild log:

- Swift Testing suites: `Suite X passed after N seconds` (also quoted display
  names and `with N known issues`), millisecond precision.
- XCTest classes: the gap between `Test Suite 'X' started at <clock>` and
  `Test Suite 'X' passed|failed at <clock>`.

Suites declared `@Suite("Display Name")` are named by display name in both
xcresult and the log; they are mapped back to the type name so rows join the
inventory.

Usage: python3 scripts/audit/serial-costs.py build/audit/serial.xcresult
       [--log build/audit/serial-run.log] [--out ...] [--tests-dir whitenoise-iosTests]
"""
import argparse
import csv
import importlib.util
import json
import os
import re
import subprocess
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").replace(".py", ""), os.path.join(HERE, name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


per_file_costs = load("per-file-costs.py")

ANSI = re.compile(r"\x1b\[[0-9;]*m")
ST_SUITE = re.compile(r'Suite ("(?:[^"\\]|\\.)*"|\S+)(?: with \d+ known issues?)? (?:passed|failed) after ([\d.]+) seconds')
XCT_STARTED = re.compile(r"Test Suite '([^']+)' started at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
XCT_ENDED = re.compile(r"Test Suite '([^']+)' (?:passed|failed) at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
XCT_SKIP = {"All tests", "Selected tests"}


def parse_clock(text):
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f")


def suite_walls_from_log(path):
    """suite name (as printed) -> wall seconds, for Swift Testing and XCTest suites."""
    walls = {}
    started = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = ANSI.sub("", raw)
            m = ST_SUITE.search(line)
            if m:
                walls[m.group(1).strip('"')] = float(m.group(2))
                continue
            m = XCT_STARTED.search(line)
            if m and m.group(1) not in XCT_SKIP and not m.group(1).endswith(".xctest"):
                started[m.group(1)] = parse_clock(m.group(2))
                continue
            m = XCT_ENDED.search(line)
            if m and m.group(1) in started:
                walls[m.group(1)] = round((parse_clock(m.group(2)) - started.pop(m.group(1))).total_seconds(), 3)
    return walls


def failed_cases(data):
    """{suite: failed case count}. Only `Failed` counts: `Expected Failure`
    (withKnownIssue, XCTExpectFailure) is a pass."""
    failed = {}

    def walk(node, suite):
        kind = node.get("nodeType")
        if kind == "Test Suite":
            suite = node.get("name")
        if kind == "Test Case" and node.get("result") == "Failed":
            failed[suite] = failed.get(suite, 0) + 1
        for child in node.get("children") or []:
            walk(child, suite)

    for root in data.get("testNodes", []):
        walk(root, None)
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle")
    ap.add_argument("--out", default="build/audit/serial-costs.csv")
    ap.add_argument("--json", default=None, help="use a saved xcresulttool JSON instead of calling it")
    ap.add_argument("--log", default=None, help="raw timed-xcodebuild log of the same run (adds wall_s)")
    ap.add_argument("--tests-dir", default="whitenoise-iosTests")
    args = ap.parse_args()

    if args.json:
        with open(args.json) as fh:
            data = json.load(fh)
    else:
        data = json.loads(subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", args.bundle],
            check=True, capture_output=True, text=True).stdout)

    display_to_type, frameworks = per_file_costs.scan_suites(args.tests_dir)
    suite_wall = {display_to_type.get(k, k): v for k, v in (suite_walls_from_log(args.log).items() if args.log else [])}
    durations = per_file_costs.per_suite_durations(data)
    failed = failed_cases(data)

    rows = []
    for suite, ds in sorted(durations.items()):
        name = display_to_type.get(suite, suite)
        rows.append({"suite": name, "framework": frameworks.get(name, ""), "tests": len(ds),
                     "sum_test_s": round(sum(ds), 3), "max_test_s": round(max(ds), 3) if ds else "",
                     "failed": failed.get(suite, 0), "wall_s": suite_wall.get(name, "")})
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, lineterminator="\n",
                           fieldnames=["suite", "framework", "tests", "sum_test_s", "max_test_s", "failed", "wall_s"])
        w.writeheader()
        w.writerows(rows)
    total = sum(r["sum_test_s"] for r in rows)
    wall_total = sum(v for v in suite_wall.values())
    missing_wall = [r["suite"] for r in rows if r["wall_s"] == ""]
    print(f"wrote {args.out}: {len(rows)} suites, {sum(r['tests'] for r in rows)} tests, "
          f"summed test time {total:.1f}s, suite wall {wall_total:.1f}s, failed cases {sum(failed.values())}")
    if args.log and missing_wall:
        print(f"  {len(missing_wall)} suite(s) without a wall time in the log: {', '.join(missing_wall[:8])}")

    def key(r):
        return -(r["wall_s"] if r["wall_s"] != "" else r["sum_test_s"])

    for r in sorted(rows, key=key)[:20]:
        wall = f"{r['wall_s']:8.2f}s wall" if r["wall_s"] != "" else f"{r['sum_test_s']:8.1f}s sum "
        print(f"  {wall}  {r['tests']:4d} tests  {r['suite']}")


if __name__ == "__main__":
    main()
