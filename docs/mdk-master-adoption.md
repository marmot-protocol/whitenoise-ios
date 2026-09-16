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
