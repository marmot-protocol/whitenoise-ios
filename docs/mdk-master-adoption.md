# MarmotKit 0.10.0 integration

The installed package is the published `marmotkit-v0.10.0` release from
`4800db0e2901b5be996f32d095f8aabb6d7ae013`. Generated Swift and the remote binary
were installed together with `scripts/sync-bindings.sh 0.10.0`.

- Chat filters use bounded MDK windows; account attention supplies badges independently.
  Pending invitations contribute through MDK's attention total exactly once.
  Unavailable account counts display explicitly, retaining cached icon totals;
  without a cached total, the app leaves the system badge unchanged.
- Conversations consume prepared windows and replace all retained rows, with
  generation/sequence fencing, visible anchors, explicit read acknowledgements,
  and cancellation before retirement. Window identities remain separate from rosters.
  Reaction chips use viewer-aware bounded summaries and disclose truncated previews.
- Draft saves, clears, attachment reads and sends use selected revisions. Conflicts
  preserve local editing and require a choice. Sending never performs a later delete.
- Blocking is available from profiles/direct-chat info and Privacy & Security.
  Uncertain publications expose a retry of the same intent.
- Local group reset stays under Chat Developer Tools with destructive confirmation.
  No leave/disband is sent; a fresh invitation is required afterward.
- Key-package developer tools include current and superseded relay-event history.

Storage migration 75 is not downgrade-compatible. Use fresh simulator storage or
back up existing data before running this release. SDK privacy resources are
packaged with the static framework; App Store privacy/audit acceptance is separate.

## Conversation live-update behavior

Prepared snapshots remain the sole authoritative retained window. iOS compares
rows before applying them, preserves MDK order, and layers bounded local sends
above that mirror. Exact send-summary message IDs bind local display identities
to protocol IDs; repeated snapshot rows never acknowledge sends by matching text.
Pending attachment bytes retire when the authoritative row arrives. Once mirrored,
rows follow window eviction; absence before that handoff does not mean deletion.

Viewport intent distinguishes following latest from reading history. Rejected stale
commands retry against received revisions with a finite attempt budget. Timeout
and NotReady can follow admission, so they await stream completion rather than
replaying a page. Recoverable receive errors keep the same native handle; closure
reopens using the current navigation intent.

MarmotKit 0.10.0 supplies no pre-completion host send-correlation token. A durable
row arriving before its send result can temporarily coexist with the local echo;
the exact result merges them without changing the local display ID. An outcome
without an ID stays unresolved for the session, never guessed or resent. Local
echoes are capped at 200; capacity returns after reconciliation, discard of failed
sends, or session reset. Improving exact early correlation requires a separate MDK
API change. New edit metadata, system-event provenance, local-first opening, and
incremental prepared streams remain separate future binding work.

## Current validation

Build 36 checkpoint: app and NSE use `2026.9.16 (36)` in both flavors.
Production's targeted simulator run passed (110 tests reported in 14 suites;
the relay-dependent account-creation diagnostic was explicitly skipped).
Both unsigned device Release builds and host privacy checks passed at build 36.
Strict SwiftLint 0.63.2 passed across 449 files. The prior staging upload's
framework-stub symbol warning is documented as a distribution warning, not a
failure of these build checks; a new upload has not been performed here.

- Published source/binary/checksum installed together; native cancellation exercised.
- 91 targeted simulator tests passed on the isolated iOS 26.5 integration simulator,
  covering window bindings, draft conflicts/edit-during-send, attention, retained
  anchors, media outcomes, and group action/reset behavior.
- Follow-up runs passed: 29 draft/group/long-chat scroll tests and 19 prepared
  chat-list/conversation-control/native-draft tests.
- Production and Staging unsigned device Release builds passed, including host
  permission translations and app/extension privacy checks. Both app bundles
  contain `Frameworks/marmot_uniffiFFI.framework/PrivacyInfo.xcprivacy`.
- The current signed simulator build launches; its Welcome terms line was visually
  checked in `/tmp/wn-010-welcome-final.png`.
- Strict SwiftLint 0.63.2: 448 files, zero violations. `git diff --check` passed.
- Physical-device performance, cross-device block/reinvite, and APNS/NSE checks
  remain in `docs/manual-tests.md`. The simulator UI automation surface was not
  available; interactive screen acceptance remains manual.

The following section records the earlier local-snapshot investigation, not a
current finding against the published release. The user asked to defer it.

## Historical investigation: attention and second-account creation

This was observed on the earlier `dcb3c1c3` local snapshot.

Reproduction is in `AccountAttentionCreationTests`. It is an opt-in manual
integration diagnostic: set `WN_RUN_ATTENTION_CREATION_DIAGNOSTIC=1` in the test
process environment. It requires working relay publication/readiness and is not
part of the default offline regression gate.

A build-36 run against 0.10.0 failed the first identity's `networkReady`
prerequisite (including with attention disabled). That run did not establish a
second-account regression or validate its absence; the investigation remains
explicitly deferred.

Historical reproduction steps:

1. Bootstrap a fresh temporary Marmot root.
2. Create a generated identity and wait for `accountSetupReadiness == networkReady`.
3. Create a second generated identity.
4. Repeat with only the host's account-attention subscription enabled/disabled.

With attention disabled, both identities are created. With attention enabled, the
second `createIdentity()` throws `MarmotKitError.Runtime` with details
`backend failure: file is not a database`. Native logs also report SQLCipher page-1
HMAC/decryption failures. This occurs before the multi-account test reaches sign-out
or account switching.

The broader suite reproduces the same failure in four existing multi-account
fixtures. This establishes the triggering integration, **not yet the exact Rust
root cause**. Relevant upstream paths to investigate are account-attention catalog
discovery/account-state preparation and concurrent encrypted account-storage
creation. No persistent data was reset as a workaround, and MDK source was not
modified.

The unsigned Production Release build for a generic iPhone also succeeded
(`/tmp/whitenoise-adoption-release-build.log`). This establishes compile/link
compatibility, not readiness to ship past the runtime blocker.

Logs from this checkout:

- `/tmp/whitenoise-attention-creation-isolation.log`: enabled/disabled reproduction.
- `/tmp/whitenoise-adoption-regression-tests.log`: 179 of 183 tests passed; four
  multi-account fixture failures above.
- `/tmp/whitenoise-adoption-native-viewport-tests.log`: 29 tests passed, including
  rendered retained/recovered List anchors, draft draining, native subscriptions,
  cancellation, and idempotent group reset.
- `/tmp/whitenoise-adoption-final-tests.log`: 28 tests passed after the final reset,
  attention-store, and presented-list adjustments. Strict SwiftLint and
  `git diff --check` also passed.
- `/tmp/whitenoise-adoption-focused-tests2.log`: 46 tests passed for attention-store
  semantics, attachment projection, and group-action success/failure handling.

Physical-device recovery of an existing broken group and a fresh cross-device
reinvite remain manual checks. See `docs/manual-tests.md`.

## Local master build for device exploration (2026-09-16)

The current local package uses MDK `f420c355fb2f52c9edda1ce62620dd21900af56b`,
with `otlp-export` and `product-analytics-export`. It was built from a clean,
isolated checkout using `scripts/sync-local-bindings.sh`. `LOCAL_BUILD.json`
records artifact hashes and toolchain; the XCFramework remains ignored.
This is an unpublished local override, not a MarmotKit release pin.

Host compatibility changes:

- Copy MDK's separately generated privacy manifest into the Swift package's
  resource bundle. The new XCFramework contains raw static libraries, not a
  codeless framework wrapper.
- Render prepared edited bodies directly, consume their edit summary, and load
  accepted edit versions through the paged, off-main history query. That query
  excludes the original body; never label an effective edited body as original.
- Use authenticated group-system projections and prepared chat-preview names.
  Member-authored assertions must not become trusted membership/admin notices.
- Preserve the handwritten native cancellation adapter and local-send display IDs.

Do not publish the local artifact or its generated bindings as a release pin.
A future published adoption must synchronize Swift, binary, privacy resource,
checksums and provenance together. Physical-device validation remains separate.

Local validation: both unsigned Release flavors and host privacy checks passed;
app and NSE SDK resource manifests match the build output, with no framework
wrapper embedded. The focused integration run passed 77 tests. The additional
native/lifecycle run passed 45 of 47: two preexisting multi-account setup tests
still reported SQLCipher “file is not a database”; native conversation and
presentation-subscription cancellation tests passed. No physical-device or
TestFlight upload validation is implied.

## Published 0.10.1 adoption

The local override above is superseded by `marmotkit-v0.10.1`, source and builder
`fcc6f67609113f9bb1547b7de0ba22c65437ccd3`. The immutable SwiftPM binary checksum
is `44c959ffa62aa76307ad8b6ced0342042a0a4d31224e3da46ad0aa1d11ff8e22`.
`scripts/sync-bindings.sh` now verifies the separate privacy asset, its sibling
checksum and manifest metadata before installation, and stages it as a Swift
wrapper resource consumed by both app and NSE. The generated Swift matches the
published asset after the installer's existing trailing-whitespace normalization.

Chat rows, conversation headers, sender avatars and reaction details consume
MDK avatar metadata. Visible views register demand and read protected native
bytes; only transient decoded pixels remain in those views. Group/contact info
uses the prepared header title and avatar, while roster/admin operations keep
using MDK's combined group conversation snapshot. UI draft/send/scroll state and
localized nickname overrides remain host-owned. Account attention continues to
own badges independently of filtered chat windows.

Group members can report through the long-press menu. Admin review pages native
reports and reads `reportedMessage` so personal blocking does not hide review
content. Dismissal labels and admin deletion are separate operations. Existing
projection events refresh the review list, and pending acceptances are not shown
as completed moderation. Native authorization is still decisive. Reports travel
inside the encrypted group; this does not add centralized developer enforcement.

Validation distinguishes the offline native fixture (report storage and pending
moderation, not delivery) from deterministic host tests (permissions, dismissal
versus deletion, pending duplicate prevention, failure retention, avatar-only
updates). Physical-device, multi-device relay propagation, accessibility and
upgrade checks remain in `docs/manual-tests.md`.

Automated checks for the published pin passed: the 74-test integration run,
follow-up native cancellation and notification suites, and the final 47-test
projection/moderation/menu run. Avatar-only identity updates do not rebuild
markdown or initiate scroll handling. Report review has a separately scoped
projection observer, so pushing Group Info does not stop live review updates;
account switches disable actions on the old conversation. Both final unsigned
Release builds (Production and Staging), app/NSE privacy checks, SwiftLint and
`git diff --check` passed. Version/build remain 2026.9.16 (37). These checks do
not establish physical-device behavior, multi-device report delivery, or Store
upload success.
