import csv
import pathlib
import tempfile
import unittest

import audit_support

heuristics = audit_support.load("assertion-heuristics")
inventory = audit_support.load("inventory")
swiftscan = heuristics.swiftscan


def analyse(body, helpers=frozenset(), constants=None, signature="()"):
    source = "struct T {\n    @Test func t%s {\n" % signature + body + "\n    }\n}\n"
    masked = swiftscan.mask(source)
    suite = next(swiftscan.declarations(masked))
    test = swiftscan.tests_in(masked, suite, "SwiftTesting")[0]
    count, flags = heuristics.analyse_body(masked, test, helpers, constants)
    return count, dict(flags)


class AnalyseBodyTests(unittest.TestCase):
    def test_counts_assertions_and_flags_none_on_ordinary_test(self):
        count, flags = analyse('let v = compute()\n#expect(v == 3)\ntry #require(v > 0)\nXCTAssertTrue(ok)\nIssue.record("x")')
        self.assertEqual(count, 4)
        self.assertEqual(flags, {})

    def test_zero_assertions_unless_a_helper_asserts_or_the_test_must_not_throw(self):
        self.assertEqual(analyse("run()")[1], {"zero-assertions": 1})
        count, flags = analyse("expectReady(model)", helpers={"expectReady"})
        self.assertEqual((count, flags), (1, {}))
        count, flags = analyse("await #expect {\n try await prepare()\n} throws: { error in true }")
        self.assertEqual((count, flags), (1, {}))
        self.assertEqual(analyse("try Limit.validate(counts: [1])", signature="() throws")[1], {})
        self.assertEqual(analyse("Limit.validate(counts: [1])", signature="() throws")[1], {"zero-assertions": 1})
        self.assertEqual(analyse("try? Limit.validate(counts: [1])", signature="() throws")[1], {"zero-assertions": 1})

    def test_memberwise_roundtrip(self):
        body = 'let s = Shape(width: 2, name: "box", other: make())\n#expect(s.width == 2)\n#expect(s.name == "box")\n#expect(s.area == 4)'
        self.assertEqual(analyse(body)[1], {"memberwise-roundtrip": 2})

    def test_constant_literal_uses_static_constants_when_available(self):
        body = ("#expect(Metrics.cornerRadius == 18)\n#expect(Metrics.Inner.pad == 2)\n#expect(Metrics.compute() == 18)\n"
                "#expect(value.count == 18)\n#expect(Metrics.cornerRadius == Other.radius)\n#expect(Metrics.cornerRadius == other.radius)")
        self.assertEqual(analyse(body)[1], {"constant-literal": 3})
        constants = {("Metrics", "cornerRadius"), ("Other", "radius")}
        self.assertEqual(analyse(body, constants=constants)[1], {"constant-literal": 2})
        self.assertEqual(analyse(body, constants={("Metrics", "cornerRadius")})[1], {"constant-literal": 1})
        self.assertEqual(analyse(body, constants=set())[1], {})


class SourceScanTests(unittest.TestCase):
    def test_static_constants_skip_computed_vars(self):
        with tempfile.TemporaryDirectory() as root:
            audit_support.write_tree(root, {"app/M.swift": (
                "enum Metrics {\n    static let cornerRadius: CGFloat = 18\n    let instance = 1\n"
                "    static var cacheCount: Int { counter.load() }\n    static var stored = 4\n"
                "    struct Inner { static var pad = 2 }\n}\nextension Metrics { static let extra = 3 }\n")})
            self.assertEqual(heuristics.static_constants_in([root]),
                             {("Metrics", "cornerRadius"), ("Metrics", "stored"), ("Inner", "pad"), ("Metrics", "extra")})

    def test_asserting_helpers_are_found_across_files(self):
        masks = {
            "a": swiftscan.mask("struct T {\n    func expectReady(_ m: M) { #expect(m.ready) }\n    func build() -> M { M() }\n"
                                "    @Test func testish() { #expect(true) }\n}\n"),
            "b": swiftscan.mask("func fileLevel() { XCTAssertTrue(true) }\nfunc quiet() {}\n"),
        }
        self.assertEqual(heuristics.asserting_helpers(masks), {"expectReady", "fileLevel"})

    def test_main_writes_csv_and_merges_rollup(self):
        files = {"FlagTests.swift": (
            "struct FlagTests {\n    @Test func bare() { run() }\n"
            "    @Test func pinned() { #expect(Keys.storage == \"k\"); #expect(Keys.storage == \"k\") }\n"
            "    @Test func fine() { #expect(f() == 1) }\n}\n"
            "struct OtherTests {\n    @Test func ok() { #expect(true) }\n}\n")}
        with tempfile.TemporaryDirectory() as root:
            tests_dir = pathlib.Path(root) / "whitenoise-iosTests"
            audit_support.write_tree(tests_dir, files)
            inv = pathlib.Path(root) / "inventory.csv"
            inventory.main(["--tests-dir", str(tests_dir), "--out", str(inv)])
            out = pathlib.Path(root) / "assertions.csv"
            code = heuristics.main(["--tests-dir", str(tests_dir), "--out", str(out), "--inventory", str(inv),
                                    "--merge", "--no-app-dirs"])
            self.assertEqual(code, 0)
            with out.open(newline="") as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual(list(rows[0]), heuristics.COLUMNS)
            self.assertEqual([(r["test"], r["assertions"], r["flags"]) for r in rows], [
                ("bare()", "0", "zero-assertions:1"), ("pinned()", "2", "constant-literal:2"),
                ("fine()", "1", ""), ("ok()", "1", "")])
            with inv.open(newline="") as handle:
                merged = {r["suite"]: r for r in csv.DictReader(handle)}
            self.assertEqual(merged["FlagTests"]["literal_assertion_flags"], "zero-assertions:1;constant-literal:2")
            self.assertEqual(merged["OtherTests"]["literal_assertion_flags"], "")
            self.assertNotIn("tautology_flags", merged["FlagTests"])


if __name__ == "__main__":
    unittest.main()
