import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name):
    path = ROOT / "scripts" / "audit" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").replace(".py", ""), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cov = load("coverage-unique.py")


class CoveredLinesTests(unittest.TestCase):
    def test_keeps_first_party_executed_lines_only(self):
        archive = {
            "/Users/x/white-noise-ios/Shared/Hex.swift": [
                {"isExecutable": False, "line": 1},
                {"isExecutable": True, "line": 2, "executionCount": 3},
                {"isExecutable": True, "line": 3, "executionCount": 0},
            ],
            "/Users/x/white-noise-ios/whitenoise-ios/Core/AppState.swift": [
                {"isExecutable": True, "line": 10, "executionCount": 1},
            ],
            "/Users/x/DerivedData/SourcePackages/checkouts/stripe/Stripe.swift": [
                {"isExecutable": True, "line": 1, "executionCount": 9},
            ],
        }
        completed = mock.Mock(stdout=json.dumps(archive))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(cov.subprocess, "run", return_value=completed):
            cache = os.path.join(tmp, "A.coverage.json")
            lines = cov.covered_lines(os.path.join(tmp, "A.xcresult"), cache)
            self.assertEqual(lines, {("Shared/Hex.swift", 2), ("whitenoise-ios/Core/AppState.swift", 10)})
            # second call must come from the cache without running xccov
            with mock.patch.object(cov.subprocess, "run", side_effect=AssertionError("xccov called")):
                self.assertEqual(cov.covered_lines(os.path.join(tmp, "A.xcresult"), cache), lines)

    def test_missing_coverage_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
                cov.subprocess, "run", side_effect=cov.subprocess.CalledProcessError(1, "xccov")):
            self.assertIsNone(cov.covered_lines(os.path.join(tmp, "B.xcresult"), os.path.join(tmp, "B.json")))


if __name__ == "__main__":
    unittest.main()
