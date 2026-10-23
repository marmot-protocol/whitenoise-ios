#!/usr/bin/env python3
"""Static inventory of the test suites: one CSV row per suite.

Counts call sites that matter for test cost (runtime construction, UI
hosting, sleeps, polling loops) inside each suite's brace ranges, including
``extension <Suite>`` blocks, plus the non-suite declarations the suite
reaches: file-private harness types, file-level helper funcs and properties,
and shared helpers in other files (same file first; cross-file only for
non-private declarations and extension members). Each helper declaration is
counted once per suite; ``helper_sites`` shows the share that came from
helpers so both numbers stay visible. Audit tooling, not a test; it reads
test sources on purpose.

    python3 scripts/audit/inventory.py                  # writes build/audit/inventory.csv
    python3 scripts/audit/inventory.py --emit-tier-lists
    python3 scripts/audit/inventory.py --rule testClient-requires-tag=runtime   # exits 1 on violations
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
DEFAULT_OUT = "build/audit/inventory.csv"

COUNT_COLUMNS = [
    "testClient_sites", "start_sites", "shutdown_sites", "app_state_test_sites",
    "ui_hosting", "image_renderer", "layout_if_needed", "sleep_sites", "poll_loops",
    "run_loop", "l10n_asserts", "xcstrings_reads",
]
COLUMNS = ["suite", "file", "line", "tests", "framework", "traits", "main_actor"] + COUNT_COLUMNS + ["helper_sites"]

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
# Inside an extension member such as `MarmotClient.testClient()` or
# `AppState.test()` the construction it wraps is what the call site already
# counted, so only nested call sites count there.
MEMBER_PATTERNS = dict(CODE_PATTERNS, **{
    "testClient_sites": r"MarmotClient\.testClient\(",
    "app_state_test_sites": r"AppState\.test\(",
})
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
HELPER_KEYWORDS = ("struct", "class", "enum", "actor", "func", "let", "var")

COLUMN_ALIASES = {
    "testClient": "testClient_sites", "start": "start_sites", "shutdown": "shutdown_sites",
    "app_state_test": "app_state_test_sites", "sleep": "sleep_sites",
}


class HelperDecl(collections.namedtuple("HelperDecl", "path masked start end member shared")):
    """A non-suite declaration a suite may reach. ``member`` marks extension
    members; ``shared`` ones (not private/fileprivate) resolve across files."""


def helper_index(masks, suite_names):
    index = collections.defaultdict(list)
    for path, masked in masks.items():
        for decl in swiftscan.declarations(masked):
            if decl.name in suite_names:
                continue
            if decl.keyword == "extension" and decl.body_start >= 0:
                for member in swiftscan.declarations(masked, decl.body_start + 1, decl.body_end, 1):
                    if member.keyword in ("func", "let", "var"):
                        index[member.name].append(HelperDecl(path, masked, member.start, member.body_end,
                                                             True, _is_shared(member)))
            elif decl.keyword in HELPER_KEYWORDS:
                index[decl.name].append(HelperDecl(path, masked, decl.start, decl.body_end, False, _is_shared(decl)))
    return index


def _is_shared(decl):
    return not (decl.modifiers & {"private", "fileprivate"})


def resolve_helper(index, name, path):
    candidates = index.get(name, ())
    local = [c for c in candidates if c.path == path]
    return local or [c for c in candidates if c.shared]


def reached_helpers(suite, index):
    """Helper declarations the suite references, transitively, each once."""
    seen, found = set(), []
    queue = [(part.path, part.masked, part.start, part.end) for part in suite.parts]
    while queue:
        path, masked, start, end = queue.pop()
        for name in sorted(set(swiftscan.identifiers(masked.code, start, end))):
            for helper in resolve_helper(index, name, path):
                key = (helper.path, helper.start)
                if key in seen:
                    continue
                seen.add(key)
                found.append(helper)
                queue.append((helper.path, helper.masked, helper.start, helper.end))
    return found


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
            for tag in trait[len(".tags("):-1].split(","):
                tags.add(tag.strip().lstrip(".").split(".")[-1])
    return tags


def count_l10n_asserts(code, start, end):
    count = 0
    for match in ASSERTION_CALL.finditer(code, start, end):
        close = swiftscan.match_close(code, match.end() - 1)
        if "L10n." in code[match.end():close]:
            count += 1
    return count


def _is_repeat_tail(code, at):
    """True when the `while` at ``at`` closes a `repeat { } while` loop."""
    before = code[:at].rstrip()
    if not before.endswith("}"):
        return False
    depth = 0
    for k in range(len(before) - 1, -1, -1):
        if code[k] == "}":
            depth += 1
        elif code[k] == "{":
            depth -= 1
            if depth == 0:
                return code[:k].rstrip().endswith("repeat")
    return False


def count_poll_loops(code, start, end):
    count = 0
    for match in LOOP_KEYWORD.finditer(code, start, end):
        if match.group(1) == "while" and _is_repeat_tail(code, match.start()):
            continue  # already counted at its `repeat`
        brace = code.find("{", match.end(), end)
        if brace < 0:
            continue
        close = swiftscan.match_close(code, brace)
        if POLL_BODY.search(code, brace, close):
            count += 1
    return count


def count_range(masked, start, end, patterns):
    counts = collections.Counter()
    for column, pattern in patterns.items():
        counts[column] += swiftscan.count_pattern(pattern, masked.code, start, end)
    for column, pattern in TEXT_PATTERNS.items():
        counts[column] += swiftscan.count_pattern(pattern, masked.text, start, end)
    counts["l10n_asserts"] += count_l10n_asserts(masked.code, start, end)
    counts["poll_loops"] += count_poll_loops(masked.code, start, end)
    return counts


def suite_row(suite, tests_dir, index):
    decl = suite.declaration
    row = {
        "suite": suite.name,
        "file": os.path.relpath(suite.path, tests_dir),
        "line": suite.line,
        "tests": len(suite.tests),
        "framework": suite.framework,
        "traits": ";".join(traits_of(decl)),
        "main_actor": int(decl.has_attribute("MainActor")),
    }
    own, via_helpers = collections.Counter(), collections.Counter()
    for part in suite.parts:
        own += count_range(part.masked, part.start, part.end, CODE_PATTERNS)
    for helper in reached_helpers(suite, index):
        via_helpers += count_range(helper.masked, helper.start, helper.end,
                                   MEMBER_PATTERNS if helper.member else CODE_PATTERNS)
    for column in COUNT_COLUMNS:
        row[column] = own[column] + via_helpers[column]
    row["helper_sites"] = ";".join("%s:%d" % (c, via_helpers[c]) for c in COUNT_COLUMNS if via_helpers[c])
    return row


def build_rows(tests_dir, warn=None):
    suites, masks = swiftscan.collect_suites(tests_dir, warn)
    index = helper_index(masks, {s.name for s in suites})
    return [suite_row(suite, tests_dir, index) for suite in suites]


def is_runtime_tier(row):
    return any(int(row[c]) > 0 for c in RUNTIME_COLUMNS) or "runtime" in tags_of(row["traits"].split(";"))


def is_ui_tier(row):
    tags = tags_of(row["traits"].split(";"))
    return any(int(row[c]) > 0 for c in UI_COLUMNS) or bool(tags & {"ui", "uiHosting"})


def tier_lists(rows, tests_dir_name):
    """Disjoint tier lists; a UI suite that also builds a runtime is runtime."""
    runtime = ["%s/%s" % (tests_dir_name, r["suite"]) for r in rows if is_runtime_tier(r)]
    ui = ["%s/%s" % (tests_dir_name, r["suite"]) for r in rows if is_ui_tier(r) and not is_runtime_tier(r)]
    return runtime, ui


RULE_RE = re.compile(r"^(?P<column>[A-Za-z_]+)-(?P<kind>requires-tag|requires-trait|max)=(?P<value>.+)$")


def parse_rule(rule):
    match = RULE_RE.match(rule)
    if not match:
        raise ValueError("rule must look like <column>-requires-tag=<tag>, "
                         "<column>-requires-trait=<trait> or <column>-max=<n>: %s" % rule)
    column = COLUMN_ALIASES.get(match.group("column"), match.group("column"))
    if column not in COUNT_COLUMNS + ["tests", "main_actor"]:
        raise ValueError("unknown inventory column in rule: %s" % rule)
    kind, value = match.group("kind"), match.group("value").strip().lstrip(".")
    if kind == "max":
        if not value.isdigit():
            raise ValueError("max rule needs an integer: %s" % rule)
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tests-dir", default=str(ROOT / DEFAULT_TESTS_DIR))
    parser.add_argument("--out", default=str(ROOT / DEFAULT_OUT))
    parser.add_argument("--rule", action="append", default=[],
                        help="check a rule and exit 1 on violations, e.g. testClient-requires-tag=runtime")
    parser.add_argument("--check", action="store_true", help="implied by --rule")
    parser.add_argument("--emit-tier-lists", action="store_true",
                        help="write tier-runtime.txt and tier-ui.txt next to the CSV")
    args = parser.parse_args(argv)

    try:
        rules = [parse_rule(rule) for rule in args.rule]
    except ValueError as error:
        parser.error(str(error))
    if args.check and not rules:
        parser.error("--check needs at least one --rule")
    rows = build_rows(args.tests_dir, warn=lambda message: print("warning: " + message, file=sys.stderr))
    swiftscan.write_csv(args.out, rows, COLUMNS)
    print("wrote %s (%d suites, %d tests)" % (args.out, len(rows), sum(r["tests"] for r in rows)))

    if args.emit_tier_lists:
        out_dir = pathlib.Path(args.out).parent
        runtime, ui = tier_lists(rows, pathlib.Path(args.tests_dir).name)
        for name, lines in (("tier-runtime.txt", runtime), ("tier-ui.txt", ui)):
            (out_dir / name).write_text("".join(line + "\n" for line in lines), encoding="utf-8")
            print("wrote %s (%d suites)" % (out_dir / name, len(lines)))

    if rules:
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
