#!/usr/bin/env python3
"""Static inventory of the test suites: one CSV row per suite.

Counts call sites that matter for test cost (runtime construction, UI
hosting, sleeps, polling loops) inside each suite's brace ranges, including
any ``extension <Suite>`` blocks in the test directory. Audit tooling, not a
test; it reads test sources on purpose.

    python3 scripts/audit/inventory.py                  # writes build/audit/inventory.csv
    python3 scripts/audit/inventory.py --emit-tier-lists
    python3 scripts/audit/inventory.py --check --rule testClient-requires-tag=runtime
"""
import argparse
import csv
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftscan  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_TESTS_DIR = "whitenoise-iosTests"
DEFAULT_OUT = "build/audit/inventory.csv"

COLUMNS = [
    "suite", "file", "line", "tests", "framework", "traits", "main_actor",
    "testClient_sites", "start_sites", "shutdown_sites", "app_state_test_sites",
    "ui_hosting", "image_renderer", "layout_if_needed", "sleep_sites", "poll_loops",
    "run_loop", "l10n_asserts", "xcstrings_reads",
]

# Patterns counted on the code view (comments and string contents blanked).
CODE_PATTERNS = {
    "testClient_sites": r"MarmotClient\.testClient\(|MarmotClient\(\s*rootPath",
    "start_sites": r"\bstartRuntime\(|\bbootstrap\(\)|\bmarmot\.start\b",
    "shutdown_sites": r"\bshutdownAndClose\b",
    "app_state_test_sites": r"AppState\.test\(|AppState\(\s*client:",
    "ui_hosting": r"\bUIHostingController\b|\bUIWindow\b|\bmakeKeyAndVisible\b",
    "image_renderer": r"\bImageRenderer\b",
    "layout_if_needed": r"\blayoutIfNeeded\b",
    "sleep_sites": r"\bTask\.sleep\b",
    "run_loop": r"\bRunLoop\.\w+\.run\b",
}
# Counted on the text view (comments blanked, strings kept): resource paths
# live inside string literals.
TEXT_PATTERNS = {
    "xcstrings_reads": r"\.xcstrings\b",
}
ASSERTION_CALL = re.compile(r"#expect\(|#require\(|XCTAssert\w*\(")
# Not the `for:` argument label of Task.sleep(for:).
LOOP_KEYWORD = re.compile(r"(?<![\w.])(for|while|repeat)\b(?!\s*:)")
POLL_BODY = re.compile(r"\bTask\.yield\(|\bTask\.sleep\b")
RUNTIME_COLUMNS = ("testClient_sites", "start_sites", "app_state_test_sites")
UI_COLUMNS = ("ui_hosting", "image_renderer", "layout_if_needed")

COLUMN_ALIASES = {
    "testClient": "testClient_sites", "start": "start_sites", "shutdown": "shutdown_sites",
    "app_state_test": "app_state_test_sites", "sleep": "sleep_sites",
}


def traits_of(decl):
    """Compact ``.trait(args)`` strings from the ``@Suite(...)`` attribute."""
    attribute = decl.attribute("Suite")
    if attribute is None:
        return []
    traits = []
    for argument in swiftscan._split_top_level(attribute.arguments, ","):
        argument = re.sub(r"\s+", "", argument)
        if argument.startswith("."):
            traits.append(argument)
    return traits


def tags_of(traits):
    tags = set()
    for trait in traits:
        if trait.startswith(".tags("):
            inner = trait[len(".tags("):-1]
            for tag in inner.split(","):
                tags.add(tag.strip().lstrip(".").split(".")[-1])
    return tags


def count_l10n_asserts(code, start, end):
    count = 0
    for match in ASSERTION_CALL.finditer(code, start, end):
        close = swiftscan.match_close(code, match.end() - 1)
        if "L10n." in code[match.end():close]:
            count += 1
    return count


def count_poll_loops(code, start, end):
    count = 0
    for match in LOOP_KEYWORD.finditer(code, start, end):
        brace = code.find("{", match.end(), end)
        if brace < 0:
            continue
        # The loop header must not cross a statement boundary.
        if "\n" in code[match.end():brace].strip("\n ") and ";" in code[match.end():brace]:
            continue
        close = swiftscan.match_close(code, brace)
        if POLL_BODY.search(code, brace, close):
            count += 1
    return count


def suite_row(suite, tests_dir):
    decl = suite.declaration
    traits = traits_of(decl)
    row = {
        "suite": suite.name,
        "file": os.path.relpath(suite.path, tests_dir),
        "line": suite.line,
        "tests": len(suite.tests),
        "framework": suite.framework,
        "traits": ";".join(traits),
        "main_actor": int(decl.has_attribute("MainActor")),
    }
    for column in list(CODE_PATTERNS) + list(TEXT_PATTERNS) + ["l10n_asserts", "poll_loops"]:
        row[column] = 0
    for part in suite.parts:
        code, text = part.masked.code, part.masked.text
        start, end = part.start, part.end
        for column, pattern in CODE_PATTERNS.items():
            row[column] += swiftscan.count_pattern(pattern, code, start, end)
        for column, pattern in TEXT_PATTERNS.items():
            row[column] += swiftscan.count_pattern(pattern, text, start, end)
        row["l10n_asserts"] += count_l10n_asserts(code, start, end)
        row["poll_loops"] += count_poll_loops(code, start, end)
    return row


def build_rows(tests_dir, warn=None):
    suites, _ = swiftscan.collect_suites(tests_dir, warn)
    return [suite_row(suite, tests_dir) for suite in suites]


def is_runtime_tier(row):
    return any(int(row[c]) > 0 for c in RUNTIME_COLUMNS) or "runtime" in tags_of(row["traits"].split(";"))


def is_ui_tier(row):
    return any(int(row[c]) > 0 for c in UI_COLUMNS) or "ui" in tags_of(row["traits"].split(";"))


def tier_lists(rows, tests_dir_name):
    """Disjoint tier lists; a UI suite that also builds a runtime is runtime."""
    runtime = ["%s/%s" % (tests_dir_name, r["suite"]) for r in rows if is_runtime_tier(r)]
    ui = ["%s/%s" % (tests_dir_name, r["suite"]) for r in rows if is_ui_tier(r) and not is_runtime_tier(r)]
    return runtime, ui


def resolve_column(name):
    column = COLUMN_ALIASES.get(name, name)
    if column not in COLUMNS:
        raise ValueError("unknown inventory column: %s" % name)
    return column


RULE_RE = re.compile(r"^(?P<column>[A-Za-z_]+)-(?P<kind>requires-tag|requires-trait|max)=(?P<value>.+)$")


def parse_rule(rule):
    match = RULE_RE.match(rule)
    if not match:
        raise ValueError("rule must look like <column>-requires-tag=<tag>, "
                         "<column>-requires-trait=<trait> or <column>-max=<n>: %s" % rule)
    column = resolve_column(match.group("column"))
    kind, value = match.group("kind"), match.group("value").strip().lstrip(".")
    if kind == "max":
        value = int(value)
    return column, kind, value


def check_rules(rows, rules):
    """Return violation strings for the parsed rules."""
    violations = []
    for row in rows:
        traits = row["traits"].split(";") if row["traits"] else []
        trait_names = {t.lstrip(".").split("(")[0] for t in traits}
        tags = tags_of(traits)
        for column, kind, value in rules:
            count = int(row[column])
            if kind == "max":
                if count > value:
                    violations.append("%s: %s=%d exceeds %d" % (row["suite"], column, count, value))
            elif count > 0 and kind == "requires-tag" and value not in tags:
                violations.append("%s: %s=%d but suite lacks .tags(.%s)" % (row["suite"], column, count, value))
            elif count > 0 and kind == "requires-trait" and value not in trait_names:
                violations.append("%s: %s=%d but suite lacks .%s" % (row["suite"], column, count, value))
    return violations


def write_csv(path, rows, columns):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in columns})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tests-dir", default=str(ROOT / DEFAULT_TESTS_DIR))
    parser.add_argument("--out", default=str(ROOT / DEFAULT_OUT))
    parser.add_argument("--check", action="store_true", help="exit non-zero when a --rule is violated")
    parser.add_argument("--rule", action="append", default=[], help="e.g. testClient-requires-tag=runtime")
    parser.add_argument("--emit-tier-lists", action="store_true",
                        help="write tier-runtime.txt and tier-ui.txt next to the CSV")
    args = parser.parse_args(argv)

    rules = [parse_rule(rule) for rule in args.rule]
    if args.check and not rules:
        parser.error("--check needs at least one --rule")
    rows = build_rows(args.tests_dir, warn=lambda message: print("warning: " + message, file=sys.stderr))
    write_csv(args.out, rows, COLUMNS)
    print("wrote %s (%d suites, %d tests)" % (args.out, len(rows), sum(r["tests"] for r in rows)))

    if args.emit_tier_lists:
        out_dir = pathlib.Path(args.out).parent
        runtime, ui = tier_lists(rows, pathlib.Path(args.tests_dir).name)
        for name, lines in (("tier-runtime.txt", runtime), ("tier-ui.txt", ui)):
            (out_dir / name).write_text("".join(line + "\n" for line in lines), encoding="utf-8")
            print("wrote %s (%d suites)" % (out_dir / name, len(lines)))

    if args.check:
        violations = check_rules(rows, rules)
        for violation in violations:
            print(violation)
        if violations:
            print("%d violation(s)" % len(violations), file=sys.stderr)
            return 1
        print("all rules satisfied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
