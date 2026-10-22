#!/usr/bin/env python3
"""Flag tests whose assertions compare literals rather than behaviour.

Per-test assertion counts and literal-assertion flags. Audit tooling, not a
test; it reads test sources on purpose. The heuristics are textual and
conservative: a flag is a prompt to read the test, not a verdict. A flagged
assertion may be a deliberate persistence or security pin (a storage key, a
directory name) the ledger must keep. They cannot see tautologies that go
through a mock echoing its input back, or two expressions that are equal
only at runtime.

    python3 scripts/audit/assertion-heuristics.py           # writes build/audit/assertions.csv
    python3 scripts/audit/assertion-heuristics.py --merge   # also adds literal_assertion_flags to inventory.csv

Flags:
  zero-assertions      no #expect/#require (parenthesised or trailing-closure form),
                       XCTAssert*/XCTFail/XCTUnwrap or Issue.record, no call to a
                       helper func that asserts, and not the "must not throw" idiom
                       (a throwing test whose body `try`s the code under test)
  memberwise-roundtrip let s = S(a: 1); #expect(s.a == 1)
  constant-literal     #expect(Type.member == <literal>) or Type.a == Other.b where
                       the members are `static let` / stored `static var` in the app
                       sources (shape-only with --no-app-dirs)
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
DEFAULT_OUT = "build/audit/assertions.csv"
DEFAULT_INVENTORY = "build/audit/inventory.csv"
COLUMNS = ["suite", "test", "assertions", "flags"]
MERGED_COLUMN = "literal_assertion_flags"
FLAGS = ("zero-assertions", "memberwise-roundtrip", "constant-literal")

ASSERTION = re.compile(r"#expect\s*[({]|#require\s*[({]|\bXCTAssert\w*\(|\bXCTFail\(|\bXCTUnwrap\(|\bIssue\.record\(")
EXPECT = re.compile(r"#expect\(|\bXCTAssertEqual\(|\bXCTAssertTrue\(|\bXCTAssert\(")
TRY = re.compile(r"\btry\b(?![?!])")
IDENT = swiftscan.IDENTIFIER
LITERAL = r'(?:-?\d[\d_]*(?:\.\d+)?|"[^"]*"|true|false|nil)'
LET_INIT = re.compile(r"\b(?:let|var)\s+(%s)\s*=\s*(?:try\s+)?([A-Z]%s)\s*\(" % (IDENT, IDENT))
CONSTANT_REF = re.compile(r"^(?:[A-Z]%s\.)+(%s)$" % (IDENT, IDENT))


def strip_literal(value):
    return value.replace("_", "")


def comparison_sides(name, raw):
    """(left, right) of an equality assertion, or None."""
    parts = [p.strip() for p in swiftscan._split_top_level(raw, ",")]
    if name.startswith("XCTAssertEqual"):
        return (parts[0], parts[1]) if len(parts) >= 2 else None
    sides = _split_operator(parts[0] if parts else "", "==")
    return (sides[0].strip(), sides[1].strip()) if sides else None


def _split_operator(expression, operator):
    depth = 0
    in_string = False
    i = 0
    while i < len(expression):
        c = expression[i]
        if c == '"' and (i == 0 or expression[i - 1] != "\\"):
            in_string = not in_string
        elif not in_string:
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif depth == 0 and expression.startswith(operator, i) and not expression.startswith(operator + "=", i):
                if i > 0 and expression[i - 1] in "<>!=":
                    i += 1
                    continue
                return expression[:i], expression[i + len(operator):]
        i += 1
    return None


def analyse_body(masked, test, helper_assertions=frozenset(), static_constants=None):
    """Return (assertion_count, Counter of flags) for one test function."""
    code, text = masked.code, masked.text
    start, end = test.body_start, test.body_end
    flags = collections.Counter()
    count = sum(1 for _ in ASSERTION.finditer(code, start, end))
    for name in helper_assertions:
        count += swiftscan.count_pattern(r"(?<![\w.])%s\(" % re.escape(name), code, start, end)
    if count == 0 and not _must_not_throw(masked, test):
        flags["zero-assertions"] += 1

    body = text[start:end]
    inits = _memberwise_inits(body)
    for match in EXPECT.finditer(code, start, end):
        close = swiftscan.match_close(code, match.end() - 1)
        sides = comparison_sides(match.group(0), text[match.end():close])
        if sides is None:
            continue
        left, right = sides
        if _memberwise_roundtrip(left, right, inits):
            flags["memberwise-roundtrip"] += 1
        if _constant_literal(left, right, static_constants):
            flags["constant-literal"] += 1
    return count, flags


def _must_not_throw(masked, test):
    """A throwing test whose body only `try`s the code under test asserts
    that it does not throw."""
    signature = masked.code[test.start:test.body_start]
    return "throws" in signature and TRY.search(masked.code, test.body_start, test.body_end) is not None


def _is_literal(value):
    return re.fullmatch(LITERAL, value) is not None


def _memberwise_inits(body):
    """{variable: {label: literal}} for `let s = S(a: 1, b: "x")` bindings."""
    inits = {}
    for match in LET_INIT.finditer(body):
        open_paren = match.end() - 1
        close = swiftscan.match_close(body, open_paren)
        arguments = {}
        for argument in swiftscan._split_top_level(body[open_paren + 1:close], ","):
            label_value = argument.split(":", 1)
            if len(label_value) != 2:
                continue
            label, value = label_value[0].strip(), label_value[1].strip()
            if re.fullmatch(IDENT, label) and _is_literal(value):
                arguments[label] = strip_literal(value)
        if arguments:
            inits[match.group(1)] = arguments
    return inits


def _memberwise_roundtrip(left, right, inits):
    for access, literal in ((left, right), (right, left)):
        match = re.fullmatch(r"(%s)\.(%s)" % (IDENT, IDENT), access)
        if match and _is_literal(literal):
            variable, label = match.groups()
            if inits.get(variable, {}).get(label) == strip_literal(literal):
                return True
    return False


def _is_constant(reference, static_constants):
    match = CONSTANT_REF.fullmatch(reference)
    if not match:
        return False
    owner = reference.rsplit(".", 2)[-2]
    return static_constants is None or (owner, match.group(1)) in static_constants


def _constant_literal(left, right, static_constants):
    if _is_constant(left, static_constants) and (_is_literal(right) or _is_constant(right, static_constants)):
        return True
    return _is_literal(left) and _is_constant(right, static_constants)


def static_constants_in(directories):
    """{(TypeName, member)} for every `static let` and stored `static var`."""
    constants = set()
    for directory in directories:
        for path in swiftscan.swift_files(directory):
            _collect_static(swiftscan.mask(path.read_text(encoding="utf-8")), 0, None, 0, constants)
    return constants


def _collect_static(masked, start, end, depth, constants):
    for decl in swiftscan.declarations(masked, start, end, depth):
        if decl.keyword in swiftscan.TYPE_KEYWORDS and decl.body_start >= 0:
            body_start, body_end = decl.body_start + 1, decl.body_end
            for member in swiftscan.declarations(masked, body_start, body_end, depth + 1):
                stored = member.keyword == "let" or (member.keyword == "var" and member.body_start < 0)
                if stored and "static" in member.modifiers:
                    constants.add((decl.name, member.name))
            _collect_static(masked, body_start, body_end, depth + 1, constants)


def asserting_helpers(masks):
    """Names of non-test funcs anywhere in the test tree whose body asserts."""
    names = set()
    for masked in masks.values():
        for decl in _all_funcs(masked, 0, None, 0):
            if decl.has_attribute("Test") or decl.name.startswith("test") or decl.body_start < 0:
                continue
            if ASSERTION.search(masked.code, decl.body_start, decl.body_end):
                names.add(decl.name)
    return names


def _all_funcs(masked, start, end, depth):
    for decl in swiftscan.declarations(masked, start, end, depth):
        if decl.keyword == "func":
            yield decl
        elif decl.keyword in swiftscan.TYPE_KEYWORDS and decl.body_start >= 0:
            yield from _all_funcs(masked, decl.body_start + 1, decl.body_end, depth + 1)


def analyse_suites(suites, masks, static_constants=None):
    helpers = asserting_helpers(masks)
    rows = []
    for suite in suites:
        for test in suite.tests:
            count, flags = analyse_body(masks[test.path], test, helpers, static_constants)
            rows.append({"suite": suite.name, "test": test.qualified_name, "assertions": count,
                         "flags": ";".join("%s:%d" % (f, flags[f]) for f in FLAGS if flags[f])})
    return rows


def rollup(rows):
    by_suite = collections.defaultdict(collections.Counter)
    for row in rows:
        for item in filter(None, row["flags"].split(";")):
            flag, count = item.rsplit(":", 1)
            by_suite[row["suite"]][flag] += int(count)
    return {suite: (";".join("%s:%d" % (f, c[f]) for f in FLAGS if c[f]),) for suite, c in by_suite.items()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tests-dir", default=str(ROOT / DEFAULT_TESTS_DIR))
    parser.add_argument("--app-dir", action="append", default=None,
                        help="app source directory used to confirm static constants (repeatable)")
    parser.add_argument("--no-app-dirs", action="store_true", help="flag constant-literal by shape only")
    parser.add_argument("--out", default=str(ROOT / DEFAULT_OUT))
    parser.add_argument("--inventory", default=str(ROOT / DEFAULT_INVENTORY))
    parser.add_argument("--merge", action="store_true", help="add %s to the inventory" % MERGED_COLUMN)
    args = parser.parse_args(argv)

    static_constants = None
    if not args.no_app_dirs:
        app_dirs = args.app_dir or [str(ROOT / d) for d in DEFAULT_APP_DIRS if (ROOT / d).exists()]
        static_constants = static_constants_in(app_dirs)
    suites, masks = swiftscan.collect_suites(args.tests_dir)
    rows = analyse_suites(suites, masks, static_constants)
    swiftscan.write_csv(args.out, rows, COLUMNS)
    totals = collections.Counter()
    for row in rows:
        for item in filter(None, row["flags"].split(";")):
            flag, count = item.rsplit(":", 1)
            totals[flag] += int(count)
    print("wrote %s (%d tests; %s)" % (args.out, len(rows),
                                       ", ".join("%s=%d" % (f, totals[f]) for f in FLAGS if totals[f]) or "no flags"))
    if args.merge:
        if not pathlib.Path(args.inventory).exists():
            print("no inventory at %s; run inventory.py first" % args.inventory, file=sys.stderr)
            return 1
        swiftscan.merge_columns(args.inventory, rollup(rows), [MERGED_COLUMN])
        print("merged %s into %s" % (MERGED_COLUMN, args.inventory))
    return 0


if __name__ == "__main__":
    sys.exit(main())
