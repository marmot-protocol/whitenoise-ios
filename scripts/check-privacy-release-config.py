#!/usr/bin/env python3
"""Verify host permission strings and manifests in a built iOS app bundle."""

import argparse
import json
import plistlib
from pathlib import Path

LOCALES = ("de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant")
PERMISSIONS = {
    "NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSFaceIDUsageDescription",
    "NSLocationWhenInUseUsageDescription", "NSPhotoLibraryAddUsageDescription",
}
REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
}


def read_plist(path):
    with path.open("rb") as file:
        return plistlib.load(file)


def verify(app, repo):
    info = read_plist(app / "Info.plist")
    catalog = json.loads((repo / "whitenoise-ios/InfoPlist.xcstrings").read_text())["strings"]
    keys = {key for key in info if key.startswith("NS") and key.endswith("UsageDescription")}
    if missing := PERMISSIONS - keys:
        raise ValueError(f"Missing built purpose strings: {sorted(missing)}")
    for key in keys:
        expected = catalog[key]["localizations"]["en"]["stringUnit"]["value"]
        if not expected or info[key] != expected:
            raise ValueError(f"Built English purpose differs from catalog: {key}")
    for locale in LOCALES:
        localized = read_plist(app / f"{locale}.lproj/InfoPlist.strings")
        for key in keys:
            unit = catalog[key]["localizations"][locale]["stringUnit"]
            if unit["state"] != "translated" or not unit["value"] or localized.get(key) != unit["value"]:
                raise ValueError(f"Missing or stale built translation: {locale}/{key}")
        if "CFBundleDisplayName" in localized:
            raise ValueError(f"Localized display name overrides the build flavor: {locale}")
    for bundle in (app, app / "PlugIns/NotificationServiceExtension.appex"):
        entries = read_plist(bundle / "PrivacyInfo.xcprivacy")["NSPrivacyAccessedAPITypes"]
        actual = {entry["NSPrivacyAccessedAPIType"]: set(entry["NSPrivacyAccessedAPITypeReasons"]) for entry in entries}
        if actual != REASONS or len(actual) != len(entries):
            raise ValueError(f"Unexpected host required-reason declarations: {bundle.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Built .app directory, including its notification extension")
    args = parser.parse_args()
    try:
        verify(args.app, Path(__file__).resolve().parents[1])
    except (KeyError, OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Privacy configuration check failed: {error}\n")
    print("Host permission translations and app/extension manifests verified; SDK and App Store Connect review remains separate.")


if __name__ == "__main__":
    main()
