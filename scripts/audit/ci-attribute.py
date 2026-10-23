#!/usr/bin/env python3
"""Attribute failed CI runs to test suites.

Reads build/audit/ci-runs.json (gh run list output) and the failed-step logs
under build/audit/ci-logs/<run_id>.log, and writes:

  ci-history.csv       suite, failures, master_failures, branches, kinds, runs
  ci-unattributed.csv  run_id, kind, event, branch   (runs no suite explains)

Attribution sources, all from xcodebuild/xcbeautify output:
- Swift Testing: `Suite X failed after …` (quoted display names allowed);
- XCTest: `##[error]    testFoo, failed` and `Test Case '-[Module.Class testFoo]'
  failed`, mapped from method to class through the test sources;
- XCTest crash/restart: a `Test Suite 'X' started at …` with no matching
  `passed|failed at` line later in the log means the host died inside X.

Only the failed runs in the current ci-runs.json are attributed (logs left in
ci-logs from an older window are ignored); a failed run whose log could not
be fetched is listed as `log-unavailable`. Run kinds: `build-failure` (`** TEST BUILD FAILED **`), `test-failure` (some
suite attributed), `host-crash` (`** TEST EXECUTE FAILED **` with a crashed
suite), `execute-failure` (execute failed, nothing attributed), `other`
(post-step gates etc.). `master_failures` counts failures on push events to
master; a failure on a PR branch is often the test catching a regression that
the same PR then fixed, so it is listed separately rather than treated as
flakiness.

Usage: python3 scripts/audit/ci-attribute.py [--out-dir build/audit] [--tests-dir whitenoise-iosTests]
"""
import argparse
import csv
import glob
import json
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftscan  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;]*m")
ST_FAILED = re.compile(r'Suite ("(?:[^"\\]|\\.)*"|\S+)(?: with \d+ known issues?)? failed after')
XCT_METHOD = re.compile(r"##\[error\]\s+(test\w+), failed|Test Case '-\[[\w.]+\.(\w+) (test\w+)\]' failed")
XCT_STARTED = re.compile(r"Test Suite '([^']+)' started at ")
XCT_EXECUTED = re.compile(r"Executed \d+ tests?, with")
HOST_DIED = re.compile(r"encountered an error \((?:Early unexpected exit|Crash|Test crashed)")
XCT_SKIP = {"All tests", "Selected tests"}


def xctest_method_map(tests_dir):
    """XCTest method name -> class name, from the test sources."""
    mapping = {}
    for path in glob.glob(os.path.join(tests_dir, "*.swift")):
        try:
            for suite in swiftscan.suites_in_file(path):
                if suite.framework == "XCTest":
                    for test in suite.tests:
                        mapping[test.name] = suite.name
        except (OSError, UnicodeDecodeError):
            continue
    return mapping


def attribute(text, method_map):
    """Return (kind, {suite: how}) for one failed-step log."""
    text = ANSI.sub("", text)
    suites = {}
    for m in ST_FAILED.finditer(text):
        suites[m.group(1).strip('"')] = "failed"
    for m in XCT_METHOD.finditer(text):
        method = m.group(1) or m.group(3)
        cls = m.group(2) or method_map.get(method)
        suites[cls or f"XCTest/{method}"] = "failed"
    # xcbeautify prints no per-class "passed at" line, so a crash shows as an
    # XCTest class that starts and is followed by a `Selected tests` restart (or
    # a host-died message) before any `Executed N tests` summary.
    current = None
    for line in text.splitlines():
        m = XCT_STARTED.search(line)
        if m:
            name = m.group(1)
            if name == "Selected tests" and current and current not in suites:
                suites[current] = "crashed"
            if name in XCT_SKIP or name.endswith(".xctest"):
                continue
            current = name
            continue
        if XCT_EXECUTED.search(line):
            current = None
            continue
        if HOST_DIED.search(line) and current and current not in suites:
            suites[current] = "crashed"
    if "** TEST BUILD FAILED **" in text or ("BUILD FAILED" in text and "TEST EXECUTE" not in text):
        kind = "build-failure"
    elif suites:
        kind = "host-crash" if any(v == "crashed" for v in suites.values()) and "failed" not in suites.values() else "test-failure"
    elif "** TEST EXECUTE FAILED **" in text:
        kind = "execute-failure"
    else:
        kind = "other"
    return kind, suites


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default="build/audit")
    ap.add_argument("--tests-dir", default="whitenoise-iosTests")
    args = ap.parse_args(argv)
    out = args.out_dir
    with open(os.path.join(out, "ci-runs.json")) as fh:
        runs = {str(r["databaseId"]): r for r in json.load(fh)}
    method_map = xctest_method_map(args.tests_dir)

    per_suite = defaultdict(lambda: {"runs": set(), "master": set(), "branches": set(), "kinds": set()})
    unattributed = []
    for run_id in sorted(r for r, run in runs.items() if run.get("conclusion") == "failure"):
        run = runs[run_id]
        path = os.path.join(out, "ci-logs", run_id + ".log")
        if not os.path.exists(path):
            unattributed.append((run_id, "log-unavailable", run.get("event", ""), run.get("headBranch", "")))
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            kind, suites = attribute(fh.read(), method_map)
        if not suites:
            unattributed.append((run_id, kind, run.get("event", ""), run.get("headBranch", "")))
            continue
        for suite, how in suites.items():
            entry = per_suite[suite]
            entry["runs"].add(run_id)
            entry["branches"].add(run.get("headBranch", ""))
            entry["kinds"].add(how)
            if run.get("event") == "push" and run.get("headBranch") == "master":
                entry["master"].add(run_id)

    with open(os.path.join(out, "ci-history.csv"), "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["suite", "failures", "master_failures", "branches", "kinds", "runs"])
        for suite, e in sorted(per_suite.items(), key=lambda kv: (-len(kv[1]["runs"]), kv[0])):
            w.writerow([suite, len(e["runs"]), len(e["master"]), len(e["branches"]), ";".join(sorted(e["kinds"])),
                        ";".join(sorted(e["runs"]))])
    with open(os.path.join(out, "ci-unattributed.csv"), "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["run_id", "kind", "event", "branch"])
        w.writerows(unattributed)
    print(f"wrote ci-history.csv ({len(per_suite)} suites) and ci-unattributed.csv ({len(unattributed)} runs)")
    for suite, e in sorted(per_suite.items(), key=lambda kv: -len(kv[1]["runs"]))[:15]:
        print(f"  {len(e['runs']):3d} ({len(e['master'])} on master, {len(e['branches'])} branches, {'/'.join(sorted(e['kinds']))})  {suite}")
    kinds = defaultdict(int)
    for _, kind, _, _ in unattributed:
        kinds[kind] += 1
    if kinds:
        print("  unattributed by kind:", dict(kinds))


if __name__ == "__main__":
    main()
