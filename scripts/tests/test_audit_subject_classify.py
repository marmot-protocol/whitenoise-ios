import csv
import pathlib
import tempfile
import unittest

import audit_support

classify = audit_support.load("subject-classify")
inventory = audit_support.load("inventory")

APP_SOURCES = {
    "whitenoise-ios/Core/AppThing.swift": (
        "struct AppThing {\n    static let limit = 3\n    func run() -> Int { 1 }\n"
        "    override class var layerClass: AnyClass { Layer.self }\n}\n"
        "nonisolated enum BrowseState { case idle\n    static func resolve() -> BrowseState { .idle } }\n"
        "func appFreeFunction() {}\n"
    ),
    "Shared/L10n.swift": "enum L10n {\n    static func string(_ key: String) -> String { key }\n}\n",
}
MDK_SOURCES = {
    "Packages/MarmotKit/Sources/MarmotKit/MarmotKit.swift": (
        "public struct RecordFfi {\n    public var id: String\n}\n"
        "public class Marmot {\n    public func listAccounts() -> [RecordFfi] { [] }\n"
        "    public func run() {}\n}\n"
        "public func generateKeypair() -> String { \"\" }\n"
    ),
}
TEST_SOURCES = {
    "whitenoise-iosTests/Support.swift": (
        "final class Stub {\n    var calls = 0\n}\n"
        "func makeThing() -> AppThing { AppThing() }\n"
        "extension AppThing {\n    static func test() -> AppThing { AppThing() }\n}\n"
    ),
    "whitenoise-iosTests/ThingTests.swift": (
        "struct ThingTests {\n"
        "    private typealias State = BrowseState\n"
        "    private static let shared = State.resolve()\n"
        "    private func state() -> State { .resolve() }\n"
        "    @Test func viaAlias() { #expect(Self.shared == .idle) }\n"
        "    @Test func direct() { #expect(AppThing().run() == 1) }\n"
        "    @Test func viaHelper() { let t = makeThing(); #expect(t.run() == 1) }\n"
        "    @Test func viaMember() { let t = AppThing.test(); #expect(t.run() == 1) }\n"
        "    @Test func viaSignature() { #expect(state() == .idle) }\n"
        "    @Test func mdk() { let r = RecordFfi(id: \"a\"); let m = Marmot(); #expect(m.listAccounts().isEmpty); _ = generateKeypair() }\n"
        "    @Test func mdkRun() { let m = Marmot(); m.run(); #expect(true) }\n"
        "    @Test func helperOnly() { let s = Stub(); s.calls += 1; #expect(s.calls == 1) }\n"
        "    @Test func platform() { let d = Date(); var x = 1; x += 1; #expect(d.timeIntervalSince1970 > 0) }\n"
        "    @Test func catalog() { let url = Bundle.main.url(forResource: \"Localizable\", withExtension: \"xcstrings\"); #expect(url != nil) }\n"
        "    @Test func catalogText() { let path = \"Shared/Localizable.xcstrings\"; #expect(!path.isEmpty) }\n"
        "}\n"
    ),
}


class ClassifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.temp.name)
        audit_support.write_tree(root, {**APP_SOURCES, **MDK_SOURCES, **TEST_SOURCES})
        cls.root = root
        cls.tests_dir = root / "whitenoise-iosTests"
        suites, masks = classify.swiftscan.collect_suites(cls.tests_dir)
        suite_names = {s.name for s in suites}
        app_dirs = [str(root / "whitenoise-ios"), str(root / "Shared")]
        mdk_dir = str(root / "Packages/MarmotKit")
        cls.classifier = classify.Classifier(
            classify.names_in_dirs(app_dirs), classify.names_in_dirs([mdk_dir]),
            classify.helper_names(masks, suite_names), classify.helper_bodies(masks, suite_names),
            classify.func_names_in_dirs([mdk_dir]) - classify.func_names_in_dirs(app_dirs))
        cls.rows = {row["test"]: row for row in classify.classify_tests(suites, cls.classifier)}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_identifier_sets(self):
        self.assertIn("AppThing", self.classifier.app)
        self.assertIn("BrowseState", self.classifier.app)
        self.assertIn("appFreeFunction", self.classifier.app)
        self.assertNotIn("var", self.classifier.app)
        self.assertIn("RecordFfi", self.classifier.mdk)
        self.assertIn("listAccounts", self.classifier.mdk_calls)
        self.assertIn("generateKeypair", self.classifier.mdk_calls)
        self.assertNotIn("run", self.classifier.mdk_calls)  # also declared by the app
        self.assertEqual(self.classifier.helper, {"Stub"})

    def test_subjects(self):
        expected = {
            "direct()": "app", "viaHelper()": "app", "viaMember()": "app", "viaSignature()": "app",
            "viaAlias()": "app",
            "mdk()": "mdk", "mdkRun()": "platform", "helperOnly()": "test-helper",
            "platform()": "platform", "catalog()": "catalog", "catalogText()": "catalog",
        }
        self.assertEqual({name: self.rows[name]["subject"] for name in expected}, expected)
        self.assertEqual(self.rows["mdk()"]["mdk_refs"], 2)
        self.assertEqual(self.rows["viaHelper()"]["app_refs"], 2)
        self.assertEqual(self.rows["helperOnly()"]["helper_refs"], 1)

    def test_rollup_prefers_app_on_ties_and_reports_mix(self):
        rolled = classify.rollup([
            {"suite": "S", "subject": "mdk"}, {"suite": "S", "subject": "app"},
            {"suite": "T", "subject": "test-helper"}, {"suite": "T", "subject": "test-helper"},
            {"suite": "T", "subject": "platform"},
        ])
        self.assertEqual(rolled["S"], ("app", "app:1;mdk:1"))
        self.assertEqual(rolled["T"], ("test-helper", "test-helper:2;platform:1"))

    def test_main_writes_csv_and_merges_into_inventory(self):
        with tempfile.TemporaryDirectory() as out_root:
            out_dir = pathlib.Path(out_root)
            inv = out_dir / "inventory.csv"
            inventory.main(["--tests-dir", str(self.tests_dir), "--out", str(inv)])
            code = classify.main([
                "--tests-dir", str(self.tests_dir), "--app-dir", str(self.root / "whitenoise-ios"),
                "--app-dir", str(self.root / "Shared"), "--mdk-dir", str(self.root / "Packages/MarmotKit"),
                "--out", str(out_dir / "subjects.csv"), "--inventory", str(inv), "--merge"])
            self.assertEqual(code, 0)
            with (out_dir / "subjects.csv").open(newline="") as handle:
                subjects = list(csv.DictReader(handle))
            self.assertEqual(list(subjects[0]), classify.COLUMNS)
            self.assertEqual(len(subjects), 11)
            with inv.open(newline="") as handle:
                merged = list(csv.DictReader(handle))
            self.assertEqual(merged[0]["suite"], "ThingTests")
            self.assertEqual(merged[0]["subject"], "app")
            self.assertEqual(merged[0]["subject_mix"], "app:5;mdk:1;test-helper:1;catalog:2;platform:2")
            self.assertEqual(merged[0]["tests"], "11")
            code = classify.main(["--tests-dir", str(self.tests_dir), "--app-dir", str(self.root / "Shared"),
                                  "--mdk-dir", str(self.root / "Packages/MarmotKit"),
                                  "--out", str(out_dir / "s2.csv"), "--inventory", str(out_dir / "missing.csv"), "--merge"])
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
