# App Store privacy evidence — September 15, 2026

This records the R6 work from the App Store review. Source and artifact checks are
complete for the items below; App Store Connect answers, live retention/deletion,
and native SDK required-reason declarations remain separate checks.

## Artifacts inspected

- Local production archive: `2026-09-09/Whitenoise (Production) 09-09-2026, 13.12.xcarchive`.
  Its app and extension are version **2026.9.9 (33)**. Host permission translations
  and manifests passed the preflight; `codesign --verify --deep --strict` passed.
  This is a matching local archive, not independent proof of which binary Apple received.
- Current app source remains **2026.9.11 (34)** with published MarmotKit **0.9.21**,
  source `fdd398a80f1626f1713787cebe416f7890b5b204`. No version or binding pin changed.
- The local 0.9.21 XCFramework contains no privacy manifest. The build 33 archive
  contains only the app and extension host manifests, not a separate SDK manifest.
- Both build 33 executables import file-metadata and filesystem APIs, including
  `stat`, `fstat`, `fstatat`, `lstat`, `statfs`, and `fstatfs`. Symbol presence is a
  candidate list for source review, not proof of an approved API purpose.

## Implementation validation

- 30 Swift tests across screen privacy, app lock, and diagnostics consent passed.
- 14 Python checks passed, including archive resolution, version mismatch, and
  credential exclusion from evidence reports.
- Strict lint passed for changed Swift files; `git diff --check` passed.
- Final unsigned Release-Production and Release-Staging device builds passed;
  both built-bundle host privacy preflights passed.
- Actual device app-switcher snapshots, recording/mirroring, and iPad/VoiceOver
  behavior remain manual checks in `docs/manual-tests.md`. Simulator tests verify
  lifecycle/presenter behavior, not the OS recording pipeline.
- No build was uploaded or installed on a phone during this work.

## Repeatable checks

The host preflight now accepts `.app` or `.xcarchive`, verifies matching app/NSE
versions, and optionally emits an allowlisted JSON inventory. It never exports
build tokens, arbitrary Info.plist contents, or provisioning data.

```sh
python3 scripts/check-privacy-release-config.py /path/to/App.xcarchive \
  --report build/reviews/submitted-privacy.json

python3 scripts/check-privacy-release-config.py /path/to/App.app \
  --sdk /path/to/MarmotKit.xcframework \
  --report build/reviews/current-privacy.json
```

The SDK option inventories the supplied directory independently. It does not
establish that those SDK bytes were linked into the supplied archive. Use the
release provenance and Xcode dependency information to make that association.
A passing host check is not a complete SDK privacy audit or submission approval.

## Website reconciliation

The in-app privacy URL returned HTTP 200 and served a readable policy dated
September 9, 2026 on September 15. The broken-link finding R1 is resolved in this
live check.

The revised page still needs these targeted corrections:

1. **Audit uploads are automatic after opt-in.** Sections 4 and 7 describe a
   local-only log followed by a manual send. `MarmotClient.init` configures the
   audit tracker. In the exact released MDK source,
   `runtime/audit_tracker.rs::run_audit_log_tracker_uploader` runs automatic upload
   passes, and `post_audit_log_tracker_update` gates them on the audit setting.
   There is no separate per-file approval before each automatic pass. The app's
   diagnostic-log toggle now explicitly says it automatically uploads logs.
2. **Diagnostics has a resettable installation identifier.** Section 6's claim
   that technical diagnostics contains no device identifier conflicts with
   `TelemetryBuildConfig.runtimeConfig(installId:)`, which supplies
   `serviceInstanceId`, and with the app's existing consent disclosure. The policy
   itself elsewhere mentions rotating this identifier. Distinguish it from
   hardware identifiers or an advertising ID, rather than claiming it is absent.
3. **Retention needs backend confirmation.** The app displays a verified
   deployment statement of 180 days for product analytics. Audit retention and
   technical-metric retention need their own actual service values/processes.
   Clearing local audit files does not recall uploaded copies.

Suggested replacement for the manual-only audit paragraph, for website review:

> Diagnostic-log sharing is off by default and has a separate consent setting.
> When you enable it, White Noise records technical protocol activity locally
> and automatically uploads eligible diagnostic logs to IPF's diagnostic service.
> Logs can contain protocol identifiers, timestamps, relay addresses, and
> technical device/app information from profiles on this device. Disabling
> sharing stops new recording and subsequent automatic upload passes; an upload
> already in flight may finish. Clearing logs in the app removes local files,
> not copies already received by IPF. [Insert the verified service retention and
> deletion process.]

Suggested clarification for technical diagnostics:

> Technical diagnostics includes a randomly generated installation identifier,
> which changes after you turn sharing off. It is separate from your Nostr public
> key and from advertising identifiers. Diagnostic requests also carry technical
> resource information such as app version, operating-system version, and system
> hardware model.

These drafts describe inspected configuration and runtime behavior. Verify the
actual backend treatment before publishing the remaining retention statements.
No website changes were made in this task.

## App Privacy answers to reconcile

These are review inputs, not final App Store Connect selections. Apple's
[App Privacy guidance](https://developer.apple.com/app-store/app-privacy-details/)
requires considering partner collection and ongoing optional collection; being
opt-in is not a blanket exemption.

| Surface | Source evidence | App Store Connect review needed |
|---|---|---|
| Usage analytics | `ProductAnalyticsBuildConfig`, `ProductAnalytics`, MDK consent settings | Product interaction/performance categories; temporary sessions; the policy's server-derived country/region and daily grouping; actual linkage and purpose |
| Technical metrics | `TelemetryBuildConfig.runtimeConfig` | Performance/other diagnostics and installation identifier; resource metadata, backend retention, linkage to a device |
| Diagnostic audit uploads | `MarmotClient.init`, released MDK `runtime/audit_tracker.rs` | Diagnostic data and identifiers; automatic opt-in sharing, retained protocol references, access and deletion |
| Public profile/media | Profile setup/edit, `uploadProfileImage` | User ID, user-provided profile content/photos, public destinations, retention and provider responsibilities |
| Chat attachments | `MarmotClient.uploadMedia` | Encrypted media hosting and actual provider retention; encryption alone does not answer every data-collection question |
| Push | Native push registration and notification extension | Push token and service metadata, cleanup on disable/sign-out, actual backend persistence |
| Search/support | GIPHY, explicit web-image search, support chat | Search terms and content shared with providers/support; purpose and provider handling |

No cross-app advertising tracking integration was identified. Confirm actual
service use before declaring tracking, linkage, or “Data Not Collected.” Do not
invent a need for ATT merely because a resettable diagnostics identifier exists.

## MarmotKit upstream handoff

The current immutable package cannot be fixed by editing its expanded binary in
this app. Required work belongs in MDK's Apple packaging/release workflow:

1. Audit the exact released native dependencies and classify each required-reason
   API by its real use. In particular, SQLite filesystem calls used for locking
   or read-only flags do not by themselves justify a low-disk-space reason.
2. Supply the SDK's own declarations/resources through both Apple exporters:
   `crates/marmot-uniffi/xcframework.sh` and `xcframework-macos.sh`. The existing
   static-library packaging must preserve any privacy resource through final app
   embedding; simply dropping a file next to the ZIP is not sufficient.
3. Build a consuming archive and inspect its Xcode privacy report and packaged
   resources. Add an artifact check covering each Apple platform slice.
4. Publish a new immutable MarmotKit release, then install it using
   `scripts/sync-bindings.sh <release>` and rerun the iOS artifact checks.

Apple's [required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
and [SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
are the references. A missing manifest is not, alone, proof that MarmotKit is on
Apple's specially listed SDK list. Do not invent reasons or use the app manifest
to declare the native SDK audit complete.

## Remaining external evidence

- Submitted App Privacy selections and exact uploaded build association.
- Xcode's privacy report for the matching signed archive and native SDK purpose audit.
- Production diagnostic/audit retention and deletion configuration.
- Encryption export classification for the bundled MLS/SQLCipher/native crypto.
  The archive has no `ITSAppUsesNonExemptEncryption` key; this does not establish
  that the App Store Connect encryption questionnaire was left unanswered.

## Other review findings clarified

**R4:** Settings now presents **Delete Profile** directly below **Sign Out**.
After exact profile-name confirmation, it leaves the profile's groups, requests
deletion of its outstanding KeyPackages from known relays, clears its push
registration, and removes its local chats, drafts, media, settings, and device key
material. **Sign Out** remains non-destructive, while Privacy & Security →
**Erase App Data** deletes every local profile. Reviewer notes should explain this
non-custodial model, independent relay and recipient copies, and separately handled
uploaded diagnostics. Do not promise network-wide deletion of a Nostr identity.
Apple's [account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
requires an in-app initiation path where account deletion is applicable.
Record the full create-or-sign-in and Delete Profile flow on a physical device for
the App Review Information attachment.

**R7:** The developer already supplied reviewers a walkthrough creating two
identities and exchanging messages between them. The missing-instructions concern
is addressed by that clarification. A separate maintained peer is not a mandatory
addition; verify that the supplied two-profile flow works on the submitted build.

**R8:** No change requested. Sign Up / Sign In and the import placeholders are
intentional; the review's first-run suggestion was optional polish.

**Walkthrough videos:** App Review Information supports an Attachment for demo
videos/documents, and Review Notes can point to a hosted video. Review information
is separate from public App Preview videos and is editable at any time according
to Apple's [version-information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information).
The [review-attachments API](https://developer.apple.com/documentation/appstoreconnectapi/app-store-review-attachments)
also explicitly supports demo videos. Use an accessible, non-expiring link if
that is the practical option. Nothing was uploaded or sent to Apple here.
