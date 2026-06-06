import Testing
import Foundation
import SwiftUI
import UIKit
@testable import darkmatter_ios
@testable import MarmotKit

/// Smoke coverage for the iOS-side glue layer.
///
/// Full functional tests require running against a Nostr relay (handled by
/// `marmot-uniffi`'s Rust integration tests). These tests just exercise the
/// boundary between MarmotKit and the iOS code, plus pure-Swift helpers.
@MainActor
struct AppStateBootstrapTests {

    @Test func freshAppStateStartsBootstrapping() async throws {
        let appState = AppState()
        #expect(appState.phase == .bootstrapping)
        #expect(appState.accounts.isEmpty)
        #expect(appState.activeToast == nil)
    }

    @Test func bootstrapWithoutAccountsTransitionsToOnboarding() async throws {
        // Use a fresh AppState backed by a tempdir-based MarmotClient so
        // we don't collide with the user's real Application Support data.
        let appState = AppState(client: try MarmotClient.testClient())
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        #expect(appState.accounts.isEmpty)
    }

    @Test func presentingAToastUpdatesActiveToast() async throws {
        let appState = AppState()
        await MainActor.run {
            appState.present(.success("Hello"))
        }
        #expect(appState.activeToast?.title == "Hello")
        #expect(appState.activeToast?.style == .success)

        await MainActor.run { appState.dismissToast() }
        #expect(appState.activeToast == nil)
    }

    @Test func visibleChatRouteTracksAccountAndClearsOnlyMatchingRoute() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-a"

        let route = appState.beginViewingChat(groupIdHex: "group-a")

        #expect(route == VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-a"))
        #expect(appState.visibleChat == route)
        #expect(appState.isViewingNotificationDestination(accountRef: "account-a", groupIdHex: "group-a"))
        #expect(!appState.isViewingNotificationDestination(accountRef: "account-a", groupIdHex: "group-b"))

        appState.setAppSceneActive(false)
        #expect(!appState.isViewingNotificationDestination(accountRef: "account-a", groupIdHex: "group-a"))

        appState.setAppSceneActive(true)
        appState.endViewingChat(VisibleChatRoute(accountRef: "account-b", groupIdHex: "group-a"))
        #expect(appState.visibleChat == route)

        if let route {
            appState.endViewingChat(route)
        }
        #expect(appState.visibleChat == nil)
    }

    @Test func backgroundSuspensionWaitsUntilRuntimeIsReady() async throws {
        let appState = AppState(client: try MarmotClient.testClient())

        await appState.prepareForBackgroundSuspension()

        #expect(!appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == 0)
    }

    @Test func readyRuntimeSuspendsForBackgroundAndResumesForForeground() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        await appState.bootstrap()
        try await appState.createIdentity()

        let generation = appState.runtimeGeneration
        await appState.prepareForBackgroundSuspension()

        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)
        // The runtime handle is released on suspension so its SQLite storage in
        // the shared App Group container is closed and its file lock freed
        // (otherwise iOS kills the app at suspension with 0xdead10cc). Don't
        // touch `marmot` here: the accessor would rebuild it on demand.
        #expect(appState.client == nil)

        await appState.resumeAfterForegroundActivation()

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation + 1)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(!appState.marmot.isStopping())
    }

    @Test func inactiveSceneStartsRuntimeSuspensionBeforeBackground() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        await appState.bootstrap()
        try await appState.createIdentity()

        let suspension = appState.startRuntimeSuspension()
        await suspension.value

        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        // Runtime released (storage closed) rather than kept alive in a
        // stopping state — see readyRuntimeSuspendsForBackgroundAndResumesForForeground.
        #expect(appState.client == nil)
    }

    @Test func signOutDisablesNativePushAndSwitchesActiveAccount() async throws {
        // Regression for issue #7: signing out must clear the signed-out
        // account's push registration so the push server stops delivering
        // its notifications to this device. Previously sign-out only mutated
        // `activeAccountRef`, leaving the registration (and the
        // `nativePushEnabled` preference) intact.
        let appState = AppState(client: try MarmotClient.testClient())
        await appState.bootstrap()
        let accountA = try await appState.createIdentity()
        let accountB = try await appState.createIdentity()
        appState.activeAccountRef = accountA.label

        // Simulate the app having enabled native push for A. The production
        // path goes through `setNativePushEnabled(_:)`, which requires an
        // APNS token unavailable in unit tests; calling marmot directly
        // flips the same local preference.
        _ = try await appState.marmot.setNativePushEnabled(accountRef: accountA.label, enabled: true)
        #expect(appState.notificationSettings(for: accountA.label)?.nativePushEnabled == true)

        await appState.signOut()

        #expect(appState.activeAccountRef == accountB.label)
        #expect(appState.notificationSettings(for: accountA.label)?.nativePushEnabled == false)
        // A remaining account means we stay in the main interface.
        #expect(appState.phase == .ready)
    }

    @Test func signOutOfOnlyAccountLeavesActiveAccountRefNil() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        await appState.bootstrap()
        let only = try await appState.createIdentity()
        appState.activeAccountRef = only.label

        await appState.signOut()

        #expect(appState.activeAccountRef == nil)
        #expect(appState.notificationSettings(for: only.label)?.nativePushEnabled == false)
        // Signing out of the last account must route back to onboarding
        // rather than leaving the main UI up with no active account.
        #expect(appState.phase == .onboarding)
    }

    @Test func signOutOfOnlyAccountClearsPersistedActiveAccountRef() async throws {
        // Without this, the next launch reads the stale label from
        // UserDefaults and bootstrap silently resurrects the signed-out
        // account (key material stays in the Keychain).
        UserDefaults.standard.removeObject(forKey: "marmot.activeAccountRef")
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        await appState.bootstrap()
        let only = try await appState.createIdentity()
        appState.activeAccountRef = only.label
        #expect(UserDefaults.standard.string(forKey: "marmot.activeAccountRef") == only.label)

        await appState.signOut()

        #expect(UserDefaults.standard.string(forKey: "marmot.activeAccountRef") == nil)
        let reborn = AppState(client: try client.freshRuntime())
        #expect(reborn.activeAccountRef == nil)
    }
}

@MainActor
struct RelaySettingsTests {

    @Test func editableRelayListComesFromMarmotAccountRelayLists() {
        let lists = AccountRelayListsFfi(
            complete: true,
            missing: [],
            defaultRelays: ["wss://nip65.example"],
            bootstrapRelays: ["wss://source.example"],
            nip65: RelayListFfi(kind: 10002, relays: ["wss://nip65.example"]),
            inbox: RelayListFfi(kind: 39000, relays: ["wss://inbox.example"]),
            keyPackage: RelayListFfi(kind: 39001, relays: ["wss://keys.example"])
        )

        #expect(RelaySettings.editableRelays(from: lists) == ["wss://nip65.example"])
        #expect(RelaySettings.bootstrapRelays(from: lists) == ["wss://source.example"])
    }

    @Test func relayInputAllowsWebsocketSchemesOnly() {
        #expect(RelaySettings.normalizedRelayURL("  ws://relay.example  ") == "ws://relay.example")
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example") == "wss://relay.example")
        #expect(RelaySettings.normalizedRelayURL("https://relay.example") == nil)
        #expect(RelaySettings.normalizedRelayURL("relay.example") == nil)
    }
}

@MainActor
struct AppContainerConfigTests {

    @Test func productionPushServerConfigIsPresent() {
        let config = NativePushServerConfig.current()

        #expect(config?.serverPubkeyHex == "73a4996bd18de19f6ac5f6ad42f5f2671eba6e5b739ea9695f07b00b0693fc04")
        #expect(config?.relayHint == "wss://relay.primal.net")
    }

    @Test func marmotRootUsesStableDirectoryName() {
        let base = URL(fileURLWithPath: "/tmp/darkmatter-test", isDirectory: true)

        #expect(AppContainerConfig.marmotRoot(in: base).path == "/tmp/darkmatter-test/Marmot")
    }

    @Test func legacyRootMovesIntoSharedContainerWhenSharedRootIsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotMove-\(UUID().uuidString)", isDirectory: true)
        let legacy = tmp.appendingPathComponent("legacy/Marmot", isDirectory: true)
        let shared = tmp.appendingPathComponent("shared/Marmot", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let marker = legacy.appendingPathComponent("marker.txt")
        try "ok".write(to: marker, atomically: true, encoding: .utf8)

        AppContainerConfig.migrateLegacyRootIfNeeded(from: legacy, to: shared)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("marker.txt").path))
    }

    @Test func existingSharedRootWinsOverLegacyRoot() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotKeep-\(UUID().uuidString)", isDirectory: true)
        let legacy = tmp.appendingPathComponent("legacy/Marmot", isDirectory: true)
        let shared = tmp.appendingPathComponent("shared/Marmot", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        AppContainerConfig.migrateLegacyRootIfNeeded(from: legacy, to: shared)

        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: shared.path))
    }
}

struct LocalizationCatalogTests {
    private let expectedLocales = ["de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"]

    @Test func sharedCatalogCoversLaunchLanguagesAndCoreKeys() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedKeys = [
            "Settings",
            "Notifications",
            "New Chat",
            "Message",
            "Appearance",
            "Theme",
            "Light",
            "Dark",
            "System",
            "Language",
            "Preferences",
            "New encrypted message",
            "That QR code isn't a Dark Matter profile.",
            "Couldn't create chat",
            "Push registration failed"
        ]

        for key in expectedKeys {
            let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in expectedLocales {
                #expect(localizations[locale] != nil, "Missing \(locale) localization for \(key)")
            }
        }
    }

    @Test func sharedCatalogHasFilledTranslationsForRepresentativeVisibleKeys() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedTranslations: [String: [String: String]] = [
            "Save profile": [
                "de": "Profil speichern",
                "es": "Guardar perfil",
                "fr": "Enregistrer le profil",
                "it": "Salva profilo",
                "pt": "Salvar perfil",
                "ru": "Сохранить профиль",
                "tr": "Profili kaydet",
                "zh-Hans": "保存个人资料",
                "zh-Hant": "儲存個人資料"
            ],
            "Couldn't load chats": [
                "de": "Chats konnten nicht geladen werden",
                "es": "No se pudieron cargar los chats",
                "fr": "Impossible de charger les discussions",
                "it": "Impossibile caricare le chat",
                "pt": "Não foi possível carregar os bate-papos",
                "ru": "Не удалось загрузить чаты",
                "tr": "Sohbetler yüklenemedi",
                "zh-Hans": "无法加载聊天记录",
                "zh-Hant": "無法載入聊天記錄"
            ]
        ]

        for (key, translations) in expectedTranslations {
            for (locale, expected) in translations {
                #expect(try localizedValue(key, locale: locale, in: strings) == expected)
            }
        }
    }

    @Test func sharedCatalogHasNoMissingLocalizedValuesAndKeepsPlaceholders() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any], "Invalid localization entry: \(key)")
            let expectedPlaceholders = placeholders(in: key)
            for locale in expectedLocales {
                let value = try localizedValue(key, locale: locale, in: strings)
                if !key.isEmpty {
                    #expect(!value.isEmpty, "Missing \(locale) value for \(key)")
                }
                #expect(placeholders(in: value).sorted() == expectedPlaceholders.sorted(), "Broken placeholders for \(key) in \(locale)")
            }
        }
    }

    @Test func infoPlistCatalogLocalizesCameraPermissionCopy() throws {
        let catalog = try readCatalog("darkmatter-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let cameraUsage = try #require(strings["NSCameraUsageDescription"] as? [String: Any])
        let localizations = try #require(cameraUsage["localizations"] as? [String: Any])

        let english = try localizedValue("NSCameraUsageDescription", locale: "en", in: strings)
        #expect(english != "NSCameraUsageDescription")
        #expect(english == "Dark Matter uses the camera to scan profile QR codes so you can add people to encrypted chats.")
        #expect(localizations["fr"] != nil)
        #expect(localizations["zh-Hant"] != nil)
    }

    @Test func infoPlistCatalogCoversLaunchLanguages() throws {
        let catalog = try readCatalog("darkmatter-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in ["CFBundleDisplayName", "CFBundleName", "NSCameraUsageDescription"] {
            for locale in ["en"] + expectedLocales {
                #expect(!(try localizedValue(key, locale: locale, in: strings)).isEmpty)
            }
        }
    }

    private func readCatalog(_ relativePath: String) throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func localizedValue(_ key: String, locale: String, in strings: [String: Any]) throws -> String {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let stringUnit = try #require(localeEntry["stringUnit"] as? [String: Any], "Missing string unit for \(key) in \(locale)")
        return try #require(stringUnit["value"] as? String, "Missing value for \(key) in \(locale)")
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = #"%[@a-zA-Z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange])
        }
    }
}

struct AppearancePreferencesTests {
    @Test func themePreferencesResolveToExpectedColorSchemes() {
        #expect(AppearanceTheme.resolved(rawValue: nil) == .system)
        #expect(AppearanceTheme.resolved(rawValue: "nope") == .system)
        #expect(AppearanceTheme.system.preferredColorScheme == nil)
        #expect(AppearanceTheme.light.preferredColorScheme == .light)
        #expect(AppearanceTheme.dark.preferredColorScheme == .dark)
        #expect(AppearanceTheme.system.userInterfaceStyle == .unspecified)
        #expect(AppearanceTheme.light.userInterfaceStyle == .light)
        #expect(AppearanceTheme.dark.userInterfaceStyle == .dark)
    }

    @Test func languagePreferencesCoverSupportedCatalogLocales() {
        let localeIDs = AppLanguage.supportedAppLanguages.compactMap(\.localeIdentifier)

        #expect(AppLanguage.resolved(rawValue: nil) == .system)
        #expect(AppLanguage.resolved(rawValue: "nope") == .system)
        #expect(AppLanguage.system.localeIdentifier == nil)
        #expect(localeIDs == ["en", "de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"])
    }

    @Test func appAppearanceSelectionResolvesThemeAndLanguageTogether() {
        let selected = AppAppearanceSelection(themeRawValue: "dark", languageRawValue: "fr")
        let fallback = AppAppearanceSelection(themeRawValue: "unknown", languageRawValue: "unknown")

        #expect(selected.theme == .dark)
        #expect(selected.preferredColorScheme == .dark)
        #expect(selected.language == .french)
        #expect(selected.locale.identifier == "fr")
        #expect(fallback.theme == .system)
        #expect(fallback.preferredColorScheme == nil)
        #expect(fallback.language == .system)
    }
}

@MainActor
struct ToastPresentationTests {
    @Test func toastOverlayPresentsAboveModalWindows() {
        #expect(ToastOverlayPresentation.windowLevel.rawValue > UIWindow.Level.alert.rawValue)
    }
}

struct GroupPushDebugPresentationTests {
    @Test func tokenSummaryIncludesTotalActiveAndStaleCounts() {
        let info = GroupPushDebugInfoFfi(
            totalTokenCount: 3,
            activeTokenCount: 2,
            staleTokenCount: 1,
            missingRelayHintCount: 1,
            lastTokenListUpdatedAtMs: nil,
            localRegistration: LocalPushRegistrationDebugFfi(
                registered: true,
                shareable: true,
                localNotificationsEnabled: true,
                nativePushEnabled: true,
                localLeafIndex: 7,
                localTokenCached: true
            ),
            tokens: []
        )

        #expect(GroupPushDebugPresentation.tokenSummary(for: info) == "3 total, 2 active, 1 stale")
        #expect(GroupPushDebugPresentation.missingRelayHintSummary(for: info) == "1 missing relay hint")
        #expect(GroupPushDebugPresentation.localRegistrationSummary(for: info.localRegistration) == "Registered, native push on, token cached")
        #expect(GroupPushDebugPresentation.platformLabel(.apns) == "APNS")
        #expect(GroupPushDebugPresentation.platformLabel(.fcm) == "FCM")
    }

    @Test func tokenSummaryPluralizesZeroAndMultipleCounts() {
        let info = GroupPushDebugInfoFfi(
            totalTokenCount: 0,
            activeTokenCount: 0,
            staleTokenCount: 0,
            missingRelayHintCount: 2,
            lastTokenListUpdatedAtMs: nil,
            localRegistration: LocalPushRegistrationDebugFfi(
                registered: false,
                shareable: false,
                localNotificationsEnabled: false,
                nativePushEnabled: false,
                localLeafIndex: nil,
                localTokenCached: false
            ),
            tokens: []
        )

        #expect(GroupPushDebugPresentation.tokenSummary(for: info) == "0 total, 0 active, 0 stale")
        #expect(GroupPushDebugPresentation.missingRelayHintSummary(for: info) == "2 missing relay hints")
        #expect(GroupPushDebugPresentation.localRegistrationSummary(for: info.localRegistration) == "Not registered, native push off, no local token")
    }
}

struct GroupForensicsPresentationTests {
    @Test func sensitiveModeIsPresentedAsPrivate() {
        #expect(GroupForensicsPresentation.modeLabel(.sensitive) == "Private")
    }

    @Test func exportFilenameIsStableAndFilesystemSafe() {
        let filename = GroupForensicsPresentation.fileName(
            groupTitle: "Marmot / QA: incident",
            groupIdHex: "abcdef1234567890",
            mode: .`public`,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(filename == "marmot-qa-incident-abcdef12-public-forensics-19700101-000000.json")
    }

    @Test func privateExportFilenameUsesPrivateLabel() {
        let filename = GroupForensicsPresentation.fileName(
            groupTitle: "Marmot / QA: incident",
            groupIdHex: "abcdef1234567890",
            mode: .sensitive,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(filename == "marmot-qa-incident-abcdef12-private-forensics-19700101-000000.json")
    }
}

@MainActor
struct IdentityFormatterTests {

    @Test func shortTruncatesLongStrings() {
        let long = "npub1abcdefghijklmnopqrstuvwxyz0123456789"
        let s = IdentityFormatter.short(long)
        #expect(s.contains("…"))
        #expect(s.count < long.count)
    }

    @Test func shortPassesShortStringsUnchanged() {
        let short = "abc"
        #expect(IdentityFormatter.short(short) == short)
    }

    @Test func displayNameFallsBackToShortIdWhenLabelEmpty() {
        let id = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let result = IdentityFormatter.displayName(label: "", accountIdHex: id)
        #expect(result.contains("…"))
    }
}

@MainActor
struct NotificationPresentationTests {

    @Test func directMessageUsesSenderPreviewAndRouteMetadata() {
        let update = notificationUpdate(
            notificationKey: "notif-1",
            conversationKey: "conv-1",
            isDm: true,
            groupName: nil,
            senderName: " Alice\nExample ",
            previewText: " hello\u{202E}\nthere ",
            messageIdHex: "message-1"
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.identifier == "notif-1")
        #expect(presentation?.threadIdentifier == "conv-1")
        #expect(presentation?.title == "Alice Example")
        #expect(presentation?.body == "hello there")
        #expect(presentation?.route.accountRef == "account-a")
        #expect(presentation?.route.groupIdHex == "group-a")
        #expect(presentation?.route.messageIdHex == "message-1")
        #expect(presentation?.userInfo[LocalNotificationProjection.accountRefKey] == "account-a")
    }

    @Test func groupMessageUsesGroupTitleAndSenderBodyPrefix() {
        let update = notificationUpdate(
            isDm: false,
            groupName: " Project\nRoom ",
            senderName: "Bob",
            previewText: "Ship it"
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.title == "Project Room")
        #expect(presentation?.body == "Bob: Ship it")
    }

    @Test func selfMessagesAreNotPresentedLocally() {
        let update = notificationUpdate(isFromSelf: true)

        #expect(LocalNotificationProjection.makePresentation(for: update) == nil)
    }

    @Test func tapRouteRoundTripsThroughUserInfo() {
        let route = LocalNotificationRoute(
            accountRef: "account-b",
            groupIdHex: "group-b",
            notificationKey: "notif-b",
            messageIdHex: "message-b"
        )

        let parsed = LocalNotificationProjection.route(from: LocalNotificationProjection.userInfo(for: route))

        #expect(parsed == route)
    }

    @Test func missingPreviewFallsBackToGenericEncryptedMessage() {
        let update = notificationUpdate(isDm: true, senderName: nil, previewText: nil)

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.title == "01234567…abcdef")
        #expect(presentation?.body == "New encrypted message")
    }
}

struct LocalNotificationSuppressionPolicyTests {

    @Test func visibleDestinationChatSuppressesMatchingNotificationOnly() {
        let visibleChat = VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-a")

        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: visibleChat
        ))
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-b",
            visibleChat: visibleChat
        ))
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-b",
            updateGroupIdHex: "group-a",
            visibleChat: visibleChat
        ))
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func inactiveAppScenePresentsNotificationsEvenWhenChatRouteMatches() {
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-a")
        ))
    }

    @Test func disabledLocalNotificationsAreNeverPresented() {
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: false,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }
}

struct AgentStreamSecurityTests {

    @Test func insecureLocalIsOffWhenDeveloperModeIsOff() {
        #expect(AgentStreamSecurity.insecureLocalEnabled(developerMode: false) == false)
    }

    @Test func insecureLocalMatchesBuildAllowanceWhenDeveloperModeIsOn() {
        // When developer mode is on, the effective flag must equal the
        // compile-time gate: true in DEBUG builds, false in release builds.
        #expect(
            AgentStreamSecurity.insecureLocalEnabled(developerMode: true)
                == AgentStreamSecurity.buildAllowsInsecureLocal
        )
    }

    @Test func buildAllowsInsecureLocalReflectsCompilationCondition() {
        #if DEBUG
        #expect(AgentStreamSecurity.buildAllowsInsecureLocal == true)
        #else
        #expect(AgentStreamSecurity.buildAllowsInsecureLocal == false)
        #endif
    }

    @Test func releaseBuildsForceInsecureLocalOffEvenWithDeveloperModeOn() {
        // Issue #10 invariant: in a release build, a user toggling
        // developer mode in Settings must not be able to disable TLS
        // verification for the agent QUIC stream.
        #if !DEBUG
        #expect(AgentStreamSecurity.insecureLocalEnabled(developerMode: true) == false)
        #endif
    }
}

struct NativePushRegistrationPolicyTests {

    @Test func enabledAccountsAreSyncedAcrossAllLocalAccounts() {
        let accounts = [
            AccountSummaryFfi(label: "account-a", accountIdHex: hex("11"), localSigning: true, running: true),
            AccountSummaryFfi(label: "account-b", accountIdHex: hex("22"), localSigning: true, running: true),
            AccountSummaryFfi(label: "account-c", accountIdHex: hex("33"), localSigning: true, running: true)
        ]
        let settings = [
            "account-a": NotificationSettingsFfi(
                accountRef: "account-a",
                accountIdHex: hex("11"),
                localNotificationsEnabled: true,
                nativePushEnabled: true
            ),
            "account-b": NotificationSettingsFfi(
                accountRef: "account-b",
                accountIdHex: hex("22"),
                localNotificationsEnabled: true,
                nativePushEnabled: false
            )
        ]

        let enabled = NativePushRegistrationPolicy.enabledAccountRefs(accounts: accounts) { settings[$0] }

        #expect(enabled == ["account-a"])
    }

    @Test func remoteTokenIsRequestedOnlyWhenEnabledAccountsLackAToken() {
        #expect(NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: ["account-a"],
            currentToken: nil
        ))
        #expect(NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: ["account-a"],
            currentToken: ""
        ))
        #expect(!NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: ["account-a"],
            currentToken: "abc123"
        ))
        #expect(!NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: [],
            currentToken: nil
        ))
    }
}

struct ForegroundNotificationSyncPolicyTests {

    @Test func catchUpRunsOnlyWhenAppIsReadyAndIdle() {
        #expect(ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .ready,
            isCatchUpRunning: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .ready,
            isCatchUpRunning: true,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .bootstrapping,
            isCatchUpRunning: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .onboarding,
            isCatchUpRunning: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .failed("offline"),
            isCatchUpRunning: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
    }

    @Test func catchUpDoesNotRunWhileInactiveSuspendedOrSuspending() {
        #expect(!ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .ready,
            isCatchUpRunning: false,
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .ready,
            isCatchUpRunning: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: .ready,
            isCatchUpRunning: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true
        ))
    }
}

@MainActor
struct NotificationServiceProjectionTests {

    @Test func newDataCollectionUsesNewestPresentableNotification() {
        let older = notificationUpdate(
            notificationKey: "older",
            senderName: "Alice",
            previewText: "first",
            timestampMs: 1_000
        )
        let newer = notificationUpdate(
            notificationKey: "newer",
            senderName: "Bob",
            previewText: "second",
            timestampMs: 2_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [older, newer],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        #expect(decision == .decorate(LocalNotificationProjection.makePresentation(for: newer)!))
    }

    @Test func noDataCollectionSuppressesProviderFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .noData,
            notifications: [],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .suppress)
    }

    @Test func selfOnlyCollectionSuppressesProviderFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [notificationUpdate(isFromSelf: true)],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .suppress)
    }

    @Test func failedCollectionKeepsGenericFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .failed,
            notifications: [],
            error: "relay timeout"
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .fallback)
    }
}

@MainActor
struct ProfileSanitizerTests {

    @Test func stripsBidiOverrideFromName() {
        // Trojan-Source-style: an RLO (U+202E) can reverse rendering to spoof.
        let spoofed = "alice\u{202E}evil"
        let safe = ProfileSanitizer.displayName(spoofed)
        #expect(safe == "aliceevil")
        #expect(!(safe?.unicodeScalars.contains { $0.value == 0x202E } ?? false))
    }

    @Test func collapsesNewlinesInName() {
        let multiline = "line one\nline two\t\tmore"
        let safe = ProfileSanitizer.displayName(multiline)
        #expect(safe == "line one line two more")
    }

    @Test func capsNameLength() {
        let long = String(repeating: "a", count: 500)
        let safe = ProfileSanitizer.displayName(long)
        #expect((safe?.count ?? 0) <= ProfileSanitizer.maxNameLength)
    }

    @Test func emptyAfterStrippingReturnsNil() {
        #expect(ProfileSanitizer.displayName("\u{202E}\u{200B}") == nil)
        #expect(ProfileSanitizer.displayName("   ") == nil)
        #expect(ProfileSanitizer.displayName(nil) == nil)
    }

    @Test func imageURLAllowsHttps() {
        #expect(ProfileSanitizer.imageURL("https://example.com/a.png") != nil)
        #expect(ProfileSanitizer.imageURL("http://example.com/a.png") != nil)
    }

    @Test func imageURLRejectsDangerousSchemes() {
        #expect(ProfileSanitizer.imageURL("data:image/png;base64,AAAA") == nil)
        #expect(ProfileSanitizer.imageURL("file:///etc/passwd") == nil)
        #expect(ProfileSanitizer.imageURL("javascript:alert(1)") == nil)
        #expect(ProfileSanitizer.imageURL("ftp://example.com/x") == nil)
        #expect(ProfileSanitizer.imageURL("https://") == nil) // no host
        #expect(ProfileSanitizer.imageURL("not a url") == nil)
    }

    // MARK: - Message bodies

    @Test func messageBodyStripsBidiButKeepsNewlines() {
        let raw = "first line\u{202E}spoof\nsecond line"
        let safe = ProfileSanitizer.messageBody(raw)
        #expect(!safe.unicodeScalars.contains { $0.value == 0x202E })
        #expect(safe.contains("\n"))            // newline preserved
        #expect(safe == "first linespoof\nsecond line")
    }

    @Test func messageBodyClampsBlankLineFlooding() {
        let raw = "top\n\n\n\n\n\n\n\nbottom"
        let safe = ProfileSanitizer.messageBody(raw)
        #expect(safe == "top\n\nbottom")        // 3+ blank lines → 2
    }

    @Test func messageBodyCapsLength() {
        let raw = String(repeating: "x", count: ProfileSanitizer.maxMessageLength + 500)
        #expect(ProfileSanitizer.messageBody(raw).count == ProfileSanitizer.maxMessageLength)
    }

    @Test func messageBodyTrimsOuterWhitespace() {
        #expect(ProfileSanitizer.messageBody("  \n hello \n  ") == "hello")
    }

    // MARK: - Group names

    @Test func groupNameSingleLinesAndStripsBidi() {
        let raw = "Secret\u{202E}evil\nClub"
        let safe = ProfileSanitizer.groupName(raw)
        #expect(safe == "Secretevil Club")      // bidi gone, newline → space
    }

    @Test func groupNameCaps() {
        let raw = String(repeating: "g", count: 400)
        #expect((ProfileSanitizer.groupName(raw)?.count ?? 0) <= ProfileSanitizer.maxGroupNameLength)
    }

    @Test func groupNameEmptyIsNil() {
        #expect(ProfileSanitizer.groupName("") == nil)
        #expect(ProfileSanitizer.groupName("\u{202E}\u{200B}") == nil)
    }
}

@MainActor
struct GroupDisplayTests {

    @Test func otherMemberUsesMemberIdNotLocalAccountLabel() {
        let me = hex("11")
        let other = hex("22")
        let members = [
            AppGroupMemberRecordFfi(memberIdHex: me, account: "Jeff", local: true),
            AppGroupMemberRecordFfi(memberIdHex: other, account: nil, local: false)
        ]

        #expect(GroupDisplay.otherMemberAccount(in: members, myAccountId: me) == other)
    }

    @MainActor
    @Test func namedGroupTitleWinsOverMemberRules() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let title = GroupDisplay.title(
            group: group(name: "  Project Room  "),
            otherMember: hex("22"),
            memberCount: 2,
            appState: appState
        )

        #expect(title == "Project Room")
    }

    @MainActor
    @Test func unnamedMultiPersonGroupShowsCount() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let title = GroupDisplay.title(
            group: group(name: ""),
            otherMember: hex("22"),
            memberCount: 3,
            appState: appState
        )

        #expect(title == "3 person group")
    }

    @MainActor
    @Test func unnamedTwoPersonGroupShowsOtherDisplayName() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let other = hex("22")
        appState.cacheProfile(
            UserProfileMetadataFfi(
                name: nil,
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            ),
            for: other
        )

        let title = GroupDisplay.title(
            group: group(name: ""),
            otherMember: other,
            memberCount: 2,
            appState: appState
        )

        #expect(title == "Alice")
    }

    @MainActor
    @Test func unnamedTwoPersonGroupFallsBackToNpub() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let title = GroupDisplay.title(
            group: group(name: ""),
            otherMember: hex("22"),
            memberCount: 2,
            appState: appState
        )

        #expect(title.hasPrefix("npub1"))
    }
}

@MainActor
struct ConversationChromeTests {

    @Test func directMessageTitleUsesInitialChatListHintsBeforeRosterLoads() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let other = hex("22")
        appState.cacheProfile(
            UserProfileMetadataFfi(
                name: nil,
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            ),
            for: other
        )

        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: ""),
            initialOtherMember: other,
            initialMemberCount: 2
        )

        #expect(viewModel.displayTitle == "Alice")
        #expect(viewModel.displaySubtitle == "2 members")
    }
}

@MainActor
struct ChatsListProjectionTests {

    @Test func projectedRowsDriveActiveArchivedUnreadAndOrdering() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let older = chatListRow(
            groupIdHex: hex("a1"),
            title: "Older",
            lastMessage: chatListPreview(messageIdHex: hex("b1"), plaintext: "older", timelineAt: 10),
            updatedAt: 10
        )
        let newerUnread = chatListRow(
            groupIdHex: hex("a2"),
            title: "Newer",
            lastMessage: chatListPreview(messageIdHex: hex("b2"), plaintext: "newer", timelineAt: 20),
            unreadCount: 3,
            firstUnreadMessageIdHex: hex("c2"),
            updatedAt: 20
        )
        let archived = chatListRow(
            groupIdHex: hex("a3"),
            archived: true,
            title: "Archived",
            lastMessage: chatListPreview(messageIdHex: hex("b3"), plaintext: "archived", timelineAt: 30),
            updatedAt: 30
        )

        viewModel.applyChatListSnapshot([older, archived, newerUnread])

        #expect(viewModel.items.map(\.id) == [newerUnread.groupIdHex, older.groupIdHex])
        #expect(viewModel.archivedItems.map(\.id) == [archived.groupIdHex])
        #expect(viewModel.items.first?.title == "Newer")
        #expect(viewModel.items.first?.previewText == "newer")
        #expect(viewModel.items.first?.unreadCount == 3)
        #expect(viewModel.items.first?.firstUnreadMessageIdHex == hex("c2"))
    }

    @Test func localArchiveChangeMovesProjectedRowBetweenScopes() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: hex("d1"), title: "General")
        viewModel.applyChatListSnapshot([row])

        viewModel.applyLocalGroupChange(group(name: "General", id: row.groupIdHex, archived: true))

        #expect(viewModel.items.isEmpty)
        #expect(viewModel.archivedItems.map(\.id) == [row.groupIdHex])
        #expect(viewModel.archivedItems.first?.group.archived == true)
    }
}

@MainActor
struct ConversationTimelineProjectionTests {

    @Test func readMarkersApplyOnlyToVisibleKindNineMessagesOnce() throws {
        let chatRecord = message(id: hex("11"), kind: MessageSemantics.kindChat)
        let reactionRecord = message(id: hex("22"), kind: MessageSemantics.kindReaction)
        let emptyId = message(id: "", kind: MessageSemantics.kindChat)

        #expect(ConversationViewModel.shouldMarkRead(chatRecord, isDeleted: false, alreadyMarked: false))
        #expect(!ConversationViewModel.shouldMarkRead(chatRecord, isDeleted: true, alreadyMarked: false))
        #expect(!ConversationViewModel.shouldMarkRead(chatRecord, isDeleted: false, alreadyMarked: true))
        #expect(!ConversationViewModel.shouldMarkRead(reactionRecord, isDeleted: false, alreadyMarked: false))
        #expect(!ConversationViewModel.shouldMarkRead(emptyId, isDeleted: false, alreadyMarked: false))
    }

    @Test func timelinePageHydratesReplyPreviewReactionsAndDeletedState() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let parentSender = hex("11")
        appState.cacheProfile(
            UserProfileMetadataFfi(
                name: nil,
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            ),
            for: parentSender
        )
        let viewModel = ConversationViewModel(appState: appState, group: group(name: ""))
        let parent = timelineRecord(
            messageIdHex: hex("a1"),
            sender: parentSender,
            plaintext: "the parent text",
            timelineAt: 1
        )
        let reply = timelineRecord(
            messageIdHex: hex("b2"),
            sender: hex("22"),
            plaintext: "replying",
            timelineAt: 2,
            replyToMessageIdHex: parent.messageIdHex,
            replyPreview: TimelineReplyPreviewFfi(
                messageIdHex: parent.messageIdHex,
                sender: parent.sender,
                plaintext: parent.plaintext,
                kind: MessageSemantics.kindChat,
                mediaJson: nil,
                agentTextStreamJson: nil,
                deleted: false
            ),
            reactions: TimelineReactionSummaryFfi(
                byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [hex("33"), hex("44")])],
                userReactions: []
            )
        )
        let deleted = timelineRecord(
            messageIdHex: hex("c3"),
            sender: hex("33"),
            plaintext: "",
            timelineAt: 3,
            deleted: true
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [parent, reply, deleted], hasMoreBefore: false, hasMoreAfter: false),
            placement: .tail
        )

        #expect(viewModel.timeline.count == 3)
        #expect(viewModel.reactions(for: reply.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "👍", count: 2, mine: false)
        ])
        #expect(viewModel.isDeleted(deleted.messageIdHex))
        let replyRecord = try #require(viewModel.record(for: reply.messageIdHex))
        #expect(viewModel.replyPreview(for: replyRecord)?.name == "Alice")
        #expect(viewModel.replyPreview(for: replyRecord)?.text == "the parent text")
    }

    @Test func liveTailRefreshPreservesLoadedScrollback() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let latest = timelineRecord(messageIdHex: hex("f2"), plaintext: "latest", timelineAt: 20)
        let older = timelineRecord(messageIdHex: hex("e1"), plaintext: "older", timelineAt: 10)
        let latestWithReaction = timelineRecord(
            messageIdHex: latest.messageIdHex,
            plaintext: latest.plaintext,
            timelineAt: latest.timelineAt,
            reactions: TimelineReactionSummaryFfi(
                byEmoji: [TimelineReactionEmojiFfi(emoji: "🔥", senders: [hex("33")])],
                userReactions: []
            )
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [latest], hasMoreBefore: true, hasMoreAfter: false),
            placement: .tail
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [older], hasMoreBefore: false, hasMoreAfter: true),
            placement: .older
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [latestWithReaction], hasMoreBefore: true, hasMoreAfter: false),
            placement: .tail
        )

        let messageIds = viewModel.timeline.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
        #expect(messageIds == [older.messageIdHex, latest.messageIdHex])
        #expect(viewModel.reactions(for: latest.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 1, mine: false)
        ])
        #expect(!viewModel.hasMoreBefore)
    }

    @Test func projectionDeltaMergesTimelineAndForwardsChatListRow() throws {
        var forwardedRows: [ChatListRowFfi] = []
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: ""),
            onChatListRowUpdated: { forwardedRows.append($0) }
        )
        let existing = timelineRecord(messageIdHex: hex("a1"), plaintext: "existing", timelineAt: 10)
        let projected = timelineRecord(messageIdHex: hex("b2"), plaintext: "projected", timelineAt: 20)
        let row = chatListRow(
            groupIdHex: existing.groupIdHex,
            title: "Projected",
            lastMessage: chatListPreview(messageIdHex: projected.messageIdHex, plaintext: projected.plaintext, timelineAt: projected.timelineAt),
            unreadCount: 1,
            firstUnreadMessageIdHex: projected.messageIdHex,
            updatedAt: projected.timelineAt
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [existing], hasMoreBefore: true, hasMoreAfter: false),
            placement: .tail
        )
        viewModel.applyTimelineSubscriptionUpdate(
            .projection(
                update: RuntimeProjectionUpdateFfi(
                    accountIdHex: hex("ff"),
                    accountLabel: "account-a",
                    update: TimelineProjectionUpdateFfi(
                        groupIdHex: existing.groupIdHex,
                        messages: [projected],
                        chatListRow: row
                    )
                )
            )
        )

        let messageIds = viewModel.timeline.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
        #expect(messageIds == [existing.messageIdHex, projected.messageIdHex])
        #expect(viewModel.hasMoreBefore)
        #expect(forwardedRows.map(\.groupIdHex) == [row.groupIdHex])
        #expect(forwardedRows.first?.firstUnreadMessageIdHex == projected.messageIdHex)
    }
}

@MainActor
struct GroupManagementPresentationTests {

    @Test func adminCanPromoteAndRemoveNonAdminMember() {
        let actions = GroupManagementPresentation.memberActions(
            for: GroupMemberActionStateFfi(
                memberIdHex: hex("22"),
                isSelf: false,
                isAdmin: false,
                canRemove: true,
                canPromote: true,
                canDemote: false
            ),
            state: managementState(isSelfAdmin: true, isLastAdmin: false)
        )

        #expect(actions == [.promote, .remove])
    }

    @Test func adminCanDemoteAndRemoveAnotherAdminWhenNotLastAdmin() {
        let actions = GroupManagementPresentation.memberActions(
            for: GroupMemberActionStateFfi(
                memberIdHex: hex("22"),
                isSelf: false,
                isAdmin: true,
                canRemove: true,
                canPromote: false,
                canDemote: true
            ),
            state: managementState(isSelfAdmin: true, isLastAdmin: false)
        )

        #expect(actions == [.demote, .remove])
    }

    @Test func selfAdminCanStepDownOnlyWhenAnotherAdminExists() {
        let selfAction = GroupMemberActionStateFfi(
            memberIdHex: hex("11"),
            isSelf: true,
            isAdmin: true,
            canRemove: false,
            canPromote: false,
            canDemote: false
        )

        #expect(
            GroupManagementPresentation.memberActions(
                for: selfAction,
                state: managementState(isSelfAdmin: true, isLastAdmin: false)
            ) == [.selfDemote]
        )
        #expect(
            GroupManagementPresentation.memberActions(
                for: selfAction,
                state: managementState(isSelfAdmin: true, isLastAdmin: true)
            ).isEmpty
        )
    }

    @Test func nonLastAdminsCanLeaveWithAutomaticDemotion() {
        let state = managementState(
            isSelfAdmin: true,
            isLastAdmin: false,
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true
        )

        #expect(GroupManagementPresentation.canLeave(state: state, fallbackIsLastAdmin: false))
        #expect(GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: state))
        #expect(GroupManagementPresentation.leaveFooter(state: state, fallbackIsLastAdmin: false) == "Leaving will step you down as admin first.")
        #expect(GroupManagementPresentation.leaveConfirmationMessage(state: state) == "You'll step down as admin first, then stop receiving messages from this group.")
    }

    @Test func lastAdminStillCannotLeave() {
        let state = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true
        )

        #expect(!GroupManagementPresentation.canLeave(state: state, fallbackIsLastAdmin: false))
        #expect(!GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: state))
        #expect(GroupManagementPresentation.leaveFooter(state: state, fallbackIsLastAdmin: false) == "You're the only admin. Make another member an admin before you leave.")
    }

    @Test func relayDisclosureShowsCountAndUrls() {
        let relays = ["wss://relay.example", "wss://relay.two"]

        #expect(GroupRelaysPresentation.countLabel(for: relays) == "2")
        #expect(GroupRelaysPresentation.rows(for: relays) == relays)
    }

    @Test func relayDisclosureShowsEmptyState() {
        #expect(GroupRelaysPresentation.countLabel(for: []) == "0")
        #expect(GroupRelaysPresentation.rows(for: []) == [GroupRelaysPresentation.emptyMessage])
    }

    @Test func addMembersScannerAcceptsProfileDeepLinks() {
        let npub = "npub1abcdefghijklmnopqrstuvwxyz"
        let nprofile = "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"
        let nprofileHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "darkmatter://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "nostr:\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: nprofile) == nprofileHex
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "nostr:\(nprofile)") == nprofileHex
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "darkmatter://profile/\(nprofile)") == nprofileHex
        )
        #expect(
            DeepLink.parse(string: "nostr:\(nprofile)") == .profile(npub: nprofileHex)
        )
        #expect(
            NostrProfileReference.memberRef(from: nprofileHex.uppercased()) == nprofileHex
        )
    }

    @Test func stagedMembersUseCachedDisplayNameAndNpubSubtitle() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let account = hex("33")
        let member = MemberRefFfi(
            memberRef: account,
            accountIdHex: account,
            npub: "npub1abcdefghijklmnopqrstuvwxyz0123456789"
        )
        appState.cacheProfile(
            UserProfileMetadataFfi(
                name: nil,
                displayName: "Nadia",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            ),
            for: account
        )

        #expect(AddMembersPresentation.displayName(for: member, appState: appState) == "Nadia")
        #expect(AddMembersPresentation.secondaryIdentity(for: member).hasPrefix("npub1"))
    }

    @Test func adminStatusCanUpdateOptimisticallyBeforePublishReturns() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "", admins: [me]),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: false, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: true,
                    isLastAdmin: true,
                    canInvite: true,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: true,
                    memberActions: [
                        GroupMemberActionStateFfi(
                            memberIdHex: other,
                            isSelf: false,
                            isAdmin: false,
                            canRemove: true,
                            canPromote: true,
                            canDemote: false
                        )
                    ]
                )
            )
        )

        viewModel.applyOptimisticAdminStatus(memberIdHex: other, isAdmin: true)

        #expect(viewModel.group.admins.contains(other))
        #expect(viewModel.groupMemberDetails.first { $0.memberIdHex == other }?.isAdmin == true)
        #expect(viewModel.managementAction(for: other)?.canPromote == false)
        #expect(viewModel.managementAction(for: other)?.canDemote == true)
        #expect(viewModel.managementState?.isLastAdmin == false)
    }

    @Test func selfDemoteUpdatesOwnManagementStateOptimistically() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "", admins: [me, other]),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: true, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: true,
                    isLastAdmin: false,
                    canInvite: true,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: true,
                    memberActions: []
                )
            )
        )

        viewModel.applyOptimisticAdminStatus(memberIdHex: me, isAdmin: false)

        #expect(!viewModel.group.admins.contains(me))
        #expect(viewModel.groupMemberDetails.first { $0.memberIdHex == me }?.isAdmin == false)
        #expect(viewModel.managementState?.isSelfAdmin == false)
        #expect(viewModel.managementState?.requiresSelfDemoteBeforeLeave == false)
        #expect(viewModel.managementState?.canLeave == true)
    }
}

@MainActor
struct AgentStreamTests {

    @Test func streamIdIsDecodedFromStartTags() {
        let streamId = hex("ab")
        let start = ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId.uppercased()]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
                MessageTagFfi(values: [MessageSemantics.streamBrokerTag, AppState.agentTextStreamQuicBrokerCandidate]),
            ],
            recordedAt: 1
        )

        #expect(ConversationViewModel.agentStreamId(from: start) == streamId)
    }

    @Test func malformedStreamStartsAreIgnored() {
        let invalidId = ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, "abcd"]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ],
            recordedAt: 1
        )
        let audioProfile = ReceivedMessageFfi(
            messageIdHex: hex("dd"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: ["stream-type", "audio"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ],
            recordedAt: 1
        )
        let missingRoute = ReceivedMessageFfi(
            messageIdHex: hex("ee"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
            ],
            recordedAt: 1
        )
        let websocketProfile = ReceivedMessageFfi(
            messageIdHex: hex("ff"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "websocket"]),
            ],
            recordedAt: 1
        )

        #expect(ConversationViewModel.agentStreamId(from: invalidId) == nil)
        #expect(ConversationViewModel.agentStreamId(from: audioProfile) == nil)
        #expect(ConversationViewModel.agentStreamId(from: missingRoute) == nil)
        #expect(ConversationViewModel.agentStreamId(from: websocketProfile) == nil)
    }

    @Test func agentStreamStartUsesProductionBrokerCandidate() {
        #expect(AppState.agentTextStreamQuicCandidates == ["quic://quic-broker.ipf.dev:4450"])
    }

    @Test func snapshotStartsAreWatchedOnlyUntilFinalAnchorArrives() {
        let streamId = hex("ab")
        let start = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ]
        )

        #expect(ConversationViewModel.snapshotStartStreamIdToWatch(from: start, finalizedStreamIds: []) == streamId)
        #expect(ConversationViewModel.snapshotStartStreamIdToWatch(from: start, finalizedStreamIds: [streamId]) == nil)
    }

    @MainActor
    @Test func streamChunksRenderIntoOnePreviewBubble() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "Hel")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: "lo")
        )

        #expect(viewModel.timeline.count == 1)
        #expect(viewModel.timeline.first?.id == "msg:stream:\(streamId)")
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext == "Hello")
        #expect(MessagePreview.body(record) == "Hello")
    }

    @MainActor
    @Test func finishedUpdateReplacesPreviewAndIgnoresLateChunks() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .finished(text: "complete", transcriptHashHex: hex("55"), chunkCount: 1)
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: " late")
        )

        #expect(viewModel.timeline.count == 1)
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a finalized stream message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "complete")
        #expect(MessagePreview.body(record) == "complete")
    }

    @MainActor
    @Test func failedUpdateDropsEmptyLivePreview() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .failed(message: "broker closed")
        )

        #expect(viewModel.timeline.isEmpty)
    }
}

@MainActor
struct ReceivedMessageTimestampTests {

    /// Regression for the timeline-sort bug: live messages must keep the
    /// event's own send time as `recordedAt`, not the device clock at receipt.
    /// Otherwise a late-arriving message (e.g. after a reconnect) would sort
    /// after messages sent moments ago.
    @Test func liveMessageUsesEventTimestampForRecordedAt() {
        let eventTime: UInt64 = 1_700_000_000
        let now: UInt64 = 1_700_000_500
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: receivedMessage(recordedAt: eventTime)
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: now)

        #expect(record.recordedAt == eventTime)
        #expect(record.receivedAt == now)
    }

    /// If the FFI omits a timestamp (zero sentinel — possible for very old
    /// stored events or a future relay that drops it), fall back to the local
    /// receipt time so the message still has a sensible ordering anchor.
    @Test func liveMessageFallsBackToNowWhenEventTimestampMissing() {
        let now: UInt64 = 1_700_000_500
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: receivedMessage(recordedAt: 0)
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: now)

        #expect(record.recordedAt == now)
        #expect(record.receivedAt == now)
    }

    @Test func receivedRecordCopiesIdentityAndPayloadFields() {
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: receivedMessage(recordedAt: 42)
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: 99)

        #expect(record.direction == "received")
        #expect(record.messageIdHex == runtime.message.messageIdHex)
        #expect(record.groupIdHex == runtime.message.groupIdHex)
        #expect(record.sender == runtime.message.sender)
        #expect(record.plaintext == runtime.message.plaintext)
        #expect(record.kind == runtime.message.kind)
        #expect(record.tags == runtime.message.tags)
    }

    private func receivedMessage(recordedAt: UInt64) -> ReceivedMessageFfi {
        ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "hello",
            kind: MessageSemantics.kindChat,
            tags: [MessageTagFfi(values: ["e", hex("dd")])],
            recordedAt: recordedAt
        )
    }
}

@MainActor
struct MessageSemanticsTests {

    @Test func decodedUnsignedEventChatPreviewsItsContent() {
        let record = unsignedEventRecord(
            plaintext: "hello from the inner content",
            kind: MessageSemantics.kindChat,
            tags: []
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "hello from the inner content")
    }

    @Test func decodedUnsignedEventControlsDoNotPreviewAsText() {
        let target = hex("44")
        let streamId = hex("ab")
        let reaction = unsignedEventRecord(
            plaintext: "+",
            kind: MessageSemantics.kindReaction,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])]
        )
        let deletion = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindDelete,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])]
        )
        let streamStart = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ]
        )

        #expect(MessageSemantics.classify(reaction) == .reaction(targetMessageId: target))
        #expect(MessageSemantics.classify(deletion) == .delete(targetMessageId: target))
        #expect(!MessagePreview.isPreviewable(reaction))
        #expect(!MessagePreview.isPreviewable(deletion))
        #expect(!MessagePreview.isPreviewable(streamStart))
    }

    @Test func decodedUnsignedEventStreamFinalPreviewsTranscript() {
        let streamId = hex("ab")
        let record = unsignedEventRecord(
            plaintext: "complete answer",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: [MessageSemantics.streamStartTag, hex("cc")]),
                MessageTagFfi(values: [MessageSemantics.streamHashTag, hex("55")]),
                MessageTagFfi(values: [MessageSemantics.streamChunksTag, "2"]),
            ]
        )

        #expect(MessageSemantics.classify(record) == .streamFinal(streamId: streamId))
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "complete answer")
    }

    @Test func incompleteStreamFinalIsPlainChatNotAStreamFinal() {
        let record = unsignedEventRecord(
            plaintext: "complete answer",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: [MessageSemantics.streamHashTag, hex("55")]),
                MessageTagFfi(values: [MessageSemantics.streamChunksTag, "2"]),
            ]
        )

        #expect(MessageSemantics.classify(record) == .chat)
    }

    @Test func mediaReferenceParsesMip04V2ImetaFields() {
        let nonce = String(repeating: "22", count: 12)
        let record = AppMessageRecordFfi(
            messageIdHex: hex("dd"),
            direction: "received",
            groupIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [
                    MessageSemantics.imetaTag,
                    "url https://media.example/a.png",
                    "m image/png",
                    "filename a.png",
                    "x \(hex("33"))",
                    "n \(nonce)",
                    "v mip04-v2",
                    "size 7",
                ])
            ],
            recordedAt: 1,
            receivedAt: 1
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false))
            return
        }

        #expect(info.url == "https://media.example/a.png")
        #expect(info.mediaType == "image/png")
        #expect(info.fileName == "a.png")
        #expect(info.fileHashHex == hex("33"))
        #expect(info.nonceHex == nonce)
        #expect(info.version == "mip04-v2")
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func malformedMediaReferenceIsNotPreviewable() {
        let record = AppMessageRecordFfi(
            messageIdHex: hex("dd"),
            direction: "received",
            groupIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [
                    MessageSemantics.imetaTag,
                    "url https://media.example/a.png",
                    "m image/png",
                    "filename a.png",
                    "x \(hex("33"))",
                    "size 7",
                ])
            ],
            recordedAt: 1,
            receivedAt: 1
        )

        #expect(MessageSemantics.classify(record) == .unknown)
        #expect(!MessagePreview.isPreviewable(record))
    }

    @Test func mediaReferenceWithoutCaptionFallsBackToFileName() {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [
                    MessageSemantics.imetaTag,
                    "url https://media.example/a.png",
                    "m image/png",
                    "filename a.png",
                    "x \(hex("33"))",
                    "n \(nonce)",
                    "v mip04-v2",
                    "size 7",
                ])
            ]
        )

        #expect(MessagePreview.body(record) == "📎 a.png")
    }

    @MainActor
    @Test func conversationDisplayBodyUsesMediaFileNameFallback() throws {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [
                    MessageSemantics.imetaTag,
                    "url https://media.example/a.png",
                    "m image/png",
                    "filename a.png",
                    "x \(hex("33"))",
                    "n \(nonce)",
                    "v mip04-v2",
                    "size 7",
                ])
            ]
        )
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )

        #expect(viewModel.displayBody(of: record) == "📎 a.png")
    }
}

@MainActor
struct ReplySwipeTests {

    @Test func horizontalDragPastThresholdActivatesReply() {
        #expect(ReplySwipe.shouldActivate(translation: CGSize(width: 72, height: 10)))
    }

    @Test func verticalOrShortDragsDoNotActivateReply() {
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 59, height: 4)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 90, height: 120)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 72, height: 65)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: -90, height: 4)))
    }

    @Test func feedbackOffsetFollowsHorizontalDragButIsCapped() {
        let partialOffset = ReplySwipe.feedbackOffset(translation: CGSize(width: 50, height: 3))
        #expect(partialOffset > 20)
        #expect(partialOffset < ReplySwipe.maximumFeedbackOffset)
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 160, height: 3)) == ReplySwipe.maximumFeedbackOffset)
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 40, height: 80)) == 0)
    }

    @Test func completionNudgeStaysBelowMaximumFeedback() {
        #expect(ReplySwipe.minimumDistance >= 20)
        #expect(ReplySwipe.completionOffset < ReplySwipe.maximumFeedbackOffset)
        #expect(ReplySwipe.completionOffset <= 12)
        #expect(ReplySwipe.completionPauseNanoseconds <= 20_000_000)
    }
}

@MainActor
struct TimelineBottomTests {

    @Test func initialEntryStartsAtBottomWhenMessagesExist() {
        #expect(TimelineInitialScroll.shouldStartAtBottom(hasItems: true, didPerformInitialScroll: false))
        #expect(!TimelineInitialScroll.shouldStartAtBottom(hasItems: false, didPerformInitialScroll: false))
        #expect(!TimelineInitialScroll.shouldStartAtBottom(hasItems: true, didPerformInitialScroll: true))
    }

    @Test func initialEntryFromNotificationPrefersTargetMessage() {
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: "message-target",
            targetItemId: "msg-target"
        ) == .item("msg-target"))
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: nil,
            targetItemId: nil
        ) == .bottom)
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: "message-target",
            targetItemId: nil
        ) == .none)
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: true,
            targetMessageIdHex: "message-target",
            targetItemId: "msg-target"
        ) == .none)
    }

    @Test func bottomStateAllowsSmallLayoutDrift() {
        #expect(TimelineBottom.isPinned(bottomY: 1030, viewportBottomY: 1000))
    }

    @Test func bottomStateDetectsScrolledUpHistory() {
        #expect(!TimelineBottom.isPinned(bottomY: 1090, viewportBottomY: 1000))
    }

    @Test func scrollToBottomButtonAppearsOnlyAwayFromBottom() {
        #expect(!TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: 12))
        #expect(!TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: TimelineBottom.pinnedThreshold))
        #expect(TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: 90))
    }

    @Test func viewportChangesFollowOnlyWhenAlreadyPinned() {
        #expect(TimelineBottom.shouldFollowViewportChange(wasPinned: true))
        #expect(!TimelineBottom.shouldFollowViewportChange(wasPinned: false))
    }

    @Test func scrollButtonTapDoesNotHideButtonBeforeGeometryConfirmsBottom() {
        #expect(!TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: false))
        #expect(TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: true))
    }
}

@MainActor
struct ReplyPreviewLayoutTests {

    @Test func closeControlIsCenteredWithMatchingTrailingInset() {
        #expect(ReplyPreviewLayout.contentTopInset == ReplyPreviewLayout.contentBottomInset)
        #expect(ReplyPreviewLayout.closeHitSize >= 44)
        #expect(ReplyPreviewLayout.closeAlignment == .trailing)
        #expect(ReplyPreviewLayout.closeTrailingInset == ReplyPreviewLayout.leadingContentInset)
    }
}

@MainActor
struct SensitiveClipboardTests {

    @Test func clearWipesPasteboardWhenItStillHoldsTheSecret() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        pasteboard.string = secret

        SensitiveClipboard.clear(secret, from: pasteboard)

        #expect(pasteboard.string == nil || pasteboard.string?.isEmpty == true)
        #expect(!pasteboard.hasStrings)
    }

    @Test func clearLeavesPasteboardAloneWhenContentsDifferFromSecret() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        let unrelated = "https://example.com/some-link"
        pasteboard.string = unrelated

        SensitiveClipboard.clear(secret, from: pasteboard)

        #expect(pasteboard.string == unrelated)
    }

    @Test func clearIgnoresWhitespaceAroundSecretWhenComparing() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        pasteboard.string = secret

        SensitiveClipboard.clear("  \n\(secret)\n  ", from: pasteboard)

        #expect(!pasteboard.hasStrings)
    }

    @Test func clearIgnoresWhitespaceAroundPasteboardValueWhenComparing() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        pasteboard.string = "  \n\(secret)\n  "

        SensitiveClipboard.clear(secret, from: pasteboard)

        #expect(!pasteboard.hasStrings)
    }

    @Test func clearIsNoOpWhenSecretIsEmpty() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let unrelated = "something else"
        pasteboard.string = unrelated

        SensitiveClipboard.clear("", from: pasteboard)
        SensitiveClipboard.clear("   \n  ", from: pasteboard)

        #expect(pasteboard.string == unrelated)
    }

    @Test func clearIsNoOpWhenPasteboardHasNoString() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.items = []

        SensitiveClipboard.clear("nsec1secret", from: pasteboard)

        #expect(!pasteboard.hasStrings)
    }

    private func makeIsolatedPasteboard() -> UIPasteboard {
        let name = UIPasteboard.Name("dev.ipf.darkmatter.tests.sensitive-clipboard-\(UUID().uuidString)")
        return UIPasteboard(name: name, create: true)!
    }
}

// MARK: - Test scaffolding

private func unsignedEventRecord(
    plaintext: String,
    kind: UInt64,
    tags: [MessageTagFfi]
) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: hex("dd"),
        direction: "received",
        groupIdHex: hex("aa"),
        sender: hex("11"),
        plaintext: plaintext,
        kind: kind,
        tags: tags,
        recordedAt: 1,
        receivedAt: 1
    )
}

private func timelineRecord(
    messageIdHex: String,
    direction: String = "received",
    groupIdHex: String = hex("aa"),
    sender: String = hex("11"),
    plaintext: String = "hello",
    kind: UInt64 = MessageSemantics.kindChat,
    tags: [MessageTagFfi] = [],
    timelineAt: UInt64,
    receivedAt: UInt64? = nil,
    replyToMessageIdHex: String? = nil,
    replyPreview: TimelineReplyPreviewFfi? = nil,
    mediaJson: String? = nil,
    agentTextStreamJson: String? = nil,
    reactions: TimelineReactionSummaryFfi = TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
    deleted: Bool = false,
    deletedByMessageIdHex: String? = nil
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: nil,
        direction: direction,
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        kind: kind,
        tags: tags,
        timelineAt: timelineAt,
        receivedAt: receivedAt ?? timelineAt,
        replyToMessageIdHex: replyToMessageIdHex,
        replyPreview: replyPreview,
        mediaJson: mediaJson,
        agentTextStreamJson: agentTextStreamJson,
        reactions: reactions,
        deleted: deleted,
        deletedByMessageIdHex: deletedByMessageIdHex
    )
}

private func message(
    id: String,
    kind: UInt64 = MessageSemantics.kindChat,
    groupIdHex: String = hex("aa"),
    sender: String = hex("11"),
    plaintext: String = "hello",
    tags: [MessageTagFfi] = [],
    recordedAt: UInt64 = 1
) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: id,
        direction: "received",
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        kind: kind,
        tags: tags,
        recordedAt: recordedAt,
        receivedAt: recordedAt
    )
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}

private func group(
    name: String,
    id: String = hex("aa"),
    admins: [String] = [],
    archived: Bool = false
) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: id,
        endpoint: "",
        name: name,
        description: "",
        admins: admins,
        relays: [],
        nostrGroupIdHex: "",
        archived: archived,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func chatListPreview(
    messageIdHex: String,
    sender: String = hex("11"),
    senderDisplayName: String? = nil,
    plaintext: String = "hello",
    kind: UInt64 = MessageSemantics.kindChat,
    timelineAt: UInt64 = 1,
    deleted: Bool = false
) -> ChatListMessagePreviewFfi {
    ChatListMessagePreviewFfi(
        messageIdHex: messageIdHex,
        sender: sender,
        senderDisplayName: senderDisplayName,
        plaintext: plaintext,
        kind: kind,
        timelineAt: timelineAt,
        deleted: deleted
    )
}

private func chatListRow(
    groupIdHex: String,
    archived: Bool = false,
    pendingConfirmation: Bool = false,
    title: String,
    groupName: String? = nil,
    avatar: ChatListAvatarFfi? = nil,
    lastMessage: ChatListMessagePreviewFfi? = nil,
    unreadCount: UInt64 = 0,
    firstUnreadMessageIdHex: String? = nil,
    lastReadMessageIdHex: String? = nil,
    lastReadTimelineAt: UInt64? = nil,
    updatedAt: UInt64 = 1
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: groupIdHex,
        archived: archived,
        pendingConfirmation: pendingConfirmation,
        title: title,
        groupName: groupName ?? title,
        avatar: avatar,
        lastMessage: lastMessage,
        unreadCount: unreadCount,
        hasUnread: unreadCount > 0,
        firstUnreadMessageIdHex: firstUnreadMessageIdHex,
        lastReadMessageIdHex: lastReadMessageIdHex,
        lastReadTimelineAt: lastReadTimelineAt,
        updatedAt: updatedAt
    )
}

private func groupMember(memberIdHex: String, isAdmin: Bool, isSelf: Bool) -> GroupMemberDetailsFfi {
    GroupMemberDetailsFfi(
        memberIdHex: memberIdHex,
        account: memberIdHex,
        local: isSelf,
        isAdmin: isAdmin,
        isSelf: isSelf,
        npub: "npub-\(IdentityFormatter.short(memberIdHex))",
        displayName: nil
    )
}

private func notificationUpdate(
    notificationKey: String = "notif-a",
    conversationKey: String = "conv-a",
    trigger: NotificationTriggerFfi = .newMessage,
    accountRef: String = "account-a",
    accountIdHex: String = hex("11"),
    groupIdHex: String = "group-a",
    isDm: Bool = true,
    groupName: String? = nil,
    senderName: String? = "Alice",
    previewText: String? = "Hello",
    messageIdHex: String? = "message-a",
    isFromSelf: Bool = false,
    timestampMs: Int64 = 1_700_000_000_123
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: notificationKey,
        conversationKey: conversationKey,
        trigger: trigger,
        accountRef: accountRef,
        accountIdHex: accountIdHex,
        groupIdHex: groupIdHex,
        groupName: groupName,
        isDm: isDm,
        messageIdHex: messageIdHex,
        sender: NotificationUserFfi(
            accountIdHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            displayName: senderName,
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: accountIdHex,
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: previewText,
        timestampMs: timestampMs,
        isFromSelf: isFromSelf
    )
}

private func managementState(
    isSelfAdmin: Bool,
    isLastAdmin: Bool,
    canLeave: Bool? = nil,
    requiresSelfDemoteBeforeLeave: Bool? = nil
) -> GroupManagementStateFfi {
    GroupManagementStateFfi(
        myAccountIdHex: hex("11"),
        isSelfAdmin: isSelfAdmin,
        isLastAdmin: isLastAdmin,
        canInvite: isSelfAdmin,
        canLeave: canLeave ?? !isSelfAdmin,
        requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave ?? isSelfAdmin,
        memberActions: []
    )
}

extension MarmotClient {
    /// Builds a MarmotClient pointed at a unique temp directory so unit tests
    /// stay hermetic. Falls back to the production root only if the temp dir
    /// can't be created (which would itself be a test environment problem).
    static func testClient() throws -> MarmotClient {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return try MarmotClient(rootPath: tmp.path, relayUrls: ["wss://relay.invalid.test"])
    }
}
