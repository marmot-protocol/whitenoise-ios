"""Parse synthetic xcodebuild logs into test-run phases."""
import datetime
import importlib.util
import io
import pathlib
import tempfile
import unittest


script = pathlib.Path(__file__).resolve().parents[1] / "audit" / "phases.py"
spec = importlib.util.spec_from_file_location("audit_phases", script)
phases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phases)


TIMED_LOG = """\
2026-10-22T10:00:00 ==> build-for-testing: 767s
2026-10-22T10:00:05 Command line invocation:
2026-10-22T10:00:05     /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test-without-building -project whitenoise-ios.xcodeproj
2026-10-22T10:00:09 Testing started
2026-10-22T10:00:40 2026-10-22 10:00:40.500 xcodebuild[1:2] [MT] some unrelated noise
2026-10-22T10:07:10 Test Suite 'All tests' started at 2026-10-22 10:07:10.100.
2026-10-22T10:07:10 Test Suite 'whitenoise-iosTests.xctest' started at 2026-10-22 10:07:10.101.
2026-10-22T10:07:46 Test Suite 'All tests' passed at 2026-10-22 10:07:46.300.
2026-10-22T10:07:46 \t Executed 20 tests, with 0 failures (0 unexpected) in 36.1 (36.2) seconds
2026-10-22T10:08:20 ◇ Test run started.
2026-10-22T10:08:20 ◇ Suite SlowTests started.
2026-10-22T10:08:21 ✔ Suite FastTests passed after 0.393 seconds.
2026-10-22T10:08:25 ✔ Suite "Media viewer presentation" passed after 3.250 seconds.
2026-10-22T10:14:00 ✘ Suite SlowTests failed after 338.5 seconds with 1 issue.
2026-10-22T10:15:02 ✘ Test run with 2952 tests in 300 suites failed after 402.000 seconds with 1 issue.
2026-10-22T10:15:03 2026-10-22 10:15:03.000 xcodebuild[1:2] [MT] IDETestOperationsObserverDebug: 894.000 elapsed -- Testing started completed.
2026-10-22T10:15:03 2026-10-22 10:15:03.000 xcodebuild[1:2] [MT] IDETestOperationsObserverDebug: 894.000 sec, +894.000 sec -- end
2026-10-22T10:15:20 Test session results, code coverage, and logs:
2026-10-22T10:15:20 \t/Users/ci/build/TestResults.xcresult
2026-10-22T10:15:21 ** TEST EXECUTE FAILED **
2026-10-22T10:15:21 ==> test-without-building: 921s
"""

# Shape of build/scroll-test-stability/full-suite.log: no test.sh markers, no
# wall-clock prefixes, and `Testing started` printed last.
RAW_LOG = """\
Command line invocation:
    xcodebuild test-without-building -project whitenoise-ios.xcodeproj
Test Suite 'All tests' started at 2026-09-16 15:00:42.737.
Test Suite 'All tests' passed at 2026-09-16 15:00:42.739.
\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds
◇ Test run started.
✔ Suite AccountAttentionCreationTests passed after 0.393 seconds.
✔ Suite ChatRowStatusPresentationTests passed after 0.415 seconds.
✘ Test run with 2018 tests in 260 suites failed after 107.552 seconds with 5 issues.
2026-09-16 15:02:42.313 xcodebuild[42634:1861458] [MT] IDETestOperationsObserverDebug: 163.283 elapsed -- Testing started completed.
Test session results, code coverage, and logs:
\t/Users/dev/build/FullSuite.xcresult
** TEST EXECUTE FAILED **
Testing started
"""


def dt(text):
    return datetime.datetime.fromisoformat(text)


class ParseLogTests(unittest.TestCase):
    def test_timed_log_yields_every_marker(self):
        parsed = phases.parse_log(io.StringIO(TIMED_LOG))
        self.assertEqual(parsed["build_for_testing_s"], 767)
        self.assertEqual(parsed["test_without_building_s"], 921)
        self.assertEqual(parsed["build_end_at"], dt("2026-10-22T10:00:00"))
        self.assertEqual(parsed["first_line_at"], dt("2026-10-22T10:00:00"))
        self.assertEqual(parsed["testing_started_line_at"], dt("2026-10-22T10:00:09"))
        self.assertEqual(parsed["xctest_started_at"], dt("2026-10-22T10:07:10.100"))
        self.assertEqual(parsed["xctest_ended_at"], dt("2026-10-22T10:07:46.300"))
        self.assertEqual(parsed["swift_testing_started_at"], dt("2026-10-22T10:08:20"))
        self.assertEqual(parsed["swift_testing_end_line_at"], dt("2026-10-22T10:15:02"))
        self.assertEqual(parsed["swift_testing_s"], 402.0)
        self.assertEqual(parsed["swift_testing_tests"], 2952)
        self.assertEqual(parsed["swift_testing_suites"], 300)
        self.assertEqual(parsed["ide_elapsed_s"], 894.0)
        self.assertEqual(parsed["ide_line_at"], dt("2026-10-22T10:15:03"))
        self.assertEqual(parsed["session_results_at"], dt("2026-10-22T10:15:20"))
        self.assertEqual(
            parsed["suites"],
            [("FastTests", "passed", 0.393), ("Media viewer presentation", "passed", 3.25),
             ("SlowTests", "failed", 338.5)],
        )

    def test_raw_log_without_prefixes_keeps_clocks_and_suites(self):
        parsed = phases.parse_log(io.StringIO(RAW_LOG))
        self.assertIsNone(parsed["build_for_testing_s"])
        self.assertIsNone(parsed["first_line_at"])
        self.assertIsNone(parsed["testing_started_line_at"])
        self.assertIsNone(parsed["swift_testing_started_at"])
        self.assertEqual(parsed["xctest_started_at"], dt("2026-09-16T15:00:42.737"))
        self.assertEqual(parsed["swift_testing_s"], 107.552)
        self.assertEqual(parsed["ide_elapsed_s"], 163.283)
        self.assertEqual(len(parsed["suites"]), 2)

    def test_empty_log_has_no_markers(self):
        parsed = phases.parse_log([])
        self.assertTrue(all(value is None for key, value in parsed.items() if key != "suites"))
        self.assertEqual(parsed["suites"], [])


class ComputePhasesTests(unittest.TestCase):
    def test_timed_log_phases(self):
        row = phases.compute_phases(phases.parse_log(io.StringIO(TIMED_LOG)), run_id="t")
        self.assertEqual(row["run_id"], "t")
        self.assertEqual(row["build_for_testing_s"], 767)
        self.assertEqual(row["test_without_building_s"], 921)
        # No xcresult: back-date the IDE elapsed from its own clock.
        self.assertEqual(row["testing_started_at"], dt("2026-10-22T10:00:09"))
        self.assertEqual(row["first_xctest_suite_at"], dt("2026-10-22T10:07:10.100"))
        self.assertAlmostEqual(row["xctest_s"], 36.2)
        self.assertEqual(row["swift_testing_started_at"], dt("2026-10-22T10:08:20"))
        self.assertEqual(row["swift_testing_s"], 402.0)
        # Build marker to the first XCTest suite.
        self.assertAlmostEqual(row["gap_build_end_to_first_test_s"], 430.1)
        # Swift Testing end line to `Test session results`.
        self.assertAlmostEqual(row["finalize_s"], 18.0)
        self.assertEqual(row["ide_elapsed_s"], 894.0)

    def test_xcresult_summary_sets_start_and_finish(self):
        start = dt("2026-10-22T10:00:08.500").timestamp()
        finish = dt("2026-10-22T10:15:10.250").timestamp()
        row = phases.compute_phases(
            phases.parse_log(io.StringIO(TIMED_LOG)), {"startTime": start, "finishTime": finish}
        )
        self.assertEqual(row["testing_started_at"], dt("2026-10-22T10:00:08.500"))
        self.assertEqual(row["run_end_at"], dt("2026-10-22T10:15:10.250"))
        self.assertAlmostEqual(row["finalize_s"], 8.25)

    def test_raw_log_degrades_to_empty_cells(self):
        row = phases.compute_phases(phases.parse_log(io.StringIO(RAW_LOG)))
        self.assertIsNone(row["build_for_testing_s"])
        self.assertEqual(row["testing_started_at"], dt("2026-09-16T15:02:42.313") - datetime.timedelta(seconds=163.283))
        self.assertAlmostEqual(row["xctest_s"], 0.002)
        # Build end is unknown, so the gap counts from `Testing started`.
        self.assertAlmostEqual(row["gap_build_end_to_first_test_s"], 43.707, places=3)
        self.assertEqual(row["swift_testing_s"], 107.552)
        self.assertIsNone(row["swift_testing_started_at"])
        self.assertIsNone(row["finalize_s"])

    def test_swift_testing_start_backdated_from_end_line(self):
        log = "2026-10-22T10:10:00 ✔ Test run with 3 tests in 1 suite passed after 100.000 seconds.\n"
        row = phases.compute_phases(phases.parse_log(io.StringIO(log)))
        self.assertEqual(row["swift_testing_started_at"], dt("2026-10-22T10:08:20"))
        self.assertEqual(row["run_end_at"], None)
        self.assertIsNone(row["finalize_s"])

    def test_finalize_needs_every_ran_framework_to_end(self):
        log = TIMED_LOG.replace("✘ Test run with 2952 tests in 300 suites failed after 402.000 seconds with 1 issue.", "")
        row = phases.compute_phases(phases.parse_log(io.StringIO(log)))
        self.assertIsNone(row["finalize_s"])
        self.assertIsNone(row["swift_testing_s"])

    def test_xctest_only_run(self):
        swift_testing = ("Test run", "Suite Fast", "Suite \"", "Suite Slow")
        log = "\n".join(line for line in TIMED_LOG.splitlines()
                        if not any(marker in line for marker in swift_testing)) + "\n"
        row = phases.compute_phases(phases.parse_log(io.StringIO(log)))
        self.assertAlmostEqual(row["xctest_s"], 36.2)
        self.assertIsNone(row["swift_testing_s"])
        self.assertAlmostEqual(row["finalize_s"], (dt("2026-10-22T10:15:20") - dt("2026-10-22T10:07:46.300")).total_seconds())


class CsvAndSuiteTests(unittest.TestCase):
    def test_csv_header_written_once(self):
        row = phases.compute_phases(phases.parse_log(io.StringIO(TIMED_LOG)), run_id="a")
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "nested" / "phases.csv"
            phases.append_csv(path, row)
            phases.append_csv(path, dict(row, run_id="b"))
            lines = path.read_text().splitlines()
        self.assertEqual(lines[0], ",".join(phases.CSV_COLUMNS))
        self.assertEqual(len(lines), 3)
        self.assertTrue(lines[1].startswith("a,767,921,2026-10-22T10:00:09.000,2026-10-22T10:07:10.100,36.200,"))
        self.assertTrue(lines[2].startswith("b,"))

    def test_empty_cells_for_missing_values(self):
        row = phases.compute_phases(phases.parse_log([]), run_id="empty")
        self.assertEqual([phases.format_cell(row[c]) for c in phases.CSV_COLUMNS], ["empty"] + [""] * 9)

    def test_parse_duration_handles_locale_and_units(self):
        self.assertAlmostEqual(phases.parse_duration("0,083s"), 0.083)
        self.assertAlmostEqual(phases.parse_duration("3s"), 3.0)
        self.assertAlmostEqual(phases.parse_duration("1m 2.5s"), 62.5)
        self.assertAlmostEqual(phases.parse_duration("250ms"), 0.25)
        self.assertIsNone(phases.parse_duration(None))
        self.assertIsNone(phases.parse_duration("n/a"))

    def test_xcresult_suite_durations_sum_cases_recursively(self):
        tree = {"testNodes": [{"nodeType": "Test Plan", "name": "Plan", "children": [
            {"nodeType": "Unit test bundle", "name": "Bundle", "children": [
                {"nodeType": "Test Suite", "name": "Outer", "children": [
                    {"nodeType": "Test Case", "name": "a()", "duration": "1s"},
                    {"nodeType": "Test Suite", "name": "Inner", "children": [
                        {"nodeType": "Test Case", "name": "b()", "duration": "0,5s"},
                        {"nodeType": "Test Case", "name": "c()"},
                    ]},
                ]},
                {"nodeType": "Test Suite", "name": "Other", "children": [
                    {"nodeType": "Test Case", "name": "d()", "duration": "4s"},
                ]},
            ]},
        ]}]}
        found = phases.suite_durations_from_xcresult(tree)
        self.assertEqual(found, [("Outer", 1.5, 3), ("Inner", 0.5, 2), ("Other", 4.0, 1)])
        self.assertEqual([name for name, _, _ in phases.slowest(found, 2)], ["Other", "Outer"])

    def test_slowest_log_suites_and_render(self):
        parsed = phases.parse_log(io.StringIO(TIMED_LOG))
        row = phases.compute_phases(parsed, run_id="r")
        top = phases.slowest(parsed["suites"], 2, seconds_index=2)
        self.assertEqual([name for name, _, _ in top], ["SlowTests", "Media viewer presentation"])
        text = phases.render(row, top, [], 2, markdown=True)
        self.assertIn("## Test phases: r", text)
        self.assertIn("| SlowTests | 338.500 | failed |", text)
        plain = phases.render(row, [], [], 20, markdown=False)
        self.assertIn("No per-suite durations found", plain)


if __name__ == "__main__":
    unittest.main()
