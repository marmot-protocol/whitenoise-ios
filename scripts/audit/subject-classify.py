#!/usr/bin/env python3
"""Classify what each test actually exercises: app, mdk, test-helper, catalog or platform.

Builds identifier sets (app types and API from the app sources, MDK funcs
from the MarmotKit package, test-support types from the test directory) and
labels each test from its header, signature and body:

  catalog      reads an .xcstrings file or a Bundle resource
  app          references app code (directly, or through the helper funcs,
               properties, typealiases and test doubles it names, one level)
  mdk          invokes MDK funcs/methods more often than it references app
               code; `marmot.<name>(` always counts, an unqualified name only
               when neither the app nor the test tree declares it
  test-helper  references no app code, only test-support types
  platform     references none of the above (Foundation/SwiftUI/UIKit only)

MDK record types (`*Ffi`) are fixture inputs in app tests, so naming one is
not MDK evidence; calling MDK is. Audit tooling, not a test; it reads test
sources on purpose.

    python3 scripts/audit/subject-classify.py           # writes build/audit/subjects.csv
    python3 scripts/audit/subject-classify.py --merge   # also adds subject columns to inventory.csv
"""
import argparse
import collections
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftscan  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_TESTS_DIR = "whitenoise-iosTests"
DEFAULT_APP_DIRS = ("whitenoise-ios", "Shared", "NotificationServiceExtension")
DEFAULT_MDK_DIR = "Packages/MarmotKit"
DEFAULT_OUT = "build/audit/subjects.csv"
DEFAULT_INVENTORY = "build/audit/inventory.csv"
COLUMNS = ["suite", "test", "subject", "app_refs", "mdk_refs", "helper_refs"]
SUBJECTS = ("app", "mdk", "test-helper", "catalog", "platform")
MERGED_COLUMNS = ["subject", "subject_mix"]

CATALOG_TEXT = re.compile(r"\.xcstrings\b")
CATALOG_CODE = re.compile(r"\bBundle\b[^\n]*\b(forResource|forInfoDictionaryKey|builtInPlugInsURL|bundleURL|resourceURL)\b")
SWIFT_KEYWORDS = {
    "let", "var", "func", "struct", "class", "enum", "actor", "protocol", "extension", "typealias",
    "if", "else", "for", "in", "while", "repeat", "return", "self", "Self", "true", "false", "nil",
    "import", "case", "switch", "default", "guard", "defer", "throw", "throws", "try", "await", "async",
    "init", "deinit", "subscript",
}
CALL = re.compile(r"(?<![\w])(marmot\s*\.\s*)?(%s)\s*\(" % swiftscan.IDENTIFIER)
VALUE_TYPES = ("struct", "class", "enum", "actor")


def _member_declarations(masked, start, end, depth, parent):
    for decl in swiftscan.declarations(masked, start, end, depth):
        yield decl, parent
        if decl.keyword in swiftscan.TYPE_KEYWORDS and decl.body_start >= 0:
            yield from _member_declarations(masked, decl.body_start + 1, decl.body_end, depth + 1, decl)


def app_names(directories, foreign_members=frozenset()):
    """Types at any depth, top-level funcs/properties and every member an
    `extension` adds (API the app grafts onto MDK or platform types, which a
    test reaches without naming an app type), except members that MDK also
    declares (`label`, wrapper methods), since those name MDK as much as the
    app. Methods inside type bodies are not added: a test reaches them
    through the type name, and their names (`contains`, `append`) are too
    generic to be evidence."""
    names = set()
    for directory in directories:
        for path in swiftscan.swift_files(directory):
            masked = swiftscan.mask(path.read_text(encoding="utf-8"))
            for decl, parent in _member_declarations(masked, 0, None, 0, None):
                in_extension = parent is not None and parent.keyword == "extension"
                if decl.keyword in VALUE_TYPES or decl.keyword in ("protocol", "typealias"):
                    names.add(decl.name)
                elif decl.keyword in ("func", "let", "var") and (decl.depth == 0 or in_extension):
                    if decl.name not in foreign_members:
                        names.add(decl.name)
    return names - SWIFT_KEYWORDS


def member_names(directories):
    """Every func/property name declared at any depth under the directories."""
    names = set()
    for directory in directories:
        for path in swiftscan.swift_files(directory):
            masked = swiftscan.mask(path.read_text(encoding="utf-8"))
            names |= {d.name for d, _ in _member_declarations(masked, 0, None, 0, None)
                      if d.keyword in ("func", "let", "var")}
    return names - SWIFT_KEYWORDS


def func_names(directories):
    names = set()
    for directory in directories:
        for path in swiftscan.swift_files(directory):
            masked = swiftscan.mask(path.read_text(encoding="utf-8"))
            names |= {d.name for d, _ in _member_declarations(masked, 0, None, 0, None) if d.keyword == "func"}
    return names - SWIFT_KEYWORDS


def helper_names(masks, suite_names):
    """Test-support type names: every type declared in the test tree, at any
    depth, that is not itself a suite."""
    names = set()
    for masked in masks.values():
        names |= swiftscan.all_type_names(masked)
    return names - set(suite_names) - SWIFT_KEYWORDS


class HelperRange(collections.namedtuple("HelperRange", "masked start end shared")):
    """A helper declaration's source range. ``shared`` helpers (non-private
    top-level declarations and extension members) resolve from any file;
    others resolve only from their own file, since suites reuse names."""


def helper_bodies(masks, suite_names):
    """{name: [HelperRange]} for every non-test declaration in the test tree
    a test may name: helper funcs (signature and body), typealiases, stored
    properties and test-double types, at top level or directly in a type."""
    bodies = collections.defaultdict(list)
    for masked in masks.values():
        for decl, parent in _member_declarations(masked, 0, None, 0, None):
            if decl.name in suite_names or decl.keyword in ("extension", "protocol"):
                continue
            if decl.keyword == "func":
                xctest = parent is not None and "XCTestCase" in parent.inheritance
                if decl.has_attribute("Test") or (xctest and decl.name.startswith("test")):
                    continue
            in_extension = parent is not None and parent.keyword == "extension"
            if decl.depth > 0 and not in_extension and parent is not None and parent.name in suite_names:
                shared = False
            else:
                shared = (decl.depth == 0 or in_extension) and not (decl.modifiers & {"private", "fileprivate"})
            bodies[decl.name].append(HelperRange(masked, decl.start, decl.body_end, shared))
    return bodies


class Classifier:
    def __init__(self, app, mdk_funcs, helpers, helper_bodies=None, other_funcs=()):
        self.helper = set(helpers)
        self.app = set(app) - self.helper
        self.mdk_funcs = set(mdk_funcs)
        # Unqualified call names count as MDK only when neither the app nor
        # the test tree declares a func of that name.
        self.mdk_calls = self.mdk_funcs - self.app - set(other_funcs) - self.helper
        self.helper_bodies = helper_bodies or {}

    def _count(self, masked, start, end, counts):
        for identifier in swiftscan.identifiers(masked.code, start, end):
            if identifier in self.helper:
                counts["helper"] += 1
            elif identifier in self.app:
                counts["app"] += 1
        for match in CALL.finditer(masked.code, start, end):
            qualified, name = match.group(1), match.group(2)
            if name in self.mdk_calls or (qualified and name in self.mdk_funcs):
                counts["mdk"] += 1

    def resolve(self, identifier, masked):
        candidates = self.helper_bodies.get(identifier, ())
        local = [h for h in candidates if h.masked is masked]
        return local or [h for h in candidates if h.shared]

    def count(self, masked, start, end, header=""):
        counts = collections.Counter()
        self._count(masked, start, end, counts)
        for identifier in swiftscan.identifiers(header):
            if identifier in self.app:
                counts["app"] += 1
        seen = {(id(masked), start, end)}
        frontier = set(swiftscan.identifiers(masked.code, start, end)) | set(swiftscan.identifiers(header))
        # Helpers one level deep, then the aliases those helpers name: a
        # suite-private `typealias Placement = AppPlacement` is how a helper
        # signature reaches the app type.
        for level in range(2):
            next_frontier = set()
            for identifier in frontier:
                for helper in self.resolve(identifier, masked):
                    key = (id(helper.masked), helper.start, helper.end)
                    if key in seen or (helper.masked is masked and helper.start <= start and end <= helper.end):
                        continue
                    if level == 1 and not helper.masked.code.startswith("typealias", helper.start):
                        continue
                    seen.add(key)
                    self._count(helper.masked, helper.start, helper.end, counts)
                    next_frontier |= set(swiftscan.identifiers(helper.masked.code, helper.start, helper.end))
            frontier = next_frontier
        return counts

    def classify(self, masked, start, end, header=""):
        if CATALOG_TEXT.search(masked.text, start, end) or CATALOG_CODE.search(masked.code, start, end):
            return "catalog", 0, 0, 0
        counts = self.count(masked, start, end, header)
        app, mdk, helper = counts["app"], counts["mdk"], counts["helper"]
        if mdk > app:
            subject = "mdk"
        elif app:
            subject = "app"
        elif helper:
            subject = "test-helper"
        else:
            subject = "platform"
        return subject, app, mdk, helper


def classify_tests(suites, classifier):
    rows = []
    for suite in suites:
        for test in suite.tests:
            masked = next(part.masked for part in suite.parts if part.path == test.path)
            subject, app, mdk, helper = classifier.classify(masked, test.declaration.start, test.body_end,
                                                            test.declaration.header)
            rows.append({"suite": suite.name, "test": test.qualified_name, "subject": subject,
                         "app_refs": app, "mdk_refs": mdk, "helper_refs": helper})
    return rows


def rollup(rows):
    """Per-suite dominant subject and a compact mix, ties resolved app first."""
    by_suite = collections.defaultdict(collections.Counter)
    for row in rows:
        by_suite[row["suite"]][row["subject"]] += 1
    result = {}
    for suite, counts in by_suite.items():
        best = max(counts.values())
        subject = next(s for s in SUBJECTS if counts[s] == best)
        result[suite] = (subject, ";".join("%s:%d" % (s, counts[s]) for s in SUBJECTS if counts[s]))
    return result


def build_classifier(tests_dir, app_dirs, mdk_dir):
    suites, masks = swiftscan.collect_suites(tests_dir)
    suite_names = {s.name for s in suites}
    classifier = Classifier(app_names(app_dirs, member_names([mdk_dir])), func_names([mdk_dir]),
                            helper_names(masks, suite_names), helper_bodies(masks, suite_names),
                            func_names(app_dirs) | func_names([tests_dir]))
    return suites, classifier


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tests-dir", default=str(ROOT / DEFAULT_TESTS_DIR))
    parser.add_argument("--app-dir", action="append", default=None,
                        help="app source directory (repeatable; default: the three app targets)")
    parser.add_argument("--mdk-dir", default=str(ROOT / DEFAULT_MDK_DIR))
    parser.add_argument("--out", default=str(ROOT / DEFAULT_OUT))
    parser.add_argument("--inventory", default=str(ROOT / DEFAULT_INVENTORY))
    parser.add_argument("--merge", action="store_true", help="add subject/subject_mix columns to the inventory")
    args = parser.parse_args(argv)
    app_dirs = args.app_dir or [str(ROOT / d) for d in DEFAULT_APP_DIRS]

    suites, classifier = build_classifier(args.tests_dir, app_dirs, args.mdk_dir)
    rows = classify_tests(suites, classifier)
    swiftscan.write_csv(args.out, rows, COLUMNS)
    totals = collections.Counter(row["subject"] for row in rows)
    print("wrote %s (%d tests: %s)" % (args.out, len(rows), ", ".join("%s=%d" % kv for kv in sorted(totals.items()))))
    if args.merge:
        if not pathlib.Path(args.inventory).exists():
            print("no inventory at %s; run inventory.py first" % args.inventory, file=sys.stderr)
            return 1
        swiftscan.merge_columns(args.inventory, rollup(rows), MERGED_COLUMNS)
        print("merged subject columns into %s" % args.inventory)
    return 0


if __name__ == "__main__":
    sys.exit(main())
