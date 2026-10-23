import importlib.util
import os
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name):
    path = ROOT / "scripts" / "audit" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").replace(".py", ""), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


serial = load("serial-costs.py")
costs = load("per-file-costs.py")
names = load("suite-names.py")

LOG = """2026-10-23T00:50:53 Test Suite 'All tests' started at 2026-10-23 00:50:53.335.
2026-10-23T00:50:53 Test Suite 'whitenoise-iosTests.xctest' started at 2026-10-23 00:50:53.336.
2026-10-23T00:50:53 Test Suite 'AccountExitSheetTests' started at 2026-10-23 00:50:53.336.
2026-10-23T00:50:58 Test Suite 'AccountExitSheetTests' passed at 2026-10-23 00:50:58.995.
2026-10-23T00:51:20 \x1b[32m✔\x1b[0m Suite FooTests passed after 1.250 seconds.
2026-10-23T00:51:21 ✔ Suite "Media viewer presentation" passed after 0.400 seconds.
2026-10-23T00:51:22 ✔ Suite BarTests with 2 known issues passed after 2.000 seconds.
2026-10-23T00:51:23 ✘ Suite BazTests failed after 0.100 seconds with 1 issue.
"""


class SuiteWallsTests(unittest.TestCase):
    def test_swift_testing_xctest_display_names_and_known_issues(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
            fh.write(LOG)
            path = fh.name
        try:
            walls = serial.suite_walls_from_log(path)
        finally:
            os.unlink(path)
        self.assertAlmostEqual(walls["FooTests"], 1.25)
        self.assertAlmostEqual(walls["Media viewer presentation"], 0.4)
        self.assertAlmostEqual(walls["BarTests"], 2.0)
        self.assertAlmostEqual(walls["BazTests"], 0.1)
        self.assertAlmostEqual(walls["AccountExitSheetTests"], 5.659)
        self.assertNotIn("All tests", walls)
        self.assertNotIn("whitenoise-iosTests.xctest", walls)


class LastMarkerTests(unittest.TestCase):
    def test_rerun_appends_marker_and_last_one_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "Foo.log")
            with open(log, "w") as fh:
                fh.write("x ==> Foo: 41s status=0\n")
                fh.write("y ==> Foo: 9s status=65\n")
            self.assertEqual(costs.wall_from_log(log), (9, 65))


class DisplayNameTests(unittest.TestCase):
    def test_display_name_read_from_raw_source(self):
        source = 'import Testing\n\n@Suite("Media viewer presentation")\nstruct MediaViewerPresentationTests {\n    @Test func a() {}\n}\n'
        masked = names.swiftscan.mask(source)
        with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as fh:
            fh.write(source)
            path = fh.name
        try:
            suites = names.swiftscan.suites_in_file(path, masked)
        finally:
            os.unlink(path)
        self.assertEqual([s.name for s in suites], ["MediaViewerPresentationTests"])
        self.assertEqual(names.display_name(suites[0].declaration, masked), "Media viewer presentation")

    def test_nonisolated_struct_is_a_suite(self):
        source = "import Testing\n\nnonisolated struct AppLaunchPolicyTests {\n    @Test func a() {}\n}\n"
        with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as fh:
            fh.write(source)
            path = fh.name
        try:
            suites = names.swiftscan.suites_in_file(path)
        finally:
            os.unlink(path)
        self.assertEqual([s.name for s in suites], ["AppLaunchPolicyTests"])
        self.assertIsNone(names.display_name(suites[0].declaration, names.swiftscan.mask(source)))


if __name__ == "__main__":
    unittest.main()
