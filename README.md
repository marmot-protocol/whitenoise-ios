<h1 align="center">White Noise iOS</h1>

<p align="center">
  <strong>Private MLS group messaging for iPhone, powered by the Marmot Rust runtime.</strong>
</p>

<p align="center">
  SwiftUI interface. Rust cryptographic core. Generic APNS wakes. Local-first diagnostics.
</p>

White Noise iOS is the native iPhone client for the MDK/Marmot secure messaging stack. The app gives iOS users a polished SwiftUI chat experience while delegating accounts, MLS group state, storage, relay catch-up, message processing, encrypted media, push-token cryptography, telemetry, and audit-log plumbing to the `MarmotKit` UniFFI package.

The project is intentionally split along the platform boundary: Swift owns presentation, navigation, lifecycle, notifications, and Apple integration; Marmot owns protocol state and durable encrypted data.

## What It Does

- End-to-end encrypted MLS group messaging over the MDK/Marmot relay stack.
- Nostr identity flows: create/import local identities, display npubs, share profile deep links, and scan QR codes.
- Rich conversations with markdown, replies, reactions, mentions, encrypted image attachments, read state, and group system events.
- Multi-account chat lists, account switching, group management, profile publishing, and NIP-65/inbox relay editing.
- Privacy-preserving notifications: APNS carries only a generic wake, while the Notification Service Extension locally catches up Marmot state and renders visible content on device.
- Developer and forensic tooling: diagnostics, streaming debug rows, telemetry controls, local audit JSONL files, and protected transcript export.
- Extension-safe shared projection code for local notifications, notification-service rendering, localization, profile sanitization, and app-group configuration.

## Architecture

`whitenoise-ios` is a SwiftUI app wrapped around a Rust runtime:

- SwiftUI owns the app shell, onboarding, settings, chat UI, navigation, sheets, toasts, and foreground/background lifecycle.
- `AppState` is the observable hub for global app state. It owns the live `MarmotClient`, the active account, pending navigation, visible-chat tracking, notification subscriptions, native push sync, and runtime suspend/resume.
- `MarmotKit` is generated from MDK. Its generated Swift source is kept in a local package while SwiftPM downloads the matching immutable XCFramework release.
- `Shared/` compiles into both the app and the Notification Service Extension, so files there must remain extension-safe.
- The Notification Service Extension opens the shared Marmot store, runs bounded relay catch-up, and projects local notification content without putting private metadata in the APNS payload.

## Project Map

- `whitenoise-ios/` - main SwiftUI app target.
- `whitenoise-ios/Core/` - app state, Marmot client setup, lifecycle, notifications, routing, telemetry, diagnostics helpers, and shared UI utilities.
- `whitenoise-ios/Chats/`, `Conversation/`, `Group/`, `Settings/`, `Profile/`, `Onboarding/` - feature screens and view models.
- `NotificationServiceExtension/` - APNS wake handling and local notification decoration.
- `Shared/` - extension-safe code shared by the app and notification extension.
- `Packages/MarmotKit/` - generated UniFFI Swift bindings and the pinned remote XCFramework declaration.
- `scripts/sync-rc.sh` - pins `develop` to MDK's latest verified MarmotKit Release Candidate.
- `scripts/promote-stable.sh` - swaps an RC pin for the Stable MarmotKit release MDK promoted from it.
- `scripts/sync-bindings.sh` - verifies and installs a published immutable `MarmotKit` release.
- `CONTRIBUTING.md` - branch conventions, pull requests, and the daily RC bump flow.
- `docs/release-flow.md` - `develop` vs. `master` channels, staging tags, Stable promotion, and hotfixes.
- `docs/manual-tests.md` - release-focused manual checks for flows that are expensive to automate.
- `docs/releases.md` - version bumps, validation, and immutable release tags on master.
- `AGENTS.md` - canonical coding-agent guidance for this repo (`CLAUDE.md` is a symlink).

## Requirements

- Xcode with iOS 18+ SDK support.
- Apple developer signing configured for device builds, APNS, App Groups, and the Notification Service Extension.
- Network access for SwiftPM to download the pinned MarmotKit XCFramework on a clean build.

Production identifiers:

- Main app bundle ID: `dev.ipf.whitenoise.ios`
- Notification Service Extension bundle ID: `dev.ipf.whitenoise.ios.NotificationService`
- App Group: `group.dev.ipf.whitenoise.ios`
- URL scheme: `marmot`
- Legacy URL scheme: `whitenoise`

Staging identifiers:

- Main app bundle ID: `dev.ipf.whitenoise.ios.staging`
- Notification Service Extension bundle ID: `dev.ipf.whitenoise.ios.staging.NotificationService`
- App Group: `group.dev.ipf.whitenoise.ios.staging`
- URL scheme: `marmot-staging`
- Legacy URL scheme: `whitenoise-staging`

## Build And Test

List project targets and schemes:

```sh
xcodebuild -list -project whitenoise-ios.xcodeproj
```

Build production for a simulator:

```sh
xcodebuild build \
  -project whitenoise-ios.xcodeproj \
  -scheme "Whitenoise (Production)" \
  -destination 'platform=iOS Simulator,name=iPhone Air'
```

Run unit tests with the production scheme:

```sh
xcodebuild test \
  -project whitenoise-ios.xcodeproj \
  -scheme "Whitenoise (Production)" \
  -destination 'platform=iOS Simulator,name=iPhone Air'
```

Build the production device release artifact:

```sh
xcodebuild build \
  -project whitenoise-ios.xcodeproj \
  -scheme "Whitenoise (Production)" \
  -configuration Release-Production \
  -destination 'generic/platform=iOS'
```

Build the staging device release artifact:

```sh
xcodebuild build \
  -project whitenoise-ios.xcodeproj \
  -scheme "Whitenoise (Staging)" \
  -configuration Release-Staging \
  -destination 'generic/platform=iOS'
```

If a simulator name is unavailable on your machine, list local destinations:

```sh
xcodebuild -showdestinations \
  -project whitenoise-ios.xcodeproj \
  -scheme "Whitenoise (Production)"
```

## Branches And MarmotKit Bindings

`Packages/MarmotKit/MARMOT_VERSION` records the immutable MDK release and channel (`rc` or `stable`) used for the current bindings.

- **`develop`** (default branch) pins MDK's daily verified Release Candidate (`marmotkit-vX.Y.Z-rc.N`). Feature work branches from `develop` and targets `develop`, and staging builds are cut from here. RCs are deleted upstream after 30 days.
- **`master`** (production) pins **Stable** releases (`marmotkit-vX.Y.Z`) only, enforced by CI (`scripts/ci/check-marmotkit-channel.sh`).

Common commands:

```sh
just sync-rc                 # pin develop to the latest verified RC from mdk rc-meta
just promote-stable          # on release/X.Y.Z, swap the RC for the Stable promoted from it
just sync-bindings 0.19.0    # install a specific published release by version or SHA
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/release-flow.md](docs/release-flow.md) for the full branch, staging-tag, promotion, and hotfix workflow. All scripts verify every published digest, SwiftPM checksum, generated Swift source, privacy manifest, and source SHA before updating `Packages/MarmotKit`. Do not hand-edit generated files in `Packages/MarmotKit`.

## Privacy And Storage

- APNS provider payloads stay generic. Sender names, account IDs, group IDs, message IDs, and plaintext are never sent to Apple.
- The app and Notification Service Extension share the Marmot root through the App Group container. Current MDK builds use the `White Noise/Marmot` root and intentionally do not migrate the legacy top-level `Marmot` root or old secure-storage entries; users re-import their nsec after the cutover.
- Marmot stores account secrets in the Keychain.
- User defaults hold preferences such as active account, developer mode, recent reactions, and diagnostics self-check state.
- Decrypted media cache files and temporary transcript exports use complete file protection.
- Remote group-image search is an explicit third-party egress surface and uses ephemeral, no-cookie/no-cache URL sessions.
- GIF search sends the query and IP address directly to GIPHY over the same pinned, ephemeral transport. Messages contain GIPHY's returned media URL rather than a Blossom copy. Received GIFs are tap-to-load by default so merely opening a chat does not contact GIPHY.

## Telemetry And Audit Logs

Telemetry is compiled into the published MarmotKit bundle with the `otlp-export` feature. The app reads these Xcode build settings through `Info.plist`:

- `WHITENOISE_OTLP_ENDPOINT` - default `https://otlp.whitenoise.chat/v1/metrics`
- `WHITENOISE_OTLP_BEARER_TOKEN` - the metrics write token, `$(OTLP_TOKEN_WHITENOISE_IOS)` for both flavors
- `WHITENOISE_TELEMETRY_ENVIRONMENT` - `staging` or `production`, selected by the build flavor (not by TestFlight distribution)
- `WHITENOISE_AUDIT_OTLP_ENDPOINT` - v5 audit receiver, `https://otlp.whitenoise.chat/v1/logs` for both flavors
- `WHITENOISE_AUDIT_LOG_BEARER_TOKEN` - the audit receiver's write token, `$(AUDIT_LOG_TOKEN_WHITENOISE_IOS)` for both flavors
- `WHITENOISE_GIPHY_API_KEY` - defaults to `$(GIPHY_API_KEY_WHITENOISE_IOS)`

Put local secrets in `Config/TelemetrySecrets.xcconfig` and do not commit real tokens or API keys. Metrics use one shared token; the flavor is reported through the `deployment.environment.name` resource attribute. Opt-in audit recordings are delivered as MDK audit v5 over OTLP logs with one shared audit token; the audit and metrics tokens are not interchangeable. Without an audit token, recordings stay on the device for manual export. GIF search remains unavailable when no GIPHY key is configured.

## Release Checks

Before a TestFlight build:

1. Run focused tests for the behavior you changed.
2. Run a Release device build.
3. Run `git diff --check`.
4. Walk the relevant checks in `docs/manual-tests.md`.
5. Confirm signing still includes APNS for the app and App Group access for both the app and extension.

## License

Copyright (c) 2024-2026 White Noise developers.

White Noise iOS is licensed under the GNU Affero General Public License version 3.0 only (AGPL-3.0-only). See [LICENSE](LICENSE).
