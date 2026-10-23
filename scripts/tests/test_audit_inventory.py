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
        repeat {
            await Task.yield()
        } while !settled
        for item in items { consume(item) }
        #expect(
            label == L10n.string("Copied")
        )
        try #require(L10n.formatted("x", 1) == "x")
        try await client.marmot.shutdownAndClose()
        RunLoop.main.run(until: .now)
        try await fileHelper()
        await Watchdog.wait()
    }
}

private func fileHelper() async throws {
    try await Task.sleep(for: .seconds(1))
}

private func unusedHelper() async throws {
    try await Task.sleep(for: .seconds(2))
}
'''

RUNTIME_EXTENSION = '''extension RuntimeTests {
    @Test func more() async throws {
        try await Task.sleep(for: .seconds(1))
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
    }
}
'''

HARNESS_SUITE = '''struct HarnessTests {
    @Test func drivesTheDouble() throws {
        let harness = try SendHarness()
        harness.shutdown()
    }
}

private final class SendHarness {
    let client: MarmotClient
    init() throws {
        client = try MarmotClient.testClient()
        let window = UIWindow()
        window.layoutIfNeeded()
    }
    func shutdown() { client.marmot.shutdownAndClose() }
}
'''

FACTORY_FILE = '''extension AppState {
    static func test(client: MarmotClient? = nil) -> AppState {
        AppState(client: client ?? (try! MarmotClient.testClient()))
    }
}
private let gate = Gate(sleep: { try await Task.sleep(for: .seconds(9)) })
'''

WATCHDOG_FILE = '''enum Watchdog {
    static func wait() async {
        try? await Task.sleep(for: .seconds(30))
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

struct FactoryTests {
    @Test func usesTheFactory() {
        let appState = AppState.test()
        #expect(appState != nil)
    }
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
            "HarnessTests.swift": HARNESS_SUITE,
            "AppStateTestFactory.swift": FACTORY_FILE,
            "Watchdog.swift": WATCHDOG_FILE,
            "LayoutTests.swift": UI_SUITE,
        })
        cls.rows = {row["suite"]: row for row in inventory.build_rows(str(cls.tests_dir))}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_runtime_suite_counts_its_ranges_extensions_and_reached_helpers(self):
        row = self.rows["RuntimeTests"]
        self.assertEqual(row["file"], "RuntimeTests.swift")
        self.assertEqual(row["line"], 6)  # the keyword line, not the first attribute
        self.assertEqual(row["tests"], 2)
        self.assertEqual(row["framework"], "SwiftTesting")
        self.assertEqual(row["traits"], ".serialized;.timeLimit(.minutes(1));.tags(.runtime,.slow)")
        self.assertEqual(row["main_actor"], 1)
        self.assertEqual(row["testClient_sites"], 3)  # two call sites + the one hidden in AppState.test()
        self.assertEqual(row["start_sites"], 2)
        self.assertEqual(row["shutdown_sites"], 1)
        self.assertEqual(row["app_state_test_sites"], 1)
        # body 2 + extension 1 + fileHelper (same file) + Watchdog (shared,
        # other file); unusedHelper and the private `gate` elsewhere are not reached
        self.assertEqual(row["sleep_sites"], 5)
        self.assertEqual(row["helper_sites"], "testClient_sites:1;sleep_sites:2")
        self.assertEqual(row["poll_loops"], 3)
        self.assertEqual(row["run_loop"], 1)
        self.assertEqual(row["l10n_asserts"], 2)
        self.assertEqual(row["xcstrings_reads"], 1)
        self.assertEqual(row["ui_hosting"], 0)

    def test_file_private_harness_cost_is_charged_to_the_suite_using_it(self):
        row = self.rows["HarnessTests"]
        self.assertEqual(row["testClient_sites"], 1)
        self.assertEqual(row["ui_hosting"], 1)
        self.assertEqual(row["layout_if_needed"], 1)
        self.assertEqual(row["shutdown_sites"], 1)
        self.assertEqual(row["helper_sites"],
                         "testClient_sites:1;shutdown_sites:1;ui_hosting:1;layout_if_needed:1")

    def test_extension_member_factory_counts_nested_calls_but_not_its_own_construction(self):
        row = self.rows["FactoryTests"]
        self.assertEqual(row["app_state_test_sites"], 1)  # the call site only
        self.assertEqual(row["testClient_sites"], 1)  # hidden runtime inside AppState.test()
        self.assertEqual(row["sleep_sites"], 0)  # the private `gate` in that file is not reached
        self.assertEqual(row["helper_sites"], "testClient_sites:1")

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
        self.assertEqual(sum(int(pure[c]) for c in inventory.COUNT_COLUMNS), 0)
        self.assertEqual(pure["helper_sites"], "")

    def test_tier_lists_are_disjoint_with_runtime_precedence(self):
        rows = list(self.rows.values()) + [{
            "suite": "TaggedTests", "traits": ".tags(.ui)", "tests": 1,
            **{c: 0 for c in inventory.COUNT_COLUMNS},
        }]
        runtime, ui = inventory.tier_lists(rows, "whitenoise-iosTests")
        self.assertEqual(runtime, ["whitenoise-iosTests/FactoryTests", "whitenoise-iosTests/HarnessTests",
                                   "whitenoise-iosTests/RuntimeTests"])
        self.assertEqual(ui, ["whitenoise-iosTests/LayoutTests", "whitenoise-iosTests/TaggedTests"])

    def test_rules(self):
        rows = list(self.rows.values())
        self.assertEqual(inventory.parse_rule("testClient-requires-tag=runtime"), ("testClient_sites", "requires-tag", "runtime"))
        self.assertEqual(inventory.parse_rule("sleep_sites-max=0"), ("sleep_sites", "max", 0))
        for bad in ("bogus-requires-tag=x", "testClient=runtime", "sleep-max=abc"):
            with self.assertRaises(ValueError):
                inventory.parse_rule(bad)
        violations = inventory.check_rules(rows, [inventory.parse_rule("testClient-requires-tag=runtime")])
        self.assertEqual(sorted(v.split(":")[0] for v in violations), ["FactoryTests", "HarnessTests"])
        violations = inventory.check_rules(rows, [inventory.parse_rule("ui_hosting-requires-tag=ui"),
                                                  inventory.parse_rule("sleep-max=1"),
                                                  inventory.parse_rule("testClient-requires-trait=timeLimit")])
        self.assertTrue(any(v.startswith("LayoutTests: ui_hosting=3") for v in violations))
        self.assertTrue(any(v.startswith("RuntimeTests: sleep_sites=5") for v in violations))
        self.assertTrue(any(v.startswith("HarnessTests: testClient_sites=1 but suite lacks .timeLimit") for v in violations))
        self.assertFalse(any(v.startswith("RuntimeTests: testClient_sites") for v in violations))

    def test_main_writes_csv_tier_lists_and_exit_code(self):
        with tempfile.TemporaryDirectory() as out_root:
            out = pathlib.Path(out_root) / "audit" / "inventory.csv"
            code = inventory.main(["--tests-dir", str(self.tests_dir), "--out", str(out), "--emit-tier-lists",
                                   "--rule", "sleep-max=9"])
            self.assertEqual(code, 0)
            with out.open(newline="") as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual([r["suite"] for r in rows],
                             ["FactoryTests", "HarnessTests", "LayoutTests", "PureTests", "RuntimeTests"])
            self.assertEqual(list(rows[0]), inventory.COLUMNS)
            self.assertEqual((out.parent / "tier-ui.txt").read_text(), "whitenoise-iosTests/LayoutTests\n")
            self.assertEqual(len((out.parent / "tier-runtime.txt").read_text().splitlines()), 3)
            code = inventory.main(["--tests-dir", str(self.tests_dir), "--out", str(out),
                                   "--rule", "ui_hosting-requires-tag=ui"])
            self.assertEqual(code, 1)
            with self.assertRaises(SystemExit):
                inventory.main(["--tests-dir", str(self.tests_dir), "--out", str(out), "--rule", "sleep-max=abc"])


WAIT_HELPERS_FILE = '''import Foundation

final class TestLatch: Sendable {
    func wait(timeout: Duration = .seconds(30)) async throws {
        Task { try? await Task.sleep(for: timeout) }
    }
}

func eventually(timeout: Duration = .seconds(30), _ condition: () async throws -> Bool) async throws {
    while true {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func pauseBriefly() async throws {
    try await Task.sleep(for: .milliseconds(50))
}
'''

WAITING_SUITES = '''import Testing

struct LatchTests {
    @Test func waits() async throws {
        let latch = TestLatch()
        try await latch.wait()
        try await eventually { true }
    }
}

struct PausingTests {
    @Test func pauses() async throws {
        try await pauseBriefly()
    }
}
'''


class BoundedWaitHelperTests(unittest.TestCase):
    def rows(self, files):
        with tempfile.TemporaryDirectory() as root:
            tests_dir = pathlib.Path(root) / "whitenoise-iosTests"
            audit_support.write_tree(tests_dir, files)
            return {row["suite"]: row for row in inventory.build_rows(str(tests_dir))}

    def test_testsupport_wait_helpers_do_not_count_as_sleep_sites(self):
        rows = self.rows({"TestSupport/TestLatch.swift": WAIT_HELPERS_FILE, "WaitingTests.swift": WAITING_SUITES})
        latch = rows["LatchTests"]
        self.assertEqual(latch["sleep_sites"], 0)
        self.assertEqual(latch["poll_loops"], 1)  # eventually still polls, boundedly
        self.assertEqual(rows["PausingTests"]["sleep_sites"], 1)  # other TestSupport sleeps still count

    def test_the_exemption_needs_the_testsupport_directory(self):
        rows = self.rows({"Waits.swift": WAIT_HELPERS_FILE, "WaitingTests.swift": WAITING_SUITES})
        self.assertEqual(rows["LatchTests"]["sleep_sites"], 2)


if __name__ == "__main__":
    unittest.main()
