import csv
import pathlib
import tempfile
import unittest

import audit_support

classify = audit_support.load("subject-classify")
inventory = audit_support.load("inventory")

APP_SOURCES = {
    "whitenoise-ios/Core/AppThing.swift": (
        "struct AppThing {\n    static let limit = 3\n    func run() -> Int { 1 }\n    func contains(_ x: Int) -> Bool { true }\n"
        "    override class var layerClass: AnyClass { Layer.self }\n}\n"
        "nonisolated enum BrowseState { case idle\n    static func resolve() -> BrowseState { .idle } }\n"
        "enum Connector { case claude\n    func prompt() -> String { \"\" } }\n"
        "func appFreeFunction() {}\n"
        "extension MarmotKitError {\n    var isTransientStartupReadinessFailure: Bool { true }\n    var label: String { \"\" }\n}\n"
        "extension Marmot {\n    func createGroup(name: String) -> RecordFfi { createGroup(name: name, options: nil) }\n}\n"
    ),
    "Shared/L10n.swift": "enum L10n {\n    static func string(_ key: String) -> String { key }\n}\n",
}
MDK_SOURCES = {
    "Packages/MarmotKit/Sources/MarmotKit/MarmotKit.swift": (
        "public struct RecordFfi {\n    public var id: String\n    public var label: String\n}\n"
        "public enum MarmotKitError: Error {\n    case RuntimeBusy\n}\n"
        "public class Marmot {\n    public func listAccounts() -> [RecordFfi] { [] }\n"
        "    public func createGroup(name: String, options: Int?) -> RecordFfi { RecordFfi(id: \"\", label: \"\") }\n"
        "    public func shutdown() {}\n    public func run() {}\n}\n"
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
        "    @Test func direct() { #expect(AppThing().run() == 1) }\n"
        "    @Test func viaHelper() { let t = makeThing(); #expect(t.run() == 1) }\n"
        "    @Test func viaMember() { let t = AppThing.test(); #expect(t.run() == 1) }\n"
        "    @Test func viaSignature() { #expect(state() == .idle) }\n"
        "    @Test func viaAlias() { #expect(Self.shared == .idle) }\n"
        "    @Test func viaExtensionMember() { #expect(MarmotKitError.RuntimeBusy.isTransientStartupReadinessFailure) }\n"
        "    @Test(arguments: [(Connector.claude, \"claude\")])\n"
        "    func parameterised(connector: Connector, name: String) { #expect(connector.prompt().contains(name)) }\n"
        "    @Test func mdk() { let r = RecordFfi(id: \"a\", label: \"b\"); let m = Marmot(); #expect(m.listAccounts().isEmpty); _ = generateKeypair() }\n"
        "    @Test func mdkWrappedName() { let m = Marmot(); _ = m.createGroup(name: \"a\"); #expect(client.marmot.createGroup(name: \"b\").id == \"\") }\n"
        "    @Test func mdkRun() { let m = Marmot(); m.run(); #expect(true) }\n"
        "    @Test func viaDouble() { let h = try! SendHarness(); h.shutdown(); #expect(h.appState != nil) }\n"
        "    @Test func helperOnly() { let s = Stub(); s.calls += 1; #expect(s.calls == 1) }\n"
        "    @Test func platform() { let d = Date(); var x = [1]; x.append(2); #expect(d.timeIntervalSince1970 > 0 && x.contains(2)) }\n"
        "    @Test func catalog() { let url = Bundle.main.url(forResource: \"Localizable\", withExtension: \"xcstrings\"); #expect(url != nil) }\n"
        "    @Test func catalogText() { let path = \"Shared/Localizable.xcstrings\"; #expect(!path.isEmpty) }\n"
        "}\n"
        "private final class SendHarness {\n    let appState: AppThing\n    init() throws { appState = AppThing() }\n"
        "    func shutdown() {}\n}\n"
    ),
}

OWNED_SOURCES = {
    "whitenoise-iosTests/OwnedTests.swift": (
        "struct OwnedTests {\n"
        "    func makeSubject() -> AppThing { AppThing() }\n"
        "    @Test func viaExtensionHelper() { let t = sharedSubject(); #expect(t != nil) }\n"
        "}\n"
    ),
    "whitenoise-iosTests/OwnedTests+More.swift": (
        "extension OwnedTests {\n"
        "    func sharedSubject() -> AppThing { AppThing() }\n"
        "    @Test func viaBodyHelper() { let t = makeSubject(); #expect(t != nil) }\n"
        "}\n"
    ),
    "whitenoise-iosTests/OtherTests.swift": (
        "struct OtherTests {\n"
        "    @Test func sameNames() { let a = sharedSubject(); let b = makeSubject(); #expect(a == b) }\n"
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
        app_dirs = [str(root / "whitenoise-ios"), str(root / "Shared")]
        suites, cls.classifier = classify.build_classifier(str(cls.tests_dir), app_dirs, str(root / "Packages/MarmotKit"))
        cls.rows = {row["test"]: row for row in classify.classify_tests(suites, cls.classifier)}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_identifier_sets(self):
        app = self.classifier.app
        self.assertTrue({"AppThing", "BrowseState", "Connector", "appFreeFunction", "isTransientStartupReadinessFailure"} <= app)
        self.assertNotIn("var", app)
        self.assertNotIn("contains", app)  # method inside a type body
        self.assertNotIn("label", app)  # extension member MDK also declares
        self.assertNotIn("createGroup", app)  # app wrapper over an MDK method
        self.assertIn("createGroup", self.classifier.mdk_funcs)
        self.assertIn("listAccounts", self.classifier.mdk_calls)
        self.assertIn("generateKeypair", self.classifier.mdk_calls)
        self.assertNotIn("run", self.classifier.mdk_calls)  # also declared by the app
        self.assertNotIn("shutdown", self.classifier.mdk_calls)  # also declared by a test double
        self.assertEqual(self.classifier.helper, {"Stub", "SendHarness"})

    def test_subjects(self):
        expected = {
            "direct()": "app", "viaHelper()": "app", "viaMember()": "app", "viaSignature()": "app",
            "viaAlias()": "app", "viaExtensionMember()": "app", "parameterised(connector:name:)": "app",
            "mdk()": "mdk", "mdkWrappedName()": "mdk", "mdkRun()": "platform", "viaDouble()": "app",
            "helperOnly()": "test-helper", "platform()": "platform", "catalog()": "catalog", "catalogText()": "catalog",
        }
        self.assertEqual({name: self.rows[name]["subject"] for name in expected}, expected)
        self.assertEqual(self.rows["mdk()"]["mdk_refs"], 2)
        self.assertEqual(self.rows["mdkWrappedName()"]["mdk_refs"], 1)  # only the marmot.-qualified call
        self.assertEqual(self.rows["viaHelper()"]["app_refs"], 2)
        self.assertGreaterEqual(self.rows["viaDouble()"]["helper_refs"], 1)
        self.assertGreaterEqual(self.rows["viaDouble()"]["app_refs"], 1)  # through the double's body
        self.assertGreaterEqual(self.rows["helperOnly()"]["helper_refs"], 1)
        self.assertEqual(self.rows["helperOnly()"]["app_refs"], 0)

    def test_suite_members_resolve_by_owning_suite_not_by_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            audit_support.write_tree(root, {**APP_SOURCES, **MDK_SOURCES, **OWNED_SOURCES})
            suites, classifier = classify.build_classifier(
                str(root / "whitenoise-iosTests"), [str(root / "whitenoise-ios")], str(root / "Packages/MarmotKit"))
            rows = {row["test"]: row["subject"] for row in classify.classify_tests(suites, classifier)}
        self.assertEqual(rows["viaBodyHelper()"], "app")  # body helper reached from an extension in another file
        self.assertEqual(rows["viaExtensionHelper()"], "app")  # extension helper reached from the suite body
        self.assertEqual(rows["sameNames()"], "platform")  # another suite's members do not leak

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
            self.assertEqual(len(subjects), 15)
            with inv.open(newline="") as handle:
                merged = list(csv.DictReader(handle))
            self.assertEqual(merged[0]["suite"], "ThingTests")
            self.assertEqual(merged[0]["subject"], "app")
            self.assertEqual(merged[0]["subject_mix"], "app:8;mdk:2;test-helper:1;catalog:2;platform:2")
            self.assertEqual(merged[0]["tests"], "15")
            code = classify.main(["--tests-dir", str(self.tests_dir), "--app-dir", str(self.root / "Shared"),
                                  "--mdk-dir", str(self.root / "Packages/MarmotKit"),
                                  "--out", str(out_dir / "s2.csv"), "--inventory", str(out_dir / "missing.csv"), "--merge"])
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
