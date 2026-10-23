"""Fixture tests for the guardrails behind `inventory.py --check`: each rule
has a fixture that must fail and the allowed shapes that must pass."""
import contextlib
import io
import json
import pathlib
import tempfile
import unittest

import audit_support

inventory = audit_support.load("inventory")

TEST_SUPPORT = {
    "TestSupport/MarmotTestClient.swift": '''extension MarmotClient {
    static func testClient() throws -> MarmotClient { try MarmotClient(rootPath: "/tmp") }
}
func withTestClient<T>(_ body: (MarmotClient) async throws -> T) async throws -> T {
    let client = try MarmotClient.testClient()
    return try await body(client)
}
func closing<T>(_ client: MarmotClient, _ body: () async throws -> T) async throws -> T { try await body() }
final class TestRuntimeScope {
    static func own(_ client: MarmotClient) throws -> MarmotClient { client }
}
''',
    "TestSupport/TestLatch.swift": '''func eventually(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(5)) }
}
func settleBriefly() async throws {
    try await Task.sleep(for: .milliseconds(5))
}
''',
}


def plan(skipped=()):
    return {"testTargets": [{"skippedTags": {"tags": ["runtime", "uiHosting"]},
                             "skippedTests": list(skipped), "target": {"name": "whitenoise-iosTests"}}]}


class GuardrailTests(unittest.TestCase):
    def check(self, files, skipped=(), baseline=""):
        """(exit code, printed lines) of `inventory.py --check` over a fixture tree."""
        with tempfile.TemporaryDirectory() as root:
            root = pathlib.Path(root)
            tests_dir = root / "whitenoise-iosTests"
            audit_support.write_tree(tests_dir, dict(TEST_SUPPORT, **files))
            (root / "PR.xctestplan").write_text(json.dumps(plan(skipped)), encoding="utf-8")
            (root / "baseline.txt").write_text(baseline, encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = inventory.main(["--tests-dir", str(tests_dir), "--out", str(root / "inventory.csv"),
                                       "--check", "--pr-plan", str(root / "PR.xctestplan"),
                                       "--baseline", str(root / "baseline.txt")])
            return code, out.getvalue().splitlines()

    def assertFails(self, files, rule, suite, skipped=()):
        code, lines = self.check(files, skipped)
        self.assertEqual(code, 1, lines)
        self.assertTrue(any(line.startswith("error: ") and " %s %s:" % (rule, suite) in line for line in lines), lines)

    def assertPasses(self, files, skipped=()):
        code, lines = self.check(files, skipped)
        self.assertEqual(code, 0, lines)

    # runtime-tag

    def test_untagged_runtime_test_fails(self):
        self.assertFails({"ATests.swift": '''@Suite struct ATests {
    @Test func opens() async throws {
        try await withTestClient { client in _ = client }
    }
}
'''}, "runtime-tag", "ATests")

    def test_runtime_through_a_helper_fails(self):
        self.assertFails({"ATests.swift": '''struct ATests {
    @Test func opens() throws { _ = try makeState() }
    private func makeState() throws -> AppState {
        AppState.test(client: try TestRuntimeScope.own(MarmotClient.testClient()))
    }
}
'''}, "runtime-tag", "ATests")

    def test_runtime_tag_on_the_test_or_the_suite_passes(self):
        self.assertPasses({"ATests.swift": '''struct ATests {
    @Test(.tags(.runtime), .marmotRuntimeConcurrencyLimit)
    func opens() async throws {
        try await withTestClient { client in _ = client }
    }
    @Test func pure() { #expect(true) }
}

@Suite(.tags(.runtime))
struct BTests {
    @Test func opens() async throws {
        try await withTestClient { client in _ = client }
    }
}
'''}, skipped=["ATests/opens()", "BTests"])

    def test_suite_wide_runtime_needs_the_suite_tag(self):
        self.assertFails({"ATests.swift": '''struct ATests {
    let owner = try! OwnedTestClient()
    @Test(.tags(.runtime)) func usesIt() { _ = owner }
    @Test func pure() { #expect(true) }
}
'''}, "runtime-tag", "ATests")

    # ui-tag

    def test_untagged_hosting_fails_but_image_renderer_passes(self):
        self.assertFails({"ATests.swift": '''@MainActor struct ATests {
    @Test func hosts() {
        let controller = UIHostingController(rootView: Text("x"))
        _ = controller
    }
}
'''}, "ui-tag", "ATests")
        self.assertPasses({"BTests.swift": '''@MainActor struct BTests {
    @Test func renders() { _ = ImageRenderer(content: Text("x")).uiImage }
}
'''})

    def test_hosting_xctest_class_must_be_skipped_by_the_pr_plan(self):
        files = {"LayoutTests.swift": '''import XCTest
final class LayoutTests: XCTestCase {
    func testHosts() { let window = UIWindow(); window.makeKeyAndVisible() }
}
'''}
        self.assertFails(files, "ui-tag", "LayoutTests")
        self.assertPasses(files, skipped=["LayoutTests"])

    # sleep

    def test_fixed_sleep_in_a_suite_or_its_own_helper_fails(self):
        self.assertFails({"ATests.swift": '''struct ATests {
    @Test func waits() async throws { try await Task.sleep(for: .milliseconds(10)) }
}
'''}, "sleep", "ATests")
        self.assertFails({"ATests.swift": '''struct ATests {
    @Test func waits() async throws { try await pause() }
}
''', "Helpers.swift": '''func pause() async throws { try await Task.sleep(for: .milliseconds(10)) }
'''}, "sleep", "ATests")

    def test_named_wait_helpers_may_sleep(self):
        self.assertPasses({"ATests.swift": '''struct ATests {
    @Test func waits() async throws {
        try await eventually { true }
    }
}
'''})

    def test_a_new_testsupport_helper_that_sleeps_fails(self):
        self.assertFails({"ATests.swift": '''struct ATests {
    @Test func waits() async throws {
        try await settleBriefly()
    }
}
'''}, "sleep", "ATests")

    def test_bootstrap_counts_as_opening_a_runtime(self):
        self.assertFails({"ATests.swift": '''@MainActor struct ATests {
    @Test func boots() async {
        let state = AppState.test()
        await state.bootstrap()
    }
}
'''}, "runtime-tag", "ATests")

    def test_a_tag_on_a_nested_suite_covers_its_tests_and_the_plan(self):
        files = {"OuterTests.swift": '''struct OuterTests {
    @Suite(.tags(.runtime))
    struct Booting {
        @Test func boots() async throws {
            try await withTestClient { client in _ = client }
        }
    }
    @Test func pure() {}
}
'''}
        self.assertFails(files, "pr-plan", "OuterTests")
        self.assertPasses(files, skipped=["OuterTests/Booting"])

    # unowned-runtime

    def test_direct_runtime_without_an_owner_fails(self):
        self.assertFails({"ATests.swift": '''@Suite(.tags(.runtime))
struct ATests {
    @Test func opens() throws {
        let client = try MarmotClient.testClient()
        _ = client
    }
}
'''}, "unowned-runtime", "ATests")

    def test_owned_runtimes_pass(self):
        self.assertPasses({"ATests.swift": '''@Suite(.tags(.runtime))
struct ATests {
    @Test func scoped() throws {
        let state = AppState.test(client: try TestRuntimeScope.own(MarmotClient.testClient()))
        _ = state
    }
    @Test func reopened() async throws {
        let reopened = try MarmotClient(rootPath: "/tmp", relayUrls: [])
        try await closing(reopened) { _ = reopened }
    }
    @Test func helper() async throws {
        try await withTestClient { client in _ = client }
    }
}
'''}, skipped=["ATests"])

    # timelimit-gate

    def test_time_limit_under_the_gate_fails(self):
        self.assertFails({"ATests.swift": '''@Suite(.tags(.runtime), .marmotRuntimeConcurrencyLimit)
struct ATests {
    @Test(.timeLimit(.minutes(1))) func bounded() async throws {
        try await withTestClient { client in _ = client }
    }
}
'''}, "timelimit-gate", "ATests")
        self.assertFails({"BTests.swift": '''@Suite(.timeLimit(.minutes(1)), .marmotRuntimeConcurrencyLimit)
struct BTests {
    @Test func plain() {}
}
'''}, "timelimit-gate", "BTests")

    def test_time_limit_without_the_gate_passes(self):
        self.assertPasses({"ATests.swift": '''@Suite(.timeLimit(.minutes(1)))
struct ATests {
    @Test func plain() {}
}
'''})

    # pr-plan

    def test_pr_plan_must_skip_exactly_the_tagged_tests(self):
        files = {"ATests.swift": '''struct ATests {
    @Test(.tags(.uiHosting)) func hosts() {}
    @Test func pure() {}
}
''', "LayoutTests.swift": '''import XCTest
final class LayoutTests: XCTestCase {
    func testRendersOffscreen() {}
}
'''}
        self.assertFails(files, "pr-plan", "ATests")
        self.assertFails(files, "pr-plan", "ATests", skipped=["ATests"])  # would skip the pure test too
        self.assertPasses(files, skipped=["ATests/hosts()", "LayoutTests"])  # extra XCTest classes are allowed

    def test_write_pr_plan_regenerates_the_skips(self):
        with tempfile.TemporaryDirectory() as root:
            root = pathlib.Path(root)
            tests_dir = audit_support.write_tree(root / "whitenoise-iosTests", dict(TEST_SUPPORT, **{
                "ATests.swift": "@Suite(.tags(.runtime)) struct ATests {\n    @Test func a() {}\n}\n",
                "BTests.swift": "struct BTests {\n    @Test(.tags(.uiHosting)) func b(_ value: Int) {}\n}\n",
                "LayoutTests.swift": "import XCTest\nfinal class LayoutTests: XCTestCase {\n"
                                     "    func testHosts() { _ = UIWindow() }\n}\n",
            }))
            plan_path = root / "PR.xctestplan"
            plan_path.write_text(json.dumps(plan(["Stale/old()"])), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                inventory.main(["--tests-dir", str(tests_dir), "--out", str(root / "inventory.csv"),
                                "--pr-plan", str(plan_path), "--write-pr-plan"])
            skipped = json.loads(plan_path.read_text())["testTargets"][0]["skippedTests"]
            self.assertEqual(skipped, ["LayoutTests", "ATests", "BTests/b(_:)"])

    # baseline

    TWO_SLEEPS = {"ATests.swift": '''struct ATests {
    @Test func waits() async throws {
        try await Task.sleep(for: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(10))
    }
}
'''}

    def test_a_violation_at_its_baseline_count_passes(self):
        code, lines = self.check(self.TWO_SLEEPS, baseline="# known\nsleep ATests 2\n")
        self.assertEqual(code, 0, lines)
        self.assertTrue(any(line.startswith("baselined: sleep ATests:") for line in lines), lines)

    def test_a_count_above_the_baseline_fails(self):
        code, lines = self.check(self.TWO_SLEEPS, baseline="sleep ATests 1\n")
        self.assertEqual(code, 1, lines)
        self.assertTrue(any("count 2 exceeds baseline 1" in line for line in lines), lines)

    def test_a_count_below_the_baseline_fails_until_the_line_is_lowered(self):
        code, lines = self.check(self.TWO_SLEEPS, baseline="sleep ATests 3\n")
        self.assertEqual(code, 1, lines)
        self.assertTrue(any("lower the baseline line to 2" in line for line in lines), lines)

    def test_a_stale_baseline_line_fails(self):
        code, lines = self.check(self.TWO_SLEEPS, baseline="sleep ATests 2\nsleep GoneTests 1\n")
        self.assertEqual(code, 1, lines)
        self.assertTrue(any(line.startswith("error: stale baseline line") and "sleep GoneTests 1" in line
                            for line in lines), lines)

    def test_a_malformed_baseline_line_is_a_clear_error(self):
        for bad in ("sleep ATests\n", "nap ATests 2\n", "sleep ATests two\n", "sleep ATests 2\nsleep ATests 2\n"):
            code, lines = self.check(self.TWO_SLEEPS, baseline=bad)
            self.assertEqual(code, 2, (bad, lines))
            self.assertTrue(any(line.startswith("error: ") and "baseline.txt:" in line for line in lines), lines)

    def test_write_baseline_records_counts(self):
        with tempfile.TemporaryDirectory() as root:
            root = pathlib.Path(root)
            tests_dir = audit_support.write_tree(root / "whitenoise-iosTests", dict(TEST_SUPPORT, **self.TWO_SLEEPS))
            (root / "PR.xctestplan").write_text(json.dumps(plan()), encoding="utf-8")
            baseline = root / "baseline.txt"
            with contextlib.redirect_stdout(io.StringIO()):
                code = inventory.main(["--tests-dir", str(tests_dir), "--out", str(root / "inventory.csv"),
                                       "--pr-plan", str(root / "PR.xctestplan"), "--baseline", str(baseline),
                                       "--write-baseline", "--check"])
            self.assertEqual(code, 0)
            self.assertIn("sleep ATests 2\n", baseline.read_text())


if __name__ == "__main__":
    unittest.main()
