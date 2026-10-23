import contextlib
import importlib.util
import io
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
        failure = cov.subprocess.CalledProcessError(
            1, "xccov", stderr="error: Unable to read coverage archive at B.xcresult\n")
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(cov.subprocess, "run", side_effect=failure), \
                contextlib.redirect_stderr(stderr):
            self.assertIsNone(cov.covered_lines(os.path.join(tmp, "B.xcresult"), os.path.join(tmp, "B.json")))
        self.assertIn("Unable to read coverage archive", stderr.getvalue())

    def test_missing_xccov_binary_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
                cov.subprocess, "run", side_effect=FileNotFoundError("xcrun")), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(cov.covered_lines(os.path.join(tmp, "C.xcresult"), os.path.join(tmp, "C.json")))

    def test_foreign_checkout_named_like_the_app_target(self):
        # The checkout directory itself is `whitenoise-ios`: the suffix that
        # exists in this repository wins, not the first marker.
        self.assertEqual(cov.relative_to_root("/Users/x/whitenoise-ios/Shared/AppContainerConfig.swift"),
                         "Shared/AppContainerConfig.swift")
        self.assertEqual(cov.relative_to_root("/Users/x/whitenoise-ios/whitenoise-ios/Core/AppState.swift"),
                         "whitenoise-ios/Core/AppState.swift")
        # A file this tree no longer has falls back to the last marker.
        self.assertEqual(cov.relative_to_root("/Users/x/whitenoise-ios/Shared/Gone.swift"), "Shared/Gone.swift")

    def test_an_unreadable_bundle_stops_the_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            for label in ("A", "B"):
                os.makedirs(os.path.join(tmp, label + ".xcresult"))
            with open(os.path.join(tmp, "A.coverage.json"), "w") as fh:
                json.dump([], fh)  # an empty set is a measurement
            out = os.path.join(tmp, "coverage-unique.csv")
            cwd = os.getcwd()
            try:
                with mock.patch.object(cov.subprocess, "run", side_effect=FileNotFoundError("xcrun")), \
                        contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        cov.main(["--dir", tmp, "--out", out])
            finally:
                os.chdir(cwd)
            self.assertIn("B", str(raised.exception))
            self.assertFalse(os.path.exists(out))


if __name__ == "__main__":
    unittest.main()
