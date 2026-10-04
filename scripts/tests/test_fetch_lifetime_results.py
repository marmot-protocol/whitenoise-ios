"""Refuse absent, skipped or mixed-result security regressions."""
import copy
import importlib.util
import pathlib
import subprocess
import sys
import unittest


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
    def test_all_twelve_pass(self):
        self.assertEqual(CHECKER.require_passes(fixture()), sorted(CHECKER.REQUIRED))
        self.assertEqual(len(CHECKER.REQUIRED), 12)

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
