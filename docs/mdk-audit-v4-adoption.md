# MDK audit v4 adoption

The app pins published [MarmotKit 0.9.21](https://github.com/marmot-protocol/mdk/releases/tag/marmotkit-v0.9.21),
from MDK source commit `fdd398a80f1626f1713787cebe416f7890b5b204`.
It includes audit v4, runtime-owned legacy cleanup, and the invitation KeyPackage
fixes from PRs #1779, #1782, and #1781. Relative to the development snapshot at
`ed8b98b2`, the release only adds the 0.9.21 release-preparation commit.

Install the matching published source and binary together:

```sh
./scripts/sync-bindings.sh 0.9.21
```

The package uses the immutable remote XCFramework, with SwiftPM checksum
`cf9767035bbe45cf90ee46530c4d2c661c45ab543991ea896fe69eb97ba2edf6`.
Both OTLP and product analytics exporters are enabled. The generated Swift,
remote URL, checksum, and `MARMOT_VERSION` come from the same published release.
The active local override and `LOCAL_BUILD.json` have been removed. Previous
local artifacts remain ignored under `build/` and `Packages/MarmotKit/Artifacts/`.

The iOS tracker supplies `AuditLogTrackerConfigV4Ffi` with
`AuditLogUploadSourceV4Ffi.hardwareModel`, `platform`, and `appVersion`. Hardware
comes from the system model identifier and is omitted when unavailable. Names,
hostnames, serial numbers, and account labels are not supplied as hardware.

MDK owns v4 recording, schema validation, and upload eligibility. The app's
export remains an unchanged-byte snapshot of the chosen JSONL file, including
its original filename. No schema migration or filtering is implemented in Swift.

## Runtime-owned cleanup

MDK now deletes reserved legacy v1-v3 audit files and their segments on startup,
after acquiring exclusive root ownership, including failed-wipe remnants and
when recording is disabled. It preserves v4/future files, unrelated filenames,
symlinks, and separate key-reveal logs. Cleanup failures are nonfatal and retry
on the next open. Swift does not enumerate or delete these files itself.
Logging remains enabled only for users who enabled the feature. A v4-compatible
Goggles endpoint is required for successful uploads.

## KeyPackage refresh

This release also fetches current relay KeyPackages for every Create/Invite,
regenerates packages on account activation, and drives publication retries in
the MarmotApp runtime. The native interface is unchanged by these fixes.
iOS coalesces prewarming and deduplicates unchanged member sets within the same
account/runtime; leaving the flow resets the deduplication. Prewarming remains
advisory. Create/Invite failures retain the flow and selection for retry.
Generic runtime failures cannot reliably distinguish incompatible packages from
connectivity problems, so iOS does not infer an update/regenerate message from
error text.

## Compatibility

The release also includes structured Markdown `details` blocks. Until folding is
implemented in iOS, the display renders the summary followed by its body, and
plain-text previews retain both, using the existing rendering budgets.
The added cached-search-results trigger follows the existing streamed-result
path, so cached matches appear without completing the ongoing search early.
Replacement results overwrite cached rows by account id; native follow metadata
is honored while explicit in-session follow/unfollow actions keep precedence.

## Validation

- The installer verified the published archive and generated Swift checksums.
  Both the MDK and MarmotKit 0.9.21 tags resolve to the manifest source SHA.
- Xcode resolves the remote 0.9.21 artifact. Its extracted device and simulator
  library checksums match the release manifest; all archive members support
  the iOS 18.0 deployment target. The handwritten cancellation adapter is unchanged.
- 133 tests passed across 13 suites against the published simulator library,
  including native v4 recording/export, legacy cleanup with recording disabled,
  optional hardware metadata, native cancellation, prewarm scheduling,
  Create/Invite errors, Markdown compatibility, and recipient search.
- Unsigned `Release-Production` and `Release-Staging` iPhone builds passed.
- Host permission translations and app/notification-extension privacy manifests
  passed `scripts/check-privacy-release-config.py` for both Release bundles.
- Signed-device upgrade/manual checks and actual Goggles upload receipts remain
  pending. These checks do not establish TestFlight or App Store publication.
