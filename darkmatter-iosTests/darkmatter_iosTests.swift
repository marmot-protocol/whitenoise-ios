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

    @Test func telemetryExportSettingPersistsThroughAppState() async throws {
        let appState = AppState(client: try MarmotClient.testClient())

        let saved = try await appState.setRelayTelemetryExportEnabled(false)

        #expect(!saved.exportEnabled)
        #expect(try appState.relayTelemetrySettings().exportEnabled == false)
    }

    @Test func createIdentityFromOnboardingStartsNotificationSubscription() async throws {
        let appState = AppState(client: try MarmotClient.testClient(), notifications: AppNotifications())
        await appState.bootstrap()

        #expect(appState.phase == .onboarding)
        #expect(!appState.notificationSubscriptionActive)

        try await appState.createIdentity()

        #expect(appState.phase == .ready)
        #expect(appState.notificationSubscriptionActive)
    }

    @Test func createIdentityDefaultsNotificationsOnWhenPermissionIsGranted() async throws {
        var authorizationRequestCount = 0
        var remoteRegistrationRequestCount = 0
        let notifications = AppNotifications(
            requestAuthorizationHandler: {
                authorizationRequestCount += 1
                return true
            },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {
                remoteRegistrationRequestCount += 1
            }
        )
        let appState = AppState(client: try MarmotClient.testClient(), notifications: notifications)
        await appState.bootstrap()

        let account = try await appState.createIdentity()

        let settings = try #require(appState.notificationSettings(for: account.label))
        #expect(settings.localNotificationsEnabled)
        #expect(settings.nativePushEnabled)
        #expect(authorizationRequestCount == 1)
        #expect(remoteRegistrationRequestCount == 1)
    }

    @Test func createIdentityKeepsNotificationDefaultsOffWhenPermissionIsDenied() async throws {
        var remoteRegistrationRequestCount = 0
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .denied },
            remoteNotificationRegistrar: {
                remoteRegistrationRequestCount += 1
            }
        )
        let appState = AppState(client: try MarmotClient.testClient(), notifications: notifications)
        await appState.bootstrap()

        let account = try await appState.createIdentity()

        let settings = try #require(appState.notificationSettings(for: account.label))
        #expect(!settings.localNotificationsEnabled)
        #expect(!settings.nativePushEnabled)
        #expect(remoteRegistrationRequestCount == 0)
        #expect(appState.phase == .ready)
    }

    @Test func identityOnboardingPathsUseSharedReadyMaintenance() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)

        #expect(source.matches(#"func createIdentity\(\) async throws -> AccountSummaryFfi[\s\S]*?completeOnboardingAfterIdentityActivation\(\)[\s\S]*?return summary"#))
        #expect(source.matches(#"func importIdentity\(_ identity: String\) async throws -> AccountSummaryFfi[\s\S]*?completeOnboardingAfterIdentityActivation\(\)[\s\S]*?return summary"#))
    }

    @Test func lifecycleEntrypointsDeclareMainActorIsolation() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)

        #expect(source.matches(#"@MainActor\s+func bootstrap\(\) async"#))
        #expect(source.matches(#"@MainActor\s+@discardableResult\s+func createIdentity\(\) async throws -> AccountSummaryFfi"#))
        #expect(source.matches(#"@MainActor\s+@discardableResult\s+func importIdentity\(_ identity: String\) async throws -> AccountSummaryFfi"#))
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

    @Test func toastPresentationIsBackedByFocusedToastState() async throws {
        let appState = AppState()
        await MainActor.run {
            appState.present(.success("Hello"))
        }

        #expect(appState.toastState.activeToast?.title == "Hello")
        #expect(appState.activeToast == appState.toastState.activeToast)

        await MainActor.run { appState.dismissToast() }
        #expect(appState.toastState.activeToast == nil)
    }

    @Test func toastSleepDurationIsClampedBeforeNanosecondConversion() {
        #expect(ToastState.sleepNanoseconds(forDuration: -1) == 0)
        #expect(ToastState.sleepNanoseconds(forDuration: .nan) == 0)
        #expect(ToastState.sleepNanoseconds(forDuration: .infinity) == UInt64.max)
        #expect(ToastState.sleepNanoseconds(forDuration: 1.25) == 1_250_000_000)
    }

    @Test func routingIsBackedByFocusedNavigationState() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-a"

        appState.presentProfile(npub: "npub1example")
        #expect(appState.navigation.pendingProfile == AppState.ProfileLink(npub: "npub1example"))
        #expect(appState.pendingProfile == appState.navigation.pendingProfile)

        appState.presentChat(
            groupIdHex: "group-a",
            accountRef: "account-b",
            messageIdHex: "  message-a  "
        )
        #expect(appState.activeAccountRef == "account-b")
        #expect(appState.navigation.pendingChatId == "group-a")
        #expect(appState.navigation.pendingChatAccountRef == "account-b")
        #expect(appState.navigation.pendingChatMessageIdHex == "message-a")

        appState.clearPendingChat()
        #expect(appState.navigation.pendingChatId == nil)
        #expect(appState.navigation.pendingChatAccountRef == nil)
        #expect(appState.navigation.pendingChatMessageIdHex == nil)
    }

    @Test func profileCachingIsBackedByFocusedProfileCache() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let id = String(repeating: "a", count: 64)

        appState.cacheProfile(
            UserProfileMetadataFfi(
                name: nil,
                displayName: "Alice",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            ),
            for: id
        )

        #expect(appState.profileCache.profiles[id]?.displayName == "Alice")
        #expect(appState.displayNames[id] == "Alice")
        #expect(appState.avatarURL(forAccountIdHex: id)?.absoluteString == "https://example.com/alice.png")
    }

    @Test func profileCacheDoesNotMemoizeRawHexNpubFallbacks() {
        let cache = ProfileCache()
        let id = String(repeating: "a", count: 64)
        let npub = "npub1example"

        #expect(cache.npub(forAccountIdHex: id, projected: nil) == id)
        #expect(cache.npubs[id] == nil)

        #expect(cache.npub(forAccountIdHex: id, projected: npub) == npub)
        #expect(cache.npubs[id] == npub)
    }

    @Test func appInjectsFocusedStateStoresIntoEnvironment() throws {
        let source = try String(contentsOf: appSourceURL, encoding: .utf8)

        #expect(source.contains(".environment(appState.toastState)"))
        #expect(source.contains(".environment(appState.navigation)"))
        #expect(source.contains(".environment(appState.profileCache)"))
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

    @Test func auditLogSettingChangeRestartsReadyRuntimeImmediately() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        await appState.bootstrap()
        try await appState.createIdentity()

        let generation = appState.runtimeGeneration
        let settings = try await appState.setAuditLogEnabled(true)

        #expect(settings.enabled)
        #expect(try appState.auditLogSettings().enabled)
        #expect(appState.runtimeGeneration == generation + 1)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(!appState.marmot.isStopping())
    }

    @Test func inactiveSceneDoesNotStartRuntimeSuspensionBeforeBackground() throws {
        let source = try String(contentsOf: appSourceURL, encoding: .utf8)

        #expect(source.matches(#"case \.inactive:\s*appState\.setAppSceneActive\(false\)"#))
        #expect(!source.matches(#"case \.inactive:\s*appState\.startRuntimeSuspension\(\)"#))
        #expect(source.matches(#"case \.background:\s*beginBackgroundRuntimeSuspension\(\)"#))
    }

    @Test func foregroundActivationDoesNotPollForRuntimeSuspension() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)

        #expect(!source.matches(#"(?s)func resumeAfterForegroundActivation\(\) async \{.*Task\.sleep"#))
        #expect(!source.matches(#"while\s+isRuntimeSuspending"#))
    }

    @Test func profileMissesUseTrackedFetchQueue() throws {
        let appStateSource = try String(contentsOf: appStateSourceURL, encoding: .utf8)
        let profilesSource = try String(contentsOf: appStateProfilesSourceURL, encoding: .utf8)

        #expect(profilesSource.contains("scheduleProfileRefresh(forAccountIdHex: id)"))
        #expect(profilesSource.contains("profileFetchQueueTask = Task"))
        #expect(!profilesSource.matches(#"Task\s*\{\s*await\s+refreshProfile\(forAccountIdHex:\s*id\)\s*\}"#))
        #expect(appStateSource.contains("cancelProfileFetchQueue()"))
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
        #expect(appState.accounts.map(\.label) == [accountB.label])
        #expect(appState.notificationSettings(for: accountA.label) == nil)
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
        #expect(appState.notificationSettings(for: only.label) == nil)
        // Signing out of the last account must route back to onboarding
        // rather than leaving the main UI up with no active account.
        #expect(appState.phase == .onboarding)
    }

    @Test func signOutOfOnlyAccountRemovesAccountAndReturnsToOnboarding() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        await appState.bootstrap()
        let only = try await appState.createIdentity()
        appState.activeAccountRef = only.label

        await appState.signOut()

        #expect(appState.accounts.isEmpty)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.phase == .onboarding)
    }

    @Test func signOutOfOnlyAccountClearsPersistedActiveAccountRef() async throws {
        // Without this, the next launch reads the stale label from
        // UserDefaults and bootstrap points at an account that was removed
        // from local Marmot storage.
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

    private var appStateSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/AppState.swift")
    }

    private var appSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/darkmatter_iosApp.swift")
    }

    private var appStateProfilesSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/AppState+Profiles.swift")
    }
}

struct NotificationSubscriptionRetryTests {
    @Test func retriesAfterSubscribeErrorAndDeliversNextNotification() async throws {
        let probe = NotificationSubscriptionProbe(attempts: [
            .failure,
            .updates([notificationUpdate()])
        ])
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: 1,
            maximumRetryDelayNanoseconds: 8,
            subscribe: { try await probe.subscribe() },
            present: { await probe.present($0) },
            reportError: { await probe.report(error: $0) },
            sleep: { try await probe.sleep(nanoseconds: $0) }
        )

        await runner.run()

        let snapshot = await probe.snapshot()
        #expect(snapshot.subscribeAttempts == 2)
        #expect(snapshot.presentedNotificationKeys == ["notif-a"])
        #expect(snapshot.errorCount == 1)
        #expect(snapshot.sleepDelays == [1, 1])
    }

    @Test func retriesAfterNotificationStreamFinishes() async throws {
        let probe = NotificationSubscriptionProbe(attempts: [
            .updates([]),
            .updates([notificationUpdate(notificationKey: "notif-b")])
        ])
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: 1,
            maximumRetryDelayNanoseconds: 8,
            subscribe: { try await probe.subscribe() },
            present: { await probe.present($0) },
            reportError: { await probe.report(error: $0) },
            sleep: { try await probe.sleep(nanoseconds: $0) }
        )

        await runner.run()

        let snapshot = await probe.snapshot()
        #expect(snapshot.subscribeAttempts == 2)
        #expect(snapshot.presentedNotificationKeys == ["notif-b"])
        #expect(snapshot.errorCount == 0)
        #expect(snapshot.sleepDelays == [1, 1])
    }

    @Test func backsOffConsecutiveFailuresAndResetsAfterNotification() async throws {
        let probe = NotificationSubscriptionProbe(attempts: [
            .failure,
            .failure,
            .failure,
            .updates([notificationUpdate(notificationKey: "notif-c")])
        ])
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: 1,
            maximumRetryDelayNanoseconds: 2,
            subscribe: { try await probe.subscribe() },
            present: { await probe.present($0) },
            reportError: { await probe.report(error: $0) },
            sleep: { try await probe.sleep(nanoseconds: $0) }
        )

        await runner.run()

        let snapshot = await probe.snapshot()
        #expect(snapshot.subscribeAttempts == 4)
        #expect(snapshot.presentedNotificationKeys == ["notif-c"])
        #expect(snapshot.errorCount == 3)
        #expect(snapshot.sleepDelays == [1, 2, 2, 1])
    }
}

struct TelemetryBuildConfigTests {

    @Test func defaultsToStagingAndTreatsUnresolvedBuildSettingsAsMissing() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "DarkmatterTelemetryOTLPEndpoint": "$(DARKMATTER_OTLP_ENDPOINT)",
            "DarkmatterTelemetryBearerToken": "$(DARKMATTER_OTLP_BEARER_TOKEN)",
            "DarkmatterTelemetryEnvironment": "",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [:])

        #expect(config.otlpEndpoint == TelemetryBuildConfig.defaultOtlpEndpoint)
        #expect(config.bearerToken == nil)
        #expect(!config.telemetryCredentialsAvailable)
        #expect(config.deploymentEnvironment == "staging")
        #expect(config.serviceVersion == "1.2.3+45")
    }

    @Test func unresolvedBuildSettingsCanReadTelemetryCredentialsFromEnvironment() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "DarkmatterTelemetryOTLPEndpoint": "$(DARKMATTER_OTLP_ENDPOINT)",
            "DarkmatterTelemetryBearerToken": "$(DARKMATTER_OTLP_BEARER_TOKEN)",
            "DarkmatterTelemetryEnvironment": "$(DARKMATTER_TELEMETRY_ENVIRONMENT)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "DARKMATTER_OTLP_ENDPOINT": "https://collector.example/v1/metrics",
            "OTLP_TOKEN_DARKMATTER_IOS": "env-token",
            "DARKMATTER_TELEMETRY_ENVIRONMENT": "production"
        ])

        #expect(config.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(config.bearerToken == "env-token")
        #expect(config.telemetryCredentialsAvailable)
        #expect(config.deploymentEnvironment == "production")
    }

    @Test func productionEnvironmentMustBeExplicitlyConfigured() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "DarkmatterTelemetryOTLPEndpoint": "https://collector.example/v1/metrics",
            "DarkmatterTelemetryBearerToken": "secret-token",
            "DarkmatterTelemetryEnvironment": "production",
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "9"
        ])

        #expect(config.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(config.bearerToken == "secret-token")
        #expect(config.telemetryCredentialsAvailable)
        #expect(config.deploymentEnvironment == "production")
        #expect(config.serviceVersion == "2.0+9")
    }

    @Test func runtimeConfigCarriesInstallAndIOSResourceFields() {
        let config = TelemetryBuildConfig(
            otlpEndpoint: "https://collector.example/v1/metrics",
            bearerToken: "secret-token",
            deploymentEnvironment: "staging",
            serviceVersion: "2.0+9",
            osVersion: "26.0",
            deviceModelIdentifier: "iPhone99,9"
        )

        let runtime = config.runtimeConfig(installId: "install-a")

        #expect(runtime.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(runtime.authorizationBearerToken == "secret-token")
        #expect(runtime.resource?.serviceVersion == "2.0+9")
        #expect(runtime.resource?.serviceInstanceId == "install-a")
        #expect(runtime.resource?.deploymentEnvironment == "staging")
        #expect(runtime.resource?.tenant == "darkmatter-ios")
        #expect(runtime.resource?.osType == "darwin")
        #expect(runtime.resource?.osVersion == "26.0")
        #expect(runtime.resource?.deviceModelIdentifier == "iPhone99,9")
    }

    @Test func supportedDeploymentEnvironmentsPassThrough() {
        for environment in ["production", "staging", "development", "test"] {
            let config = TelemetryBuildConfig.current(infoDictionary: [
                "DarkmatterTelemetryEnvironment": environment
            ], environment: [:])

            #expect(config.deploymentEnvironment == environment)
        }
    }

    @Test func auditTrackerConfigDefersEndpointToMarmotAndCarriesCredentialsAndSource() {
        let config = TelemetryBuildConfig(
            otlpEndpoint: "https://collector.example/v1/metrics",
            bearerToken: "secret-token",
            deploymentEnvironment: "staging",
            serviceVersion: "2.0+9",
            osVersion: "Version 18.0",
            deviceModelIdentifier: "iPhone99,9"
        )

        let tracker = config.auditTrackerConfig()

        #expect(tracker.endpoint == nil)
        #expect(tracker.authorizationBearerToken == "secret-token")
        #expect(tracker.source.accountLabel == nil)
        #expect(tracker.source.deviceLabel == "iPhone99,9")
        #expect(tracker.source.platform == "ios")
        #expect(tracker.source.appVersion == "2.0+9")
    }
}

@MainActor
struct RelativeTimeTests {

    @Test func shortReusesCachedDateFormattersForRepeatedListRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekdayDate = now.addingTimeInterval(-3 * 24 * 3600)
        let olderDate = now.addingTimeInterval(-10 * 24 * 3600)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = RelativeTime.short(weekdayDate, now: now, calendar: calendar)
        }
        #expect(RelativeTime.formatterCacheCountForTesting == 1)

        for _ in 0..<50 {
            _ = RelativeTime.short(olderDate, now: now, calendar: calendar)
        }
        #expect(RelativeTime.formatterCacheCountForTesting == 2)
    }

    @Test func shortTimeReusesCachedDateFormatterForMessageBubbles() {
        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = RelativeTime.shortTime(messageDate)
        }

        #expect(RelativeTime.formatterCacheCountForTesting == 1)
    }

    @Test func shortRefreshesFormatterCacheWhenLocaleIdentifierChanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekdayDate = now.addingTimeInterval(-3 * 24 * 3600)
        let olderDate = now.addingTimeInterval(-10 * 24 * 3600)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        _ = RelativeTime.short(weekdayDate, now: now, calendar: calendar)
        _ = RelativeTime.short(olderDate, now: now, calendar: calendar)
        #expect(RelativeTime.formatterCacheCountForTesting == 2)

        RelativeTime.setFormatterCacheLocaleIdentifierForTesting("stale-locale")
        _ = RelativeTime.short(weekdayDate, now: now, calendar: calendar)

        #expect(RelativeTime.formatterCacheCountForTesting == 1)
        #expect(RelativeTime.formatterCacheLocaleIdentifierForTesting == Locale.autoupdatingCurrent.identifier)
    }

    @Test func messageBubbleTimeLabelUsesCachedFormatter() throws {
        let source = try String(contentsOf: messageBubbleSourceURL, encoding: .utf8)

        #expect(source.matches(#"private var timeLabel: String\s*\{[\s\S]*RelativeTime\.shortTime\("#))
        #expect(!source.matches(#"private var timeLabel: String\s*\{[\s\S]*DateFormatter\("#))
    }

    private var messageBubbleSourceURL: URL {
        let testFile = URL(fileURLWithPath: #filePath)
        return testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/MessageBubble.swift")
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
            inbox: RelayListFfi(kind: 39000, relays: ["wss://inbox.example"])
        )

        #expect(RelaySettings.editableRelays(from: lists) == ["wss://nip65.example"])
        #expect(RelaySettings.bootstrapRelays(from: lists) == ["wss://source.example"])
    }

    @Test func relayInputAllowsWebsocketSchemesOnly() {
        #expect(RelaySettings.normalizedRelayURL("  ws://relay.example  ") == "ws://relay.example")
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example") == "wss://relay.example")
        #expect(RelaySettings.normalizedRelayURL("https://relay.example") == nil)
        #expect(RelaySettings.normalizedRelayURL("relay.example") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss:// ") == nil)
        #expect(RelaySettings.normalizedRelayURL("ws://\n") == nil)
    }

    @Test func relayNormalizationDeduplicatesSchemeAndHostCase() {
        #expect(
            RelaySettings.normalizedRelayURL("WSS://Relay.DAMUS.IO/Nostr?Token=ABC")
                == "wss://relay.damus.io/Nostr?Token=ABC"
        )
        #expect(RelaySettings.normalizedRelayURLs([
            "WSS://Relay.DAMUS.IO",
            "wss://relay.damus.io"
        ]) == ["wss://relay.damus.io"])
    }

    @Test func savingRelaysReloadsAuthoritativeListsWhenFinalPublishFails() async throws {
        let oldLists = relayLists(
            bootstrapRelays: ["wss://source.example"],
            nip65: ["wss://old.example"],
            inbox: ["wss://old.example"]
        )
        let manager = FakeAccountRelayListManager(lists: oldLists, failNip65: true)

        do {
            _ = try await RelaySettings.saveAccountRelays(
                accountRef: "account-a",
                relays: ["  wss://new.example  "],
                currentLists: oldLists,
                manager: manager
            )
            Issue.record("Expected relay save to fail")
        } catch let failure as RelaySettingsSaveFailure {
            #expect(failure.reloadedLists == relayLists(
                bootstrapRelays: ["wss://source.example"],
                nip65: ["wss://old.example"],
                inbox: ["wss://new.example"]
            ))
            #expect(manager.calls == [
                .inbox(relays: ["wss://new.example"], bootstrapRelays: ["wss://source.example"]),
                .nip65(relays: ["wss://new.example"], bootstrapRelays: ["wss://source.example"]),
                .reload(accountRef: "account-a")
            ])
        } catch {
            Issue.record("Expected RelaySettingsSaveFailure, got \(error)")
        }
    }
}

private enum RelayManagerCall: Equatable {
    case reload(accountRef: String)
    case inbox(relays: [String], bootstrapRelays: [String])
    case nip65(relays: [String], bootstrapRelays: [String])
}

private enum RelayManagerError: LocalizedError {
    case nip65Rejected

    var errorDescription: String? {
        "NIP-65 relay update rejected"
    }
}

private final class FakeAccountRelayListManager: AccountRelayListManaging {
    var calls: [RelayManagerCall] = []

    private var lists: AccountRelayListsFfi
    private let failNip65: Bool

    init(lists: AccountRelayListsFfi, failNip65: Bool) {
        self.lists = lists
        self.failNip65 = failNip65
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        calls.append(.reload(accountRef: accountRef))
        return lists
    }

    func setAccountInboxRelays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi {
        calls.append(.inbox(relays: relays, bootstrapRelays: bootstrapRelays))
        lists.inbox = RelayListFfi(kind: 39000, relays: relays)
        return lists
    }

    func setAccountNip65Relays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi {
        calls.append(.nip65(relays: relays, bootstrapRelays: bootstrapRelays))
        if failNip65 {
            throw RelayManagerError.nip65Rejected
        }
        lists.nip65 = RelayListFfi(kind: 10002, relays: relays)
        return lists
    }
}

private func relayLists(
    bootstrapRelays: [String],
    nip65: [String],
    inbox: [String]
) -> AccountRelayListsFfi {
    AccountRelayListsFfi(
        complete: true,
        missing: [],
        defaultRelays: [],
        bootstrapRelays: bootstrapRelays,
        nip65: RelayListFfi(kind: 10002, relays: nip65),
        inbox: RelayListFfi(kind: 39000, relays: inbox)
    )
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}

@MainActor
struct AppContainerConfigTests {

    @Test func seedRelaysUseWhiteNoiseRegionalRelaysOnly() {
        #expect(AppContainerConfig.seedRelays == [
            "wss://relay.eu.whitenoise.chat",
            "wss://relay.us.whitenoise.chat"
        ])
    }

    @Test func productionPushServerConfigIsPresent() {
        let config = NativePushServerConfig.current()

        #expect(config?.serverPubkeyHex == "73a4996bd18de19f6ac5f6ad42f5f2671eba6e5b739ea9695f07b00b0693fc04")
        #expect(config?.relayHint == "wss://relay.primal.net")
    }

    @Test func marmotRootUsesStableDirectoryName() {
        let base = URL(fileURLWithPath: "/tmp/darkmatter-test", isDirectory: true)

        #expect(AppContainerConfig.marmotRoot(in: base).path == "/tmp/darkmatter-test/Marmot")
    }

    @Test func productionRootThrowsWhenAppGroupContainerUnavailable() {
        // Marmot data must live only in the shared App Group container so the
        // app and the Notification Service Extension share one store. When the
        // container is missing we hard-fail rather than fork the store into a
        // per-process path.
        let fileManager = StubFileManager(
            sharedContainerURL: nil
        )

        #expect(throws: AppContainerError.appGroupContainerUnavailable) {
            _ = try AppContainerConfig.productionMarmotRoot(fileManager: fileManager)
        }
        #expect(fileManager.applicationSupportLookupCount == 0)
    }

    @Test func productionRootDoesNotConsultApplicationSupport() throws {
        let shared = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotShared-\(UUID().uuidString)", isDirectory: true)
        let fileManager = StubFileManager(
            sharedContainerURL: shared
        )

        let root = try AppContainerConfig.productionMarmotRoot(fileManager: fileManager)

        #expect(root.path == shared.appendingPathComponent("Marmot").path)
        #expect(fileManager.applicationSupportLookupCount == 0)
    }

    @Test func productionRootSurfacesDirectoryCreationFailure() {
        let shared = URL(fileURLWithPath: "/tmp/darkmatter-unwritable", isDirectory: true)
        let root = shared.appendingPathComponent("Marmot", isDirectory: true)
        let creationError = NSError(
            domain: "AppContainerConfigTests",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let fileManager = StubFileManager(
            sharedContainerURL: shared,
            createDirectoryError: creationError
        )

        #expect(throws: AppContainerError.storageDirectoryCreationFailed(
            path: root.path,
            reason: "permission denied"
        )) {
            _ = try AppContainerConfig.productionMarmotRoot(fileManager: fileManager)
        }
        #expect(fileManager.createdDirectories.map(\.path) == [root.path])
    }
}

/// Test double that lets us drive `AppContainerConfig`'s storage resolution
/// down its failure branches deterministically.
private final class StubFileManager: FileManager {
    private let sharedContainerURL: URL?
    private let createDirectoryError: Error?
    private(set) var applicationSupportLookupCount = 0
    private(set) var createdDirectories: [URL] = []

    init(
        sharedContainerURL: URL?,
        createDirectoryError: Error? = nil
    ) {
        self.sharedContainerURL = sharedContainerURL
        self.createDirectoryError = createDirectoryError
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        sharedContainerURL
    }

    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        if directory == .applicationSupportDirectory {
            applicationSupportLookupCount += 1
        }
        return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }

    override func fileExists(atPath path: String) -> Bool {
        if createDirectoryError != nil { return false }
        return super.fileExists(atPath: path)
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        createdDirectories.append(url)
        if let createDirectoryError {
            throw createDirectoryError
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
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

    @Test func countLocalizationsUseStaticFormatKeysInSource() throws {
        let dynamicCountKeys = [
            (
                "darkmatter-ios/Conversation/ConversationViewModel.swift",
                #"L10n.string("\(memberCount) members")"#
            ),
            (
                "darkmatter-ios/Conversation/ConversationView.swift",
                #"L10n.string("\(memberCount) members")"#
            ),
            (
                "darkmatter-ios/Group/GroupDetailsView.swift",
                #"L10n.string("Invited \(refs.count) members")"#
            ),
            (
                "darkmatter-ios/Group/GroupDetailsView.swift",
                #"L10n.string("Published \(summary.published) updates.")"#
            ),
            (
                "darkmatter-ios/Settings/ProfileEditView.swift",
                #"L10n.string("Your kind:0 metadata is live on \(relays.count) relays.")"#
            ),
            (
                "darkmatter-ios/Core/GroupDisplay.swift",
                #"L10n.string("\(memberCount) person group")"#
            ),
        ]

        for (relativePath, dynamicKey) in dynamicCountKeys {
            let source = try readSource(relativePath)

            #expect(!source.contains(dynamicKey), "\(relativePath) still uses dynamic localization key \(dynamicKey)")
        }
    }

    @Test func formattedLocalizationUsesStaticCatalogKeys() {
        #expect(
            L10n.formatted(
                "%lld members",
                arguments: [Int64(3)],
                locale: Locale(identifier: "de")
            ) == "3-Mitglieder"
        )
        #expect(
            L10n.formatted(
                "Invited %lld members",
                arguments: [Int64(3)],
                locale: Locale(identifier: "it")
            ) == "Membri 3 invitati"
        )
        #expect(
            L10n.formatted(
                "Published %lld updates.",
                arguments: [Int64(2)],
                locale: Locale(identifier: "zh-Hans")
            ) == "已发布 2 更新。"
        )
        #expect(
            L10n.formatted(
                "Your kind:0 metadata is live on %lld relays.",
                arguments: [Int64(4)],
                locale: Locale(identifier: "de")
            ) == "Ihre kind:0-Metadaten sind live auf 4-Relays."
        )
        #expect(
            L10n.formatted(
                "%lld person group",
                arguments: [Int64(3)],
                locale: Locale(identifier: "it")
            ) == "3 gruppo di persone"
        )
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

    private func readSource(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
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

struct ComposerInputChromeTests {
    @Test func lightModeComposerInputUsesLightSystemFill() {
        let lightFill = ComposerInputChrome.overlayFill(for: .light)
        let darkFill = ComposerInputChrome.overlayFill(for: .dark)

        #expect(lightFill.base == .systemBackground)
        #expect(lightFill.opacity > darkFill.opacity)
    }

    @Test func darkModeComposerInputKeepsSmokyOverlay() {
        let fill = ComposerInputChrome.overlayFill(for: .dark)

        #expect(fill.base == .black)
        #expect(fill.opacity == 0.26)
    }
}

@MainActor
struct ToastPresentationTests {
    @Test func toastOverlayPresentsAboveModalWindows() {
        #expect(ToastOverlayPresentation.windowLevel.rawValue > UIWindow.Level.alert.rawValue)
    }
}

struct DiagnosticsPresentationTests {
    @Test func messageReceivedDiagnosticRedactsPlaintextButKeepsEventShape() {
        let secret = "secret launch code"
        let sender = hex("11")
        let event = MarmotEventFfi.messageReceived(
            received: RuntimeMessageReceivedFfi(
                accountIdHex: hex("aa"),
                accountLabel: "alice",
                message: ReceivedMessageFfi(
                    messageIdHex: hex("bb"),
                    groupIdHex: hex("cc"),
                    sender: sender,
                    senderDisplayName: nil,
                    plaintext: secret,
                    kind: MessageSemantics.kindChat,
                    tags: [],
                    recordedAt: 42
                )
            )
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] msg from \(IdentityFormatter.short(sender))"))
        #expect(text.contains("(\(secret.count) chars)"))
        #expect(!text.contains(secret))

        let emptyEvent = MarmotEventFfi.messageReceived(
            received: RuntimeMessageReceivedFfi(
                accountIdHex: hex("aa"),
                accountLabel: "alice",
                message: ReceivedMessageFfi(
                    messageIdHex: hex("dd"),
                    groupIdHex: hex("cc"),
                    sender: sender,
                    senderDisplayName: nil,
                    plaintext: "",
                    kind: MessageSemantics.kindChat,
                    tags: [],
                    recordedAt: 43
                )
            )
        )

        let emptyText = DiagnosticsView.diagnosticText(for: emptyEvent)
        #expect(emptyText.contains("[alice] msg from \(IdentityFormatter.short(sender))"))
        #expect(emptyText.contains("(empty)"))
        #expect(!emptyText.contains(secret))
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

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: newer)!,
            additionalPresentations: [
                LocalNotificationProjection.makePresentation(for: older)!
            ]
        ))
    }

    @Test func newDataCollectionCarriesRemainingPresentationsForSameWake() {
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
        let selfMessage = notificationUpdate(
            notificationKey: "self",
            isFromSelf: true,
            timestampMs: 3_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [older, selfMessage, newer],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: newer)!,
            additionalPresentations: [
                LocalNotificationProjection.makePresentation(for: older)!
            ]
        ))
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

    @Test func decisionIsNotMainActorIsolatedForExtensionUse() throws {
        let source = try String(contentsOf: notificationServiceProjectionSourceURL, encoding: .utf8)

        #expect(!source.matches(#"@MainActor\s+static func decision\("#))
    }

    private var notificationServiceProjectionSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/NotificationServiceProjection.swift")
    }
}

struct NotificationServiceTests {
    @Test func notificationServiceSerializesFinishOnMainActor() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"@MainActor\s+final class NotificationService"#))
        #expect(source.matches(#"private func finish\(\)[\s\S]*self\.contentHandler = nil[\s\S]*self\.bestAttemptContent = nil[\s\S]*contentHandler\(bestAttemptContent\)"#))
    }

    @Test func notificationServiceSchedulesAdditionalPresentationsBeforeFinish() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.contains("additionalPresentations"))
        #expect(source.contains("UNUserNotificationCenter.current().add"))
    }

    @Test func serviceTimeoutShutsDownActiveMarmotBeforeFinishing() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"private var activeMarmot: Marmot\?"#))
        #expect(source.matches(#"activeMarmot = marmot"#))
        #expect(source.matches(#"await marmot\.shutdown\(\)[\s\S]*activeMarmot = nil"#))
        #expect(source.matches(#"override func serviceExtensionTimeWillExpire\(\)[\s\S]*collectionTask\?\.cancel\(\)[\s\S]*guard let marmot = activeMarmot[\s\S]*activeMarmot = nil[\s\S]*expirationTask = Task[\s\S]*await marmot\.shutdown\(\)[\s\S]*await self\?\.finish\(\)"#))
        #expect(!source.matches(#"override func serviceExtensionTimeWillExpire\(\)\s*\{\s*collectionTask\?\.cancel\(\)\s*finish\(\)\s*\}"#))
    }

    private var notificationServiceSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NotificationServiceExtension/NotificationService.swift")
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
        #expect(ProfileSanitizer.imageURL("http://example.com/a.png") == nil)
    }

    @Test func imageURLRejectsDangerousSchemes() {
        #expect(ProfileSanitizer.imageURL("data:image/png;base64,AAAA") == nil)
        #expect(ProfileSanitizer.imageURL("file:///etc/passwd") == nil)
        #expect(ProfileSanitizer.imageURL("javascript:alert(1)") == nil)
        #expect(ProfileSanitizer.imageURL("ftp://example.com/x") == nil)
        #expect(ProfileSanitizer.imageURL("https://") == nil) // no host
        #expect(ProfileSanitizer.imageURL("not a url") == nil)
    }

    @Test func imageURLRejectsPrivateAndLoopbackHosts() {
        #expect(ProfileSanitizer.imageURL("https://localhost/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://127.0.0.1/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://10.1.2.3/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://172.16.0.1/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://172.31.255.255/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://192.168.1.10/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://169.254.169.254/latest/meta-data/") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::1]/avatar.png") == nil)

        #expect(ProfileSanitizer.imageURL("https://172.32.0.1/avatar.png") != nil)
    }

    @Test func imageURLRejectsIPv4MappedIPv6PrivateAndLoopbackHosts() {
        #expect(ProfileSanitizer.imageURL("https://[::ffff:127.0.0.1]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::ffff:10.1.2.3]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::ffff:172.16.0.1]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::ffff:192.168.1.10]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::ffff:c0a8:010a]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[0:0:0:0:0:ffff:169.254.169.254]/latest/meta-data/") == nil)

        #expect(ProfileSanitizer.imageURL("https://[::ffff:8.8.8.8]/avatar.png") != nil)
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

    @Test func messageBodyUsesCachedBlankLineRegex() throws {
        let source = try String(contentsOf: profileSanitizerSourceURL, encoding: .utf8)

        #expect(source.contains("private static let blankLineRunRegex"))
        #expect(!source.matches(#"static func messageBody\(_ raw: String\) -> String \{[\s\S]*options:\s*\.regularExpression"#))
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

    private var profileSanitizerSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/ProfileSanitizer.swift")
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

struct DeepLinkTests {

    @Test func generatedURLKeepsDelimiterCharactersInsidePathComponent() {
        let profileURL = DeepLink.profile(npub: "npub?query#fragment/child").url
        let chatURL = DeepLink.chat(groupIdHex: "ABC?query#fragment/child").url

        #expect(profileURL.absoluteString == "darkmatter://profile/npub%3Fquery%23fragment%2Fchild")
        #expect(profileURL.query == nil)
        #expect(profileURL.fragment == nil)

        #expect(chatURL.absoluteString == "darkmatter://chat/ABC%3Fquery%23fragment%2Fchild")
        #expect(chatURL.query == nil)
        #expect(chatURL.fragment == nil)
    }
}

@MainActor
struct ConversationChromeTests {

    @Test func initialChromeUsesChatListTitleBeforeViewModelLoads() {
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "", id: hex("aa")),
            initialTitle: "Alice",
            initialMemberCount: nil
        )

        #expect(chrome.title == "Alice")
        #expect(chrome.subtitle == nil)
    }

    @Test func initialChromeReservesKnownMemberSubtitle() {
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "", id: hex("aa")),
            initialTitle: "Project Room",
            initialMemberCount: 2
        )

        #expect(chrome.title == "Project Room")
        #expect(chrome.subtitle == "2 members")
    }

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

    @Test func previewTextSanitizesProjectedLastMessage() throws {
        let unsafe = chatListRow(
            groupIdHex: hex("d0"),
            title: "Unsafe",
            lastMessage: chatListPreview(
                messageIdHex: hex("d1"),
                plaintext: " hello\u{202E}\nthere\u{200B} ",
                timelineAt: 1
            )
        )

        let item = ChatsListViewModel.Item(row: unsafe)

        #expect(item.previewText == "hello there")
    }

    @Test func localArchiveChangeMovesProjectedRowBetweenScopes() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: hex("d1"), title: "General")
        viewModel.applyChatListSnapshot([row])

        viewModel.applyLocalGroupChange(group(name: "General", id: row.groupIdHex, archived: true))

        #expect(viewModel.items.isEmpty)
        #expect(viewModel.archivedItems.map(\.id) == [row.groupIdHex])
        #expect(viewModel.archivedItems.first?.isArchived == true)
    }

    @Test func chatListRemoveUpdateDropsProjectedRow() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let kept = chatListRow(groupIdHex: hex("d1"), title: "Keep")
        let removed = chatListRow(groupIdHex: hex("d2"), title: "Remove")
        viewModel.applyChatListSnapshot([kept, removed])

        viewModel.applyChatListUpdate(.removeRow(trigger: .removed, groupIdHex: removed.groupIdHex))

        #expect(viewModel.items.map(\.id) == [kept.groupIdHex])
        #expect(viewModel.archivedItems.isEmpty)
    }

    @Test func chatListItemsDoNotExposeSyntheticGroupRecords() throws {
        let source = try String(contentsOf: chatsListViewModelSourceURL, encoding: .utf8)

        #expect(!source.contains("var group: AppGroupRecordFfi"))
        #expect(!source.contains("endpoint: \"\""))
        #expect(!source.contains("admins: []"))
    }

    @Test func chatDestinationResolvesFullGroupBeforeOpeningConversation() throws {
        let source = try String(contentsOf: chatsListViewSourceURL, encoding: .utf8)

        #expect(source.contains("@State private var resolvedGroup"))
        #expect(source.contains("groupDetails(accountRef: accountRef, groupIdHex: item.id)"))
        #expect(source.matches(#"ConversationView\(\s*chat: resolvedGroup"#))
    }

    @Test func chatListUsesMessagesStyleSearchAndComposeChrome() throws {
        let source = try String(contentsOf: chatsListViewSourceURL, encoding: .utf8)

        #expect(source.contains(#".navigationTitle("Chats")"#))
        #expect(source.contains("private var chatSearchBar"))
        #expect(source.contains("chatListBottomAccessory"))
        #expect(source.contains("safeAreaBar(edge: .bottom"))
        #expect(source.contains("safeAreaInset(edge: .bottom"))
        #expect(source.contains("glassEffect(.regular"))
        #expect(source.contains("private let chatListSearchHorizontalInset: CGFloat = 12"))
        #expect(source.contains(".padding(.horizontal, chatListSearchHorizontalInset)"))
        #expect(source.contains(#"TextField("Search", text: $searchText, onEditingChanged: { isEditing in"#))
        #expect(source.contains(#"Image(systemName: "mic.fill")"#))
        #expect(source.contains(".frame(height: 44)"))
        #expect(source.contains("private func focusSearchField()"))
        #expect(source.contains("private var searchCancellationActive: Bool"))
        #expect(source.contains("searchFocused || searchEditing"))
        #expect(source.contains(".searchDictationBehavior(.inline(activation: .onSelect))"))
        #expect(source.contains("private func cancelSearch()"))
        #expect(source.contains("UIApplication.shared.sendAction"))
        #expect(source.contains("private func searchActionTapped()"))
        #expect(source.contains("searchText = \"\""))
        #expect(source.contains("searchFocused = false"))
        #expect(!source.contains("safeAreaInset(edge: .top"))
        #expect(!source.contains(#".searchable(text: $searchText"#))
        #expect(!source.contains(#""Search chats""#))
        #expect(source.contains("private var filterMenu"))
        #expect(source.contains("case active, archived, unread"))
        #expect(source.contains(#"Picker("Filter", selection: $scope)"#))
        #expect(!source.contains("ToolbarItem(placement: .principal)"))
        #expect(!source.contains("scopePills"))
    }

    @Test func chatsListViewModelDeclaresMainActorIsolation() throws {
        let source = try String(contentsOf: chatsListViewModelSourceURL, encoding: .utf8)

        #expect(source.matches(#"@Observable\s+@MainActor\s+final class ChatsListViewModel"#))
        #expect(source.matches(#"isolated deinit\s*\{"#))
    }

    private var chatsListViewModelSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Chats/ChatsListViewModel.swift")
    }

    private var chatsListViewSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Chats/ChatsListView.swift")
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

    @Test func deleteMessageChecksPermissionBeforeOptimisticTombstone() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)

        #expect(source.matches(#"func deleteMessage\(_ message: AppMessageRecordFfi\) async \{[\s\S]*Self\.canDeleteMessage\(message, myAccountId: myAccountId, isSelfAdmin: isSelfAdmin\)[\s\S]*optimisticDeletedMessageIds\.insert"#))
    }

    @Test func canDeleteMessageRequiresSenderOrAdminPermission() {
        let me = hex("11")
        let mine = message(id: hex("a1"), sender: me)
        let other = message(id: hex("a2"), sender: hex("22"))
        let emptyId = message(id: "", sender: me)

        #expect(ConversationViewModel.canDeleteMessage(mine, myAccountId: me, isSelfAdmin: false))
        #expect(ConversationViewModel.canDeleteMessage(other, myAccountId: me, isSelfAdmin: true))
        #expect(!ConversationViewModel.canDeleteMessage(other, myAccountId: me, isSelfAdmin: false))
        #expect(!ConversationViewModel.canDeleteMessage(mine, myAccountId: nil, isSelfAdmin: false))
        #expect(!ConversationViewModel.canDeleteMessage(emptyId, myAccountId: me, isSelfAdmin: true))
    }

    @Test func failedTimelineSubscriptionRetriesWithBackoff() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)

        #expect(source.matches(#"private func startLiveTimeline\(accountRef: String\)[\s\S]*while !Task\.isCancelled[\s\S]*subscribeTimelineMessages[\s\S]*Task\.sleep\(nanoseconds: retryDelay\)[\s\S]*Self\.nextLiveSubscriptionRetryDelay"#))
    }

    @Test func liveSubscriptionRetryDelayDoublesUntilCapped() {
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 500_000_000) == 1_000_000_000)
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 4_000_000_000) == 8_000_000_000)
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 8_000_000_000) == 8_000_000_000)
    }

    @Test func conversationErrorStateOffersRetryAction() throws {
        let source = try String(contentsOf: conversationViewSourceURL, encoding: .utf8)

        #expect(source.matches(#"if let error = viewModel\.error[\s\S]*ContentUnavailableView[\s\S]*Couldn't load conversation[\s\S]*Button\(\"Retry\"\)[\s\S]*await viewModel\.start\(\)"#))
    }

    @Test func startClearsOptimisticOverlaysBeforeRebindingSubscriptions() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)

        #expect(source.matches(#"func start\(\) async \{[\s\S]*stopLiveSubscriptions\(\)\s*resetOptimisticState\(\)[\s\S]*startLiveTimeline"#))
        #expect(source.matches(#"private func resetOptimisticState\(\) \{[\s\S]*optimisticDeletedMessageIds\.removeAll\(\)[\s\S]*optimisticReactionRemovals\.removeAll\(\)[\s\S]*reactionRecords\.removeAll\(\)[\s\S]*rebuildDeletedMessageIds\(\)[\s\S]*recomputeReactions\(\)"#))
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
                        changes: [],
                        chatListRow: row,
                        chatListTrigger: .newLastMessage
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

    @Test func projectionRemoveRetractsTimelineRecord() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let existing = timelineRecord(messageIdHex: hex("a1"), plaintext: "existing", timelineAt: 10)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [existing], hasMoreBefore: false, hasMoreAfter: false),
            placement: .tail
        )

        viewModel.applyTimelineSubscriptionUpdate(
            .projection(
                update: RuntimeProjectionUpdateFfi(
                    accountIdHex: hex("ff"),
                    accountLabel: "account-a",
                    update: TimelineProjectionUpdateFfi(
                        groupIdHex: existing.groupIdHex,
                        messages: [],
                        changes: [.remove(messageIdHex: existing.messageIdHex, reason: .invalidated)],
                        chatListRow: nil,
                        chatListTrigger: .snapshotRefresh
                    )
                )
            )
        )

        #expect(viewModel.timeline.isEmpty)
        #expect(viewModel.record(for: existing.messageIdHex) == nil)
    }

    @Test func projectedOutgoingMessageReplacesMatchingPendingBubble() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "hello from me",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let projected = timelineRecord(
            messageIdHex: hex("b2"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 20
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-1", record: pending)
        viewModel.applyTimelineSubscriptionUpdate(
            .projection(
                update: RuntimeProjectionUpdateFfi(
                    accountIdHex: sender,
                    accountLabel: "account-a",
                    update: TimelineProjectionUpdateFfi(
                        groupIdHex: groupIdHex,
                        messages: [projected],
                        changes: [],
                        chatListRow: nil,
                        chatListTrigger: .newLastMessage
                    )
                )
            )
        )

        let messages = viewModel.timeline.compactMap { item -> (String, MessageStatus, UInt64)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.timestamp)
        }

        #expect(messages.count == 1)
        #expect(messages.first?.0 == projected.messageIdHex)
        #expect(messages.first?.1 == .sent)
        #expect(messages.first?.2 == projected.timelineAt)
    }

    @Test func projectedOutgoingMessageReconcilesClosestPendingBubbleWhenContentMatches() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let plaintext = "same text twice"
        let olderPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let newerPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 20,
            receivedAt: 20
        )
        let tempIds = try #require(
            tempIdsWhereTransientTimelinePrefersNewerPendingFirst(older: olderPending, newer: newerPending)
        )
        let projectedOlder = timelineRecord(
            messageIdHex: hex("c3"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            timelineAt: olderPending.recordedAt
        )

        viewModel.applyPendingOutgoingMessage(tempId: tempIds.older, record: olderPending)
        viewModel.applyPendingOutgoingMessage(tempId: tempIds.newer, record: newerPending)
        viewModel.applyTimelineSubscriptionUpdate(
            .projection(
                update: RuntimeProjectionUpdateFfi(
                    accountIdHex: sender,
                    accountLabel: "account-a",
                    update: TimelineProjectionUpdateFfi(
                        groupIdHex: groupIdHex,
                        messages: [projectedOlder],
                        changes: [],
                        chatListRow: nil,
                        chatListTrigger: .newLastMessage
                    )
                )
            )
        )

        let messages = viewModel.timeline.compactMap { item -> (id: String, status: MessageStatus, timestamp: UInt64)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.timestamp)
        }

        #expect(messages.count == 2)
        #expect(messages.first?.id == projectedOlder.messageIdHex)
        #expect(messages.first?.status == .sent)
        #expect(messages.first?.timestamp == projectedOlder.timelineAt)
        #expect(messages.last?.id == "")
        #expect(messages.last?.status == .sending)
        #expect(messages.last?.timestamp == newerPending.recordedAt)
    }

    @Test func singleTimelineMutationsAvoidFullTimelineRebuild() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)

        #expect(source.matches(#"private func upsertTimelineItem\("#))
        #expect(!source.matches(#"func applyPendingOutgoingMessage[\s\S]*?rebuildTimeline\("#))
        #expect(!source.matches(#"private func upsertStreamBubble[\s\S]*?rebuildTimeline\("#))
    }

    @Test func conversationViewModelDeclaresMainActorIsolation() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)

        #expect(source.matches(#"@Observable\s+@MainActor\s+final class ConversationViewModel"#))
    }

    private var conversationViewModelSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/ConversationViewModel.swift")
    }

    private var conversationViewSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/ConversationView.swift")
    }

    private func tempIdsWhereTransientTimelinePrefersNewerPendingFirst(
        older olderRecord: AppMessageRecordFfi,
        newer newerRecord: AppMessageRecordFfi
    ) -> (older: String, newer: String)? {
        for olderIndex in 0..<256 {
            for newerIndex in 0..<256 where newerIndex != olderIndex {
                let older = "duplicate-older-\(olderIndex)"
                let newer = "duplicate-newer-\(newerIndex)"
                let olderItem = TimelineItem.pendingMessage(tempId: older, record: olderRecord)
                let newerItem = TimelineItem.pendingMessage(tempId: newer, record: newerRecord)
                var values: [String: TimelineItem] = [:]
                values[olderItem.id] = olderItem
                values[newerItem.id] = newerItem
                if values.first?.key == newerItem.id {
                    return (older, newer)
                }
            }
        }
        return nil
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

    @Test func memberRefRejectsNonASCIIHRPWithoutCrashing() {
        // Regression test for issue #35: a bech32 string whose HRP contains a
        // Unicode scalar > 0x1FFF used to trap in bech32VerifyChecksum via
        // UInt8($0.value >> 5). The decoder must reject it and return nil.
        let crafted = "nprofile🎉1qpzry9x8gf2tvdw0s3jn54khce6mua7l"

        #expect(NostrProfileReference.memberRef(from: crafted) == nil)
        #expect(NostrProfileReference.memberRef(fromReference: crafted) == nil)
        #expect(DeepLink.parse(string: "nostr:\(crafted)") == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: crafted) == nil)
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "darkmatter://profile/\(crafted)") == nil
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

    @Test func adminStatusIgnoresLocalAccountLabelFallback() throws {
        let admin = hex("11")
        let nonAdminMember = AppGroupMemberRecordFfi(
            memberIdHex: hex("22"),
            account: admin,
            local: false
        )
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", admins: [admin])
        )

        #expect(!viewModel.isAdmin(nonAdminMember))
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

    @Test func agentStreamStartsAreWatchedOnlyUntilFinalAnchorArrives() {
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

        #expect(ConversationViewModel.agentStreamStartIdToWatch(from: start, finalizedStreamIds: []) == streamId)
        #expect(ConversationViewModel.agentStreamStartIdToWatch(from: start, finalizedStreamIds: [streamId]) == nil)
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
    @Test func streamChunksAreCappedToMessageBodyLimit() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let almostFull = String(repeating: "a", count: ProfileSanitizer.maxMessageLength - 1)

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: almostFull)
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: "bcdef")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 3, text: "late")
        )

        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a capped stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext.count == ProfileSanitizer.maxMessageLength)
        #expect(record.plaintext.hasSuffix("ab"))
        #expect(!record.plaintext.contains("c"))
        #expect(!record.plaintext.contains("late"))
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

    @Test func mediaReferenceRejectsUnsafeURLSchemes() {
        let nonce = String(repeating: "22", count: 12)
        for url in [
            "http://media.example/a.png",
            "ftp://media.example/a.png",
            "file:///tmp/a.png",
        ] {
            let record = unsignedEventRecord(
                plaintext: "caption",
                kind: MessageSemantics.kindChat,
                tags: [
                    MessageTagFfi(values: [
                        MessageSemantics.imetaTag,
                        "url \(url)",
                        "m image/png",
                        "filename a.png",
                        "x \(hex("33"))",
                        "n \(nonce)",
                        "v mip04-v2",
                        "size 7",
                    ])
                ]
            )

            #expect(MessageSemantics.classify(record) == .unknown)
            #expect(!MessagePreview.isPreviewable(record))
        }
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

    @Test func copyStoresSensitiveTextWithExpirationOptions() throws {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let expiry = Date().addingTimeInterval(120)

        SensitiveClipboard.copy("private message", to: pasteboard, expiresAt: expiry)

        #expect(pasteboard.string == "private message")

        let source = try String(contentsOf: sensitiveClipboardSourceURL, encoding: .utf8)
        #expect(source.contains("options: [.expirationDate: expiresAt]"))
        #expect(source.contains("UIPasteboard.typeAutomatic"))
    }

    @Test func messageCopyActionUsesExpiringSensitiveClipboard() throws {
        let source = try String(contentsOf: conversationViewSourceURL, encoding: .utf8)

        #expect(source.contains("SensitiveClipboard.copy(viewModel.displayBody(of: record))"))
        #expect(!source.contains("UIPasteboard.general.string = viewModel.displayBody(of: record)"))
    }

    @Test func importIdentityClearsPastedSecretOnEveryOutcome() throws {
        let source = try String(contentsOf: importIdentityViewSourceURL, encoding: .utf8)

        #expect(source.matches(#"defer\s*\{\s*SensitiveClipboard\.clear\(trimmed\)\s*\}"#))
        #expect(!source.matches(#"try await appState\.importIdentity\(trimmed\)[\s\S]{0,200}SensitiveClipboard\.clear\(trimmed\)"#))
    }

    private func makeIsolatedPasteboard() -> UIPasteboard {
        let name = UIPasteboard.Name("dev.ipf.darkmatter.tests.sensitive-clipboard-\(UUID().uuidString)")
        return UIPasteboard(name: name, create: true)!
    }

    private var sensitiveClipboardSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Onboarding/SensitiveClipboard.swift")
    }

    private var conversationViewSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/ConversationView.swift")
    }

    private var importIdentityViewSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Onboarding/ImportIdentityView.swift")
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

private actor NotificationSubscriptionProbe {
    enum Attempt {
        case failure
        case updates([NotificationUpdateFfi])
    }

    struct Snapshot {
        let subscribeAttempts: Int
        let presentedNotificationKeys: [String]
        let errorCount: Int
        let sleepDelays: [UInt64]
    }

    private var attempts: [Attempt]
    private var subscribeAttempts = 0
    private var presentedNotificationKeys: [String] = []
    private var errorCount = 0
    private var sleepDelays: [UInt64] = []

    init(attempts: [Attempt]) {
        self.attempts = attempts
    }

    func subscribe() throws -> AsyncStream<NotificationUpdateFfi> {
        subscribeAttempts += 1
        let index = subscribeAttempts - 1
        guard attempts.indices.contains(index) else {
            return AsyncStream { continuation in continuation.finish() }
        }

        switch attempts[index] {
        case .failure:
            throw NotificationSubscriptionTestError.transient
        case .updates(let updates):
            return AsyncStream { continuation in
                for update in updates {
                    continuation.yield(update)
                }
                continuation.finish()
            }
        }
    }

    func present(_ update: NotificationUpdateFfi) {
        presentedNotificationKeys.append(update.notificationKey)
    }

    func report(error: Error) {
        errorCount += 1
    }

    func sleep(nanoseconds delay: UInt64) throws {
        sleepDelays.append(delay)
        if !presentedNotificationKeys.isEmpty {
            throw CancellationError()
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            subscribeAttempts: subscribeAttempts,
            presentedNotificationKeys: presentedNotificationKeys,
            errorCount: errorCount,
            sleepDelays: sleepDelays
        )
    }
}

private enum NotificationSubscriptionTestError: Error {
    case transient
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
