#!/usr/bin/env python3
"""Per-file coverage sets, unique lines and overlap from the per-file bundles.

For every build/audit/per-file/<File>.xcresult (written by measure-per-file.sh
with coverage on) this reads `xcrun xccov view --archive --json`, keeps the
first-party source lines (whitenoise-ios/, Shared/, NotificationServiceExtension/)
with executionCount > 0, and writes build/audit/coverage-unique.csv with one row
per suite:

  suite, file, covered_lines, unique_lines, overlaps_with, max_jaccard,
  shared_file, file_suites

Two corrections keep the numbers about test subjects rather than plumbing:
- the host-launch baseline (the empty-selection `overhead` bundle: AppState
  init, RootView, the bootstrap splash) is subtracted from every file;
- lines covered by more than `--ubiquity` of all files (default 15%: L10n
  lookups, hex/npub helpers, build-config reads) are excluded from
  `unique_lines` and from the Jaccard overlap, otherwise every suite that
  renders a localized string "overlaps" every other.

`unique_lines` are remaining lines no other test file covers. Suites that share
a test file share its coverage set (`shared_file` = 1) because one xcresult
covers all of them; read those rows at file granularity. A file whose bundle
covered no app line at all (disabled or skipped suites) gets empty cells, not
zeros. Coverage JSON is cached as <File>.coverage.json beside the bundle and
refreshed when the bundle is newer.

Usage: python3 scripts/audit/coverage-unique.py [--dir build/audit/per-file]
       [--out build/audit/coverage-unique.csv] [--top 3] [--ubiquity 0.15]
"""
import argparse
import csv
import glob
import json
import os
import subprocess
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftscan  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIRST_PARTY = ("whitenoise-ios/", "Shared/", "NotificationServiceExtension/")


def relative_to_root(path):
    """Repo-relative path for an absolute xccov path, anchored on the repo root.
    For a foreign root (another checkout or worktree) the first suffix that
    starts at a first-party directory and exists under ROOT wins, so a checkout
    directory named `whitenoise-ios` is not mistaken for the app target;
    otherwise the suffix at the last marker."""
    root = os.path.realpath(ROOT) + os.sep
    real = os.path.realpath(path)
    if real.startswith(root):
        return real[len(root):]
    parts = path.split("/")
    markers = {m.rstrip("/") for m in FIRST_PARTY}
    candidates = ["/".join(parts[i:]) for i, part in enumerate(parts[:-1]) if part in markers]
    for candidate in candidates:
        if os.path.exists(os.path.join(ROOT, candidate)):
            return candidate
    return candidates[-1] if candidates else path


def newest_mtime(bundle):
    newest = os.path.getmtime(bundle)
    for root, _, files in os.walk(bundle):
        for name in files:
            try:
                newest = max(newest, os.path.getmtime(os.path.join(root, name)))
            except OSError:
                pass
    return newest


def covered_lines(bundle, cache):
    if os.path.exists(cache) and (not os.path.exists(bundle) or os.path.getmtime(cache) >= newest_mtime(bundle)):
        with open(cache) as fh:
            return {tuple(x) for x in json.load(fh)}
    try:
        out = subprocess.run(["xcrun", "xccov", "view", "--archive", "--json", bundle],
                             check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        detail = (getattr(exc, "stderr", None) or "").strip()
        print(f"warning: no coverage in {bundle}: {exc}" + (f": {detail}" if detail else ""), file=sys.stderr)
        return None
    data = json.loads(out)
    lines = set()
    for path, entries in data.items():
        if "/SourcePackages/" in path:
            continue
        rel = relative_to_root(path)
        if not rel.startswith(FIRST_PARTY) or rel.startswith("whitenoise-iosTests/"):
            continue
        for entry in entries:
            if entry.get("isExecutable") and entry.get("executionCount", 0) > 0:
                lines.add((rel, entry["line"]))
    with open(cache, "w") as fh:
        json.dump(sorted(lines), fh)
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="build/audit/per-file")
    ap.add_argument("--out", default="build/audit/coverage-unique.csv")
    ap.add_argument("--tests-dir", default="whitenoise-iosTests")
    ap.add_argument("--top", type=int, default=3, help="how many overlapping files to list")
    ap.add_argument("--ubiquity", type=float, default=0.15,
                    help="exclude lines covered by more than this fraction of files from unique/overlap")
    args = ap.parse_args(argv)
    os.chdir(ROOT)

    baseline = set()
    overhead_bundle = os.path.join(args.dir, "overhead.xcresult")
    unreadable = []
    if os.path.isdir(overhead_bundle):
        baseline = covered_lines(overhead_bundle, os.path.join(args.dir, "overhead.coverage.json"))
        if baseline is None:
            unreadable.append("overhead")
    raw = {}
    for bundle in sorted(glob.glob(os.path.join(args.dir, "*.xcresult"))):
        label = os.path.basename(bundle)[:-len(".xcresult")]
        if label == "overhead":
            continue
        lines = covered_lines(bundle, os.path.join(args.dir, label + ".coverage.json"))
        if lines is None:
            unreadable.append(label)
        else:
            raw[label] = lines - (baseline or set())
    # A dropped file would silently shrink the file count and skew the
    # overlap; an empty set (no app line covered) is still a measurement.
    if unreadable:
        raise SystemExit("cannot read coverage from: " + ", ".join(unreadable)
                         + " (re-measure with scripts/audit/measure-per-file.sh)")
    if not raw:
        raise SystemExit("no coverage sets found")

    counts = defaultdict(int)
    for lines in raw.values():
        for line in lines:
            counts[line] += 1
    threshold = args.ubiquity * len(raw)
    ubiquitous = {line for line, n in counts.items() if n > threshold}
    sets = {label: lines - ubiquitous for label, lines in raw.items()}
    print(f"host-launch baseline: {len(baseline)} lines subtracted; "
          f"{len(ubiquitous)} ubiquitous lines (covered by >{args.ubiquity:.0%} of {len(raw)} files) excluded")

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
                overlaps.append((inter / len(lines | sets[other]), other))
        overlaps.sort(reverse=True)
        top = overlaps[:args.top]
        test_file = os.path.join(args.tests_dir, label + ".swift")
        suites = [s.name for s in swiftscan.suites_in_file(test_file)] if os.path.exists(test_file) else [label]
        covered_app = len(raw[label])
        for suite in suites or [label]:
            rows.append({
                "suite": suite, "file": label + ".swift",
                "covered_lines": len(lines) if covered_app else "", "unique_lines": unique if covered_app else "",
                "overlaps_with": ";".join(f"{o}:{j:.2f}" for j, o in top),
                "max_jaccard": f"{top[0][0]:.3f}" if top else "", "shared_file": int(len(suites) > 1),
                "file_suites": len(suites),
            })

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, lineterminator="\n", fieldnames=[
            "suite", "file", "covered_lines", "unique_lines", "overlaps_with", "max_jaccard", "shared_file", "file_suites"])
        w.writeheader()
        w.writerows(rows)
    zero = {r["file"] for r in rows if r["unique_lines"] == 0}
    empty = {r["file"] for r in rows if r["covered_lines"] == ""}
    print(f"wrote {args.out}: {len(rows)} suite rows from {len(sets)} files; "
          f"{len(zero)} files with zero unique covered lines; {len(empty)} files covered no app line")
    for f in sorted(zero)[:40]:
        print("  no unique lines:", f)


if __name__ == "__main__":
    main()
