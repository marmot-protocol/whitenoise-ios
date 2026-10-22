#!/usr/bin/env python3
"""Flag tests whose assertions cannot fail or do not test the app.

Per-test assertion counts and tautology flags. Audit tooling, not a test; it
reads test sources on purpose. Heuristics are textual and conservative: a
flag is a prompt to read the test, not a verdict.

    python3 scripts/audit/assertion-heuristics.py           # writes build/audit/assertions.csv
    python3 scripts/audit/assertion-heuristics.py --merge   # also adds tautology_flags to inventory.csv

Flags:
  zero-assertions      no #expect/#require/XCTAssert*/XCTFail/Issue.record (calls to
                       same-file helper funcs that assert count as assertions)
  self-compare         #expect(x == x) or XCTAssertEqual(x, x)
  literal-roundtrip    #expect(v == 1) where `let v = 1` in the same body (a `var`
                       counts only if nothing else in the body mentions it)
  require-then-nonnil  #expect(x != nil) after `let x = try #require(...)`
  l10n-identity        #expect(L10n.string("Key") == "Key")
  memberwise-roundtrip let s = S(a: 1); #expect(s.a == 1)
  constant-literal     #expect(Type.member == <literal>) where member is a static
                       let/var in the app sources (shape-only when no app sources)
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
DEFAULT_OUT = "build/audit/assertions.csv"
DEFAULT_INVENTORY = "build/audit/inventory.csv"
COLUMNS = ["suite", "test", "assertions", "flags"]
FLAGS = ("zero-assertions", "self-compare", "literal-roundtrip", "require-then-nonnil",
         "l10n-identity", "memberwise-roundtrip", "constant-literal")

ASSERTION = re.compile(r"#expect\(|#require\(|\bXCTAssert\w*\(|\bXCTFail\(|\bXCTUnwrap\(|\bIssue\.record\(")
EXPECT = re.compile(r"#expect\(|\bXCTAssertEqual\(|\bXCTAssertTrue\(|\bXCTAssert\(")
IDENT = swiftscan.IDENTIFIER
LITERAL = r'(?:-?\d[\d_]*(?:\.\d+)?|"[^"]*"|true|false|nil)'
LET_LITERAL = re.compile(r"\b(let|var)\s+(%s)\s*(?::\s*[\w.<>?\[\]]+)?\s*=\s*(%s)\s*$" % (IDENT, LITERAL), re.M)
LET_REQUIRE = re.compile(r"\b(?:let|var)\s+(%s)\s*=\s*try\s+#require\(" % IDENT)
LET_INIT = re.compile(r"\b(?:let|var)\s+(%s)\s*=\s*(?:try\s+)?([A-Z]%s)\s*\(" % (IDENT, IDENT))
L10N_CALL = re.compile(r'L10n\.(?:string|formatted)\(\s*("[^"]*")')
STATIC_CONSTANT = re.compile(r"\bstatic\s+(?:let|var)\s+(%s)" % IDENT)
CONSTANT_REF = re.compile(r"^(?:[A-Z]%s\.)+(%s)$" % (IDENT, IDENT))


def strip_literal(value):
    return value.replace("_", "")


class _Context:
    """One test body in both views, with the raw-string version of each
    assertion argument so literals can be compared."""

    def __init__(self, masked, start, end):
        self.masked = masked
        self.start, self.end = start, end
        self.code = masked.code
        self.text = masked.text

    def assertions(self):
        for match in ASSERTION.finditer(self.code, self.start, self.end):
            close = swiftscan.match_close(self.code, match.end() - 1)
            yield match.group(0), match.end(), close

    def expect_args(self):
        for match in EXPECT.finditer(self.code, self.start, self.end):
            close = swiftscan.match_close(self.code, match.end() - 1)
            raw = self.text[match.end():close]
            yield match.group(0), raw


def comparison_sides(name, raw):
    """(left, right, operator) of an equality assertion, or None."""
    parts = [p.strip() for p in swiftscan._split_top_level(raw, ",")]
    if name.startswith("XCTAssertEqual"):
        if len(parts) >= 2:
            return parts[0], parts[1], "=="
        return None
    expression = parts[0] if parts else ""
    for operator in ("==", "!="):
        sides = _split_operator(expression, operator)
        if sides:
            return sides[0].strip(), sides[1].strip(), operator
    return None


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


def analyse_body(masked, start, end, helper_assertions=frozenset(), static_constants=None):
    """Return (assertion_count, Counter of flags) for one test body."""
    context = _Context(masked, start, end)
    flags = collections.Counter()
    count = sum(1 for _ in context.assertions())
    if helper_assertions:
        for name in helper_assertions:
            count += swiftscan.count_pattern(r"(?<![\w.])%s\(" % re.escape(name), context.code, start, end)
    if count == 0:
        flags["zero-assertions"] += 1

    body = context.text[start:end]
    literal_bindings = {}
    for keyword, name, value in LET_LITERAL.findall(body):
        # A `var` the body touches again (counters bumped in closures, for
        # example) is not a round-trip: only the declaration and the
        # assertion may mention it.
        if keyword == "var" and len(re.findall(r"(?<![\w.])%s\b" % re.escape(name), body)) > 2:
            continue
        literal_bindings[name] = strip_literal(value)
    required = set(LET_REQUIRE.findall(body))
    inits = _memberwise_inits(body)

    for name, raw in context.expect_args():
        sides = comparison_sides(name, raw)
        if sides is None:
            continue
        left, right, operator = sides
        if operator == "==" and left == right and left:
            flags["self-compare"] += 1
        if operator == "==" and _literal_roundtrip(left, right, literal_bindings):
            flags["literal-roundtrip"] += 1
        if operator == "!=" and right == "nil" and left in required:
            flags["require-then-nonnil"] += 1
        if operator == "==" and _l10n_identity(left, right):
            flags["l10n-identity"] += 1
        if operator == "==" and _memberwise_roundtrip(left, right, inits):
            flags["memberwise-roundtrip"] += 1
        if operator == "==" and _constant_literal(left, right, static_constants):
            flags["constant-literal"] += 1
    return count, flags


def _is_literal(value):
    return re.fullmatch(LITERAL, value) is not None


def _literal_roundtrip(left, right, bindings):
    for variable, literal in ((left, right), (right, left)):
        if variable in bindings and _is_literal(literal) and bindings[variable] == strip_literal(literal):
            return True
    return False


def _l10n_identity(left, right):
    for call, literal in ((left, right), (right, left)):
        match = L10N_CALL.fullmatch(call) or L10N_CALL.match(call)
        if match and literal == match.group(1):
            return True
    return False


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


def _constant_literal(left, right, static_constants):
    for reference, literal in ((left, right), (right, left)):
        match = CONSTANT_REF.fullmatch(reference)
        if not match or not _is_literal(literal):
            continue
        owner = reference.rsplit(".", 2)[-2]
        if static_constants is None or (owner, match.group(1)) in static_constants:
            return True
    return False


def static_constants_in(directories):
    """{(TypeName, member)} for every `static let/var` in the given sources."""
    constants = set()
    for directory in directories:
        for path in swiftscan.swift_files(directory):
            masked = swiftscan.mask(path.read_text(encoding="utf-8"))
            _collect_static(masked, 0, None, 0, constants)
    return constants


def _collect_static(masked, start, end, depth, constants):
    for decl in swiftscan.declarations(masked, start, end, depth):
        if decl.keyword in swiftscan.TYPE_KEYWORDS and decl.body_start >= 0:
            body_start, body_end = decl.body_start + 1, decl.body_end
            for member in swiftscan.declarations(masked, body_start, body_end, depth + 1):
                if member.keyword in ("let", "var") and "static" in member.modifiers:
                    constants.add((decl.name, member.name))
            _collect_static(masked, body_start, body_end, depth + 1, constants)


def asserting_helpers(masked):
    """Names of non-test funcs in a file whose body contains an assertion."""
    names = set()
    for decl in _all_funcs(masked, 0, None, 0):
        if decl.has_attribute("Test") or decl.name.startswith("test"):
            continue
        if decl.body_start >= 0 and ASSERTION.search(masked.code, decl.body_start, decl.body_end):
            names.add(decl.name)
    return names


def _all_funcs(masked, start, end, depth):
    for decl in swiftscan.declarations(masked, start, end, depth):
        if decl.keyword == "func":
            yield decl
        elif decl.keyword in swiftscan.TYPE_KEYWORDS and decl.body_start >= 0:
            yield from _all_funcs(masked, decl.body_start + 1, decl.body_end, depth + 1)


def analyse_suites(suites, masks, static_constants=None):
    helpers = {path: asserting_helpers(masked) for path, masked in masks.items()}
    rows = []
    for suite in suites:
        for test in suite.tests:
            masked = masks[test.path]
            count, flags = analyse_body(masked, test.body_start, test.body_end,
                                        helpers.get(test.path, frozenset()), static_constants)
            rows.append({"suite": suite.name, "test": test.qualified_name, "assertions": count,
                         "flags": ";".join("%s:%d" % (f, flags[f]) for f in FLAGS if flags[f])})
    return rows


def rollup(rows):
    by_suite = collections.defaultdict(collections.Counter)
    for row in rows:
        for item in filter(None, row["flags"].split(";")):
            flag, count = item.rsplit(":", 1)
            by_suite[row["suite"]][flag] += int(count)
    return {suite: ";".join("%s:%d" % (f, c[f]) for f in FLAGS if c[f]) for suite, c in by_suite.items()}


def merge_into_inventory(inventory_path, rolled):
    inventory_path = pathlib.Path(inventory_path)
    with inventory_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        fields = list(reader.fieldnames)
    if "tautology_flags" not in fields:
        fields.append("tautology_flags")
    for row in rows:
        row["tautology_flags"] = rolled.get(row["suite"], "")
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
                        help="app source directory used to confirm static constants (repeatable)")
    parser.add_argument("--no-app-dirs", action="store_true", help="flag constant-literal by shape only")
    parser.add_argument("--out", default=str(ROOT / DEFAULT_OUT))
    parser.add_argument("--inventory", default=str(ROOT / DEFAULT_INVENTORY))
    parser.add_argument("--merge", action="store_true", help="add tautology_flags to the inventory")
    args = parser.parse_args(argv)

    static_constants = None
    if not args.no_app_dirs:
        app_dirs = args.app_dir or [str(ROOT / d) for d in DEFAULT_APP_DIRS if (ROOT / d).exists()]
        static_constants = static_constants_in(app_dirs)
    suites, masks = swiftscan.collect_suites(args.tests_dir)
    rows = analyse_suites(suites, masks, static_constants)
    write_csv(args.out, rows, COLUMNS)
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
        merge_into_inventory(args.inventory, rollup(rows))
        print("merged tautology_flags into %s" % args.inventory)
    return 0


if __name__ == "__main__":
    sys.exit(main())
