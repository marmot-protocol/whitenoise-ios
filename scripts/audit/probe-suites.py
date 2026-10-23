#!/usr/bin/env python3
"""Which suites to run against a mutation probe.

Selection order, first that yields something:
  explicit  the probe's own "suites" list (a hand override);
  coverage  every test file whose per-file coverage set (build/audit/per-file/
            <File>.coverage.json from coverage-unique.py) executes a line of the
            mutated text, mapped to the suites declared in that file;
  file      files covering any line of the mutated production file;
  grep      files whose text mentions the probe's "grep" symbol.

A suite that is not selected is not evidence of anything; a selected suite
that passes the mutant executed the mutated lines and did not notice.

Prints `# method: <name>` then one suite type name per line.
Usage: probe-suites.py PROBE.json [--per-file-dir build/audit/per-file] [--tests-dir whitenoise-iosTests]
"""
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftscan  # noqa: E402


def mutated_lines(path, old):
    source = open(path, encoding="utf-8").read()
    index = source.find(old)
    if index < 0:
        return []
    first = source.count("\n", 0, index) + 1
    last = first + old.count("\n") - (1 if old.endswith("\n") else 0)
    return list(range(first, max(first, last) + 1))


def coverage_sets(per_file_dir):
    sets = {}
    for cache in glob.glob(os.path.join(per_file_dir, "*.coverage.json")):
        label = os.path.basename(cache)[:-len(".coverage.json")]
        if label == "overhead":
            continue
        with open(cache) as fh:
            sets[label] = {(rel, line) for rel, line in json.load(fh)}
    return sets


def suites_in(tests_dir, label):
    path = os.path.join(tests_dir, label + ".swift")
    if not os.path.exists(path):
        return []
    return [s.name for s in swiftscan.suites_in_file(path)]


def select(probe, per_file_dir, tests_dir):
    if probe.get("suites"):
        return "explicit", list(probe["suites"])
    sets = coverage_sets(per_file_dir)
    rel = probe["path"]
    lines = set(mutated_lines(rel, probe["old"]))
    if sets and lines:
        exact = sorted(label for label, lines_ in sets.items() if any((rel, n) in lines_ for n in lines))
        if exact:
            return "coverage", sorted({s for label in exact for s in suites_in(tests_dir, label)})
        any_line = sorted(label for label, lines_ in sets.items() if any(r == rel for r, _ in lines_))
        if any_line:
            return "file", sorted({s for label in any_line for s in suites_in(tests_dir, label)})
    needle = probe.get("grep")
    if needle:
        suites = set()
        for path in sorted(glob.glob(os.path.join(tests_dir, "*.swift"))):
            if needle in open(path, encoding="utf-8", errors="replace").read():
                suites.update(s.name for s in swiftscan.suites_in_file(path))
        return "grep", sorted(suites)
    return "none", []


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("probe")
    ap.add_argument("--per-file-dir", default="build/audit/per-file")
    ap.add_argument("--tests-dir", default="whitenoise-iosTests")
    args = ap.parse_args()
    with open(args.probe) as fh:
        probe = json.load(fh)
    method, suites = select(probe, args.per_file_dir, args.tests_dir)
    print(f"# method: {method}")
    for suite in suites:
        print(suite)


if __name__ == "__main__":
    main()
