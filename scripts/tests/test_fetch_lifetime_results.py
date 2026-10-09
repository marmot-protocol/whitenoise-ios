"""Refuse absent, skipped or mixed-result security regressions."""
import copy
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "check-fetch-lifetime-results.py"
SPEC = importlib.util.spec_from_file_location("fetch_lifetime_results", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def fixture():
    return {"testNodes": [{"nodeType": "Test Plan", "children": [
        {"nodeType": "Test Case", "nodeIdentifier": "whitenoise_iosTests/" + identifier, "result": "Passed"}
        for identifier in sorted(CHECKER.REQUIRED)
    ]}]}


class FetchLifetimeResultTests(unittest.TestCase):
    def test_all_eleven_hermetic_cases_pass(self):
        self.assertEqual(CHECKER.require_passes(fixture()), sorted(CHECKER.REQUIRED))
        self.assertEqual(len(CHECKER.REQUIRED), 11)

    def test_public_case_is_required_only_when_opted_in(self):
        document = fixture()
        with self.assertRaises(ValueError):
            CHECKER.require_passes(document, include_public_cdn=True)
        document["testNodes"][0]["children"].append({
            "nodeType": "Test Case", "nodeIdentifier": CHECKER.PUBLIC_CDN_CASE, "result": "Passed"})
        self.assertEqual(len(CHECKER.require_passes(document, include_public_cdn=True)), 12)

    def test_skipped_public_case_does_not_weaken_hermetic_cases(self):
        document = fixture()
        document["testNodes"][0]["children"].append({
            "nodeType": "Test Case", "nodeIdentifier": CHECKER.PUBLIC_CDN_CASE, "result": "Skipped"})
        self.assertEqual(CHECKER.require_passes(document), sorted(CHECKER.REQUIRED))
        with self.assertRaises(ValueError):
            CHECKER.require_passes(document, include_public_cdn=True)

    def test_staging_scheme_does_not_override_runner_flag_or_change_launch(self):
        project = SCRIPT.parent.parent / "whitenoise-ios.xcodeproj"
        scheme = ET.parse(project / "xcshareddata/xcschemes/Whitenoise (Staging).xcscheme").getroot()
        action = scheme.find("TestAction")
        self.assertEqual(action.get("shouldUseLaunchSchemeArgsEnv"), "NO")
        self.assertIsNone(action.find("EnvironmentVariables"))
        self.assertIsNone(scheme.find("LaunchAction/EnvironmentVariables"))

    def check_runner_environment(self, opt_in):
        with tempfile.TemporaryDirectory() as directory:
            fixtures = pathlib.Path(directory)
            runner = fixtures / "xcodebuild"
            runner.write_text(
                "#!" + sys.executable + "\nimport json, os, sys\n"
                "print('RUNNER_FIXTURE:' + json.dumps({'phase': sys.argv[1], "
                "'flag': os.environ.get('TEST_RUNNER_WN_FETCH_NATIVE_CDN'), "
                "'build_setting': any(a.startswith('WN_FETCH_NATIVE_CDN=') for a in sys.argv)}))\n",
                encoding="utf-8")
            runner.chmod(0o700)
            formatter = fixtures / "xcbeautify"
            formatter.write_text("#!/bin/sh\nexec cat\n", encoding="utf-8")
            formatter.chmod(0o700)
            environment = os.environ.copy()
            environment.pop("TEST_RUNNER_WN_FETCH_NATIVE_CDN", None)
            environment.pop("WN_FETCH_NATIVE_CDN", None)
            environment["PATH"] = str(fixtures) + os.pathsep + environment["PATH"]
            environment["WN_TEST_DESTINATION"] = "platform=iOS Simulator,name=Owned Fixture"
            environment["WN_TEST_RESULT_BUNDLE"] = str(fixtures / "owned-results.xcresult")
            if opt_in is not None:
                environment["WN_FETCH_NATIVE_CDN"] = opt_in
            result = subprocess.run(
                ["bash", str(SCRIPT.parent / "test.sh")], env=environment,
                capture_output=True, text=True, timeout=30, check=True)
            phases = [json.loads(line.removeprefix("RUNNER_FIXTURE:"))
                      for line in result.stdout.splitlines() if line.startswith("RUNNER_FIXTURE:")]
            self.assertEqual(phases, [
                {"phase": "build-for-testing", "flag": None, "build_setting": False},
                {"phase": "test-without-building", "flag": opt_in or "0", "build_setting": False},
            ])

    def test_manual_opt_in_is_exported_only_to_test_execution(self):
        self.check_runner_environment("1")

    def test_ordinary_tests_export_an_explicit_off_flag(self):
        self.check_runner_environment(None)

    def test_missing_required_case_refused(self):
        document = fixture()
        document["testNodes"][0]["children"].pop()
        with self.assertRaisesRegex(ValueError, "missing or not passed"):
            CHECKER.require_passes(document)

    def test_skipped_failed_expected_failure_and_missing_result_refused(self):
        for result in ("Skipped", "Failed", "Expected Failure", "Mixed", None):
            with self.subTest(result=result):
                document = fixture()
                document["testNodes"][0]["children"][0]["result"] = result
                with self.assertRaises(ValueError):
                    CHECKER.require_passes(document)

    def test_later_pass_cannot_hide_failed_duplicate(self):
        document = fixture()
        duplicate = copy.deepcopy(document["testNodes"][0]["children"][0])
        duplicate["result"] = "Failed"
        document["testNodes"][0]["children"].insert(0, duplicate)
        with self.assertRaises(ValueError):
            CHECKER.require_passes(document)

    def test_other_suite_same_method_cannot_replace_required_case(self):
        document = fixture()
        case = document["testNodes"][0]["children"][0]
        case["nodeIdentifier"] = case["nodeIdentifier"].replace("PinnedHTTPSFetchLifetimeTests", "UnrelatedTests")
        with self.assertRaises(ValueError):
            CHECKER.require_passes(document)

    def test_module_qualified_suite_supported(self):
        document = fixture()
        for case in document["testNodes"][0]["children"]:
            pieces = case["nodeIdentifier"].split("/")
            pieces[-2] = "whitenoise_iosTests." + pieces[-2]
            case["nodeIdentifier"] = "/".join(pieces)
        self.assertEqual(CHECKER.require_passes(document), sorted(CHECKER.REQUIRED))

    def test_malformed_tree_refused(self):
        for document in (None, {}, {"testNodes": [None]}, {"testNodes": [{"children": None}]}):
            with self.subTest(document=document), self.assertRaises(ValueError):
                CHECKER.require_passes(document)

    def test_cli_invalid_json_refused(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], input=b"not JSON", capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
