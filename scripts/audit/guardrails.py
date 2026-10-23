"""Test-suite guardrails behind ``inventory.py --check``.

Fixed rules, each keyed by suite and counted:

- ``runtime-tag``: a Swift Testing test that opens or starts a Marmot runtime
  (``MarmotClient.testClient(``, ``MarmotClient(rootPath:``,
  ``withTestClient``, ``OwnedTestClient(``, ``TestRuntimeScope.own(``,
  ``bootstrap()``, ``startRuntime(``, ``marmot.start``), directly or through a
  helper it reaches, carries ``.tags(.runtime)`` on the test, an enclosing
  nested suite or its suite. Suite-wide code (stored properties, ``init``)
  needs the suite tag. Count: offending tests.
- ``ui-tag``: the same for ``UIWindow``/``UIHostingController`` and
  ``.tags(.uiHosting)``. ``ImageRenderer`` renders offscreen and does not count.
  XCTest classes cannot be tagged, so for both rules an XCTest class must be
  listed in the PR test plan's ``skippedTests`` instead.
- ``sleep``: no ``Task.sleep`` in the suite or in a helper it reaches, except
  the named bounded-wait helpers in ``TestSupport/`` (``SLEEP_EXEMPT``).
  Count: sleep sites.
- ``unowned-runtime``: a direct ``MarmotClient.testClient(`` or
  ``MarmotClient(rootPath:`` outside ``TestSupport/`` sits inside
  ``TestRuntimeScope.own(`` / ``closing(``, or binds a name the enclosing
  declaration passes to one of them. Otherwise use ``withTestClient`` or
  ``OwnedTestClient``. Count: distinct site lines.
- ``timelimit-gate``: ``.timeLimit`` and ``.marmotRuntimeConcurrencyLimit``
  never apply to the same test, since the limit would count queue time behind
  the gate. Count: offending tests.
- ``pr-plan``: ``TestPlans/PR.xctestplan`` skips exactly the tagged Swift
  Testing suites and tests (see ``tagged_skips``) plus XCTest classes;
  ``inventory.py --write-pr-plan`` regenerates the list.

Known violations live in a baseline file, ``<rule> <Suite> <count>`` per line.
A suite at its baseline count prints as baselined; a new violation, a higher
count, a lower count and a line whose violation is gone all fail, so the
baseline is tightened in the change that fixes a suite
(``inventory.py --write-baseline`` rewrites it from the tree).
"""
import json
import pathlib
import re

import swiftscan

RUNTIME_SITE = re.compile(
    r"MarmotClient\.testClient\s*\(|MarmotClient\(\s*rootPath|\bwithTestClient\s*[({]"
    r"|\bOwnedTestClient\s*\(|TestRuntimeScope\.own\s*\("
    r"|(?<!func )\bbootstrap\(\)|(?<!func )\bstartRuntime\s*\(|\bmarmot\.start\b")
UI_SITE = re.compile(r"\bUIHostingController\b|\bUIWindow\b(?!\s*\.\s*Level)")
SLEEP_SITE = re.compile(r"\bTask\.sleep\b")
DIRECT_RUNTIME = re.compile(r"MarmotClient\.testClient\s*\(|MarmotClient\(\s*rootPath")
OWNER_CALL = re.compile(r"TestRuntimeScope\.own\s*\(|(?<![\w.])closing\s*\(")
BINDING = re.compile(r"\b(?:let|var)\s+(\w+)\b[^=\n]*=[^=]")
GATE = "marmotRuntimeConcurrencyLimit"
SUPPORT_DIR = "TestSupport"
TIER_TAGS = ("runtime", "uiHosting")
RULES = ("runtime-tag", "ui-tag", "sleep", "unowned-runtime", "timelimit-gate", "pr-plan")
# (file, helper) pairs in TestSupport/ whose Task.sleep is a bounded wait, a
# deadlock deadline or the production retry backoff, not a fixed delay.
SLEEP_EXEMPT = frozenset({
    ("TestLatch.swift", "TestLatch"),          # TestLatch.wait timeout
    ("TestLatch.swift", "eventually"),
    ("SettleLayout.swift", "settleLayout"),
    ("MarmotFixtureWatchdog.swift", "MarmotFixtureWatchdog"),
    ("AppStateTestFactory.swift", "test"),     # AppState.test's default runtimeRetrySleeper
})
# The bounded waits stay exempt only while their body still uses a timeout or
# deadline (not just declares the parameter); an `eventually` that ignores its
# timeout polls forever and its sleep counts.
TIMEOUT_BOUNDED = frozenset({"TestLatch", "eventually"})
TIMEOUT_USE = re.compile(r"\b(?:timeout|deadline)\b(?!\s*:)")


def enforces_timeout(code):
    return bool(TIMEOUT_USE.search(code))


class Range:
    """One source range: the file's masked views and [start, end); ``name``
    is the helper declaration it came from, if any."""

    def __init__(self, path, masked, start, end, name=None):
        self.path, self.masked, self.start, self.end, self.name = path, masked, start, end, name

    def key(self):
        return (self.path, self.start)

    def in_support(self):
        return SUPPORT_DIR in pathlib.Path(self.path).parts

    def sleep_exempt(self):
        if not (self.in_support() and (pathlib.Path(self.path).name, self.name) in SLEEP_EXEMPT):
            return False
        return self.name not in TIMEOUT_BOUNDED or enforces_timeout(self.masked.code[self.start:self.end])


class Violation:
    def __init__(self, rule, suite, count, detail):
        self.rule, self.suite, self.count, self.detail = rule, suite, count, detail

    def key(self):
        return (self.rule, self.suite)

    def __str__(self):
        return "%s %s: %s" % (self.rule, self.suite, self.detail)


def _traits(arguments):
    return [re.sub(r"\s+", "", a) for a in swiftscan._split_top_level(arguments, ",") if a.strip().startswith(".")]


def _tags(traits):
    tags = set()
    for trait in traits:
        if trait.startswith(".tags("):
            tags.update(t.strip().lstrip(".").split(".")[-1] for t in trait[len(".tags("):-1].split(","))
    return tags


def _names(traits):
    return {t.lstrip(".").split("(")[0] for t in traits}


def _suite_traits(decl):
    attribute = decl.attribute("Suite")
    return _traits(attribute.arguments) if attribute else []


def _test_traits(test):
    attribute = test.declaration.attribute("Test")
    return _traits(attribute.arguments) if attribute else []


def nested_tags(suite):
    """Tags of each nested type inside the suite, keyed by its nesting path
    (``Inner`` or ``Inner/Deeper``), as written on that type only."""
    found = {}

    def walk(masked, decl, prefix):
        if decl.body_start < 0:
            return
        for member in swiftscan.declarations(masked, decl.body_start + 1, decl.body_end, decl.depth + 1):
            if member.keyword in ("struct", "class", "enum", "actor") and member.body_start >= 0:
                path = prefix + "/" + member.name if prefix else member.name
                found[path] = _tags(_suite_traits(member))
                walk(masked, member, path)

    for part in suite.parts:
        walk(part.masked, part.declaration, "")
    return found


def _tagged_prefix(test, nested):
    """The shortest nesting path of ``test`` whose type carries a tier tag."""
    parts = test.nesting.split("/") if test.nesting else []
    for i in range(1, len(parts) + 1):
        prefix = "/".join(parts[:i])
        if nested.get(prefix, set()) & set(TIER_TAGS):
            return prefix, nested[prefix]
    return None, set()


def effective_test_tags(test, nested):
    tags = set(_tags(_test_traits(test)))
    parts = test.nesting.split("/") if test.nesting else []
    for i in range(1, len(parts) + 1):
        tags |= nested.get("/".join(parts[:i]), set())
    return tags


class SuiteScan:
    """Per-test reach of one suite: its tests, the suite members they use and
    the shared helpers (``inventory.helper_index``) behind them."""

    def __init__(self, suite, index, resolve):
        self.suite, self.index, self.resolve = suite, index, resolve
        self.members = {}
        owned = []
        for part in suite.parts:
            decl = part.declaration
            if decl.body_start < 0:
                continue
            tests = {t.start for t in suite.tests if t.path == part.path}
            for member in swiftscan.declarations(part.masked, decl.body_start + 1, decl.body_end, decl.depth + 1):
                if member.start in tests or member.body_start < 0:
                    continue  # tests are scanned separately; stored properties stay suite-wide
                if member.keyword in ("let", "typealias", "extension", "protocol"):
                    continue
                rng = Range(part.path, part.masked, member.start, member.body_end + 1)
                self.members.setdefault(member.name, []).append(rng)
                owned.append(rng)
        self.test_ranges = {}
        for test in suite.tests:
            masked = next(p.masked for p in suite.parts if p.path == test.path)
            rng = Range(test.path, masked, test.start, test.body_end + 1)
            self.test_ranges[test.qualified_name] = rng
            owned.append(rng)
        self.suite_wide = []
        for part in suite.parts:
            decl = part.declaration
            if decl.body_start < 0:
                continue
            cuts = sorted((r.start, r.end) for r in owned if r.path == part.path
                          and decl.body_start < r.start < decl.body_end)
            cursor = decl.body_start + 1
            for start, end in cuts:
                if start > cursor:
                    self.suite_wide.append(Range(part.path, part.masked, cursor, start))
                cursor = max(cursor, end)
            if cursor < decl.body_end:
                self.suite_wide.append(Range(part.path, part.masked, cursor, decl.body_end))

    def reach(self, ranges):
        """``ranges`` plus every member and helper they reference, transitively."""
        seen, found, queue = set(), [], list(ranges)
        while queue:
            rng = queue.pop()
            if rng.key() in seen:
                continue
            seen.add(rng.key())
            found.append(rng)
            for name in sorted(set(swiftscan.identifiers(rng.masked.code, rng.start, rng.end))):
                queue.extend(self.members.get(name, ()))
                for helper in self.resolve(self.index, name, rng.path):
                    queue.append(Range(helper.path, helper.masked, helper.start, helper.end + 1, helper.name))
        return found

    def everything(self):
        return self.reach([*self.test_ranges.values(), *self.suite_wide])


def _count(pattern, ranges):
    return sum(len(pattern.findall(r.masked.code, r.start, r.end)) for r in ranges)


def _tag_rule(rule, scan, pattern, tag, suite_tags, pr_skips, nested):
    suite = scan.suite
    if suite.framework == "XCTest":
        if _count(pattern, scan.everything()) and suite.name not in pr_skips:
            return [Violation(rule, suite.name, 1, "XCTest class needs an entry in the PR test plan's skippedTests")]
        return []
    if tag in suite_tags:
        return []
    if _count(pattern, scan.reach(scan.suite_wide)):
        return [Violation(rule, suite.name, 1, "suite-wide code needs @Suite(.tags(.%s))" % tag)]
    missing = [test.name for test in suite.tests
               if tag not in effective_test_tags(test, nested)
               and _count(pattern, scan.reach([scan.test_ranges[test.qualified_name]]))]
    if missing:
        return [Violation(rule, suite.name, len(missing),
                          "%s need .tags(.%s) on the test or suite" % (", ".join(missing), tag))]
    return []


def _sleep_rule(scan):
    count = _count(SLEEP_SITE, [r for r in scan.everything() if not r.sleep_exempt()])
    if count:
        return [Violation("sleep", scan.suite.name, count,
                          "%d Task.sleep site(s) outside the bounded-wait helpers" % count)]
    return []


def _owned(code, at, enclosing):
    for match in OWNER_CALL.finditer(code, enclosing.start, at):
        if swiftscan.match_close(code, match.end() - 1) > at:
            return True
    line_start = code.rfind("\n", 0, at) + 1
    binding = BINDING.search(code, line_start, at)
    if binding:
        owner = re.compile(r"(?:TestRuntimeScope\.own|(?<![\w.])closing)\s*\(\s*%s\b" % re.escape(binding.group(1)))
        return bool(owner.search(code, enclosing.start, enclosing.end))
    return False


def _unowned_rule(scan):
    lines = set()
    for rng in scan.everything():
        if rng.in_support():
            continue
        code = rng.masked.code
        for match in DIRECT_RUNTIME.finditer(code, rng.start, rng.end):
            if not _owned(code, match.start(), rng):
                lines.add("%s:%d" % (pathlib.Path(rng.path).name, rng.masked.line(match.start())))
    if lines:
        return [Violation("unowned-runtime", scan.suite.name, len(lines),
                          "runtime opened outside withTestClient/OwnedTestClient/TestRuntimeScope at %s"
                          % ", ".join(sorted(lines)))]
    return []


def _timelimit_rule(suite, suite_traits):
    suite_names = _names(suite_traits)
    if "timeLimit" in suite_names and GATE in suite_names:
        return [Violation("timelimit-gate", suite.name, 1, "suite combines .timeLimit with .%s" % GATE)]
    offenders = []
    for test in suite.tests:
        names = _names(_test_traits(test))
        if ("timeLimit" in names or "timeLimit" in suite_names) and (GATE in names or GATE in suite_names):
            offenders.append(test.name)
    if offenders:
        return [Violation("timelimit-gate", suite.name, len(offenders),
                          "%s combine .timeLimit with .%s" % (", ".join(offenders), GATE))]
    return []


def pr_plan_entries(plan_path):
    """The plan's ``skippedTests`` identifiers (any target)."""
    path = pathlib.Path(plan_path)
    if not path.exists():
        return []
    plan = json.loads(path.read_text(encoding="utf-8"))
    return [entry if isinstance(entry, str) else entry.get("identifier", "")
            for target in plan.get("testTargets", []) for entry in target.get("skippedTests", [])]


def pr_plan_skips(plan_path):
    """Suite names the plan skips."""
    return {entry.split("/")[0] for entry in pr_plan_entries(plan_path)}


def tagged_skips(suites):
    """Identifiers of Swift Testing suites, nested suites and tests tagged for
    a slow tier.

    As of Xcode 27.1, xcodebuild ignores a plan's ``skippedTags`` and applies
    its ``skippedTests`` only to XCTest, so the PR plan names the tagged
    suites and tests and ``scripts/test.sh --tier pr`` passes them to Swift
    Testing as ``-skip-testing:`` flags.
    """
    skips = set()
    for suite in suites:
        if suite.framework == "XCTest":
            continue
        if _tags(_suite_traits(suite.declaration)) & set(TIER_TAGS):
            skips.add(suite.name)
            continue
        nested = nested_tags(suite)
        for test in suite.tests:
            prefix, _ = _tagged_prefix(test, nested)
            if prefix:
                skips.add("%s/%s" % (suite.name, prefix))
            elif _tags(_test_traits(test)) & set(TIER_TAGS):
                skips.add("%s/%s" % (suite.name, test.qualified_name))
    return sorted(skips)


def _plan_rule(suites, plan_entries):
    """The PR plan skips exactly the tagged Swift Testing suites and tests;
    other entries must name XCTest classes."""
    xctest = {s.name for s in suites if s.framework == "XCTest"}
    wanted = set(tagged_skips(suites))
    have = set(plan_entries)
    by_suite = {}
    for entry in sorted(wanted - have):
        by_suite.setdefault(entry.split("/")[0], []).append("missing " + entry)
    for entry in sorted(have - wanted):
        if entry not in xctest:
            by_suite.setdefault(entry.split("/")[0], []).append("untagged " + entry)
    return [Violation("pr-plan", suite, len(items), "PR plan skippedTests out of date (%s); run "
                      "inventory.py --write-pr-plan" % "; ".join(items)) for suite, items in sorted(by_suite.items())]


def write_pr_plan(plan_path, suites, xctest_classes=()):
    """Rewrite the plan's skippedTests: the XCTest tier classes and those it
    already lists (XCTest cannot be tagged), then the tagged identifiers."""
    path = pathlib.Path(plan_path)
    plan = json.loads(path.read_text(encoding="utf-8"))
    xctest = {s.name for s in suites if s.framework == "XCTest"}
    tagged = tagged_skips(suites)
    for target in plan.get("testTargets", []):
        kept = sorted({e for e in target.get("skippedTests", []) if isinstance(e, str) and e in xctest}
                      | set(xctest_classes))
        target["skippedTests"] = kept + tagged
    path.write_text(json.dumps(plan, indent=2, separators=(",", " : ")) + "\n", encoding="utf-8")
    return len(tagged)


def violations(suites, index, resolve, pr_skips, plan_entries=None):
    found = []
    if plan_entries is not None:
        found += _plan_rule(suites, plan_entries)
    for suite in suites:
        scan = SuiteScan(suite, index, resolve)
        traits = _suite_traits(suite.declaration)
        tags = _tags(traits)
        nested = nested_tags(suite)
        found += _tag_rule("runtime-tag", scan, RUNTIME_SITE, "runtime", tags, pr_skips, nested)
        found += _tag_rule("ui-tag", scan, UI_SITE, "uiHosting", tags, pr_skips, nested)
        found += _sleep_rule(scan)
        found += _unowned_rule(scan)
        found += _timelimit_rule(suite, traits)
    return found


class BaselineError(ValueError):
    pass


def read_baseline(path):
    """``{(rule, suite): count}``; a malformed line raises ``BaselineError``."""
    path = pathlib.Path(path)
    if not path.exists():
        return {}
    entries = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        text = line.split("#", 1)[0].strip()
        if not text:
            continue
        fields = text.split()
        if len(fields) != 3 or fields[0] not in RULES or not fields[2].isdigit() or int(fields[2]) < 1:
            raise BaselineError("%s:%d: expected `<rule> <Suite> <count>` with a rule from %s and a positive "
                                "count, got %r" % (path, number, ", ".join(RULES), line))
        key = (fields[0], fields[1])
        if key in entries:
            raise BaselineError("%s:%d: duplicate entry %s %s" % (path, number, *key))
        entries[key] = int(fields[2])
    return entries


def compare_with_baseline(found, baseline):
    """(failures, baselined) message lists. A violation passes only at
    exactly its baseline count; new, higher, lower and vanished entries fail."""
    failures, known = [], []
    current = {v.key(): v for v in found}
    for violation in found:
        allowed = baseline.get(violation.key())
        if allowed is None:
            failures.append("new: %s" % violation)
        elif violation.count > allowed:
            failures.append("count %d exceeds baseline %d: %s" % (violation.count, allowed, violation))
        elif violation.count < allowed:
            failures.append("count %d is below baseline %d; lower the baseline line to %d: %s"
                            % (violation.count, allowed, violation.count, violation))
        else:
            known.append(str(violation))
    for key in sorted(set(baseline) - set(current)):
        failures.append("stale baseline line (fixed; delete it): %s %s %d" % (key[0], key[1], baseline[key]))
    return failures, known


BASELINE_HEADER = """\
# Known guardrail violations, `<rule> <Suite> <count>` per line (scripts/audit/guardrails.py).
# A suite must match its count exactly: more fails, and so do fewer or a fixed
# suite until this file is tightened in the same change. Regenerate with
# `python3 scripts/audit/inventory.py --write-baseline`; never raise a count to
# land new code, fix the suite instead.
"""


def write_baseline(path, found):
    lines = [BASELINE_HEADER]
    for rule in RULES:
        rows = sorted((v.suite, v.count) for v in found if v.rule == rule)
        if rows:
            lines.append("\n")
            lines.extend("%s %s %d\n" % (rule, suite, count) for suite, count in rows)
    pathlib.Path(path).write_text("".join(lines), encoding="utf-8")
    return len(found)
