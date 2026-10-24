#!/usr/bin/env python3
"""Turn the per-file measurement runs into per-suite costs.

Reads build/audit/per-file/<File>.log (written by measure-per-file.sh, each
ending with a `==> <File>: Ns status=S` marker) and <File>.xcresult (per-test
durations via `xcrun xcresulttool get test-results tests`), subtracts the fixed
per-process overhead measured by the `overhead` run, and writes
build/audit/per-file-costs.csv with one row per suite:

  suite, file, wall_s, overhead_s, net_wall_s, tests, sum_test_s, max_test_s,
  status

`net_wall_s` is the serialized cost of running that file's suites in their own
process: build attach/launch/discovery removed. `sum_test_s` is the sum of
Swift Testing's per-test durations inside that process; with one file per
process, contention is limited to tests of the same file, so it is a fair
upper bound of CPU-ish cost. Suites that share a file share the file's wall
time; `sum_test_s`/`max_test_s`/`tests` are per suite.

Usage: python3 scripts/audit/per-file-costs.py [--dir build/audit/per-file]
       [--out build/audit/per-file-costs.csv] [--xcresulttool-json-dir DIR]
"""
import argparse
import csv
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

MARKER = re.compile(r"==> (?P<label>\S+): (?P<secs>\d+)s status=(?P<status>\d+)")
DURATION = re.compile(r"([\d.,]+)\s*(ms|s|m)?")


def parse_duration(value):
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    m = DURATION.match(str(value).strip())
    if not m:
        return 0.0
    number = float(m.group(1).replace(",", "."))
    unit = m.group(2) or "s"
    return number / 1000 if unit == "ms" else number * 60 if unit == "m" else number


def wall_from_log(path):
    """Wall seconds and exit status from the LAST `==> label: Ns status=S` marker
    (a rerun appends a new marker; the newest run is the one the bundle belongs to)."""
    found = (None, None)
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = MARKER.search(line)
            if m:
                found = (int(m.group("secs")), int(m.group("status")))
    return found


def bundle_mtime(bundle):
    """Newest mtime inside the bundle (the directory mtime does not change when
    xcodebuild rewrites its contents)."""
    newest = os.path.getmtime(bundle)
    for root, _, files in os.walk(bundle):
        for name in files:
            try:
                newest = max(newest, os.path.getmtime(os.path.join(root, name)))
            except OSError:
                pass
    return newest


def tests_json(bundle, cache_dir=None):
    if cache_dir:
        cached = os.path.join(cache_dir, os.path.basename(bundle) + ".json")
        if os.path.exists(cached) and os.path.getmtime(cached) >= bundle_mtime(bundle):
            with open(cached) as fh:
                return json.load(fh)
    try:
        out = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
            check=True, capture_output=True, text=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"warning: cannot read {bundle}: {exc}", file=sys.stderr)
        return None
    data = json.loads(out)
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
        with open(os.path.join(cache_dir, os.path.basename(bundle) + ".json"), "w") as fh:
            json.dump(data, fh)
    return data


def per_suite_durations(data):
    """suite name -> list of test-case durations (seconds)."""
    result = defaultdict(list)

    def walk(node, suite):
        kind = node.get("nodeType")
        name = node.get("name", "")
        if kind == "Test Suite":
            suite = name
        if kind == "Test Case":
            result[suite or "?"].append(parse_duration(node.get("duration")))
        for child in node.get("children") or []:
            walk(child, suite)

    for root in data.get("testNodes", []):
        walk(root, None)
    return result


def scan_suites(tests_dir="whitenoise-iosTests"):
    """(display name -> type name, type name -> framework) for every suite in the
    test tree, via the shared scanner. Display names are what xcresult and the
    Swift Testing log print for suites declared with @Suite("…")."""
    import glob
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("suite_names", os.path.join(here, "suite-names.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    mapping, frameworks = {}, {}
    for path in glob.glob(os.path.join(tests_dir, "*.swift")):
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        masked = module.swiftscan.mask(text)
        for suite in module.swiftscan.suites_in_file(path, masked):
            frameworks[suite.name] = suite.framework
            shown = module.display_name(suite.declaration, masked)
            if shown:
                mapping[shown] = suite.name
    return mapping, frameworks


def display_name_map(tests_dir="whitenoise-iosTests"):
    return scan_suites(tests_dir)[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="build/audit/per-file")
    ap.add_argument("--tests-dir", default="whitenoise-iosTests")
    ap.add_argument("--out", default="build/audit/per-file-costs.csv")
    ap.add_argument("--xcresulttool-json-dir", default=None,
                    help="cache directory for xcresulttool JSON (defaults to <dir>/json)")
    args = ap.parse_args()
    cache = args.xcresulttool_json_dir or os.path.join(args.dir, "json")
    display_to_type = display_name_map(args.tests_dir)

    overhead_s, _ = wall_from_log(os.path.join(args.dir, "overhead.log")) if os.path.exists(
        os.path.join(args.dir, "overhead.log")) else (None, None)
    if overhead_s is None:
        print("warning: no overhead run; net_wall_s equals wall_s", file=sys.stderr)
        overhead_s = 0

    rows = []
    for entry in sorted(os.listdir(args.dir)):
        if not entry.endswith(".log") or entry in ("overhead.log", "runs.log"):
            continue
        label = entry[:-4]
        wall, status = wall_from_log(os.path.join(args.dir, entry))
        bundle = os.path.join(args.dir, label + ".xcresult")
        suites = {}
        if os.path.isdir(bundle):
            data = tests_json(bundle, cache)
            if data:
                suites = per_suite_durations(data)
        if not suites:
            rows.append({"suite": label, "file": label + ".swift", "wall_s": wall, "overhead_s": overhead_s,
                         "net_wall_s": None if wall is None else max(0, wall - overhead_s), "file_suites": 0,
                         "shared_file": 0, "tests": 0, "sum_test_s": "", "max_test_s": "", "status": status})
            continue
        for suite, durations in sorted(suites.items()):
            rows.append({
                "suite": display_to_type.get(suite, suite), "file": label + ".swift", "wall_s": wall,
                "overhead_s": overhead_s, "net_wall_s": None if wall is None else max(0, wall - overhead_s),
                "file_suites": len(suites), "shared_file": int(len(suites) > 1),
                "tests": len(durations), "sum_test_s": round(sum(durations), 3),
                "max_test_s": round(max(durations), 3) if durations else "", "status": status,
            })

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        writer = csv.DictWriter(fh, lineterminator="\n", fieldnames=[
            "suite", "file", "wall_s", "overhead_s", "net_wall_s", "file_suites", "shared_file", "tests",
            "sum_test_s", "max_test_s", "status"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {args.out}: {len(rows)} suite rows from {len(set(r['file'] for r in rows))} files; "
          f"overhead {overhead_s}s per process")
    top = sorted((r for r in rows if isinstance(r["net_wall_s"], int)), key=lambda r: -r["net_wall_s"])[:15]
    for r in top:
        print(f"  {r['net_wall_s']:5d}s net  {r['suite']} ({r['file']}, {r['tests']} tests, sum {r['sum_test_s']}s)")


if __name__ == "__main__":
    main()
