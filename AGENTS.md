# Agent Notes

This repo is a SwiftUI iOS app around the Darkmatter/Marmot Rust runtime. Read this before changing code.

`AGENTS.md` is the canonical agent guidance file. `CLAUDE.md` should remain a symlink to this file for Claude-based tooling.

## Start Here

- Main app entry point: `darkmatter-ios/darkmatter_iosApp.swift`
- Global state and runtime ownership: `darkmatter-ios/Core/AppState.swift`
- Marmot wrapper: `darkmatter-ios/Core/MarmotClient.swift`
- Shared app/extension config: `Shared/AppContainerConfig.swift`
- Notification projection: `Shared/LocalNotificationProjection.swift`
- NSE projection policy: `Shared/NotificationServiceProjection.swift`
- Transcript export: `darkmatter-ios/Core/ConversationTranscriptExport.swift`
- Media cache and draft image processing: `darkmatter-ios/Conversation/MessageMediaAttachment.swift`
- Manual release checks: `docs/manual-tests.md`

## Architecture

Swift owns UI, app lifecycle, navigation, presentation state, and iOS notification plumbing. Marmot owns accounts, MLS group state, storage, relay catch-up, message processing, and push-token cryptography.

`AppState` is the app's observable hub. It owns the `MarmotClient`, active account, phase routing, pending navigation, toasts, visible-chat tracking, notification subscription, native push sync, and runtime suspend/resume around app backgrounding.

Bootstrap retry is user-visible from the startup failure screen and may happen
after the runtime was released for background suspension. Starting the runtime
from bootstrap must clear foreground/suspension gates and increment runtime
generation just like foreground resume.
If bootstrap fails after creating or starting a runtime, release that partial
runtime before showing the failure screen so Retry rebuilds a fresh runtime.

Background task identifiers used during runtime suspension must be owned and
ended on the MainActor; UIKit expiration and completion paths should share an
idempotent end helper.

Keep lightweight popovers/sheets, such as the emoji picker, out of navigation
containers unless they actually need navigation state. Stable option models and
grid metadata should be precomputed outside `body`.

Conversation initial positioning may hide timeline content until the first
layout-driven scroll to the bottom or targeted message has settled. Keep that
path cancellable and tied to scroll/layout callbacks, not fixed delay chains.

Prefer behavior-level regression tests over `String(contentsOf:)` source
scrapes. When a private SwiftUI or async path needs coverage, extract a small
pure helper for the decision point first; reserve source checks for constraints
that truly cannot be observed otherwise.

`Shared/` is compiled into both the main app and the Notification Service Extension. Keep code there extension-safe. Do not use `UIApplication`, app delegates, SwiftUI views, or APIs unavailable to extensions from shared files.
Keep keyboard notification adapters and other SwiftUI/UIKit-only helpers in the app target; `Shared/` may hold CoreGraphics-only layout constants that the extension can compile safely.

## Rust Bindings

The generated Swift bindings and static library live in `Vendored/MarmotKit`. The source of truth is the sibling Darkmatter repo, normally at `/Users/jeff/code/darkmatter`.

Regenerate with:

```sh
./scripts/sync-bindings.sh
```

or:

```sh
DARKMATTER_DIR=/path/to/darkmatter ./scripts/sync-bindings.sh
```

Do not patch generated binding files directly. Change Rust/UniFFI, regenerate, then validate the iOS app.

## Notifications

The app uses privacy-preserving MIP-05 native push.

- Main app bundle ID: `dev.ipf.darkmatter`
- NSE bundle ID: `dev.ipf.darkmatter.NotificationService`
- App Group: `group.dev.ipf.darkmatter`

Rules for notification work:

- APNS payloads must stay generic.
- Do not include account IDs, group IDs, sender names, message IDs, or plaintext in provider payloads.
- APNS pushes target the main app bundle ID, not the extension bundle ID.
- The Notification Service Extension may enrich the visible notification only from local Marmot state after `collectNotificationsAfterWake`.
- The Notification Service Extension must honor each account's `localNotificationsEnabled` setting before rendering decrypted sender or preview content.
- The Notification Service Extension cannot suppress an alert that already woke it. If no local presentation exists, deliver the generic fallback content rather than blank content.
- The Notification Service Extension should keep primary and additional local presentations alert-consistent, including `UNNotificationSound.default` when rendering visible message content.
- Do not abandon additional NSE presentations after `collectNotificationsAfterWake`; those records have already been consumed from Marmot's background notification cursor.
- Native push relay hints from configuration must be validated with the shared `RelayURL` normalizer; malformed hints should behave like an omitted hint.
- Sign-out must cancel and await any in-flight native-push registration sync before clearing the removed account's push registration.
- Disabling native push must flip the local preference off before clearing the server registration, and roll the preference back on if registration cleanup fails.
- Foreground resume must schedule native-push registration independently from relay catch-up success; catch-up failures are best-effort and must not skip push reconciliation.
- Main-app and NSE local notification presentation must fail open if a settings read throws; only an explicit disabled setting should suppress.
- The main-app notification subscription must resolve `localNotificationsEnabled` off the MainActor before running foreground suppression.
- `NotificationDriver` task state is MainActor-owned; runner completion must hop back to MainActor before clearing task storage.
- Notification subscription retry failures should show at most one generic user-facing banner per outage; do not surface raw backend error descriptions in that toast.
- The main app should not keep the Marmot runtime alive indefinitely in the background. It suspends the runtime on background and restarts it on foreground.

If notifications are flaky, check token registration, group push-token gossip, relay hints, transponder visibility on the relay, and NSE timeout behavior before changing UI code.

## Remote Image Search

The group image web search is an explicit third-party egress surface. Keep DuckDuckGo requests and result thumbnail fetches on ephemeral, no-cookie/no-cache URL sessions, and keep the in-app disclosure aligned with the actual hosts contacted. Do not use `URLSession.shared` or SwiftUI `AsyncImage` for this search/preview path.

## Storage

- `UserDefaults` stores app preferences such as active account, developer mode, recent reactions, and per-account diagnostics self-check group IDs.
- The shared App Group container stores the Marmot root used by both app and extension.
- Marmot stores account secrets in the Keychain.
- Decrypted media cache files under `Caches/EncryptedMedia` must set complete file protection on both the directory and cached plaintext files.
- Temporary transcript export JSON files contain raw conversation event history; write them with complete file protection and remove them after the share sheet completes or dismisses.

Do not add a second storage path for data Marmot already owns.

## Code Style

- Follow the existing SwiftUI and Observation patterns.
- Keep feature state in view models when it is screen-specific.
- Put cross-screen app state in `AppState`.
- `AppState.telemetryBuildConfig` must use the live runtime config when present
  and a cached fallback while the runtime is suspended; do not recompute
  `TelemetryBuildConfig.current()` from the accessor.
- `AppLanguage.didChangeNotification` carries the selected language in
  `userInfo`; leave `object` nil so future sender-scoped observers keep
  working.
- AppLanguage uses process-scoped defaults under unit tests. Tests that verify
  language preference writes should inject isolated `UserDefaults` and
  `NotificationCenter` instances instead of mutating the shared app preference.
- Keep pure formatting/projection helpers in `Shared/` only when the extension also needs them.
- Use `LocalNotificationProjection` for notification title/body/thread/userInfo decisions.
- Use `LocalNotificationSuppressionPolicy` for foreground suppression decisions.
- Audit-log settings hot-swap against the running Marmot runtime; do not restart the runtime for a settings toggle.
- Audit-log uploads and OTLP metrics use separate bearer-token settings. Do not reuse the OTLP token for Goggles audit-log uploads.
- Privacy/audit settings screens should load Marmot settings and audit-file details through off-main projection helpers, then render precomputed row strings from SwiftUI body.
- Normalize optional group metadata before handing it to Marmot. Group names and descriptions go through `ProfileSanitizer`; blank descriptions pass `nil`, unnamed group creates use MarmotKit's empty-string sentinel, and blank renames are rejected.
- Sanitize peer-controlled group names with `ProfileSanitizer.groupName` before storing or rendering timeline/system-event display strings, and use static `L10n.formatted` keys for dynamic text.
- Use `L10n.plural` for dynamic counts and static `L10n.formatted` keys for formatted strings so the string catalog can carry plural variations and translations.
- Chat-list relative time labels must use localized duration/date formatters; do not hand-build minute/hour suffixes or date patterns. If `RelativeTime.short` receives an injected `now`, today/yesterday bucketing must compare against that value rather than the device wall clock.
- Route peer-controlled profile and group image URLs through `ProfileSanitizer.imageURL`; it only allows HTTPS public hosts and rejects local/private IPv4/IPv6 hosts, loopback/unspecified/link-local forms, IPv4-mapped and IPv4-compatible IPv6 embeddings, and legacy IPv4 literal spellings.
- External markdown-link confirmations must render bounded, sanitized URL text and explicitly flag IDN/punycode hosts; do not show unbounded peer URL strings verbatim.
- Media attachment display IDs must include the owning message or timeline-row identity; do not key SwiftUI media views solely by the encrypted media reference.
- Timeline row geometry preferences must be keyed by `TimelineItem.rowFrameKey`/row identity, not `messageIdHex`, because pending, failed, and live stream rows can have empty message IDs.
- Malformed or unsupported media `imeta` fields must not hide kind-9 messages; degrade to chat text unless a valid encrypted-media reference is available, and keep optional fields such as `thumbhash` bounded and validated.
- Fullscreen media galleries are image-only. Reject non-image initial items before presentation and surface undecodable image bytes as an explicit failure state rather than an idle spinner.
- Media downloads should pass through the conversation view model's in-flight store so duplicate thumbnail/gallery requests share one decrypt/download task.
- Conversation media record refreshes must keep the message-id map and normalized attachment lookup index in sync; download paths should not scan every media record to recover `sourceEpoch`.
- Draft photo attachment decoding, downsampling, JPEG encoding, and thumbnail generation should run off the MainActor; hop back to the UI actor only to append prepared drafts or surface errors.
- Chat-list subscription row bursts should be coalesced before publishing SwiftUI-observed arrays; keep durable row/item caches keyed by group id and update only affected avatar rows after backfill.
- Markdown display blocks are cacheable per message content and profile refresh generation; do not call `MarkdownMessageBuilder.displayBlocks` directly from bubble body paths.
- Markdown preview/plain-text walkers must budget table rows and cells, including empty cells, so hostile ASTs cannot bypass node limits.
- Developer-mode streaming debug may show agent-stream MLS events and live QUIC update rows in the conversation timeline. Console logs for agent streams should log sizes, counts, hashes, and stream ids rather than plaintext message content.
- Build user-visible date formats from localized templates rather than raw `DateFormatter.dateFormat` patterns.
- When a sheet folds typed pending input into a submit action, abort on invalid pending input before clearing validation errors or starting async work.
- Recipient-staging sheets should parse with `AddMembersPresentation`, normalize through Marmot to `MemberRefFfi`, and deduplicate staged recipients by `accountIdHex` rather than raw input text.
- Do not use `abs` on wrapped or peer-influenced integer hashes; use magnitude or unsigned modulo helpers that are safe for `Int.min`.
- Import identity flows should consume and clear pasted nsec state before awaiting Marmot, while still clearing matching pasteboard contents on every outcome.
- Profile edits must normalize and length-bound outgoing kind:0 metadata before publishing: display names and about text go through `ProfileSanitizer`, picture URLs must be public HTTPS, and NIP-05/lud16 drafts must validate as address-shaped values before async publish starts.
- Pasted, scanned, and deep-linked profile references must reject overlong bech32 inputs before lowercasing, URL parsing, checksum verification, or TLV conversion.
- Profile references from QR scans, deep links, and pasted input must be validated before routing or staging: `npub` and `nprofile` need valid bech32 checksums, and hex public keys should be normalized to lowercase.
- Conversation reply-order normalization runs during timeline rebuilds and single-row inserts; keep it linear over the timeline and avoid fixpoint loops that rebuild message indexes per pass.
- Profile refresh queue drains must leave queued IDs intact when `canRefreshProfiles` is false, then re-arm when foreground/runtime state allows refresh again.
- When synthesizing timeline rows from protocol records, carry the source record timestamp when one is available. If a group-state snapshot has no source timestamp, refresh/read Marmot's durable kind-1210 timeline rows instead of stamping a local row with the client wall clock; wall clock is only for genuinely local UI/debug rows.
- Session-only system timeline rows should stay bounded, deduplicate consecutive identical event kinds, clear when conversation state resets, and only be appended with an explicit source timestamp; durable protocol rows come from Marmot records.
- Conversation timeline sync Marmot reads, including pagination, media listing, read-state initialization, and read marking, should go through `MarmotClient` async wrappers so generated synchronous FFI does not block the MainActor. Coalesce row-appearance read marks before flushing them to Marmot.
- For SwiftUI scroll timing, prefer cancellable main-actor tasks and layout-driven callbacks over `DispatchQueue.main` hop chains.
- Conversation bottom-follow requests, including the scroll-to-bottom button, should route through the timeline scroll coordinator instead of calling `scrollToBottom` directly from SwiftUI event handlers.
- Keep comments short and only where they explain a non-obvious constraint.

## Validation

Use the smallest test set that covers your change, then broaden when lifecycle, notification, or binding behavior changes.

Useful commands:

```sh
xcodebuild test \
  -project darkmatter-ios.xcodeproj \
  -scheme darkmatter-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

```sh
xcodebuild build \
  -project darkmatter-ios.xcodeproj \
  -scheme darkmatter-ios \
  -configuration Release \
  -destination 'generic/platform=iOS'
```

```sh
git diff --check
```

For TestFlight-facing changes, also walk the relevant items in `docs/manual-tests.md`.

## Git Hygiene

The worktree may contain user edits. Do not revert changes you did not make. If a generated file changes, confirm whether it came from `scripts/sync-bindings.sh` before touching it.

Commit related work as one clear checkpoint when asked. Leave unrelated cleanup for a separate commit.
