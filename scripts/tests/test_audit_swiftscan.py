import tempfile
import unittest

import audit_support

swiftscan = audit_support.load("swiftscan")


class MaskTests(unittest.TestCase):
    def test_comments_and_string_contents_are_blanked_but_offsets_kept(self):
        source = 'let a = "x { y" // brace {\n/* multi\n line { */ let b = 1\n'
        masked = swiftscan.mask(source)
        self.assertEqual(len(masked.code), len(source))
        self.assertEqual(len(masked.text), len(source))
        self.assertNotIn("brace", masked.text)
        self.assertNotIn("multi", masked.text)
        self.assertIn('"x { y"', masked.text)
        self.assertNotIn("x { y", masked.code)
        self.assertIn('"', masked.code)
        self.assertEqual(masked.code.count("{"), 0)
        self.assertEqual(masked.line(source.index("let b")), 3)

    def test_interpolation_code_is_kept_and_nested_strings_handled(self):
        source = 'let s = "a \\(f("{", { x in x }))b"\nlet t = 2\n'
        masked = swiftscan.mask(source)
        self.assertIn("f(", masked.code)
        self.assertNotIn("a ", masked.code[:12])
        self.assertEqual(masked.code.count("{"), masked.code.count("}"))
        self.assertIn("let t = 2", masked.code)

    def test_multiline_and_raw_strings(self):
        source = 'let m = """\n  { not code "quoted" }\n  """\nlet r = #"raw { " text"#\nlet z = 0\n'
        masked = swiftscan.mask(source)
        self.assertNotIn("not code", masked.code)
        self.assertNotIn("raw {", masked.code)
        self.assertIn("let z = 0", masked.code)
        self.assertEqual(swiftscan.brace_depths(masked.code)[-1], 0)

    def test_nested_block_comments(self):
        masked = swiftscan.mask("/* outer /* inner */ still { comment */ let q = 1\n")
        self.assertNotIn("comment", masked.code)
        self.assertIn("let q = 1", masked.code)


class DeclarationTests(unittest.TestCase):
    def test_headers_collect_multiline_attributes_and_skip_imports_and_conditionals(self):
        source = (
            "import Testing\n@testable import app\n\n"
            "@MainActor\n@Suite(.serialized, .tags(.runtime))\nstruct AlphaTests {\n"
            "    private let gate = Gate()\n"
            "    @Test(\n        .enabled(if: flag),\n        arguments: [1, 2]\n    )\n"
            "    func first(value: Int) async throws {}\n"
            "    #if os(iOS)\n    @Test(.disabled(\"why\"))\n    #else\n    @Test\n    #endif\n"
            "    func second() {}\n"
            "    func helper(_ a: Int, b: String) {}\n"
            "    class func factory() -> Int { 1 }\n"
            "}\n"
        )
        masked = swiftscan.mask(source)
        decls = list(swiftscan.declarations(masked))
        self.assertEqual([d.name for d in decls], ["AlphaTests"])
        suite = decls[0]
        self.assertNotIn("import", suite.header)
        self.assertTrue(suite.has_attribute("MainActor"))
        self.assertEqual(suite.attribute("Suite").arguments, ".serialized, .tags(.runtime)")
        members = list(swiftscan.declarations(masked, suite.body_start + 1, suite.body_end, 1))
        names = [(m.keyword, m.name) for m in members]
        self.assertEqual(names, [("let", "gate"), ("func", "first"), ("func", "second"),
                                 ("func", "helper"), ("func", "factory")])
        self.assertTrue(members[1].has_attribute("Test"))
        self.assertTrue(members[2].has_attribute("Test"))
        self.assertFalse(members[3].has_attribute("Test"))
        self.assertIn("class", members[4].modifiers)
        self.assertEqual(swiftscan.signature_of(masked, members[1]), "first(value:)")
        self.assertEqual(swiftscan.signature_of(masked, members[3]), "helper(_:b:)")

    def test_signature_keeps_labels_after_closure_typed_parameters(self):
        masked = swiftscan.mask("struct T {\n    func t(handler: (Int) -> Void, b: Int, c: [String: () -> Bool]) {}\n}\n")
        suite = next(swiftscan.declarations(masked))
        func = next(swiftscan.declarations(masked, suite.body_start + 1, suite.body_end, 1))
        self.assertEqual(swiftscan.signature_of(masked, func), "t(handler:b:c:)")

    def test_nested_types_do_not_count_as_top_level(self):
        masked = swiftscan.mask("struct Outer {\n    struct Inner {}\n    enum Mode { case a }\n}\nenum Top {}\n")
        self.assertEqual([d.name for d in swiftscan.declarations(masked)], ["Outer", "Top"])
        self.assertEqual(swiftscan.all_type_names(masked), {"Outer", "Inner", "Mode", "Top"})


class SuiteTests(unittest.TestCase):
    def test_suites_merge_extensions_across_files_and_detect_frameworks(self):
        files = {
            "AlphaTests.swift": (
                "struct AlphaTests {\n    @Test func one() {}\n    func notATest() {}\n"
                "    struct Nested {\n        @Test func inner() {}\n    }\n}\n"
                "private struct Fixture {}\n"
            ),
            "AlphaMore.swift": "extension AlphaTests {\n    @Test func two(_ x: Int) {}\n}\n"
                              "extension Fixture {\n    @Test func ignored() {}\n}\n",
            "Legacy.swift": "final class LegacyTests: XCTestCase {\n    func testOld() {}\n"
                            "    func helper() {}\n    static func testNotInstance() {}\n}\n",
            "Base.swift": "class LayoutCase: XCTestCase {\n    func measure() {}\n}\n"
                          "final class ControlLayoutChecks: LayoutCase {\n    func testFits() {}\n}\n",
            "Named.swift": '@Suite("Media viewer")\nstruct MediaViewerChecks {\n    @Test func shows() {}\n}\n'
                           "struct ImplicitChecks {\n    @Test func implied() {}\n}\n"
                           "struct NotASuite {\n    func plain() {}\n}\n",
        }
        with tempfile.TemporaryDirectory() as root:
            audit_support.write_tree(root, files)
            warnings = []
            suites, masks = swiftscan.collect_suites(root, warnings.append)
        self.assertEqual([s.name for s in suites], ["AlphaTests", "ControlLayoutChecks", "ImplicitChecks",
                                                    "LayoutCase", "LegacyTests", "MediaViewerChecks"])
        by_name = {s.name: s for s in suites}
        self.assertEqual(by_name["ControlLayoutChecks"].framework, "XCTest")
        self.assertEqual([t.signature for t in by_name["ControlLayoutChecks"].tests], ["testFits()"])
        self.assertEqual(by_name["LayoutCase"].tests, [])
        self.assertEqual([t.signature for t in by_name["ImplicitChecks"].tests], ["implied()"])
        alpha = suites[0]
        self.assertEqual(sorted(t.qualified_name for t in alpha.tests), ["Nested/inner()", "one()", "two(_:)"])
        self.assertEqual(len(alpha.parts), 2)
        self.assertEqual(alpha.framework, "SwiftTesting")
        self.assertEqual(alpha.line, 1)
        legacy = by_name["LegacyTests"]
        self.assertEqual(legacy.framework, "XCTest")
        self.assertEqual([t.signature for t in legacy.tests], ["testOld()"])
        self.assertEqual(warnings, [])
        self.assertEqual(set(masks), {str(audit_support.pathlib.Path(root) / name) for name in files})

    def test_duplicate_suite_names_are_reported(self):
        files = {"A.swift": "struct DupTests {}\n", "B.swift": "struct DupTests {}\n"}
        with tempfile.TemporaryDirectory() as root:
            audit_support.write_tree(root, files)
            warnings = []
            suites, _ = swiftscan.collect_suites(root, warnings.append)
        self.assertEqual(len(suites), 2)
        self.assertEqual(len(warnings), 1)
        self.assertIn("DupTests", warnings[0])


if __name__ == "__main__":
    unittest.main()
