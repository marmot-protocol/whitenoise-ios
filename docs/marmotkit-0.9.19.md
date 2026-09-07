# MarmotKit 0.9.19 integration

Installed with `./scripts/sync-bindings.sh 0.9.19` from the immutable
`marmotkit-v0.9.19` release, source
`a65c1fa72a984d1893edbb6be575384ae8725008`. The script verified the generated
Swift source and binary checksums and updated all four provenance/package files.

Compared with the previous `5f8db5a546ae556f59622656866e21ac1e378be8` snapshot,
the generated Swift API adds `MarmotEventFfi.groupChangeSuperseded`. There are
no new or changed method signatures or onboarding/settings record fields.
The app observes recovery events outside Developer Tools and shows a localized
notice for outcomes other than `reissued`; Diagnostics records the kind, outcome,
and reason. This is a live event stream, not durable notification history.

## Onboarding

Imports already use `beginOnboarding`, `runOnboarding`, finite off-main
`onboardingSnapshot` reads, and MDK's offered retry/skip/discovery actions.
Repair approval and single-device acknowledgment use the displayed/proposed
revision. Explicit profile/default-relay publication uses the returned proposal
revision; restored proposals are never automatically approved. Follows are skipped.
Normal account activation remains gated by readiness, cancellation state, and
the explicit Open Chats action.

The released `OnboardingSubscription.next()` still has no close/cancellation
method. Keep cancellable 250 ms snapshot polling so suspension can drain the
observer. Cancellation is idempotent and resumes `cancellationPending` checkpoints.
Approved unfinished repairs still cannot be cancelled through `cancelOnboarding`;
the existing host exit retains their journals (MDK #1741). Legacy account creation
and legacy setup recovery remain supported by this release.

## Telemetry and audit settings

`relayTelemetrySettings` / `setRelayTelemetrySettings` remain device-wide.
The analytics toggle preserves `exportIntervalSeconds` and configures the live
runtime using `setRelayTelemetryRuntimeConfig`. The persisted install ID remains
the resource instance ID. Production/staging OTLP tokens remain distinct, with
a shared endpoint and the existing resource metadata.

`auditLogSettings` / async `setAuditLogSettings` hot-swap live recorders without
restarting the runtime. Audit upload credentials enter through
`setAuditLogTrackerConfig`, separately from OTLP credentials, using the shared
compiled tracker endpoint. Disabling logging retains local files; clearing uses
`deleteAuditLogFile` and leaves the preference intact. MDK owns automatic sealed
segment batching, retries, and backoff; no host upload timer is needed.

See `manual-tests.md` for signed-device and live collector checks. Automated
settings tests establish local persistence and runtime behavior, not server receipt.
The release includes storage migrations 60–64 and versioned shared/directory
schemas; it does not support downgrading upgraded storage.

## Validation

- Production iPhone 17 Pro simulator: 1,735 tests in 217 suites passed,
  including onboarding, audit hot-swap/file retention, independent analytics
  settings, and group-recovery notice ownership.
- SwiftLint 0.63.2: zero violations across 372 files.
- Production and staging Release builds for generic iOS devices passed, including
  the notification extension, with `CODE_SIGNING_ALLOWED=NO`.
- `git diff --check` passed. Signed-device onboarding, concurrent group recovery,
  and live collector/Goggles receipt checks remain pending.
- Resolved Debug/Release settings for production and staging: credentials are
  present and mapped to the expected flavor/shared aliases. OTLP tokens differ
  between flavors; the audit token is shared and distinct from both OTLP tokens.
  Only presence/equality results were reported; token values were not displayed.
