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
        self.write("Info.plist", {key: catalog[key]["localizations"]["en"]["stringUnit"]["value"] for key in CHECK.PERMISSIONS})
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


if __name__ == "__main__":
    unittest.main()
