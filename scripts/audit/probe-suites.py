#!/usr/bin/env python3
"""Which suites to run against a mutation probe.

Selection order, first that yields something:
  explicit  the probe's own "suites" list (a hand override);
  coverage  every test file whose per-file coverage set (build/audit/per-file/
            <File>.coverage.json from coverage-unique.py) executes a line of the
            mutated text, mapped to the suites declared in that file;
  file      files covering any line of the mutated production file;
  grep      files whose text mentions the probe's "grep" symbol.

A suite that is not selected is not evidence of anything. Coverage sets are
per test file, so a passing suite executed the mutated lines only when it was
selected by `coverage` from a file that declares no other suite (or listed by
hand); every other selected suite is printed under `# unverified:` and
mutate.sh records its pass as `unverified`, not as a survivor (`0`).

Prints `# method: <name>`, `# unverified: <suites>` when there are any, then
one suite type name per line.
Usage: probe-suites.py PROBE.json [--per-file-dir build/audit/per-file] [--tests-dir whitenoise-iosTests]
"""
import argparse
import glob
import importlib.util
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftscan  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "coverage_unique", os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage-unique.py"))
coverage_unique = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(coverage_unique)


def mutated_lines(path, old):
    source = open(path, encoding="utf-8").read()
    index = source.find(old)
    if index < 0:
        return []
    first = source.count("\n", 0, index) + 1
    last = first + old.count("\n") - (1 if old.endswith("\n") else 0)
    return list(range(first, max(first, last) + 1))


def coverage_sets(per_file_dir):
    """{label: covered lines} per test file. Goes through coverage-unique's
    reader, which re-reads a bundle that is newer than its cached JSON."""
    labels = {os.path.basename(p)[:-len(".coverage.json")]
              for p in glob.glob(os.path.join(per_file_dir, "*.coverage.json"))}
    labels |= {os.path.basename(p)[:-len(".xcresult")] for p in glob.glob(os.path.join(per_file_dir, "*.xcresult"))}
    sets = {}
    for label in sorted(labels - {"overhead"}):
        lines = coverage_unique.covered_lines(os.path.join(per_file_dir, label + ".xcresult"),
                                              os.path.join(per_file_dir, label + ".coverage.json"))
        if lines is not None:
            sets[label] = lines
    return sets


def suites_in(tests_dir, label):
    path = os.path.join(tests_dir, label + ".swift")
    if not os.path.exists(path):
        return []
    return [s.name for s in swiftscan.suites_in_file(path)]


def select(probe, per_file_dir, tests_dir):
    """Return (method, suites, unverified): `unverified` are the selected
    suites a pass says nothing about (see the module docstring)."""
    if probe.get("suites"):
        return "explicit", list(probe["suites"]), set()
    sets = coverage_sets(per_file_dir)
    rel = probe["path"]
    lines = set(mutated_lines(rel, probe["old"]))
    if sets and lines:
        exact = sorted(label for label, lines_ in sets.items() if any((rel, n) in lines_ for n in lines))
        if exact:
            per_file = {label: suites_in(tests_dir, label) for label in exact}
            suites = sorted({s for names in per_file.values() for s in names})
            unverified = {s for names in per_file.values() if len(names) > 1 for s in names}
            return "coverage", suites, unverified
        any_line = sorted(label for label, lines_ in sets.items() if any(r == rel for r, _ in lines_))
        if any_line:
            suites = sorted({s for label in any_line for s in suites_in(tests_dir, label)})
            return "file", suites, set(suites)
    needle = probe.get("grep")
    if needle:
        suites = set()
        for path in sorted(glob.glob(os.path.join(tests_dir, "*.swift"))):
            if needle in open(path, encoding="utf-8", errors="replace").read():
                suites.update(s.name for s in swiftscan.suites_in_file(path))
        return "grep", sorted(suites), set(suites)
    return "none", [], set()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("probe")
    ap.add_argument("--per-file-dir", default="build/audit/per-file")
    ap.add_argument("--tests-dir", default="whitenoise-iosTests")
    args = ap.parse_args()
    with open(args.probe) as fh:
        probe = json.load(fh)
    method, suites, unverified = select(probe, args.per_file_dir, args.tests_dir)
    if method in ("coverage", "file"):
        # A test file without a coverage set can never be selected by coverage;
        # say so, since its suites' silence is then not evidence of anything.
        measured = set(coverage_sets(args.per_file_dir))
        unmeasured = sorted(
            os.path.basename(p)[:-len(".swift")]
            for p in glob.glob(os.path.join(args.tests_dir, "*.swift"))
            if os.path.basename(p)[:-len(".swift")] not in measured and swiftscan.suites_in_file(p))
        if unmeasured:
            print(f"# warning: {len(unmeasured)} test file(s) have no coverage set and were not considered: "
                  + ", ".join(unmeasured), file=sys.stderr)
    print(f"# method: {method}")
    if unverified:
        print("# unverified: " + " ".join(sorted(unverified)))
    for suite in suites:
        print(suite)


if __name__ == "__main__":
    main()
