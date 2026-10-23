import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name):
    path = ROOT / "scripts" / "audit" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").replace(".py", ""), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe_suites = load("probe-suites.py")

PROBE = {"name": "p", "path": "Shared/AppContainerConfig.swift", "old": "import Foundation"}


class SelectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temp.name)
        self.per_file = root / "per-file"
        self.tests = root / "tests"
        self.per_file.mkdir()
        self.tests.mkdir()
        (self.tests / "Shared.swift").write_text(
            "import Testing\nstruct OneTests {\n    @Test func a() {}\n}\nstruct TwoTests {\n    @Test func b() {}\n}\n")
        (self.tests / "Single.swift").write_text("import Testing\nstruct SoloTests {\n    @Test func c() {}\n}\n")
        self.cwd = os.getcwd()
        os.chdir(ROOT)  # probe paths are repo-relative
        self.hit = [[PROBE["path"], probe_suites.mutated_lines(PROBE["path"], PROBE["old"])[0]]]

    def tearDown(self):
        os.chdir(self.cwd)
        self.temp.cleanup()

    def cache(self, label, lines):
        with open(self.per_file / (label + ".coverage.json"), "w") as fh:
            json.dump(lines, fh)

    def test_coverage_of_a_file_with_several_suites_is_unverified(self):
        self.cache("Shared", self.hit)
        self.cache("Single", self.hit)
        method, suites, unverified = probe_suites.select(PROBE, str(self.per_file), str(self.tests))
        self.assertEqual((method, suites), ("coverage", ["OneTests", "SoloTests", "TwoTests"]))
        self.assertEqual(unverified, {"OneTests", "TwoTests"})

    def test_file_level_fallback_is_unverified(self):
        self.cache("Single", [[PROBE["path"], 100000]])  # covers the file, not the mutated line
        method, suites, unverified = probe_suites.select(PROBE, str(self.per_file), str(self.tests))
        self.assertEqual((method, suites, unverified), ("file", ["SoloTests"], {"SoloTests"}))

    def test_a_bundle_newer_than_its_cache_is_reread(self):
        self.cache("Single", [])  # stale: says the file covers nothing
        bundle = self.per_file / "Single.xcresult"
        bundle.mkdir()
        later = time.time() + 10
        os.utime(bundle, (later, later))
        archive = {str(ROOT / PROBE["path"]): [{"isExecutable": True, "line": self.hit[0][1], "executionCount": 1}]}
        with mock.patch.object(probe_suites.coverage_unique.subprocess, "run",
                               return_value=mock.Mock(stdout=json.dumps(archive))), \
                contextlib.redirect_stderr(io.StringIO()):
            method, suites, unverified = probe_suites.select(PROBE, str(self.per_file), str(self.tests))
        self.assertEqual((method, suites, unverified), ("coverage", ["SoloTests"], set()))


if __name__ == "__main__":
    unittest.main()
