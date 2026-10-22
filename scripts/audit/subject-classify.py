#!/usr/bin/env python3
"""Classify what each test actually exercises: app, mdk, test-helper, catalog or platform.

Builds three identifier sets (app types from the app sources, MDK types from
the MarmotKit package, test-support declarations from the test directory)
and labels each test body by the set it references most: app identifier
occurrences, test-support type occurrences, MDK func/method invocations (MDK
record types are fixture inputs in app tests, so only calls count), plus
whatever the non-test helper funcs, properties and typealiases it names
reference, one level deep. Ties go app > mdk > test-helper. Audit tooling,
not a test; it reads test sources on purpose.

    python3 scripts/audit/subject-classify.py           # writes build/audit/subjects.csv
    python3 scripts/audit/subject-classify.py --merge   # also adds `subject` to inventory.csv
"""
import argparse
import collections
import csv
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

CATALOG_TEXT = re.compile(r"\.xcstrings\b")
CATALOG_CODE = re.compile(r"\bBundle\b[^\n]*\b(forResource|forInfoDictionaryKey|builtInPlugInsURL|bundleURL|resourceURL)\b")


def declared_names(masked, include_members=False):
    """Type names at any depth plus top-level func/let/var names.

    With ``include_members`` the funcs and properties declared directly in
    top-level extensions are added too (that is how the test support layer
    adds ``MarmotClient.testClient`` and ``AppState.test``).
    """
    names = swiftscan.all_type_names(masked)
    for decl in swiftscan.declarations(masked):
        if decl.keyword in ("func", "let", "var", "typealias"):
            names.add(decl.name)
        elif include_members and decl.keyword == "extension" and decl.body_start >= 0:
            for member in swiftscan.declarations(masked, decl.body_start + 1, decl.body_end, 1):
                if member.keyword in ("func", "let", "var"):
                    names.add(member.name)
    return names


def names_in_dirs(directories, include_members=False):
    names = set()
    for directory in directories:
        for path in swiftscan.swift_files(directory):
            names |= declared_names(swiftscan.mask(path.read_text(encoding="utf-8")), include_members)
    return names


def func_names_in_dirs(directories):
    """Names of every func declared at any depth under the directories."""
    names = set()
    for directory in directories:
        for path in swiftscan.swift_files(directory):
            masked = swiftscan.mask(path.read_text(encoding="utf-8"))
            names |= {decl.name for decl in _all_funcs(masked, 0, None, 0)}
    return names


def helper_names(masks, suite_names):
    """Test-support type names: every type declared in the test tree, at any
    depth, that is not itself a suite. Helper *funcs* are not counted as
    references; what their bodies reference is attributed instead."""
    names = set()
    for masked in masks.values():
        names |= swiftscan.all_type_names(masked)
    return names - set(suite_names)


SWIFT_KEYWORDS = {
    "let", "var", "func", "struct", "class", "enum", "actor", "protocol", "extension", "typealias",
    "if", "else", "for", "in", "while", "repeat", "return", "self", "Self", "true", "false", "nil",
    "import", "case", "switch", "default", "guard", "defer", "throw", "throws", "try", "await", "async",
    "init", "deinit", "subscript",
}


def helper_bodies(masks, suite_names):
    """{name: [(masked, start, end)]} for every non-test member declaration
    in the test tree: funcs (signature and body), typealiases and stored
    properties at top level or directly inside a type. A test that reaches
    the app only through one of these is attributed what it references."""
    bodies = collections.defaultdict(list)
    for masked in masks.values():
        for decl, parent in _member_declarations(masked, 0, None, 0, None):
            if decl.keyword == "func":
                xctest = parent is not None and "XCTestCase" in parent.inheritance
                if decl.has_attribute("Test") or (xctest and decl.name.startswith("test")):
                    continue
            elif decl.keyword not in ("typealias", "let", "var"):
                continue
            shared = decl.depth == 0 or (parent is not None and parent.keyword == "extension")
            bodies[decl.name].append(HelperRange(masked, decl.start, decl.body_end, shared))
    return bodies


class HelperRange(collections.namedtuple("HelperRange", "masked start end shared")):
    """A helper declaration's source range. ``shared`` helpers (top-level
    funcs and extension members) resolve from any file; type members resolve
    only from their own file, since suites reuse names like `model`."""


def _member_declarations(masked, start, end, depth, parent):
    for decl in swiftscan.declarations(masked, start, end, depth):
        yield decl, parent
        if decl.keyword in swiftscan.TYPE_KEYWORDS and decl.body_start >= 0:
            yield from _member_declarations(masked, decl.body_start + 1, decl.body_end, depth + 1, decl)


def _all_funcs(masked, start, end, depth):
    for decl, _ in _member_declarations(masked, start, end, depth, None):
        if decl.keyword == "func":
            yield decl


CALL = re.compile(r"(?<![\w])(%s)\s*\(" % swiftscan.IDENTIFIER)


class Classifier:
    """Counts references per set and labels a body by the dominant one.

    ``app`` counts occurrences of app identifiers (types, top-level funcs).
    ``helper`` counts occurrences of test-support type names (doubles,
    harnesses, fixtures). ``mdk`` counts *invocations* of MarmotKit funcs and
    methods whose names the app does not also declare: MDK record types
    appear in app tests as fixture inputs, so naming one is not evidence the
    test exercises MDK, calling one is. A call to a non-test helper func is
    instrumental: it adds that helper's own references (one level deep)
    instead of counting as a reference itself.
    """

    def __init__(self, app_names, mdk_names, helper_names, helper_bodies=None, mdk_calls=()):
        # A name declared in several sets counts as the one closest to the
        # app: helper > app > mdk (helper names are local to the test tree).
        self.helper = set(helper_names) - SWIFT_KEYWORDS
        self.app = set(app_names) - self.helper - SWIFT_KEYWORDS
        self.mdk = set(mdk_names) - self.helper - self.app - SWIFT_KEYWORDS
        self.mdk_calls = set(mdk_calls) - self.helper - self.app - SWIFT_KEYWORDS
        self.helper_bodies = helper_bodies or {}

    def _count(self, masked, start, end, counts):
        for identifier in swiftscan.identifiers(masked.code, start, end):
            if identifier in self.helper:
                counts["helper"] += 1
            elif identifier in self.app:
                counts["app"] += 1
        for match in CALL.finditer(masked.code, start, end):
            if match.group(1) in self.mdk_calls:
                counts["mdk"] += 1

    def count(self, masked, start, end):
        counts = collections.Counter()
        self._count(masked, start, end, counts)
        seen = {(id(masked), start, end)}
        frontier = set(swiftscan.identifiers(masked.code, start, end))
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

    def resolve(self, identifier, masked):
        """Same-file helpers first; otherwise only shared (top-level) ones."""
        candidates = self.helper_bodies.get(identifier, ())
        local = [h for h in candidates if h.masked is masked]
        return local or [h for h in candidates if h.shared]

    def classify(self, masked, start, end):
        if CATALOG_TEXT.search(masked.text, start, end) or CATALOG_CODE.search(masked.code, start, end):
            return "catalog", 0, 0, 0
        counts = self.count(masked, start, end)
        app, mdk, helper = counts["app"], counts["mdk"], counts["helper"]
        if app == mdk == helper == 0:
            return "platform", 0, 0, 0
        best = max(app, mdk, helper)
        if app == best:
            subject = "app"
        elif mdk == best:
            subject = "mdk"
        else:
            subject = "test-helper"
        return subject, app, mdk, helper


def classify_tests(suites, classifier):
    rows = []
    for suite in suites:
        for test in suite.tests:
            masked = next(part.masked for part in suite.parts if part.path == test.path)
            subject, app, mdk, helper = classifier.classify(masked, test.body_start, test.body_end)
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
        mix = ";".join("%s:%d" % (s, counts[s]) for s in SUBJECTS if counts[s])
        result[suite] = (subject, mix)
    return result


def merge_into_inventory(inventory_path, rolled, columns):
    inventory_path = pathlib.Path(inventory_path)
    with inventory_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        fields = list(reader.fieldnames)
    for column in columns:
        if column not in fields:
            fields.append(column)
    for row in rows:
        values = rolled.get(row["suite"])
        for column, value in zip(columns, values if values else [""] * len(columns)):
            row[column] = value
    with inventory_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_csv(path, rows, columns):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


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

    suites, masks = swiftscan.collect_suites(args.tests_dir)
    suite_names = {s.name for s in suites}
    mdk_calls = func_names_in_dirs([args.mdk_dir]) - func_names_in_dirs(app_dirs)
    classifier = Classifier(names_in_dirs(app_dirs), names_in_dirs([args.mdk_dir]),
                            helper_names(masks, suite_names), helper_bodies(masks, suite_names), mdk_calls)
    rows = classify_tests(suites, classifier)
    write_csv(args.out, rows, COLUMNS)
    totals = collections.Counter(row["subject"] for row in rows)
    print("wrote %s (%d tests: %s)" % (args.out, len(rows), ", ".join("%s=%d" % kv for kv in sorted(totals.items()))))
    if args.merge:
        if not pathlib.Path(args.inventory).exists():
            print("no inventory at %s; run inventory.py first" % args.inventory, file=sys.stderr)
            return 1
        merge_into_inventory(args.inventory, rollup(rows), ["subject", "subject_mix"])
        print("merged subject columns into %s" % args.inventory)
    return 0


if __name__ == "__main__":
    sys.exit(main())
