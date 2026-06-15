import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
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
        let appState = try testAppState()
        #expect(appState.phase == .bootstrapping)
        #expect(appState.accounts.isEmpty)
        #expect(appState.activeToast == nil)
    }

    @Test func bootstrapWithoutAccountsTransitionsToOnboarding() async throws {
        // Use a fresh AppState backed by a tempdir-based MarmotClient so
        // we don't collide with the user's real Application Support data.
        let appState = try testAppState()
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        #expect(appState.accounts.isEmpty)
    }

    @Test func concurrentBootstrapCallsShareOneInFlightRun() async throws {
        let appState = try testAppState()

        async let first: Void = appState.bootstrap()
        async let second: Void = appState.bootstrap()
        await first
        await second

        #expect(appState.phase == .onboarding)
        #expect(appState.accounts.isEmpty)
    }

    @Test func telemetryExportSettingPersistsThroughAppState() async throws {
        let appState = try testAppState()

        let saved = try await appState.setRelayTelemetryExportEnabled(false)

        #expect(!saved.exportEnabled)
        #expect(try appState.relayTelemetrySettings().exportEnabled == false)
    }

    @Test func suspendedRuntimeTelemetryBuildConfigUsesCachedFallback() async throws {
        let fallback = TelemetryBuildConfig(
            otlpEndpoint: "https://cached.example/v1/metrics",
            bearerToken: "cached-token",
            auditLogBearerToken: "cached-audit-token",
            deploymentEnvironment: "test",
            serviceVersion: "cached-version",
            osVersion: "cached-os",
            deviceModelIdentifier: "cached-device"
        )
        let appState = try testAppState(suspendedRuntimeTelemetryBuildConfig: fallback)

        await appState.bootstrap()
        _ = try await appState.createIdentity()
        #expect(appState.telemetryBuildConfig != fallback)

        await appState.prepareForBackgroundSuspension()

        #expect(appState.client == nil)
        #expect(appState.telemetryBuildConfig == fallback)
        #expect(appState.telemetryBuildConfig == fallback)
    }

    @Test func createIdentityFromOnboardingStartsNotificationSubscription() async throws {
        let appState = try testAppState()
        await appState.bootstrap()

        #expect(appState.phase == .onboarding)
        #expect(!appState.notificationSubscriptionActive)

        try await appState.createIdentity()

        #expect(appState.phase == .ready)
        #expect(appState.notificationSubscriptionActive)

        await stopReadyRuntime(appState)
    }

    @Test func createIdentityDefaultsNotificationsOnWhenPermissionIsGranted() async throws {
        var authorizationRequestCount = 0
        var remoteRegistrationRequestCount = 0
        let notifications = grantedNotifications(
            onAuthorizationRequest: {
                authorizationRequestCount += 1
            },
            remoteNotificationRegistrar: {
                remoteRegistrationRequestCount += 1
            }
        )
        let appState = try testAppState(notifications: notifications)
        await appState.bootstrap()

        let account = try await appState.createIdentity()

        let settings = try #require(appState.notificationSettings(for: account.label))
        #expect(settings.localNotificationsEnabled)
        #expect(settings.nativePushEnabled)
        #expect(authorizationRequestCount == 1)
        #expect(remoteRegistrationRequestCount == 1)

        await stopReadyRuntime(appState)
    }

    @Test func createIdentityKeepsNotificationDefaultsOffWhenPermissionIsDenied() async throws {
        var remoteRegistrationRequestCount = 0
        let notifications = deniedNotifications {
            remoteRegistrationRequestCount += 1
        }
        let appState = try testAppState(notifications: notifications)
        await appState.bootstrap()

        let account = try await appState.createIdentity()

        let settings = try #require(appState.notificationSettings(for: account.label))
        #expect(!settings.localNotificationsEnabled)
        #expect(!settings.nativePushEnabled)
        #expect(remoteRegistrationRequestCount == 0)
        #expect(appState.phase == .ready)

        await stopReadyRuntime(appState)
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

    @Test func bootstrapReentryAwaitsInFlightTask() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)
        let bootstrapPattern =
            #"func bootstrap\(\) async \{[\s\S]*"#
            + #"if let bootstrapTask \{[\s\S]*await bootstrapTask\.value[\s\S]*return[\s\S]*"#
            + #"Task \{ @MainActor \[weak self\] in[\s\S]*performBootstrap\(\)"#

        #expect(source.contains("private var bootstrapTask: Task<Void, Never>?"))
        #expect(source.matches(bootstrapPattern))
    }

    @Test func bootstrapFailureReleasesPartialRuntimeBeforeRetry() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)
        let catchPattern =
            #"private func performBootstrap\(\) async \{[\s\S]*"#
            + #"catch \{[\s\S]*"#
            + #"await releaseRuntimeAfterStartupFailure\(\)[\s\S]*"#
            + #"phase = \.failed\(error\.localizedDescription\)"#
        let cleanupPattern =
            #"private func releaseRuntimeAfterStartupFailure\(\) async \{[\s\S]*"#
            + #"pushTask\?\.cancel\(\)[\s\S]*"#
            + #"await pushTask\?\.value[\s\S]*"#
            + #"await client\.marmot\.shutdown\(\)[\s\S]*"#
            + #"self\.client = nil"#

        #expect(source.matches(catchPattern))
        #expect(source.matches(cleanupPattern))
    }

    @Test func foregroundResumeFailureReleasesPartialRuntimeBeforeRetry() throws {
        // #200: the foreground-resume catch must release the partial runtime
        // (shutdown + client = nil) before showing the failure screen, mirroring
        // the bootstrap-path fix in #183. Otherwise `client` is left pointing at
        // the instance whose `startRuntime()` already failed, and Retry →
        // bootstrap() → runtimeClient() reuses that broken client instead of
        // rebuilding a fresh one. No injectable runtime seam exists to fail
        // `startRuntime()` after `client` is set without a real failing FFI, so
        // (as with #183) the catch contract is asserted at the source level.
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)
        let resumeStart = try #require(
            source.range(of: "func resumeAfterForegroundActivation() async {")
        )
        let resumeEnd = try #require(
            source.range(of: "private func noteRuntimeForegroundReadyAfterSuspension()")
        )
        let resumeBody = String(source[resumeStart.lowerBound..<resumeEnd.lowerBound])

        let catchPattern =
            #"catch \{[\s\S]*"#
            + #"await releaseRuntimeAfterStartupFailure\(\)[\s\S]*"#
            + #"phase = \.failed\(error\.localizedDescription\)[\s\S]*"#
            + #"return"#
        #expect(resumeBody.matches(catchPattern))
    }

    @Test func presentingAToastUpdatesActiveToast() async throws {
        let appState = try testAppState()
        await MainActor.run {
            appState.present(.success("Hello"))
        }
        #expect(appState.activeToast?.title == "Hello")
        #expect(appState.activeToast?.style == .success)

        await MainActor.run { appState.dismissToast() }
        #expect(appState.activeToast == nil)
    }

    @Test func toastPresentationIsBackedByFocusedToastState() async throws {
        let appState = try testAppState()
        await MainActor.run {
            appState.present(.success("Hello"))
        }

        #expect(appState.toastState.activeToast?.title == "Hello")
        #expect(appState.activeToast == appState.toastState.activeToast)

        await MainActor.run { appState.dismissToast() }
        #expect(appState.toastState.activeToast == nil)
    }

    @Test func notificationSubscriptionErrorsAreDedupedAndRedacted() async throws {
        let appState = try testAppState()
        let sensitiveError = SensitiveNotificationSubscriptionError()

        appState.reportNotificationSubscriptionError(sensitiveError)
        let firstToast = try #require(appState.activeToast)
        #expect(firstToast.title == "Notifications unavailable")
        #expect(firstToast.message == "We'll keep trying in the background.")
        #expect(!(firstToast.message?.contains(sensitiveError.errorDescription ?? "") ?? false))

        appState.reportNotificationSubscriptionError(sensitiveError)
        #expect(appState.activeToast?.id == firstToast.id)

        appState.noteNotificationSubscriptionDelivery()
        appState.reportNotificationSubscriptionError(sensitiveError)

        #expect(appState.activeToast?.id != firstToast.id)
        #expect(appState.activeToast?.message == "We'll keep trying in the background.")
    }

    @Test func toastSleepDurationIsClampedBeforeNanosecondConversion() {
        #expect(ToastState.sleepNanoseconds(forDuration: -1) == 0)
        #expect(ToastState.sleepNanoseconds(forDuration: .nan) == 0)
        #expect(ToastState.sleepNanoseconds(forDuration: .infinity) == UInt64.max)
        #expect(ToastState.sleepNanoseconds(forDuration: 1.25) == 1_250_000_000)
    }

    @Test func routingIsBackedByFocusedNavigationState() async throws {
        let appState = try testAppState()
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

    @Test func appInjectsFocusedStateStoresIntoEnvironment() throws {
        let source = try String(contentsOf: appSourceURL, encoding: .utf8)

        #expect(source.contains(".environment(appState.toastState)"))
        #expect(source.contains(".environment(appState.navigation)"))
    }

    @Test func notificationPresentationPolicyRunsOnMainActor() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)
        let presentationPattern =
            #"present:\s*\{ \[weak self\] update in[\s\S]*"#
            + #"let localNotificationsEnabled = await self\.localNotificationsEnabledForPresentation\([\s\S]*"#
            + #"accountRef: update\.accountRef[\s\S]*"#
            + #"let shouldPresent = await MainActor\.run \{[\s\S]*"#
            + #"self\.noteNotificationSubscriptionDelivery\(\)[\s\S]*"#
            + #"self\.shouldPresentLocalNotification\([\s\S]*"#
            + #"localNotificationsEnabled: localNotificationsEnabled[\s\S]*"#
            + #"guard shouldPresent else \{ return \}[\s\S]*"#
            + #"await self\.notifications\.present\(update: update\)"#
        let oldPresentationPattern =
            #"present:\s*\{ \[weak self\] update in\s*"#
            + #"guard let self, self\.shouldPresentLocalNotification"#

        #expect(source.matches(#"@MainActor\s+private func shouldPresentLocalNotification"#))
        #expect(source.matches(presentationPattern))
        #expect(!source.matches(oldPresentationPattern))
    }

    @Test func notificationPresentationSettingsReadFailureFailsOpen() throws {
        let appStateSource = try String(contentsOf: appStateSourceURL, encoding: .utf8)
        let marmotClientSource = try String(contentsOf: marmotClientSourceURL, encoding: .utf8)
        let helperPattern =
            #"@MainActor\s+private func localNotificationsEnabledForPresentation\(accountRef: String\) async -> Bool \{[\s\S]*"#
            + #"let client = try runtimeClient\(\)[\s\S]*"#
            + #"return await client\.localNotificationsEnabledForPresentation\(accountRef: accountRef\)"#
        let clientHelperPattern =
            #"func localNotificationsEnabledForPresentation\(accountRef: String\) async -> Bool \{[\s\S]*"#
            + #"Task\.detached\(priority: \.utility\) \{ \[marmot, accountRef\] in[\s\S]*"#
            + #"do \{[\s\S]*return try marmot\.notificationSettings\(accountRef: accountRef\)\.localNotificationsEnabled[\s\S]*"#
            + #"\} catch \{[\s\S]*return true[\s\S]*\}"#
        let policyPattern =
            #"LocalNotificationSuppressionPolicy\.shouldPresent\([\s\S]*"#
            + #"localNotificationsEnabled: localNotificationsEnabled"#

        #expect(appStateSource.matches(helperPattern))
        #expect(marmotClientSource.matches(clientHelperPattern))
        #expect(appStateSource.matches(policyPattern))
        #expect(!appStateSource.contains("return try marmot.notificationSettings(accountRef: accountRef).localNotificationsEnabled"))
        #expect(!appStateSource.matches(#"localNotificationsEnabled:\s*\(try\? marmot\.notificationSettings"#))
    }

    @Test func visibleChatRouteTracksAccountAndClearsOnlyMatchingRoute() async throws {
        let appState = try testAppState()
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
        let appState = try testAppState()

        await appState.prepareForBackgroundSuspension()

        #expect(!appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == 0)
    }

    @Test func readyRuntimeSuspendsForBackgroundAndResumesForForeground() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

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

        await stopReadyRuntime(appState)
    }

    @Test func bootstrapRetryAfterSuspendedRuntimeClearsForegroundGates() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let generation = appState.runtimeGeneration

        await appState.prepareForBackgroundSuspension()
        appState.setAppSceneActive(true)

        #expect(appState.runtimeSuspendedForBackground)
        #expect(!appState.canRefreshProfiles)

        await appState.bootstrap()

        #expect(appState.phase == .ready)
        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.canRefreshProfiles)
        #expect(appState.runtimeGeneration == generation + 1)

        await stopReadyRuntime(appState)
    }

    @Test func auditLogSettingChangeHotSwapsWithoutRestartingRuntime() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        let generation = appState.runtimeGeneration
        let settings = try await appState.setAuditLogEnabled(true)

        #expect(settings.enabled)
        #expect(try appState.auditLogSettings().enabled)
        #expect(appState.runtimeGeneration == generation)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(!appState.marmot.isStopping())

        await stopReadyRuntime(appState)
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

    @Test func foregroundResumeSchedulesNativePushAfterBestEffortCatchUp() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)
        let catchUpStart = try #require(source.range(of: "func catchUpAfterForegroundActivation() async {"))
        let catchUpEnd = try #require(source.range(of: "func setAppSceneActive(_ active: Bool)"))
        let catchUpBody = source[catchUpStart.lowerBound..<catchUpEnd.lowerBound]

        #expect(catchUpBody.contains("try await marmot.catchUpAccounts()"))
        #expect(!catchUpBody.contains("syncNativePushRegistrationIfEnabled()"))

        let resumeStart = try #require(source.range(of: "func resumeAfterForegroundActivation() async {"))
        let resumeEnd = try #require(source.range(of: "private func noteRuntimeForegroundReadyAfterSuspension()"))
        let resumeBody = source[resumeStart.lowerBound..<resumeEnd.lowerBound]

        #expect(String(resumeBody).matches(
            #"await catchUpAfterForegroundActivation\(\)\s+"#
                + #"guard isAppSceneActive, !Task\.isCancelled else \{ return \}\s+"#
                + #"scheduleNativePushRegistrationIfEnabled\(\)\s+"#
                + #"resumeProfileFetchQueueIfNeeded\(\)"#
        ))
    }

    @Test func profileFetchQueueLeavesQueuedIDsWhenRefreshBecomesUnavailable() async throws {
        let appState = try testAppState()
        let queued = [hex("11"), hex("22")]
        appState.queuedProfileFetchIDs = queued
        appState.scheduledProfileFetchIDs = Set(queued)
        appState.setAppSceneActive(false)

        await appState.runProfileFetchQueueForTesting()

        #expect(appState.queuedProfileFetchIDs == queued)
        #expect(appState.scheduledProfileFetchIDs == Set(queued))
        #expect(appState.activeProfileFetchID == nil)
        #expect(appState.profileFetchQueueTask == nil)
    }

    @Test func profileFetchQueueRearmsPreservedIDsWhenRefreshIsAllowed() async throws {
        let appState = try testAppState()
        let queued = [hex("33")]
        appState.queuedProfileFetchIDs = queued
        appState.scheduledProfileFetchIDs = Set(queued)

        appState.resumeProfileFetchQueueIfNeeded()
        let task = appState.cancelProfileFetchQueue()

        #expect(task != nil)
    }

    @Test func signOutDisablesNativePushAndSwitchesActiveAccount() async throws {
        // Regression for issue #7: signing out must clear the signed-out
        // account's push registration so the push server stops delivering
        // its notifications to this device. Previously sign-out only mutated
        // `activeAccountRef`, leaving the registration (and the
        // `nativePushEnabled` preference) intact.
        let seeded = try await readyAppStateWithCreatedIdentities(accountCount: 2)
        let appState = seeded.appState
        let accountA = seeded.accounts[0]
        let accountB = seeded.accounts[1]
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

        await stopReadyRuntime(appState)
    }

    @Test func signOutOfOnlyAccountClearsAccountStateAndReturnsToOnboarding() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let only = seeded.accounts[0]
        appState.activeAccountRef = only.label

        await appState.signOut()

        #expect(appState.accounts.isEmpty)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.notificationSettings(for: only.label) == nil)
        // Signing out of the last account must route back to onboarding
        // rather than leaving the main UI up with no active account.
        #expect(appState.phase == .onboarding)
    }

    @Test func signOutOfOnlyAccountClearsPersistedActiveAccountRef() async throws {
        // Without this, the next launch reads the stale label from
        // UserDefaults and bootstrap points at an account that was removed
        // from local Marmot storage.
        UserDefaults.standard.removeObject(forKey: "marmot.activeAccountRef")
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client, notifications: deniedNotifications())
        await appState.bootstrap()
        let only = try await appState.createIdentity()
        appState.activeAccountRef = only.label
        #expect(UserDefaults.standard.string(forKey: "marmot.activeAccountRef") == only.label)

        await appState.signOut()

        #expect(UserDefaults.standard.string(forKey: "marmot.activeAccountRef") == nil)
        let reborn = AppState(client: try client.freshRuntime(), notifications: deniedNotifications())
        #expect(reborn.activeAccountRef == nil)
    }

    private func testAppState(
        notifications: AppNotifications? = nil,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig? = nil
    ) throws -> AppState {
        resetPersistedActiveAccountRef()
        let client = try MarmotClient.testClient()
        if let suspendedRuntimeTelemetryBuildConfig {
            return AppState(
                client: client,
                notifications: notifications ?? deniedNotifications(),
                suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig
            )
        }
        return AppState(client: client, notifications: notifications ?? deniedNotifications())
    }

    private func readyAppStateWithCreatedIdentities(
        accountCount: Int = 1,
        notifications: AppNotifications? = nil
    ) async throws -> (appState: AppState, accounts: [AccountSummaryFfi]) {
        let appState = try testAppState(notifications: notifications)
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        var accounts: [AccountSummaryFfi] = []
        for _ in 0..<accountCount {
            let account = try await appState.createIdentity()
            accounts.append(account)
        }
        #expect(appState.phase == .ready)
        return (appState, accounts)
    }

    private func deniedNotifications(
        remoteNotificationRegistrar: @escaping () -> Void = {}
    ) -> AppNotifications {
        AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .denied },
            remoteNotificationRegistrar: remoteNotificationRegistrar
        )
    }

    private func grantedNotifications(
        onAuthorizationRequest: @escaping () -> Void = {},
        remoteNotificationRegistrar: @escaping () -> Void = {}
    ) -> AppNotifications {
        AppNotifications(
            requestAuthorizationHandler: {
                onAuthorizationRequest()
                return true
            },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: remoteNotificationRegistrar
        )
    }

    private func stopReadyRuntime(_ appState: AppState) async {
        guard appState.phase == .ready || appState.notificationSubscriptionActive else { return }
        await appState.prepareForBackgroundSuspension()
        resetPersistedActiveAccountRef()
    }

    private func resetPersistedActiveAccountRef() {
        UserDefaults.standard.removeObject(forKey: "marmot.activeAccountRef")
    }

    private var appStateSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/AppState.swift")
    }

    private var marmotClientSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/MarmotClient.swift")
    }

    private var appSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/darkmatter_iosApp.swift")
    }

}

struct NotificationSubscriptionRetryTests {
    @MainActor
    @Test func driverClearsRunningStateWhenRunnerCompletes() async throws {
        let driver = NotificationDriver()
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: 1,
            maximumRetryDelayNanoseconds: 8,
            subscribe: {
                AsyncStream { continuation in continuation.finish() }
            },
            present: { _ in },
            reportError: { _ in },
            sleep: { _ in throw CancellationError() }
        )

        driver.start(runner: runner)
        #expect(driver.isRunning)

        for _ in 0..<1000 where driver.isRunning {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(!driver.isRunning)
    }

    @Test func driverStateMutationsStayOnMainActor() throws {
        let source = try String(contentsOf: notificationDriverSourceURL, encoding: .utf8)

        #expect(source.matches(#"@MainActor\s+final class NotificationDriver"#))
        #expect(source.matches(
            #"task = Task \{ \[weak self\] in[\s\S]*"#
            + #"await runner\.run\(\)[\s\S]*"#
            + #"await MainActor\.run \{[\s\S]*"#
            + #"self\?\.clearCompletedTask\(id: id\)"#
        ))
    }

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

    private var notificationDriverSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/NotificationDriver.swift")
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
            auditLogBearerToken: nil,
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
            bearerToken: "otlp-token",
            auditLogBearerToken: "audit-token",
            deploymentEnvironment: "staging",
            serviceVersion: "2.0+9",
            osVersion: "Version 18.0",
            deviceModelIdentifier: "iPhone99,9"
        )

        let tracker = config.auditTrackerConfig()

        #expect(tracker.endpoint == nil)
        // Must carry the dedicated audit-log token, NOT the OTLP/telemetry token.
        #expect(tracker.authorizationBearerToken == "audit-token")
        #expect(tracker.source.accountLabel == nil)
        #expect(tracker.source.deviceLabel == "iPhone99,9")
        #expect(tracker.source.platform == "ios")
        #expect(tracker.source.appVersion == "2.0+9")
    }

    @Test func auditTokenIsReadFromDedicatedKeyAndDoesNotFallBackToOtlpToken() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "DarkmatterTelemetryBearerToken": "$(DARKMATTER_OTLP_BEARER_TOKEN)",
            "DarkmatterAuditLogBearerToken": "$(DARKMATTER_AUDIT_LOG_BEARER_TOKEN)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "OTLP_TOKEN_DARKMATTER_IOS": "otlp-env-token",
            "AUDIT_LOG_TOKEN_DARKMATTER_IOS": "audit-env-token"
        ])

        #expect(config.bearerToken == "otlp-env-token")
        #expect(config.auditLogBearerToken == "audit-env-token")
        #expect(config.auditTrackerConfig().authorizationBearerToken == "audit-env-token")
    }

    @Test func auditTokenStaysNilWhenOnlyOtlpTokenIsConfigured() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "DarkmatterTelemetryBearerToken": "$(DARKMATTER_OTLP_BEARER_TOKEN)",
            "DarkmatterAuditLogBearerToken": "$(DARKMATTER_AUDIT_LOG_BEARER_TOKEN)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "OTLP_TOKEN_DARKMATTER_IOS": "otlp-env-token"
        ])

        // No dedicated audit token => audit uploads stay unconfigured rather than
        // borrowing the OTLP token and authenticating against the wrong API.
        #expect(config.bearerToken == "otlp-env-token")
        #expect(config.auditLogBearerToken == nil)
        #expect(config.auditTrackerConfig().authorizationBearerToken == nil)
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

    @Test func shortReusesCachedDurationFormattersForRecentRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let minutesAgo = now.addingTimeInterval(-4 * 60)
        let hoursAgo = now.addingTimeInterval(-2 * 3600)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = RelativeTime.short(minutesAgo, now: now, calendar: calendar)
        }
        #expect(RelativeTime.durationFormatterCacheCountForTesting == 1)

        for _ in 0..<50 {
            _ = RelativeTime.short(hoursAgo, now: now, calendar: calendar)
        }
        #expect(RelativeTime.durationFormatterCacheCountForTesting == 2)
        #expect(RelativeTime.formatterCacheCountForTesting == 0)
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

    @Test func shortUsesLocalizedAbbreviatedDurationsForRecentRows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let locale = Locale(identifier: "ar_EG")

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        let minuteLabel = RelativeTime.short(
            now.addingTimeInterval(-4 * 60),
            now: now,
            calendar: calendar,
            locale: locale
        )
        let hourLabel = RelativeTime.short(
            now.addingTimeInterval(-2 * 3600),
            now: now,
            calendar: calendar,
            locale: locale
        )

        let expectedMinute = try expectedAbbreviatedDuration(4, unit: .minute, locale: locale)
        let expectedHour = try expectedAbbreviatedDuration(2, unit: .hour, locale: locale)
        #expect(minuteLabel == expectedMinute)
        #expect(hourLabel == expectedHour)
        #expect(minuteLabel != "4m")
        #expect(hourLabel != "2h")
    }

    @Test func shortUsesLocalizedDateTemplateOrderingForOlderDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 10,
            hour: 12
        )))
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 20,
            hour: 12
        )))
        let locale = Locale(identifier: "en_US")
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = locale
        expectedFormatter.setLocalizedDateFormatFromTemplate("d MMM")

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        let rendered = RelativeTime.short(date, now: now, calendar: calendar, locale: locale)
        let expected = expectedFormatter.string(from: date)
        #expect(rendered == expected)
    }

    @Test func messageBubbleTimeLabelUsesCachedFormatter() {
        let timestamp: UInt64 = 1_700_000_000

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = MessageBubble.timeLabel(recordedAt: timestamp)
        }

        #expect(RelativeTime.formatterCacheCountForTesting == 1)
    }

    private func expectedAbbreviatedDuration(
        _ value: Int,
        unit: NSCalendar.Unit,
        locale: Locale
    ) throws -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [unit]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1

        let secondsPerUnit: TimeInterval = unit == .hour ? 3600 : 60
        return try #require(formatter.string(from: TimeInterval(value) * secondsPerUnit))
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
        #expect(config?.relayHint == "wss://relay.eu.whitenoise.chat")
        #expect(config?.relayHint == AppContainerConfig.pushNotificationRelayHint)
        #expect(AppContainerConfig.seedRelays.contains(config?.relayHint ?? ""))
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
            _ = try #require(rawEntry as? [String: Any], "Invalid localization entry: \(key)")
            let expectedPlaceholders = placeholders(in: key)
            for locale in expectedLocales {
                let values = try localizedLeafValues(key, locale: locale, in: strings)
                for value in values {
                    if !key.isEmpty {
                        #expect(!value.isEmpty, "Missing \(locale) value for \(key)")
                    }
                    #expect(
                        placeholders(in: value).sorted() == expectedPlaceholders.sorted(),
                        "Broken placeholders for \(key) in \(locale)"
                    )
                }
                if !key.isEmpty {
                    #expect(!values.isEmpty, "Missing \(locale) values for \(key)")
                }
            }
        }
    }

    @Test func dynamicLocalizationsUseStaticFormatKeysInSource() throws {
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
            (
                "Shared/LocalNotificationProjection.swift",
                #"L10n.string("Invitation to \($0)")"#
            ),
            (
                "Shared/LocalNotificationProjection.swift",
                #"L10n.string("\(senderName) sent a message")"#
            ),
            (
                "darkmatter-ios/Chats/ChatRow.swift",
                #"L10n.string("You: \(body)")"#
            ),
        ]

        for (relativePath, dynamicKey) in dynamicCountKeys {
            let source = try readSource(relativePath)

            #expect(!source.contains(dynamicKey), "\(relativePath) still uses dynamic localization key \(dynamicKey)")
        }
    }

    @Test func visibleSourceLiteralsHaveCatalogCoverage() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let knownDebugOnlyDynamicLiterals: Set<String> = [
            #"id: \(record.messageIdHex)"#,
            #"QUIC · \(event.eventKind)"#,
            #"stream \(shortStreamId(event.streamId))"#,
            #"leaf \(token.leafIndex)"#
        ]
        let patterns = [
            #"L10n\.string\("((?:[^"\\]|\\.)*)"\)"#,
            #"L10n\.formatted\("((?:[^"\\]|\\.)*)""#,
            #"L10n\.plural\("((?:[^"\\]|\\.)*)""#,
            #"\bText\("((?:[^"\\]|\\.)*)""#,
            #"\bButton\("((?:[^"\\]|\\.)*)""#,
            #"\bLabel\("((?:[^"\\]|\\.)*)""#,
            #"\bSection\("((?:[^"\\]|\\.)*)""#,
            #"\bPicker\("((?:[^"\\]|\\.)*)""#,
            #"\bToggle\("((?:[^"\\]|\\.)*)""#,
            #"\bTextField\("((?:[^"\\]|\\.)*)""#,
            #"\bSecureField\("((?:[^"\\]|\\.)*)""#,
            #"\.navigationTitle\("((?:[^"\\]|\\.)*)""#,
            #"\.alert\("((?:[^"\\]|\\.)*)""#,
            #"\.confirmationDialog\("((?:[^"\\]|\\.)*)""#,
            #"\.accessibilityLabel\("((?:[^"\\]|\\.)*)""#,
            #"\.accessibilityHint\("((?:[^"\\]|\\.)*)""#
        ].map { try! NSRegularExpression(pattern: $0) }

        for relativePath in try swiftSourcePaths(in: ["darkmatter-ios", "Shared"]) {
            let source = try readSource(relativePath)
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for pattern in patterns {
                for match in pattern.matches(in: source, range: nsRange) {
                    guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
                    let literal = unescapedSourceLiteral(String(source[literalRange]))
                    guard !knownDebugOnlyDynamicLiterals.contains(literal) else { continue }
                    #expect(strings[literal] != nil, "\(relativePath) uses visible string missing from catalog: \(literal)")
                }
            }
        }
    }

    @Test func sharedSourcesStayExtensionSafe() throws {
        for relativePath in try swiftSourcePaths(in: ["Shared"]) {
            let source = try readSource(relativePath)

            #expect(!source.contains("import SwiftUI"), "\(relativePath) imports SwiftUI")
            #expect(!source.contains("import UIKit"), "\(relativePath) imports UIKit")
            #expect(!source.contains("UIApplication"), "\(relativePath) references UIApplication")
            #expect(!source.contains("UIScreen"), "\(relativePath) references UIScreen")
        }
    }

    @Test func countLocalizationsUsePluralVariations() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let pluralKeys = [
            "%lld members",
            "%lld person group",
            "%llu unread messages",
            "📎 %lld attachments",
            "Invited %lld members",
            "Published %lld updates.",
            "Your kind:0 metadata is live on %lld relays.",
            "You can send up to %lld photos at once"
        ]

        for key in pluralKeys {
            for locale in ["en"] + expectedLocales {
                let categories = try pluralCategories(key, locale: locale, in: strings)
                #expect(categories.contains("other"), "\(key) in \(locale) is missing an `other` plural form")
                if locale == "ru" {
                    #expect(categories.isSuperset(of: ["one", "few", "many", "other"]))
                }
            }
        }
    }

    @Test func formattedLocalizationUsesStaticCatalogKeys() {
        #expect(
            L10n.plural(
                "%lld members",
                Int64(3),
                locale: Locale(identifier: "de")
            ) == "3 Mitglieder"
        )
        #expect(
            L10n.plural(
                "Invited %lld members",
                Int64(3),
                locale: Locale(identifier: "it")
            ) == "3 membri invitati"
        )
        #expect(
            L10n.plural(
                "Published %lld updates.",
                Int64(2),
                locale: Locale(identifier: "zh-Hans")
            ) == "已发布 2 个更新。"
        )
        #expect(
            L10n.plural(
                "Your kind:0 metadata is live on %lld relays.",
                Int64(4),
                locale: Locale(identifier: "de")
            ) == "Ihre kind:0-Metadaten sind auf 4 Relays live."
        )
        #expect(
            L10n.plural(
                "%lld person group",
                Int64(3),
                locale: Locale(identifier: "it")
            ) == "Gruppo di 3 persone"
        )
        #expect(
            L10n.plural(
                "Published %lld updates.",
                Int64(5),
                locale: Locale(identifier: "ru")
            ) == "Опубликовано 5 обновлений."
        )
    }

    @Test func infoPlistCatalogLocalizesCameraPermissionCopy() throws {
        let catalog = try readCatalog("darkmatter-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let cameraUsage = try #require(strings["NSCameraUsageDescription"] as? [String: Any])
        let localizations = try #require(cameraUsage["localizations"] as? [String: Any])

        let english = try localizedValue("NSCameraUsageDescription", locale: "en", in: strings)
        #expect(english != "NSCameraUsageDescription")
        #expect(english == "Dark Matter uses the camera to scan profile QR codes and take photos for encrypted chats.")
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

    private func swiftSourcePaths(in relativeDirectories: [String]) throws -> [String] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var paths: [String] = []

        for relativeDirectory in relativeDirectories {
            let root = repoRoot.appendingPathComponent(relativeDirectory)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                paths.append(url.path.replacingOccurrences(of: repoRoot.path + "/", with: ""))
            }
        }

        return paths.sorted()
    }

    private func localizedValue(_ key: String, locale: String, in strings: [String: Any]) throws -> String {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let stringUnit = try #require(localeEntry["stringUnit"] as? [String: Any], "Missing string unit for \(key) in \(locale)")
        return try #require(stringUnit["value"] as? String, "Missing value for \(key) in \(locale)")
    }

    private func localizedLeafValues(_ key: String, locale: String, in strings: [String: Any]) throws -> [String] {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")

        if let substitutions = localeEntry["substitutions"] as? [String: Any] {
            return try substitutions.values.flatMap { rawSubstitution in
                let substitution = try #require(rawSubstitution as? [String: Any])
                let variations = try #require(substitution["variations"] as? [String: Any])
                let plural = try #require(variations["plural"] as? [String: Any])
                return try plural.values.map { rawForm in
                    let form = try #require(rawForm as? [String: Any])
                    let stringUnit = try #require(form["stringUnit"] as? [String: Any])
                    return try #require(stringUnit["value"] as? String)
                }
            }
        }

        return [try localizedValue(key, locale: locale, in: strings)]
    }

    private func pluralCategories(_ key: String, locale: String, in strings: [String: Any]) throws -> Set<String> {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let substitutions = try #require(localeEntry["substitutions"] as? [String: Any])
        let count = try #require(substitutions["count"] as? [String: Any])
        let variations = try #require(count["variations"] as? [String: Any])
        let plural = try #require(variations["plural"] as? [String: Any])
        return Set(plural.keys)
    }

    private func unescapedSourceLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\""#, with: #"""#)
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\t"#, with: "\t")
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

    @Test func languageChangeNotificationCarriesLanguageInUserInfoNotObject() throws {
        let suiteName = "dev.ipf.darkmatter.language-notification-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()

        var received: Notification?
        let observer = notificationCenter.addObserver(
            forName: AppLanguage.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            received = notification
        }
        defer { notificationCenter.removeObserver(observer) }

        AppLanguage.setCurrentRawValue(
            AppLanguage.french.rawValue,
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        let notification = try #require(received)
        #expect(defaults.string(forKey: AppLanguage.storageKey) == "fr")
        #expect(notification.object == nil)
        #expect(notification.userInfo?[AppLanguage.didChangeLanguageUserInfoKey] as? String == "fr")
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
    @Test func diagnosticsStreamRebindsWhenRuntimeGenerationChanges() throws {
        let source = try String(contentsOf: diagnosticsViewSourceURL, encoding: .utf8)

        #expect(source.contains(".task(id: appState.runtimeGeneration)"))
        #expect(!source.contains(".task {\n            streaming = true"))
    }

    @Test func diagnosticSelfSendReusesStoredGroupOnlyWhenPresentForAccount() throws {
        let suiteName = "DiagnosticSelfSendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storedGroupId = hex("ab")
        let otherGroupId = hex("cd")
        DiagnosticSelfSend.remember(
            groupIdHex: storedGroupId,
            accountRef: "alice",
            defaults: defaults
        )
        let stored = chatListRow(
            groupIdHex: storedGroupId,
            archived: true,
            title: DiagnosticSelfSend.groupName
        )
        let other = chatListRow(
            groupIdHex: otherGroupId,
            archived: true,
            title: DiagnosticSelfSend.groupName
        )

        #expect(
            DiagnosticSelfSend.reusableGroup(
                accountRef: "alice",
                rows: [other, stored],
                defaults: defaults
            )?.groupIdHex == storedGroupId
        )
        #expect(
            DiagnosticSelfSend.reusableGroup(
                accountRef: "alice",
                rows: [other],
                defaults: defaults
            ) == nil
        )
        #expect(
            DiagnosticSelfSend.reusableGroup(
                accountRef: "bob",
                rows: [stored],
                defaults: defaults
            ) == nil
        )
    }

    @Test func diagnosticSelfSendUsesStableNeutralGroupName() {
        #expect(DiagnosticSelfSend.groupName == "Self check")
        #expect(!DiagnosticSelfSend.groupName.localizedCaseInsensitiveContains("diagnostic"))
        #expect(!DiagnosticSelfSend.groupName.contains("-"))
    }

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

    private var diagnosticsViewSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Diagnostics/DiagnosticsView.swift")
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

    @Test func notificationFallbacksUseFormattedLocalizationKeys() {
        let invite = notificationUpdate(
            trigger: .groupInvite,
            isDm: false,
            groupName: "Project Room",
            previewText: nil
        )
        let groupMessage = notificationUpdate(
            isDm: false,
            groupName: nil,
            senderName: "Bob",
            previewText: nil
        )

        #expect(LocalNotificationProjection.makePresentation(for: invite)?.body == L10n.formatted("Invitation to %@", "Project Room"))
        #expect(LocalNotificationProjection.makePresentation(for: groupMessage)?.body == L10n.formatted("%@ sent a message", "Bob"))
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

    @Test func enabledAccountRefsCanUseCapturedAccountLabels() {
        let settings = [
            "account-a": Self.settings(nativePushEnabled: true),
            "account-b": Self.settings(nativePushEnabled: false)
        ]

        let enabled = NativePushRegistrationPolicy.enabledAccountRefs(
            accountRefs: ["account-a", "account-b", "account-c"]
        ) { settings[$0] }

        #expect(enabled == ["account-a"])
    }

    @Test func nativePushEnabledLookupIsOffloadedBeforeRegistrationSync() throws {
        let appStateSource = try sourceString("darkmatter-ios/Core/AppState.swift")
        let marmotClientSource = try sourceString("darkmatter-ios/Core/MarmotClient.swift")

        #expect(appStateSource.contains("let accountRefs = await nativePushEnabledAccountRefs()"))
        #expect(appStateSource.contains("private func nativePushEnabledAccountRefs() async -> [String]"))
        #expect(appStateSource.contains("return await client.nativePushEnabledAccountRefs(accountRefs: accountRefs)"))
        #expect(!appStateSource.contains("guard !nativePushEnabledAccountRefs().isEmpty else { return }"))
        #expect(marmotClientSource.contains("Task.detached(priority: .utility)"))
        #expect(marmotClientSource.contains("marmot.notificationSettings(accountRef: accountRef)"))
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

    private static func settings(nativePushEnabled: Bool) -> NotificationSettingsFfi {
        NotificationSettingsFfi(
            accountRef: "account",
            accountIdHex: hex("11"),
            localNotificationsEnabled: true,
            nativePushEnabled: nativePushEnabled
        )
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

struct NativePushDisableCoordinatorTests {

    @Test func disableWritesPreferenceBeforeClearingRegistration() async throws {
        var operations: [String] = []
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            clearPushRegistration: {
                operations.append("clear")
            }
        )

        let settings = try await coordinator.disable()

        #expect(settings.nativePushEnabled == false)
        #expect(operations == ["set:false", "clear"])
    }

    @Test func disableDoesNotClearRegistrationWhenPreferenceWriteFails() async {
        var operations: [String] = []
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                throw NativePushDisableTestError.writeFailed
            },
            clearPushRegistration: {
                operations.append("clear")
            }
        )

        do {
            _ = try await coordinator.disable()
            Issue.record("Expected preference write failure")
        } catch {
            #expect(error as? NativePushDisableTestError == .writeFailed)
        }

        #expect(operations == ["set:false"])
    }

    @Test func disableRollsPreferenceBackWhenRegistrationClearFails() async {
        var operations: [String] = []
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            clearPushRegistration: {
                operations.append("clear")
                throw NativePushDisableTestError.clearFailed
            }
        )

        do {
            _ = try await coordinator.disable()
            Issue.record("Expected registration clear failure")
        } catch {
            #expect(error as? NativePushDisableTestError == .clearFailed)
        }

        #expect(operations == ["set:false", "clear", "set:true"])
    }

    private static func settings(nativePushEnabled: Bool) -> NotificationSettingsFfi {
        NotificationSettingsFfi(
            accountRef: "account-a",
            accountIdHex: hex("11"),
            localNotificationsEnabled: true,
            nativePushEnabled: nativePushEnabled
        )
    }
}

private enum NativePushDisableTestError: Error, Equatable {
    case writeFailed
    case clearFailed
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

    @Test func disabledLocalNotificationsAreNotDecoratedByNSE() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [
                notificationUpdate(accountRef: "disabled-account")
            ],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            localNotificationsEnabled: { _ in false }
        )

        #expect(decision == .fallback)
    }

    @Test func disabledLocalNotificationsAreFilteredBeforeChoosingNewestPresentation() {
        let disabledNewer = notificationUpdate(
            notificationKey: "disabled-newer",
            accountRef: "account-disabled",
            senderName: "Muted",
            previewText: "private",
            timestampMs: 3_000
        )
        let enabledMiddle = notificationUpdate(
            notificationKey: "enabled-middle",
            accountRef: "account-enabled",
            senderName: "Visible",
            previewText: "shown",
            timestampMs: 2_000
        )
        let enabledOlder = notificationUpdate(
            notificationKey: "enabled-older",
            accountRef: "account-enabled",
            senderName: "Also visible",
            previewText: "also shown",
            timestampMs: 1_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [enabledOlder, disabledNewer, enabledMiddle],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            localNotificationsEnabled: { $0 == "account-enabled" }
        )

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: enabledMiddle)!,
            additionalPresentations: [
                LocalNotificationProjection.makePresentation(for: enabledOlder)!
            ]
        ))
    }

    @Test func settingsReadPolicySuppressesOnlyExplicitFalse() {
        #expect(NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
            true
        })
        #expect(!NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
            false
        })
    }

    @Test func settingsReadPolicyFailsOpenOnReadError() {
        #expect(NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
            throw NotificationServiceSettingsReadPolicyTestError.unavailable
        })
    }

    @Test func noDataCollectionKeepsGenericFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .noData,
            notifications: [],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .fallback)
    }

    @Test func selfOnlyCollectionKeepsGenericFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [notificationUpdate(isFromSelf: true)],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .fallback)
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

    @Test func projectionDoesNotAskNSEToSuppressDeliveredAlerts() throws {
        let source = try String(contentsOf: notificationServiceProjectionSourceURL, encoding: .utf8)

        #expect(!source.contains("case suppress"))
        #expect(source.contains("An NSE cannot cancel an alerting APNS push after delivery"))
    }

    private var notificationServiceProjectionSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/NotificationServiceProjection.swift")
    }
}

private enum NotificationServiceSettingsReadPolicyTestError: Error {
    case unavailable
}

struct NotificationServiceTests {
    @Test func notificationServiceSerializesFinishOnMainActor() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"@MainActor\s+final class NotificationService"#))
        #expect(source.matches(#"private func finish\(applyingFallbackForTimeout: Bool = false\)[\s\S]*self\.contentHandler = nil[\s\S]*self\.bestAttemptContent = nil[\s\S]*contentHandler\(bestAttemptContent\)"#))
    }

    @Test func notificationServiceSchedulesAdditionalPresentationsBeforeFinish() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.contains("additionalPresentations"))
        #expect(source.contains("UNUserNotificationCenter.current().add"))
    }

    @Test func notificationServicePrimaryDecorationSetsDefaultSound() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)
        let decoratePattern =
            #"private func decorate\([\s\S]*"# +
            #"content\.body = presentation\.body[\s\S]*"# +
            #"content\.sound = \.default[\s\S]*"# +
            #"content\.threadIdentifier = presentation\.threadIdentifier"#

        #expect(source.matches(decoratePattern))
    }

    @Test func additionalPresentationsAreTrackedAcrossTimeoutCancellation() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"private var additionalPresentationTask: Task<Void, Never>\?"#))
        #expect(source.matches(#"let additionalPresentationTask = startAdditionalPresentations\(additionalPresentations\)[\s\S]*decorate\(content, with: presentation\)[\s\S]*await additionalPresentationTask\?\.value[\s\S]*self\.additionalPresentationTask = nil"#))
        #expect(source.matches(#"private func startAdditionalPresentations\([\s\S]*\) -> Task<Void, Never>\? \{[\s\S]*let task = Task \{ \[additionalPresentations\][\s\S]*UNUserNotificationCenter\.current\(\)\.add\(request\)[\s\S]*additionalPresentationTask = task[\s\S]*return task"#))
        #expect(!source.contains("guard !Task.isCancelled else { return }"))
    }

    @Test func serviceTimeoutWaitsForAdditionalPresentationsBeforeFinishing() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"override func serviceExtensionTimeWillExpire\(\)[\s\S]*let additionalPresentationTask = additionalPresentationTask"#))
        #expect(source.matches(#"guard let marmot = takeActiveMarmotForShutdown\(\) else \{[\s\S]*await additionalPresentationTask\.value[\s\S]*await self\?\.finish\(applyingFallbackForTimeout: true\)"#))
        #expect(source.matches(#"expirationTask = Task[\s\S]*let shutdownTask = Task[\s\S]*await marmot\.shutdown\(\)[\s\S]*await additionalPresentationTask\?\.value[\s\S]*await shutdownTask\.value[\s\S]*await self\?\.finish\(applyingFallbackForTimeout: true\)"#))
    }

    @Test func serviceTimeoutShutsDownActiveMarmotBeforeFinishing() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"private var activeMarmot: Marmot\?"#))
        #expect(source.matches(#"private var activeMarmotNeedsShutdown = false"#))
        #expect(source.matches(#"activeMarmot = marmot"#))
        #expect(source.matches(#"override func serviceExtensionTimeWillExpire\(\)[\s\S]*collectionTask\?\.cancel\(\)[\s\S]*guard let marmot = takeActiveMarmotForShutdown\(\)[\s\S]*expirationTask = Task[\s\S]*await marmot\.shutdown\(\)[\s\S]*await self\?\.finish\(applyingFallbackForTimeout: true\)"#))
        #expect(!source.matches(#"override func serviceExtensionTimeWillExpire\(\)\s*\{\s*collectionTask\?\.cancel\(\)\s*finish\(\)\s*\}"#))
    }

    @Test func serviceShutdownTakesOwnedMarmotAfterStartIsAttempted() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"activeMarmot = marmot[\s\S]*activeMarmotNeedsShutdown = true[\s\S]*try await marmot\.start\(\)"#))
        #expect(!source.matches(#"try await marmot\.start\(\)[\s\S]*activeMarmotNeedsShutdown = true"#))
        #expect(source.contains("if let marmot = takeActiveMarmotForShutdown(marmot)"))
        #expect(source.matches(#"private func takeActiveMarmotForShutdown\(_ marmot: Marmot\? = nil\) -> Marmot\? \{[\s\S]*guard let active = activeMarmot else \{ return nil \}[\s\S]*if let marmot, active !== marmot \{ return nil \}[\s\S]*activeMarmot = nil[\s\S]*defer \{ activeMarmotNeedsShutdown = false \}[\s\S]*guard activeMarmotNeedsShutdown else \{ return nil \}[\s\S]*return active"#))
        #expect(!source.matches(#"catch \{[\s\S]*applyFallback\(to: content\)[\s\S]*\}\s*await marmot\.shutdown\(\)"#))
    }

    @Test func serviceTimeoutAppliesFallbackOnlyBeforeRenderDecision() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.matches(#"private var didApplyRenderDecision = false"#))
        #expect(source.matches(#"override func serviceExtensionTimeWillExpire\(\)[\s\S]*finish\(applyingFallbackForTimeout: true\)"#))
        #expect(source.matches(#"private func apply\([\s\S]*didApplyRenderDecision = true[\s\S]*switch decision"#))
        #expect(source.matches(#"private func finish\(applyingFallbackForTimeout: Bool = false\)[\s\S]*if applyingFallbackForTimeout, !didApplyRenderDecision \{[\s\S]*applyFallback\(to: bestAttemptContent\)"#))
    }

    @Test func serviceNeverReturnsBlankContentForSuppressDecision() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(!source.contains("bestAttemptContent = UNMutableNotificationContent()"))
        #expect(source.matches(#"case \.fallback:[\s\S]*applyFallback\(to: content\)"#))
    }

    @Test func notificationServiceSettingsReadFailureFailsOpen() throws {
        let source = try String(contentsOf: notificationServiceSourceURL, encoding: .utf8)

        #expect(source.contains("NotificationServiceSettingsReadPolicy.localNotificationsEnabled"))
        #expect(!source.contains("(try? marmot.notificationSettings"))
    }

    private var notificationServiceSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NotificationServiceExtension/NotificationService.swift")
    }
}

struct ProfileEditViewTests {
    @Test func profilePictureDraftUsesPublicHTTPSPolicyBeforePublish() throws {
        let source = try String(contentsOf: profileEditSourceURL, encoding: .utf8)

        #expect(source.contains("pictureURL: ProfileSanitizer.imageURL(picture)"))
        #expect(source.contains("private var normalizedPictureURL: String?"))
        #expect(source.contains("ProfileSanitizer.imageURL(trimmedPicture)?.absoluteString"))
        #expect(source.contains("picture: normalizedPictureURL"))
        #expect(source.contains("profile: normalizedMetadata.ffi"))
        #expect(!source.contains("picture: picture.isEmpty ? nil : picture"))
    }

    @Test func profileSaveIsDisabledForInvalidPictureDraft() throws {
        let source = try String(contentsOf: profileEditSourceURL, encoding: .utf8)

        #expect(source.contains(".disabled(saveDisabled)"))
        #expect(source.matches(#"private var saveDisabled: Bool \{[\s\S]*currentDraft\.validationError != nil"#))
        #expect(source.contains(#"L10n.string("Only public HTTPS image URLs are allowed.")"#))
    }

    @Test func profileMetadataDraftSanitizesAndBoundsOutgoingFields() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: " Alice\u{202E}\nEvil ",
            about: String(repeating: "a", count: ProfileSanitizer.maxAboutLength + 25),
            picture: " https://example.com/avatar.png ",
            nip05: " ALICE@Example.COM ",
            lud16: " Sats+Tips@Lightning.Example "
        )

        let metadata = try #require(draft.normalizedMetadata)

        #expect(metadata.name == "Alice Evil")
        #expect(metadata.displayName == "Alice Evil")
        #expect(metadata.about?.count == ProfileSanitizer.maxAboutLength)
        #expect(metadata.picture == "https://example.com/avatar.png")
        #expect(metadata.nip05 == "alice@example.com")
        #expect(metadata.lud16 == "sats+tips@lightning.example")
    }

    @Test func profileMetadataDraftRejectsInvalidFieldsBeforePublish() {
        let invalidPicture = ProfileEditMetadataDraft(
            displayName: "", about: "", picture: "http://example.com/a.png", nip05: "", lud16: ""
        )
        let invalidNip05 = ProfileEditMetadataDraft(
            displayName: "", about: "", picture: "", nip05: "alice example.com", lud16: ""
        )
        let invalidLud16 = ProfileEditMetadataDraft(
            displayName: "", about: "", picture: "", nip05: "", lud16: "alice@"
        )

        #expect(invalidPicture.validationError == .picture)
        #expect(invalidNip05.validationError == .nip05)
        #expect(invalidLud16.validationError == .lud16)
        #expect(invalidPicture.normalizedMetadata == nil)
        #expect(invalidNip05.normalizedMetadata == nil)
        #expect(invalidLud16.normalizedMetadata == nil)
    }

    private var profileEditSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Settings/ProfileEditView.swift")
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
        #expect(ProfileSanitizer.imageURL("https://0.0.0.0/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://0.1.2.3/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://10.1.2.3/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://172.16.0.1/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://172.31.255.255/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://192.168.1.10/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://169.254.169.254/latest/meta-data/") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[0:0:0:0:0:0:0:0]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::1]/avatar.png") == nil)

        #expect(ProfileSanitizer.imageURL("https://172.32.0.1/avatar.png") != nil)
    }

    @Test func imageURLRejectsLegacyIPv4LiteralBypasses() {
        #expect(ProfileSanitizer.imageURL("https://127.0.0.1./avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://2130706433/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://0x7f000001/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://017700000001/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://127.1/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://012.0.0.1/avatar.png") == nil)
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

    @Test func imageURLRejectsIPv4CompatibleIPv6PrivateAndLoopbackHosts() {
        #expect(ProfileSanitizer.imageURL("https://[::127.0.0.1]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::10.1.2.3]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::172.16.0.1]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::192.168.1.10]/avatar.png") == nil)
        #expect(ProfileSanitizer.imageURL("https://[::169.254.169.254]/latest/meta-data/") == nil)
        #expect(ProfileSanitizer.imageURL("https://[0:0:0:0:0:0:c0a8:010a]/avatar.png") == nil)

        #expect(ProfileSanitizer.imageURL("https://[::8.8.8.8]/avatar.png") != nil)
    }

    @Test func profileAddressNormalizesSimpleAddressFields() {
        #expect(ProfileSanitizer.profileAddress(" Alice+Tips@Example.COM ") == "alice+tips@example.com")
        #expect(ProfileSanitizer.profileAddress("alice@example.com") == "alice@example.com")
    }

    @Test func profileAddressRejectsMalformedOrOversizedValues() {
        #expect(ProfileSanitizer.profileAddress("alice") == nil)
        #expect(ProfileSanitizer.profileAddress("alice@localhost") == nil)
        #expect(ProfileSanitizer.profileAddress("alice@-example.com") == nil)
        #expect(ProfileSanitizer.profileAddress("alice@example-.com") == nil)
        #expect(ProfileSanitizer.profileAddress("alice@exa_mple.com") == nil)
        #expect(ProfileSanitizer.profileAddress("a b@example.com") == nil)
        #expect(ProfileSanitizer.profileAddress(String(repeating: "a", count: 65) + "@example.com") == nil)
        #expect(ProfileSanitizer.profileAddress("alice@" + String(repeating: "a", count: 250) + ".com") == nil)
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
        try withAppLanguage(.english) {
            let appState = AppState(client: try MarmotClient.testClient())
            let title = GroupDisplay.title(
                group: group(name: ""),
                otherMember: hex("22"),
                memberCount: 3,
                appState: appState
            )

            #expect(title == "3 person group")
        }
    }

    @MainActor
    @Test func unnamedTwoPersonGroupFallsBackToOtherIdentity() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let other = hex("22")

        let title = GroupDisplay.title(
            group: group(name: ""),
            otherMember: other,
            memberCount: 2,
            appState: appState
        )

        // With no known profile for the peer, a 2-person group resolves to the
        // other member's npub. Name resolution is covered by
        // ResolvedDisplayNameTests now that iOS reads profiles from the binding.
        #expect(title == appState.shortNpub(forAccountIdHex: other))
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

    @MainActor
    @Test func groupAvatarURLWinsOverDirectMessageFallback() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let avatar = GroupDisplay.avatarURL(
            group: group(name: "", avatarUrl: "https://cdn.example.com/group.png"),
            otherMember: hex("22"),
            memberCount: 2,
            appState: appState
        )

        #expect(avatar?.absoluteString == "https://cdn.example.com/group.png")
    }

    @MainActor
    @Test func groupAvatarURLRejectsUnsafeGroupURL() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let avatar = GroupDisplay.avatarURL(
            group: group(name: "Unsafe", avatarUrl: "http://127.0.0.1/group.png"),
            otherMember: hex("22"),
            memberCount: 3,
            appState: appState
        )

        #expect(avatar == nil)
    }
}

struct GroupImageSearchTests {
    @Test func duckDuckGoVQDParserHandlesKnownEmbeddings() throws {
        #expect(DuckDuckGoImageSearchClient.vqdToken(in: #"DDG.duckbar.load('images', {vqd:'4-1234567890'});"#) == "4-1234567890")
        #expect(DuckDuckGoImageSearchClient.vqdToken(in: #""vqd":"3-abc&amp;def""#) == "3-abc&def")
        #expect(DuckDuckGoImageSearchClient.vqdToken(in: #"https://duckduckgo.com/i.js?q=cats&vqd=2-token&ia=images"#) == "2-token")
    }

    @Test func duckDuckGoResultDecoderKeepsOnlyPublicHTTPSImages() throws {
        let json = """
        {
          "results": [
            {
              "title": "Safe",
              "image": "https://images.example.com/a.jpg",
              "thumbnail": "//external-content.duckduckgo.com/thumb.jpg",
              "url": "https://example.com/page",
              "width": 640,
              "height": 480
            },
            {
              "title": "Duplicate",
              "image": "https://images.example.com/a.jpg",
              "thumbnail": "https://example.com/other-thumb.jpg",
              "url": "https://example.com/page",
              "width": 640,
              "height": 480
            },
            {
              "title": "Unsafe",
              "image": "http://127.0.0.1/a.jpg",
              "thumbnail": "https://example.com/thumb.jpg",
              "url": "https://example.com/page",
              "width": 1,
              "height": 1
            }
          ]
        }
        """

        let results = try DuckDuckGoImageSearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == 1)
        #expect(results.first?.imageURL.absoluteString == "https://images.example.com/a.jpg")
        #expect(results.first?.thumbnailURL?.absoluteString == "https://external-content.duckduckgo.com/thumb.jpg")
        #expect(results.first?.sourceHost == "example.com")
        #expect(results.first?.dimensionsLabel == "640x480")
    }

    @Test func groupImageSheetUsesProfileImageURLPolicy() {
        #expect(GroupImageURLSheet.validatedImageURL("https://example.com/a.png")?.absoluteString == "https://example.com/a.png")
        #expect(GroupImageURLSheet.validatedImageURL("http://example.com/a.png") == nil)
        #expect(GroupImageURLSheet.validatedImageURL("https://localhost/a.png") == nil)
    }

    @Test func groupImageWebSearchUsesEphemeralNetworking() throws {
        let source = try groupImageURLSheetSource()

        #expect(source.contains("URLSessionConfiguration.ephemeral"))
        #expect(source.contains("httpCookieAcceptPolicy = .never"))
        #expect(source.contains("httpShouldSetCookies = false"))
        #expect(source.contains("requestCachePolicy = .reloadIgnoringLocalCacheData"))
        #expect(!source.contains("URLSession.shared"))
        #expect(!source.contains("AsyncImage(url: result.thumbnailURL ?? result.imageURL)"))
        #expect(source.contains("GroupImageRemoteThumbnail(url: result.thumbnailURL ?? result.imageURL)"))
        #expect(source.contains("Web search sends your query and IP address to DuckDuckGo and image hosts."))
    }

    @Test func groupImageThumbnailsCapBytesAndDownsampleDecode() throws {
        let source = try groupImageURLSheetSource()

        #expect(source.contains("static let maximumImageBytes = 2 * 1024 * 1024"))
        #expect(source.contains("session.bytes(for: request)"))
        #expect(source.contains("response.expectedContentLength > Int64(maximumImageBytes)"))
        #expect(source.contains("throw URLError(.dataLengthExceedsMaximum)"))
        #expect(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        #expect(source.contains("kCGImageSourceThumbnailMaxPixelSize"))
        #expect(!source.contains("UIImage(data: data)"))
    }

    @Test func groupDetailsSourceWiresAvatarMutationAndEditor() throws {
        let source = try String(contentsOf: groupDetailsSourceURL, encoding: .utf8)

        #expect(source.contains("onGroupChanged"))
        #expect(source.contains("refreshGroupManagementAndNotify"))
        #expect(source.contains("showGroupImageEditor"))
        #expect(source.contains("GroupImageURLSheet(initialURL: viewModel.group.avatarUrl)"))
        #expect(source.contains("updateGroupAvatarUrl"))
        #expect(source.contains(#"Label(viewModel.group.avatarUrl == nil ? "Set group image" : "Edit group image""#))
    }

    private var groupDetailsSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Group/GroupDetailsView.swift")
    }

    private var groupImageURLSheetSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Group/GroupImageURLSheet.swift")
    }

    private var remoteImageLoaderSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/RemoteImageLoader.swift")
    }

    private func groupImageURLSheetSource() throws -> String {
        try String(contentsOf: groupImageURLSheetSourceURL, encoding: .utf8)
            + "\n"
            + String(contentsOf: remoteImageLoaderSourceURL, encoding: .utf8)
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

        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: ""),
            initialOtherMember: other,
            initialMemberCount: 2
        )

        // The initial-member-count hint drives the 2-person title/subtitle before
        // the roster loads; with no known profile the title is the peer's npub.
        #expect(viewModel.displayTitle == appState.shortNpub(forAccountIdHex: other))
        #expect(viewModel.displaySubtitle == "2 members")
    }
}

@MainActor
struct AvatarBubbleTests {

    @Test func paletteIndexHandlesMinimumIntegerHash() {
        let index = AvatarBubble.paletteIndex(forHash: Int.min, paletteCount: 8)

        #expect((0..<8).contains(index))
    }

    @Test func paletteIndexMatchesAbsoluteRemainderForOrdinaryNegativeHashes() {
        #expect(AvatarBubble.paletteIndex(forHash: -9, paletteCount: 8) == 1)
        #expect(AvatarBubble.paletteIndex(forHash: 9, paletteCount: 8) == 1)
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

        let item = ChatsListViewModel.Item(row: unsafe, avatarURL: nil)

        #expect(item.previewText == "hello there")
    }

    @Test func itemAvatarURLUsesProjectedGroupAvatarURL() throws {
        let item = ChatsListViewModel.Item(
            row: chatListRow(groupIdHex: hex("d4"), title: "Avatar"),
            avatarURL: URL(string: "https://cdn.example.com/group.png")
        )

        #expect(item.avatarURL?.absoluteString == "https://cdn.example.com/group.png")
    }

    @Test func itemAvatarURLRejectsUnsafeProjectedGroupAvatarURL() throws {
        let item = ChatsListViewModel.Item(
            row: chatListRow(groupIdHex: hex("d5"), title: "Unsafe Avatar"),
            avatarURL: nil
        )

        #expect(item.avatarURL == nil)
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

    @Test func localGroupChangeUpdatesProjectedAvatarURL() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: hex("d6"), title: "General")
        viewModel.applyChatListSnapshot([row])

        viewModel.applyLocalGroupChange(group(
            name: "General",
            id: row.groupIdHex,
            avatarUrl: "https://cdn.example.com/group.png"
        ))

        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/group.png")
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

    @Test func chatListRowUpdatesAreCoalescedBeforePublishing() async throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let older = chatListRow(
            groupIdHex: hex("e1"),
            title: "Older",
            lastMessage: chatListPreview(messageIdHex: hex("f1"), plaintext: "older", timelineAt: 10),
            updatedAt: 10
        )
        let newer = chatListRow(
            groupIdHex: hex("e2"),
            title: "Newer",
            lastMessage: chatListPreview(messageIdHex: hex("f2"), plaintext: "newer", timelineAt: 20),
            updatedAt: 20
        )

        viewModel.applyChatListUpdate(.row(trigger: .newLastMessage, row: older))
        viewModel.applyChatListUpdate(.row(trigger: .newLastMessage, row: newer))

        #expect(viewModel.items.isEmpty)
        try await waitForExpectation { viewModel.items.count == 2 }
        #expect(viewModel.items.map(\.id) == [newer.groupIdHex, older.groupIdHex])
    }

    @Test func chatListViewModelKeepsIncrementalRowCaches() throws {
        let source = try String(contentsOf: chatsListViewModelSourceURL, encoding: .utf8)

        #expect(source.contains("private var rowByGroupId"))
        #expect(source.contains("private var itemByGroupId"))
        #expect(source.contains("private var pendingChatListRowsByGroupId"))
        #expect(source.contains("flushPendingChatListUpdates()"))
        #expect(!source.contains("private func recompute()"))
        #expect(!source.matches(#"private func scheduleAvatarURLRefresh[\s\S]*?avatarURLTask\?\.cancel\(\)"#))
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

    @Test func chatDestinationForwardsConversationGroupChangesToChatList() throws {
        let source = try String(contentsOf: chatsListViewSourceURL, encoding: .utf8)

        #expect(source.contains("onGroupChanged: { viewModel.applyLocalGroupChange($0) }"))
    }

    @Test func chatListUsesMessagesStyleSearchAndComposeChrome() throws {
        let source = try String(contentsOf: chatsListViewSourceURL, encoding: .utf8)

        #expect(source.contains(#".navigationTitle("Chats")"#))
        #expect(source.contains("private var chatSearchBar"))
        #expect(source.contains("bottomInputChromeAccessory"))
        #expect(source.contains("keyboardAdaptiveHorizontalPadding"))
        #expect(source.contains(".padding(.bottom, BottomInputChromeLayout.bottomInset)"))
        #expect(source.contains(#"TextField("", text: $searchText, onEditingChanged: { isEditing in"#))
        #expect(source.contains("searchPlaceholderColor"))
        #expect(!source.contains(#"Image(systemName: "mic.fill")"#))
        #expect(!source.contains(".searchDictationBehavior(.inline(activation: .onSelect))"))
        #expect(source.contains("private func focusSearchField()"))
        #expect(source.contains("simultaneousGesture(TapGesture().onEnded { focusSearchField() })"))
        #expect(source.contains("compatibleInputCapsuleChrome(interactive: false)"))
        #expect(source.contains("BottomInputChromeLayout.sideControlIconSize"))
        #expect(source.contains("keyboardAdaptiveBottomPadding()"))
        #expect(source.contains("bottomInputGlassContainer"))
        #expect(source.contains("private var searchCancellationActive: Bool"))
        #expect(source.contains("isKeyboardVisible || searchFocused || hasSearchText"))
        #expect(source.contains("private func dismissSearchKeyboard()"))
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
            placement: .window
        )

        #expect(viewModel.timeline.count == 3)
        #expect(viewModel.reactions(for: reply.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "👍", count: 2, mine: false)
        ])
        #expect(viewModel.isDeleted(deleted.messageIdHex))
        let replyRecord = try #require(viewModel.record(for: reply.messageIdHex))
        // The reply preview's resolved name now comes from the binding (covered by
        // ResolvedDisplayNameTests); here we assert the hydrated preview text.
        #expect(viewModel.replyPreview(for: replyRecord)?.text == "the parent text")
    }

    @Test func replyResponseStaysBelowParentWhenSameTimestampWouldSortByIdFirst() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let approve = timelineRecord(
            messageIdHex: hex("ff"),
            direction: "sent",
            sender: hex("22"),
            plaintext: "/approve",
            timelineAt: 1
        )
        let response = timelineRecord(
            messageIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "Command approved.",
            timelineAt: 1,
            replyToMessageIdHex: approve.messageIdHex,
            replyPreview: TimelineReplyPreviewFfi(
                messageIdHex: approve.messageIdHex,
                sender: approve.sender,
                plaintext: approve.plaintext,
                kind: MessageSemantics.kindChat,
                mediaJson: nil,
                agentTextStreamJson: nil,
                deleted: false
            )
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [response, approve], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let ids = viewModel.timeline.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
        #expect(ids == [approve.messageIdHex, response.messageIdHex])
    }

    @Test func liveReplyResponseStaysBelowParentWhenSameTimestampWouldInsertAbove() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let approve = timelineRecord(
            messageIdHex: hex("ff"),
            direction: "sent",
            sender: hex("22"),
            plaintext: "/approve",
            timelineAt: 1
        )
        let response = timelineRecord(
            messageIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "Command approved.",
            timelineAt: 1,
            replyToMessageIdHex: approve.messageIdHex
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [approve], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyTimelineSubscriptionUpdate(.projection(update: RuntimeProjectionUpdateFfi(
            accountIdHex: hex("22"),
            accountLabel: "account",
            update: TimelineProjectionUpdateFfi(
                groupIdHex: hex("aa"),
                messages: [],
                changes: [.upsert(trigger: .newMessage, message: response)],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            )
        )))

        let ids = viewModel.timeline.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
        #expect(ids == [approve.messageIdHex, response.messageIdHex])
    }

    @Test func normalizedReplyOrderingMovesNestedRepliesAfterParents() {
        let parent = timelineRecord(messageIdHex: hex("ff"), timelineAt: 1)
        let middle = timelineRecord(
            messageIdHex: hex("bb"),
            timelineAt: 1,
            replyToMessageIdHex: parent.messageIdHex
        )
        let leaf = timelineRecord(
            messageIdHex: hex("aa"),
            timelineAt: 1,
            replyToMessageIdHex: middle.messageIdHex
        )
        let unrelated = timelineRecord(messageIdHex: hex("cc"), timelineAt: 1)
        let targetById = [
            middle.messageIdHex: parent.messageIdHex,
            leaf.messageIdHex: middle.messageIdHex,
        ]
        let items = [leaf, middle, unrelated, parent].map {
            TimelineItem.message(ConversationViewModel.appMessageRecord(from: $0))
        }

        let ordered = ConversationViewModel.normalizedReplyOrdering(items) {
            targetById[$0.messageIdHex]
        }

        #expect(messageIds(in: ordered) == [
            unrelated.messageIdHex,
            parent.messageIdHex,
            middle.messageIdHex,
            leaf.messageIdHex,
        ])
    }

    @Test func normalizedReplyOrderingPreservesEarlySiblingReplyOrder() {
        let parent = timelineRecord(messageIdHex: hex("ff"), timelineAt: 1)
        let firstReply = timelineRecord(
            messageIdHex: hex("aa"),
            timelineAt: 1,
            replyToMessageIdHex: parent.messageIdHex
        )
        let secondReply = timelineRecord(
            messageIdHex: hex("bb"),
            timelineAt: 1,
            replyToMessageIdHex: parent.messageIdHex
        )
        let targetById = [
            firstReply.messageIdHex: parent.messageIdHex,
            secondReply.messageIdHex: parent.messageIdHex,
        ]
        let items = [firstReply, secondReply, parent].map {
            TimelineItem.message(ConversationViewModel.appMessageRecord(from: $0))
        }

        let ordered = ConversationViewModel.normalizedReplyOrdering(items) {
            targetById[$0.messageIdHex]
        }

        #expect(messageIds(in: ordered) == [
            parent.messageIdHex,
            firstReply.messageIdHex,
            secondReply.messageIdHex,
        ])
    }

    @Test func timelineWindowPageReplacesRowsOutsideAuthoritativeWindow() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let latest = timelineRecord(messageIdHex: hex("f2"), plaintext: "latest", timelineAt: 20)
        let older = timelineRecord(messageIdHex: hex("e1"), plaintext: "older", timelineAt: 10)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [latest], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [older], hasMoreBefore: false, hasMoreAfter: true),
            placement: .window
        )

        #expect(messageIds(in: viewModel.timeline) == [older.messageIdHex])
        #expect(viewModel.record(for: latest.messageIdHex) == nil)
        #expect(!viewModel.hasMoreBefore)
        #expect(viewModel.hasMoreAfter)
    }

    @Test func tailRefreshWhileDetachedOnlyUpdatesLoadedRows() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let loaded = timelineRecord(messageIdHex: hex("e1"), plaintext: "loaded", timelineAt: 10)
        let loadedWithReaction = timelineRecord(
            messageIdHex: loaded.messageIdHex,
            plaintext: loaded.plaintext,
            timelineAt: loaded.timelineAt,
            reactions: TimelineReactionSummaryFfi(
                byEmoji: [TimelineReactionEmojiFfi(emoji: "🔥", senders: [hex("33")])],
                userReactions: []
            )
        )
        let newHead = timelineRecord(messageIdHex: hex("f2"), plaintext: "new head", timelineAt: 20)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [loaded], hasMoreBefore: false, hasMoreAfter: true),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [loadedWithReaction, newHead], hasMoreBefore: true, hasMoreAfter: false),
            placement: .tailRefresh
        )

        #expect(messageIds(in: viewModel.timeline) == [loaded.messageIdHex])
        #expect(viewModel.reactions(for: loaded.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 1, mine: false)
        ])
        #expect(!viewModel.hasMoreBefore)
        #expect(viewModel.hasMoreAfter)
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
            placement: .window
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
            placement: .window
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

    @Test func multiChangeProjectionPublishesOneProjectionGeneration() throws {
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let existing = timelineRecord(
            messageIdHex: hex("a1"),
            groupIdHex: groupIdHex,
            plaintext: "existing",
            timelineAt: 10
        )
        let first = timelineRecord(
            messageIdHex: hex("b2"),
            groupIdHex: groupIdHex,
            plaintext: "first",
            timelineAt: 20
        )
        let second = timelineRecord(
            messageIdHex: hex("c3"),
            groupIdHex: groupIdHex,
            plaintext: "second",
            timelineAt: 30
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [existing], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let generationAfterPage = viewModel.timelineProjectionGeneration

        viewModel.applyTimelineSubscriptionUpdate(
            .projection(
                update: RuntimeProjectionUpdateFfi(
                    accountIdHex: hex("ff"),
                    accountLabel: "account-a",
                    update: TimelineProjectionUpdateFfi(
                        groupIdHex: groupIdHex,
                        messages: [],
                        changes: [
                            .upsert(trigger: .newMessage, message: first),
                            .upsert(trigger: .newMessage, message: second),
                        ],
                        chatListRow: nil,
                        chatListTrigger: .newLastMessage
                    )
                )
            )
        )

        #expect(viewModel.timelineProjectionGeneration == generationAfterPage + 1)
        #expect(messageIds(in: viewModel.timeline) == [
            existing.messageIdHex,
            first.messageIdHex,
            second.messageIdHex,
        ])
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

    @Test func projectedOutgoingMessageReplacesConfirmedTransientWithoutServerId() throws {
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
            plaintext: "confirmed without id",
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
        viewModel.confirmSent(tempId: "pending-1", record: pending, messageId: nil)
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
        #expect(source.contains("@ObservationIgnored private var replyTargetByMessageId"))
        #expect(source.contains("@ObservationIgnored private var pendingMediaByRowId"))
        #expect(source.contains("private(set) var timelineProjectionGeneration"))
        #expect(source.contains("let updateTimelineIncrementally = update.changes.count == 1"))
    }

    @Test func synchronousConversationMarmotReadsUseAsyncClientWrappers() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)
        let viewSource = try String(contentsOf: conversationViewSourceURL, encoding: .utf8)
        let clientSource = try String(contentsOf: marmotClientSourceURL, encoding: .utf8)

        #expect(source.contains("pendingReadMessageIds"))
        #expect(source.contains("flushPendingReadMarks(accountRef:"))
        #expect(source.contains("await client.markTimelineMessagesRead("))
        #expect(source.contains("try await client.initializeChatReadState("))
        #expect(source.contains("try await client.timelineMessages("))
        #expect(source.contains("try await client.listMedia("))
        #expect(source.contains("@ObservationIgnored private var timelineSubscription"))
        #expect(source.contains("SubscriptionDriver.timelineMessages(timelineSub)"))
        #expect(source.contains("timelineSubscription.paginateBackwards"))
        #expect(source.contains("timelineSubscription.paginateForwards"))
        #expect(source.contains("private(set) var hasMoreAfter"))
        #expect(viewSource.contains("newerTimelineTrigger(viewModel: viewModel)"))
        #expect(viewSource.contains("viewModel.loadNewerTimelinePage()"))
        #expect(!source.contains("appState.marmot.markTimelineMessageRead("))
        #expect(!source.contains("appState.marmot.initializeChatReadState("))
        #expect(!source.contains("appState.marmot.timelineMessages("))
        #expect(!source.contains("appState.marmot.listMedia("))
        #expect(clientSource.matches(#"func markTimelineMessagesRead[\s\S]*?Task\.detached\(priority: \.utility\)[\s\S]*?markTimelineMessageRead"#))
        #expect(clientSource.matches(#"func timelineMessages[\s\S]*?Task\.detached\(priority: \.utility\)[\s\S]*?timelineMessages"#))
        #expect(clientSource.matches(#"func listMedia[\s\S]*?Task\.detached\(priority: \.utility\)[\s\S]*?listMedia"#))
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

    private var marmotClientSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/MarmotClient.swift")
    }

    private func messageIds(in items: [TimelineItem]) -> [String] {
        items.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
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
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
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

    @Test func addMembersScannerRejectsCorruptNpubReferences() {
        let invalidNpub = "npub1abcdefghijklmnopqrstuvwxyz"

        #expect(NostrProfileReference.memberRef(fromReference: invalidNpub) == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: invalidNpub) == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: "nostr:\(invalidNpub)") == nil)
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "darkmatter://profile/\(invalidNpub)") == nil
        )
        #expect(DeepLink.parse(string: "nostr:\(invalidNpub)") == nil)
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

    @Test func addMembersPendingRecipientRejectsInvalidInputWithoutChangingMembers() {
        let existing = stagedMember(accountIdHex: hex("11"))
        let result = AddMembersPresentation.pendingMemberAddResult(
            "not a profile",
            existingMembers: [existing],
            normalize: { stagedMember(accountIdHex: $0) }
        )

        #expect(result == .invalid)
    }

    @Test func addMembersPendingRecipientAppendsValidInput() {
        let existing = stagedMember(accountIdHex: hex("11"))
        let candidate = stagedMember(accountIdHex: hex("22"))
        let result = AddMembersPresentation.pendingMemberAddResult(
            candidate.accountIdHex,
            existingMembers: [existing],
            normalize: { stagedMember(accountIdHex: $0) }
        )

        #expect(result == .added([existing, candidate], candidate))
    }

    @Test func stagedMembersFallBackToShortIdWithNpubSubtitle() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let account = hex("33")
        let member = stagedMember(accountIdHex: account)

        // With no known profile, the staged-member name falls back to the short
        // account id; the subtitle is the npub. (Name resolution from a profile
        // is covered by ResolvedDisplayNameTests.)
        #expect(AddMembersPresentation.displayName(for: member, appState: appState) == IdentityFormatter.short(account))
        #expect(AddMembersPresentation.secondaryIdentity(for: member).hasPrefix("npub1"))
    }

    private func stagedMember(accountIdHex: String) -> MemberRefFfi {
        MemberRefFfi(
            memberRef: accountIdHex,
            accountIdHex: accountIdHex,
            npub: "npub1abcdefghijklmnopqrstuvwxyz0123456789"
        )
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

    @Test func groupMlsRefreshGenerationTracksMembershipInputsOnly() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", admins: [me])
        )
        let initialGeneration = viewModel.groupMlsRefreshGeneration

        viewModel.applyGroupRecord(group(name: "Renamed", admins: [me]))

        #expect(viewModel.groupMlsRefreshGeneration == initialGeneration)

        viewModel.applyGroupRecord(group(name: "Renamed", admins: [me, other]))

        #expect(viewModel.groupMlsRefreshGeneration == initialGeneration + 1)

        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "Renamed", admins: [me, other]),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: false, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: true,
                    isLastAdmin: false,
                    canInvite: true,
                    canLeave: true,
                    requiresSelfDemoteBeforeLeave: false,
                    memberActions: []
                )
            )
        )

        #expect(viewModel.groupMlsRefreshGeneration == initialGeneration + 2)
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

        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [],
            trigger: .agentStreamStarted
        ) == streamId)
        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [streamId],
            trigger: .agentStreamStarted
        ) == nil)
        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [],
            trigger: nil
        ) == nil)
        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [],
            trigger: .snapshotRefresh
        ) == nil)
    }

    @Test func streamPreviewTimestampPrefersStartRecordTime() {
        #expect(ConversationViewModel.streamPreviewTimestamp(startedAt: 42, fallback: 99) == 42)
        #expect(ConversationViewModel.streamPreviewTimestamp(startedAt: 0, fallback: 99) == 99)
        #expect(ConversationViewModel.streamPreviewTimestamp(startedAt: nil, fallback: 99) == 99)
    }

    @Test func streamStartRecordedAtIsCarriedIntoLivePreview() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)

        #expect(source.contains("startedAt: record.recordedAt"))
        #expect(source.contains("streamStartedAtById[streamId] = startedAt"))
        #expect(source.contains("recordedAt: timestamp"))
        #expect(source.contains("receivedAt: timestamp"))
    }

    @Test func streamChunkAppendUsesRunningLengthCounter() throws {
        let source = try String(contentsOf: conversationViewModelSourceURL, encoding: .utf8)
        let appendPattern =
            #"private func appendStreamChunk\(_ text: String, to streamId: String\) \{[\s\S]*"#
            + #"let currentLength = streamTextLengthById\[streamId\][\s\S]*"#
            + #"ProfileSanitizer\.maxMessageLength - currentLength[\s\S]*"#
            + #"streamTextLengthById\[streamId\] = currentLength \+ cappedChunk\.count"#

        #expect(source.contains("private var streamTextLengthById: [String: Int] = [:]"))
        #expect(source.matches(appendPattern))
        #expect(!source.matches(#"private func appendStreamChunk[\s\S]*current\.count"#))
    }

    @MainActor
    @Test func historicalStreamStartsRenderNoBlankBubble() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let start = timelineRecord(
            messageIdHex: hex("cc"),
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: streamStartTags(streamId),
            timelineAt: 1,
            agentTextStreamJson: #"{"stream_id_hex":"\#(streamId)","status":"started"}"#
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [start], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.isEmpty)
    }

    @MainActor
    @Test func finalizedStreamProjectionRemovesSyntheticPreview() throws {
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
        let final = timelineRecord(
            messageIdHex: hex("ef"),
            sender: hex("11"),
            plaintext: "complete",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: [MessageSemantics.streamStartTag, hex("cc")]),
            ],
            timelineAt: 2,
            agentTextStreamJson: #"{"stream_id_hex":"\#(streamId)","status":"finalized","start_event_id":"\#(hex("cc"))"}"#
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [final], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.count == 1)
        #expect(viewModel.timeline.first?.id == "msg:\(hex("ef"))")
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected the finalized timeline message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "complete")
    }

    @MainActor
    @Test func fallbackChatUpdateDropsMatchingLivePreview() throws {
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
        let fallback = timelineRecord(
            messageIdHex: hex("ef"),
            sender: hex("11"),
            plaintext: "fallback complete",
            kind: MessageSemantics.kindChat,
            tags: [],
            timelineAt: 2
        )

        viewModel.applyTimelineSubscriptionUpdate(.projection(update: RuntimeProjectionUpdateFfi(
            accountIdHex: hex("22"),
            accountLabel: "account",
            update: TimelineProjectionUpdateFfi(
                groupIdHex: hex("aa"),
                messages: [],
                changes: [.upsert(trigger: .newMessage, message: fallback)],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            )
        )))

        #expect(viewModel.timeline.count == 1)
        #expect(viewModel.timeline.first?.id == "msg:\(hex("ef"))")
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected the fallback chat message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "fallback complete")
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
    @Test func streamStatusAndProgressDoNotChangePreviewText() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .status(seq: 1, status: "thinking")
        )
        #expect(viewModel.timeline.isEmpty)

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: "answer")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .progress(seq: 3, text: "searched 3 sources")
        )

        #expect(viewModel.timeline.count == 1)
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext == "answer")
    }

    @MainActor
    @Test func checkpointRecordReplacesPreviewText() throws {
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
            update: .record(seq: 2, recordType: 0x04, text: "replacement")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 3, text: " continued")
        )

        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext == "replacement continued")
    }

    @MainActor
    @Test func finishedUpdateKeepsCheckpointPreviewWhenBrokerTextIsDeltaOnly() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "hello")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .record(seq: 2, recordType: 0x04, text: "hello world")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .finished(text: "hello", transcriptHashHex: hex("55"), chunkCount: 2)
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 3, text: " late")
        )

        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a finalized stream message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "hello world")
    }

    private func streamStartTags(_ streamId: String) -> [MessageTagFfi] {
        [
            MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
            MessageTagFfi(values: ["stream-type", "text"]),
            MessageTagFfi(values: ["final-kind", "9"]),
            MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
        ]
    }

    private var conversationViewModelSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/ConversationViewModel.swift")
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
        #expect(viewModel.streamTextLengthEntryCountForTesting == 1)
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
        #expect(viewModel.streamTextEntryCountForTesting == 0)
        #expect(viewModel.streamTextLengthEntryCountForTesting == 0)
    }

    @MainActor
    @Test func normalMessageAfterFinishedStreamKeepsFinalizedTranscript() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let sender = hex("11")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: sender,
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: sender,
            update: .finished(text: "complete", transcriptHashHex: hex("55"), chunkCount: 1)
        )

        let nextMessage = timelineRecord(
            messageIdHex: hex("ef"),
            sender: sender,
            plaintext: "next message",
            kind: MessageSemantics.kindChat,
            tags: [],
            timelineAt: 2
        )
        viewModel.applyTimelineSubscriptionUpdate(.projection(update: RuntimeProjectionUpdateFfi(
            accountIdHex: hex("22"),
            accountLabel: "account",
            update: TimelineProjectionUpdateFfi(
                groupIdHex: hex("aa"),
                messages: [],
                changes: [.upsert(trigger: .newMessage, message: nextMessage)],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            )
        )))

        let ids = Set(viewModel.timeline.map(\.id))
        #expect(ids.contains("msg:stream:\(streamId)"))
        #expect(ids.contains("msg:\(hex("ef"))"))

        let streamItem = try #require(viewModel.timeline.first { $0.id == "msg:stream:\(streamId)" })
        guard case .message(let record, let status) = streamItem.kind else {
            Issue.record("Expected a finalized stream message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "complete")
    }

    @MainActor
    @Test func emptyFinishedUpdateDoesNotCreateBlankBubble() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .status(seq: 1, status: "thinking")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .progress(seq: 2, text: "tool started")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .finished(text: "", transcriptHashHex: hex("55"), chunkCount: 2)
        )

        #expect(viewModel.timeline.isEmpty)
    }

    @MainActor
    @Test func abortRecordDropsLivePreview() throws {
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
            update: .record(seq: 2, recordType: 0x05, text: "")
        )

        #expect(viewModel.timeline.isEmpty)
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
        let agentActivity = unsignedEventRecord(
            plaintext: #"{"v":1,"status":"thinking","text":"Thinking"}"#,
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["status", "thinking"])]
        )
        let agentOperation = unsignedEventRecord(
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","text":"Searching"}"#,
            kind: MessageSemantics.kindAgentOperation,
            tags: [MessageTagFfi(values: ["operation", "tool_call"])]
        )
        let groupSystem = unsignedEventRecord(
            plaintext: #"{"v":1,"system_type":"member_added","text":"Member added"}"#,
            kind: MessageSemantics.kindGroupSystem,
            tags: [MessageTagFfi(values: ["system", "member_added"])]
        )

        #expect(MessageSemantics.classify(reaction) == .reaction(targetMessageId: target))
        #expect(MessageSemantics.classify(deletion) == .delete(targetMessageId: target))
        #expect(MessageSemantics.classify(agentActivity) == .agentActivity)
        #expect(MessageSemantics.classify(agentOperation) == .agentOperation)
        #expect(MessageSemantics.classify(groupSystem) == .groupSystem)
        #expect(!MessagePreview.isPreviewable(reaction))
        #expect(!MessagePreview.isPreviewable(deletion))
        #expect(!MessagePreview.isPreviewable(streamStart))
        #expect(!MessagePreview.isPreviewable(agentActivity))
        #expect(!MessagePreview.isPreviewable(agentOperation))
        #expect(!MessagePreview.isPreviewable(groupSystem))
        #expect(MessagePreview.body(agentActivity) == "Thinking")
        #expect(MessagePreview.body(agentOperation) == "Searching")
        #expect(MessagePreview.body(groupSystem) == "Member added")
    }

    @Test func typedAgentReplyPreviewDoesNotExposeRawJson() {
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: hex("bb"),
            sender: hex("11"),
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","text":"Searching"}"#,
            kind: MessageSemantics.kindAgentOperation,
            mediaJson: nil,
            agentTextStreamJson: nil,
            deleted: false
        )

        #expect(MessagePreview.body(preview) == "Searching")
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

    @Test func mediaReferenceParsesEncryptedMediaV1ImetaFields() {
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
                    "v encrypted-media-v1",
                    "locator blossom-v1 https://media.example/a.png",
                    "ciphertext_sha256 \(hex("44"))",
                    "plaintext_sha256 \(hex("33"))",
                    "nonce \(nonce)",
                    "m image/png",
                    "filename a.png",
                    "dim 640x480",
                ])
            ],
            recordedAt: 1,
            receivedAt: 1
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false))
            return
        }

        #expect(info.count == 1)
        #expect(info[0].locators == [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/a.png")])
        #expect(info[0].mediaType == "image/png")
        #expect(info[0].fileName == "a.png")
        #expect(info[0].plaintextSha256 == hex("33"))
        #expect(info[0].ciphertextSha256 == hex("44"))
        #expect(info[0].nonceHex == nonce)
        #expect(info[0].version == "encrypted-media-v1")
        #expect(info[0].dim == "640x480")
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func mediaReferenceParsesMultipleEncryptedMediaAttachmentsInOrder() {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                encryptedMediaTag(fileName: "first.jpg", plaintextByte: "31", ciphertextByte: "41", nonce: nonce),
                encryptedMediaTag(fileName: "second.jpg", plaintextByte: "32", ciphertextByte: "42", nonce: nonce),
            ]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false))
            return
        }

        #expect(info.map(\.fileName) == ["first.jpg", "second.jpg"])
        #expect(MessagePreview.body(record) == "📎 2 attachments")
    }

    @Test func malformedMediaReferenceFallsBackToChat() {
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
                    "v encrypted-media-v1",
                    "locator blossom-v1 https://media.example/a.png",
                    "ciphertext_sha256 \(hex("44"))",
                    "plaintext_sha256 \(hex("33"))",
                    "m image/png",
                    "filename a.png",
                ])
            ],
            recordedAt: 1,
            receivedAt: 1
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func mediaReferenceRejectsLegacyMip04FieldsWithoutHidingMessage() {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
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
            ]
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func unsupportedBlurhashFieldDoesNotRejectValidMediaReference() throws {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false), "expected media")
            return
        }

        #expect(info.count == 1)
        #expect(info[0].fileName == "a.png")
    }

    @Test func validThumbhashIsPreserved() throws {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("thumbhash Abc123+/=_-")
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false), "expected media")
            return
        }

        #expect(info[0].thumbhash == "Abc123+/=_-")
    }

    @Test func invalidThumbhashFallsBackToChat() {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("thumbhash \(String(repeating: "x", count: 129))")
        let record = unsignedEventRecord(
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func mediaReferenceWithoutCaptionFallsBackToFileName() {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44", nonce: nonce)
            ]
        )

        #expect(MessagePreview.body(record) == "📎 a.png")
    }

    @MainActor
    @Test func mediaReferenceMatchingIgnoresOnlySourceEpoch() {
        let timelineReference = encryptedMediaReference(sourceEpoch: 0)
        let listedReference = encryptedMediaReference(sourceEpoch: 42)
        let differentCiphertext = encryptedMediaReference(ciphertextByte: "45", sourceEpoch: 42)

        #expect(ConversationViewModel.sameMediaAttachment(listedReference, timelineReference))
        #expect(!ConversationViewModel.sameMediaAttachment(differentCiphertext, timelineReference))
    }

    @MainActor
    @Test func mediaRecordReferenceLookupUsesIndexedNormalizedIdentity() throws {
        var timelineReference = encryptedMediaReference(sourceEpoch: 0)
        timelineReference.plaintextSha256 = timelineReference.plaintextSha256.uppercased()
        timelineReference.ciphertextSha256 = timelineReference.ciphertextSha256.uppercased()
        timelineReference.nonceHex = timelineReference.nonceHex.uppercased()
        let listedReference = encryptedMediaReference(sourceEpoch: 42)
        let messageId = hex("dd")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        viewModel.replaceMediaRecordsForTesting([
            messageId: [
                MediaRecordFfi(
                    messageIdHex: messageId,
                    attachmentIndex: 0,
                    direction: "received",
                    groupIdHex: hex("aa"),
                    sender: hex("11"),
                    reference: listedReference,
                    caption: nil,
                    recordedAt: 1,
                    receivedAt: 1
                )
            ]
        ])

        #expect(viewModel.mediaRecordReferenceIndexCountForTesting == 1)
        #expect(viewModel.mediaRecordReferenceForTesting(matching: timelineReference) == listedReference)
    }

    @Test func mediaDownloadInFlightKeyNormalizesCryptoIdentity() {
        var uppercase = encryptedMediaReference(sourceEpoch: 0)
        let lowercase = uppercase
        uppercase.plaintextSha256 = uppercase.plaintextSha256.uppercased()
        uppercase.ciphertextSha256 = uppercase.ciphertextSha256.uppercased()
        uppercase.nonceHex = uppercase.nonceHex.uppercased()

        #expect(MediaDownloadInFlightKey(reference: uppercase) == MediaDownloadInFlightKey(reference: lowercase))
    }

    @MainActor
    @Test func inFlightMediaDownloadsShareTaskForSameReference() async throws {
        let store = MediaDownloadInFlightStore()
        let key = MediaDownloadInFlightKey(reference: encryptedMediaReference(sourceEpoch: 0))
        let probe = MediaDownloadProbe()

        async let first = store.data(for: key) {
            await probe.run(returning: Data([1]))
        }
        async let second = store.data(for: key) {
            await probe.run(returning: Data([2]))
        }

        let results = try await (first, second)
        #expect(results.0 == results.1)
        #expect(await probe.startCount() == 1)
    }

    @MainActor
    @Test func inFlightMediaDownloadsClearCompletedTask() async throws {
        let store = MediaDownloadInFlightStore()
        let key = MediaDownloadInFlightKey(reference: encryptedMediaReference(sourceEpoch: 0))
        var starts = 0

        let first = try await store.data(for: key) {
            starts += 1
            return Data([UInt8(starts)])
        }
        let second = try await store.data(for: key) {
            starts += 1
            return Data([UInt8(starts)])
        }

        #expect(first == Data([1]))
        #expect(second == Data([2]))
        #expect(starts == 2)
    }

    @Test func mediaAttachmentIdentityChangesWhenSourceEpochArrives() throws {
        let timelineReference = encryptedMediaReference(sourceEpoch: 0)
        let listedReference = encryptedMediaReference(sourceEpoch: 42)

        let timelineItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [timelineReference],
                ownerId: "msg-a"
            ).first
        )
        let listedItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [listedReference],
                ownerId: "msg-a"
            ).first
        )

        #expect(timelineItem.id != listedItem.id)
        #expect(timelineItem.id.hasSuffix(":0:0"))
        #expect(listedItem.id.hasSuffix(":42:0"))
    }

    @Test func mediaAttachmentIdentityIncludesOwningMessage() throws {
        let reference = encryptedMediaReference(sourceEpoch: 0)

        let firstItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [reference],
                ownerId: "msg-a"
            ).first
        )
        let secondItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [reference],
                ownerId: "msg-b"
            ).first
        )

        #expect(firstItem.id != secondItem.id)
        #expect(firstItem.id.hasPrefix("msg-a:"))
        #expect(secondItem.id.hasPrefix("msg-b:"))
    }

    @Test func mediaCacheStoresPlaintextWithCompleteFileProtection() throws {
        let reference = encryptedMediaReference(
            plaintextByte: "7a",
            ciphertextByte: "7b",
            sourceEpoch: 0
        )
        let data = Data([0x01, 0x02, 0x03])
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(data, for: reference, cachesDirectory: cachesDirectory)

        #expect(try Data(contentsOf: url) == data)

        let source = try String(contentsOf: messageMediaAttachmentSourceURL, encoding: .utf8)
        #expect(source.contains(".protectionKey: FileProtectionType.complete"))
        #expect(source.contains("attributes: protectedAttributes"))
        #expect(source.contains("setAttributes(protectedAttributes, ofItemAtPath: directory.path)"))
        #expect(source.contains("data.write(to: url, options: [.atomic, .completeFileProtection])"))
        #expect(source.contains("setAttributes(protectedAttributes, ofItemAtPath: url.path)"))
    }

    @MainActor
    @Test func conversationDisplayBodyUsesMediaFileNameFallback() throws {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44", nonce: nonce)
            ]
        )
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )

        #expect(viewModel.displayBody(of: record) == "📎 a.png")
    }

    private var messageMediaAttachmentSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/MessageMediaAttachment.swift")
    }
}

@MainActor
struct MediaComposerAvailabilityTests {

    @Test func mediaComponentEnablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "media-ready")
        )

        #expect(viewModel.canSendMediaAttachments)
    }

    @Test func legacyGroupWithoutMediaComponentDisablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "legacy", encryptedMedia: legacyEncryptedMediaComponent())
        )

        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func attachmentButtonUsesDisabledAppearanceWhenMediaIsUnavailable() {
        let enabled = ComposerAttachmentButtonAppearance.mediaAvailability(true)
        let disabled = ComposerAttachmentButtonAppearance.mediaAvailability(false)

        #expect(enabled.iconTone == .primary)
        #expect(enabled.chromeInteractive)
        #expect(enabled.controlOpacity == 1)
        #expect(enabled.tapBehavior == .showOptions)
        #expect(disabled.iconTone == .disabled)
        #expect(!disabled.chromeInteractive)
        #expect(disabled.controlOpacity < enabled.controlOpacity)
        #expect(disabled.tapBehavior == .showUnavailableTooltip)
    }
}

struct MediaAttachmentPolicyTests {

    @Test func acceptsAudioVideoAndDocumentMediaTypes() {
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "audio/mp4"))
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "video/mp4"))
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "application/pdf"))
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "text/plain"))
        #expect(!MediaAttachmentPolicy.isSupported(mediaType: "application/x-msdownload"))
    }

    @Test func genericDraftPreservesNonImageBytesForUpload() throws {
        let data = Data("hello".utf8)
        let attachment = try MediaDraftProcessor.attachment(
            from: data,
            fileName: "note.txt",
            typeIdentifier: "public.plain-text"
        )

        #expect(attachment.fileName == "note.txt")
        #expect(attachment.mediaType == "text/plain")
        #expect(attachment.data == data)
        #expect(attachment.kind == .document)
    }

    @Test func voiceGestureOnlyLocksAfterSlideUpThreshold() {
        #expect(!VoiceRecordingGesturePolicy.shouldLock(translation: CGSize(width: 0, height: -40)))
        #expect(VoiceRecordingGesturePolicy.shouldLock(translation: CGSize(width: 0, height: -90)))
    }
}

struct AudioWaveformPresentationTests {

    @Test func liveRecordingStartsWithBlankWaveform() {
        let bars = AudioWaveformPresentation.bars(for: [], mode: .liveRecording, count: 5)

        #expect(bars.count == 5)
        #expect(bars.map(\.isVisible) == Array(repeating: false, count: 5))
    }

    @Test func liveRecordingAddsSamplesFromTrailingEdge() {
        let bars = AudioWaveformPresentation.bars(
            for: [0.2, 0.8],
            mode: .liveRecording,
            count: 5
        )

        #expect(bars.map(\.isVisible) == [false, false, false, true, true])
        #expect((bars[3].amplitude ?? 0) > 0.45)
        #expect((bars[4].amplitude ?? 0) > (bars[3].amplitude ?? 0))
    }

    @Test func liveRecordingKeepsNewestSamplesAfterWaveformFills() {
        let bars = AudioWaveformPresentation.bars(
            for: [0.1, 0.2, 0.3, 0.4],
            mode: .liveRecording,
            count: 3
        )

        #expect(bars.map(\.isVisible) == [true, true, true])
        #expect((bars[0].amplitude ?? 0) > 0.45)
        #expect((bars[1].amplitude ?? 0) > (bars[0].amplitude ?? 0))
        #expect((bars[2].amplitude ?? 0) > (bars[1].amplitude ?? 0))
    }

    @Test func playbackWaveformUsesSameAmplifiedCurveAsRecording() {
        let playbackBars = AudioWaveformPresentation.bars(for: [0.2, 0.8], mode: .playback, count: 2)
        let recordingBars = AudioWaveformPresentation.bars(for: [0.2, 0.8], mode: .liveRecording, count: 2)

        #expect(playbackBars.map(\.amplitude) == recordingBars.map(\.amplitude))
        #expect((playbackBars[0].amplitude ?? 0) > 0.45)
        #expect((playbackBars[1].amplitude ?? 0) > 0.9)
    }

    @Test func playbackWaveformStillFallsBackWhenSamplesAreMissing() {
        let bars = AudioWaveformPresentation.bars(for: [], mode: .playback, count: 5)

        #expect(bars.count == 5)
        #expect(bars.map(\.isVisible) == Array(repeating: true, count: 5))
    }
}

struct ComposerAudioDraftPreviewPresentationTests {

    @Test func sendButtonCentersWithoutBottomOffsetForAudioDrafts() {
        #expect(ComposerAudioDraftPreviewPresentation.sendButtonBottomPadding(hasAudioDraft: true) == 0)
        #expect(ComposerAudioDraftPreviewPresentation.sendButtonBottomPadding(hasAudioDraft: false) == 2)
    }

    @Test func sendButtonGetsStateSpecificVisualNudge() {
        #expect(ComposerAudioDraftPreviewPresentation.sendButtonOffset(hasAudioDraft: true) == CGSize(width: 3, height: 0))
        #expect(ComposerAudioDraftPreviewPresentation.sendButtonOffset(hasAudioDraft: false) == CGSize(width: 3, height: 1))
    }

    @Test func playbackIconReflectsPreviewState() {
        #expect(ComposerAudioDraftPreviewPresentation.playIconName(isPlaying: false, didFail: false) == "play.fill")
        #expect(ComposerAudioDraftPreviewPresentation.playIconName(isPlaying: true, didFail: false) == "pause.fill")
        #expect(ComposerAudioDraftPreviewPresentation.playIconName(isPlaying: false, didFail: true) == "arrow.clockwise")
    }

    @Test func durationLabelMatchesComposerPreviewFormat() {
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(nil) == "")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(2.9) == "0:02")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(65) == "1:05")
    }
}

struct ComposerMediaDraftPresentationTests {

    @Test func singleAudioDraftMovesIntoInlineComposerPreview() {
        let audio = draft(id: UUID(), mediaType: "audio/mp4")

        #expect(ComposerMediaDraftPresentation.inlineAudioDraft(in: [audio])?.id == audio.id)
        #expect(ComposerMediaDraftPresentation.stripAttachments(from: [audio]).isEmpty)
    }

    @Test func nonAudioDraftsStayInAttachmentStrip() {
        let image = draft(id: UUID(), mediaType: "image/jpeg")
        let document = draft(id: UUID(), mediaType: "application/pdf")

        #expect(ComposerMediaDraftPresentation.inlineAudioDraft(in: [image, document]) == nil)
        #expect(ComposerMediaDraftPresentation.stripAttachments(from: [image, document]).map(\.id) == [image.id, document.id])
    }

    @Test func mixedDraftsKeepOnlyAudioInComposerInput() {
        let image = draft(id: UUID(), mediaType: "image/jpeg")
        let audio = draft(id: UUID(), mediaType: "audio/mp4")

        #expect(ComposerMediaDraftPresentation.inlineAudioDraft(in: [image, audio])?.id == audio.id)
        #expect(ComposerMediaDraftPresentation.stripAttachments(from: [image, audio]).map(\.id) == [image.id])
    }

    private func draft(id: UUID, mediaType: String) -> MediaDraftAttachment {
        MediaDraftAttachment(
            id: id,
            fileName: "\(id.uuidString).bin",
            mediaType: mediaType,
            data: Data([0x01]),
            dim: nil,
            durationSeconds: mediaType.hasPrefix("audio/") ? 2.4 : nil,
            waveformSamples: mediaType.hasPrefix("audio/") ? [0.2, 0.8, 0.4] : []
        )
    }
}

struct PhotoLibrarySelectionOrderingTests {

    @Test func compactingLoadedSelectionsPreservesPickerOrder() {
        let first = PhotoLibrarySelection(data: Data([1]), fileName: "first.jpg")
        let second = PhotoLibrarySelection(data: Data([2]), fileName: "second.jpg")
        let third = PhotoLibrarySelection(data: Data([3]), fileName: "third.jpg")
        var slots = [PhotoLibrarySelection?](repeating: nil, count: 3)

        slots[2] = third
        slots[0] = first
        slots[1] = second

        let selections = PhotoLibrarySelection.compactPreservingPickerOrder(slots)

        #expect(selections.map(\.fileName) == ["first.jpg", "second.jpg", "third.jpg"])
    }

    @Test func compactingLoadedSelectionsDropsUnreadableSlotsWithoutReordering() {
        let first = PhotoLibrarySelection(data: Data([1]), fileName: "first.jpg")
        let third = PhotoLibrarySelection(data: Data([3]), fileName: "third.jpg")
        let selections = PhotoLibrarySelection.compactPreservingPickerOrder([first, nil, third])

        #expect(selections.map(\.fileName) == ["first.jpg", "third.jpg"])
    }
}

struct MessageMediaGridPresentationTests {

    @Test func gridShowsAtMostFourTilesAndCountsHiddenAttachments() {
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 4) == 4)
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 6) == 4)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 4) == 0)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 6) == 2)
    }

    @Test func gridUsesSingleTileOneRowOrTwoByTwoLayouts() {
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 2) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 2) == 1)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 3) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 3) == 2)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 10) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 10) == 2)
    }
}

struct MessageVideoBubblePresentationTests {

    @Test func landscapeVideoUsesActualAspectRatio() {
        let size = MessageVideoBubblePresentation.displaySize(maxWidth: 300, dim: "640x360")

        #expect(size.width == 300)
        #expect(size.height == 169)
    }

    @Test func portraitVideoNarrowsInsteadOfCropping() {
        let size = MessageVideoBubblePresentation.displaySize(maxWidth: 300, dim: "1080x1920")

        #expect(size.width == 228)
        #expect(size.height == 405)
    }

    @Test func missingVideoDimensionsUseLandscapeFallback() {
        let size = MessageVideoBubblePresentation.displaySize(maxWidth: 300, dim: nil)

        #expect(size.width == 300)
        #expect(size.height == 169)
    }

    @Test func fullscreenAffordanceUsesTouchableOverlaySize() {
        #expect(MessageVideoBubblePresentation.fullscreenButtonSize == 36)
        #expect(MessageVideoBubblePresentation.fullscreenButtonIconSize == 15)
        #expect(MessageVideoBubblePresentation.fullscreenButtonInset == 8)
    }

    @Test func thumbnailCacheKeySurvivesSourceEpochRefresh() {
        let initial = attachment(
            id: "row:\(hex("33")):0:0",
            reference: encryptedMediaReference(
                fileName: "clip.mp4",
                mediaType: "video/mp4",
                dim: "640x360",
                sourceEpoch: 0
            )
        )
        let refreshed = attachment(
            id: "row:\(hex("33")):42:0",
            reference: encryptedMediaReference(
                fileName: "clip.mp4",
                mediaType: "video/mp4",
                dim: "640x360",
                sourceEpoch: 42
            )
        )

        #expect(MessageVideoThumbnailPresentation.cacheKey(for: initial) == MessageVideoThumbnailPresentation.cacheKey(for: refreshed))
    }

    @Test func thumbnailCacheKeyFallsBackToItemIdForLocalVideo() {
        let local = attachment(id: "local-video", reference: nil)

        #expect(MessageVideoThumbnailPresentation.cacheKey(for: local) == "item:local-video")
    }

    private func attachment(
        id: String,
        reference: MediaAttachmentReferenceFfi?
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: reference,
            fileName: reference?.fileName ?? "local.mov",
            mediaType: reference?.mediaType ?? "video/quicktime",
            dim: reference?.dim,
            localData: nil
        )
    }
}

struct VideoPreviewOverlayPresentationTests {

    @Test func draftVideoPreviewUsesReadableCompactOverlay() {
        let diameter = VideoPreviewOverlayPresentation.diameter(for: CGSize(width: 68, height: 68))

        #expect(diameter == VideoPreviewOverlayPresentation.compactDiameter)
        #expect(VideoPreviewOverlayPresentation.iconFontSize(for: diameter) >= 19)
    }

    @Test func messageVideoPreviewUsesLargeCenteredOverlay() {
        let diameter = VideoPreviewOverlayPresentation.diameter(for: CGSize(width: 300, height: 169))

        #expect(diameter == VideoPreviewOverlayPresentation.regularDiameter)
    }

    @Test func veryLargeVideoPreviewCapsOverlayDiameter() {
        let diameter = VideoPreviewOverlayPresentation.diameter(for: CGSize(width: 600, height: 400))

        #expect(diameter == VideoPreviewOverlayPresentation.maximumDiameter)
    }
}

struct MessageAudioBubblePresentationTests {

    @Test func missingDurationDoesNotReserveLabelSpace() {
        #expect(MessageAudioBubblePresentation.durationLabel(nil) == nil)
    }

    @Test func durationLabelMatchesBubbleFormat() {
        #expect(MessageAudioBubblePresentation.durationLabel(2.9) == "0:02")
        #expect(MessageAudioBubblePresentation.durationLabel(65) == "1:05")
    }

    @Test func audioMetadataCacheKeySurvivesSourceEpochRefresh() {
        let initial = attachment(
            id: "row:\(hex("33")):0:0",
            reference: encryptedMediaReference(
                fileName: "voice.m4a",
                mediaType: "audio/mp4",
                dim: nil,
                sourceEpoch: 0
            )
        )
        let refreshed = attachment(
            id: "row:\(hex("33")):42:0",
            reference: encryptedMediaReference(
                fileName: "voice.m4a",
                mediaType: "audio/mp4",
                dim: nil,
                sourceEpoch: 42
            )
        )

        #expect(MessageAudioBubblePresentation.cacheKey(for: initial) == MessageAudioBubblePresentation.cacheKey(for: refreshed))
    }

    @Test func audioMetadataCacheKeyFallsBackToItemIdForLocalAudio() {
        let local = attachment(id: "local-audio", reference: nil)

        #expect(MessageAudioBubblePresentation.cacheKey(for: local) == "item:local-audio")
    }

    private func attachment(
        id: String,
        reference: MediaAttachmentReferenceFfi?
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: reference,
            fileName: reference?.fileName ?? "local.m4a",
            mediaType: reference?.mediaType ?? "audio/mp4",
            dim: reference?.dim,
            localData: nil
        )
    }
}

@MainActor
struct MessageMediaGalleryTests {

    @Test func galleryRejectsNonImageInitialItem() {
        let image = attachment(id: "image", mediaType: "image/png")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = MessageMediaGallery(
            items: [image, document],
            initialItem: document,
            initialImageData: Data()
        )

        #expect(gallery == nil)
    }

    @Test func galleryKeepsOnlyImagePagesWhenInitialImageIsInList() throws {
        let image = attachment(id: "image", mediaType: "image/png")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = try #require(MessageMediaGallery(
            items: [image, document],
            initialItem: image,
            initialImageData: imageData()
        ))

        #expect(gallery.items.map(\.id) == ["image"])
        #expect(gallery.initialItemID == "image")
    }

    @Test func galleryPrependsMissingImageInitialItem() throws {
        let initial = attachment(id: "initial", mediaType: "image/png")
        let otherImage = attachment(id: "other", mediaType: "image/jpeg")
        let document = attachment(id: "document", mediaType: "application/pdf")
        let data = imageData()

        let gallery = try #require(MessageMediaGallery(
            items: [document, otherImage],
            initialItem: initial,
            initialImageData: data
        ))

        #expect(gallery.items.map(\.id) == ["initial", "other"])
        #expect(gallery.initialData(for: initial) == data)
        #expect(gallery.initialData(for: otherImage) == nil)
    }

    @Test func fullscreenInitialDecodeFailureIsExplicit() {
        #expect(MessageMediaFullscreenPresentation.didFailInitialDecode(Data([0x00])))
        #expect(!MessageMediaFullscreenPresentation.didFailInitialDecode(nil))
        #expect(MessageMediaFullscreenPresentation.image(from: imageData()) != nil)
    }

    @Test func thumbnailCacheRetainsSourceDataForFullscreenReuse() async throws {
        let data = imageData()
        let itemID = "cache-warm-image-\(UUID().uuidString)"
        let decoded = try #require(await MessageMediaThumbnailDecoder.image(
            data: data,
            maxPixelSize: 32,
            scale: 1
        ))

        MessageMediaThumbnailDecoder.store(decoded, sourceData: data, for: itemID, maxPixelSize: 32)

        let cached = try #require(MessageMediaThumbnailDecoder.cachedThumbnail(for: itemID, maxPixelSize: 32))
        #expect(cached.sourceData == data)
        #expect(cached.image.size.width > 0)
    }

    private func attachment(
        id: String,
        mediaType: String,
        localData: Data? = nil
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: nil,
            fileName: "\(id).bin",
            mediaType: mediaType,
            dim: nil,
            localData: localData
        )
    }

    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}

@MainActor
struct MessageMediaThumbnailDecoderTests {

    @Test func decoderDownsamplesImageToPixelBudget() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        }

        let image = try #require(await MessageMediaThumbnailDecoder.image(
            data: data,
            maxPixelSize: 48,
            scale: 1
        ))
        let largestPixelEdge = max(image.size.width * image.scale, image.size.height * image.scale)

        #expect(largestPixelEdge <= 48)
    }

    @Test func videoDecoderExtractsAndCachesPreviewFrame() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageVideoThumbnail-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeTestVideo(to: url, size: CGSize(width: 96, height: 54))

        let image = try #require(await MessageVideoThumbnailDecoder.thumbnail(
            url: url,
            maxPixelSize: 48,
            scale: 1
        ))
        let largestPixelEdge = max(image.size.width * image.scale, image.size.height * image.scale)
        let itemID = "video-thumbnail-\(UUID().uuidString)"

        MessageVideoThumbnailDecoder.store(image, for: itemID, maxPixelSize: 48)
        let cached = try #require(MessageVideoThumbnailDecoder.cachedThumbnail(for: itemID, maxPixelSize: 48))

        #expect(largestPixelEdge <= 48)
        #expect(cached.size.width > 0)
    }

    private func writeTestVideo(to url: URL, size: CGSize) async throws {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw VideoThumbnailFixtureError.cannotAddInput
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.startWriting() else {
            throw writer.error ?? VideoThumbnailFixtureError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
        for _ in 0..<50 where !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard input.isReadyForMoreMediaData else {
            throw VideoThumbnailFixtureError.inputNotReady
        }
        let firstBuffer = try makePixelBuffer(
            adaptor: adaptor,
            width: width,
            height: height
        )
        guard adaptor.append(firstBuffer, withPresentationTime: .zero) else {
            throw writer.error ?? VideoThumbnailFixtureError.writerFailed
        }
        let secondBuffer = try makePixelBuffer(
            adaptor: adaptor,
            width: width,
            height: height
        )
        guard adaptor.append(secondBuffer, withPresentationTime: CMTime(value: 1, timescale: 30)) else {
            throw writer.error ?? VideoThumbnailFixtureError.writerFailed
        }
        input.markAsFinished()
        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? VideoThumbnailFixtureError.writerFailed)
                }
            }
        }
    }

    private func makePixelBuffer(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoThumbnailFixtureError.missingPixelBufferPool
        }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard let buffer = maybeBuffer else {
            throw VideoThumbnailFixtureError.missingPixelBuffer
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw VideoThumbnailFixtureError.missingContext
        }
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return buffer
    }

    private enum VideoThumbnailFixtureError: Error {
        case cannotAddInput
        case inputNotReady
        case missingContext
        case missingPixelBuffer
        case missingPixelBufferPool
        case writerFailed
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

    @Test func initialTimelineConcealsOnlyWhilePositioningCanRun() {
        #expect(TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: false,
            targetMessageIdHex: nil,
            targetItemId: nil
        ))
        #expect(!TimelineInitialScroll.shouldConcealContent(
            hasItems: false,
            didFinishInitialPositioning: false,
            targetMessageIdHex: nil,
            targetItemId: nil
        ))
        #expect(!TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: true,
            targetMessageIdHex: nil,
            targetItemId: nil
        ))
        #expect(TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: false,
            targetMessageIdHex: "message-target",
            targetItemId: "msg-target"
        ))
        #expect(!TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: false,
            targetMessageIdHex: "message-target",
            targetItemId: nil
        ))
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

    @Test func bottomDistanceAccountsForScrollContentInset() {
        let distance = TimelineBottom.distanceToBottom(
            contentHeight: 1_000,
            visibleBottomY: 1_000,
            bottomContentInset: 50
        )

        #expect(distance == 50)
        #expect(TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: distance))

        let insetAdjustedBottom = TimelineBottom.distanceToBottom(
            contentHeight: 1_000,
            visibleBottomY: 1_050,
            bottomContentInset: 50
        )
        #expect(insetAdjustedBottom == 0)
        #expect(!TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: insetAdjustedBottom))
    }

    @Test func bottomOverscrollDetectsViewportBelowLegalContentBottom() {
        let validBottom = TimelineBottomViewport(
            contentHeight: 1_000,
            visibleBottomY: 1_050,
            bottomContentInset: 50
        )
        let belowContent = TimelineBottomViewport(
            contentHeight: 1_000,
            visibleBottomY: 1_120,
            bottomContentInset: 50
        )

        #expect(validBottom.overscrollPastBottom == 0)
        #expect(!TimelineBottom.shouldRepairBottomOverscroll(validBottom))
        #expect(belowContent.overscrollPastBottom == 70)
        #expect(TimelineBottom.shouldRepairBottomOverscroll(belowContent))
    }

    @Test func pinnedContentGrowthKeepsTimelinePinned() {
        let previous = TimelineBottomViewport(
            contentHeight: 1_000,
            visibleBottomY: 995,
            bottomContentInset: 0
        )
        let current = TimelineBottomViewport(
            contentHeight: 1_080,
            visibleBottomY: 995,
            bottomContentInset: 0
        )

        #expect(previous.isPinned)
        #expect(!current.isPinned)
        #expect(TimelineBottom.shouldPreservePinAfterContentGrowth(previous: previous, current: current))
    }

    @Test func scrolledUpContentGrowthDoesNotForceTimelinePinned() {
        let previous = TimelineBottomViewport(
            contentHeight: 1_000,
            visibleBottomY: 800,
            bottomContentInset: 0
        )
        let current = TimelineBottomViewport(
            contentHeight: 1_080,
            visibleBottomY: 800,
            bottomContentInset: 0
        )

        #expect(!previous.isPinned)
        #expect(!TimelineBottom.shouldPreservePinAfterContentGrowth(previous: previous, current: current))
    }

    @Test func viewportChangesFollowOnlyWhenAlreadyPinned() {
        #expect(TimelineBottom.shouldFollowViewportChange(wasPinned: true))
        #expect(!TimelineBottom.shouldFollowViewportChange(wasPinned: false))
    }

    @Test func scrollButtonTapOptimisticallyPinsTimeline() {
        #expect(TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: false))
        #expect(TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: true))
    }

    @Test func bottomScrollRequestsCoalesceToLatestNonAnimatedTarget() {
        let timelineChange = TimelineBottomScrollRequest(
            animated: true,
            reason: .timelineChange,
            targetID: "message-a"
        )
        let viewportChange = TimelineBottomScrollRequest(
            animated: false,
            reason: .viewportChange,
            targetID: "message-b"
        )

        let result = TimelineBottomScrollCoordinator.coalesced(timelineChange, with: viewportChange)

        #expect(result.animated == false)
        #expect(result.reason == .viewportChange)
        #expect(result.targetID == "message-b")
    }

    @Test func userInitiatedBottomScrollWinsPendingAutomaticFollowUps() {
        let viewportChange = TimelineBottomScrollRequest(
            animated: false,
            reason: .viewportChange,
            targetID: "message-a"
        )
        let buttonTap = TimelineBottomScrollRequest(
            animated: true,
            reason: .buttonTap,
            targetID: "message-b"
        )

        let userWins = TimelineBottomScrollCoordinator.coalesced(viewportChange, with: buttonTap)
        let automaticDoesNotOverrideUser = TimelineBottomScrollCoordinator.coalesced(buttonTap, with: viewportChange)

        #expect(userWins.animated)
        #expect(userWins.reason == .buttonTap)
        #expect(userWins.targetID == "message-b")
        #expect(automaticDoesNotOverrideUser == buttonTap)
    }

    @Test func timelineScrollRequestsSkipAlreadyHandledTarget() {
        #expect(TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
            lastAutomaticTargetID: "message-a",
            nextTargetID: "message-a"
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
            lastAutomaticTargetID: "message-a",
            nextTargetID: "message-b"
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
            lastAutomaticTargetID: nil,
            nextTargetID: "message-a"
        ))
    }

    @Test func conversationViewCoalescesAutomaticScrollAndKeyboardFollowUps() throws {
        let source = try String(contentsOf: conversationViewSourceURL, encoding: .utf8)

        #expect(source.contains("@State private var pendingBottomScrollRequest"))
        #expect(source.contains("private func scheduleScrollToBottom"))
        #expect(source.contains("TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll"))
        #expect(source.contains("private func scheduleKeyboardDismiss"))
        #expect(source.contains("reason: .buttonTap"))
        #expect(source.contains("cancelPendingTimelineFollowUpWork()"))
        #expect(source.contains(".simultaneousGesture(TapGesture().onEnded { scheduleKeyboardDismiss() })"))
    }

    private var conversationViewSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/ConversationView.swift")
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

        #expect(source.matches(#"defer\s*\{[\s\S]{0,120}SensitiveClipboard\.clear\(trimmed\)"#))
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

func withAppLanguage<T>(_ language: AppLanguage, perform body: () throws -> T) rethrows -> T {
    let defaults = AppLanguage.defaults
    let previousValue = defaults.object(forKey: AppLanguage.storageKey)
    AppLanguage.setCurrentRawValue(language.rawValue)
    defer {
        if let previousValue {
            defaults.set(previousValue, forKey: AppLanguage.storageKey)
        } else {
            defaults.removeObject(forKey: AppLanguage.storageKey)
        }
    }
    return try body()
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
        deletedByMessageIdHex: deletedByMessageIdHex,
        invalidationStatus: nil
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

private func encryptedMediaTag(
    fileName: String,
    plaintextByte: String,
    ciphertextByte: String,
    nonce: String = String(repeating: "22", count: 12)
) -> MessageTagFfi {
    MessageTagFfi(values: [
        MessageSemantics.imetaTag,
        "v encrypted-media-v1",
        "locator blossom-v1 https://media.example/\(fileName)",
        "ciphertext_sha256 \(hex(ciphertextByte))",
        "plaintext_sha256 \(hex(plaintextByte))",
        "nonce \(nonce)",
        "m image/jpeg",
        "filename \(fileName)",
        "dim 640x480",
    ])
}

private func encryptedMediaReference(
    fileName: String = "a.jpg",
    plaintextByte: String = "33",
    ciphertextByte: String = "44",
    nonce: String = String(repeating: "22", count: 12),
    mediaType: String = "image/jpeg",
    dim: String? = "640x480",
    sourceEpoch: UInt64
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/\(fileName)")],
        ciphertextSha256: hex(ciphertextByte),
        plaintextSha256: hex(plaintextByte),
        nonceHex: nonce,
        fileName: fileName,
        mediaType: mediaType,
        version: MessageSemantics.encryptedMediaVersion,
        sourceEpoch: sourceEpoch,
        dim: dim,
        thumbhash: nil
    )
}

private actor MediaDownloadProbe {
    private var starts = 0

    func run(returning data: Data) async -> Data {
        starts += 1
        try? await Task.sleep(nanoseconds: 20_000_000)
        return data
    }

    func startCount() -> Int {
        starts
    }
}

private func encryptedMediaComponent() -> AppGroupEncryptedMediaComponentFfi {
    AppGroupEncryptedMediaComponentFfi(
        componentId: 0x8008,
        component: "marmot.group.encrypted-media.v1",
        required: true,
        mediaFormat: MessageSemantics.encryptedMediaVersion,
        allowedLocatorKinds: ["blossom-v1"],
        defaultBlobEndpoints: [
            AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
        ]
    )
}

private func legacyEncryptedMediaComponent() -> AppGroupEncryptedMediaComponentFfi {
    AppGroupEncryptedMediaComponentFfi(
        componentId: 0,
        component: "",
        required: false,
        mediaFormat: "",
        allowedLocatorKinds: [],
        defaultBlobEndpoints: []
    )
}

private func group(
    name: String,
    id: String = hex("aa"),
    admins: [String] = [],
    avatarUrl: String? = nil,
    archived: Bool = false,
    encryptedMedia: AppGroupEncryptedMediaComponentFfi = encryptedMediaComponent()
) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: id,
        endpoint: "",
        name: name,
        description: "",
        admins: admins,
        relays: [],
        nostrGroupIdHex: "",
        avatarUrl: avatarUrl,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: encryptedMedia,
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
    avatarUrl: String? = nil,
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
        avatarUrl: avatarUrl,
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

struct EmojiPickerPresentationTests {

    @Test func emojiPickerUsesStablePrecomputedOptions() {
        let options = EmojiPickerPresentation.options

        #expect(options.count == 50)
        #expect(Set(options.map(\.id)).count == options.count)
        #expect(options.first?.emoji == "👍")
        #expect(options.last?.emoji == "😆")
        #expect(EmojiPickerPresentation.columns.count == EmojiPickerPresentation.columnCount)
    }
}

private enum NotificationSubscriptionTestError: Error {
    case transient
}

private struct SensitiveNotificationSubscriptionError: LocalizedError {
    var errorDescription: String? {
        "relay failed at wss://relay.internal.invalid/path?token=secret"
    }
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

@MainActor
private func waitForExpectation(
    pollingIntervalNanoseconds: UInt64 = 5_000_000,
    attempts: Int = 100,
    _ predicate: () -> Bool
) async throws {
    for _ in 0..<attempts {
        if predicate() { return }
        try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
    }
    #expect(predicate())
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
