#!/usr/bin/env python3
"""Verify host privacy resources in a built app or Xcode archive."""

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


def resolve_app(artifact):
    if artifact.suffix != ".xcarchive":
        return artifact
    products = (artifact / "Products").resolve()
    relative = read_plist(artifact / "Info.plist")["ApplicationProperties"]["ApplicationPath"]
    app = (products / relative).resolve()
    if not app.is_relative_to(products) or app.suffix != ".app" or not app.is_dir():
        raise ValueError("Archive application path is invalid")
    return app


def privacy_inventory(app, sdk=None):
    """Allowlist report fields so build tokens and provisioning data stay private."""
    identity_keys = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")
    bundles = [app, *sorted(app.glob("PlugIns/*.appex"))]
    result = {
        "hostChecks": "passed",
        "bundles": [{
            "path": str(bundle.relative_to(app)),
            **{key: read_plist(bundle / "Info.plist").get(key) for key in identity_keys},
        } for bundle in bundles],
        "packagedPrivacyManifests": [str(path.relative_to(app)) for path in sorted(app.rglob("PrivacyInfo.xcprivacy"))],
        "unverified": ["App Store Connect privacy answers", "Native required-reason API purposes",
                       "Production retention and deletion", "Encryption export classification"],
    }
    if sdk is not None:
        if not sdk.is_dir():
            raise ValueError("SDK directory does not exist")
        manifests = sorted(sdk.rglob("PrivacyInfo.xcprivacy"))
        result["sdk"] = {
            "name": sdk.name,
            "privacyManifests": [str(path.relative_to(sdk)) for path in manifests],
            "reviewStatus": "Purpose audit still required" if manifests else "No SDK privacy manifest found; upstream review required",
        }
    return result


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
        bundle_info = read_plist(bundle / "Info.plist")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if not info.get(key) or bundle_info.get(key) != info[key]:
                raise ValueError(f"Missing or mismatched app/extension version: {key}")
        entries = read_plist(bundle / "PrivacyInfo.xcprivacy")["NSPrivacyAccessedAPITypes"]
        actual = {entry["NSPrivacyAccessedAPIType"]: set(entry["NSPrivacyAccessedAPITypeReasons"]) for entry in entries}
        if actual != REASONS or len(actual) != len(entries):
            raise ValueError(f"Unexpected host required-reason declarations: {bundle.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="Built .app directory or .xcarchive")
    parser.add_argument("--sdk", type=Path, help="Optional extracted XCFramework to inventory without modifying it")
    parser.add_argument("--report", type=Path, help="Write a credential-free JSON evidence report")
    args = parser.parse_args()
    try:
        app = resolve_app(args.artifact)
        verify(app, Path(__file__).resolve().parents[1])
        inventory = privacy_inventory(app, args.sdk)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(inventory, indent=2) + "\n")
    except (KeyError, OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Privacy configuration check failed: {error}\n")
    print("Host permission translations and app/extension manifests verified; SDK and App Store Connect review remains separate.")


if __name__ == "__main__":
    main()
