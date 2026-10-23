import importlib.util
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


costs = load("per-file-costs.py")
gate = load("gate-critical-path.py")


class ParseDurationTests(unittest.TestCase):
    def test_units_and_locales(self):
        self.assertAlmostEqual(costs.parse_duration("0.42s"), 0.42)
        self.assertAlmostEqual(costs.parse_duration("0,083s"), 0.083)
        self.assertAlmostEqual(costs.parse_duration("250ms"), 0.25)
        self.assertAlmostEqual(costs.parse_duration("1.5m"), 90.0)
        self.assertEqual(costs.parse_duration(None), 0.0)
        self.assertEqual(costs.parse_duration("garbage"), 0.0)


class WallFromLogTests(unittest.TestCase):
    def test_reads_marker_and_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "Foo.log")
            with open(log, "w") as fh:
                fh.write("2026-10-23T01:00:00 Testing started\n")
                fh.write("2026-10-23T01:00:41 ==> Foo: 41s status=0\n")
            self.assertEqual(costs.wall_from_log(log), (41, 0))

    def test_missing_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "Foo.log")
            open(log, "w").close()
            self.assertEqual(costs.wall_from_log(log), (None, None))


class PerSuiteDurationsTests(unittest.TestCase):
    def test_groups_cases_by_nearest_suite(self):
        data = {"testNodes": [{"nodeType": "Test Plan", "name": "Plan", "children": [
            {"nodeType": "Unit test bundle", "name": "whitenoise-iosTests", "children": [
                {"nodeType": "Test Suite", "name": "AlphaTests", "children": [
                    {"nodeType": "Test Case", "name": "a()", "duration": "1s"},
                    {"nodeType": "Test Case", "name": "b(x:)", "duration": "0,5s", "children": [
                        {"nodeType": "Arguments", "name": "x → 1"}]},
                ]},
                {"nodeType": "Test Suite", "name": "BetaTests", "children": [
                    {"nodeType": "Test Case", "name": "c()", "duration": "2s"}]},
            ]}]}]}
        result = costs.per_suite_durations(data)
        self.assertEqual(sorted(result), ["AlphaTests", "BetaTests"])
        self.assertAlmostEqual(sum(result["AlphaTests"]), 1.5)
        self.assertEqual(result["BetaTests"], [2.0])


class TestsJsonTests(unittest.TestCase):
    def test_unreadable_bundle_or_missing_xcrun_returns_none(self):
        from unittest import mock
        import contextlib
        import io
        failures = [
            costs.subprocess.CalledProcessError(1, "xcresulttool", stderr="Error: invalid result bundle\n"),
            FileNotFoundError("xcrun"),
        ]
        for failure in failures:
            with tempfile.TemporaryDirectory() as tmp, \
                    mock.patch.object(costs.subprocess, "run", side_effect=failure), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                bundle = os.path.join(tmp, "A.xcresult")
                os.makedirs(bundle)
                self.assertIsNone(costs.tests_json(bundle, os.path.join(tmp, "json")))
                self.assertIn("cannot read", err.getvalue())
                self.assertFalse(os.path.exists(os.path.join(tmp, "json", "A.xcresult.json")))


class GateCriticalPathTests(unittest.TestCase):
    def test_peak_concurrency_and_hold_sum(self):
        rows = [
            {"test": "t1", "requested": 0.0, "acquired": 0.0, "released": 2.0},
            {"test": "t2", "requested": 0.5, "acquired": 2.0, "released": 3.0},
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            for row in rows:
                fh.write(json.dumps(row) + "\n")
            path = fh.name
        try:
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                gate.main(path)
            out = buf.getvalue()
            self.assertIn("gated tests: 2", out)
            self.assertIn("permits observed: 1", out)
            self.assertIn("total hold 3.0s", out)
            self.assertIn("total wait 1.5s", out)
            self.assertIn("p90 2.00s", out)  # nearest rank: the larger of two holds
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
