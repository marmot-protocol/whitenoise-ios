# Dark Matter iOS

Dark Matter iOS is a SwiftUI client for the Dark Matter/Marmot secure group messaging stack. The Swift app owns the interface, navigation, notification presentation, and iOS lifecycle. The Rust runtime, exposed through the vendored `MarmotKit` UniFFI package, owns accounts, storage, MLS group state, relay catch-up, and message processing.

## Project Map

- `darkmatter-ios/` - the main SwiftUI app target.
- `darkmatter-ios/Core/` - app state, Marmot client setup, notifications, routing helpers, and shared UI utilities.
- `darkmatter-ios/Chats/`, `Conversation/`, `Group/`, `Settings/`, `Profile/`, `Onboarding/` - feature screens and view models.
- `NotificationServiceExtension/` - the iOS notification service extension used to rewrite generic APNS wakes into local notification content.
- `Shared/` - Swift code compiled into both the app and extension. Keep this extension-safe.
- `Vendored/MarmotKit/` - generated UniFFI Swift bindings plus the prebuilt Marmot static library xcframework.
- `scripts/sync-bindings.sh` - rebuilds and re-vendors `MarmotKit` from the sibling Darkmatter Rust repo.
- `docs/manual-tests.md` - manual release checks for flows that are hard to automate.

## Requirements

- Xcode with iOS 18+ SDK support.
- A configured Apple developer team for device builds, APNS, App Groups, and the Notification Service Extension.
- The sibling Darkmatter repo at `../darkmatter` only when regenerating Rust bindings. Normal Swift builds use the vendored `MarmotKit` package.

Current identifiers:

- Main app bundle ID: `dev.ipf.darkmatter`
- Notification Service Extension bundle ID: `dev.ipf.darkmatter.NotificationService`
- App Group: `group.dev.ipf.darkmatter`

## Build And Test

List project targets and schemes:

```sh
xcodebuild -list -project darkmatter-ios.xcodeproj
```

Build for a simulator:

```sh
xcodebuild build \
  -project darkmatter-ios.xcodeproj \
  -scheme darkmatter-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run unit tests:

```sh
xcodebuild test \
  -project darkmatter-ios.xcodeproj \
  -scheme darkmatter-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Build the device release artifact:

```sh
xcodebuild build \
  -project darkmatter-ios.xcodeproj \
  -scheme darkmatter-ios \
  -configuration Release \
  -destination 'generic/platform=iOS'
```

If a simulator name is unavailable on your machine, run:

```sh
xcodebuild -showdestinations -project darkmatter-ios.xcodeproj -scheme darkmatter-ios
```

## MarmotKit Bindings

`Vendored/MarmotKit/MARMOT_VERSION` records the Darkmatter commit used for the current bindings.

Regenerate bindings after changes in `marmot-uniffi` or any Rust crate it depends on:

```sh
./scripts/sync-bindings.sh
```

Use `DARKMATTER_DIR` if the Rust checkout is not the sibling default:

```sh
DARKMATTER_DIR=/path/to/darkmatter ./scripts/sync-bindings.sh
```

Do not edit generated files in `Vendored/MarmotKit` by hand. Fix the Rust/UniFFI source, regenerate, then commit the regenerated bundle.

## Notifications

Notification delivery has two paths:

- Local notifications while the app is running.
- Native APNS wakes through the Notification Service Extension while the app is backgrounded, suspended, or not running.

Native push is privacy-preserving. Darkmatter registers an encrypted platform token with the notification server and sends generic MIP-05 notification wakes. Apple sees the generic APNS payload. The extension opens the shared Marmot store, catches up accounts from relays, projects local notification updates, and rewrites the visible notification on device.

Keep APNS payloads generic. Do not send sender names, account IDs, group IDs, message IDs, or message plaintext to Apple.

## Storage

- `UserDefaults` stores app-level preferences such as the active account, developer mode, and recent reactions.
- The shared App Group container stores the Marmot root so the main app and Notification Service Extension can read the same local state.
- Account secrets live in the Keychain through Marmot.

## Release Checks

Before a TestFlight build:

1. Run focused tests for any changed behavior.
2. Run a Release device build.
3. Run `git diff --check`.
4. Walk the relevant items in `docs/manual-tests.md`.
5. Confirm signing still includes APNS for the app and App Group access for both the app and extension.
