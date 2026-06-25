<h1 align="center">WhiteNoise iOS</h1>

<p align="center">
  <strong>Private MLS group messaging for iPhone, powered by the Marmot Rust runtime.</strong>
</p>

<p align="center">
  SwiftUI interface. Rust cryptographic core. Generic APNS wakes. Local-first diagnostics.
</p>

WhiteNoise iOS is the native iPhone client for the Dark Matter/Marmot secure messaging stack. The app gives iOS users a polished SwiftUI chat experience while delegating accounts, MLS group state, storage, relay catch-up, message processing, encrypted media, push-token cryptography, telemetry, and audit-log plumbing to the vendored `MarmotKit` UniFFI package.

The project is intentionally split along the platform boundary: Swift owns presentation, navigation, lifecycle, notifications, and Apple integration; Marmot owns protocol state and durable encrypted data.

## What It Does

- End-to-end encrypted MLS group messaging over the Dark Matter/Marmot relay stack.
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
- `MarmotKit` is generated from the sibling Dark Matter Rust repo. It exposes the Marmot runtime through UniFFI and ships here as a vendored xcframework plus generated Swift bindings.
- `Shared/` compiles into both the app and the Notification Service Extension, so files there must remain extension-safe.
- The Notification Service Extension opens the shared Marmot store, runs bounded relay catch-up, and projects local notification content without putting private metadata in the APNS payload.

## Project Map

- `whitenoise-ios/` - main SwiftUI app target.
- `whitenoise-ios/Core/` - app state, Marmot client setup, lifecycle, notifications, routing, telemetry, diagnostics helpers, and shared UI utilities.
- `whitenoise-ios/Chats/`, `Conversation/`, `Group/`, `Settings/`, `Profile/`, `Onboarding/` - feature screens and view models.
- `NotificationServiceExtension/` - APNS wake handling and local notification decoration.
- `Shared/` - extension-safe code shared by the app and notification extension.
- `Vendored/MarmotKit/` - generated UniFFI Swift bindings and the prebuilt Marmot static library xcframework.
- `scripts/sync-bindings.sh` - rebuilds and re-vendors `MarmotKit` from the sibling Rust checkout.
- `docs/manual-tests.md` - release-focused manual checks for flows that are expensive to automate.
- `AGENTS.md` - canonical coding-agent guidance for this repo.

## Requirements

- Xcode with iOS 18+ SDK support.
- Apple developer signing configured for device builds, APNS, App Groups, and the Notification Service Extension.
- The sibling Dark Matter Rust repo at `../darkmatter` only when regenerating Marmot bindings. Normal Swift builds use the vendored `MarmotKit` bundle.

Current identifiers:

- Main app bundle ID: `dev.ipf.whitenoise.ios`
- Notification Service Extension bundle ID: `dev.ipf.whitenoise.ios.NotificationService`
- App Group: `group.dev.ipf.whitenoise.ios`

## Build And Test

List project targets and schemes:

```sh
xcodebuild -list -project whitenoise-ios.xcodeproj
```

Build for a simulator:

```sh
xcodebuild build \
  -project whitenoise-ios.xcodeproj \
  -scheme whitenoise-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run unit tests:

```sh
xcodebuild test \
  -project whitenoise-ios.xcodeproj \
  -scheme whitenoise-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Build the device release artifact:

```sh
xcodebuild build \
  -project whitenoise-ios.xcodeproj \
  -scheme whitenoise-ios \
  -configuration Release \
  -destination 'generic/platform=iOS'
```

If a simulator name is unavailable on your machine, list local destinations:

```sh
xcodebuild -showdestinations \
  -project whitenoise-ios.xcodeproj \
  -scheme whitenoise-ios
```

## MarmotKit Bindings

`Vendored/MarmotKit/MARMOT_VERSION` records the Dark Matter commit used for the current bindings.

Regenerate bindings after changes in `marmot-uniffi` or any Rust crate it depends on:

```sh
./scripts/sync-bindings.sh
```

Use `DARKMATTER_DIR` if the Rust checkout is not the sibling default:

```sh
DARKMATTER_DIR=/path/to/darkmatter ./scripts/sync-bindings.sh
```

Do not hand-edit generated files in `Vendored/MarmotKit`. Change Rust/UniFFI, regenerate, then validate the iOS app.

## Privacy And Storage

- APNS provider payloads stay generic. Sender names, account IDs, group IDs, message IDs, and plaintext are never sent to Apple.
- The app and Notification Service Extension share the Marmot root through the App Group container.
- Marmot stores account secrets in the Keychain.
- User defaults hold preferences such as active account, developer mode, recent reactions, and diagnostics self-check state.
- Decrypted media cache files and temporary transcript exports use complete file protection.
- Remote group-image search is an explicit third-party egress surface and uses ephemeral, no-cookie/no-cache URL sessions.

## Telemetry And Audit Logs

Telemetry is compiled into the vendored MarmotKit bundle with the `otlp-export` feature. The app reads these Xcode build settings through `Info.plist`:

- `WHITENOISE_OTLP_ENDPOINT` - default `https://otlp.ipf.dev/v1/metrics`
- `WHITENOISE_OTLP_BEARER_TOKEN` - defaults to `$(OTLP_TOKEN_WHITENOISE_IOS)`
- `WHITENOISE_TELEMETRY_ENVIRONMENT` - `staging` or `production`; TestFlight builds are staging
- `WHITENOISE_AUDIT_LOG_BEARER_TOKEN` - defaults to `$(AUDIT_LOG_TOKEN_WHITENOISE_IOS)`

Put local secrets in `Config/TelemetrySecrets.xcconfig` and do not commit real tokens. Audit-log uploads use the endpoint compiled into MarmotKit and a token separate from OTLP, because the audit tracker and metrics collector are different services.

## Release Checks

Before a TestFlight build:

1. Run focused tests for the behavior you changed.
2. Run a Release device build.
3. Run `git diff --check`.
4. Walk the relevant checks in `docs/manual-tests.md`.
5. Confirm signing still includes APNS for the app and App Group access for both the app and extension.
