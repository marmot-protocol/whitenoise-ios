"""Exercise missing and stale permission resources in disposable app bundles."""
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("privacy_config", ROOT / "scripts/check-privacy-release-config.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class PrivacyReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.app = pathlib.Path(self.root.name) / "Fixture.app"
        catalog = json.loads((ROOT / "whitenoise-ios/InfoPlist.xcstrings").read_text())["strings"]
        self.write("Info.plist", {
            **{key: catalog[key]["localizations"]["en"]["stringUnit"]["value"] for key in CHECK.PERMISSIONS},
            "CFBundleShortVersionString": "2026.9.9", "CFBundleVersion": "33",
            "WhiteNoiseAuditLogBearerToken": "fixture-secret",
        })
        self.write("PlugIns/NotificationServiceExtension.appex/Info.plist", {
            "CFBundleShortVersionString": "2026.9.9", "CFBundleVersion": "33",
        })
        for locale in CHECK.LOCALES:
            self.write(f"{locale}.lproj/InfoPlist.strings", {
                key: catalog[key]["localizations"][locale]["stringUnit"]["value"] for key in CHECK.PERMISSIONS
            })
        manifest = {"NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": key, "NSPrivacyAccessedAPITypeReasons": sorted(reasons)}
            for key, reasons in CHECK.REASONS.items()
        ]}
        self.write("PrivacyInfo.xcprivacy", manifest)
        self.write("PlugIns/NotificationServiceExtension.appex/PrivacyInfo.xcprivacy", manifest)

    def write(self, relative, value):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def test_complete_bundle_passes(self):
        CHECK.verify(self.app, ROOT)

    def test_missing_location_base_purpose_fails(self):
        info = CHECK.read_plist(self.app / "Info.plist")
        del info["NSLocationWhenInUseUsageDescription"]
        self.write("Info.plist", info)
        with self.assertRaisesRegex(ValueError, "Missing built purpose"):
            CHECK.verify(self.app, ROOT)

    def test_stale_translated_camera_purpose_fails(self):
        path = "it.lproj/InfoPlist.strings"
        info = CHECK.read_plist(self.app / path)
        info["NSCameraUsageDescription"] = "Obsolete camera purpose"
        self.write(path, info)
        with self.assertRaisesRegex(ValueError, "stale built translation"):
            CHECK.verify(self.app, ROOT)

    def test_localized_name_cannot_hide_staging(self):
        path = "it.lproj/InfoPlist.strings"
        info = CHECK.read_plist(self.app / path)
        info["CFBundleDisplayName"] = "White Noise"
        self.write(path, info)
        with self.assertRaisesRegex(ValueError, "overrides the build flavor"):
            CHECK.verify(self.app, ROOT)

    def test_missing_extension_manifest_fails(self):
        (self.app / "PlugIns/NotificationServiceExtension.appex/PrivacyInfo.xcprivacy").unlink()
        with self.assertRaises(FileNotFoundError):
            CHECK.verify(self.app, ROOT)

    def test_mismatched_extension_version_fails(self):
        path = "PlugIns/NotificationServiceExtension.appex/Info.plist"
        info = CHECK.read_plist(self.app / path)
        info["CFBundleVersion"] = "32"
        self.write(path, info)
        with self.assertRaisesRegex(ValueError, "mismatched app/extension version"):
            CHECK.verify(self.app, ROOT)

    def test_report_excludes_credentials_and_flags_missing_sdk_manifest(self):
        sdk = self.app.parent / "MarmotKit.xcframework"
        sdk.mkdir()
        report = CHECK.privacy_inventory(self.app, sdk)
        self.assertNotIn("fixture-secret", json.dumps(report))
        self.assertNotIn("BearerToken", json.dumps(report))
        self.assertEqual(report["bundles"][0]["CFBundleVersion"], "33")
        self.assertEqual(report["sdk"]["privacyManifests"], [])
        self.assertIn("upstream", report["sdk"]["reviewStatus"])

    def test_archive_resolution_and_path_escape(self):
        archive = self.app.parent / "Fixture.xcarchive"
        archived_app = archive / "Products/Applications/Fixture.app"
        archived_app.mkdir(parents=True)
        info_path = archive / "Info.plist"
        info_path.write_bytes(plistlib.dumps({"ApplicationProperties": {
            "ApplicationPath": "Applications/Fixture.app",
        }}))
        self.assertEqual(CHECK.resolve_app(archive), archived_app.resolve())
        info_path.write_bytes(plistlib.dumps({"ApplicationProperties": {
            "ApplicationPath": str(self.app),
        }}))
        with self.assertRaisesRegex(ValueError, "path is invalid"):
            CHECK.resolve_app(archive)


if __name__ == "__main__":
    unittest.main()
