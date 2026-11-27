# MarmotKit 0.20.0 integration and storage migration

First pinned on `develop` from `marmotkit-v0.20.0-rc.2`
(`a3228a2c572f2c91bbc5948160bbe890f20888a2`) via `scripts/sync-rc.sh`, classified
`minor` against `v0.19.0` (`3fce95465cdea1edc8456dbd1c6691d1c8dc1f2e`).

## Storage migrations (one-way, schema 218 → 227)

MarmotKit 0.20.0 advances the per-account SQLite schema from **218** to **227**
(plus the empty-database `baseline.sql` starting point):

- `0219_agent_item_order.rs`
- `0220_chat_activity_creation_fallback.rs`
- `0221_agent_item_expired_targets.rs`
- `0222_small_state_broadcast_devices.rs`
- `0223_local_deletion_invitation.rs`
- `0224_epoch_gap_evidence_floor.rs`
- `0225_welcome_delivery_ledger.rs`
- `0226_local_submission_refused.rs`
- `0227_welcome_expiry_mark.rs`

**Downgrade across these migrations is unsupported.** An older build (0.19.0 or
earlier) refuses an upgraded account database.

- The **main app and Notification Service Extension** share the App Group
  Marmot root and must always be updated together from the same build.
- **Test RCs only with `Whitenoise (Staging)`** (`group.dev.ipf.whitenoise.ios.staging`),
  which is isolated from `Whitenoise (Production)` (`group.dev.ipf.whitenoise.ios`).
- Before shipping Stable `0.20.0` on `master`, run the "In-place MarmotKit
  upgrade" check in [docs/manual-tests.md](manual-tests.md) on a signed device.

## UniFFI breaking changes addressed

- **Agent items (kinds 1201 / 1202):** `TimelineMessageRecordFfi` gains
  `agentItem: AgentItemFfi?` and `agentItemFirstEventMissing: Bool`;
  `TimelineUpdateTriggerFfi` replaces `.agentActivity` and `.agentOperation`
  with `.agentItem`; `NotificationTrafficClassFfi.agentActivity` is removed (MDK
  now notifies on `.standard` only when an agent item's latest version has
  `alerts == true`, or for non-commentary final agent words). Answers and
  controls publish kind `1202` through `sendCustomEventWithClientToken`.
- **Local send status:** `LocalSendStatusFfi.queued` and `.engineOwned` carry
  `messageIdHex: String`, and `.refusedNewMembers` is added and treated as a
  definitive rejection in `ComposerModel`.
- **Reply preview retention:** `TimelineReplyPreviewFfi` gains
  `retentionSeconds: UInt64?` and `retentionExpiresAt: UInt64?`.
- **Error & onboarding copy:** Added user-facing copy for
  `MarmotKitError.IncompatibleKeyPackage`, `MarmotKitError.RelayCheckRunning`,
  and `OnboardingIssueFfi.rateLimited`.
- **Generated subscription cancellation:** `OnboardingSubscription` and
  `EventsSubscription` now ship generated `nextCancellable()` alongside the
  existing five snapshot subscriptions.

## Known RC issue to resolve before Stable `0.20.0`

- **UniFFI async cancellation ABBA deadlock (`0.20.0-rc.2`):** The generated
  `uniffiRustCallAsync` helper added in `0.20.0-rc.2` calls
  `ffi_marmot_uniffi_rust_future_cancel_*` synchronously inside
  `withTaskCancellationHandler`'s `onCancel` closure while Swift Concurrency
  holds the `AsyncTask`'s `StatusRecordLock`. If a `marmotkit-rt` Tokio worker
  wakes that same `RustFuture` concurrently, `uniffi_core::RustFuture::wake`
  holds the future's `std::sync::Mutex` while calling
  `uniffiFutureContinuationCallback` → `UnsafeContinuation.resume(returning:)`,
  which acquires `StatusRecordLock`, deadlocking both threads (reproduced under
  heavy cancellation churn in `AppStateBootstrapTests` during
  `NotificationDriver.stop()` → `subscribeNotifications()` cancellation). Fix
  upstream in `marmot-protocol/mdk` (e.g. dispatch `cancelFunc` off `onCancel`
  or resume outside the `RustFuture` mutex) and pick up the next RC via
  `just sync-rc` before promoting `0.20.0` to Stable.
