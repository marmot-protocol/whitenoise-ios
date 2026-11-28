# MarmotKit 0.20.0 integration and storage migration

First pinned on `develop` from `marmotkit-v0.20.0-rc.3`
(`7847b7f7ae761d41dc07784cd0308c29127b7ff9`) via `scripts/sync-rc.sh`, classified
`minor` against `v0.19.0` (`3fce95465cdea1edc8456dbd1c6691d1c8dc1f2e`).

## Storage migrations (one-way, schema 218 → 228)

MarmotKit 0.20.0 advances the per-account SQLite schema from **218** to **228**
(plus the empty-database `baseline.sql`, directory cache `0004_follows_created_at`,
and shared storage `0006_directory_follows_created_at`):

- `0219_agent_item_order.rs`
- `0220_chat_activity_creation_fallback.rs`
- `0221_agent_item_expired_targets.rs`
- `0222_small_state_broadcast_devices.rs`
- `0223_local_deletion_invitation.rs`
- `0224_epoch_gap_evidence_floor.rs`
- `0225_welcome_delivery_ledger.rs`
- `0226_local_submission_refused.rs`
- `0227_welcome_expiry_mark.rs`
- `0228_canonicalize_group_id_hex.rs`

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
  existing five snapshot subscriptions, and `uniffiRustCallAsync` dispatches
  native cancellation off Swift's `onCancel` lock (`marmot-protocol/mdk#3821`).
- **`MarmotOptions`:** Gains `disablePublicAvatarAcquisition: Bool = false`.
