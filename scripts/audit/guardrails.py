"""Test-suite guardrails behind ``inventory.py --check``.

Fixed rules, each keyed by suite:

- ``runtime-tag``: a Swift Testing test that opens a Marmot runtime
  (``MarmotClient.testClient(``, ``MarmotClient(rootPath:``,
  ``withTestClient``, ``OwnedTestClient(``, ``TestRuntimeScope.own(``),
  directly or through a helper it reaches, carries ``.tags(.runtime)`` on the
  test or its suite. Suite-wide code (stored properties, ``init``) needs the
  suite tag.
- ``ui-tag``: the same for ``UIWindow``/``UIHostingController`` and
  ``.tags(.uiHosting)``. ``ImageRenderer`` renders offscreen and does not count.
  XCTest classes cannot be tagged, so for both rules an XCTest class must be
  listed in the PR test plan's ``skippedTests`` instead.
- ``sleep``: no ``Task.sleep`` in the suite or in a helper it reaches outside
  ``TestSupport/``.
- ``unowned-runtime``: a direct ``MarmotClient.testClient(`` or
  ``MarmotClient(rootPath:`` outside ``TestSupport/`` sits inside
  ``TestRuntimeScope.own(`` / ``closing(``, or binds a name the enclosing
  declaration passes to one of them. Otherwise use ``withTestClient`` or
  ``OwnedTestClient``.
- ``timelimit-gate``: ``.timeLimit`` and ``.marmotRuntimeConcurrencyLimit``
  never apply to the same test, since the limit would count queue time behind
  the gate.
- ``pr-plan``: ``TestPlans/PR.xctestplan`` skips exactly the tagged Swift
  Testing suites and tests (see ``tagged_skips``) plus XCTest classes;
  ``inventory.py --write-pr-plan`` regenerates the list.

Known violations live in a baseline file (``rule Suite`` per line); they are
reported but do not fail, so the check only stops new ones. Remove a line
once its suite is fixed; stale lines are reported.
"""
import json
import pathlib
import re

import swiftscan

RUNTIME_SITE = re.compile(
    r"MarmotClient\.testClient\s*\(|MarmotClient\(\s*rootPath|\bwithTestClient\s*[({]"
    r"|\bOwnedTestClient\s*\(|TestRuntimeScope\.own\s*\(")
UI_SITE = re.compile(r"\bUIHostingController\b|\bUIWindow\b(?!\s*\.\s*Level)")
SLEEP_SITE = re.compile(r"\bTask\.sleep\b")
DIRECT_RUNTIME = re.compile(r"MarmotClient\.testClient\s*\(|MarmotClient\(\s*rootPath")
OWNER_CALL = re.compile(r"TestRuntimeScope\.own\s*\(|(?<![\w.])closing\s*\(")
BINDING = re.compile(r"\b(?:let|var)\s+(\w+)\b[^=\n]*=[^=]")
GATE = "marmotRuntimeConcurrencyLimit"
SUPPORT_DIR = "TestSupport"
TIER_TAGS = ("runtime", "uiHosting")
RULES = ("runtime-tag", "ui-tag", "sleep", "unowned-runtime", "timelimit-gate", "pr-plan")


class Range:
    """One source range: the file's masked views and [start, end)."""

    def __init__(self, path, masked, start, end):
        self.path, self.masked, self.start, self.end = path, masked, start, end

    def key(self):
        return (self.path, self.start)

    def in_support(self):
        return SUPPORT_DIR in pathlib.Path(self.path).parts


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
                    queue.append(Range(helper.path, helper.masked, helper.start, helper.end + 1))
        return found


def _count(pattern, ranges):
    return sum(len(pattern.findall(r.masked.code, r.start, r.end)) for r in ranges)


def _tag_rule(rule, scan, pattern, tag, suite_tags, pr_skips):
    suite = scan.suite
    if suite.framework == "XCTest":
        if _count(pattern, scan.reach([*scan.test_ranges.values(), *scan.suite_wide])) and suite.name not in pr_skips:
            return ["%s %s: XCTest class needs an entry in the PR test plan's skippedTests" % (rule, suite.name)]
        return []
    if tag in suite_tags:
        return []
    if _count(pattern, scan.reach(scan.suite_wide)):
        return ["%s %s: suite-wide code needs @Suite(.tags(.%s))" % (rule, suite.name, tag)]
    missing = [test.name for test in suite.tests
               if tag not in _tags(_test_traits(test))
               and _count(pattern, scan.reach([scan.test_ranges[test.qualified_name]]))]
    if missing:
        return ["%s %s: %s need .tags(.%s) on the test or suite" % (rule, suite.name, ", ".join(missing), tag)]
    return []


def _sleep_rule(scan):
    ranges = [r for r in scan.reach([*scan.test_ranges.values(), *scan.suite_wide]) if not r.in_support()]
    count = _count(SLEEP_SITE, ranges)
    if count:
        return ["sleep %s: %d Task.sleep site(s) outside TestSupport/" % (scan.suite.name, count)]
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
    lines = []
    for rng in scan.reach([*scan.test_ranges.values(), *scan.suite_wide]):
        if rng.in_support():
            continue
        code = rng.masked.code
        for match in DIRECT_RUNTIME.finditer(code, rng.start, rng.end):
            if not _owned(code, match.start(), rng):
                lines.append("%s:%d" % (pathlib.Path(rng.path).name, rng.masked.line(match.start())))
    if lines:
        return ["unowned-runtime %s: runtime opened outside withTestClient/OwnedTestClient/"
                "TestRuntimeScope at %s" % (scan.suite.name, ", ".join(sorted(set(lines))))]
    return []


def _timelimit_rule(suite, suite_traits):
    suite_names = _names(suite_traits)
    if "timeLimit" in suite_names and GATE in suite_names:
        return ["timelimit-gate %s: suite combines .timeLimit with .%s" % (suite.name, GATE)]
    offenders = []
    for test in suite.tests:
        names = _names(_test_traits(test))
        if ("timeLimit" in names or "timeLimit" in suite_names) and (GATE in names or GATE in suite_names):
            offenders.append(test.name)
    if offenders:
        return ["timelimit-gate %s: %s combine .timeLimit with .%s" % (suite.name, ", ".join(offenders), GATE)]
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
    """Identifiers of Swift Testing suites and tests tagged for a slow tier.

    As of Xcode 27.1, xcodebuild ignores a plan's ``skippedTags`` and applies
    its ``skippedTests`` only to XCTest, so the PR plan names the tagged
    suites and tests and ``scripts/test.sh --tier pr`` passes them to Swift
    Testing as ``-skip-testing:`` flags.
    """
    skips = []
    for suite in suites:
        if suite.framework == "XCTest":
            continue
        if _tags(_suite_traits(suite.declaration)) & set(TIER_TAGS):
            skips.append(suite.name)
            continue
        skips.extend("%s/%s" % (suite.name, test.qualified_name) for test in suite.tests
                     if _tags(_test_traits(test)) & set(TIER_TAGS))
    return sorted(skips)


def _plan_rule(suites, plan_entries):
    """The PR plan skips exactly the tagged Swift Testing suites and tests;
    other entries must name XCTest classes."""
    xctest = {s.name for s in suites if s.framework == "XCTest"}
    wanted = set(tagged_skips(suites))
    have = set(plan_entries)
    found = ["pr-plan %s: tagged for a slow tier but missing from the PR plan's skippedTests" % entry.split("/")[0]
             + ("" if "/" not in entry else " (%s)" % entry) for entry in sorted(wanted - have)]
    found += ["pr-plan %s: the PR plan skips %s, which is no tagged test or XCTest class"
              % (entry.split("/")[0], entry) for entry in sorted(have - wanted) if entry not in xctest]
    return found


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
        found += _tag_rule("runtime-tag", scan, RUNTIME_SITE, "runtime", tags, pr_skips)
        found += _tag_rule("ui-tag", scan, UI_SITE, "uiHosting", tags, pr_skips)
        found += _sleep_rule(scan)
        found += _unowned_rule(scan)
        found += _timelimit_rule(suite, traits)
    return found


def read_baseline(path):
    path = pathlib.Path(path)
    if not path.exists():
        return set()
    entries = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            rule, suite = line.split()
            entries.add((rule, suite))
    return entries


def split_by_baseline(found, baseline):
    """(new, baselined, stale) for violation strings ``"<rule> <Suite>: …"``."""
    keyed = [(tuple(v.split(":", 1)[0].split()), v) for v in found]
    new = [v for key, v in keyed if key not in baseline]
    known = [v for key, v in keyed if key in baseline]
    stale = sorted(baseline - {key for key, _ in keyed})
    return new, known, stale
