"""Exercise the release preflight using disposable built-plist fixtures."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


class AnalyticsReleaseConfigTests(unittest.TestCase):
    def check(self, endpoint):
        script = pathlib.Path(__file__).resolve().parents[1] / "check-analytics-release-config.py"
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / "Info.plist"
            with path.open("wb") as output:
                plistlib.dump({
                    "WhiteNoiseProductAnalyticsEndpoint": endpoint,
                    "WhiteNoiseProductAnalyticsAppKey": "A-SH-fixture-only",
                    "WhiteNoiseProductAnalyticsOperator": "test_operator",
                    "WhiteNoiseProductAnalyticsRetention": "Fixture retention disclosure",
                }, output)
            return subprocess.run([sys.executable, str(script), str(path)],
                                  capture_output=True, text=True, check=False)

    def test_valid_https_endpoints(self):
        for endpoint in ("https://collector.example/api/v0/events",
                         "https://collector.example:8443/api/v0/events"):
            with self.subTest(endpoint=endpoint):
                self.assertEqual(self.check(endpoint).returncode, 0)

    def test_invalid_endpoints_fail_without_disclosing_configuration(self):
        for endpoint in ("https://collector.example:not-a-port/api/v0/events",
                         "https://collector.example:65536/api/v0/events",
                         "https://collector.example:0/api/v0/events",
                         "https://[invalid/api/v0/events",
                         "http://collector.example/api/v0/events",
                         "https://user:password@collector.example/api/v0/events",
                         "https://collector.example/api/v0/events?token=private",
                         "https://collector.example/api/v0/events#fragment"):
            with self.subTest(endpoint=endpoint):
                result = self.check(endpoint)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid events endpoint", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertNotIn(endpoint, result.stdout + result.stderr)
                self.assertNotIn("A-SH-fixture-only", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
