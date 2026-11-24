# Changelog

All notable changes to White Noise iOS are tracked here.

Format:

- Entries are grouped under `Unreleased` first, then by commit date until the
  repo starts tagging releases.
- Each section uses `Added`, `Changed`, `Fixed`, `Security`, and `Internal`
  where useful.
- This file was initially backfilled from the git log, so older entries are
  intentionally summarized rather than exhaustive.

## Unreleased

### Added

- Added this changelog.

### Fixed

- Queue a linked-device capability refresh as soon as maintenance detects
  an existing chat membership that needs one.
- Filled missing localized strings for shared app copy and Info.plist privacy
  prompts across the supported languages.
- Removed a bogus empty-string localization catalog entry.
- Cleaned up Swift concurrency build warnings by marking pure presentation and
  helper types as `nonisolated`.

## 2026-07-08

### Fixed

- Kept identity creation on the Marmot engine path for default pseudonyms and
  added coverage for the generated two-word profile.
- Refreshed group system row projections when the app language changes.
- Scoped stream fallback preview teardown.
- Cached group system row projection work.
- Bounded and consolidated timeline projection work across reply ordering,
  system rows, reactions, live streams, pagination, and update application.
- Sealed media export and recording lifecycle behavior.
- Hardened media downloads, media parsing, filenames, preview caching, and
  local playback/export paths.
- Vendored Marmot runtime support for preserving unrecognized profile metadata.
- Hardened profile references, relay hints, deep links, display normalization,
  and peer-controlled profile fields.
- Unified notification presentation policy and hardened notification lifecycle
  coordination.
- Kept left groups as inactive local history with explicit local delete.
- Blocked self and existing recipients while staging new chat members.
- Rendered unread mention badges in the chat list.
- Kept chat-list projections live and fresh after subscription failures,
  profile refreshes, archive transitions, and group-detail refreshes.
- Serialized conversation read-mark flushing.
- Preserved profile drafts and profile queue task ownership.

## 2026-07-07

### Changed

- Dropped the PR coverage regression gate from CI.

### Fixed

- Discarded stale settings reloads and queued rapid relay swipe deletes.
- Guarded async settings and group mutations against duplicate in-flight work.
- Localized presentation count labels for unread badges, gallery page counts,
  and relative time.
- Centralized safe audio duration labels and hardened toast duration conversion.
- Kept runtime warmup active through foreground catch-up.
- Guarded suspended runtime read paths.
- Kept background tasks alive through runtime suspension.
- Shut down the stored runtime during suspension instead of rebuilding it.
- Serialized foreground runtime resume.
- Tailored inactive chat-list swipe actions to membership state.
- Restored profile picture URL editing.
- Kept the member-picker QR scanner open across sheet re-renders.
- Limited media type length.

## 2026-07-06

### Changed

- Migrated iOS to MDK bindings and Marmot links.
- Bumped the build number.
- Lowercased the telemetry tenant name.

## 2026-07-03

### Added

- Added a CI coverage step.

### Changed

- Removed Python use from the simulator picker script.

### Fixed

- Sanitized editable relay rows.
- Fixed stale localized titles after changing language.

## 2026-07-02

### Changed

- Removed source-scraping tests and replaced them with behavior-oriented
  coverage where possible.

## 2026-07-01

### Added

- Autodetected and staged valid npub references when adding members.

### Fixed

- Improved reaction toggle performance.
- Loaded current account metadata in settings.
- Restored unread count badges in the accounts view.

## 2026-06-30

### Changed

- Reworked settings navigation and surfaced the edit-profile option.
- Strengthened agent guidance against source-text assertions in tests.

## 2026-06-29

### Changed

- Swapped the splash and welcome surfaces to the White Noise icon.
- Updated versions and Marmot bindings.

## 2026-06-27

### Changed

- Updated Marmot and enabled full data mode for logs.

## 2026-06-26

### Added

- Added CI test workflow support.
- Set flavor-specific display names and native push public keys.

### Fixed

- Re-armed bootstrap background suspension.
- Avoided duplicate media cache probes.
- Preserved confirmed sends during window refresh.
- Guarded concurrent account activation.
- Leased composer draft playback sessions.
- Guarded group archive actions.
- Localized group notification previews.
- Guarded non-finite audio duration labels.
- Guarded duplicate identity imports and identity creation reentry.
- Sanitized decoded IDN host display.
- Guarded profile publish reentry.
- Evicted departed account profile projections.
- Bounded stream debug timeline rows.

## 2026-06-25

### Added

- Added SwiftLint and lint CI wiring.

### Changed

- Cleaned up White Noise iOS schemes.
- Set up flavors and White Noise icons.

### Fixed

- Removed left chat rows after swipe leave.

## 2026-06-24

### Changed

- Extracted `RuntimeLifecycle` from `AppState`.
- Extracted `NotificationCoordinator` from `AppState`.
- Locked raw Marmot access behind `MarmotClient`.
- Extracted shared recipient staging helpers.
- Pinned timeline projection cache boundaries.

### Fixed

- Gated sensitive clipboard clearing on real paste change counts.
- Cached failed remote avatar loads.
- Prevented stale notification settings reloads.
- Guarded group image web searches.
- Downloaded remote images via chunked `URLSessionDataDelegate`.
- Cached resolved group display names.
- Bounded reply preview media parsing.
- Guarded profile-message group creation against duplicate work.
- Memoized notification-service settings reads.
- Stabilized timeline row identity for confirmed records.
- Serialized notification settings actions.

### Security

- Hardened pasteboard handling so typed or unrelated clipboard contents are not
  wiped after nsec import flows.

## 2026-06-23

### Added

- Added the thin-shell refactor plan for pushing projections into Rust and
  decomposing app state.

### Changed

- Refreshed MarmotKit bindings.
- Bumped version metadata.

### Fixed

- Included videos in fullscreen media galleries.
- Bounded peer-controlled profile image URL display.
- Recomputed only changed reaction targets.
- Pruned chat-list enrichment caches on snapshot replacement.
- Sanitized transcript export group names.
- Made chat destination lookup O(1).

## 2026-06-22

### Changed

- Refreshed MarmotKit and improved chat loading.
- Prevented runtime reopen during background suspension.

### Fixed

- Added `Copy npub` to group member contextual menus.
- Used stable per-position identity for sanitized relay rows.
- Gated settings reads during runtime suspension.
- Sanitized published relay lists in relay settings.
- Cleared profile projection cache on sign-out.
- Kept non-previewable message kinds out of chat-list preview bodies.

## 2026-06-21

### Added

- Added chat-list DM titles and identity key export UI.
- Adopted MarmotKit v0.2.0 account and push lifecycle APIs.

### Fixed

- Charged avatar cache entries by decoded bitmap cost.
- Ran decrypted-media cache I/O and eviction off the MainActor.
- Validated HTTP 2xx status for remote image fetches.
- Pruned optimistic reaction removals after confirmed un-react.
- Bounded profile projection load-version bookkeeping.
- Made native push runtime rebuild best-effort.
- Cached media attachment projections.
- Reconciled failed optimistic outgoing echoes.
- Sanitized image-search result titles.
- Avoided repeated image alt length scans.

## 2026-06-20

### Changed

- Bumped version to 2026.6.20.
- Switched chat-list unread state to Marmot account unread summaries.
- Disabled the composer for inactive groups.

### Fixed

- Cancelled received-audio load and playback tasks on view disappearance.
- Fixed build warnings and confirmation dialogs.
- Improved slow first chat-open after foreground resume.
- Released onboarding-phase runtimes on background suspension.
- Configured audio sessions for video attachment playback.
- Stripped residual invisible format characters from relay and URL display.
- Offloaded profile reference resolution.
- Rejected SIIT and NAT64 profile image hosts.

## 2026-06-19

### Changed

- Refreshed Marmot bindings.

### Fixed

- Cached profile QR image rendering.
- Fixed chat media bottom anchoring.
- Offloaded account relay-list FFI in profile paths.
- Bounded conversation read-mark deduplication.
- Offloaded chat-list and relay-list reads.
- Closed push re-registration windows during sign-out teardown.
- Blocked IPv6 multicast, 6to4, Teredo, and other reserved hosts in SSRF
  allowlists.
- Let remove-image bypass draft validation.
- Avoided regex recompilation in message semantics.
- Guarded transcript export pagination cursor progress.
- Offloaded chat-list subscription snapshots.
- Capped notification-service additional presentations.
- Prepared received-audio playback off the MainActor.
- Reduced media grid clipping work.
- Used durable system event timeline timestamps.
- Removed dead profile edit success state.
- Cached chat-list preview text.
- Preserved paginated timeline history on live updates.
- Reset notification retry backoff on subscribe.
- Rolled back native push default-enable failures.

## 2026-06-18

### Fixed

- Avoided stream bubble timeline scans.
- Sanitized peer-controlled agent timeline text.
- Precomputed lowercased mention-filter fields.
- Sanitized group relay rows against bidi and zero-width spoofing.
- Bounded punycode host decode cost in link confirmations.
- Budgeted markdown table display cells.
- Capped profile reference parsing before URL fallback.
- Showed unclassified key packages.
- Bounded decrypted media caches.
- Disambiguated media and text pending bubbles in the reconciler.
- Rejected SVG and non-image bytes in media thumbnail decoding.
- Offloaded live subscription snapshots.
- Capped DuckDuckGo image-search results.
- Blocked CG-NAT and other reserved IPv4 ranges in SSRF allowlists.
- Capped remote image fetch response bytes.
- Parsed markdown off the MainActor in send paths.

## 2026-06-17

### Fixed

- Threaded display scale and geometry into message-media thumbnail loaders.
- Read display scale from environment in remote group thumbnails.
- Clamped relay-influenced size and timestamp values in key-package rows.
- Configured voice playback audio sessions.
- Preserved just-sent media when upload returned no message id.
- Guarded punycode code-point accumulation against overflow.
- Skipped re-scanning finalized stream anchors on each page.
- Drained prior native-push tasks before rescheduling sync.
- Normalized staged recipients off the MainActor.
- Charged markdown node budget per list item.
- Stopped background suspend racing foreground resume into stuck suspension.
- Removed dead incremental timeline-update paths.
- Decoded fullscreen images off-main, bounded, and only once.
- Cleared stream watch task entries when watches end naturally.
- Normalized uppercase npub member references.
- Guarded notification presentation during suspension.
- Bounded message media thumbnail decoding.
- Rejected numeric profile address domains.
