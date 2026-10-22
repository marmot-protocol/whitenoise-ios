import csv
import pathlib
import tempfile
import unittest

import audit_support

inventory = audit_support.load("inventory")

RUNTIME_SUITE = '''import Testing
@testable import whitenoise_ios

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .tags(.runtime, .slow))
struct RuntimeTests {
    @Test func boots() async throws {
        let client = try MarmotClient.testClient()
        let other = MarmotClient(rootPath: "/tmp")
        let appState = AppState.test(client: client)
        await appState.bootstrap()
        try await appState.startRuntime()
        // Task.sleep in a comment must not count
        let note = "Task.sleep in a string must not count"
        try await Task.sleep(for: .milliseconds(10))
        for _ in 0..<30 {
            if appState.ready { break }
            await Task.yield()
        }
        while !done {
            try await Task.sleep(for: .milliseconds(1))
        }
        for item in items { consume(item) }
        #expect(
            label == L10n.string("Copied")
        )
        try #require(L10n.formatted("x", 1) == "x")
        try await client.marmot.shutdownAndClose()
        RunLoop.main.run(until: .now)
    }
}

private func fileHelper() async throws {
    try await Task.sleep(for: .seconds(1))
}
'''

RUNTIME_EXTENSION = '''extension RuntimeTests {
    @Test func more() async throws {
        try await Task.sleep(for: .seconds(1))
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
    }
}
'''

UI_SUITE = '''import XCTest

final class LayoutTests: XCTestCase {
    func testHosts() {
        let host = UIHostingController(rootView: Text("x"))
        let window = UIWindow()
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let renderer = ImageRenderer(content: Text("x"))
        XCTAssertEqual(L10n.string("a"), "a")
    }
}

struct PureTests {
    @Test func adds() { #expect(1 + 1 == 2) }
}
'''


class InventoryRowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.tests_dir = pathlib.Path(cls.temp.name) / "whitenoise-iosTests"
        audit_support.write_tree(cls.tests_dir, {
            "RuntimeTests.swift": RUNTIME_SUITE,
            "RuntimeMore.swift": RUNTIME_EXTENSION,
            "LayoutTests.swift": UI_SUITE,
        })
        cls.rows = {row["suite"]: row for row in inventory.build_rows(str(cls.tests_dir))}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_runtime_suite_counts_within_its_brace_ranges_including_extensions(self):
        row = self.rows["RuntimeTests"]
        self.assertEqual(row["file"], "RuntimeTests.swift")
        self.assertEqual(row["line"], 6)  # the keyword line, not the first attribute
        self.assertEqual(row["tests"], 2)
        self.assertEqual(row["framework"], "SwiftTesting")
        self.assertEqual(row["traits"], ".serialized;.timeLimit(.minutes(1));.tags(.runtime,.slow)")
        self.assertEqual(row["main_actor"], 1)
        self.assertEqual(row["testClient_sites"], 2)
        self.assertEqual(row["start_sites"], 2)
        self.assertEqual(row["shutdown_sites"], 1)
        self.assertEqual(row["app_state_test_sites"], 1)
        self.assertEqual(row["sleep_sites"], 3)  # one in each loop-free spot, one in the extension
        self.assertEqual(row["poll_loops"], 2)
        self.assertEqual(row["run_loop"], 1)
        self.assertEqual(row["l10n_asserts"], 2)
        self.assertEqual(row["xcstrings_reads"], 1)
        self.assertEqual(row["ui_hosting"], 0)

    def test_ui_suite_and_pure_suite(self):
        layout = self.rows["LayoutTests"]
        self.assertEqual(layout["framework"], "XCTest")
        self.assertEqual(layout["tests"], 1)
        self.assertEqual(layout["ui_hosting"], 3)
        self.assertEqual(layout["image_renderer"], 1)
        self.assertEqual(layout["layout_if_needed"], 1)
        self.assertEqual(layout["l10n_asserts"], 1)
        self.assertEqual(layout["main_actor"], 0)
        pure = self.rows["PureTests"]
        self.assertEqual(pure["tests"], 1)
        self.assertEqual(sum(int(pure[c]) for c in inventory.CODE_PATTERNS), 0)

    def test_tier_lists_are_disjoint_with_runtime_precedence(self):
        rows = list(self.rows.values()) + [{
            "suite": "TaggedTests", "traits": ".tags(.ui)", "tests": 1,
            **{c: 0 for c in list(inventory.CODE_PATTERNS) + ["poll_loops", "l10n_asserts", "xcstrings_reads"]},
        }]
        runtime, ui = inventory.tier_lists(rows, "whitenoise-iosTests")
        self.assertEqual(runtime, ["whitenoise-iosTests/RuntimeTests"])
        self.assertEqual(ui, ["whitenoise-iosTests/LayoutTests", "whitenoise-iosTests/TaggedTests"])

    def test_rules(self):
        rows = list(self.rows.values())
        self.assertEqual(inventory.parse_rule("testClient-requires-tag=runtime"), ("testClient_sites", "requires-tag", "runtime"))
        self.assertEqual(inventory.parse_rule("sleep_sites-max=0"), ("sleep_sites", "max", 0))
        with self.assertRaises(ValueError):
            inventory.parse_rule("bogus-requires-tag=x")
        with self.assertRaises(ValueError):
            inventory.parse_rule("testClient=runtime")
        self.assertEqual(inventory.check_rules(rows, [inventory.parse_rule("testClient-requires-tag=runtime")]), [])
        violations = inventory.check_rules(rows, [inventory.parse_rule("ui_hosting-requires-tag=ui"),
                                                  inventory.parse_rule("sleep-max=1"),
                                                  inventory.parse_rule("testClient-requires-trait=serialized")])
        self.assertEqual(len(violations), 2)
        self.assertTrue(any(v.startswith("LayoutTests: ui_hosting=3") for v in violations))
        self.assertTrue(any(v.startswith("RuntimeTests: sleep_sites=3") for v in violations))

    def test_main_writes_csv_tier_lists_and_exit_code(self):
        with tempfile.TemporaryDirectory() as out_root:
            out = pathlib.Path(out_root) / "audit" / "inventory.csv"
            code = inventory.main(["--tests-dir", str(self.tests_dir), "--out", str(out), "--emit-tier-lists",
                                   "--check", "--rule", "testClient-requires-tag=runtime"])
            self.assertEqual(code, 0)
            with out.open(newline="") as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual([r["suite"] for r in rows], ["LayoutTests", "PureTests", "RuntimeTests"])
            self.assertEqual(list(rows[0]), inventory.COLUMNS)
            self.assertEqual((out.parent / "tier-runtime.txt").read_text(), "whitenoise-iosTests/RuntimeTests\n")
            self.assertEqual((out.parent / "tier-ui.txt").read_text(), "whitenoise-iosTests/LayoutTests\n")
            code = inventory.main(["--tests-dir", str(self.tests_dir), "--out", str(out),
                                   "--check", "--rule", "ui_hosting-requires-tag=ui"])
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
