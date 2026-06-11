# Agent Notes

This repo is a SwiftUI iOS app around the Darkmatter/Marmot Rust runtime. Read this before changing code.

## Start Here

- Main app entry point: `darkmatter-ios/darkmatter_iosApp.swift`
- Global state and runtime ownership: `darkmatter-ios/Core/AppState.swift`
- Marmot wrapper: `darkmatter-ios/Core/MarmotClient.swift`
- Shared app/extension config: `Shared/AppContainerConfig.swift`
- Notification projection: `Shared/LocalNotificationProjection.swift`
- NSE projection policy: `Shared/NotificationServiceProjection.swift`
- Manual release checks: `docs/manual-tests.md`

## Architecture

Swift owns UI, app lifecycle, navigation, presentation state, and iOS notification plumbing. Marmot owns accounts, MLS group state, storage, relay catch-up, message processing, and push-token cryptography.

`AppState` is the app's observable hub. It owns the `MarmotClient`, active account, phase routing, pending navigation, toasts, visible-chat tracking, notification subscription, native push sync, and runtime suspend/resume around app backgrounding.

`Shared/` is compiled into both the main app and the Notification Service Extension. Keep code there extension-safe. Do not use `UIApplication`, app delegates, SwiftUI views, or APIs unavailable to extensions from shared files.

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
- Sign-out must cancel and await any in-flight native-push registration sync before clearing the removed account's push registration.
- Main-app local notification presentation must fail open if a settings read throws; only an explicit disabled setting should suppress.
- Notification subscription retry failures should show at most one generic user-facing banner per outage; do not surface raw backend error descriptions in that toast.
- The main app should not keep the Marmot runtime alive indefinitely in the background. It suspends the runtime on background and restarts it on foreground.

If notifications are flaky, check token registration, group push-token gossip, relay hints, transponder visibility on the relay, and NSE timeout behavior before changing UI code.

## Remote Image Search

The group image web search is an explicit third-party egress surface. Keep DuckDuckGo requests and result thumbnail fetches on ephemeral, no-cookie/no-cache URL sessions, and keep the in-app disclosure aligned with the actual hosts contacted. Do not use `URLSession.shared` or SwiftUI `AsyncImage` for this search/preview path.

## Storage

- `UserDefaults` stores app preferences such as active account, developer mode, and recent reactions.
- The shared App Group container stores the Marmot root used by both app and extension.
- Marmot stores account secrets in the Keychain.
- Decrypted media cache files under `Caches/EncryptedMedia` must set complete file protection on both the directory and cached plaintext files.

Do not add a second storage path for data Marmot already owns.

## Code Style

- Follow the existing SwiftUI and Observation patterns.
- Keep feature state in view models when it is screen-specific.
- Put cross-screen app state in `AppState`.
- Keep pure formatting/projection helpers in `Shared/` only when the extension also needs them.
- Use `LocalNotificationProjection` for notification title/body/thread/userInfo decisions.
- Use `LocalNotificationSuppressionPolicy` for foreground suppression decisions.
- Normalize optional group metadata before handing it to Marmot; trim descriptions and pass `nil` for blank values.
- Sanitize peer-controlled group names with `ProfileSanitizer.groupName` before storing or rendering timeline/system-event display strings, and use static `L10n.formatted` keys for dynamic text.
- Route peer-controlled profile and group image URLs through `ProfileSanitizer.imageURL`; it only allows HTTPS public hosts and rejects local/private hosts plus legacy IPv4 literal spellings.
- Media attachment display IDs must include the owning message or timeline-row identity; do not key SwiftUI media views solely by the encrypted media reference.
- Build user-visible date formats from localized templates rather than raw `DateFormatter.dateFormat` patterns.
- When synthesizing timeline rows from protocol records, carry the source record timestamp when one is available; use the client wall clock only for local-only UI events or missing timestamp fallbacks.
- For SwiftUI scroll timing, prefer cancellable main-actor tasks and layout-driven callbacks over `DispatchQueue.main` hop chains.
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
