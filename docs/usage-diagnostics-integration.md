# iOS usage and diagnostics integration

This integration pins MDK master
`5b7f17f9a0162dcc8c10ba37a41b7f652d4ed154` (analytics PR #1745).
It includes shared-store migration 2 and account-storage migration 65.
Use disposable test roots; reverting the binary is not a storage rollback.

## Published bindings

The package uses immutable snapshot
`marmotkit-snapshot-5b7f17f9a0162dcc8c10ba37a41b7f652d4ed154`, built with
`otlp-export` and `product-analytics-export` for arm64 iOS and simulator, with
an iOS 18.0 deployment target. Install it with:

```sh
./scripts/sync-bindings.sh 5b7f17f9a0162dcc8c10ba37a41b7f652d4ed154
```

The installer verifies the source SHA and generated Swift/binary checksums and
updates the remote package declaration and `MARMOT_VERSION` together. The
published generated API is unchanged from the development build. The immutable release
[manifest](https://github.com/marmot-protocol/mdk/releases/download/marmotkit-snapshot-5b7f17f9a0162dcc8c10ba37a41b7f652d4ed154/marmotkit-ios-snapshot-5b7f17f9a0162dcc8c10ba37a41b7f652d4ed154.manifest.json)
records source/builder SHAs, toolchain, features, and artifact checksums.
CI downloads the published package; it no longer builds Rust as part of app tests.
Before app tests, `python3 scripts/check-marmotkit-bindings.py` compares
`MARMOT_VERSION` with the evaluated SwiftPM binary target and compiled
`MarmotKitVersion` constants. It rejects local targets, mismatched snapshot SHAs,
URLs, checksums, and version metadata without changing package sources.

For local reproduction only, run
`./scripts/sync-local-bindings.sh /path/to/clean/mdk <full-master-sha>`.
This installs ignored local artifacts and records `LOCAL_BUILD.json`; restore
the published package with `sync-bindings.sh` before committing. Do not commit
the XCFramework or label local artifacts as published.

## Consent and counting

Welcome presents the optional consent sheet after bootstrap and before account
entry. Usage/diagnostics and forensic logging are separate, default-off decisions.
The top-right checkmark saves a decline when usage has not been granted. No receipt is stored in UserDefaults;
MDK's combined effective receipt controls first launch and migration prompts.
There is no replay of activity before consent, including initial bootstrap timing.
New-user onboarding measurements describe opted-in users, never all installations.

Typed observations cover screen visits, create/import steps, foreground readiness,
new-chat compose open/cancel, message search, attachments, settings, and system
notification permission results. MDK already registers their schemas; the host's
additional registry stays empty. Swift tickets prevent work begun before consent,
revocation, account changes, or runtime replacement from being attributed later.

Search reports one activation-to-dismissal interaction (success if the user saw a
match, empty if they entered a query without seeing matches, failure for paging
errors, cancellation without a query). Typing, passive updates, and paging ticks
are not separate actions. Picker outcomes represent a completed batch; mixed
read failures count as failure. Gallery opening is measured at image decode or
video player preparation, not receipt/decryption by another person. File export
reports its completion callback, with user cancellation classified separately.
Reserved MDK vocabulary does not imply absent iOS features have observation sites.

Background activity is best-effort alongside terminal shutdown. The latter closes
storage before its bounded drain; analytics never owns the suspension deadline.
Frozen notification runtimes stay silent. Runtime shutdown may lose memory-only
observations; no Swift disk queue or session identity is added.
The pinned MDK background setter flushes before returning and has no separate
non-flushing activity API. Awaiting it before terminal close would delay storage
release, so background activity cannot be guaranteed at suspension. Terminal
shutdown itself seals partial observations and drains after storage closes.

## Validation evidence

The published snapshot passed the 1,772-test simulator suite (221 suites), the
native Swift usage/diagnostics smoke check, and strict SwiftLint. Focused tests
exercise account-free consent, failed persistence, scope reconfirmation,
independent logging, identity rotation, frozen-runtime silence, stale tickets,
and every typed event value against MDK's actual collector.

MDK's pinned storage migration checks passed 72 tests (three operational
benchmarks ignored), using temporary/in-memory databases. They cover upgrades
through the current account schema and shared consent migration preserving
legacy opt-in history, export intervals, and independent audit preferences.
These checks do not establish a safe downgrade of an upgraded device database.

Production and staging unsigned Release device builds passed. Both built-plist
configuration preflights passed with distinct application keys. The preflight's
Python tests cover valid HTTPS routes and malformed ports/URLs without printing
configuration values.

Three disposable-simulator UI checks passed interrupted first launch,
background/resume with consent open, decline/relaunch, grant, and account-entry
cancellation. The sheet's default-off choices and revised layout were visually
checked. Real-storage tests additionally cover both grant and decline surviving
runtime replacement, independent log consent, and erasure restoring eligibility.
These checks use disposable roots and do not erase existing simulator profiles.

The local xcconfig now resolves separate production/staging keys and the full
`https://aptabase.ipf.dev/api/v0/events` endpoint. A staging HTTP smoke export
was accepted, and the operator confirmed persisted staging events in Aptabase
and reported the country-mapping issue resolved. The operator-specified retention
is 180 days; the disclosure remains “Usage analytics are scheduled
for automatic deletion after 180 days.” Keys and local config stay ignored.
These operator confirmations are distinct from automated checks of the deployed
ClickHouse policy or access logs. Signed-device interaction checks remain pending.

## Rollout gates

1. Provision separate production/staging applications at the existing Aptabase
   deployment, with keys in ignored xcconfig/CI secrets. Verify the full ingestion
   route; the dashboard URL alone does not establish it. Never use OTLP/audit tokens.
2. Verify the actual operator, server version, retention and identifying logs.
   Set the operator label and retention disclosure accordingly. Do not claim the
   180-day target is enforced just because MDK documents it.
3. Run `scripts/check-analytics-release-config.py <built-app/Info.plist>` for both
   flavors. This checks resolved configuration without printing values; it does
   not verify deployment privacy or ingestion.
4. Run the first-launch/upgrade/manual checks, and inspect persisted synthetic
   staging events as well as local status. HTTP success alone is insufficient.
5. Keep the immutable snapshot pin, pass CI, then ship through
   the normal separately authorized release process. No app version bump or
   deployment change belongs to this integration checkpoint.
