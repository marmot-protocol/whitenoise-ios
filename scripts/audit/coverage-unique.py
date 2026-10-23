#!/usr/bin/env python3
"""Per-file coverage sets, unique lines and overlap from the per-file bundles.

For every build/audit/per-file/<File>.xcresult (written by measure-per-file.sh
with coverage on) this reads `xcrun xccov view --archive --json`, keeps the
first-party source lines (whitenoise-ios/, Shared/, NotificationServiceExtension/)
with executionCount > 0, and writes build/audit/coverage-unique.csv with one row
per suite:

  suite, file, covered_lines, unique_lines, overlaps_with, max_jaccard, shared_file

`unique_lines` are lines no other test file covers. Suites that share a test
file share its coverage set (`shared_file` = 1) because one xcresult covers
all of them; read those rows at file granularity. Coverage JSON is cached as
<File>.coverage.json beside the bundle so reruns are cheap.

Usage: python3 scripts/audit/coverage-unique.py [--dir build/audit/per-file]
       [--out build/audit/coverage-unique.csv] [--top 3]
"""
import argparse
import csv
import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

FIRST_PARTY = ("/whitenoise-ios/", "/Shared/", "/NotificationServiceExtension/")
SUITE_RE = re.compile(r"^(?:@MainActor\s+)?(?:final\s+)?(?:struct|class|enum) (\w+Tests)\b", re.M)


def covered_lines(bundle, cache):
    if os.path.exists(cache):
        with open(cache) as fh:
            return {tuple(x) for x in json.load(fh)}
    try:
        out = subprocess.run(["xcrun", "xccov", "view", "--archive", "--json", bundle],
                             check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"warning: no coverage in {bundle}: {exc}", file=sys.stderr)
        return None
    data = json.loads(out)
    lines = set()
    for path, entries in data.items():
        if not any(marker in path for marker in FIRST_PARTY) or "/SourcePackages/" in path:
            continue
        rel = path.split("/white-noise-ios/", 1)[-1] if "/white-noise-ios/" in path else path
        rel = re.sub(r"^.*?/(whitenoise-ios|Shared|NotificationServiceExtension)/", r"\1/", rel)
        for entry in entries:
            if entry.get("isExecutable") and entry.get("executionCount", 0) > 0:
                lines.add((rel, entry["line"]))
    with open(cache, "w") as fh:
        json.dump(sorted(lines), fh)
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="build/audit/per-file")
    ap.add_argument("--out", default="build/audit/coverage-unique.csv")
    ap.add_argument("--tests-dir", default="whitenoise-iosTests")
    ap.add_argument("--top", type=int, default=3, help="how many overlapping files to list")
    args = ap.parse_args()

    # Every process also executes the host app's launch path (AppState init,
    # RootView, the bootstrap splash); the empty-selection `overhead` bundle
    # covers exactly that, so subtract it or every file overlaps every other.
    baseline = set()
    overhead_bundle = os.path.join(args.dir, "overhead.xcresult")
    if os.path.isdir(overhead_bundle):
        baseline = covered_lines(overhead_bundle, os.path.join(args.dir, "overhead.coverage.json")) or set()
    sets = {}
    for bundle in sorted(glob.glob(os.path.join(args.dir, "*.xcresult"))):
        label = os.path.basename(bundle)[:-len(".xcresult")]
        if label == "overhead":
            continue
        lines = covered_lines(bundle, os.path.join(args.dir, label + ".coverage.json"))
        if lines is not None:
            sets[label] = lines - baseline
    if not sets:
        raise SystemExit("no coverage sets found")
    print(f"host-launch baseline: {len(baseline)} lines subtracted from every file")

    counts = defaultdict(int)
    for lines in sets.values():
        for line in lines:
            counts[line] += 1

    labels = sorted(sets)
    rows = []
    for label in labels:
        lines = sets[label]
        unique = sum(1 for line in lines if counts[line] == 1)
        overlaps = []
        for other in labels:
            if other == label or not sets[other]:
                continue
            inter = len(lines & sets[other])
            if inter:
                union = len(lines | sets[other])
                overlaps.append((inter / union, other))
        overlaps.sort(reverse=True)
        top = overlaps[:args.top]
        test_file = os.path.join(args.tests_dir, label + ".swift")
        suites = SUITE_RE.findall(open(test_file).read()) if os.path.exists(test_file) else [label]
        for suite in suites or [label]:
            rows.append({
                "suite": suite, "file": label + ".swift", "covered_lines": len(lines), "unique_lines": unique,
                "overlaps_with": ";".join(f"{o}:{j:.2f}" for j, o in top),
                "max_jaccard": f"{top[0][0]:.3f}" if top else "", "shared_file": int(len(suites) > 1),
            })

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, lineterminator="\n", fieldnames=["suite", "file", "covered_lines", "unique_lines", "overlaps_with",
                                           "max_jaccard", "shared_file"])
        w.writeheader()
        w.writerows(rows)
    zero = [r["file"] for r in rows if r["unique_lines"] == 0 and r["covered_lines"] > 0]
    print(f"wrote {args.out}: {len(rows)} suite rows from {len(sets)} files; "
          f"{len(set(zero))} files with zero unique covered lines")
    for f in sorted(set(zero))[:40]:
        print("  no unique lines:", f)


if __name__ == "__main__":
    main()
