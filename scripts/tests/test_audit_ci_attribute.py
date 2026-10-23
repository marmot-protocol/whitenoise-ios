import contextlib
import csv
import importlib.util
import io
import json
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


ci = load("ci-attribute.py")
METHODS = {"testDeletionReportStaysVisible": "AccountExitSheetTests"}

CRASH_LOG = """x\tRun tests\t2026-10-20T18:16:40Z Test Suite 'All tests' started at 2026-10-20 18:15:12.219.
x\tRun tests\t2026-10-20T18:16:41Z Test Suite 'AccountExitSheetTests' started at 2026-10-20 18:15:12.220.
x\tRun tests\t2026-10-20T18:16:41Z Test Suite 'Selected tests' started at 2026-10-20 18:15:52.646.
x\tRun tests\t2026-10-20T18:16:41Z Test Suite 'AccountExitSheetTests' started at 2026-10-20 18:15:52.647.
x\tRun tests\t2026-10-20T18:16:41Z Test Suite 'Selected tests' started at 2026-10-20 18:16:10.825.
x\tRun tests\t2026-10-20T18:16:41Z Test Suite 'ControlLayoutTests' started at 2026-10-20 18:16:12.494.
x\tRun tests\t2026-10-20T18:16:41Z \tExecuted 2 tests, with 0 failures (0 unexpected) in 5.483 (5.484) seconds
x\tRun tests\t2026-10-20T18:22:53Z ** TEST EXECUTE FAILED **
"""

FAIL_LOG = """x\t2026-10-22T12:26:59Z ##[error]    testDeletionReportStaysVisible, failed: caught error: "InvalidTransition"
x\t2026-10-22T12:37:04Z \x1b[31m✘\x1b[0m Suite PrivateKeyAutoFillTests failed after 99.656 seconds with 1 issue(s)
x\t2026-10-22T12:37:05Z ✘ Suite "Media viewer presentation" failed after 1.000 seconds with 1 issue.
x\t2026-10-22T12:38:00Z ** TEST EXECUTE FAILED **
"""

BUILD_LOG = """x\t2026-10-21T10:00:00Z error: cannot find 'Foo' in scope
x\t2026-10-21T10:00:01Z ** TEST BUILD FAILED **
"""

STARTUP_CRASH_LOG = """x\t2026-10-22T20:00:22Z \twhitenoise-ios (38192) encountered an error (Early unexpected exit, operation never finished bootstrapping - no restart will be attempted.
x\t2026-10-22T20:00:22Z ** TEST EXECUTE FAILED **
"""


class AttributeTests(unittest.TestCase):
    def test_restart_after_class_start_is_a_crash_in_that_class(self):
        kind, suites = ci.attribute(CRASH_LOG, METHODS)
        self.assertEqual(suites, {"AccountExitSheetTests": "crashed"})
        self.assertEqual(kind, "host-crash")

    def test_swift_testing_and_xctest_method_failures(self):
        kind, suites = ci.attribute(FAIL_LOG, METHODS)
        self.assertEqual(kind, "test-failure")
        self.assertEqual(suites, {"AccountExitSheetTests": "failed", "PrivateKeyAutoFillTests": "failed",
                                  "Media viewer presentation": "failed"})

    def test_build_failure_is_not_attributed(self):
        kind, suites = ci.attribute(BUILD_LOG, METHODS)
        self.assertEqual((kind, suites), ("build-failure", {}))

    def test_startup_crash_without_a_running_class_is_execute_failure(self):
        kind, suites = ci.attribute(STARTUP_CRASH_LOG, METHODS)
        self.assertEqual((kind, suites), ("execute-failure", {}))


class MainWindowTests(unittest.TestCase):
    def test_attributes_only_current_failed_runs_and_reports_missing_logs(self):
        with tempfile.TemporaryDirectory() as out:
            runs = [
                {"databaseId": 1, "conclusion": "failure", "event": "push", "headBranch": "master"},
                {"databaseId": 2, "conclusion": "failure", "event": "pull_request", "headBranch": "feature"},
                {"databaseId": 3, "conclusion": "success", "event": "push", "headBranch": "master"},
            ]
            with open(os.path.join(out, "ci-runs.json"), "w") as fh:
                json.dump(runs, fh)
            os.makedirs(os.path.join(out, "ci-logs"))
            for run_id in ("1", "99"):  # 99 is a stale log from an older window
                with open(os.path.join(out, "ci-logs", run_id + ".log"), "w") as fh:
                    fh.write(FAIL_LOG)
            with contextlib.redirect_stdout(io.StringIO()):
                ci.main(["--out-dir", out, "--tests-dir", os.path.join(out, "no-tests")])
            with open(os.path.join(out, "ci-history.csv"), newline="") as fh:
                history = list(csv.DictReader(fh))
            with open(os.path.join(out, "ci-unattributed.csv"), newline="") as fh:
                unattributed = list(csv.DictReader(fh))
        self.assertEqual({row["runs"] for row in history}, {"1"})
        self.assertEqual([(r["run_id"], r["kind"]) for r in unattributed], [("2", "log-unavailable")])


if __name__ == "__main__":
    unittest.main()
