# iOS usage and diagnostics integration

This integration pins formal MarmotKit **0.9.20**, source
`2f44f6b65a19f8818644ccd7027618ba91450c33`.
It includes account-storage migrations through 67 and shared-store migration 3.
Use disposable test roots; reverting the binary is not a storage rollback.

## Published bindings

The immutable `marmotkit-v0.9.20` release contains `otlp-export` and
`product-analytics-export` for arm64 iOS and simulator (iOS 18.0 minimum).
It was built with Rust/Cargo 1.97.1. The XCFramework ZIP checksum is
`fc2e2a2046130ac78198ad067276c64b9102d0ba6757455f4b0f595cf81f7244`.
Install it with:

```sh
./scripts/sync-bindings.sh 0.9.20
```

The installer verifies the source SHA and generated Swift/binary checksums and
updates the remote package declaration and `MARMOT_VERSION` together. The
published generated API and binary come from the same formal release. Its immutable
[manifest](https://github.com/marmot-protocol/mdk/releases/download/marmotkit-v0.9.20/marmotkit-ios-0.9.20.manifest.json)
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
additional registry stays empty. The new arbitrary `recordHostTiming` API is
intentionally unused because it requires explicitly registered custom schemas.
Message-visible timings use MDK's approved host-performance enum instead: Send
through visible local bubble, and a new inbound projection through visible frame.
History reads and passive re-projections do not start these measurements. MDK's
new transport/queue/projection timings remain automatic and are not duplicated. Swift tickets prevent work begun before consent,
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

## Other 0.9.20 host contracts

- Attached presented-chat-list snapshots select title/avatar independently of
  legacy row fields. Complete updates use handle generation and sequence; title
  revision is not an unread/pin version. Store-epoch changes reopen the handle.
  A handwritten adapter forwards Swift task cancellation to the released native
  future so account switches do not retain an idle `next()` call.
- Rejoin offers are refreshed on entry and raw group-state events, including when
  ordinary group records did not change. The UI shows the authenticated inviter
  and explains replacement of local group state while retaining saved history.
  Confirmation passes the displayed Welcome ID/token; decline affects one offer.
  Automatic recovery failure does not change membership or block sending.
- Recovered onboarding approvals carry the displayed revision and recovery epoch.
  Cancellation runs before draining outstanding host calls, including approved
  attempts. Unreadable/exhausted checkpoints have a separate explicit recovery
  action that explains latest-only evidence and requires a new sign-in.

## Validation evidence

The formal 0.9.20 release passed the 1,806-test simulator suite (228 suites), the
native Swift usage/diagnostics smoke check, and strict SwiftLint. Focused tests
exercise account-free consent, failed persistence, scope reconfirmation,
independent logging, identity rotation, frozen-runtime silence, stale tickets,
and every typed event value against MDK's actual collector.

MDK's pinned storage migration checks passed 74 tests (three operational
benchmarks ignored), using temporary/in-memory databases. They cover upgrades
through the current account schema and shared consent migration preserving
legacy opt-in history, export intervals, and independent audit preferences.
These checks do not establish a safe downgrade of an upgraded device database.

The release's 33 native analytics tests passed, including storage closure before
export drain and custom host timing validation. Two native onboarding tests passed
approved/ready cancellation and recovery-epoch approval. The simulator additionally
exercises repeated cancellation of the released presented-list future, subsequent
updates on the same handle, storage closure, stale tokens/epochs, selected titles,
unchanged presentation revisions with unread changes, and bounded visibility timing.

Production and staging unsigned Release device builds passed. Both built-plist
configuration preflights passed with distinct application keys. The preflight's
Python tests cover valid HTTPS routes and malformed ports/URLs without printing
configuration values.

At the earlier analytics checkpoint, three disposable-simulator UI checks passed interrupted first launch,
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
5. Keep the immutable formal release pin, pass CI, then ship through
   the normal separately authorized release process. No app version bump or
   deployment change belongs to this integration checkpoint.
