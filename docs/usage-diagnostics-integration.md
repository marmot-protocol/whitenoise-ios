# iOS usage and diagnostics integration

This development integration targets MDK master
`5b7f17f9a0162dcc8c10ba37a41b7f652d4ed154` (analytics PR #1745).
It includes shared-store migration 2 and account-storage migration 65.
Use disposable test roots; reverting the binary is not a storage rollback.

## Local bindings

Run `./scripts/sync-local-bindings.sh /path/to/clean/mdk <full-master-sha>`.
The checkout must be clean and match that SHA. The script enables both exporters,
builds Swift plus arm64 device/simulator artifacts, validates deployment target
18.0, packages checksums, and installs the ignored local XCFramework.
`Packages/MarmotKit/LOCAL_BUILD.json` records provenance. The local binary pin
intentionally fails if its matching artifact is absent; it never falls back to
an older binary. A fresh checkout must run this local setup while the PR remains in development.
CI checks out the pinned MDK source, builds both exporters, and verifies the
generated Swift matches the checked-in binding before testing.

Before merge publish the same source as an immutable MarmotKit snapshot, run
`./scripts/sync-bindings.sh <full-master-sha>`, and validate the resulting remote
package. Do not commit the XCFramework or label local artifacts as published.

## Consent and counting

Welcome presents the optional consent sheet after bootstrap and before account
entry. Usage/diagnostics and forensic logging are separate, default-off decisions.
Closing without a usage grant saves a decline. No receipt is stored in UserDefaults;
MDK's combined effective receipt controls first launch and migration prompts.
There is no replay of activity before consent, including initial bootstrap timing.
New-user onboarding measurements describe opted-in users, never all installations.

Typed observations cover screen visits, create/import steps, foreground readiness,
new-chat compose open/cancel, message search, attachments, settings, and system
notification permission results. MDK registers those schemas; the host also
registers the aggregate stages in [host timings](host-timings.md).
Swift tickets prevent work begun before consent,
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

## Validation evidence

The local integration passed the 1,769-test simulator suite (221 suites), the
native Swift usage/diagnostics smoke check, and strict SwiftLint. Focused tests
exercise account-free consent, failed persistence, scope reconfirmation,
independent logging, identity rotation, frozen-runtime silence, stale tickets,
and every typed event value against MDK's actual collector.

MDK's pinned storage migration checks passed 72 tests (three operational
benchmarks ignored), using temporary/in-memory databases. They cover upgrades
through the current account schema and shared consent migration preserving
legacy opt-in history, export intervals, and independent audit preferences.
These checks do not establish a safe downgrade of an upgraded device database.

Production and staging unsigned Release device builds passed. A disposable
simulator visually confirmed the initial compact sheet over Welcome with both
switches off. Signed-device interaction checks and persisted staging ingestion
remain outstanding. The configuration preflight currently rejects both flavors
because the ingestion endpoint, Aptabase keys, and verified retention are absent.

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
5. Replace local bindings with the immutable snapshot, pass CI, then ship through
   the normal separately authorized release process. No app version bump or
   deployment change belongs to this integration checkpoint.
