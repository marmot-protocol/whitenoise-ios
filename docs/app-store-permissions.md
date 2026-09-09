# Permissions and submission checks

Checked against source and the production/staging Release bundles on 2026-09-09.
This documents the app's permission surfaces and remaining submission work;
local builds do not establish App Review approval.

Validation completed: 30 focused Swift tests, 11 Python checks, strict SwiftLint,
both unsigned Release device builds, and both built-bundle privacy preflights.
Version 2026.9.9 build 33 and the existing configuration values are unchanged.

## Permission prompts

| Feature | Plist declaration | Behavior |
| --- | --- | --- |
| Scan profile QR codes; capture chat photos/videos | `NSCameraUsageDescription` | Camera access is requested for scanning or capture. |
| Voice messages; video audio | `NSMicrophoneUsageDescription` | Audio capture requests microphone access. |
| Share a location | `NSLocationWhenInUseUsageDescription` | The location picker requests foreground access. No always/background location mode. |
| Biometric app unlock | `NSFaceIDUsageDescription` | Local Authentication unlocks the app. |
| Save shared media to Photos | `NSPhotoLibraryAddUsageDescription` | The system share sheet can save selected photos/videos. Add-only wording; no general library-read request. |

All five purpose strings have English and all nine supported translations in
`whitenoise-ios/InfoPlist.xcstrings`. Camera and microphone copy includes video.
The catalog tests compare every built usage-description key with its English
catalog value and require translations in every shipped language.

After each Release build, run
`python3 scripts/check-privacy-release-config.py <path-to-built.app>`.
This checks the actual localized plist resources and both host manifests without
printing ingestion keys or other build credentials.

Photo selection uses `PHPickerViewController`; contact sharing uses
`CNContactPickerViewController`. These provide the person's selected items and
do not justify blanket Photos/Contacts access. Notification authorization uses
UserNotifications and APNS entitlements, not a custom notification usage string.
No tracking authorization, background location, Bonjour discovery, Bluetooth,
health, calendar, or speech-recognition feature was found in the host code.
Do not add those permission declarations speculatively.

Sources: [Apple protected resources](https://developer.apple.com/documentation/bundleresources/protected-resources),
[Photos picker](https://developer.apple.com/documentation/avfoundation/saving-captured-photos),
[contact picker access](https://developer.apple.com/videos/play/wwdc2024/10121/),
[add-only Photos permission](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryaddusagedescription).

## Privacy manifests

`Shared/PrivacyInfo.xcprivacy` is compiled into both the app and notification
extension. It declares the host's required-reason API usage:

- `CA92.1` / `1C8F.1`: private preferences and preferences shared within the App Group.
- `C617.1`: app/App Group file metadata for caches, storage, and notification avatars.
- `35F9.1`: elapsed-time measurements and timers. Exported timing observations
  contain elapsed durations, not device boot timestamps.

See Apple's [API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
This manifest declares API access; it does not claim that the app collects no data
or replace the App Store Connect privacy answers.

### Native SDK follow-up before submission

The formal MarmotKit 0.9.20 package does not contain a privacy manifest. Apple
[requires SDK authors to report their own required-reason usage](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).
Do not treat the host manifest as completing the native SDK audit.

The linked Release executable imports `stat`, `fstat`, `lstat`, `fstatat`,
`statfs`, and `fstatfs`. The SQLite Apple VFS uses filesystem calls for locking
and read-only filesystem flags. The released archive's `sqlite3.o` independently
imports `statfs`/`fstatfs`; the pinned rusqlite revision is
`5ae7fdf83085c595fd54f977b3a56ccacabaf16b` (`libsqlite3-sys` 0.38.1).
A disk-space symbol alone does not establish a
valid disk-space purpose: do not declare `E174.1` without demonstrating the
required low-space behavior. Review the exact MDK 0.9.20 source and its native
dependencies, publish any required SDK manifest/source changes through the MDK
release workflow, and install the matching immutable release. Never patch the
generated binding source or vendor binary in this app to bypass that work.

## Remaining App Store Connect checks

- Privacy & Security now links to the published
  [White Noise privacy policy](https://www.whitenoise.chat/privacy). Confirm the
  same URL in App Store Connect. The policy dated March 30, 2026 still describes
  analytics as anonymized and does not state the 180-day retention period.
  Update its analytics/diagnostic identity and retention wording before shipping
  this integration. Apple's [review guidelines](https://developer.apple.com/app-store/review/guidelines/#privacy)
  require an accessible link both in-app and in the store metadata.
- Reconcile App Privacy answers with the deployed services: optional usage and
  diagnostic exports, installation identity, server-derived approximate
  geography, audit logs, public profile/media uploads, relay/push services,
  GIPHY and explicit image search. Consent does not automatically exempt a data
  category from disclosure. Include retention and deletion behavior.
- Confirm encryption export classification/documentation for the bundled
  MLS/SQLCipher/native cryptography. `ITSAppUsesNonExemptEncryption` is currently
  unset; do not set it to `NO` merely because HTTPS is exempt. Use an approved
  classification and Apple's compliance code if required. See
  [Apple's encryption key guidance](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption).
- Validate the signed production archive in Xcode/App Store Connect and inspect
  its generated privacy report, nested SDK resources, app/NSE entitlements and
  purpose strings. Unsigned Release builds cannot validate provisioning or
  replace this upload check.
- On a physical device, check fresh permission prompts and denial/retry paths
  for camera, microphone, Face ID, location, saving media, and notifications.
  Include a non-English system language. Ensure photo/contact selection still
  works without requesting blanket library/store access.

The configured analytics retention remains **180 days**. Its recognized
statement is localized for display; unknown deployment statements are preserved
verbatim rather than silently relabeled with another policy.
