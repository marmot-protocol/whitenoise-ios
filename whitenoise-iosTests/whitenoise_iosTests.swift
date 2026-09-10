import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

private let notificationDefaultsTestGate = AsyncTestGate()

/// Smoke coverage for the iOS-side glue layer.
///
/// Full functional tests require running against a Nostr relay (handled by
/// `marmot-uniffi`'s Rust integration tests). These tests just exercise the
/// boundary between MarmotKit and the iOS code, plus pure-Swift helpers.
@MainActor
@Suite(.serialized)
struct AppStateBootstrapTests {

    private let accountDefaults = IsolatedAccountDefaults.make()

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

    @Test(.timeLimit(.minutes(1))) func erasurePreparationDrainsMaintenanceAndReleasesRootLease() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let client = try #require(appState.client)
        let root = URL(fileURLWithPath: client.rootPath, isDirectory: true)
        await appState.runtimeLifecycle.prepareForAppErasure()
        #expect(!appState.notificationSubscriptionActive)
        #expect(!appState.retentionSweeperIsActiveForTesting)
        for account in try await client.listAccounts() {
            try await client.marmot.removeAccount(accountRef: account.label)
        }
        #expect(try await client.listAccounts().isEmpty)
        try await appState.runtimeLifecycle.closeForAppErasure()
        #expect(appState.client == nil)
        try AppDataErasure.eraseClosedRuntime(at: root)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(remaining == [AppDataErasure.runtimeLockName])
    }

    @Test func interruptedImportStaysGatedWithoutRestoringSetup() async throws {
        let appState = try testAppState()
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        let summary = try await appState.importIdentity(
            "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn"
        )
        let setup = try #require(appState.pendingAccountSetup)
        #expect(setup.accountID == summary.accountIdHex)
        #expect(!setup.snapshot.ready)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.accounts.isEmpty)
        #expect(!appState.notificationSubscriptionActive)

        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
        #expect(appState.client == nil)
        appState.pendingAccountSetup = nil
        appState.setAppSceneActive(true)
        await appState.startForegroundActivation().value
        #expect(appState.pendingAccountSetup == nil)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.accountSetupSnapshots.contains { $0.accountIdHex == summary.accountIdHex })
        #expect(appState.accounts.isEmpty)
        #expect(!appState.notificationSubscriptionActive)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test func pendingSecondImportDoesNotActivateOverExistingAccount() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let active = appState.activeAccountRef
        _ = try await appState.importIdentity(
            "nsec12kcgs78l06p30jz7z7h3n2x2cy99nw2z6zspjdp7qc206887mwvs95lnkx"
        )
        try await appState.refreshAccounts(refreshUnreadSummaries: false)
        #expect(appState.pendingAccountSetup != nil)
        #expect(appState.activeAccountRef == active)
        #expect(appState.accounts.count == 1)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test func accountRefreshStartedBeforeImportCannotDiscardItsNewSetup() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let active = appState.activeAccountRef
        let maintenance = appState.beginForegroundMaintenanceCancellation()
        for task in maintenance.mutationFollowups { await task.value }
        let checkpoint = AsyncTestCheckpoint()
        defer { Task { await checkpoint.release() } }
        appState.beforeOnboardingSnapshotReadForTesting = { _ in await checkpoint.pause() }
        let refresh = Task { try await appState.refreshAccounts(refreshUnreadSummaries: false) }
        await checkpoint.waitUntilPaused()
        appState.beforeOnboardingSnapshotReadForTesting = nil
        _ = try await appState.importIdentity(
            "nsec12kcgs78l06p30jz7z7h3n2x2cy99nw2z6zspjdp7qc206887mwvs95lnkx"
        )
        let imported = try #require(appState.pendingAccountSetup)
        await checkpoint.release()
        try await refresh.value
        #expect(appState.pendingAccountSetup === imported)
        #expect(appState.activeAccountRef == active)
        #expect(appState.accounts.count == 1)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test func olderRefreshCannotDiscardSetupRestoredAfterFinishFailure() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let account = seeded.accounts[0]
        let maintenance = appState.beginForegroundMaintenanceCancellation()
        for task in maintenance.mutationFollowups { await task.value }
        let completed = OnboardingSnapshotFfi(
            accountIdHex: account.accountIdHex, recoveryEpoch: nil, revision: 1, ready: true, steps: [],
            proposal: nil, singleDeviceNotice: nil, cancellationPending: false
        )
        let model = AccountSetupModel(snapshot: completed)
        await model.connect(CompletedAccountSetupTestClient(snapshot: completed))
        for _ in 0..<1_000 where !model.canFinish { await Task.yield() }
        try #require(model.canFinish)
        appState.signInAttempts.begin(account.accountIdHex)
        appState.pendingAccountSetup = model
        let checkpoint = AsyncTestCheckpoint()
        defer { Task { await checkpoint.release() } }
        appState.beforeOnboardingSnapshotReadForTesting = { _ in
            await checkpoint.pause()
            throw CocoaError(.fileReadCorruptFile)
        }
        let refresh = Task { try await appState.refreshAccounts(refreshUnreadSummaries: false) }
        await checkpoint.waitUntilPaused()
        appState.beforeAccountRefreshForTesting = { throw CocoaError(.fileReadCorruptFile) }
        await appState.finishAccountSetup()
        try #require(appState.pendingAccountSetup === model)
        appState.beforeAccountRefreshForTesting = nil
        appState.beforeOnboardingSnapshotReadForTesting = nil
        await checkpoint.release()
        try await refresh.value
        #expect(appState.pendingAccountSetup === model)
        #expect(appState.activeAccountRef == account.label)
        #expect(appState.signInAttempts.accountIDs.contains(account.accountIdHex))
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test(arguments: [false, true])
    func foregroundAccountRefreshRetriesAndReleasesFailedRuntime(exhaustRetries: Bool) async throws {
        let appState = AppState(
            client: try MarmotClient.testClient(), notifications: deniedNotifications(),
            accountDefaults: accountDefaults, runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(delays: [.zero])
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
        let generation = appState.runtimeGeneration
        var attempts = 0
        var retainedClient: MarmotClient?
        appState.beforeAccountRefreshForTesting = {
            attempts += 1
            retainedClient = appState.client
            if exhaustRetries || attempts == 1 { throw MarmotKitError.StorageBusy(details: "test contention") }
        }
        await appState.startForegroundActivation().value
        #expect(attempts == 2)
        if exhaustRetries {
            #expect(appState.client == nil)
            if case .failed = appState.phase {} else { Issue.record("Expected a recoverable startup failure") }
            appState.beforeAccountRefreshForTesting = nil
            // Keep the failed handle alive: Retry must still be able to reopen its root.
            #expect(retainedClient != nil)
            await appState.bootstrap()
        }
        #expect(appState.phase == .onboarding)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration > generation)
        #expect(appState.client != nil)
        appState.beforeAccountRefreshForTesting = nil
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test(arguments: [
        MarmotKitError.Runtime(details: "test checkpoint"),
        .Io(details: "test checkpoint"), .StorageClosed(details: "test checkpoint"),
        .SecretNotFound(details: "test checkpoint"), .OnboardingActionUnavailable,
        .AccountSetupRecoveryRequired,
    ])
    func unreadableCheckpointOnlyGatesItsOwnIdentity(error: MarmotKitError) async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let healthy = seeded.accounts[0]
        let broken = try await appState.importIdentity(
            "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn"
        )
        appState.beforeOnboardingSnapshotReadForTesting = { accountID in
            if accountID == broken.accountIdHex { throw error }
        }
        try await appState.refreshAccounts(refreshUnreadSummaries: false)
        #expect(appState.accounts.map(\.accountIdHex) == [healthy.accountIdHex])
        #expect(appState.activeAccountRef == healthy.label)
        #expect(appState.pendingAccountSetup == nil)
        #expect(appState.accountSetupSnapshots.isEmpty)
        await appState.activateAccount(broken.label)
        #expect(appState.activeAccountRef == healthy.label)
        let durable = try await appState.client?.listAccounts()
        #expect(durable?.count == 2)

        // The failed read must not delete or reset the durable checkpoint.
        appState.beforeOnboardingSnapshotReadForTesting = nil
        try await appState.refreshAccounts(refreshUnreadSummaries: false)
        #expect(appState.pendingAccountSetup == nil)
        #expect(appState.accountSetupSnapshots.contains { $0.accountIdHex == broken.accountIdHex && !$0.ready })
        #expect(appState.accounts.map(\.accountIdHex) == [healthy.accountIdHex])
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test(arguments: [false, true])
    func unreadableCheckpointDoesNotBlockLaunchResumeSignInOrSetupCompletion(healthyAvailable: Bool) async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let original = seeded.appState
        let healthy = seeded.accounts[0]
        let broken = try await original.importIdentity(
            "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn"
        )
        let root = try #require(original.client?.rootPath)
        let relays = try #require(original.client?.relayUrls)
        original.setAppSceneActive(false)
        await original.startRuntimeSuspension().value
        accountDefaults.set(broken.label, forKey: AccountStore.activeAccountKey)
        let appState = AppState(
            client: try MarmotClient(rootPath: root, relayUrls: relays),
            notifications: deniedNotifications(), accountDefaults: accountDefaults
        )
        appState.beforeOnboardingSnapshotReadForTesting = { accountID in
            if !healthyAvailable || accountID == broken.accountIdHex {
                throw MarmotKitError.OnboardingActionUnavailable
            }
        }
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        #expect(appState.phase == (healthyAvailable ? .ready : .onboarding))
        #expect(appState.activeAccountRef == (healthyAvailable ? healthy.label : nil))
        #expect(appState.pendingAccountSetup == nil)
        #expect(appState.client != nil)

        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
        appState.setAppSceneActive(true)
        await appState.startForegroundActivation().value
        #expect(appState.phase == (healthyAvailable ? .ready : .onboarding))
        #expect(appState.activeAccountRef == (healthyAvailable ? healthy.label : nil))
        #expect(appState.canUseRuntimeForLocalForegroundWork)
        if !healthyAvailable {
            #expect(appState.accounts.isEmpty)
            #expect(appState.accountSetupSnapshots.isEmpty)
            appState.beforeOnboardingSnapshotReadForTesting = nil
            try await appState.refreshAccounts(refreshUnreadSummaries: false)
            #expect(appState.accounts.map(\.accountIdHex) == [healthy.accountIdHex])
            #expect(appState.pendingAccountSetup == nil)
            appState.setAppSceneActive(false)
            await appState.startRuntimeSuspension().value
            return
        }
        #expect(await appState.signOut())
        #expect(appState.accounts.first?.signedOut == true)
        await appState.activateAccount(healthy.label)
        #expect(appState.activeAccountRef == healthy.label)
        #expect(appState.accounts.first?.signedOut == false)

        // Model the completed checklist for a real, ready local identity.
        let completed = OnboardingSnapshotFfi(
            accountIdHex: healthy.accountIdHex, recoveryEpoch: nil, revision: 1, ready: true, steps: [],
            proposal: nil, singleDeviceNotice: nil, cancellationPending: false
        )
        let model = AccountSetupModel(snapshot: completed)
        await model.connect(CompletedAccountSetupTestClient(snapshot: completed))
        for _ in 0..<1_000 where !model.canFinish { await Task.yield() }
        #expect(model.canFinish)
        appState.activeAccountRef = nil
        appState.setPhase(.onboarding)
        appState.pendingAccountSetup = model
        await appState.finishAccountSetup()
        #expect(appState.phase == .ready)
        #expect(appState.activeAccountRef == healthy.label)
        #expect(appState.pendingAccountSetup == nil)
        #expect(model.errorMessage == nil)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test(arguments: [false, true])
    func unreadableIdentityCannotStaySelectedOrBeActivatedAfterSignIn(signIn: Bool) async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let account = seeded.accounts[0]
        if signIn { #expect(await appState.signOut()) }
        appState.beforeOnboardingSnapshotReadForTesting = { _ in
            throw MarmotKitError.Runtime(details: "test checkpoint")
        }
        if signIn {
            await appState.activateAccount(account.label)
        } else {
            try await appState.refreshAccounts(refreshUnreadSummaries: false)
        }
        #expect(appState.accounts.isEmpty)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.pendingAccountSetup == nil)
        #expect(appState.client != nil)
        #expect(RootPresentation.resolve(phase: appState.phase, activeAccountRef: nil) == (signIn ? .onboarding : .profileSelection))
        appState.beforeOnboardingSnapshotReadForTesting = nil
        try await appState.refreshAccounts(refreshUnreadSummaries: false)
        await appState.activateAccount(account.label)
        #expect(appState.activeAccountRef == account.label)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test(arguments: [
        MarmotKitError.RuntimeBusy,
        .StorageBusy(details: "test contention"), .KeystoreUnavailable(details: "test contention"),
    ])
    func transientCheckpointFailureStillRetriesAtLaunchAndResume(error: MarmotKitError) async throws {
        let appState = AppState(
            client: try MarmotClient.testClient(), notifications: deniedNotifications(),
            accountDefaults: accountDefaults, runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(delays: [.zero])
        )
        let client = try #require(appState.client)
        try await client.startRuntime()
        _ = try await client.marmot.createIdentityWithProfile(defaultRelays: client.relayUrls, bootstrapRelays: client.relayUrls)
        var attempts = 0
        appState.beforeOnboardingSnapshotReadForTesting = { _ in
            attempts += 1
            if attempts == 1 { throw error }
        }
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        #expect(attempts == 2)
        #expect(appState.phase == .ready)
        #expect(appState.accounts.count == 1)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
        attempts = 0
        appState.setAppSceneActive(true)
        await appState.startForegroundActivation().value
        #expect(attempts == 2)
        #expect(appState.phase == .ready)
        #expect(appState.accounts.count == 1)
        #expect(appState.canUseRuntimeForLocalForegroundWork)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test func cancelledCheckpointRefreshKeepsTheLastCompleteProjection() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let originalIDs = appState.accounts.map(\.accountIdHex)
        appState.beforeOnboardingSnapshotReadForTesting = { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await appState.refreshAccounts(refreshUnreadSummaries: false)
        }
        #expect(appState.accounts.map(\.accountIdHex) == originalIDs)
        #expect(appState.activeAccountRef == seeded.accounts[0].label)
        #expect(appState.pendingAccountSetup == nil)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test func refreshDoesNotSelectAnotherUnfinishedIdentity() async throws {
        let appState = try testAppState()
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        let first = try await appState.importIdentity(
            "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn"
        )
        let second = try await appState.importIdentity(
            "nsec12kcgs78l06p30jz7z7h3n2x2cy99nw2z6zspjdp7qc206887mwvs95lnkx"
        )
        let client = try #require(appState.client)
        try await client.marmot.removeAccount(accountRef: second.accountIdHex)
        try await appState.refreshAccounts(refreshUnreadSummaries: false)
        #expect(appState.pendingAccountSetup == nil)
        #expect(appState.accountSetupSnapshots.map(\.accountIdHex) == [first.accountIdHex])
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test func bootstrapWithoutAccountsClearsPersistedActiveAccountRef() async throws {
        accountDefaults.set("legacy-darkmatter-account", forKey: AccountStore.activeAccountKey)
        let appState = AppState(
            client: try MarmotClient.testClient(),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )

        await appState.bootstrap()

        #expect(appState.phase == .onboarding)
        #expect(appState.accounts.isEmpty)
        #expect(appState.activeAccountRef == nil)
        #expect(accountDefaults.string(forKey: AccountStore.activeAccountKey) == nil)
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

    @Test func coldBootstrapBecomesReadyBeforeUnreadSummaryRefreshCompletes() async throws {
        resetPersistedActiveAccountRef()
        var originalClient: MarmotClient? = try MarmotClient.testClient()
        let originalRootPath = originalClient!.rootPath
        let originalRelayUrls = originalClient!.relayUrls
        let original = AppState(
            client: originalClient!,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )
        await original.bootstrap()
        _ = try await original.createIdentity()
        await stopReadyRuntime(original)
        originalClient = nil

        let relaunched = AppState(
            client: try MarmotClient(
                rootPath: originalRootPath,
                relayUrls: originalRelayUrls
            ),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )
        relaunched.setAppSceneActive(true)
        let checkpoint = AsyncTestCheckpoint()
        relaunched.beforeUnreadSummaryRefreshForTesting = {
            await checkpoint.pause()
        }
        var splashReadySuccesses = 0
        var phaseWhenSplashReadyWasRecorded: AppState.Phase?
        relaunched.runtimeLifecycle.hostPerformanceObserverForTesting = { operation, _, outcome in
            if case .splashReady = operation, case .success = outcome {
                splashReadySuccesses += 1
                phaseWhenSplashReadyWasRecorded = relaunched.phase
            }
        }

        let bootstrap = Task { @MainActor in
            await relaunched.bootstrap()
        }
        await checkpoint.waitUntilPaused()

        #expect(relaunched.phase == .ready)
        #expect(!relaunched.accounts.isEmpty)
        #expect(splashReadySuccesses == 1)
        #expect(phaseWhenSplashReadyWasRecorded == .ready)

        await checkpoint.release()
        await bootstrap.value
        await relaunched.drainUnreadSummaryRefresh()
        #expect(splashReadySuccesses == 1)
        relaunched.beforeUnreadSummaryRefreshForTesting = nil
        relaunched.runtimeLifecycle.hostPerformanceObserverForTesting = nil
        await stopReadyRuntime(relaunched)
    }

    @Test func combinedUsageConsentPersistsWithoutChangingAuditOrRuntime() async throws {
        let appState = try testAppState()
        await appState.bootstrap()
        _ = try await appState.createIdentity()

        let generation = appState.runtimeGeneration
        let auditBefore = try await appState.auditLogSettings()

        let saved = try await appState.saveUsageDiagnosticsConsent(false)

        #expect(saved.settings.decision == .declined)
        #expect(try await appState.auditLogSettings() == auditBefore)
        #expect(appState.runtimeGeneration == generation)
        let maybeReloaded = try await appState.deviceDiagnosticsSnapshot()
        let reloaded = try #require(maybeReloaded)
        #expect(reloaded.settings.decision == .declined)

        await stopReadyRuntime(appState)
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

        await appState.startRuntimeSuspension().value

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

    @Test func profileSetupCreationDefersOnboardingCompletionUntilExplicitActivation() async throws {
        let appState = try testAppState()
        await appState.bootstrap()

        let creation = try await appState.createIdentityForProfileSetup()
        let summary = creation.account

        #expect(appState.phase == .onboarding)
        #expect(appState.activeAccount == nil)
        #expect(!appState.notificationSubscriptionActive)

        await appState.completeIdentityProfileSetup(summary)

        #expect(appState.phase == .ready)
        #expect(appState.activeAccount?.label == summary.label)
        #expect(appState.notificationSubscriptionActive)

        await stopReadyRuntime(appState)
    }

    @Test func identityActivationReturnsBeforeNotificationDefaultsFinish() async throws {
        let checkpoint = AsyncTestCheckpoint()
        let notifications = AppNotifications(
            requestAuthorizationHandler: {
                await checkpoint.pause()
                return false
            },
            authorizationStatusProvider: { .denied },
            remoteNotificationRegistrar: {}
        )
        let appState = try testAppState(notifications: notifications)
        await appState.bootstrap()
        let creation = try await appState.createIdentityForProfileSetup()
        let summary = creation.account

        await appState.completeIdentityProfileSetup(summary)

        #expect(appState.phase == .ready)
        #expect(appState.activeAccount?.label == summary.label)
        await checkpoint.waitUntilPaused()

        await checkpoint.release()
        await appState.drainRuntimeLifecycleTasksForTesting()
        await stopReadyRuntime(appState)
    }

    @Test func createIdentityPublishesEngineDefaultPseudonymProfile() async throws {
        let appState = try testAppState()
        await appState.bootstrap()

        let account = try await appState.createIdentity()
        let client = try appState.currentMarmotClient()
        let projections = await client.profileProjections(for: [
            ProfileProjectionRequest(accountIdHex: account.accountIdHex, localAccountLabel: nil)
        ])
        let projection = try #require(projections[account.accountIdHex])
        let profile = try #require(projection.profile)
        let name = try #require(profile.name)
        let displayName = try #require(profile.displayName)

        #expect(name == displayName)
        #expect(projection.projectedName == displayName)
        #expect(name.split(separator: " ").count == 2)
        #expect(name.range(of: #"^[A-Z][A-Za-z]+ [A-Z][A-Za-z]+$"#, options: .regularExpression) != nil)

        await stopReadyRuntime(appState)
    }

    @Test func createIdentityDefaultsNotificationsOnWhenPermissionIsGranted() async throws {
        try await notificationDefaultsTestGate.withLock {
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
            await appState.drainRuntimeLifecycleTasksForTesting()

            let maybeSettings = await appState.notificationSettings(for: account.label)
            let settings = try #require(maybeSettings)
            #expect(settings.localNotificationsEnabled)
            #expect(settings.nativePushEnabled)
            #expect(authorizationRequestCount == 1)
            #expect(remoteRegistrationRequestCount >= 1)

            let marmot = try #require(appState.client?.marmot)
            _ = try? marmot.setLocalNotificationsEnabled(accountRef: account.label, enabled: false)
            _ = try? await marmot.setNativePushEnabled(accountRef: account.label, enabled: false)
            _ = try? await marmot.clearPushRegistration(accountRef: account.label)
            await appState.signOut()
            await stopReadyRuntime(appState)
        }
    }

    @Test func createIdentityKeepsNotificationDefaultsOffWhenPermissionIsDenied() async throws {
        try await notificationDefaultsTestGate.withLock {
            var remoteRegistrationRequestCount = 0
            let notifications = deniedNotifications {
                remoteRegistrationRequestCount += 1
            }
            let appState = try testAppState(notifications: notifications)
            await appState.bootstrap()

            let account = try await appState.createIdentity()
            await appState.drainRuntimeLifecycleTasksForTesting()

            let maybeSettings = await appState.notificationSettings(for: account.label)
            let settings = try #require(maybeSettings)
            #expect(!settings.localNotificationsEnabled)
            #expect(!settings.nativePushEnabled)
            #expect(remoteRegistrationRequestCount == 0)
            #expect(appState.phase == .ready)

            await appState.signOut()
            await stopReadyRuntime(appState)
        }
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

        appState.stopNotificationSubscription()
        appState.reportNotificationSubscriptionError(sensitiveError)
        #expect(appState.activeToast?.id == firstToast.id)

        appState.startNotificationSubscription()
        appState.reportNotificationSubscriptionError(sensitiveError)
        #expect(appState.activeToast?.id == firstToast.id)
        appState.stopNotificationSubscription()

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
        #expect(ToastState.sleepNanoseconds(
            forDuration: TimeInterval(UInt64.max) / 1_000_000_000
        ) == UInt64.max)
        #expect(ToastState.sleepNanoseconds(forDuration: .greatestFiniteMagnitude) == UInt64.max)
    }

    @Test func routingIsBackedByFocusedNavigationState() async throws {
        let appState = try testAppState()
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "account-a", accountIdHex: hex("aa"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-b", accountIdHex: hex("bb"), localSigning: true, signedOut: false, running: true)
        ]
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

    @Test func deferredChatPresentationPublishesNavigationIntentImmediately() async throws {
        let appState = try testAppState()
        appState.accountStore.accounts = [
            AccountSummaryFfi(
                label: "account-a",
                accountIdHex: hex("aa"),
                localSigning: true,
                signedOut: false,
                running: true
            )
        ]
        appState.activeAccountRef = "account-a"

        DeferredChatPresentation.present(groupIdHex: "group-a", using: appState)

        #expect(appState.navigation.pendingChatId == "group-a")
    }

    @Test func routedChatIgnoresMissingOrSignedOutAccounts() async throws {
        let appState = try testAppState()
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "account-a", accountIdHex: hex("aa"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-b", accountIdHex: hex("bb"), localSigning: true, signedOut: true, running: false)
        ]
        appState.activeAccountRef = "account-a"

        appState.presentChat(groupIdHex: "group-stale", accountRef: "removed-account")

        #expect(appState.activeAccountRef == "account-a")
        #expect(appState.navigation.pendingChatId == nil)

        appState.presentChat(groupIdHex: "group-signed-out", accountRef: "account-b")

        #expect(appState.activeAccountRef == "account-a")
        #expect(appState.navigation.pendingChatId == nil)
    }

    @Test func notificationPresentationRuntimeGateRequiresForegroundRuntime() {
        #expect(NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: true,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: true,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: false
        ))
    }

    @Test func archivedNotificationCacheKeepsEntriesForInterleavedAccounts() {
        var cache = NotificationArchivedKeysCache()
        let now = ContinuousClock.now
        let lifetime: Duration = .seconds(2)
        cache.store(["group-a"], for: "account-a", readAt: now, lifetime: lifetime)
        cache.store(["group-b"], for: "account-b", readAt: now, lifetime: lifetime)

        #expect(cache.keys(for: "account-a", now: now, lifetime: lifetime) == ["group-a"])
        #expect(cache.keys(for: "account-b", now: now, lifetime: lifetime) == ["group-b"])
    }

    @Test func settingsReadRuntimeGateRejectsSuspensionWindows() {
        #expect(SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: true,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: false
        ))
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

    @Test func preBootstrapBackgroundSuspensionIsReleasedByForegroundReturn() async throws {
        let appState = try testAppState()

        let suspension = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspension.value
            suspensionCompleted = true
        }
        await Task.yield()

        #expect(!suspensionCompleted)

        let activation = appState.startForegroundActivation()
        await suspension.value
        await activation.value
        await observer.value

        #expect(suspensionCompleted)
        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == 0)
    }

    @Test func readyRuntimeSuspendsForBackgroundAndResumesForForeground() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        let generation = appState.runtimeGeneration
        await appState.startRuntimeSuspension().value

        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)
        // The runtime handle is released on suspension so its SQLite storage in
        // the shared App Group container is closed and its file lock freed
        // (otherwise iOS kills the app at suspension with 0xdead10cc). Don't
        // touch `marmot` here: the raw accessor deliberately traps while the
        // lifecycle-owned client is unavailable.
        #expect(appState.client == nil)

        await appState.startForegroundActivation().value

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation + 1)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(appState.client?.marmot.isStopping() == false)

        await stopReadyRuntime(appState)
    }

    @Test func suspendedRuntimeSettingsReadsDoNotRebuildRuntime() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let account = seeded.accounts[0]
        let generation = appState.runtimeGeneration

        await appState.startRuntimeSuspension().value

        let notificationSettings = await appState.notificationSettings(for: account.label)
        let pushRegistration = await appState.pushRegistration(for: account.label)
        let telemetrySettings = try await appState.deviceDiagnosticsSnapshot()
        let auditSettings = try await appState.auditLogSettings()
        let auditFiles = try await appState.auditLogFiles()
        let auditRows = try await appState.auditLogFileRows()
        let privacyProjection = try await appState.privacySecuritySettingsProjection()
        let optimisticMarkdown = await appState.parseMarkdown(text: "**hello**")
        let nativePushAccountRefs = await appState.notificationCoordinator
            .nativePushEnabledAccountRefsForTesting(host: appState)

        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)
        #expect(notificationSettings == nil)
        #expect(pushRegistration == nil)
        #expect(telemetrySettings == nil)
        #expect(auditSettings == nil)
        #expect(auditFiles == nil)
        #expect(auditRows == nil)
        #expect(privacyProjection == nil)
        #expect(optimisticMarkdown.blocks.isEmpty)
        #expect(!optimisticMarkdown.truncated)
        #expect(nativePushAccountRefs.isEmpty)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)

        await appState.startForegroundActivation().value
        await stopReadyRuntime(appState)
    }

    /// #338: `performBootstrap` starts the runtime (opening its SQLite store in
    /// the shared App Group container) before checking for accounts, so the app
    /// sits in `.onboarding` with a *live* runtime. The suspend/resume machinery
    /// was gated on `phase == .ready`, so backgrounding during onboarding left
    /// that runtime — and its App Group file lock — alive across suspension, the
    /// exact `0xdead10cc` condition the machinery exists to prevent. Suspension
    /// must now tear the onboarding runtime down (`client == nil`) and foreground
    /// resume must rebuild it, all while staying in `.onboarding` and without
    /// starting the account-scoped notification subscription.
    @Test func onboardingRuntimeSuspendsForBackgroundAndResumesForForeground() async throws {
        let appState = try testAppState()
        await appState.bootstrap()
        var catchUpAttempts = 0
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = {
            catchUpAttempts += 1
        }

        #expect(appState.phase == .onboarding)
        #expect(appState.accounts.isEmpty)
        #expect(appState.client != nil)
        #expect(!appState.notificationSubscriptionActive)
        let generation = appState.runtimeGeneration

        await appState.startRuntimeSuspension().value

        // The runtime handle is released even in onboarding so its SQLite
        // storage in the shared App Group container is closed and its file lock
        // freed. Don't touch `marmot` here: the raw accessor deliberately traps
        // until foreground lifecycle restoration completes.
        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)
        #expect(appState.runtimeGeneration == generation)
        #expect(appState.phase == .onboarding)

        await appState.startForegroundActivation().value

        // Foreground rebuilds the onboarding runtime but does not promote past
        // onboarding or start the notification subscription (no active account).
        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation + 1)
        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
        #expect(appState.client?.marmot.isStopping() == false)
        #expect(!appState.notificationSubscriptionActive)
        #expect(!appState.isRuntimeWarmingUp)
        await appState.notificationCoordinator.drainConnectivityCatchUpTaskForTesting()
        #expect(catchUpAttempts == 0)
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = nil

        await appState.startRuntimeSuspension().value
        resetPersistedActiveAccountRef()
    }

    /// #222: a rapid `.background` → `.active` transition starts a runtime
    /// suspension and a foreground activation that race. Previously the
    /// suspension tore the runtime down even though the scene had returned to
    /// active (the resume task it cancelled returned early), stranding the app
    /// foregrounded with `client == nil` and nothing to re-trigger resume.
    /// Driving both synchronous entry points back-to-back and draining the
    /// lifecycle tasks must leave a running runtime.
    @Test func backgroundThenForegroundRaceLeavesRuntimeRunning() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let generation = appState.runtimeGeneration

        // Interleave the entry points the way SwiftUI delivers a fast
        // background→foreground bounce: both run synchronously before either
        // task body executes.
        appState.startRuntimeSuspension()
        appState.startForegroundActivation()
        await appState.drainRuntimeLifecycleTasksForTesting()

        // Terminal state: foreground, runtime live, not suspended.
        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(appState.client?.marmot.isStopping() == false)
        // The runtime must be re-armed exactly once if it was suspended.
        #expect(appState.runtimeGeneration <= generation + 1)

        await stopReadyRuntime(appState)
    }

    /// #222 mirror: the foreground activation is delivered first and then a
    /// suspension races in. The suspension must observe that the scene is still
    /// active after cancelling foreground maintenance and decline to tear the
    /// runtime down (rescheduling a resume), again leaving a live runtime.
    @Test func foregroundThenBackgroundThenForegroundRaceLeavesRuntimeRunning() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        appState.startForegroundActivation()
        appState.startRuntimeSuspension()
        appState.startForegroundActivation()
        await appState.drainRuntimeLifecycleTasksForTesting()

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(appState.client?.marmot.isStopping() == false)

        await stopReadyRuntime(appState)
    }

    /// #545: an inactive→active bounce while foreground resume is rebuilding
    /// the runtime must share the in-flight activation. Starting a second
    /// activation before the first `startRuntime()` returns can double-open the
    /// App Group SQLite store, or let the cancelled task tear down the winner.
    @Test func inactiveActiveBounceDuringRuntimeRestartSharesInFlightForegroundActivation() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let generation = appState.runtimeGeneration

        await appState.startRuntimeSuspension().value

        let checkpoint = AsyncTestCheckpoint()
        var foregroundRuntimeCreateCount = 0
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = {
            foregroundRuntimeCreateCount += 1
            await checkpoint.pause()
        }

        let firstActivation = appState.startForegroundActivation()
        await checkpoint.waitUntilPaused()

        #expect(appState.client == nil)
        #expect(foregroundRuntimeCreateCount == 1)

        appState.setAppSceneActive(false)
        let secondActivation = appState.startForegroundActivation()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(foregroundRuntimeCreateCount == 1)

        await checkpoint.release()
        await firstActivation.value
        await secondActivation.value
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = nil

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(appState.runtimeGeneration == generation + 1)

        await stopReadyRuntime(appState)
    }

    /// Marmot signals command-readiness after local hydration and runs its
    /// initial relay sync asynchronously. Foreground catch-up must still run,
    /// but it cannot hold the whole conversation UI in "Connecting…".
    @Test func runtimeWarmupClearsBeforeForegroundCatchUpCompletes() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        await appState.startRuntimeSuspension().value

        let checkpoint = AsyncTestCheckpoint()
        var catchUpAttempts = 0
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = {
            catchUpAttempts += 1
            await checkpoint.pause()
        }
        var localReadySuccesses = 0
        var warmingUpWhenLocalReadyWasRecorded: Bool?
        appState.runtimeLifecycle.hostPerformanceObserverForTesting = { operation, _, outcome in
            if case .foregroundLocalReady = operation, case .success = outcome {
                localReadySuccesses += 1
                warmingUpWhenLocalReadyWasRecorded = appState.isRuntimeWarmingUp
            }
        }

        let activation = appState.startForegroundActivation()
        await checkpoint.waitUntilPaused()
        await activation.value

        #expect(!appState.isRuntimeWarmingUp)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.client != nil)
        #expect(catchUpAttempts == 1)
        #expect(appState.notificationCoordinator.hasConnectivityCatchUpTaskForTesting)
        #expect(appState.isConnectivityCatchUpInProgress)
        #expect(localReadySuccesses == 1)
        #expect(warmingUpWhenLocalReadyWasRecorded == false)

        await checkpoint.release()
        await appState.notificationCoordinator.drainConnectivityCatchUpTaskForTesting()
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = nil
        appState.runtimeLifecycle.hostPerformanceObserverForTesting = nil

        #expect(!appState.isRuntimeWarmingUp)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(!appState.isConnectivityCatchUpInProgress)
        #expect(localReadySuccesses == 1)

        await stopReadyRuntime(appState)
    }

    @Test func foregroundCatchUpFailureDoesNotFailOrReblockReadyRuntime() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        await appState.startRuntimeSuspension().value

        var catchUpAttempts = 0
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = {
            catchUpAttempts += 1
            throw ForegroundRuntimeMutationError.runtimeUnavailable
        }

        await appState.startForegroundActivation().value
        await appState.notificationCoordinator.drainConnectivityCatchUpTaskForTesting()
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = nil

        #expect(catchUpAttempts == 1)
        #expect(appState.phase == .ready)
        #expect(!appState.isRuntimeWarmingUp)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.client != nil)

        await stopReadyRuntime(appState)
    }

    @Test func connectivityRestoredWakesDurableRetriesBeforeCatchUp() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        var operations: [String] = []
        appState.notificationCoordinator.connectivityRestoredOperationForTesting = {
            operations.append("wake")
        }
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = {
            operations.append("catch-up")
        }

        appState.scheduleConnectivityCatchUp(connectivityRestored: true)
        await appState.notificationCoordinator.drainConnectivityCatchUpTaskForTesting()

        #expect(operations == ["wake", "catch-up"])
        appState.notificationCoordinator.connectivityRestoredOperationForTesting = nil
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = nil
        await stopReadyRuntime(appState)
    }

    @Test func staleForegroundActivationDoesNotScheduleCatchUpAfterBackgroundWins() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        await appState.startRuntimeSuspension().value

        let checkpoint = AsyncTestCheckpoint()
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = {
            await checkpoint.pause()
        }
        var catchUpAttempts = 0
        var localReadySamples = 0
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = {
            catchUpAttempts += 1
        }
        appState.runtimeLifecycle.hostPerformanceObserverForTesting = { operation, _, _ in
            if case .foregroundLocalReady = operation {
                localReadySamples += 1
            }
        }

        let activation = appState.startForegroundActivation()
        await checkpoint.waitUntilPaused()
        let suspension = appState.startRuntimeSuspension()

        await checkpoint.release()
        await activation.value
        await suspension.value
        await appState.notificationCoordinator.drainConnectivityCatchUpTaskForTesting()
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = nil
        appState.runtimeLifecycle.hostPerformanceObserverForTesting = nil
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = nil

        #expect(catchUpAttempts == 0)
        #expect(localReadySamples == 0)
        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)
        #expect(!appState.isRuntimeWarmingUp)

        resetPersistedActiveAccountRef()
    }

    /// #445: if the app is backgrounded while `performBootstrap` is still in
    /// flight, the runtime is already started but `phase` is still
    /// `.bootstrapping`, so a suspension that lands during bootstrap fails the
    /// `phaseOwnsLiveRuntime` guard and clears itself. Bootstrap then promotes to
    /// `.onboarding`, leaving a started runtime holding the shared App Group
    /// SQLite lock across suspension (the `0xdead10cc` watchdog-kill class).
    /// Bootstrap must keep that suspension chained through phase promotion (or
    /// re-arm it if no bootstrap task existed yet).
    @Test func backgroundSuspensionTaskWaitsForInFlightBootstrapBeforeEnding() async throws {
        let appState = try testAppState()
        let checkpoint = AsyncTestCheckpoint()

        appState.runtimeLifecycle.afterBootstrapRuntimeStartForTesting = {
            await checkpoint.pause()
        }
        let bootstrapTask = Task { @MainActor in
            await appState.bootstrap()
        }
        await checkpoint.waitUntilPaused()

        #expect(appState.phase == .bootstrapping)
        #expect(appState.client != nil)

        let suspensionTask = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspensionTask.value
            suspensionCompleted = true
        }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!suspensionCompleted)
        #expect(appState.phase == .bootstrapping)
        #expect(appState.client != nil)

        await checkpoint.release()
        await bootstrapTask.value
        await suspensionTask.value
        await observer.value

        #expect(suspensionCompleted)
        #expect(appState.phase == .onboarding)
        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)
        #expect(!appState.notificationSubscriptionActive)

        resetPersistedActiveAccountRef()
    }

    /// #743: UIKit owns the expiration deadline. Its callback must release the
    /// assertion immediately through the same idempotent helper as normal
    /// completion, even if Marmot teardown is still waiting elsewhere.
    @Test func backgroundTaskExpirationEndsAssertionExactlyOnce() async throws {
        let checkpoint = AsyncTestCheckpoint()
        let taskID = UIBackgroundTaskIdentifier(rawValue: 42)
        let suspensionTask = Task {
            await checkpoint.pause()
        }

        var capturedExpirationHandler: (() -> Void)?
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        var expirationCount = 0
        let backgroundTask = BackgroundRuntimeSuspensionTask(
            name: "Suspend Marmot runtime",
            onExpiration: {
                expirationCount += 1
            },
            beginBackgroundTask: { name, expirationHandler in
                #expect(name == "Suspend Marmot runtime")
                capturedExpirationHandler = expirationHandler
                return taskID
            },
            endBackgroundTask: { endedTaskID in
                endedTaskIDs.append(endedTaskID)
            }
        )
        backgroundTask.endWhenSuspensionCompletes(suspensionTask)
        await checkpoint.waitUntilPaused()

        capturedExpirationHandler?()
        try await waitForExpectation {
            expirationCount == 1 && endedTaskIDs == [taskID]
        }

        await checkpoint.release()
        await suspensionTask.value
        await Task.yield()

        #expect(endedTaskIDs == [taskID])
        #expect(expirationCount == 1)
    }

    /// A cancelled foreground task may not reach its cancellation point before
    /// UIKit expires the background assertion. Terminal storage closure must
    /// therefore happen before lifecycle cleanup waits for those tasks.
    @Test func backgroundSuspensionClosesStorageBeforeMaintenanceDrainCompletes() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let marmot = try #require(appState.client?.marmot)
        let checkpoint = AsyncTestCheckpoint()

        appState.beforeUnreadSummaryRefreshForTesting = {
            await checkpoint.pause()
        }
        appState.scheduleAccountUnreadSummaryRefresh()
        await checkpoint.waitUntilPaused()

        let suspensionTask = appState.startRuntimeSuspension()
        try await waitForExpectation {
            marmot.storageIsClosed()
        }
        #expect(appState.client == nil)

        await checkpoint.release()
        await suspensionTask.value
        #expect(appState.runtimeSuspendedForBackground)
        appState.beforeUnreadSummaryRefreshForTesting = nil

        await stopReadyRuntime(appState)
    }

    @Test func bootstrapRegistrationCompletesOriginalSuspensionInOnboarding() async throws {
        let appState = try testAppState()

        // The real background entry point lands before SwiftUI has registered
        // bootstrap. The covered suspension owner must remain alive rather than
        // bail and re-arm teardown outside its UIKit assertion (#592).
        let suspension = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspension.value
            suspensionCompleted = true
        }
        await Task.yield()
        #expect(!suspensionCompleted)

        await appState.bootstrap()
        await suspension.value
        await observer.value

        #expect(suspensionCompleted)
        #expect(appState.phase == .onboarding)
        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)
        #expect(!appState.notificationSubscriptionActive)

        resetPersistedActiveAccountRef()
    }

    @Test func bootstrapWhileOnlyInactiveDoesNotStartBackgroundSuspension() async throws {
        let appState = try testAppState()

        // `.inactive` only flips the scene-active gate; the actual teardown is
        // reserved for the `.background` entry point (`startRuntimeSuspension`).
        appState.setAppSceneActive(false)
        await appState.bootstrap()
        await appState.drainRuntimeLifecycleTasksForTesting()

        #expect(appState.phase == .onboarding)
        #expect(!appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.client != nil)

        await appState.startRuntimeSuspension().value
        resetPersistedActiveAccountRef()
    }

    /// #445 (ready variant): the same bootstrap↔background race for an app that
    /// resolves to `.ready` (accounts on disk). Bootstrap must re-arm suspension
    /// instead of starting `.ready`-only foreground maintenance and leaving the
    /// started runtime alive in the background.
    @Test func bootstrapRegistrationCompletesOriginalSuspensionWhenReady() async throws {
        // Seed an account on disk, then build a fresh AppState so the next
        // bootstrap starts from `.bootstrapping` and resolves to `.ready`.
        let seeded = try await readyAppStateWithCreatedIdentities()
        let seedRootPath = try #require(seeded.appState.client).rootPath
        let seedRelayUrls = try #require(seeded.appState.client).relayUrls
        await stopReadyRuntime(seeded.appState)
        let appState = AppState(
            client: try MarmotClient(rootPath: seedRootPath, relayUrls: seedRelayUrls),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )

        let suspension = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspension.value
            suspensionCompleted = true
        }
        await Task.yield()
        #expect(!suspensionCompleted)

        await appState.bootstrap()
        await suspension.value
        await observer.value

        #expect(suspensionCompleted)
        #expect(appState.phase == .ready)
        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)
        // Foreground-only maintenance must not have been left as the follow-up:
        // the subscription belongs to a live foreground `.ready` runtime.
        #expect(!appState.notificationSubscriptionActive)

        resetPersistedActiveAccountRef()
    }

    @Test func bootstrapRetryAfterSuspendedRuntimeClearsForegroundGates() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let generation = appState.runtimeGeneration

        await appState.startRuntimeSuspension().value
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

    /// A notification action arriving while the runtime is suspended must run
    /// on a lease-owned ephemeral frozen runtime, never the app's client slot:
    /// the durable slot stays suspended for the whole lease (no generation
    /// bump), and the frozen runtime is shut down when the action completes. A
    /// later foreground activation rebuilds a fresh durable client.
    @Test func notificationActionFromSuspensionUsesLeaseOwnedRuntimeAndLeavesSlotSuspended() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let generation = appState.runtimeGeneration

        await appState.startRuntimeSuspension().value
        #expect(appState.client == nil)

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()

        #expect(lease.ownsEphemeralRuntime)
        #expect(lease.client.cursorPersistence == .frozen)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)
        let accounts = try await lease.client.listAccounts()
        #expect(!accounts.isEmpty)
        #expect(appState.client == nil)

        // Notification actions refresh badges through the lease too. Calling
        // the ordinary runtime accessor is deliberately unavailable while the
        // app is still suspended.
        await appState.refreshAccountUnreadSummaries(using: lease.client)
        #expect(appState.client == nil)
        #expect(appState.runtimeGeneration == generation)

        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)

        #expect(!appState.isAppSceneActive)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)

        await appState.startForegroundActivation().value

        #expect(appState.client != nil)
        #expect(appState.client?.cursorPersistence == .advance)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation + 1)

        await stopReadyRuntime(appState)
    }

    /// A scene that activates mid-action must not adopt the lease's frozen
    /// runtime. The activation parks on the action's suspension claim, then
    /// resumes with a fresh durable runtime once the lease ends.
    @Test func foregroundActivationDuringNotificationActionHandsOffToFreshDurableRuntime() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        await appState.startRuntimeSuspension().value

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
        #expect(lease.ownsEphemeralRuntime)

        let activation = appState.startForegroundActivation()
        // Hand the MainActor to the activation so it runs to its first await —
        // `waitForRuntimeSuspensionToFinish` — and parks on the action's claim.
        // One yield suffices (the activation touches the client slot only after
        // that await), so the assertions below hold without a wall-clock delay.
        await Task.yield()

        // Still parked on the action's suspension claim: the durable slot must
        // not be rebuilt while the frozen lease runtime is live.
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)
        await activation.value
        await appState.drainRuntimeLifecycleTasksForTesting()

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.client != nil)
        #expect(appState.client?.cursorPersistence == .advance)

        await stopReadyRuntime(appState)
    }

    /// With a live foreground runtime, a notification action leases the
    /// durable client directly and builds nothing ephemeral. The scene must
    /// have reported a phase for the lease end to leave the runtime alone —
    /// otherwise this launch is indistinguishable from a cold UI-less one.
    @Test func notificationActionWithLiveRuntimeReusesDurableClient() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        appState.setAppSceneActive(true)

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()

        #expect(!lease.ownsEphemeralRuntime)
        #expect(lease.client === appState.client)
        #expect(lease.client.cursorPersistence == .advance)

        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)

        #expect(appState.client.map(ObjectIdentifier.init) == lease.clientIdentity)
        #expect(appState.phase == .ready)

        await stopReadyRuntime(appState)
    }

    /// A live notification-action lease can overlap the scene's background
    /// transition while its FFI call is suspended. Background teardown must
    /// wait for the lease instead of shutting down the same durable client.
    @Test func backgroundSuspensionWaitsForLiveNotificationActionLease() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        appState.setAppSceneActive(true)

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
        #expect(!lease.ownsEphemeralRuntime)
        #expect(lease.client === appState.client)
        #expect(appState.runtimeLifecycle.isRuntimeSuspendingNow)

        let suspension = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspension.value
            suspensionCompleted = true
        }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!suspensionCompleted)
        #expect(appState.client === lease.client)
        #expect(!appState.runtimeSuspendedForBackground)

        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)
        await suspension.value
        await observer.value

        #expect(suspensionCompleted)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await stopReadyRuntime(appState)
    }

    /// A generated Rust future may ignore Swift task cancellation. The action
    /// deadline must terminal-close the leased runtime and release background
    /// suspension without waiting for that operation to return.
    @Test func notificationActionDeadlineClosesLiveRuntimeAndReleasesSuspension() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        appState.setAppSceneActive(true)
        let marmot = try #require(appState.client?.marmot)
        let checkpoint = AsyncTestCheckpoint()
        let route = LocalNotificationRoute(
            accountRef: seeded.accounts[0].label,
            groupIdHex: "deadline-group",
            notificationKey: "deadline-notification",
            messageIdHex: "deadline-message"
        )

        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Action expired",
                deadline: .milliseconds(100)
            ) { _ in
                await checkpoint.pause()
                try Task.checkCancellation()
            }
        }
        await checkpoint.waitUntilPaused()

        let suspension = appState.startRuntimeSuspension()
        await action.value
        await suspension.value

        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)

        await checkpoint.release()
        await Task.yield()
        await stopReadyRuntime(appState)
    }

    /// A notification action on a cold UI-less launch (terminated app)
    /// bootstraps the durable runtime itself and no scene ever reports a
    /// phase, so nothing else suspends that runtime before iOS freezes the
    /// process with the App Group SQLite lock held (0xdead10cc). Ending the
    /// lease must suspend the runtime the action started.
    @Test func coldLaunchNotificationActionSuspendsBootstrappedRuntime() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        #expect(!appState.sceneHasReportedPhase)
        #expect(appState.client != nil)

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
        #expect(!lease.ownsEphemeralRuntime)

        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)

        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await stopReadyRuntime(appState)
    }

    /// The resume-tail badge refresh runs in its own task; suspension must
    /// drain it so no unread-summary FFI read is in flight when the runtime
    /// shuts down.
    @Test func suspensionDrainsScheduledUnreadSummaryRefresh() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        appState.scheduleAccountUnreadSummaryRefresh()
        #expect(appState.hasPendingUnreadSummaryRefreshForTesting)

        await appState.startRuntimeSuspension().value

        #expect(!appState.hasPendingUnreadSummaryRefreshForTesting)
        #expect(appState.client == nil)

        await stopReadyRuntime(appState)
    }

    @Test func liveChatListUnreadChangesSynchronizeApplicationBadge() async throws {
        var appliedBadgeCounts: [Int] = []
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .denied },
            remoteNotificationRegistrar: {},
            applicationBadgeCountSetter: { count in
                appliedBadgeCounts.append(count)
            }
        )
        let seeded = try await readyAppStateWithCreatedIdentities(
            accountCount: 1,
            notifications: notifications
        )
        let appState = seeded.appState
        await notifications.drainApplicationBadgeUpdates()
        appliedBadgeCounts.removeAll()

        appState.updateAccountUnreadSummary(
            accountIdHex: seeded.accounts[0].accountIdHex,
            chatListRows: [
                chatListRow(
                    groupIdHex: "unread-chat",
                    title: "Unread chat",
                    unreadCount: 4
                ),
            ]
        )
        await notifications.drainApplicationBadgeUpdates()
        #expect(appliedBadgeCounts.last == 4)

        appState.updateAccountUnreadSummary(
            accountIdHex: seeded.accounts[0].accountIdHex,
            chatListRows: [
                chatListRow(
                    groupIdHex: "unread-chat",
                    title: "Unread chat",
                    unreadCount: 4
                ),
                chatListRow(
                    groupIdHex: "manual-reminder",
                    title: "Manual reminder",
                    manuallyMarkedUnread: true
                ),
            ]
        )
        await notifications.drainApplicationBadgeUpdates()
        #expect(appliedBadgeCounts.last == 5)

        appState.updateAccountUnreadSummary(
            accountIdHex: seeded.accounts[0].accountIdHex,
            chatListRows: [
                chatListRow(
                    groupIdHex: "unread-chat",
                    title: "Unread chat",
                    unreadCount: 4
                ),
                chatListRow(
                    groupIdHex: "manual-reminder",
                    title: "Manual reminder",
                    manuallyMarkedUnread: true
                ),
                chatListRow(
                    groupIdHex: "pending-invite",
                    pendingConfirmation: true,
                    title: "Pending invite"
                ),
            ]
        )
        await notifications.drainApplicationBadgeUpdates()
        #expect(appliedBadgeCounts.last == 6)

        appState.updateAccountUnreadSummary(
            accountIdHex: seeded.accounts[0].accountIdHex,
            chatListRows: []
        )
        await notifications.drainApplicationBadgeUpdates()
        #expect(appliedBadgeCounts.last == 0)

        await stopReadyRuntime(appState)
    }

    @Test func suspensionClosesStorageBeforeForegroundMutationLeaseDrains() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let liveClient = try #require(appState.client)
        let marmot = liveClient.marmot
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()

        let suspension = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspension.value
            suspensionCompleted = true
        }

        try await waitForExpectation {
            marmot.storageIsClosed()
        }

        #expect(!suspensionCompleted)
        #expect(appState.client == nil)

        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        await suspension.value
        await observer.value

        #expect(suspensionCompleted)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        resetPersistedActiveAccountRef()
    }

    @Test func suspensionClosesStorageBeforeConnectivityCatchUpDrains() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let checkpoint = AsyncTestCheckpoint()

        await appState.startRuntimeSuspension().value
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = {
            await checkpoint.pause()
        }
        let activation = appState.startForegroundActivation()
        await checkpoint.waitUntilPaused()
        await activation.value
        let liveClient = try #require(appState.client)
        let marmot = liveClient.marmot

        let suspension = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspension.value
            suspensionCompleted = true
        }
        try await waitForExpectation {
            marmot.storageIsClosed()
        }

        #expect(!suspensionCompleted)
        #expect(appState.client == nil)

        await checkpoint.release()
        await suspension.value
        await observer.value
        appState.notificationCoordinator.foregroundCatchUpOperationForTesting = nil

        #expect(suspensionCompleted)
        #expect(appState.client == nil)

        resetPersistedActiveAccountRef()
    }

    @Test func suspendedRuntimeAccessAndForegroundMutationsFailWithoutRebuilding() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let generation = appState.runtimeGeneration

        await appState.startRuntimeSuspension().value

        #expect(!appState.canRefreshProfiles)
        #expect(throws: ForegroundRuntimeMutationError.self) {
            _ = try appState.currentMarmotClient()
        }
        await #expect(throws: ForegroundRuntimeMutationError.self) {
            _ = try await appState.createIdentity()
        }
        await #expect(throws: ForegroundRuntimeMutationError.self) {
            _ = try await appState.setAuditLogEnabled(true)
        }
        await #expect(throws: ForegroundRuntimeMutationError.self) {
            _ = try await appState.saveUsageDiagnosticsConsent(false)
        }

        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)

        resetPersistedActiveAccountRef()
    }

    /// A badge refresh with no leased client must never resurrect the durable
    /// runtime while it is suspended — that would strand a background `.advance`
    /// runtime holding the App Group SQLite lock (the notification-action lease
    /// exists precisely to avoid this). The refresh degrades to a no-op. This is
    /// the fleet-footed guard for the class of
    /// bug where background code reaches the plain runtime accessor: it can be
    /// driven without a relay, which the notification-action content operations
    /// (send / mark-read) would require.
    @Test func unreadSummaryRefreshWithoutLeaseNeverRebuildsSuspendedRuntime() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let generation = appState.runtimeGeneration

        await appState.startRuntimeSuspension().value
        #expect(appState.client == nil)

        await appState.refreshAccountUnreadSummaries()

        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)

        await stopReadyRuntime(appState)
    }

    @Test func groupRecoveryNoticesRespectAccountAndRuntimeOwnership() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let account = try #require(appState.activeAccount)
        let generation = try #require(appState.runtimeEventsGeneration)
        let event = MarmotEventFfi.groupChangeSuperseded(
            accountIdHex: account.accountIdHex, accountLabel: account.label,
            groupIdHex: "group", commitIdHex: "commit", kind: "invite",
            outcome: "reinvite_required", reason: "concurrent_change"
        )
        appState.dismissToast()
        appState.handleRuntimeEvent(event, generation: generation - 1)
        #expect(appState.activeToast == nil)
        appState.handleRuntimeEvent(.groupChangeSuperseded(
            accountIdHex: "unavailable-account", accountLabel: "private",
            groupIdHex: "group", commitIdHex: "commit", kind: "invite",
            outcome: "conflict", reason: "concurrent_change"
        ), generation: generation)
        #expect(appState.activeToast == nil)
        appState.handleRuntimeEvent(event, generation: generation)
        #expect(appState.activeToast?.style == .warning)
        appState.dismissToast()

        await appState.startRuntimeSuspension().value
        #expect(appState.runtimeEventsGeneration == nil)
        appState.handleRuntimeEvent(event, generation: generation)
        #expect(appState.activeToast == nil)
        await stopReadyRuntime(appState)
    }

    @Test func auditLogSettingChangeHotSwapsWithoutRestartingRuntime() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState

        let generation = appState.runtimeGeneration
        let telemetryBefore = try await appState.deviceDiagnosticsSnapshot()?.settings
        let settings = try await appState.setAuditLogEnabled(true)

        #expect(settings.enabled)
        let maybeReloadedSettings = try await appState.auditLogSettings()
        let reloadedSettings = try #require(maybeReloadedSettings)
        #expect(reloadedSettings.enabled)
        #expect(appState.runtimeGeneration == generation)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(appState.client?.marmot.isStopping() == false)

        let recordingFiles = try #require(try await appState.auditLogFiles())
        #expect(!recordingFiles.isEmpty)
        let disabled = try await appState.setAuditLogEnabled(false)
        #expect(!disabled.enabled)
        #expect(try await appState.auditLogSettings()?.enabled == false)
        let retainedFiles = try #require(try await appState.auditLogFiles())
        #expect(!retainedFiles.isEmpty)
        #expect(try await appState.deviceDiagnosticsSnapshot()?.settings == telemetryBefore)
        #expect(appState.runtimeGeneration == generation)

        await stopReadyRuntime(appState)
    }

    @Test func foregroundRuntimeWorkIsGatedDuringBackgroundSuspension() {
        #expect(ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: false
        ))

        #expect(ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true
        ))
    }

    @Test func chatListSubscriptionScopeChangesWhenSceneBecomesActive() {
        let inactive = ChatsListView.SubscriptionScope(
            accountRef: "account-a",
            runtimeGeneration: 4,
            isAppSceneActive: false
        )
        let active = ChatsListView.SubscriptionScope(
            accountRef: "account-a",
            runtimeGeneration: 4,
            isAppSceneActive: true
        )

        #expect(inactive != active)
    }

    @Test func profileFetchQueueLeavesQueuedIDsWhenRefreshBecomesUnavailable() async throws {
        let appState = try testAppState()
        let queued = [hex("11"), hex("22")]
        appState.profileStore.queuedProfileFetchIDs = queued
        appState.profileStore.scheduledProfileFetchIDs = Set(queued)
        appState.setAppSceneActive(false)

        await appState.runProfileFetchQueueForTesting()

        #expect(appState.profileStore.queuedProfileFetchIDs == queued)
        #expect(appState.profileStore.scheduledProfileFetchIDs == Set(queued))
        #expect(appState.profileStore.activeProfileFetchID == nil)
        #expect(appState.profileStore.profileFetchQueueTask == nil)
    }

    @Test func profileFetchQueueRearmsPreservedIDsWhenRefreshIsAllowed() async throws {
        let appState = try testAppState()
        let queued = [hex("33")]
        appState.profileStore.queuedProfileFetchIDs = queued
        appState.profileStore.scheduledProfileFetchIDs = Set(queued)

        appState.resumeProfileFetchQueueIfNeeded()
        let task = appState.cancelProfileFetchQueue()

        #expect(task != nil)
    }

    @Test func inactiveProfileMissQueuesHydrationUntilForegroundActivation() async throws {
        let appState = try testAppState()
        let accountIdHex = hex("34")
        appState.setAppSceneActive(false)

        #expect(appState.knownDisplayName(forAccountIdHex: accountIdHex) == nil)
        #expect(appState.profileStore.queuedProfileProjectionLoadIDs == [accountIdHex])
        #expect(appState.profileStore.scheduledProfileProjectionLoadIDs == [accountIdHex])
        #expect(appState.profileStore.profileProjectionRefreshAfterLoadIDs == [accountIdHex])
        #expect(appState.profileStore.profileProjectionLoadTask == nil)

        appState.setAppSceneActive(true)
        appState.resumeProfileFetchQueueIfNeeded()
        #expect(appState.cancelProfileFetchQueue() != nil)
    }

    @Test func cachedProjectionWithoutIdentityRequeuesRefreshWhileInactive() async throws {
        let appState = try testAppState()
        let accountIdHex = hex("35")
        appState.profileStore.profileProjectionCache[accountIdHex] = ProfileDisplayProjection(
            profile: nil,
            projectedName: nil,
            localAccountLabel: nil
        )
        appState.setAppSceneActive(false)

        #expect(appState.knownDisplayName(forAccountIdHex: accountIdHex) == nil)
        #expect(appState.profileStore.queuedProfileFetchIDs == [accountIdHex])
        #expect(appState.profileStore.scheduledProfileFetchIDs == [accountIdHex])
        #expect(appState.profileStore.profileFetchQueueTask == nil)
    }

    @Test func foregroundMaintenancePausePreservesPendingProfileWork() async throws {
        let appState = try testAppState()
        let loading = hex("36")
        let refreshing = hex("37")
        appState.profileStore.queuedProfileProjectionLoadIDs = [loading]
        appState.profileStore.scheduledProfileProjectionLoadIDs = [loading]
        appState.profileStore.profileProjectionRefreshAfterLoadIDs = [loading]
        appState.profileStore.queuedProfileFetchIDs = [refreshing]
        appState.profileStore.scheduledProfileFetchIDs = [refreshing]

        _ = appState.pauseProfileFetchQueue()

        #expect(appState.profileStore.queuedProfileProjectionLoadIDs == [loading])
        #expect(appState.profileStore.scheduledProfileProjectionLoadIDs == [loading])
        #expect(appState.profileStore.profileProjectionRefreshAfterLoadIDs == [loading])
        #expect(appState.profileStore.queuedProfileFetchIDs == [refreshing])
        #expect(appState.profileStore.scheduledProfileFetchIDs == [refreshing])
        #expect(appState.profileStore.profileProjectionCacheNeedsReloadOnResume)
    }

    @Test func staleProfileFetchQueueCompletionDoesNotClearNewerRunner() async throws {
        let appState = try testAppState()
        let oldTaskID = UUID()
        let newTaskID = UUID()
        let newTask = Task<Void, Never> {}

        appState.profileStore.profileFetchQueueTask = newTask
        appState.profileStore.profileFetchQueueTaskID = newTaskID
        appState.profileStore.activeProfileFetchID = hex("44")

        appState.profileStore.finishProfileFetchQueueForTesting(taskID: oldTaskID)

        #expect(appState.profileStore.profileFetchQueueTask != nil)
        #expect(appState.profileStore.profileFetchQueueTaskID == newTaskID)
        #expect(appState.profileStore.activeProfileFetchID == hex("44"))

        newTask.cancel()
    }

    @Test func staleProfileProjectionQueueCompletionDoesNotClearNewerRunner() async throws {
        let appState = try testAppState()
        let oldTaskID = UUID()
        let newTaskID = UUID()
        let newTask = Task<Void, Never> {}

        appState.profileStore.profileProjectionLoadTask = newTask
        appState.profileStore.profileProjectionLoadTaskID = newTaskID

        appState.profileStore.finishProfileProjectionLoadQueueForTesting(taskID: oldTaskID)

        #expect(appState.profileStore.profileProjectionLoadTask != nil)
        #expect(appState.profileStore.profileProjectionLoadTaskID == newTaskID)

        newTask.cancel()
    }

    @Test func cancelProfileFetchQueuePreservesProfileProjectionLoadVersions() async throws {
        // Regression for #353 (corrected per adversarial review of PR #357):
        // `cancelProfileFetchQueue()` runs on every background suspension (via
        // `cancelForegroundMaintenance`). A direct `reloadProfileProjection`
        // caller can be suspended at its `await` holding an already-captured
        // version token. If this method reset the whole version map, a later
        // load for the same id would restart the per-id counter and re-issue a
        // token that COLLIDES with the suspended caller's captured value (ABA),
        // letting stale data pass the staleness guard. So it must clear the
        // sibling queues (bounded to in-flight work) while PRESERVING the
        // monotonic version map. Eviction happens instead via post-load pruning
        // and full sign-out — covered by the tests below.
        let appState = try testAppState()
        appState.profileStore.queuedProfileProjectionLoadIDs = [hex("44")]
        appState.profileStore.scheduledProfileProjectionLoadIDs = [hex("44"), hex("55")]
        appState.profileStore.profileProjectionRefreshAfterLoadIDs = [hex("55")]
        appState.profileStore.profileProjectionLoadVersions = [hex("44"): 3, hex("55"): 1]

        _ = appState.cancelProfileFetchQueue()

        // Sibling queues are cleared...
        #expect(appState.profileStore.queuedProfileProjectionLoadIDs.isEmpty)
        #expect(appState.profileStore.scheduledProfileProjectionLoadIDs.isEmpty)
        #expect(appState.profileStore.profileProjectionRefreshAfterLoadIDs.isEmpty)
        // ...but the monotonic version map survives, so a suspended direct
        // reload's captured token cannot be reused by a re-bump after resume.
        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("44"): 3, hex("55"): 1])
    }

    @Test func settledProfileProjectionLoadPrunesItsVersionEntry() async throws {
        // After a guarded load completes for an id with no pending
        // queued/scheduled/refresh work, its version entry is evicted so the map
        // stays bounded to in-flight work rather than growing per distinct id
        // ever seen (#353).
        let appState = try testAppState()
        appState.profileStore.profileProjectionLoadVersions = [hex("66"): 7, hex("77"): 2]

        // id 66 settled at its current token, nothing pending -> evicted.
        appState.pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex: hex("66"), matching: 7)

        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("77"): 2])
    }

    @Test func prunePreservesVersionEntryWhenTokenSupersededOrWorkPending() async throws {
        // The prune must fail closed in exactly the cases that protect the
        // staleness guard's monotonic invariant (#353):
        //   (a) the stored token has been superseded by a newer load (the value
        //       no longer matches the settled token) -> keep the live token, and
        //   (b) queued/scheduled/refresh work still pending for the id -> keep
        //       the token a pending load will read.
        let appState = try testAppState()

        // (a) superseded token: a newer load bumped 88 from 4 to 5; an older
        // load settling with token 4 must NOT evict the live token 5.
        appState.profileStore.profileProjectionLoadVersions = [hex("88"): 5]
        appState.pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex: hex("88"), matching: 4)
        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("88"): 5])

        // (b) work still pending: matching token but the id is still queued.
        appState.profileStore.profileProjectionLoadVersions = [hex("99"): 1]
        appState.profileStore.queuedProfileProjectionLoadIDs = [hex("99")]
        appState.pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex: hex("99"), matching: 1)
        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("99"): 1])
    }

    @Test func destructiveWipeClearsProfileProjectionState() async throws {
        // A destructive wipe into onboarding is the one place a whole-map reset is
        // safe: with no active account `canRefreshProfiles` is false, so no
        // in-flight load can re-bump a token for the gone account ids or
        // repopulate the cache and race the reset. Signing out the last account
        // must reclaim accumulated cached projections (#366) and version entries
        // (#353).
        let seeded = try await readyAppStateWithCreatedIdentities(accountCount: 1)
        let appState = seeded.appState
        let account = seeded.accounts[0]
        appState.activeAccountRef = account.label
        appState.profileStore.profileProjectionCache = [
            hex("aa"): ProfileDisplayProjection(profile: nil, projectedName: "Previous peer", localAccountLabel: nil),
            account.accountIdHex: ProfileDisplayProjection(profile: nil, projectedName: nil, localAccountLabel: account.label),
        ]
        appState.profileStore.profileProjectionLoadVersions = [hex("aa"): 9, account.accountIdHex: 2]

        await appState.signOutAndWipeActiveAccount()

        #expect(appState.activeAccountRef == nil)
        #expect(appState.phase == .onboarding)
        #expect(appState.profileStore.profileProjectionCache.isEmpty)
        #expect(appState.profileStore.profileProjectionLoadVersions.isEmpty)
    }

    @Test func nonDestructiveSignOutPreservesRetainedAccountProjectionState() async throws {
        // A normal sign-out keeps the account and its local state available for
        // reactivation, including its cached local-account projection.
        let seeded = try await readyAppStateWithCreatedIdentities(accountCount: 2)
        let appState = seeded.appState
        let accountA = seeded.accounts[0]
        let accountB = seeded.accounts[1]
        let peerID = hex("aa")
        appState.activeAccountRef = accountA.label
        appState.profileStore.profileProjectionCache = [
            accountA.accountIdHex: ProfileDisplayProjection(
                profile: nil,
                projectedName: "Departed account",
                localAccountLabel: accountA.label
            ),
            accountB.accountIdHex: ProfileDisplayProjection(
                profile: nil,
                projectedName: "Remaining account",
                localAccountLabel: accountB.label
            ),
            peerID: ProfileDisplayProjection(profile: nil, projectedName: "Existing peer", localAccountLabel: nil),
        ]
        appState.profileStore.profileProjectionLoadVersions = [
            accountA.accountIdHex: 3,
            accountB.accountIdHex: 7,
        ]

        await appState.signOut()

        #expect(appState.activeAccountRef == nil)
        #expect(appState.accounts.contains { $0.label == accountB.label && !$0.signedOut })
        #expect(appState.phase == .ready)
        // A non-destructive sign-out keeps the retained accounts' projection
        // entries — `refreshAccounts()` re-warms the local accounts from fresh
        // state (so the seeded placeholder values are refreshed, not the point),
        // while unrelated peer projections persist untouched.
        #expect(appState.profileStore.profileProjectionCache[accountA.accountIdHex] != nil)
        #expect(appState.profileStore.profileProjectionCache[accountB.accountIdHex]?.localAccountLabel == accountB.label)
        #expect(appState.profileStore.profileProjectionCache[peerID]?.projectedName == "Existing peer")

        await stopReadyRuntime(appState)
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
        let marmot = try #require(appState.client?.marmot)
        _ = try await marmot.setNativePushEnabled(accountRef: accountA.label, enabled: true)
        let enabledSettings = await appState.notificationSettings(for: accountA.label)
        #expect(enabledSettings?.nativePushEnabled == true)

        await appState.signOut()

        let signedOutSettings = await appState.notificationSettings(for: accountA.label)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.accounts.contains { $0.label == accountB.label && !$0.signedOut })
        // Both accounts remain; their order comes from `listAccounts()`, which
        // makes no ordering guarantee, so compare membership, not sequence.
        #expect(Set(appState.accounts.map(\.label)) == Set([accountA.label, accountB.label]))
        #expect(appState.accounts.first(where: { $0.label == accountA.label })?.signedOut == true)
        #expect(signedOutSettings?.nativePushEnabled == false)
        // A remaining account means we stay in the main interface.
        #expect(appState.phase == .ready)

        await stopReadyRuntime(appState)
    }

    @Test func nativePushRegistrationScheduleGateBlocksDuringSignOut() {
        // Regression for issue #320: a system-driven APNS device-token callback
        // (`recordDeviceToken`) can land on one of `signOut()`'s `await`
        // suspension points and call `scheduleNativePushRegistrationIfEnabled()`.
        // While the departing account is still on disk (push enabled) and still
        // in the in-memory `accounts` list, that fresh sync would
        // re-`upsertPushRegistration` it — resurrecting a server-side push
        // registration for a signed-out account (residual of #7/#111). The
        // sign-out guard must suppress scheduling, exactly like the existing
        // scene-inactive / runtime-suspended guards.
        #expect(NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false
        ))
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: true
        ))
        // The pre-existing guards must keep blocking regardless of the new flag.
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false
        ))
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            isSigningOut: false
        ))
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            isSigningOut: false
        ))
    }

    /// Suspension closes storage before draining account exit. Sign-out and
    /// wipe must therefore keep one captured client across awaits; re-reading
    /// the former non-optional AppState handle here was a fatal-error race.
    @Test(arguments: [false, true])
    func accountExitUsesCapturedClientWhenSuspensionWins(_ destructive: Bool) async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        appState.activeAccountRef = seeded.accounts[0].label
        let checkpoint = AsyncTestCheckpoint()
        let marmot = try #require(appState.client?.marmot)

        appState.afterAccountExitClientCapturedForTesting = {
            await checkpoint.pause()
        }
        let accountExit = Task { @MainActor in
            if destructive {
                return await appState.signOutAndWipeActiveAccount()
            }
            return await appState.signOut()
        }
        await checkpoint.waitUntilPaused()

        let suspension = appState.startRuntimeSuspension()
        try await waitForExpectation {
            marmot.storageIsClosed() && appState.client == nil
        }
        await checkpoint.release()

        let succeeded = await accountExit.value
        await suspension.value
        appState.afterAccountExitClientCapturedForTesting = nil

        #expect(!succeeded)
        #expect(!appState.isSigningOutForTesting)
        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await stopReadyRuntime(appState)
    }

    @Test func signOutClearsSigningOutGuardBeforeReturning() async throws {
        // The sign-out guard (#320) must be raised only for the duration of the
        // teardown and cleared before `signOut()` returns. Otherwise the
        // legitimate post-sign-out reschedule for the surviving active account
        // — and every later token-driven reschedule — would stay suppressed.
        let seeded = try await readyAppStateWithCreatedIdentities(accountCount: 2)
        let appState = seeded.appState
        let accountA = seeded.accounts[0]
        let accountB = seeded.accounts[1]
        appState.activeAccountRef = accountA.label

        #expect(!appState.isSigningOutForTesting)

        await appState.signOut()

        // Guard down on return, surviving account active and intact.
        #expect(!appState.isSigningOutForTesting)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.accounts.contains { $0.label == accountB.label && !$0.signedOut })
        // A reschedule for the surviving account is now permitted (the guard no
        // longer suppresses it); calling it must not trap or re-raise the flag.
        appState.scheduleNativePushRegistrationIfEnabled()
        #expect(!appState.isSigningOutForTesting)

        await appState.drainRuntimeLifecycleTasksForTesting()
        await stopReadyRuntime(appState)
    }

    @Test func signOutOfOnlyAccountKeepsItAvailableForReactivation() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let only = seeded.accounts[0]
        appState.activeAccountRef = only.label
        appState.profileStore.profileProjectionCache = [
            hex("aa"): ProfileDisplayProjection(profile: nil, projectedName: "Previous peer", localAccountLabel: nil)
        ]
        appState.profileStore.profileProjectionLoadVersions = [hex("aa"): 9]

        await appState.signOut()

        let signedOutSettings = await appState.notificationSettings(for: only.label)
        #expect(appState.accounts.map(\.label) == [only.label])
        #expect(appState.accounts.first?.signedOut == true)
        #expect(appState.activeAccountRef == nil)
        #expect(signedOutSettings?.nativePushEnabled == false)
        // The prototype returns to Welcome when no signed-in profile remains.
        #expect(appState.phase == .onboarding)
        #expect(appState.profileStore.profileProjectionCache.isEmpty)
        #expect(appState.profileStore.profileProjectionLoadVersions.isEmpty)
        // Account-bound maintenance is stopped while every account is signed out.
        #expect(!appState.notificationSubscriptionActive)
        #expect(!appState.retentionSweeperIsActiveForTesting)

        await appState.activateAccount(only.label)

        #expect(appState.activeAccountRef == only.label)
        #expect(appState.accounts.first?.signedOut == false)
        // Reactivation must restart the maintenance the sign-out stopped;
        // nothing else (foreground resume, relaunch) heals it this session.
        #expect(appState.notificationSubscriptionActive)
        #expect(appState.retentionSweeperIsActiveForTesting)
        await stopReadyRuntime(appState)
    }

    @Test func newIdentityFromFullySignedOutShellRestartsForegroundMaintenance() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        appState.activeAccountRef = seeded.accounts[0].label

        await appState.signOut()

        #expect(appState.phase == .onboarding)
        #expect(!appState.notificationSubscriptionActive)
        #expect(!appState.retentionSweeperIsActiveForTesting)

        // Creating a fresh identity must restart the stopped maintenance loops.
        let fresh = try await appState.createIdentity()

        #expect(appState.activeAccountRef == fresh.label)
        #expect(appState.notificationSubscriptionActive)
        #expect(appState.retentionSweeperIsActiveForTesting)
        await stopReadyRuntime(appState)
    }

    @Test func accountSwitchBetweenSignedInAccountsKeepsSubscriptionRunning() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities(accountCount: 2)
        let appState = seeded.appState
        appState.activeAccountRef = seeded.accounts[0].label
        #expect(appState.notificationSubscriptionActive)

        await appState.activateAccount(seeded.accounts[1].label)

        #expect(appState.activeAccountRef == seeded.accounts[1].label)
        #expect(appState.notificationSubscriptionActive)
        #expect(appState.retentionSweeperIsActiveForTesting)
        await stopReadyRuntime(appState)
    }

    @Test func signOutOfOnlyAccountClearsPersistedActiveAccountRef() async throws {
        // Without this, the next launch reads the stale label from
        // UserDefaults and bootstrap points at an account that was removed
        // from local Marmot storage.
        resetPersistedActiveAccountRef()
        var client: MarmotClient? = try MarmotClient.testClient()
        let rootPath = client!.rootPath
        let relayUrls = client!.relayUrls
        let appState = AppState(
            client: client!,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )
        await appState.bootstrap()
        let only = try await appState.createIdentity()
        appState.activeAccountRef = only.label
        #expect(accountDefaults.string(forKey: AccountStore.activeAccountKey) == only.label)

        await appState.signOut()

        #expect(accountDefaults.string(forKey: AccountStore.activeAccountKey) == nil)
        await appState.startRuntimeSuspension().value
        client = nil
        let reborn = AppState(
            client: try MarmotClient(rootPath: rootPath, relayUrls: relayUrls),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )
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
                accountDefaults: accountDefaults,
                suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig
            )
        }
        return AppState(
            client: client,
            notifications: notifications ?? deniedNotifications(),
            accountDefaults: accountDefaults
        )
    }

    private func readyAppStateWithCreatedIdentities(
        accountCount: Int = 1,
        notifications: AppNotifications? = nil
    ) async throws -> (appState: AppState, accounts: [AccountSummaryFfi]) {
        let appState = try testAppState(notifications: notifications)
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        var accounts: [AccountSummaryFfi] = []
        for index in 0..<accountCount {
            let account = try await appState.createIdentity()
            accounts.append(account)
            if index + 1 < accountCount {
                // The production API now returns at local readiness. MDK
                // intentionally coalesces another generated-identity request
                // until this background publication finishes, so wait for its
                // local readiness projection before asking for an independent
                // second test account.
                try await waitForGeneratedAccountNetworkReadiness(
                    appState: appState,
                    accountRef: account.label
                )
            }
        }
        #expect(appState.phase == .ready)
        return (appState, accounts)
    }

    private func waitForGeneratedAccountNetworkReadiness(
        appState: AppState,
        accountRef: String
    ) async throws {
        let marmot = try #require(appState.client?.marmot)
        for _ in 0..<300 {
            switch try marmot.accountSetupReadiness(accountRef: accountRef) {
            case .networkReady:
                return
            case .recoveryRequired:
                throw MarmotKitError.AccountSetupRetryRequired
            case .initializing, .localReady, .publishing:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw MarmotKitError.AccountSetupRetryRequired
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
        await appState.startRuntimeSuspension().value
        resetPersistedActiveAccountRef()
    }

    private func resetPersistedActiveAccountRef() {
        accountDefaults.removeObject(forKey: AccountStore.activeAccountKey)
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

    @MainActor
    @Test func stoppedDriverReturnsItsInFlightTaskForLifecycleDrain() async throws {
        let driver = NotificationDriver()
        let checkpoint = AsyncTestCheckpoint()
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: 1,
            maximumRetryDelayNanoseconds: 8,
            subscribe: {
                await checkpoint.pause()
                return AsyncStream { continuation in continuation.finish() }
            },
            present: { _ in },
            reportError: { _ in }
        )

        driver.start(runner: runner)
        await checkpoint.waitUntilPaused()

        let taskToDrain = try #require(driver.stop())
        var drained = false
        let observer = Task { @MainActor in
            await taskToDrain.value
            drained = true
        }
        await Task.yield()
        #expect(!drained)

        await checkpoint.release()
        await observer.value

        #expect(drained)
        #expect(!driver.isRunning)
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

    @Test func idleSubscriptionDoesNotResetBackoffAfterFailures() async throws {
        let probe = NotificationSubscriptionProbe(attempts: [
            .failure,
            .failure,
            .updates([]),
            .updates([notificationUpdate(notificationKey: "notif-idle-reset")])
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
        #expect(snapshot.subscribeAttempts == 4)
        #expect(snapshot.presentedNotificationKeys == ["notif-idle-reset"])
        #expect(snapshot.errorCount == 2)
        #expect(snapshot.sleepDelays == [1, 2, 4, 1])
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
            "WhiteNoiseTelemetryOTLPEndpoint": "$(WHITENOISE_OTLP_ENDPOINT)",
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "",
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
            "WhiteNoiseTelemetryOTLPEndpoint": "$(WHITENOISE_OTLP_ENDPOINT)",
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "$(WHITENOISE_TELEMETRY_ENVIRONMENT)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "WHITENOISE_OTLP_ENDPOINT": "https://collector.example/v1/metrics",
            "OTLP_TOKEN_WHITENOISE_IOS": "env-token",
            "WHITENOISE_TELEMETRY_ENVIRONMENT": "production"
        ])

        #expect(config.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(config.bearerToken == "env-token")
        #expect(config.telemetryCredentialsAvailable)
        #expect(config.deploymentEnvironment == "production")
    }

    @Test func productionEnvironmentMustBeExplicitlyConfigured() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryOTLPEndpoint": "https://collector.example/v1/metrics",
            "WhiteNoiseTelemetryBearerToken": "secret-token",
            "WhiteNoiseTelemetryEnvironment": "production",
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
        #expect(runtime.resource?.tenant == "whitenoise-ios")
        #expect(runtime.resource?.osType == "darwin")
        #expect(runtime.resource?.osVersion == "26.0")
        #expect(runtime.resource?.deviceModelIdentifier == "iPhone99,9")
    }

    @Test func supportedDeploymentEnvironmentsPassThrough() {
        for environment in ["production", "staging", "development", "test"] {
            let config = TelemetryBuildConfig.current(infoDictionary: [
                "WhiteNoiseTelemetryEnvironment": environment
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
        #expect(tracker.source.deviceLabel == "iPhone99,9")
        #expect(tracker.source.platform == "ios")
        #expect(tracker.source.appVersion == "2.0+9")
    }

    @Test func unresolvedBuildSettingsPickFlavorOtlpTokenFromDeploymentEnvironment() {
        let production = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "production"
        ], environment: [
            "PRODUCTION_OTLP_TOKEN_WHITENOISE_IOS": "production-otlp-token",
            "STAGING_OTLP_TOKEN_WHITENOISE_IOS": "staging-otlp-token",
            "AUDIT_LOG_TOKEN_WHITENOISE_IOS": "shared-audit-token"
        ])
        let staging = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "staging"
        ], environment: [
            "PRODUCTION_OTLP_TOKEN_WHITENOISE_IOS": "production-otlp-token",
            "STAGING_OTLP_TOKEN_WHITENOISE_IOS": "staging-otlp-token",
            "AUDIT_LOG_TOKEN_WHITENOISE_IOS": "shared-audit-token"
        ])

        #expect(production.bearerToken == "production-otlp-token")
        #expect(staging.bearerToken == "staging-otlp-token")
        #expect(production.auditLogBearerToken == "shared-audit-token")
        #expect(staging.auditLogBearerToken == "shared-audit-token")
    }

    @Test func auditTokenIsReadFromDedicatedKeyAndDoesNotFallBackToOtlpToken() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseAuditLogBearerToken": "$(WHITENOISE_AUDIT_LOG_BEARER_TOKEN)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "OTLP_TOKEN_WHITENOISE_IOS": "otlp-env-token",
            "AUDIT_LOG_TOKEN_WHITENOISE_IOS": "audit-env-token"
        ])

        #expect(config.bearerToken == "otlp-env-token")
        #expect(config.auditLogBearerToken == "audit-env-token")
        #expect(config.auditTrackerConfig().authorizationBearerToken == "audit-env-token")
    }

    @Test func auditTokenStaysNilWhenOnlyOtlpTokenIsConfigured() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseAuditLogBearerToken": "$(WHITENOISE_AUDIT_LOG_BEARER_TOKEN)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "OTLP_TOKEN_WHITENOISE_IOS": "otlp-env-token"
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

    @Test func chatListUsesLocalizedClockTimeForOlderMessagesToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = now.addingTimeInterval(-2 * 3600)
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = locale
        expectedFormatter.setLocalizedDateFormatFromTemplate("jm")

        #expect(RelativeTime.chatList(
            date,
            now: now,
            calendar: calendar,
            locale: locale
        ) == expectedFormatter.string(from: date))
    }

    @Test func chatListKeepsLocalizedMinuteDurationForRecentMessages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "fr_FR")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = try expectedAbbreviatedDuration(4, unit: .minute, locale: locale)

        #expect(RelativeTime.chatList(
            now.addingTimeInterval(-4 * 60),
            now: now,
            calendar: calendar,
            locale: locale
        ) == expected)
    }

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
        #expect(RelativeTime.formatterCacheLocaleIdentifierForTesting == AppLanguage.currentLocale.identifier)
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

    @Test func shortDefaultsToInAppLanguageLocaleForFormattedLabels() throws {
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

        withAppLanguage(.french) {
            RelativeTime.resetFormatterCacheForTesting()
            defer { RelativeTime.resetFormatterCacheForTesting() }

            let expectedFormatter = DateFormatter()
            expectedFormatter.locale = AppLanguage.currentLocale
            expectedFormatter.setLocalizedDateFormatFromTemplate("d MMM")

            #expect(RelativeTime.short(date, now: now, calendar: calendar) == expectedFormatter.string(from: date))
            #expect(RelativeTime.formatterCacheLocaleIdentifierForTesting == AppLanguage.currentLocale.identifier)
        }
    }

    @Test func shortTimeDefaultsToInAppLanguageLocale() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        withAppLanguage(.french) {
            RelativeTime.resetFormatterCacheForTesting()
            defer { RelativeTime.resetFormatterCacheForTesting() }

            let expectedFormatter = DateFormatter()
            expectedFormatter.locale = AppLanguage.currentLocale
            expectedFormatter.setLocalizedDateFormatFromTemplate("hmm a")

            #expect(RelativeTime.shortTime(date) == expectedFormatter.string(from: date))
            #expect(RelativeTime.formatterCacheLocaleIdentifierForTesting == AppLanguage.currentLocale.identifier)
        }
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

    @Test func relayInputRequiresPublicSecureWebsocketDestinations() {
        #expect(RelaySettings.normalizedRelayURL("  ws://relay.example  ") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example") == "wss://relay.example")
        #expect(RelaySettings.normalizedRelayURL("wss://localhost") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://127.0.0.1") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://10.0.0.1") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://[::1]") == nil)
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

    @Test func relayNormalizationRejectsUserinfoAndBoundsInput() {
        #expect(RelaySettings.normalizedRelayURL("wss://user:pass@relay.example") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example/path?q=token#frag") == "wss://relay.example/path?q=token")
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example:443/path") == "wss://relay.example:443/path")
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example/" + String(repeating: "a", count: 4096)) == nil)
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

@MainActor
struct AppContainerConfigTests {

    @Test func seedRelaysUseWhiteNoiseRegionalRelaysOnly() {
        #expect(AppContainerConfig.seedRelays == [
            "wss://relay.eu.whitenoise.chat",
            "wss://relay.us.whitenoise.chat"
        ])
    }

    @Test func pushServerConfigMatchesBuildFlavor() throws {
        // The push server pubkey is flavor-specific (`WHITENOISE_PUSH_SERVER_PUBKEY_HEX`),
        // so assert against the value for the flavor this test bundle was built
        // with rather than hardcoding production; the test runs under Staging in CI.
        let config = try #require(NativePushServerConfig.current())

        let expectedPubkeyByFlavor = [
            "production": "73a4996bd18de19f6ac5f6ad42f5f2671eba6e5b739ea9695f07b00b0693fc04",
            "staging": "94186f72f66d09f94ca33599fda4b39cd8ac403769647658252dc48b8318f0c9"
        ]
        let flavor = try #require(Bundle.main.object(forInfoDictionaryKey: "WNFlavor") as? String)
        let expectedPubkey = try #require(expectedPubkeyByFlavor[flavor])

        #expect(config.serverPubkeyHex == expectedPubkey)
        #expect(config.relayHint == "wss://relay.eu.whitenoise.chat")
        #expect(config.relayHint == AppContainerConfig.pushNotificationRelayHint)
        #expect(AppContainerConfig.seedRelays.contains(config.relayHint ?? ""))
    }

    @Test func marmotRootUsesProductScopedCutoverDirectoryName() {
        let base = URL(fileURLWithPath: "/tmp/WhiteNoise-test", isDirectory: true)

        #expect(AppContainerConfig.productDirectoryName == "White Noise")
        #expect(AppContainerConfig.legacyMarmotDirectoryName == "Marmot")
        #expect(AppContainerConfig.marmotRoot(in: base).path == "/tmp/WhiteNoise-test/White Noise/Marmot")
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

        let expectedRoot = shared
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Marmot", isDirectory: true)
        #expect(root.path == expectedRoot.path)
        #expect(fileManager.applicationSupportLookupCount == 0)
    }

    @Test func productionRootSurfacesDirectoryCreationFailure() {
        let shared = URL(fileURLWithPath: "/tmp/WhiteNoise-unwritable", isDirectory: true)
        let root = shared
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Marmot", isDirectory: true)
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
            "Draft: %@",
            "Edit Description",
            "Shared Media",
            "New encrypted message",
            "That QR code isn't a White Noise profile.",
            "Couldn't create chat",
            "Mark as unread",
            "Pin",
            "Pinned",
            "Unpin",
            "Updating chat…",
            "Couldn't mark as unread",
            "Couldn't update pin",
            "Push registration failed",
            "Support",
            "Chat with support",
            "Connecting to support…",
            "Couldn't connect to support",
            "Please check your connection and try again.",
            "Leave “%@”?",
            "You'll stop receiving new messages. This chat will remain on this device as read-only history until you delete it.",
            "Leaving…",
            "Sign Up",
            "Choose Avatar",
            "Change Avatar",
            "Remove Avatar",
            "Name",
            "About (Optional)",
            "Signing Up…",
            "Couldn't create your profile. Try again.",
            "Your profile was created, but some details couldn't be saved.",
            "Continue",
            "Your avatar is public. The photo is uploaded to a public service, and removing it from your profile may not delete the uploaded copy.",
            "That photo is too large. Choose a different photo.",
            "That photo can't be used. Choose a different photo.",
            "New profile",
            "Profile avatar preview",
            "Selected profile photo"
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

    @Test func welcomeEntryPointButtonsAreTranslatedInEveryShippedLocale() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedTranslations: [String: [String: String]] = [
            "Sign In": [
                "de": "Anmelden",
                "es": "Iniciar sesión",
                "fr": "Se connecter",
                "it": "Accedi",
                "pt": "Entrar",
                "ru": "Войти",
                "tr": "Oturum Aç",
                "zh-Hans": "登录",
                "zh-Hant": "登入"
            ],
            "Sign Up": [
                "de": "Registrieren",
                "es": "Registrarse",
                "fr": "S’inscrire",
                "it": "Registrati",
                "pt": "Cadastrar-se",
                "ru": "Зарегистрироваться",
                "tr": "Kaydol",
                "zh-Hans": "注册",
                "zh-Hant": "註冊"
            ]
        ]

        for (key, translations) in expectedTranslations {
            for locale in expectedLocales {
                let expected = try #require(
                    translations[locale],
                    "No expected \(locale) translation declared for \(key)"
                )
                #expect(try localizedValue(key, locale: locale, in: strings) == expected)
                #expect(
                    try localizedState(key, locale: locale, in: strings) == "translated",
                    "\(key) is not marked translated in \(locale)"
                )
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
                let values = try localizedLeaves(key, locale: locale, in: strings)
                    .filter { !$0.isSubstitutionShell }
                    .map(\.value)
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

    @Test func sharedCatalogMarksEveryLocaleTranslated() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        for (key, rawEntry) in strings {
            _ = try #require(rawEntry as? [String: Any], "Invalid localization entry: \(key)")
            for locale in expectedLocales {
                for leaf in try localizedLeaves(key, locale: locale, in: strings) {
                    #expect(
                        leaf.state == "translated",
                        "Untranslated \(locale) value for \(key) (state: \(leaf.state))"
                    )
                }
            }
        }
    }

    @Test func countLocalizationsUsePluralVariations() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let pluralKeys = [
            "%lld members",
            "%lld person group",
            "%lld more messages",
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

    @Test func localizationBundleLookupIsMemoizedForSelectedLanguage() {
        let bundle = Bundle(for: L10nBundleCacheProbe.self)
        L10n.resetBundleCacheForTesting()
        #expect(L10n.bundleCacheCountForTesting(in: bundle) == 0)
        _ = L10n.formatted(
            "Settings",
            arguments: [],
            locale: Locale(identifier: "fr"),
            baseBundle: bundle
        )
        #expect(L10n.bundleCacheCountForTesting(in: bundle) == 1)
        _ = L10n.formatted(
            "Done",
            arguments: [],
            locale: Locale(identifier: "fr"),
            baseBundle: bundle
        )
        #expect(L10n.bundleCacheCountForTesting(in: bundle) == 1)
    }

    @Test func infoPlistCatalogLocalizesCameraPermissionCopy() throws {
        let catalog = try readCatalog("whitenoise-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let cameraUsage = try #require(strings["NSCameraUsageDescription"] as? [String: Any])
        let localizations = try #require(cameraUsage["localizations"] as? [String: Any])

        let english = try localizedValue("NSCameraUsageDescription", locale: "en", in: strings)
        #expect(english != "NSCameraUsageDescription")
        #expect(english == "White Noise uses the camera to scan profile QR codes and take photos and videos for encrypted chats.")
        #expect(localizations["fr"] != nil)
        #expect(localizations["zh-Hant"] != nil)
    }

    @Test func infoPlistCatalogCoversLaunchLanguages() throws {
        let catalog = try readCatalog("whitenoise-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        // CFBundleDisplayName is flavor-specific (`WN_DISPLAY_NAME`). Xcode's IDE
        // auto-extracts a development-language placeholder (`state` "new",
        // resolved against the Release-Production default config) into this
        // catalog on every build, and there is no build setting that suppresses
        // it. That placeholder is NOT compiled into the built app's
        // `.lproj/InfoPlist.strings`, so it cannot override the flavor display
        // name (verified: a Staging build with the entry present still ships
        // "WN Staging" with no localized override). Only a *translated*
        // localization would actually hide staging, so fail on that alone
        // rather than on the harmless auto-extracted placeholder.
        if let displayName = strings["CFBundleDisplayName"] as? [String: Any] {
            let localizations = (displayName["localizations"] as? [String: Any]) ?? [:]
            for (locale, entry) in localizations {
                let state = ((entry as? [String: Any])?["stringUnit"] as? [String: Any])?["state"] as? String
                #expect(
                    state != "translated",
                    "CFBundleDisplayName must not carry a translated value (\(locale)); it would hide the flavor display name."
                )
            }
        }

        for key in ["CFBundleName", "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSFaceIDUsageDescription", "NSLocationWhenInUseUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
            for locale in ["en"] + expectedLocales {
                #expect(!(try localizedValue(key, locale: locale, in: strings)).isEmpty)
            }
        }
    }

    @Test func permissionDescriptionsMatchBuiltAppAndCoverEveryLanguage() throws {
        let catalog = try readCatalog("whitenoise-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let info = try #require(Bundle.main.infoDictionary)
        let usageKeys = info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
        #expect(usageKeys.contains("NSPhotoLibraryAddUsageDescription"))
        #expect(usageKeys.contains("NSLocationWhenInUseUsageDescription"))
        for key in usageKeys {
            let purpose = try #require(info[key] as? String)
            #expect(try localizedValue(key, locale: "en", in: strings) == purpose)
            for locale in expectedLocales {
                #expect(!(try localizedValue(key, locale: locale, in: strings)).isEmpty)
                #expect(try localizedState(key, locale: locale, in: strings) == "translated")
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

    private func localizedState(_ key: String, locale: String, in strings: [String: Any]) throws -> String {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let stringUnit = try #require(localeEntry["stringUnit"] as? [String: Any], "Missing string unit for \(key) in \(locale)")
        return try #require(stringUnit["state"] as? String, "Missing state for \(key) in \(locale)")
    }

    private struct LocalizedLeaf {
        let state: String
        let value: String
        let isSubstitutionShell: Bool
    }

    private func localizedLeaves(_ key: String, locale: String, in strings: [String: Any]) throws -> [LocalizedLeaf] {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let substitutions = (localeEntry["substitutions"] as? [String: Any]) ?? [:]

        var leaves: [LocalizedLeaf] = []
        if let stringUnit = localeEntry["stringUnit"] as? [String: Any] {
            leaves.append(
                LocalizedLeaf(
                    state: try #require(stringUnit["state"] as? String, "Missing state for \(key) in \(locale)"),
                    value: try #require(stringUnit["value"] as? String, "Missing value for \(key) in \(locale)"),
                    isSubstitutionShell: !substitutions.isEmpty
                )
            )
        }

        for rawSubstitution in substitutions.values {
            let substitution = try #require(rawSubstitution as? [String: Any])
            let variations = try #require(substitution["variations"] as? [String: Any])
            let plural = try #require(variations["plural"] as? [String: Any])
            for rawForm in plural.values {
                let form = try #require(rawForm as? [String: Any])
                let stringUnit = try #require(form["stringUnit"] as? [String: Any])
                leaves.append(
                    LocalizedLeaf(
                        state: try #require(stringUnit["state"] as? String, "Missing state for \(key) in \(locale)"),
                        value: try #require(stringUnit["value"] as? String, "Missing value for \(key) in \(locale)"),
                        isSubstitutionShell: false
                    )
                )
            }
        }

        return leaves
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

private final class L10nBundleCacheProbe {}

struct AppearancePreferencesTests {
    @Test func themePreferencesResolveToExpectedColorSchemes() {
        #expect(AppearanceTheme.resolved(rawValue: nil) == .system)
        #expect(AppearanceTheme.resolved(rawValue: "nope") == .system)
        #expect(AppearanceTheme.resolved(rawValue: "trueBlack") == .dark)
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

    @Test func systemLanguageDisplayNameUsesSelectedAppLanguage() {
        withAppLanguage(.french) {
            #expect(AppLanguage.system.displayName == "Système")
        }
    }

    @Test func languageChangeNotificationCarriesLanguageInUserInfoNotObject() throws {
        let suiteName = "dev.ipf.WhiteNoise.language-notification-test.\(UUID().uuidString)"
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

    @Test func compactComposerMetricsMatchThePrototypeWithoutShrinkingHitTargets() {
        #expect(ComposerInputChrome.controlSize == 44)
        #expect(ComposerInputChrome.sendButtonSize == 32)
        #expect(ComposerInputChrome.cornerRadius == 22)
        #expect(ComposerInputChrome.rowSpacing == 8)
        #expect(ComposerInputChrome.inputSpacing == 4)
        #expect(ComposerInputChrome.horizontalInset == 16)
        #expect(ComposerInputChrome.verticalInset == 6)
    }

    @Test func sendButtonStaysMonochromeAcrossAppearances() {
        let light = ComposerSendButtonAppearance.colorScheme(.light)
        let dark = ComposerSendButtonAppearance.colorScheme(.dark)

        #expect(light.fill == .black)
        #expect(light.symbol == .white)
        #expect(dark.fill == .white)
        #expect(dark.symbol == .black)
    }

    @Test func voiceRecordingControlsKeepCancelAvailableAndGateStopOnLock() {
        #expect(!ComposerVoiceChromePresentation.showsCancel(isActive: false))
        #expect(ComposerVoiceChromePresentation.showsCancel(isActive: true))
        #expect(!ComposerVoiceChromePresentation.showsStop(isActive: false, isLocked: true))
        #expect(!ComposerVoiceChromePresentation.showsStop(isActive: true, isLocked: false))
        #expect(ComposerVoiceChromePresentation.showsStop(isActive: true, isLocked: true))
    }

    @Test func activeVoiceRecordingHidesButDoesNotReplaceTheFocusedTextEntry() {
        #expect(ComposerVoiceChromePresentation.textEntryOpacity(isActive: false) == 1)
        #expect(ComposerVoiceChromePresentation.textEntryOpacity(isActive: true) == 0)
    }
}

@MainActor
struct ToastPresentationTests {
    @Test func toastOverlayPresentsAboveModalWindows() {
        #expect(ToastOverlayPresentation.windowLevel.rawValue > UIWindow.Level.alert.rawValue)
    }

    @Test func toastDefaultsStayVisibleLongEnoughToRead() {
        #expect(Toast.success("Saved").duration == 3.0)
        #expect(Toast.warning("Warning").duration == 3.5)
        #expect(Toast.error("Failed").duration == 4.0)
    }

    @Test func upwardToastGestureDismissesByDistanceOrVelocity() {
        #expect(ToastDismissGesture.shouldDismiss(
            translation: -28,
            predictedEndTranslation: -28
        ))
        #expect(ToastDismissGesture.shouldDismiss(
            translation: -12,
            predictedEndTranslation: -60
        ))
        #expect(!ToastDismissGesture.shouldDismiss(
            translation: -12,
            predictedEndTranslation: -20
        ))
        #expect(!ToastDismissGesture.shouldDismiss(
            translation: 40,
            predictedEndTranslation: 60
        ))
    }
}

struct DiagnosticsPresentationTests {
    @Test func performanceOperationTextReportsAggregateLatencyShape() throws {
        let snapshot = AppPerformanceOperationSnapshotFfi(
            attempts: 3,
            successes: 2,
            failures: 1,
            durationMs: DurationHistogramSnapshotFfi(
                buckets: [DurationHistogramBucketFfi(upperBoundMs: 250, count: 2)],
                overflowCount: 1,
                sumMs: 875
            )
        )

        let text = try #require(DiagnosticsView.performanceOperationText(
            label: "message send",
            snapshot: snapshot
        ))

        #expect(
            text == "[perf] message send: 3 attempts, 2 succeeded, 1 failed, 875 ms total, 291 ms avg, p50 ≤250 ms, p95 >250 ms"
        )
        #expect(DiagnosticsView.performanceOperationText(
            label: "unused",
            snapshot: AppPerformanceOperationSnapshotFfi(
                attempts: 0,
                successes: 0,
                failures: 0,
                durationMs: DurationHistogramSnapshotFfi(
                    buckets: [],
                    overflowCount: 0,
                    sumMs: 0
                )
            )
        ) == nil)
    }

    @Test func performancePercentilesHandleEmptyAndOverflowOnlyHistograms() {
        #expect(DiagnosticsView.percentileText(
            DurationHistogramSnapshotFfi(buckets: [], overflowCount: 0, sumMs: 0),
            percentile: 0.95
        ) == "n/a")
        #expect(DiagnosticsView.percentileText(
            DurationHistogramSnapshotFfi(buckets: [], overflowCount: 2, sumMs: 4_000),
            percentile: 0.50
        ) == "overflow")
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

    @Test func diagnosticTextLabelsWelcomeDeliveryPending() {
        let groupId = hex("cc")
        let messageId = hex("dd")
        let recipient = hex("ee")
        let event = MarmotEventFfi.welcomeDeliveryPending(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            messageIdHex: messageId,
            recipientHex: recipient
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] welcome pending"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
        #expect(text.contains(IdentityFormatter.short(messageId)))
        #expect(text.contains(IdentityFormatter.short(recipient)))
    }

    @Test func diagnosticTextLabelsEpochStallEscalation() {
        let groupId = hex("cc")
        let event = MarmotEventFfi.epochStallEscalated(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            stalledEpoch: 12,
            arms: 3
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice]"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
        #expect(text.contains("epoch 12"))
        #expect(text.contains("3 recovery attempts"))
        #expect(text.contains("re-sync recommended"))
    }

    @Test func diagnosticTextLabelsGroupStateInvalidated() {
        let groupId = hex("cc")
        let event = MarmotEventFfi.groupEvent(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            event: .groupStateInvalidated(
                epoch: 2,
                invalidatedCommitIdHex: hex("dd"),
                reason: "superseded_by_branch_selection"
            )
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] group event state invalidated"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
    }

    @Test func diagnosticTextLabelsTransportObjectResourceRefusal() {
        let groupId = hex("cc")
        let messageId = hex("dd")
        let event = MarmotEventFfi.groupEvent(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            event: .transportObjectResourceRefused(
                messageIdHex: messageId,
                resource: "deferred_peel_rows"
            )
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] group event resource refused"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
        #expect(!text.contains(messageId))
        #expect(!text.contains("deferred_peel_rows"))
    }

    @Test @MainActor func notificationServiceDiagnosticTextUsesLocalizedOperationalShape() {
        let snapshot = NotificationServiceDiagnosticSnapshot(
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 931,
            stage: .collectionCompleted,
            outcome: .failed,
            notificationCount: 0
        )

        let english = DiagnosticsView.notificationServiceDiagnosticText(
            snapshot,
            locale: Locale(identifier: "en_US")
        )
        let german = DiagnosticsView.notificationServiceDiagnosticText(
            snapshot,
            locale: Locale(identifier: "de_DE")
        )

        #expect(english.contains("931 ms"))
        #expect(english.contains("0 notifications"))
        #expect(german.contains("0 Benachrichtigungen"))
        #expect(english != german)
        #expect(!english.contains("2023-11-14T22:13:20Z"))
    }

    @Test @MainActor func notificationServiceDiagnosticIsTimestampedAndAppendedOnce() {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = NotificationServiceDiagnosticSnapshot(
            recordedAt: recordedAt,
            durationMilliseconds: 931,
            stage: .collectionCompleted,
            outcome: .failed,
            notificationCount: 0
        )
        let model = DiagnosticsViewModel()

        model.appendNotificationServiceDiagnosticIfNeeded(snapshot)
        model.appendNotificationServiceDiagnosticIfNeeded(snapshot)

        #expect(model.entries.count == 1)
        #expect(model.entries.first?.timestamp == recordedAt)
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
        #expect(presentation?.userInfo[LocalNotificationProjection.accountIdHexKey] == hex("11"))
    }

    @Test func notificationDeliveryDispositionMarkersAreExplicit() {
        #expect(LocalNotificationProjection.isQuietOrFallback(from: [
            LocalNotificationProjection.deliveryDispositionKey:
                LocalNotificationProjection.quietDisposition,
        ]))
        #expect(LocalNotificationProjection.isQuietOrFallback(from: [
            LocalNotificationProjection.deliveryDispositionKey:
                LocalNotificationProjection.fallbackDisposition,
        ]))
        #expect(!LocalNotificationProjection.isQuietOrFallback(from: [:]))
        #expect(LocalNotificationProjection.isActionFailure(from: [
            LocalNotificationProjection.deliveryDispositionKey:
                LocalNotificationProjection.actionFailureDisposition,
        ]))
    }

    @Test func notificationActionsRemoveOnlyTheActedNotification() {
        #expect(
            NotificationActionDeliveredNotificationPolicy.identifiersToRemove(
                actedNotificationIdentifier: "acted"
            ) == ["acted"]
        )
    }

    @Test func groupMessageUsesGroupTitleAndSenderBodyPrefix() {
        withAppLanguage(.english) {
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
    }

    @Test func groupMessagePreviewUsesLocalizedSeparator() {
        withAppLanguage(.french) {
            let update = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Bob",
                previewText: "Ship it"
            )

            let presentation = LocalNotificationProjection.makePresentation(for: update)

            #expect(presentation?.body == "Bob : Ship it")
        }
    }

    @Test func groupMentionUsesMentionBodyPrefix() {
        let update = notificationUpdate(
            isDm: false,
            isMention: true,
            groupName: "Project Room",
            senderName: "Bob",
            previewText: "Ship it"
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.title == "Project Room")
        #expect(presentation?.body == "Bob mentioned you: Ship it")
    }

    @Test func groupMentionWithoutPreviewUsesMentionFallback() {
        let update = notificationUpdate(
            isDm: false,
            isMention: true,
            groupName: nil,
            senderName: "Bob",
            previewText: nil
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.title == "Group message")
        #expect(presentation?.body == "Bob mentioned you")
    }

    @Test func notificationFallbacksUseFormattedLocalizationKeys() {
        let invite = notificationUpdate(
            trigger: .groupInvite,
            isDm: false,
            groupName: "Project Room",
            previewText: nil
        )
        let inviteWithoutGroupName = notificationUpdate(
            trigger: .groupInvite,
            isDm: false,
            groupName: nil,
            previewText: nil
        )
        let groupMessage = notificationUpdate(
            isDm: false,
            groupName: nil,
            senderName: "Bob",
            previewText: nil
        )

        #expect(LocalNotificationProjection.makePresentation(for: invite)?.body == L10n.formatted("Invitation to %@", "Project Room"))
        #expect(LocalNotificationProjection.makePresentation(for: inviteWithoutGroupName)?.body == L10n.string("Open White Noise to view the invite"))
        #expect(LocalNotificationProjection.makePresentation(for: groupMessage)?.body == L10n.formatted("%@ sent a message", "Bob"))
    }

    @Test func groupMembershipAndAdminNotificationsUseDedicatedCopy() {
        let removed = LocalNotificationProjection.makePresentation(for: notificationUpdate(
            trigger: .removedFromGroup,
            isDm: false,
            groupName: "Project Room",
            previewText: nil
        ))
        let madeAdmin = LocalNotificationProjection.makePresentation(for: notificationUpdate(
            trigger: .madeAdmin,
            isDm: false,
            groupName: "Project Room",
            previewText: nil
        ))
        let removedAsAdmin = LocalNotificationProjection.makePresentation(for: notificationUpdate(
            trigger: .removedAsAdmin,
            isDm: false,
            groupName: nil,
            previewText: nil
        ))

        #expect(removed?.title == "Project Room")
        #expect(removed?.body == "You were removed from this chat.")
        #expect(madeAdmin?.title == "Project Room")
        #expect(madeAdmin?.body == "You are now an admin.")
        #expect(removedAsAdmin?.title == "White Noise")
        #expect(removedAsAdmin?.body == "You are no longer an admin.")
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

        #expect(
            presentation?.title
                == IdentityPresentation.text(
                    accountIdHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                )
        )
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

    @Test func archivedNotificationsAreNeverPresented() {
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            isArchived: true,
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
            AccountSummaryFfi(label: "account-a", accountIdHex: hex("11"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-b", accountIdHex: hex("22"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-c", accountIdHex: hex("33"), localSigning: true, signedOut: false, running: true)
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

struct NativePushEnableCoordinatorTests {

    @Test func enableWritesPreferenceBeforeSyncingRegistration() async throws {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            syncPushRegistration: {
                operations.append("sync")
            }
        )

        let settings = try await coordinator.enable()

        #expect(settings.nativePushEnabled == true)
        #expect(operations == ["set:true", "sync"])
    }

    @Test func enableDoesNotSyncRegistrationWhenPreferenceWriteFails() async {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                throw NativePushEnableTestError.writeFailed
            },
            syncPushRegistration: {
                operations.append("sync")
            }
        )

        do {
            _ = try await coordinator.enable()
            Issue.record("Expected preference write failure")
        } catch {
            #expect(error as? NativePushEnableTestError == .writeFailed)
        }

        #expect(operations == ["set:true"])
    }

    @Test func enableKeepsPreferenceOnWhenWaitingForApnsToken() async throws {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            syncPushRegistration: {
                operations.append("sync")
                throw NotificationSettingsActionError.missingApnsToken
            }
        )

        let settings = try await coordinator.enable()

        #expect(settings.nativePushEnabled == true)
        #expect(operations == ["set:true", "sync"])
    }

    @Test func enableRollsPreferenceBackWhenRegistrationSyncFails() async {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            syncPushRegistration: {
                operations.append("sync")
                throw NativePushEnableTestError.syncFailed
            }
        )

        do {
            _ = try await coordinator.enable()
            Issue.record("Expected registration sync failure")
        } catch {
            #expect(error as? NativePushEnableTestError == .syncFailed)
        }

        #expect(operations == ["set:true", "sync", "set:false"])
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

private enum NativePushEnableTestError: Error, Equatable {
    case writeFailed
    case syncFailed
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

    @Test func newDataCollectionShowsAllAdditionalPresentationsAtTheCap() {
        // primary + exactly maxAdditionalPresentations additional => no overflow,
        // every record shown individually, no summary appended.
        let total = NotificationServiceProjection.maxAdditionalPresentations + 1
        let updates = (0..<total).map { index in
            notificationUpdate(
                notificationKey: "notif-\(index)",
                previewText: "message-\(index)",
                // newest first after sort: higher timestamp == newer
                timestampMs: Int64(10_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates.shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        let expectedPresentations = updates.map {
            LocalNotificationProjection.makePresentation(for: $0)!
        }
        #expect(decision == .decorate(
            expectedPresentations.first!,
            additionalPresentations: Array(expectedPresentations.dropFirst())
        ))
    }

    @Test func newDataCollectionShowsSingleRecordOverCapWithoutSummary() {
        let total = NotificationServiceProjection.maxAdditionalPresentations + 2
        let updates = (0..<total).map { index in
            notificationUpdate(
                notificationKey: "notif-\(index)",
                previewText: "message-\(index)",
                timestampMs: Int64(10_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates.shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        let expectedPresentations = updates.map {
            LocalNotificationProjection.makePresentation(for: $0)!
        }
        #expect(decision == .decorate(
            expectedPresentations.first!,
            additionalPresentations: Array(expectedPresentations.dropFirst())
        ))
    }

    @Test func newDataCollectionCapsAdditionalPresentationsAndCoalescesOverflow() {
        let cap = NotificationServiceProjection.maxAdditionalPresentations
        let overflow = 5
        // primary + cap shown individually + overflow folded into one summary.
        let total = 1 + cap + overflow
        let updates = (0..<total).map { index in
            notificationUpdate(
                notificationKey: "notif-\(index)",
                previewText: "message-\(index)",
                timestampMs: Int64(100_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates.shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        guard case let .decorate(primary, additional) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }

        // Exactly cap individually-shown additional presentations + 1 summary.
        #expect(additional.count == cap + 1)

        let presentations = updates.map {
            LocalNotificationProjection.makePresentation(for: $0)!
        }
        #expect(primary == presentations.first!)
        // The first `cap` additional presentations are the next-newest records,
        // shown individually.
        #expect(Array(additional.prefix(cap)) == Array(presentations.dropFirst().prefix(cap)))

        // The trailing entry is a coalesced summary, not an abandoned record.
        let summary = additional.last!
        #expect(summary.title == L10n.string("White Noise"))
        #expect(summary.body == L10n.plural("%lld more messages", Int64(overflow)))
        // Summary carries no message content/preview from the overflow records.
        for index in (1 + cap)..<total {
            #expect(!summary.body.contains("message-\(index)"))
        }
        // Distinct identifier so the summary never dedupes against a real message.
        #expect(summary.identifier != primary.identifier)
        for shown in additional.dropLast() {
            #expect(summary.identifier != shown.identifier)
        }
        // Routes to the newest conversation so a tap lands somewhere sane.
        #expect(summary.threadIdentifier == primary.threadIdentifier)
        #expect(summary.route.accountRef == primary.route.accountRef)
        #expect(summary.route.groupIdHex == primary.route.groupIdHex)
        #expect(summary.route.messageIdHex == nil)
    }

    @Test func overflowSummariesStayOnTheirOwnNotificationRoutes() {
        let cap = NotificationServiceProjection.maxAdditionalPresentations
        let primary = notificationUpdate(
            notificationKey: "primary",
            accountRef: "account-a",
            groupIdHex: "group-a",
            timestampMs: 100_000
        )
        let shown = (0..<cap).map { index in
            notificationUpdate(
                notificationKey: "shown-\(index)",
                accountRef: "account-a",
                groupIdHex: "group-a",
                timestampMs: Int64(90_000 - index)
            )
        }
        let overflow = [
            notificationUpdate(
                notificationKey: "overflow-b-1",
                conversationKey: "conv-b",
                accountRef: "account-b",
                groupIdHex: "group-b",
                timestampMs: 80_000
            ),
            notificationUpdate(
                notificationKey: "overflow-b-2",
                conversationKey: "conv-b",
                accountRef: "account-b",
                groupIdHex: "group-b",
                timestampMs: 79_000
            ),
            notificationUpdate(
                notificationKey: "overflow-c-1",
                conversationKey: "conv-c",
                accountRef: "account-c",
                groupIdHex: "group-c",
                timestampMs: 78_000
            )
        ]
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: ([primary] + shown + overflow).shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        guard case let .decorate(_, additional) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }

        let summaries = Array(additional.dropFirst(cap))
        #expect(summaries.map(\.route.accountRef) == ["account-b", "account-c"])
        #expect(summaries.map(\.route.groupIdHex) == ["group-b", "group-c"])
        #expect(summaries.map(\.threadIdentifier) == ["conv-b", "conv-c"])
        #expect(summaries.map(\.body) == [
            L10n.plural("%lld more messages", Int64(2)),
            L10n.plural("%lld more messages", Int64(1))
        ])
    }

    @Test func boundedAdditionalPresentationsCoalescesOverflowWithoutDroppingRecords() {
        // Unit-level coverage of the live NSE bounding path (the one
        // `decision(...)` uses).
        let cap = NotificationServiceProjection.maxAdditionalPresentations
        let additionalUpdates = (0..<(cap + 3)).map { index in
            notificationUpdate(notificationKey: "add-\(index)", timestampMs: Int64(900 - index))
        }

        let bounded = NotificationPresentationPolicy.boundedAdditionalPresentations(
            from: additionalUpdates
        )

        // cap shown + a single summary; the 3 overflow records are represented, not lost.
        let shown = additionalUpdates.prefix(cap).compactMap {
            LocalNotificationProjection.makePresentation(for: $0)
        }
        #expect(bounded.count == cap + 1)
        #expect(Array(bounded.prefix(cap)) == shown)
        #expect(bounded.last!.body == L10n.plural("%lld more messages", Int64(3)))
    }

    @Test func boundedAdditionalPresentationsLeavesSmallListUntouched() {
        let additionalUpdates = (0..<3).map { index in
            notificationUpdate(notificationKey: "add-\(index)", timestampMs: Int64(900 - index))
        }

        let bounded = NotificationPresentationPolicy.boundedAdditionalPresentations(
            from: additionalUpdates
        )

        #expect(bounded == additionalUpdates.compactMap {
            LocalNotificationProjection.makePresentation(for: $0)
        })
    }

    @Test func equalTimestampsUseStableOrdering() {
        let updates = [
            notificationUpdate(
                notificationKey: "key-b",
                accountRef: "account-b",
                groupIdHex: "group-a",
                timestampMs: 2_000
            ),
            notificationUpdate(
                notificationKey: "key-a",
                accountRef: "account-a",
                groupIdHex: "group-z",
                timestampMs: 2_000
            ),
            notificationUpdate(
                notificationKey: "key-c",
                accountRef: "account-b",
                groupIdHex: "group-b",
                timestampMs: 2_000
            )
        ]
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates,
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        guard case let .decorate(primary, additional) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }
        #expect(primary.identifier == "key-a")
        #expect(additional.map(\.identifier) == ["key-b", "key-c"])
    }

    @Test func disabledLocalNotificationsDeliverQuietlyFromTheNSE() {
        // Disabling local notifications must not produce an audible generic
        // banner per message; the wake sheds its alert and lands quietly,
        // matching the all-muted wake. Forward-looking: the pinned engine
        // currently discards disabled-account records at ingest (the wake
        // arrives as an empty `.noData` collection instead), so this state
        // only occurs once the engine surfaces suppressed records.
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

        #expect(decision == .deliverQuietly)
    }

    @Test func archivedNotificationsAreFilteredBeforeChoosingPresentation() {
        let archivedNewer = notificationUpdate(
            notificationKey: "archived-newer",
            accountRef: "account-a",
            groupIdHex: "group-archived",
            timestampMs: 3_000
        )
        let visibleOlder = notificationUpdate(
            notificationKey: "visible-older",
            accountRef: "account-a",
            groupIdHex: "group-visible",
            timestampMs: 2_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [archivedNewer, visibleOlder],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            isArchived: { _, groupIdHex in groupIdHex == "group-archived" }
        )

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: visibleOlder)!,
            additionalPresentations: []
        ))
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

    @Test func memoizingReadResolvesEachDistinctAccountAtMostOncePerWake() {
        // A backlog of many records spanning only a couple of distinct accounts
        // must not issue one settings read per record (the NSE's read is a
        // synchronous FFI call inside the ~8 s wake budget). Wrapping the read
        // with the memoizing policy should resolve each distinct accountRef once.
        var readCounts: [String: Int] = [:]
        let memoized = NotificationServiceSettingsReadPolicy.memoizingLocalNotificationsEnabled { accountRef in
            readCounts[accountRef, default: 0] += 1
            return accountRef == "account-enabled"
        }

        let notifications = (0..<40).map { index -> NotificationUpdateFfi in
            // Alternate between two accounts so distinct count is 2, records 40.
            let accountRef = index.isMultiple(of: 2) ? "account-enabled" : "account-disabled"
            return notificationUpdate(
                notificationKey: "notif-\(index)",
                accountRef: accountRef,
                timestampMs: Int64(10_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: notifications,
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            localNotificationsEnabled: memoized
        )

        // Each distinct account is read exactly once despite 40 records.
        #expect(readCounts == ["account-enabled": 1, "account-disabled": 1])

        // Memoization must not change the filtering outcome: only enabled-account
        // records survive, newest first.
        guard case let .decorate(primary, _) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }
        #expect(primary.route.accountRef == "account-enabled")
    }

    @Test func memoizingReadReturnsStableValuePerAccount() {
        // The cached value, not a fresh read, is returned on repeated calls for
        // the same account; distinct accounts each get their own read.
        var readCount = 0
        let memoized = NotificationServiceSettingsReadPolicy.memoizingLocalNotificationsEnabled { accountRef in
            readCount += 1
            return accountRef == "yes"
        }

        #expect(memoized("yes"))
        #expect(memoized("yes"))
        #expect(!memoized("no"))
        #expect(!memoized("no"))

        // One read per distinct account: "yes" once, "no" once.
        #expect(readCount == 2)
    }

    @Test func archivedLookupsRunOnlyForRecordsPassingCheapPolicyGates() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [
                notificationUpdate(accountRef: "allowed", accountIdHex: hex("11")),
                notificationUpdate(accountRef: "disabled", accountIdHex: hex("22")),
                notificationUpdate(accountRef: "muted", accountIdHex: hex("33")),
                notificationUpdate(
                    accountRef: "mentions-only-plain",
                    accountIdHex: hex("44"),
                    isMention: false
                ),
                notificationUpdate(
                    accountRef: "mentions-only-mention",
                    accountIdHex: hex("44"),
                    isMention: true
                ),
                notificationUpdate(accountRef: "self", accountIdHex: hex("55"), isFromSelf: true),
            ],
            error: nil
        )

        let accounts = NotificationPresentationPolicy.accountRefsRequiringArchivedLookup(
            for: collection,
            localNotificationsEnabled: { $0 != "disabled" },
            notifyMode: { accountIdHex, _ in
                switch accountIdHex {
                case hex("33"): .nothing
                case hex("44"): .mentionsOnly
                default: .all
                }
            }
        )

        #expect(accounts == ["allowed", "mentions-only-mention"])
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

    @Test func notificationServiceStorageReaderProjectsSmallValuesOffMain() async throws {
        let client = try MarmotClient.testClient()
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentity(
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
            )
            let expected = try await client.notificationSettings(accountRef: account.label)

            let enabled = await NotificationServiceStorageReader.localNotificationsEnabled(
                marmot: client.marmot,
                accountRefs: [account.label]
            )
            let badgeCount = await NotificationServiceStorageReader.applicationBadgeCount(
                marmot: client.marmot
            )

            #expect(enabled[account.label] == expected.localNotificationsEnabled)
            #expect(badgeCount == 0)
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func noDataCollectionKeepsGenericFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .noData,
            notifications: [],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .fallback)
    }

    @Test func selfOnlyCollectionDeliversQuietly() {
        // The wake carried records and every one was the user's own message;
        // quiet delivery beats an audible generic banner for self content.
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [notificationUpdate(isFromSelf: true)],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .deliverQuietly)
    }

    @Test func overflowSummariesAreBoundedAcrossManyConversations() {
        // A backlog spread across many chats folds into at most
        // maxOverflowSummaries presentations — the per-conversation summary
        // path must not reintroduce the unbounded add/donate loop.
        let updates = (0..<30).map { index in
            notificationUpdate(
                notificationKey: "overflow-\(index)",
                groupIdHex: hex(String(format: "%02x", index))
            )
        }
        let summaries = NotificationPresentationPolicy.overflowSummaryPresentations(from: updates)
        #expect(summaries.count == NotificationPresentationPolicy.maxOverflowSummaries)
        // Every folded conversation stays represented: per-route counts plus
        // the aggregate tail account for all 30 records.
        #expect(summaries.count <= updates.count)
    }

    @Test func overflowSummariesCarryTheOrOfTheirMembersMentionBits() {
        // A missing bit reads as a mention in willPresent, so an
        // all-non-mention summary must carry an explicit "0" or it banners
        // through a later mentions-only switch.
        let plainSummary = NotificationPresentationPolicy.overflowSummaryPresentations(from: [
            notificationUpdate(notificationKey: "p1"),
            notificationUpdate(notificationKey: "p2"),
        ])
        #expect(plainSummary.count == 1)
        #expect(!LocalNotificationProjection.isMention(from: plainSummary[0].userInfo))

        let mentionSummary = NotificationPresentationPolicy.overflowSummaryPresentations(from: [
            notificationUpdate(notificationKey: "m1"),
            notificationUpdate(notificationKey: "m2", isMention: true),
        ])
        #expect(mentionSummary.count == 1)
        #expect(LocalNotificationProjection.isMention(from: mentionSummary[0].userInfo))
    }

    @Test func presentationPersistsTheMentionBitForWillPresent() {
        let mention = notificationUpdate(notificationKey: "m", isMention: true)
        let plain = notificationUpdate(notificationKey: "p")

        let mentionInfo = LocalNotificationProjection.makePresentation(for: mention)!.userInfo
        let plainInfo = LocalNotificationProjection.makePresentation(for: plain)!.userInfo

        #expect(LocalNotificationProjection.isMention(from: mentionInfo))
        #expect(!LocalNotificationProjection.isMention(from: plainInfo))
        // Pre-upgrade notifications carry no bit; only an explicit
        // non-mention is suppressible by a later mentions-only switch.
        #expect(LocalNotificationProjection.isMention(from: [:]))
    }

    @Test func archivedChatKeysFoldOnlyArchivedRowsPerAccount() {
        let rowA = chatListRow(groupIdHex: "group-a", archived: true, title: "A")
        let rowB = chatListRow(groupIdHex: "group-b", archived: false, title: "B")
        let rowC = chatListRow(groupIdHex: "group-c", archived: true, title: "C")

        let keys = NotificationServiceProjection.archivedChatKeys(rowsByAccountRef: [
            "account-1": [rowA, rowB],
            "account-2": [rowC],
        ])

        #expect(keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-1", groupIdHex: "group-a")))
        #expect(keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-2", groupIdHex: "group-c")))
        #expect(!keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-1", groupIdHex: "group-b")))
        // Keys are account-scoped: another account's archive doesn't leak.
        #expect(!keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-1", groupIdHex: "group-c")))
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

private enum NotificationServiceSettingsReadPolicyTestError: Error {
    case unavailable
}

struct ProfileEditViewTests {
    @MainActor
    @Test func profileSaveIsDisabledForInvalidDraft() {
        let viewModel = ProfileEditViewModel()

        viewModel.picture = "not-a-url"
        #expect(viewModel.currentDraft.validationError == .picture)
        #expect(viewModel.invalidPictureMessage == L10n.string("Only public HTTPS image URLs are allowed."))

        viewModel.picture = "https://cdn.example.com/avatar.png"
        #expect(viewModel.currentDraft.validationError == nil)
        #expect(viewModel.invalidPictureMessage == nil)

        viewModel.nip05 = "alice example.com"
        #expect(viewModel.currentDraft.validationError == .nip05)
        #expect(viewModel.invalidNip05Message == L10n.string("Enter a valid NIP-05 address like name@example.com."))

        viewModel.nip05 = "alice@example.com"
        #expect(viewModel.currentDraft.validationError == nil)
        #expect(viewModel.invalidNip05Message == nil)
    }

    @Test func profileMetadataDraftSanitizesEditableFields() throws {
        let draft = ProfileEditMetadataDraft(
            displayName: " Alice\u{202E}\nEvil ",
            about: String(repeating: "a", count: ContentSanitizer.maxAboutLength + 25),
            picture: "",
            nip05: " ALICE@Example.COM ",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)

        #expect(metadata.name == "Alice Evil")
        #expect(metadata.displayName == "Alice Evil")
        #expect(metadata.about?.count == ContentSanitizer.maxAboutLength)
        #expect(metadata.nip05 == "alice@example.com")
    }

    @Test func profilePreservesExistingLud16Verbatim() throws {
        // lud16 is not editable here; whatever the profile already had must
        // round-trip unchanged so a kind:0 replacement never wipes it.
        let draft = ProfileEditMetadataDraft(
            displayName: "Alice",
            about: "",
            picture: "",
            nip05: "",
            preservedLud16: "weird-but-existing"
        )

        #expect(draft.validationError == nil)
        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.picture == nil)
        #expect(metadata.lud16 == "weird-but-existing")
    }

    @Test func profileMetadataDraftRejectsInvalidNip05BeforePublish() {
        let invalidNip05 = ProfileEditMetadataDraft(
            displayName: "", about: "", picture: "", nip05: "alice example.com",
            preservedLud16: nil
        )

        #expect(invalidNip05.validationError == .nip05)
        #expect(invalidNip05.normalizedMetadata == nil)
    }
}

@MainActor
struct ContentSanitizerTests {

    @Test func stripsBidiOverrideFromName() {
        // Trojan-Source-style: an RLO (U+202E) can reverse rendering to spoof.
        let spoofed = "alice\u{202E}evil"
        let safe = ContentSanitizer.displayName(spoofed)
        #expect(safe == "aliceevil")
        #expect(!(safe?.unicodeScalars.contains { $0.value == 0x202E } ?? false))
    }

    @Test func collapsesNewlinesInName() {
        let multiline = "line one\nline two\t\tmore"
        let safe = ContentSanitizer.displayName(multiline)
        #expect(safe == "line one line two more")
    }

    @Test func capsNameLength() {
        let long = String(repeating: "a", count: 500)
        let safe = ContentSanitizer.displayName(long)
        #expect((safe?.count ?? 0) <= ContentSanitizer.maxNameLength)
    }

    @Test func emptyAfterStrippingReturnsNil() {
        #expect(ContentSanitizer.displayName("\u{202E}\u{200B}") == nil)
        #expect(ContentSanitizer.displayName("\u{200D}\u{2060}\u{3164}") == nil)
        #expect(ContentSanitizer.displayName("   ") == nil)
        #expect(ContentSanitizer.displayName(nil) == nil)
    }

    @Test func verticalSeparatorsAreRemovedBeforeBlankLineClamp() {
        #expect(ContentSanitizer.messageBody("hello\u{2028}\u{2029}world") == "helloworld")
        #expect(ContentSanitizer.multilineText("about\u{2028}\u{2029}text") == "abouttext")
    }

    @Test func namesAndReactionsHaveScalarBudgets() {
        let megaCluster = "a" + String(repeating: "\u{0301}", count: 2_000)

        let name = ContentSanitizer.displayName(megaCluster)
        #expect(name?.count == 1)
        #expect((name?.unicodeScalars.count ?? 0) <= ContentSanitizer.maxNameLength * 8)

        let reaction = ContentSanitizer.reactionEmoji(megaCluster)
        #expect(reaction.count == 1)
        #expect(reaction.unicodeScalars.count <= ContentSanitizer.maxReactionLength * 8)
    }

    @Test func relayDisplayLineStripsInvisibleLetterScalars() {
        #expect(ContentSanitizer.relayDisplayLine("relay\u{115F}\u{1160}\u{3164}\u{FFA0}\u{2800}.example", maxLength: 80) == "relay.example")
    }

    @Test func compactSingleLineStripsInvisibleFormatAndBlankScalars() {
        #expect(
            ContentSanitizer.compactSingleLine(
                "before\u{200D}\u{2060}\u{3164}after",
                maxLength: 80
            ) == "beforeafter"
        )
        #expect(ContentSanitizer.compactSingleLine("\u{3164}", maxLength: 80) == nil)
    }

    @Test func imageURLAllowsHttps() {
        #expect(ContentSanitizer.imageURL("https://example.com/a.png") != nil)
        #expect(ContentSanitizer.imageURL("http://example.com/a.png") == nil)
    }

    @Test func imageURLRejectsNonStandardPorts() {
        // A peer URL with an explicit port would drive TLS connections at
        // arbitrary ports on public hosts — a connect/timing oracle.
        #expect(ContentSanitizer.imageURL("https://example.com:443/a.png") != nil)
        #expect(ContentSanitizer.imageURL("https://example.com:1234/a.png") == nil)
        #expect(ContentSanitizer.imageURL("https://example.com:8443/a.png") == nil)
        #expect(ContentSanitizer.imageURL("https://example.com:80/a.png") == nil)
    }

    @Test func imageURLRejectsUserInfo() {
        #expect(ContentSanitizer.imageURL("https://user@example.com/a.png") == nil)
        #expect(ContentSanitizer.imageURL("https://user:password@example.com/a.png") == nil)
    }

    @Test func imageURLRejectsOverLengthStrings() {
        // Peer-controlled fields (kind:0 `picture`, group `avatarUrl`, DuckDuckGo
        // results) are unbounded; reject before parsing past the length cap (#381).
        let cap = ContentSanitizer.maxImageURLLength
        let prefix = "https://example.com/"
        // A well-formed HTTPS URL at exactly the cap is still accepted.
        let atCap = prefix + String(repeating: "a", count: cap - prefix.count)
        #expect(atCap.count == cap)
        #expect(ContentSanitizer.imageURL(atCap) != nil)
        // One character over the cap is rejected outright, even though the URL
        // is otherwise valid (HTTPS, public host).
        let overCap = atCap + "a"
        #expect(overCap.count == cap + 1)
        #expect(ContentSanitizer.imageURL(overCap) == nil)
        let utf8OverCap = prefix + String(repeating: "é", count: cap - prefix.count)
        #expect(utf8OverCap.count == cap)
        #expect(utf8OverCap.utf8.count > cap)
        #expect(ContentSanitizer.imageURL(utf8OverCap) == nil)
        // A multi-megabyte hostile value is rejected without parsing it.
        let huge = prefix + String(repeating: "a", count: 4_000_000)
        #expect(ContentSanitizer.imageURL(huge) == nil)
        // Leading/trailing whitespace is trimmed before the length check, so a
        // valid URL padded with whitespace still passes.
        #expect(ContentSanitizer.imageURL("  https://example.com/a.png  ") != nil)
    }

    @Test func imageURLRejectsDangerousSchemes() {
        #expect(ContentSanitizer.imageURL("data:image/png;base64,AAAA") == nil)
        #expect(ContentSanitizer.imageURL("file:///etc/passwd") == nil)
        #expect(ContentSanitizer.imageURL("javascript:alert(1)") == nil)
        #expect(ContentSanitizer.imageURL("ftp://example.com/x") == nil)
        #expect(ContentSanitizer.imageURL("https://") == nil) // no host
        #expect(ContentSanitizer.imageURL("not a url") == nil)
    }

    @Test func imageURLRejectsPrivateAndLoopbackHosts() {
        #expect(ContentSanitizer.imageURL("https://localhost/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://127.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://0.0.0.0/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://0.1.2.3/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://10.1.2.3/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://172.16.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://172.31.255.255/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://192.168.1.10/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://169.254.169.254/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[::]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[0:0:0:0:0:0:0:0]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::1]/avatar.png") == nil)

        #expect(ContentSanitizer.imageURL("https://172.32.0.1/avatar.png") != nil)
    }

    @Test func imageURLRejectsSharedAddressSpaceAndOtherReservedIPv4() {
        // RFC 6598 Carrier-Grade-NAT / shared address space (100.64.0.0/10).
        #expect(ContentSanitizer.imageURL("https://100.64.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://100.64.0.0/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://100.100.50.25/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://100.127.255.255/avatar.png") == nil)
        // RFC 6890 IETF protocol assignments (192.0.0.0/24).
        #expect(ContentSanitizer.imageURL("https://192.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://192.0.0.255/avatar.png") == nil)
        // Multicast (224.0.0.0/4) and reserved/future-use (240.0.0.0/4).
        #expect(ContentSanitizer.imageURL("https://224.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://239.255.255.255/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://240.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://255.255.255.255/avatar.png") == nil)

        // Boundaries just outside the blocked ranges remain reachable.
        #expect(ContentSanitizer.imageURL("https://100.63.255.255/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://100.128.0.1/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://192.0.1.1/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://223.255.255.255/avatar.png") != nil)
    }

    @Test func imageURLRejectsLegacyIPv4LiteralBypasses() {
        #expect(ContentSanitizer.imageURL("https://127.0.0.1./avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://2130706433/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://0x7f000001/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://017700000001/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://127.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://012.0.0.1/avatar.png") == nil)
    }

    @Test func imageURLRejectsIPv4MappedIPv6PrivateAndLoopbackHosts() {
        #expect(ContentSanitizer.imageURL("https://[::ffff:127.0.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:10.1.2.3]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:172.16.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:192.168.1.10]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:c0a8:010a]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[0:0:0:0:0:ffff:169.254.169.254]/latest/meta-data/") == nil)

        #expect(ContentSanitizer.imageURL("https://[::ffff:8.8.8.8]/avatar.png") != nil)
    }

    @Test func imageURLRejectsIPv4CompatibleIPv6PrivateAndLoopbackHosts() {
        #expect(ContentSanitizer.imageURL("https://[::127.0.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::10.1.2.3]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::172.16.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::192.168.1.10]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::169.254.169.254]/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[0:0:0:0:0:0:c0a8:010a]/avatar.png") == nil)

        #expect(ContentSanitizer.imageURL("https://[::8.8.8.8]/avatar.png") != nil)
    }

    @Test func imageURLRejectsSIITAndNAT64IPv4Embeddings() {
        #expect(ContentSanitizer.imageURL("https://[::ffff:0:127.0.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:0:169.254.169.254]/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[64:ff9b::a9fe:a9fe]/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[64:ff9b::127.0.0.1]/avatar.png") == nil)

        #expect(ContentSanitizer.imageURL("https://[::ffff:0:8.8.8.8]/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://[64:ff9b::808:808]/avatar.png") != nil)
    }

    @Test func profileAddressNormalizesSimpleAddressFields() {
        #expect(ContentSanitizer.profileAddress(" Alice+Tips@Example.COM ") == "alice+tips@example.com")
        #expect(ContentSanitizer.profileAddress("alice@example.com") == "alice@example.com")
    }

    @Test func profileAddressRejectsMalformedOrOversizedValues() {
        #expect(ContentSanitizer.profileAddress("alice") == nil)
        #expect(ContentSanitizer.profileAddress("alice@localhost") == nil)
        #expect(ContentSanitizer.profileAddress("alice@-example.com") == nil)
        #expect(ContentSanitizer.profileAddress("alice@example-.com") == nil)
        #expect(ContentSanitizer.profileAddress("alice@exa_mple.com") == nil)
        #expect(ContentSanitizer.profileAddress("a b@example.com") == nil)
        #expect(ContentSanitizer.profileAddress(String(repeating: "a", count: 65) + "@example.com") == nil)
        #expect(ContentSanitizer.profileAddress("alice@" + String(repeating: "a", count: 250) + ".com") == nil)
    }

    @Test func profileAddressRejectsIPLiteralAndNumericDomains() {
        #expect(ContentSanitizer.profileAddress("alice@127.0.0.1") == nil)
        #expect(ContentSanitizer.profileAddress("bob@10.0.0.1") == nil)
        #expect(ContentSanitizer.profileAddress("x@169.254.169.254") == nil)
        #expect(ContentSanitizer.profileAddress("alice@8.8.8.8") == nil)
        #expect(ContentSanitizer.profileAddress("alice@0x7f.0.0.1") == nil)
        #expect(ContentSanitizer.profileAddress("alice@123.456") == nil)
        #expect(ContentSanitizer.profileAddress("alice@example.123") == nil)
    }

    // MARK: - Message bodies

    @Test func messageBodyStripsBidiButKeepsNewlines() {
        let raw = "first line\u{202E}spoof\nsecond line"
        let safe = ContentSanitizer.messageBody(raw)
        #expect(!safe.unicodeScalars.contains { $0.value == 0x202E })
        #expect(safe.contains("\n"))            // newline preserved
        #expect(safe == "first linespoof\nsecond line")
    }

    @Test func messageBodyClampsBlankLineFlooding() {
        let raw = "top\n\n\n\n\n\n\n\nbottom"
        let safe = ContentSanitizer.messageBody(raw)
        #expect(safe == "top\n\nbottom")        // 3+ blank lines → 2
    }

    @Test func messageBodyCapsLength() {
        let raw = String(repeating: "x", count: ContentSanitizer.maxMessageLength + 500)
        #expect(ContentSanitizer.messageBody(raw).count == ContentSanitizer.maxMessageLength)
    }

    @Test func messageBodyTrimsOuterWhitespace() {
        #expect(ContentSanitizer.messageBody("  \n hello \n  ") == "hello")
    }

    // MARK: - Group names

    @Test func groupNameSingleLinesAndStripsBidi() {
        let raw = "Secret\u{202E}evil\nClub"
        let safe = ContentSanitizer.groupName(raw)
        #expect(safe == "Secretevil Club")      // bidi gone, newline → space
    }

    @Test func groupNameCaps() {
        let raw = String(repeating: "g", count: 400)
        #expect((ContentSanitizer.groupName(raw)?.count ?? 0) <= ContentSanitizer.maxGroupNameLength)
    }

    @Test func groupNameEmptyIsNil() {
        #expect(ContentSanitizer.groupName("") == nil)
        #expect(ContentSanitizer.groupName("\u{202E}\u{200B}") == nil)
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

    @Test func resolvedGroupSanitizesNameOnceForTitleAvatarAndSeed() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let other = hex("22")
        var sanitizeCalls = 0
        let display = GroupDisplay.resolve(
            group: group(name: ""),
            otherMember: other,
            memberCount: 2,
            sanitizeGroupName: { raw in
                sanitizeCalls += 1
                return ContentSanitizer.groupName(raw)
            }
        )

        let title = GroupDisplay.title(for: display, appState: appState)
        let avatar = GroupDisplay.avatarURL(for: display, appState: appState)
        let seed = GroupDisplay.avatarSeed(for: display)

        #expect(title == appState.shortNpub(forAccountIdHex: other))
        #expect(avatar == nil)
        #expect(seed == other)
        #expect(sanitizeCalls == 1)
    }

    @Test func namedGroupTitleWinsOverMemberRules() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: "  Project Room  "),
            otherMember: hex("22"),
            memberCount: 2
        )
        let title = GroupDisplay.title(for: display, appState: appState)

        #expect(title == "Project Room")
    }

    @Test func unnamedMultiPersonGroupShowsCount() throws {
        try withAppLanguage(.english) {
            let appState = AppState(client: try MarmotClient.testClient())
            let display = GroupDisplay.resolve(
                group: group(name: ""),
                otherMember: hex("22"),
                memberCount: 3
            )
            let title = GroupDisplay.title(for: display, appState: appState)

            #expect(title == "3 person group")
        }
    }

    @Test func unnamedTwoPersonGroupFallsBackToOtherIdentity() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let other = hex("22")
        let display = GroupDisplay.resolve(
            group: group(name: ""),
            otherMember: other,
            memberCount: 2
        )

        let title = GroupDisplay.title(for: display, appState: appState)

        // With no known profile for the peer, a 2-person group resolves to the
        // other member's npub. Name resolution is covered by
        // ResolvedDisplayNameTests now that iOS reads profiles from the binding.
        #expect(title == appState.shortNpub(forAccountIdHex: other))
    }

    @Test func unnamedTwoPersonGroupFallsBackToNpub() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: ""),
            otherMember: hex("22"),
            memberCount: 2
        )
        let title = GroupDisplay.title(for: display, appState: appState)

        #expect(title.hasPrefix("npub1"))
    }

    @Test func groupAvatarURLWinsOverDirectMessageFallback() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: "", avatarUrl: "https://cdn.example.com/group.png"),
            otherMember: hex("22"),
            memberCount: 2
        )
        let avatar = GroupDisplay.avatarURL(for: display, appState: appState)

        #expect(avatar?.absoluteString == "https://cdn.example.com/group.png")
    }

    @Test func groupAvatarURLRejectsUnsafeGroupURL() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: "Unsafe", avatarUrl: "http://127.0.0.1/group.png"),
            otherMember: hex("22"),
            memberCount: 3
        )
        let avatar = GroupDisplay.avatarURL(for: display, appState: appState)

        #expect(avatar == nil)
    }
}

private actor ConcurrentLoadProbe {
    private var active = 0

    func begin() -> Int {
        active += 1
        return active
    }

    func end() {
        active -= 1
    }
}

struct GroupImageSearchTests {
    @Test func groupImageThumbnailLoadsStayWithinConcurrencyLimit() async {
        let limiter = CancellableLoadLimiter(maximumConcurrentLoads: 4)
        let probe = ConcurrentLoadProbe()

        let peak = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    guard let reservation = await limiter.acquire() else { return 0 }
                    let active = await probe.begin()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await probe.end()
                    await limiter.release(reservation)
                    return active
                }
            }
            var peak = 0
            for await active in group {
                peak = max(peak, active)
            }
            return peak
        }

        #expect(peak == 4)
    }

    @Test func cancelledThumbnailWaiterResumesAndPreservesPermits() async throws {
        let limiter = CancellableLoadLimiter(maximumConcurrentLoads: 1)
        let first = try #require(await limiter.acquire())
        let queued = Task { await limiter.acquire() }

        while await limiter.snapshot().waiting == 0 {
            await Task.yield()
        }
        queued.cancel()

        #expect(await queued.value == nil)
        #expect(await limiter.snapshot().waiting == 0)
        await limiter.release(first)

        let next = try #require(await limiter.acquire())
        #expect(await limiter.snapshot().active == 1)
        await limiter.release(next)
        // A duplicate release must not mint an extra permit.
        await limiter.release(next)
        #expect(await limiter.snapshot().active == 0)
    }

    @Test func duckDuckGoRequestsCarryBrowserIdentityAndSameOriginReferer() throws {
        let apiURL = try #require(URL(string: "https://duckduckgo.com/i.js?q=cats"))
        let referer = try #require(URL(string: "https://duckduckgo.com/"))

        let request = DuckDuckGoImageSearchClient.request(for: apiURL, referer: referer)

        #expect(request.value(forHTTPHeaderField: "Referer") == "https://duckduckgo.com/")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mobile/15E148 Safari/604.1") == true)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
    }

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
        #expect(results.first?.dimensionsLabel == DuckDuckGoImageSearchClient.dimensionsLabel(
            width: 640,
            height: 480
        ))
    }

    @Test func groupImageDimensionsLabelLocalizesDigits() {
        let locale = Locale(identifier: "ar_EG")

        #expect(DuckDuckGoImageSearchClient.dimensionsLabel(
            width: 640,
            height: 480,
            locale: locale
        ) == L10n.formatted(
            "%@ × %@",
            arguments: [
                LocalizedNumberLabel.decimal(640, locale: locale),
                LocalizedNumberLabel.decimal(480, locale: locale)
            ],
            locale: locale
        ))
        #expect(DuckDuckGoImageSearchClient.dimensionsLabel(
            width: 640,
            height: 480,
            locale: locale
        ) != "640x480")
    }

    @Test func duckDuckGoResultDecoderCapsResultCount() throws {
        let entryCount = DuckDuckGoImageSearchClient.maximumResultCount + 40
        let entries = (0..<entryCount).map { index in
            """
            {
              "title": "Result \(index)",
              "image": "https://images.example.com/\(index).jpg",
              "thumbnail": "https://images.example.com/thumb-\(index).jpg",
              "url": "https://example.com/page/\(index)",
              "width": 640,
              "height": 480
            }
            """
        }.joined(separator: ",\n")
        let json = "{ \"results\": [\n\(entries)\n] }"

        let results = try DuckDuckGoImageSearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == DuckDuckGoImageSearchClient.maximumResultCount)
    }

    @Test func duckDuckGoResultDecoderSanitizesAndBoundsFallbackTitle() throws {
        let unsafeTitle = "  Mirror\nHost \u{202E}\u{200B}" + String(
            repeating: "x",
            count: DuckDuckGoImageSearchClient.maximumResultTitleLength + 20
        )
        let resultObject: [String: Any] = [
            "title": unsafeTitle,
            "image": "https://images.example.com/a.jpg",
            "thumbnail": "https://images.example.com/thumb-a.jpg",
            "url": "http://example.com/page",
            "width": 640,
            "height": 480
        ]
        let data = try JSONSerialization.data(withJSONObject: ["results": [resultObject]])

        let results = try DuckDuckGoImageSearchClient.decodeResults(from: data)
        let result = try #require(results.first)

        #expect(result.sourceHost == nil)
        #expect(result.title.count == DuckDuckGoImageSearchClient.maximumResultTitleLength)
        #expect(result.title.hasPrefix("Mirror Host"))
        #expect(!result.title.contains("\n"))
        #expect(!result.title.contains("\u{202E}"))
        #expect(!result.title.contains("\u{200B}"))
    }

    @Test func groupImageDraftMapsToInitialEncryptedImageInput() {
        let draft = GroupImageUploadDraft(
            data: Data([1, 2, 3]),
            mediaType: "image/jpeg",
            sourceURL: "https://images.example/group.jpg",
            dim: "640x480",
            thumbhash: "thumb"
        )

        #expect(draft.initialImage.plaintext == draft.data)
        #expect(draft.initialImage.mediaType == draft.mediaType)
        #expect(draft.initialImage.sourceUrl == nil)
        #expect(draft.initialImage.dim == draft.dim)
        #expect(draft.initialImage.thumbhash == draft.thumbhash)
    }

    @Test func groupImageDraftProcessorNormalizesDeviceImageForUpload() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }

        let draft = try await GroupImageDraftProcessor.prepare(
            data: png,
            fileName: "group.png",
            typeIdentifier: "public.png"
        )

        #expect(!draft.data.isEmpty)
        #expect(draft.mediaType == "image/jpeg")
        let prepared = try #require(UIImage(data: draft.data)?.cgImage)
        #expect(draft.dim == "\(prepared.width)x\(prepared.height)")
        #expect(draft.initialImage.sourceUrl == nil)
    }

    @Test func groupImageSearchClaimsInFlightGuardBeforeStartingTask() {
        #expect(GroupImageURLSheet.preparedSearchQuery(
            "  marmot  ",
            isSearching: false,
            isSaving: false
        ) == "marmot")
        #expect(GroupImageURLSheet.preparedSearchQuery(
            "   ",
            isSearching: false,
            isSaving: false
        ) == nil)
        #expect(GroupImageURLSheet.preparedSearchQuery(
            "marmot",
            isSearching: true,
            isSaving: false
        ) == nil)
        #expect(GroupImageURLSheet.preparedSearchQuery(
            "marmot",
            isSearching: false,
            isSaving: true
        ) == nil)
    }

    @Test func groupImageSearchDiscardsCancelledOrStaleCompletions() {
        #expect(GroupImageURLSheet.shouldApplySearchCompletion(
            issuedQuery: "marmot",
            currentQuery: "  marmot  ",
            isCancelled: false
        ))
        #expect(!GroupImageURLSheet.shouldApplySearchCompletion(
            issuedQuery: "marmot",
            currentQuery: "stoat",
            isCancelled: false
        ))
        #expect(!GroupImageURLSheet.shouldApplySearchCompletion(
            issuedQuery: "marmot",
            currentQuery: "   ",
            isCancelled: false
        ))
        #expect(!GroupImageURLSheet.shouldApplySearchCompletion(
            issuedQuery: "marmot",
            currentQuery: "marmot",
            isCancelled: true
        ))
    }

}

struct DeepLinkTests {

    @Test func generatedURLKeepsDelimiterCharactersInsidePathComponent() {
        let profileURL = DeepLink.profile(npub: "npub?query#fragment/child").url
        let chatURL = DeepLink.chat(groupIdHex: "ABC?query#fragment/child").url
        let expectedScheme = DeepLink.canonicalScheme

        #expect(expectedScheme == "marmot")
        #expect(profileURL.absoluteString == "\(expectedScheme)://profile/npub%3Fquery%23fragment%2Fchild")
        #expect(profileURL.query == nil)
        #expect(profileURL.fragment == nil)

        #expect(chatURL.absoluteString == "\(expectedScheme)://chat/ABC%3Fquery%23fragment%2Fchild")
        #expect(chatURL.query == nil)
        #expect(chatURL.fragment == nil)
    }

    @Test func legacyWhiteNoiseProfileLinksStillParse() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        for scheme in ["whitenoise", "whitenoise-staging"] {
            #expect(DeepLink.parse(string: "\(scheme)://profile/\(npub)") == .profile(npub: npub))
        }
    }

    @Test func darkmatterProfileLinksDoNotParse() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        #expect(DeepLink.parse(string: "darkmatter://profile/\(npub)") == nil)
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
        // A named group (not a DM) keeps its member-count subtitle.
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "Project Room", id: hex("aa")),
            initialTitle: nil,
            initialMemberCount: 2
        )

        #expect(chrome.title == "Project Room")
        #expect(chrome.subtitle == "2 members")
    }

    @Test func initialChromeHidesMemberSubtitleForDirectMessageTitledByContactName() {
        // A DM's title hint is the contact's name; it must still be detected as
        // a DM (no member count) from the empty group name.
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "", id: hex("aa")),
            initialTitle: "Alice",
            initialMemberCount: 2
        )

        #expect(chrome.title == "Alice")
        #expect(chrome.subtitle == nil)
    }

    @Test func initialChromeHidesMemberSubtitleForDirectMessage() {
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "", id: hex("aa")),
            initialTitle: nil,
            initialMemberCount: 2
        )

        // An unnamed 2-person chat is a DM: no member-count subtitle.
        #expect(chrome.subtitle == nil)
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

        // The initial-member-count hint drives the 2-person title before the
        // roster loads; with no known profile the title is the peer's npub. A DM
        // shows just the contact's name — no member-count subtitle.
        #expect(viewModel.displayTitle == appState.shortNpub(forAccountIdHex: other))
        #expect(viewModel.displaySubtitle == nil)
    }

    @Test func headerSecondaryShowsConnectingWhileRuntimeWarmsUp() {
        #expect(
            ConversationHeaderSecondary.resolve(isRuntimeWarmingUp: true, subtitle: "2 members")
                == .connecting
        )
    }

    @Test func headerSecondaryShowsSubtitleOnceWarmedUp() {
        #expect(
            ConversationHeaderSecondary.resolve(isRuntimeWarmingUp: false, subtitle: "2 members")
                == .subtitle("2 members")
        )
        #expect(
            ConversationHeaderSecondary.resolve(isRuntimeWarmingUp: false, subtitle: nil)
                == .subtitle(nil)
        )
    }

    @Test func emptyStateLabelsConnectingWhileWarmingUpInsteadOfBareSpinner() {
        #expect(
            ConversationEmptyState.resolve(hasError: false, isLoading: true, isRuntimeWarmingUp: true)
                == .connecting
        )
        #expect(
            ConversationEmptyState.resolve(hasError: false, isLoading: true, isRuntimeWarmingUp: false)
                == .loading
        )
    }

    @Test func emptyStatePrefersErrorThenFallsBackToEmpty() {
        // Error wins even mid-warm-up so a failed load still surfaces Retry.
        #expect(
            ConversationEmptyState.resolve(hasError: true, isLoading: true, isRuntimeWarmingUp: true)
                == .error
        )
        #expect(
            ConversationEmptyState.resolve(hasError: false, isLoading: false, isRuntimeWarmingUp: false)
                == .empty
        )
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

    @Test func directPeerProjectionRequiresExactlySelfAndOneOtherMember() {
        let me = hex("01")
        let other = hex("02")

        #expect(ChatsListViewModel.directPeerAccountId(
            memberIdsHex: [me.uppercased(), other],
            myAccountIdHex: me
        ) == other)
        #expect(ChatsListViewModel.directPeerAccountId(
            memberIdsHex: [me, other, hex("03")],
            myAccountIdHex: me
        ) == nil)
        #expect(ChatsListViewModel.directPeerAccountId(
            memberIdsHex: [other, hex("03")],
            myAccountIdHex: me
        ) == nil)
    }

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

    @Test func projectedRowsUseDurableActivityOrderingAfterPreviewPruning() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let prunedButNewer = chatListRow(
            groupIdHex: hex("a1"),
            title: "Pruned",
            activitySortAt: 30,
            updatedAt: 40
        )
        let previewButOlder = chatListRow(
            groupIdHex: hex("a2"),
            title: "Preview",
            lastMessage: chatListPreview(messageIdHex: hex("b2"), plaintext: "visible", timelineAt: 20),
            activitySortAt: 20,
            updatedAt: 50
        )

        viewModel.applyChatListSnapshot([previewButOlder, prunedButNewer])

        #expect(viewModel.items.map(\.id) == [prunedButNewer.groupIdHex, previewButOlder.groupIdHex])
    }

    @Test func pinnedRowsLeadInManualPositionOrderBeforeRecentChats() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let firstPin = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First pin",
            activitySortAt: 10
        )
        let secondPin = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second pin",
            activitySortAt: 20
        )
        let recent = chatListRow(
            groupIdHex: hex("a3"),
            title: "Recent",
            activitySortAt: 100
        )

        viewModel.applyChatListSnapshot([recent, secondPin, firstPin])

        #expect(viewModel.items.map(\.id) == [
            firstPin.groupIdHex,
            secondPin.groupIdHex,
            recent.groupIdHex,
        ])
        #expect(viewModel.items.first?.isPinned == true)
    }

    @Test func authoritativePinOrderReordersPinsAndClearsPinsOmittedFromState() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let first = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First",
            activitySortAt: 10
        )
        let second = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second",
            activitySortAt: 20
        )
        let newlyPinned = chatListRow(
            groupIdHex: hex("a3"),
            title: "Third",
            activitySortAt: 30
        )
        viewModel.applyChatListSnapshot([first, second, newlyPinned])

        viewModel.applyPinnedOrder([
            newlyPinned.groupIdHex,
            second.groupIdHex,
        ])

        #expect(viewModel.items.map(\.id) == [
            newlyPinned.groupIdHex,
            second.groupIdHex,
            first.groupIdHex,
        ])
        #expect(viewModel.item(groupIdHex: newlyPinned.groupIdHex)?.row.pinnedPosition == 0)
        #expect(viewModel.item(groupIdHex: second.groupIdHex)?.row.pinnedPosition == 1)
        #expect(viewModel.item(groupIdHex: first.groupIdHex)?.isPinned == false)
        #expect(viewModel.item(groupIdHex: first.groupIdHex)?.row.pinnedPosition == nil)
    }

    @Test func pinOrderSnapshotWaitsForSwipeDrawerTransitionToFinish() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let first = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First"
        )
        let second = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second"
        )
        viewModel.applyChatListSnapshot([first, second])

        var reorderedFirst = first
        reorderedFirst.pinnedPosition = 1
        var reorderedSecond = second
        reorderedSecond.pinnedPosition = 0
        let transitionID = viewModel.beginPinOrderUITransition()
        viewModel.applyPresentedSnapshot(presentedChatSnapshot([reorderedSecond, reorderedFirst]))

        #expect(viewModel.items.map(\.id) == [first.groupIdHex, second.groupIdHex])

        let applied = viewModel.finishPinOrderUITransition(
            transitionID: transitionID,
            orderedGroupIds: [second.groupIdHex, first.groupIdHex]
        )

        #expect(applied)
        #expect(viewModel.items.map(\.id) == [second.groupIdHex, first.groupIdHex])
    }

    @Test func pinOrderSubscriptionSnapshotAtomicallyReplacesRowsAndPendingUpdates() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let first = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First",
            updatedAt: 10
        )
        let second = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second",
            updatedAt: 10
        )
        let removed = chatListRow(groupIdHex: hex("a3"), title: "Removed", updatedAt: 10)
        viewModel.applyChatListSnapshot([first, second, removed])
        viewModel.enqueueChatListRowUpdate(chatListRow(
            groupIdHex: first.groupIdHex,
            pinned: true,
            pinnedPosition: 0,
            title: "Stale pending",
            updatedAt: 20
        ))

        let reorderedFirst = chatListRow(
            groupIdHex: first.groupIdHex,
            pinned: true,
            pinnedPosition: 1,
            title: "First",
            updatedAt: 10
        )
        let reorderedSecond = chatListRow(
            groupIdHex: second.groupIdHex,
            pinned: true,
            pinnedPosition: 0,
            title: "Second",
            updatedAt: 10
        )
        viewModel.applyPresentedSnapshot(presentedChatSnapshot([reorderedFirst, reorderedSecond]))

        #expect(viewModel.items.map(\.id) == [second.groupIdHex, first.groupIdHex])
        #expect(viewModel.items.last?.title == "First")
        #expect(viewModel.item(groupIdHex: removed.groupIdHex) == nil)
    }

    @Test func successfulSnapshotClearsPreviousLoadError() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: hex("a1"), title: "Recovered", updatedAt: 10)

        viewModel.setLoadErrorForTesting("Couldn't load chats")
        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.loadError == nil)
        #expect(viewModel.items.map(\.id) == [row.groupIdHex])
    }

    @Test func presentedSnapshotReplacesQueuedRowEvenWithOlderTimestamp() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let groupId = hex("a8")
        let stale = chatListRow(
            groupIdHex: groupId,
            title: "Stale",
            unreadCount: 1,
            updatedAt: 10
        )
        let fresh = chatListRow(
            groupIdHex: groupId,
            title: "Fresh",
            unreadCount: 4,
            updatedAt: 20
        )

        viewModel.enqueueChatListRowUpdate(fresh)
        viewModel.applyPresentedSnapshot(presentedChatSnapshot([stale]))

        #expect(viewModel.items.first?.title == "Stale")
        #expect(viewModel.items.first?.unreadCount == 1)
    }

    @Test func visibleRowsRevisionAdvancesOnlyForPublishedCollectionChanges() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: hex("a9"), title: "Stable", updatedAt: 10)

        #expect(viewModel.visibleRowsRevision == 0)
        viewModel.applyChatListSnapshot([row])
        #expect(viewModel.visibleRowsRevision == 1)
        viewModel.applyChatListSnapshot([row])
        #expect(viewModel.visibleRowsRevision == 1)
    }

    @Test func itemByGroupIdAccessorResolvesActiveAndArchivedRowsAndMissesUnknownId() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let active = chatListRow(groupIdHex: hex("a1"), title: "Active", updatedAt: 10)
        let archived = chatListRow(groupIdHex: hex("a2"), archived: true, title: "Archived", updatedAt: 20)

        viewModel.applyChatListSnapshot([active, archived])

        // The accessor resolves a row by id regardless of which published
        // array it lands in, and returns nil for an unknown id — matching the
        // old `(items + archivedItems).first(where:)` scan it replaces.
        #expect(viewModel.item(groupIdHex: active.groupIdHex)?.id == active.groupIdHex)
        #expect(viewModel.item(groupIdHex: active.groupIdHex)?.isArchived == false)
        #expect(viewModel.item(groupIdHex: archived.groupIdHex)?.id == archived.groupIdHex)
        #expect(viewModel.item(groupIdHex: archived.groupIdHex)?.isArchived == true)
        #expect(viewModel.item(groupIdHex: hex("ff")) == nil)
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

        let item = ChatsListViewModel.Item(row: unsafe, avatarURL: nil, title: "Unsafe")

        #expect(item.previewText == "hello there")
    }

    @Test func itemAvatarURLUsesProjectedGroupAvatarURL() throws {
        let item = ChatsListViewModel.Item(
            row: chatListRow(groupIdHex: hex("d4"), title: "Avatar"),
            avatarURL: URL(string: "https://cdn.example.com/group.png"),
            title: "Avatar"
        )

        #expect(item.avatarURL?.absoluteString == "https://cdn.example.com/group.png")
    }

    @Test func chatRowsDoNotFetchAvatarsBeforeInviteConfirmation() throws {
        let avatarURL = try #require(URL(string: "https://cdn.example.com/group.png"))

        #expect(ChatRow.automaticAvatarURL(avatarURL, pendingConfirmation: true) == nil)
        #expect(
            ChatRow.automaticAvatarURL(avatarURL, pendingConfirmation: false) == avatarURL
        )
    }

    @Test func itemSurfacesUnreadMentionProjection() throws {
        let item = ChatsListViewModel.Item(
            row: chatListRow(
                groupIdHex: hex("de"),
                title: "Mentions",
                unreadCount: 4,
                unreadMentionCount: 2,
                unreadMention: true
            ),
            avatarURL: nil,
            title: "Mentions"
        )

        #expect(item.hasUnreadMention)
        #expect(item.unreadMentionCount == 2)
    }

    @Test func draftPreviewOverridesTheLastMessageAndParticipatesInSearch() {
        let item = ChatsListViewModel.Item(
            row: chatListRow(
                groupIdHex: hex("df"),
                title: "Drafts",
                lastMessage: chatListPreview(
                    messageIdHex: hex("e0"),
                    plaintext: "older message",
                    timelineAt: 10
                )
            ),
            avatarURL: nil,
            title: "Drafts",
            draftSummary: MessageDraftSummaryFfi(
                groupIdHex: hex("df"),
                content: "  Follow up\nwith Alice  ",
                replyToMessageIdHex: nil,
                mediaAttachments: [],
                createdAtMs: 1,
                updatedAtMs: 1
            )
        )

        #expect(item.draftPreview == "Follow up with Alice")
        #expect(item.searchHaystack.contains("follow up with alice"))
        #expect(ChatRow.previewPresentation(
            for: item,
            activeAccountIdHex: nil,
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(
            prefix: nil,
            body: L10n.formatted("Draft: %@", "Follow up with Alice")
        ))
    }

    @MainActor
    @Test func chatListDisplayTitleUsesGroupDisplayForUnnamedDirectMessage() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let me = hex("11")
        let other = hex("22")
        let groupId = hex("aa")
        let row = chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: ""
        )
        let details = GroupDetailsFfi(
            group: group(name: "", id: groupId),
            members: [
                groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                groupMember(memberIdHex: other, isAdmin: false, isSelf: false),
            ]
        )

        let title = ChatsListViewModel.displayTitle(
            for: row,
            details: details,
            appState: appState
        )

        #expect(title == appState.shortNpub(forAccountIdHex: other))
    }

    @MainActor
    @Test func chatListDisplayUsesPeerAvatarSeedForUnnamedDirectMessage() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let me = hex("31")
        let other = hex("32")
        let groupId = hex("ab")
        let row = chatListRow(groupIdHex: groupId, title: groupId, groupName: "")
        let details = GroupDetailsFfi(
            group: group(name: "", id: groupId),
            members: [
                groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                groupMember(memberIdHex: other, isAdmin: false, isSelf: false),
            ]
        )

        let display = ChatsListViewModel.display(for: row, details: details, appState: appState)

        #expect(display.avatarSeed == other)
        #expect(display.avatarSeed != groupId)
    }

    @Test func cachedDirectPeerResolvesAnUnnamedDirectRowWithoutGroupDetails() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let other = hex("33")
        let groupId = hex("ac")
        let avatar = "https://cdn.example.com/alice.png"
        appState.profileStore.profileProjectionCache[other] = ProfileDisplayProjection(
            profile: UserProfileMetadataFfi(
                name: nil,
                displayName: "Alice",
                about: nil,
                picture: avatar,
                banner: nil,
                nip05: nil,
                lud16: nil
            ),
            projectedName: nil,
            localAccountLabel: nil
        )
        let row = chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: "",
            conversationKind: .direct
        )

        let display = ChatsListViewModel.display(
            for: row,
            details: nil,
            appState: appState,
            cachedDirectPeerAccountId: other
        )

        #expect(display.title == "Alice")
        #expect(display.avatarURL?.absoluteString == avatar)
        #expect(display.avatarSeed == other)
        #expect(display.isDirectMessage == true)
        #expect(display.directPeerAccountIdHex == other)
    }

    @Test func unresolvedDirectRowNeverExposesItsInternalGroupHexAsAUserIdentity() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let groupId = hex("ad")
        let row = chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: "",
            conversationKind: .direct
        )

        let display = ChatsListViewModel.display(for: row, details: nil, appState: appState)

        #expect(display.title == L10n.string("Direct message"))
        #expect(display.title != IdentityFormatter.short(groupId))
        #expect(display.directPeerAccountIdHex == nil)
    }

    @Test func directPeerCacheIsAccountScopedBoundedAndKeepsRecentDirectRows() {
        let olderDirect = chatListRow(
            groupIdHex: hex("b1"),
            title: "Older direct",
            activitySortAt: 10,
            conversationKind: .direct
        )
        let newerDirect = chatListRow(
            groupIdHex: hex("b2"),
            title: "Newer direct",
            activitySortAt: 20,
            conversationKind: .direct
        )
        let group = chatListRow(
            groupIdHex: hex("b3"),
            title: "Group",
            activitySortAt: 30,
            conversationKind: .group
        )
        var cache = ChatListDirectPeerCache(maxAccounts: 2, maxGroupsPerAccount: 1)

        cache.store(
            accountRef: "alice",
            peersByGroupId: [
                olderDirect.groupIdHex: hex("41"),
                newerDirect.groupIdHex: hex("42"),
                group.groupIdHex: hex("43"),
            ],
            rowsByGroupId: [
                olderDirect.groupIdHex: olderDirect,
                newerDirect.groupIdHex: newerDirect,
                group.groupIdHex: group,
            ]
        )

        #expect(cache.restore(accountRef: "bob").isEmpty)
        #expect(cache.restore(accountRef: "alice") == [newerDirect.groupIdHex: hex("42")])
    }

    @Test func emptyPartialBindDoesNotEraseRetainedDirectPeerMappings() {
        let row = chatListRow(
            groupIdHex: hex("b4"),
            title: "Direct",
            activitySortAt: 20,
            conversationKind: .direct
        )
        let peer = hex("44")
        var cache = ChatListDirectPeerCache()
        cache.store(
            accountRef: "alice",
            peersByGroupId: [row.groupIdHex: peer],
            rowsByGroupId: [row.groupIdHex: row]
        )

        cache.store(accountRef: "alice", peersByGroupId: [:], rowsByGroupId: [:])

        #expect(cache.restore(accountRef: "alice") == [row.groupIdHex: peer])
    }

    @Test func chatListEnrichmentPrioritizesPinnedThenRecentVisibleRows() {
        let firstPin = chatListRow(
            groupIdHex: hex("b5"),
            pinned: true,
            pinnedPosition: 0,
            title: "First pin",
            activitySortAt: 1
        )
        let secondPin = chatListRow(
            groupIdHex: hex("b6"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second pin",
            activitySortAt: 100
        )
        let recent = chatListRow(
            groupIdHex: hex("b7"),
            title: "Recent",
            activitySortAt: 50
        )
        let older = chatListRow(
            groupIdHex: hex("b8"),
            title: "Older",
            activitySortAt: 10
        )
        let rows = [firstPin, secondPin, recent, older]
        let rowsByGroupId = Dictionary(uniqueKeysWithValues: rows.map { ($0.groupIdHex, $0) })

        let prioritized = ChatsListViewModel.prioritizedEnrichmentGroupIds(
            Set(rowsByGroupId.keys),
            rowsByGroupId: rowsByGroupId
        )

        #expect(prioritized == rows.map(\.groupIdHex))
    }

    @Test func itemAvatarURLRejectsUnsafeProjectedGroupAvatarURL() throws {
        let item = ChatsListViewModel.Item(
            row: chatListRow(groupIdHex: hex("d5"), title: "Unsafe Avatar"),
            avatarURL: nil,
            title: "Unsafe Avatar"
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

    @Test func localGroupChangeRefreshesCachedGroupDetailsDisplay() throws {
        let groupId = hex("d8")
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: groupId, title: groupId, groupName: "")
        viewModel.applyChatListSnapshot([row])
        viewModel.seedGroupDetailsCacheForTesting(GroupDetailsFfi(
            group: group(name: "Old name", id: groupId, avatarUrl: "https://cdn.example.com/old.png"),
            members: [groupMember(memberIdHex: hex("11"), isAdmin: true, isSelf: true)]
        ))

        viewModel.applyLocalGroupChange(group(
            name: "New name",
            id: groupId,
            avatarUrl: "https://cdn.example.com/new.png"
        ))

        #expect(viewModel.items.first?.title == "New name")
        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/new.png")
    }

    @Test func chatListRowRefreshesCachedGroupDetailsDisplay() throws {
        let groupId = hex("d9")
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let oldRow = chatListRow(
            groupIdHex: groupId,
            title: "Old name",
            groupName: "Old name",
            avatarUrl: "https://cdn.example.com/old.png"
        )
        viewModel.applyChatListSnapshot([oldRow])
        viewModel.seedGroupDetailsCacheForTesting(GroupDetailsFfi(
            group: group(name: "Old name", id: groupId, avatarUrl: "https://cdn.example.com/old.png"),
            members: [groupMember(memberIdHex: hex("11"), isAdmin: true, isSelf: true)]
        ))

        viewModel.applyChatListRow(chatListRow(
            groupIdHex: groupId,
            title: "New name",
            groupName: "New name",
            avatarUrl: "https://cdn.example.com/new.png"
        ))

        #expect(viewModel.items.first?.title == "New name")
        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/new.png")
    }

    @Test func liveRowWithoutNameOrAvatarKeepsEnrichedGroupDetails() throws {
        let groupId = hex("da")
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        viewModel.applyChatListSnapshot([chatListRow(groupIdHex: groupId, title: "Enriched name", groupName: "")])
        viewModel.seedGroupDetailsCacheForTesting(GroupDetailsFfi(
            group: group(name: "Enriched name", id: groupId, avatarUrl: "https://cdn.example.com/enriched.png"),
            members: [groupMember(memberIdHex: hex("11"), isAdmin: true, isSelf: true)]
        ))

        // A routine live update (new message / unread change) carries neither
        // a name nor an avatar; it must not wipe the enriched values.
        viewModel.applyChatListRow(chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: "",
            avatarUrl: nil,
            unreadCount: 1
        ))

        let cached = viewModel.groupDetailsCacheEntryForTesting(groupIdHex: groupId)
        #expect(cached?.group.name == "Enriched name")
        #expect(cached?.group.avatarUrl == "https://cdn.example.com/enriched.png")
        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/enriched.png")
        #expect(viewModel.items.first?.unreadCount == 1)
    }

    @Test func profileRefreshRebuildsNamedGroupMentionPreviews() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let tokens = MarkdownDocumentFfi(blocks: [
            .paragraph(inlines: [
                .text(content: "ping "),
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32)),
            ]),
        ], truncated: false)
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        viewModel.mentionDisplayNameForTesting = { _ in nil }
        let row = chatListRow(
            groupIdHex: hex("da"),
            title: "Named room",
            groupName: "Named room",
            lastMessage: chatListPreview(
                messageIdHex: hex("db"),
                plaintext: "fallback",
                contentTokens: tokens
            )
        )
        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.items.first?.previewText == "ping @npub1qqq…qqqq")

        viewModel.mentionDisplayNameForTesting = { _ in "Alice" }
        viewModel.refreshDisplayProjections()

        #expect(viewModel.items.first?.previewText == "ping @Alice")
    }

    @Test func localGroupChangeUpdatesProjectedMembership() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: hex("d7"), title: "General")
        viewModel.applyChatListSnapshot([row])

        viewModel.applyLocalGroupChange(group(
            name: "General",
            id: row.groupIdHex,
            selfMembership: .removed
        ))

        #expect(viewModel.items.first?.selfMembership == .removed)
        #expect(viewModel.items.first?.isActiveMember == false)
    }

    @Test func markGroupLeftPreservesInactiveHistoryRow() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(groupIdHex: hex("df"), title: "Left group")
        viewModel.applyChatListSnapshot([row])

        viewModel.markGroupLeft(groupIdHex: row.groupIdHex)

        #expect(viewModel.items.map(\.id) == [row.groupIdHex])
        #expect(viewModel.items.first?.leaveRequestPending == true)
        // Marmot records the voluntary departure at leave time, so the optimistic
        // row must too: a row left claiming an active membership can never offer
        // the local delete that clears an uncommitted leave.
        #expect(viewModel.items.first?.selfMembership == .left)
        #expect(viewModel.items.first?.isActiveMember == false)
        #expect(viewModel.items.first?.departureStatus == .membershipEnded(.left))
        #expect(viewModel.items.first?.departureAction == .deleteLocally)
    }

    @Test func durableMemberPendingLeaveSurvivesFreshSnapshot() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let groupId = hex("e1")
        viewModel.applyChatListSnapshot([
            chatListRow(
                groupIdHex: groupId,
                title: "Leaving group",
                updatedAt: 20,
                selfMembership: .member,
                leaveRequestPending: true
            )
        ])

        #expect(viewModel.items.first?.leaveRequestPending == true)
        #expect(viewModel.items.first?.selfMembership == .member)
        #expect(viewModel.items.first?.isActiveMember == false)
    }

    @Test func resolvedTerminalMembershipClearsPendingLeave() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let groupId = hex("e2")

        viewModel.applyChatListSnapshot([
            chatListRow(
                groupIdHex: groupId,
                title: "Left group",
                updatedAt: 20,
                selfMembership: .left
            )
        ])

        #expect(viewModel.items.first?.leaveRequestPending == false)
        #expect(viewModel.items.first?.selfMembership == .left)
        #expect(viewModel.items.first?.isActiveMember == false)
    }

    @Test func publishedLeaveCanRemainDurablyPending() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(
            groupIdHex: hex("e3"),
            title: "Leaving group",
            selfMembership: .left,
            leaveRequestPending: true
        )

        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.items.first?.leaveRequestPending == true)
        #expect(viewModel.items.first?.selfMembership == .left)
        #expect(viewModel.items.first?.isActiveMember == false)
        // The durable state a quiet group leaves behind forever: it must read as
        // a settled departure with the local delete available, not as progress.
        #expect(viewModel.items.first?.departureStatus == .membershipEnded(.left))
        #expect(viewModel.items.first?.departureAction == .deleteLocally)
        #expect(
            ChatRow.previewPresentation(
                for: try #require(viewModel.items.first),
                activeAccountIdHex: nil,
                senderName: { $0 }
            ).body == "You left this chat."
        )
    }

    @Test func presentedSnapshotDropsAbsentProjectedRow() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let kept = chatListRow(groupIdHex: hex("d1"), title: "Keep")
        let removed = chatListRow(groupIdHex: hex("d2"), title: "Remove")
        viewModel.applyChatListSnapshot([kept, removed])

        viewModel.applyPresentedSnapshot(presentedChatSnapshot([kept]))

        #expect(viewModel.items.map(\.id) == [kept.groupIdHex])
        #expect(viewModel.archivedItems.isEmpty)
    }

    @Test func intersectingDictionaryKeepsOnlySurvivingKeys() throws {
        let cache = ["a": 1, "b": 2, "c": 3]
        let pruned = ChatsListViewModel.intersecting(cache, with: ["a", "c", "z"])

        #expect(pruned == ["a": 1, "c": 3])
    }

    @Test func intersectingSetKeepsOnlySurvivingMembers() throws {
        let ids: Set<String> = ["a", "b", "c"]
        let pruned = ChatsListViewModel.intersecting(ids, with: ["b", "z"])

        #expect(pruned == ["b"])
    }

    @Test func intersectingDropsEverythingWhenNothingSurvives() throws {
        #expect(ChatsListViewModel.intersecting(["a": 1, "b": 2], with: []).isEmpty)
        #expect(ChatsListViewModel.intersecting(Set(["a", "b"]), with: []).isEmpty)
    }

    @Test func intersectingKeepsEverythingWhenAllSurvive() throws {
        let cache = ["a": 1, "b": 2]
        #expect(ChatsListViewModel.intersecting(cache, with: ["a", "b"]) == cache)
    }

    @Test func chatListSubscriptionRetryDelayDoublesUntilCapped() {
        #expect(ChatsListViewModel.nextLiveSubscriptionRetryDelay(after: 500_000_000) == 1_000_000_000)
        #expect(ChatsListViewModel.nextLiveSubscriptionRetryDelay(after: 4_000_000_000) == 8_000_000_000)
        #expect(ChatsListViewModel.nextLiveSubscriptionRetryDelay(after: 8_000_000_000) == 8_000_000_000)
    }

    @Test func staleAvatarEnrichmentTaskCannotClearNewerTaskHandle() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let stale = UUID()
        let current = UUID()

        viewModel.installAvatarEnrichmentTaskForTesting(taskID: stale)
        viewModel.installAvatarEnrichmentTaskForTesting(taskID: current)
        viewModel.finishAvatarEnrichmentTaskForTesting(taskID: stale)

        #expect(viewModel.avatarEnrichmentTaskIDForTesting == current)

        viewModel.finishAvatarEnrichmentTaskForTesting(taskID: current)

        #expect(viewModel.avatarEnrichmentTaskIDForTesting == nil)
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

        viewModel.enqueueChatListRowUpdate(older)
        viewModel.enqueueChatListRowUpdate(newer)

        #expect(viewModel.items.isEmpty)
        try await waitForExpectation { viewModel.items.count == 2 }
        #expect(viewModel.items.map(\.id) == [newer.groupIdHex, older.groupIdHex])
    }

    @Test func directChatListRowUpdatesCanBeCoalescedBeforePublishing() async throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(
            groupIdHex: hex("e1"),
            title: "Read marker",
            lastMessage: chatListPreview(messageIdHex: hex("f1"), plaintext: "read", timelineAt: 10),
            updatedAt: 10
        )

        viewModel.enqueueChatListRowUpdate(row)

        #expect(viewModel.items.isEmpty)
        try await waitForExpectation { viewModel.items.map(\.id) == [row.groupIdHex] }
    }

    @Test func identicalProjectedRowDoesNotRepublishObservedLists() throws {
        let viewModel = ChatsListViewModel(appState: AppState(client: try MarmotClient.testClient()))
        let row = chatListRow(
            groupIdHex: hex("e1"),
            title: "Stable",
            lastMessage: chatListPreview(messageIdHex: hex("f1"), plaintext: "stable", timelineAt: 10),
            updatedAt: 10
        )
        viewModel.applyChatListSnapshot([row])
        let mutationCount = viewModel.publishedItemsMutationCountForTesting

        viewModel.applyChatListRow(row)
        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.publishedItemsMutationCountForTesting == mutationCount)
        #expect(viewModel.items.map(\.id) == [row.groupIdHex])
    }

}

@MainActor
struct ConversationTimelineProjectionTests {

    private func durableRetryFixture(
        invalidationStatus: String? = nil,
        catchUp: @escaping @MainActor (MarmotClient) async throws -> Void = { _ in },
        converge: @escaping @MainActor (MarmotClient, String, String) async throws -> SendSummaryFfi,
        sleep: @escaping @MainActor (UInt64) async throws -> Void = { _ in },
        refresh: @escaping @MainActor (ConversationViewModel) async -> Void = { _ in }
    ) throws -> (
        appState: AppState,
        viewModel: ConversationViewModel,
        record: TimelineMessageRecordFfi,
        rowId: String
    ) {
        let groupIdHex = hex("aa")
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "", id: groupIdHex),
            durableRetryOperations: ConversationViewModel.DurableRetryOperations(
                catchUp: catchUp,
                converge: converge,
                sleep: sleep,
                refresh: refresh
            )
        )
        let record = timelineRecord(
            messageIdHex: hex("d1"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20,
            invalidationStatus: invalidationStatus
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )
        return (appState, viewModel, record, "msg:\(record.messageIdHex)")
    }

    private func status(
        of rowId: String,
        in viewModel: ConversationViewModel
    ) -> MessageStatus? {
        viewModel.timeline.compactMap { item -> MessageStatus? in
            guard item.id == rowId, case .message(_, let status) = item.kind else { return nil }
            return status
        }.first
    }

    private func unpublishedRetrySummary() -> SendSummaryFfi {
        SendSummaryFfi(
            published: 0,
            messageIds: [],
            acceptDisposition: .acceptedPending,
            maintenanceDisposition: .ready
        )
    }

    @Test func pendingReadMarksRetryWhenRuntimeReturnsWithoutAnotherViewportUpdate() {
        #expect(
            ConversationReadMarker.pendingFlushDecision(
                hasPendingMessages: true,
                canUseRuntime: false,
                activeAccountMatches: true
            ) == .retryWhenRuntimeReturns
        )
        #expect(
            ConversationReadMarker.pendingFlushDecision(
                hasPendingMessages: true,
                canUseRuntime: true,
                activeAccountMatches: true
            ) == .flush
        )
        #expect(
            ConversationReadMarker.pendingFlushDecision(
                hasPendingMessages: true,
                canUseRuntime: false,
                activeAccountMatches: false
            ) == .stop
        )
    }

    @Test func rejectedReadMarkRequeuesTheSameWatermarkCandidate() {
        // Marmot rejects a mark for a message it has no durable row for yet,
        // which is the window right after a send. Nothing else produces a later
        // frame there, so the candidate has to survive the failed flush.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
        // A just-sent row can still be outside the loaded window's index; the
        // id is what Marmot marks, so retry it anyway.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: nil,
            pendingIndex: nil,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
    }

    @Test func rejectedReadMarkDefersToANewerQueuedCandidate() {
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: 8,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == nil)
        // Same row and an older row are both non-advances, so the failed
        // candidate stays queued rather than regressing the watermark.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: 7,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: 6,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
    }

    @Test func rejectedReadMarkStopsRetryingAtItsAttemptCap() {
        let cap = ConversationReadMarker.maximumFailedFlushAttempts
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: cap - 1,
            maximumAttempts: cap
        ) == "aa")
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: cap,
            maximumAttempts: cap
        ) == nil)
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: cap + 1,
            maximumAttempts: cap
        ) == nil)
    }

    @Test func readWatermarkAdvancesOnlyForStrictlyNewerCandidates() {
        // Marmot's read marker is one moving pointer, so the guard has to be
        // monotonic: scrolling back up must not regress it.
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 12,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == 12)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 12,
            pendingIndex: nil,
            flushedIndex: 12,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 4,
            pendingIndex: nil,
            flushedIndex: 12,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 13,
            pendingIndex: 12,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == 13)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 11,
            pendingIndex: 12,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
    }

    @Test func readWatermarkRejectsIneligibleCandidates() {
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 3,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindReaction,
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 3,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: true
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: nil,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
    }

    @Test func newestVisibleWatermarkCandidateIgnoresVisibilityOrder() {
        let older = message(id: hex("11"), kind: MessageSemantics.kindChat)
        let newest = message(id: hex("22"), kind: MessageSemantics.kindChat)
        let reactionTail = message(id: hex("33"), kind: MessageSemantics.kindReaction)
        let deletedTail = message(id: hex("44"), kind: MessageSemantics.kindChat)
        let indexes = [hex("11"): 7, hex("22"): 8, hex("33"): 9, hex("44"): 10]

        // Row keys arrive in viewport order, not timeline order, and the tail
        // of the window can be a reaction or a deleted row.
        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [reactionTail, deletedTail, newest, older],
            isDeleted: { $0 == hex("44") },
            timelineIndex: { indexes[$0] }
        )

        #expect(candidate?.messageIdHex == newest.messageIdHex)
    }

    @Test func newestVisibleWatermarkCandidateIsNilWithoutAnEligibleRow() {
        let reaction = message(id: hex("11"), kind: MessageSemantics.kindReaction)
        let outsideWindow = message(id: hex("22"), kind: MessageSemantics.kindChat)

        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [reaction, outsideWindow],
            isDeleted: { _ in false },
            timelineIndex: { $0 == hex("11") ? 1 : nil }
        )

        #expect(candidate?.messageIdHex == nil)
    }

    @Test func liveSubscriptionRetryDelayDoublesUntilCapped() {
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 500_000_000) == 1_000_000_000)
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 4_000_000_000) == 8_000_000_000)
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 8_000_000_000) == 8_000_000_000)
    }

    @Test func startClearsOptimisticOverlaysBeforeRebindingSubscriptions() throws {
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: false,
            canStartLiveWork: true
        ) == .loadLocalSnapshot(startLiveWork: true))
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: false,
            canStartLiveWork: false
        ) == .skipForegroundWork)
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: true,
            canStartLiveWork: false
        ) == .loadLocalSnapshot(startLiveWork: false))
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: true,
            canStartLiveWork: true
        ) == .loadLocalSnapshot(startLiveWork: true))

        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let message = timelineRecord(messageIdHex: hex("44"), timelineAt: 1)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [message], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        viewModel.seedOptimisticStateForTesting(
            deletedMessageIdHex: message.messageIdHex,
            reactionTargetMessageIdHex: message.messageIdHex,
            emoji: "🔥",
            sender: hex("22")
        )
        #expect(viewModel.isDeleted(message.messageIdHex))
        #expect(viewModel.reactions(for: message.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 1, mine: false)
        ])

        viewModel.resetOptimisticStateForTesting()
        #expect(!viewModel.isDeleted(message.messageIdHex))
        #expect(viewModel.reactions(for: message.messageIdHex).isEmpty)
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
                media: [],
                agentTextStreamJson: nil,
                deleted: false
            ),
            reactions: TimelineReactionSummaryFfi(
                byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", count: 2, senders: [hex("33"), hex("44")])],
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
                media: [],
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

    @Test func windowReplyResponseStaysBelowParentWhenSameTimestampWouldInsertAbove() throws {
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
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [approve, response], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

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
                byEmoji: [TimelineReactionEmojiFfi(emoji: "🔥", count: 1, senders: [hex("33")])],
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

    @Test func liveProjectionUpdateMaintainsTimelineWithoutFullRebuild() throws {
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let first = timelineRecord(messageIdHex: hex("e1"), groupIdHex: groupIdHex, timelineAt: 10)
        let second = timelineRecord(messageIdHex: hex("e2"), groupIdHex: groupIdHex, timelineAt: 20)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [first], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let rebuildCount = viewModel.timelineRebuildCountForTesting

        viewModel.applyTimelineSubscriptionUpdate(.projection(update: RuntimeProjectionUpdateFfi(
            accountIdHex: hex("01"),
            accountLabel: "account",
            update: TimelineProjectionUpdateFfi(
                groupIdHex: groupIdHex,
                messages: [],
                changes: [.upsert(trigger: .newMessage, message: second)],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            )
        )))

        #expect(messageIds(in: viewModel.timeline) == [first.messageIdHex, second.messageIdHex])
        #expect(viewModel.timelineRebuildCountForTesting == rebuildCount)
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
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projected], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
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

    @Test func durablyPendingOwnRowStaysPendingUntilDeliveredUpsert() throws {
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
            plaintext: "stuck offline",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let durablyPending = timelineRecord(
            messageIdHex: hex("b7"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 20
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-durable", record: pending)

        #expect(viewModel.timeline.compactMap { item -> MessageStatus? in
            guard item.id == "msg:pending-durable", case .message(_, let status) = item.kind else { return nil }
            return status
        }.first == .sending)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [durablyPending], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let rowId = "msg:\(durablyPending.messageIdHex)"
        func status() -> MessageStatus? {
            viewModel.timeline.compactMap { item -> MessageStatus? in
                guard item.id == rowId, case .message(_, let status) = item.kind else { return nil }
                return status
            }.first
        }

        // The first durable projection consumes the optimistic row but remains
        // unresolved, so it keeps the clock and convergence-retry path.
        #expect(status() == .sending)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).systemImage == "clock")
        #expect(viewModel.canRetryFailedSend(rowId: rowId))
        #expect(viewModel.canDiscardFailedSend(rowId: rowId))

        // Repeating the same nil-source projection must not reinterpret the
        // durable unresolved state as failure after reconciliation is complete.
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [durablyPending], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sending)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).systemImage == "clock")

        // Delivery upsert (same row, source id now present) flips it to sent.
        let delivered = timelineRecord(
            messageIdHex: durablyPending.messageIdHex,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: durablyPending.plaintext,
            timelineAt: 20
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [delivered], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sent)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).systemImage == "checkmark")
        #expect(!viewModel.canRetryFailedSend(rowId: rowId))
    }

    @Test func definitivelyInvalidatedOwnRowRendersFailed() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let invalidated = timelineRecord(
            messageIdHex: hex("b9"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "rejected durably",
            timelineAt: 20,
            invalidationStatus: "local_publish_failed"
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [invalidated], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let status = viewModel.timeline.compactMap { item -> MessageStatus? in
            guard item.id == "msg:\(invalidated.messageIdHex)", case .message(_, let status) = item.kind else {
                return nil
            }
            return status
        }.first
        #expect(status == .failed)
        #expect(MessageFooterPresentation.value(for: try #require(status), isFromMe: true).isFailure)
    }

    @Test func unsuccessfulDurableRetryRestoresInvalidatedFailureOutsideRefreshedTail() async throws {
        var attempts = 0
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, groupIdHex in
                attempts += 1
                throw MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: groupIdHex)
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(attempts == 1)
        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
        #expect(fixture.viewModel.error != nil)
    }

    @Test func durableRetryReportsUnavailableRuntime() async throws {
        let groupIdHex = hex("aa")
        let appState = AppState()
        appState.activeAccountRef = "account-ref"
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "", id: groupIdHex)
        )
        let record = timelineRecord(
            messageIdHex: hex("d1"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20,
            invalidationStatus: "local_publish_failed"
        )
        let rowId = "msg:\(record.messageIdHex)"
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )

        await viewModel.retryFailedSend(rowId: rowId)

        #expect(status(of: rowId, in: viewModel) == .failed)
        #expect(viewModel.error == L10n.string("Send failed"))
    }

    @Test func exhaustedDurableRetryKeepsNonInvalidatedRowSending() async throws {
        var attempts = 0
        var sleeps = 0
        let fixture = try durableRetryFixture(
            converge: { _, _, _ in
                attempts += 1
                return unpublishedRetrySummary()
            },
            sleep: { _ in sleeps += 1 }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(attempts == 6)
        #expect(sleeps == 5)
        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sending)
        #expect(fixture.viewModel.error != nil)
    }

    @Test func publishedDurableRetryMarksRowSentWhenRefreshedTailOmitsIt() async throws {
        let messageIdHex = hex("d1")
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, _ in
                SendSummaryFfi(
                    published: 1,
                    messageIds: [messageIdHex],
                    acceptDisposition: .published,
                    maintenanceDisposition: .ready
                )
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sent)
        #expect(!fixture.viewModel.canRetryFailedSend(rowId: fixture.rowId))
        #expect(fixture.viewModel.error == nil)
    }

    @Test func cancelledDurableRetryRestoresPriorFailure() async throws {
        var enteredRetrySleep = false
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, _ in
                return unpublishedRetrySummary()
            },
            sleep: { _ in
                enteredRetrySleep = true
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let retryTask = Task { @MainActor in
            await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)
        }
        try await waitForExpectation {
            enteredRetrySleep
        }

        retryTask.cancel()
        await retryTask.value

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
        #expect(fixture.viewModel.error == nil)
    }

    @Test func cancelledDuringFinalRefreshRestoresPriorFailureWithoutError() async throws {
        var enteredFinalRefresh = false
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, _ in unpublishedRetrySummary() },
            refresh: { _ in
                enteredFinalRefresh = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        let retryTask = Task { @MainActor in
            await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)
        }

        await retryTask.value

        #expect(enteredFinalRefresh)
        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
        #expect(fixture.viewModel.error == nil)
    }

    @Test func authoritativeDeliveryDuringRetryIsNotOverwrittenByCleanup() async throws {
        let groupIdHex = hex("aa")
        let messageIdHex = hex("d1")
        let delivered = timelineRecord(
            messageIdHex: messageIdHex,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20
        )
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, groupIdHex in
                throw MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: groupIdHex)
            },
            refresh: { viewModel in
                viewModel.applyTimelinePage(
                    TimelinePageFfi(messages: [delivered], hasMoreBefore: true, hasMoreAfter: false),
                    placement: .tailRefresh
                )
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sent)
        #expect(!fixture.viewModel.canRetryFailedSend(rowId: fixture.rowId))
        #expect(fixture.viewModel.error == nil)
    }

    @Test func authoritativePendingRefreshDuringRetryIsNotOverwrittenByCleanup() async throws {
        let groupIdHex = hex("aa")
        let messageIdHex = hex("d1")
        let revalidatedPending = timelineRecord(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20
        )
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, groupIdHex in
                throw MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: groupIdHex)
            },
            refresh: { viewModel in
                viewModel.applyTimelinePage(
                    TimelinePageFfi(messages: [revalidatedPending], hasMoreBefore: true, hasMoreAfter: false),
                    placement: .tailRefresh
                )
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sending)
        #expect(fixture.viewModel.canRetryFailedSend(rowId: fixture.rowId))
        #expect(fixture.viewModel.error != nil)
    }

    @Test func successfulSendAckDoesNotFlashFailedWhileDeliveredProjectionCatchesUp() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let messageId = hex("b8")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "published",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-ack", record: pending)
        viewModel.confirmSent(tempId: "pending-ack", record: pending, messageId: messageId)

        let localProjection = timelineRecord(
            messageIdHex: messageId,
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 10
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [localProjection], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let rowId = "msg:\(messageId)"
        func status() -> MessageStatus? {
            viewModel.timeline.compactMap { item -> MessageStatus? in
                guard item.id == rowId, case .message(_, let status) = item.kind else { return nil }
                return status
            }.first
        }

        #expect(status() == .sent)
        #expect(!viewModel.canRetryFailedSend(rowId: rowId))

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [localProjection], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sent)

        let deliveredProjection = timelineRecord(
            messageIdHex: messageId,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 10
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [deliveredProjection], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sent)
    }

    @Test func failedSendRowSupportsRetryGatingAndDiscard() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let tempId = "retry-1"
        let rowId = "msg:\(tempId)"
        let text = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "retry me",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: text)
        viewModel.markFailedForTesting(tempId: tempId)

        // A failed text row is retryable and discardable.
        #expect(viewModel.canRetryFailedSend(rowId: rowId))

        // A failed media row (carrying the pending-media marker) is NOT
        // retryable here — its compressed bytes aren't retained — but can
        // still be discarded.
        let mediaTempId = "retry-media"
        let mediaRowId = "msg:\(mediaTempId)"
        let media = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [MessageTagFfi(values: ["_media_pending"])],
            recordedAt: 11,
            receivedAt: 11
        )
        viewModel.applyPendingOutgoingMessage(tempId: mediaTempId, record: media)
        viewModel.markFailedForTesting(tempId: mediaTempId)
        #expect(!viewModel.canRetryFailedSend(rowId: mediaRowId))

        // Discard removes the failed row from the timeline.
        viewModel.discardFailedSend(rowId: rowId)
        let remaining = viewModel.timeline.compactMap { item -> String? in
            guard case .message = item.kind else { return nil }
            return item.id
        }
        #expect(!remaining.contains(rowId))
        #expect(remaining.contains(mediaRowId))
    }

    @Test func projectedOutgoingMessageReplacesMatchingFailedPendingBubble() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let tempId = "pending-1"
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

        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)
        viewModel.markFailedForTesting(tempId: tempId)

        let failedMessages = viewModel.timeline.compactMap { item -> (String, MessageStatus)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status)
        }
        #expect(failedMessages.count == 1)
        #expect(failedMessages[0].0 == "")
        #expect(failedMessages[0].1 == .failed)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projected], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
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
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projected], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
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

    @MainActor
    @Test func confirmSentWithoutServerIdPreservesPendingMediaOnRecreatedRow() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let tempId = "pending-media-1"
        let tempRowId = "msg:\(tempId)"
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let attachment = MessageMediaAttachment(
            id: "\(tempRowId):0",
            reference: nil,
            fileName: "a.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        // Mirror sendMedia's optimistic setup: stage the local attachment bytes
        // under the temp row, then add the transient bubble.
        viewModel.installPendingMediaForTesting(rowId: tempRowId, items: [attachment])
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)

        // uploadMedia succeeded but returned no message id.
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: nil)

        // The transient row is recreated under the same id (no server id), and the
        // just-sent attachment must still resolve instead of vanishing.
        #expect(viewModel.pendingMediaForTesting(rowId: tempRowId) == [attachment])

        let mediaRow = try #require(viewModel.timeline.first { $0.id == tempRowId })
        #expect(viewModel.mediaItems(for: mediaRow) == [attachment])
    }

    @MainActor
    @Test func authoritativeMediaRowReleasesConfirmedPendingBytes() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let messageId = hex("b2")
        let tempId = "pending-media-real-id"
        let tempRowId = "msg:\(tempId)"
        let realRowId = "msg:\(messageId)"
        let reference = encryptedMediaReference(
            fileName: "canonical.jpg",
            plaintextByte: "31",
            ciphertextByte: "41",
            sourceEpoch: 42
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [MessageSemantics.imetaTag(for: reference)],
            recordedAt: 10,
            receivedAt: 10
        )
        let localAttachment = MessageMediaAttachment(
            id: "local",
            reference: nil,
            fileName: "local.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )

        viewModel.installPendingMediaForTesting(rowId: tempRowId, items: [localAttachment])
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: messageId)
        #expect(viewModel.pendingMediaForTesting(rowId: realRowId) == [localAttachment])

        let authoritative = timelineRecord(
            messageIdHex: messageId,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            tags: pending.tags,
            timelineAt: 20,
            media: [reference]
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [authoritative], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.pendingMediaForTesting(rowId: realRowId) == nil)
        let mediaRow = try #require(viewModel.timeline.first { $0.id == realRowId })
        #expect(viewModel.mediaItems(for: mediaRow).map(\.fileName) == ["canonical.jpg"])
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
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projectedOlder], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
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

    @MainActor
    @Test func projectedTextSendDoesNotReconcileMediaPendingWithSameCaption() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let caption = "hi"

        // A media send: optimistic record carries `tags: []` and `plaintext`
        // equal to the caption, with the local attachment staged under its row.
        let mediaTempId = "pending-media"
        let mediaRowId = "msg:\(mediaTempId)"
        let mediaPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let attachment = MessageMediaAttachment(
            id: "\(mediaRowId):0",
            reference: nil,
            fileName: "a.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        viewModel.installPendingMediaForTesting(rowId: mediaRowId, items: [attachment])
        viewModel.applyPendingOutgoingMessage(tempId: mediaTempId, record: mediaPending)

        // A plain text send with the same text, no staged media.
        let textTempId = "pending-text"
        let textPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 11,
            receivedAt: 11
        )
        viewModel.applyPendingOutgoingMessage(tempId: textTempId, record: textPending)

        // The incoming confirmation is the plain text send (no `imeta` tags).
        // It must reconcile the text pending and leave the media bubble alone.
        let projectedText = timelineRecord(
            messageIdHex: hex("b2"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            timelineAt: 20
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projectedText], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (id: String, status: MessageStatus, rowId: String)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.id)
        }

        #expect(messages.count == 2)
        // The confirmed text send replaced the text pending.
        #expect(messages.contains { $0.id == projectedText.messageIdHex && $0.status == .sent })
        // The media pending bubble survived, still pending under its temp row.
        #expect(messages.contains { $0.rowId == mediaRowId && $0.status == .sending })
        // Its staged attachment is still resolvable.
        #expect(viewModel.pendingMediaForTesting(rowId: mediaRowId) == [attachment])
    }

    @MainActor
    @Test func projectedMediaSendReconcilesMediaPendingNotTextWithSameCaption() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let caption = "hi"

        let mediaTempId = "pending-media"
        let mediaRowId = "msg:\(mediaTempId)"
        let mediaPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let attachment = MessageMediaAttachment(
            id: "\(mediaRowId):0",
            reference: nil,
            fileName: "a.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        viewModel.installPendingMediaForTesting(rowId: mediaRowId, items: [attachment])
        viewModel.applyPendingOutgoingMessage(tempId: mediaTempId, record: mediaPending)

        let textTempId = "pending-text"
        let textRowId = "msg:\(textTempId)"
        let textPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 11,
            receivedAt: 11
        )
        viewModel.applyPendingOutgoingMessage(tempId: textTempId, record: textPending)

        // The incoming confirmation is the media send: kind-9 with an `imeta`
        // tag. It must reconcile the media pending, not the text pending.
        let reference = encryptedMediaReference(sourceEpoch: 0)
        let projectedMedia = timelineRecord(
            messageIdHex: hex("b3"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            tags: [MessageSemantics.imetaTag(for: reference)],
            timelineAt: 20
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projectedMedia], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (id: String, status: MessageStatus, rowId: String)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.id)
        }

        #expect(messages.count == 2)
        // The confirmed media send replaced the media pending.
        #expect(messages.contains { $0.id == projectedMedia.messageIdHex && $0.status == .sent })
        // The text pending bubble survived.
        #expect(messages.contains { $0.rowId == textRowId && $0.status == .sending })
        // The media pending row was removed (reconciled away).
        #expect(viewModel.pendingMediaForTesting(rowId: mediaRowId) == nil)
    }

    @Test func paginationProgressRequiresWindowEdgeMovement() {
        #expect(ConversationPaginationPolicy.movedOlder(
            previousOldestMessageId: "message-b",
            nextMessageIds: ["message-a", "message-b"]
        ))
        #expect(!ConversationPaginationPolicy.movedOlder(
            previousOldestMessageId: "message-b",
            nextMessageIds: ["message-b", "message-c"]
        ))
        #expect(!ConversationPaginationPolicy.movedOlder(
            previousOldestMessageId: "message-b",
            nextMessageIds: []
        ))
        #expect(ConversationPaginationPolicy.movedNewer(
            previousNewestMessageId: "message-b",
            nextMessageIds: ["message-b", "message-c"]
        ))
        #expect(!ConversationPaginationPolicy.movedNewer(
            previousNewestMessageId: "message-b",
            nextMessageIds: ["message-a", "message-b"]
        ))
        #expect(!ConversationPaginationPolicy.movedNewer(
            previousNewestMessageId: "message-b",
            nextMessageIds: []
        ))
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

struct NetworkTrustRegressionTests {
    @Test func nprofileResolutionStripsUnsafeRelayHintsBeforeMarmot() throws {
        let accountIdHex = hex("42")
        let raw = try #require(NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: [
                "wss://relay.example/path",
                "ws://insecure.example",
                "wss://127.0.0.1/private",
                "wss://relay.example/path",
            ]
        ))

        let sanitized = try #require(NostrProfileReference.referenceForResolution(from: raw))
        #expect(NostrProfileReference.pubkeyHex(fromBech32: sanitized) == accountIdHex)
        #expect(sanitized == NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: ["wss://relay.example/path"]
        ))
    }

    @Test func nprofileEncodingNormalizesDeduplicatesAndCapsRelayHints() throws {
        let accountIdHex = hex("43")
        let normalizedRelays = (0..<8).map { "wss://relay\($0).example/path" }
        let encoded = try #require(NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: [
                "ws://insecure.example",
                "WSS://RELAY0.EXAMPLE/path",
                normalizedRelays[0],
            ] + Array(normalizedRelays.dropFirst()) + ["wss://relay8.example/path"]
        ))
        let expected = try #require(NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: normalizedRelays
        ))

        #expect(encoded == expected)
    }

    @Test func malformedPunycodeHostIsStillFlaggedAsInternationalized() throws {
        let url = try #require(URL(string: "https://xn--.example/path"))
        let display = MessageExternalLinkConfirmation.displayText(for: url)

        #expect(display.contains("IDN/punycode"))
    }

    @Test func notificationAvatarBytesRequireADecodableRasterImage() throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        #expect(NotificationCommunicationDecorator.isAllowedAvatarData(png))
        #expect(!NotificationCommunicationDecorator.isAllowedAvatarData(Data("not an image".utf8)))
        #expect(!NotificationCommunicationDecorator.isAllowedAvatarData(Data(
            "<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8
        )))
        #expect(NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: [(width: 1_024, height: 1_024)]
        ))
        #expect(!NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: [(width: 4_097, height: 1)]
        ))
        #expect(!NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: Array(repeating: (width: 1, height: 1), count: 9)
        ))
        #expect(!NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: [(width: 4_096, height: 4_096), (width: 1, height: 1)]
        ))
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

    @Test func terminalMembershipOverridesStaleActiveManagementState() {
        let state = managementState(
            isSelfAdmin: false,
            isLastAdmin: false,
            canLeave: true
        )

        #expect(!GroupManagementPresentation.isActiveMember(
            state: state,
            members: [],
            groupMemberDetails: [],
            myAccountId: state.myAccountIdHex,
            fallbackSelfMembership: .left
        ))
        #expect(!GroupManagementPresentation.isActiveMember(
            state: state,
            members: [],
            groupMemberDetails: [],
            myAccountId: state.myAccountIdHex,
            fallbackSelfMembership: .removed
        ))
    }

    @Test func pendingLeaveDisablesMembershipAndLeaveAffordances() {
        let state = managementState(
            isSelfAdmin: false,
            isLastAdmin: false,
            canLeave: false,
            leaveRequestPending: true
        )

        #expect(!GroupManagementPresentation.canLeave(state: state, fallbackIsLastAdmin: false))
        #expect(!GroupManagementPresentation.isActiveMember(
            state: state,
            members: [],
            groupMemberDetails: [],
            myAccountId: state.myAccountIdHex
        ))
        #expect(GroupManagementPresentation.leaveFooter(
            state: state,
            fallbackIsLastAdmin: false
        ) == GroupManagementPresentation.leavingGroupComposerMessage)
    }

    @Test func adminCanEndGroupWhenLifecycleCanBeEnabledOrIsAlreadyEnabled() {
        let canEnable = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            canEnableDisbanding: true
        )
        let enabled = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            disbandingEnabled: true,
            canDisband: true
        )

        #expect(GroupManagementPresentation.shouldShowEndGroup(state: canEnable))
        #expect(GroupManagementPresentation.canEndGroup(state: canEnable))
        #expect(GroupManagementPresentation.shouldShowEndGroup(state: enabled))
        #expect(GroupManagementPresentation.canEndGroup(state: enabled))
    }

    @Test func incompatibleMembersDisableEndGroupWithUpdateGuidance() {
        let state = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            disbandingBlockers: [hex("22"), hex("33")]
        )

        #expect(GroupManagementPresentation.shouldShowEndGroup(state: state))
        #expect(!GroupManagementPresentation.canEndGroup(state: state))
        #expect(
            GroupManagementPresentation.disbandBlockerMessage(state: state)
                == "2 members must update White Noise before you can end this group."
        )
    }

    @Test func pendingAndTerminalDisbandStatesDisableTheComposer() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let pending = group(
            name: "Ending",
            disbanding: true,
            disbandRequest: .pending(requestedAtMs: 1_000)
        )
        let pendingConversation = ConversationViewModel(appState: appState, group: pending)
        let terminal = group(name: "Ended", disbanded: true)
        let terminalConversation = ConversationViewModel(appState: appState, group: terminal)

        #expect(!pendingConversation.canSendMessages)
        #expect(
            pendingConversation.inactiveGroupMessage
                == GroupManagementPresentation.disbandingComposerMessage
        )
        #expect(
            GroupManagementPresentation.disbandStatus(group: pending, state: nil)
                == .pending
        )
        #expect(!terminalConversation.canSendMessages)
        #expect(
            terminalConversation.inactiveGroupMessage
                == GroupManagementPresentation.disbandedComposerMessage
        )
        #expect(
            GroupManagementPresentation.disbandStatus(group: terminal, state: nil)
                == .disbanded
        )
    }

    @Test func failedDisbandRequestExplainsWhyItStopped() {
        let failed = group(
            name: "Not Ended",
            disbandRequest: .failed(requestedAtMs: 1_000, reason: .noLongerAdmin)
        )

        #expect(
            GroupManagementPresentation.disbandStatus(group: failed, state: nil)
                == .failed(.noLongerAdmin)
        )
        #expect(
            GroupManagementPresentation.disbandFailureMessage(.noLongerAdmin)
                == "The group wasn't ended because you're no longer an admin."
        )
    }

    @Test func relaySectionShowsUrls() {
        let relays = ["wss://relay.example", "wss://relay.two"]

        #expect(GroupRelaysPresentation.rows(for: relays) == relays)
    }

    @Test func relaySectionShowsEmptyState() {
        #expect(GroupRelaysPresentation.rows(for: []) == [GroupRelaysPresentation.emptyMessage])
    }

    @Test func addMembersScannerAcceptsProfileDeepLinks() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let nprofile = "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"
        let nprofileHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "\(DeepLink.scheme)://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "marmot-staging://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise-staging://profile/\(npub)") == npub
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
            AddMembersPresentation.memberRef(fromScannedPayload: "\(DeepLink.scheme)://profile/\(nprofile)") == nprofileHex
        )
        #expect(
            DeepLink.parse(string: "nostr:\(nprofile)") == .profile(npub: nprofile)
        )
        #expect(NostrProfileReference.memberRef(from: nprofile) == nprofileHex)
        #expect(ProfileReferenceResolution.referenceForResolution(nprofile) == nprofileHex)
        #expect(
            NostrProfileReference.memberRef(from: "3BF0C63FCB93463407AF97A5E5EE64FA883D107EF9E558472C4EB9AAAEFA459D") == "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        )
    }

    @Test func encodesNpubFromHexWithoutMarmotFfi() throws {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let hex = try #require(NostrProfileReference.pubkeyHex(fromBech32: npub))

        #expect(NostrProfileReference.npub(fromAccountIdHex: hex) == npub)
        #expect(NostrProfileReference.npub(fromAccountIdHex: hex.uppercased()) == npub)
        #expect(NostrProfileReference.npub(fromAccountIdHex: "not hex") == nil)
    }

    @Test func addMembersScannerRejectsCorruptNpubReferences() {
        let invalidNpub = "npub1abcdefghijklmnopqrstuvwxyz"

        #expect(NostrProfileReference.memberRef(fromReference: invalidNpub) == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: invalidNpub) == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: "nostr:\(invalidNpub)") == nil)
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise://profile/\(invalidNpub)") == nil
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
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise://profile/\(crafted)") == nil
        )
    }

    @Test func stagedMembersFallBackToNpubWithNpubSubtitle() throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let account = hex("33")
        let member = stagedMember(accountIdHex: account)

        // With no known profile, both identity surfaces stay in canonical npub
        // form. (Name resolution from a profile is covered separately.)
        #expect(AddMembersPresentation.displayName(for: member, appState: appState) == appState.shortNpub(forAccountIdHex: account))
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
    @Test func recordFinalizedStreamsSkipsAlreadyScannedRecordsAcrossPages() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")
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
        let page = TimelinePageFfi(messages: [final], hasMoreBefore: false, hasMoreAfter: false)

        // Apply the same window page repeatedly, as heavy pagination would.
        viewModel.applyTimelinePage(page, placement: .window)
        viewModel.applyTimelinePage(page, placement: .window)
        viewModel.applyTimelinePage(page, placement: .window)

        // The record is scanned at most once per distinct message id, and the
        // finalized-stream guard is populated exactly once.
        #expect(viewModel.scannedFinalizedMessageIdCountForTesting == 1)
        #expect(viewModel.finalizedStreamIdCountForTesting == 1)
    }

    @MainActor
    @Test func scannedFinalizedCacheIsBoundedToLoadedWindowButGuardPersists() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")
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
        #expect(viewModel.scannedFinalizedMessageIdCountForTesting == 1)
        #expect(viewModel.finalizedStreamIdCountForTesting == 1)

        // A later window scrolls the finalized anchor out of the loaded set.
        let other = timelineRecord(
            messageIdHex: hex("dd"),
            sender: hex("11"),
            plaintext: "later",
            timelineAt: 3
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [other], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )

        // The scan cache is bounded to records still in the window, but the
        // finalized-stream guard is never pruned (re-watch suppression must
        // survive the anchor leaving the window).
        #expect(viewModel.scannedFinalizedMessageIdCountForTesting == 1)
        #expect(viewModel.finalizedStreamIdCountForTesting == 1)
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

    @MainActor
    @Test func streamChunksAreCappedToMessageBodyLimit() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let almostFull = String(repeating: "a", count: ContentSanitizer.maxMessageLength - 1)

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
        #expect(record.plaintext.count == ContentSanitizer.maxMessageLength)
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
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [nextMessage], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

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

    /// Regression for #230: when an agent-stream watch task exits naturally
    /// (the broker returns nil from `next()` without any finished/failed/abort
    /// update), it must clear its own `streamWatchTasks` entry so the admission
    /// guard doesn't treat the stale dead key as "already watching" and lock
    /// out re-subscription. The clear is generation-guarded: the owning task
    /// (matching generation) clears; a stale task whose key was reused by a
    /// later re-watch (mismatched generation) must not tear the re-watch down.
    @Test func streamWatchClearsOwnEntryOnNaturalCompletion() {
        let owning = UUID()
        // Same generation still stored -> the completing task owns the key.
        #expect(ConversationViewModel.shouldClearCompletedStreamWatch(
            storedGeneration: owning,
            taskGeneration: owning
        ))
        // Key was reused by a re-watch (new generation stored) -> the stale
        // task must not clear the live re-watch.
        #expect(!ConversationViewModel.shouldClearCompletedStreamWatch(
            storedGeneration: UUID(),
            taskGeneration: owning
        ))
        // Key already cleared (no stored generation) -> nothing to clear.
        #expect(!ConversationViewModel.shouldClearCompletedStreamWatch(
            storedGeneration: nil,
            taskGeneration: owning
        ))
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

    @Test func receivedRecordPreservesSourceRetentionAndObservationMetadata() {
        let message = ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "hello",
            contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: [],
            sourceEpoch: 12,
            retentionSeconds: 60,
            retentionExpiresAt: 1_700_000_060,
            recordedAt: 1_700_000_000,
            receivedAt: 1_700_000_010
        )
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: message
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: 1_800_000_000)

        #expect(record.sourceEpoch == message.sourceEpoch)
        #expect(record.retentionSeconds == message.retentionSeconds)
        #expect(record.retentionExpiresAt == message.retentionExpiresAt)
        #expect(record.receivedAt == message.receivedAt)
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

struct ChatListSearchTests {
    @Test func matchingIgnoresCaseAndDiacritics() {
        #expect(ChatListSearch.matches(query: "elodie", in: "Élodie and Alice"))
        #expect(ChatListSearch.matches(query: "ALICE", in: "Élodie and Alice"))
        #expect(!ChatListSearch.matches(query: "bob", in: "Élodie and Alice"))
    }

    @Test func blankSearchMatchesEveryRow() {
        #expect(ChatListSearch.matches(query: "  \n", in: "Anything"))
    }
}

struct ChatListSwipeActionsPresentationTests {
    @Test func activeMemberShowsLeaveAndArchive() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.leave))
        #expect(actions.contains(.archive))
        #expect(!actions.contains(.delete))
        #expect(!actions.contains(.unarchive))
    }

    @Test func inactiveMemberShowsDeleteAndArchive() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .removed,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.delete))
        #expect(actions.contains(.archive))
        #expect(!actions.contains(.leave))
        #expect(!actions.contains(.unarchive))
    }

    @Test func archivedActiveMemberShowsUnarchiveAndLeave() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: true,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.unarchive))
        #expect(actions.contains(.leave))
        #expect(!actions.contains(.delete))
        #expect(!actions.contains(.archive))
    }

    @Test func archivedInactiveMemberShowsUnarchiveAndDelete() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: true,
            selfMembership: .left,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.unarchive))
        #expect(actions.contains(.delete))
        #expect(!actions.contains(.leave))
        #expect(!actions.contains(.archive))
    }

    @Test func bulkLocalDeleteRequiresEverySelectedMembershipToBeInactive() {
        #expect(!ChatListSelection.canDeleteLocally([]))
        #expect(ChatListSelection.canDeleteLocally([.deleteLocally]))
        #expect(ChatListSelection.canDeleteLocally([.deleteLocally, .deleteLocally]))
        #expect(!ChatListSelection.canDeleteLocally([.leave]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, .leave]))
        #expect(!ChatListSelection.canDeleteLocally([nil]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, nil]))
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
            media: [],
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

    @Test func mediaReferenceUsesMdkCanonicalV2MediaTypeValidation() {
        let base = [
            MessageSemantics.imetaTag,
            "v encrypted-media-v2",
            "locator blossom-v1 https://media.example/a.txt",
            "ciphertext_sha256 \(hex("44"))",
            "plaintext_sha256 \(hex("33"))",
            "nonce \(String(repeating: "22", count: 12))",
            "m text/plain",
            "filename a.txt",
        ]

        #expect(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: base)]
        )?.first?.mediaType == "text/plain")

        var noncanonical = base
        noncanonical[6] = "m Text/Plain"
        #expect(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: noncanonical)]
        ) == nil)
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
                    "locator blossom-v1 https://media.example/\(hex("44")).bin",
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
        #expect(info[0].locators == [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/\(hex("44")).bin")])
        #expect(info[0].mediaType == "image/png")
        #expect(info[0].fileName == "a.png")
        #expect(info[0].plaintextSha256 == hex("33"))
        #expect(info[0].ciphertextSha256 == hex("44"))
        #expect(info[0].nonceHex == nonce)
        #expect(info[0].version == .v1)
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

    @Test func unsupportedBlurhashFieldIsRejectedByMdkWithoutHidingMessage() {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        #expect(MessageSemantics.classify(record) == .chat)
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

    @Test func invalidThumbhashIsDroppedWithoutHidingAttachment() {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("thumbhash \(String(repeating: "x", count: 129))")
        let record = unsignedEventRecord(
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false), "expected media")
            return
        }
        #expect(info.count == 1)
        #expect(info[0].fileName == "a.png")
        #expect(info[0].thumbhash == nil)
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func invalidOptionalDimIsDroppedWithoutHidingAttachment() {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag = MessageTagFfi(values: tag.values.filter { !$0.hasPrefix("dim ") })
        tag.values.append("dim 640")
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
        #expect(info[0].dim == nil)
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
    @Test func timelineMediaItemsUseCachedReferenceProjection() throws {
        let messageId = hex("dd")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(messageIdHex: messageId, timelineAt: 1)
        let firstReference = encryptedMediaReference(
            fileName: "first.jpg",
            plaintextByte: "31",
            ciphertextByte: "41",
            sourceEpoch: 42
        )
        let secondReference = encryptedMediaReference(
            fileName: "second.jpg",
            plaintextByte: "32",
            ciphertextByte: "42",
            sourceEpoch: 42
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first)
        // Row-resolved references arrive already ordered (Marmot preserves imeta order).
        viewModel.replaceMediaReferencesForTesting([firstReference, secondReference], forMessageId: messageId)

        let firstRead = viewModel.mediaItems(for: item)
        let buildCountAfterProjection = viewModel.mediaItemProjectionBuildCountForTesting
        let secondRead = viewModel.mediaItems(for: item)

        #expect(firstRead.map(\.fileName) == ["first.jpg", "second.jpg"])
        #expect(secondRead == firstRead)
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == buildCountAfterProjection)
    }

    @MainActor
    @Test func mediaReferenceUpdateRefreshesOnlyChangedTimelineProjection() throws {
        let messageId = hex("dd")
        let otherMessageId = hex("ee")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(messageIdHex: messageId, timelineAt: 1)
        let otherRecord = timelineRecord(messageIdHex: otherMessageId, timelineAt: 2)
        let firstReference = encryptedMediaReference(fileName: "first.jpg", plaintextByte: "31", ciphertextByte: "41", sourceEpoch: 42)
        let replacementReference = encryptedMediaReference(fileName: "replacement.jpg", plaintextByte: "32", ciphertextByte: "42", sourceEpoch: 42)
        let otherReference = encryptedMediaReference(fileName: "other.jpg", plaintextByte: "33", ciphertextByte: "43", sourceEpoch: 42)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record, otherRecord], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first { $0.id == "msg:\(messageId)" })
        let otherItem = try #require(viewModel.timeline.first { $0.id == "msg:\(otherMessageId)" })
        viewModel.replaceMediaReferencesForTesting([firstReference], forMessageId: messageId)
        viewModel.replaceMediaReferencesForTesting([otherReference], forMessageId: otherMessageId)
        let buildCountAfterInitialProjection = viewModel.mediaItemProjectionBuildCountForTesting

        #expect(viewModel.replaceMediaReferencesForTesting([replacementReference], forMessageId: messageId))
        let updated = viewModel.mediaItems(for: item)
        let unchanged = viewModel.mediaItems(for: otherItem)

        #expect(updated.map(\.fileName) == ["replacement.jpg"])
        #expect(unchanged.map(\.fileName) == ["other.jpg"])
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == buildCountAfterInitialProjection + 1)
    }

    @MainActor
    @Test func timelineMediaItemsDoNotClassifyTagsWhenRowProjectionIsEmpty() throws {
        let messageId = hex("dd")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(
            messageIdHex: messageId,
            plaintext: "caption",
            tags: [encryptedMediaTag(fileName: "classified.jpg", plaintextByte: "31", ciphertextByte: "41")],
            timelineAt: 1
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first)
        let buildCountAfterProjection = viewModel.mediaItemProjectionBuildCountForTesting

        let firstRead = viewModel.mediaItems(for: item)
        let secondRead = viewModel.mediaItems(for: item)

        #expect(firstRead.isEmpty)
        #expect(secondRead.isEmpty)
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == buildCountAfterProjection)
    }

    @MainActor
    @Test func pendingMediaOverridesCachedTimelineProjection() throws {
        let messageId = hex("dd")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(messageIdHex: messageId, timelineAt: 1)
        let listedReference = encryptedMediaReference(
            fileName: "listed.jpg",
            plaintextByte: "31",
            ciphertextByte: "41",
            sourceEpoch: 42
        )
        let pending = MessageMediaAttachment(
            id: "pending-local",
            reference: nil,
            fileName: "pending.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first)
        viewModel.replaceMediaReferencesForTesting([listedReference], forMessageId: messageId)
        #expect(viewModel.mediaItems(for: item).map(\.fileName) == ["listed.jpg"])

        viewModel.installPendingMediaForTesting(rowId: item.id, items: [pending])
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.mediaItems(for: item) == [pending])
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

    @Test func receivedMediaDisplayFileNameStripsSpoofingScalars() throws {
        let reference = encryptedMediaReference(
            fileName: "photo\u{202E}gpj.exe",
            plaintextByte: "46",
            ciphertextByte: "47",
            sourceEpoch: 0
        )

        let item = try #require(MessageMediaAttachment.displayItems(from: [reference], ownerId: "msg").first)

        #expect(item.fileName == "photogpj.exe")
        #expect(MessagePreview.mediaFallback([reference]) == "📎 photogpj.exe")
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
    }

    @Test func mediaCacheURLIgnoresUnsafePeerFilenameExtension() throws {
        let reference = encryptedMediaReference(
            fileName: "folder/evil",
            plaintextByte: "7c",
            ciphertextByte: "7d",
            mediaType: "image/png",
            sourceEpoch: 0
        )
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheUnsafeExtensionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory))

        #expect(url.lastPathComponent == "\(reference.plaintextSha256).png")
        #expect(url.deletingLastPathComponent().lastPathComponent == "EncryptedMedia")
    }

    @Test func mediaCacheEvictsExpiredPlaintext() throws {
        let policy = DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60)
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheEvictionAgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let oldReference = encryptedMediaReference(
            plaintextByte: "10",
            ciphertextByte: "11",
            sourceEpoch: 0
        )
        let freshReference = encryptedMediaReference(
            plaintextByte: "12",
            ciphertextByte: "13",
            sourceEpoch: 0
        )
        let oldURL = try #require(MessageMediaCache.cacheURL(for: oldReference, cachesDirectory: cachesDirectory))
        let freshURL = try #require(MessageMediaCache.cacheURL(for: freshReference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(
            Data([0x01]),
            for: oldReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_000)
        )
        MessageMediaCache.store(
            Data([0x02]),
            for: freshReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_061)
        )

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: freshURL.path))
    }

    @Test func mediaCacheEvictsLeastRecentlyUsedPlaintextBySize() throws {
        let policy = DecryptedMediaCacheEvictionPolicy(maxBytes: 8, maxAge: 60 * 60)
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheEvictionSizeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let firstReference = encryptedMediaReference(
            plaintextByte: "20",
            ciphertextByte: "21",
            sourceEpoch: 0
        )
        let secondReference = encryptedMediaReference(
            plaintextByte: "22",
            ciphertextByte: "23",
            sourceEpoch: 0
        )
        let thirdReference = encryptedMediaReference(
            plaintextByte: "24",
            ciphertextByte: "25",
            sourceEpoch: 0
        )
        let firstURL = try #require(MessageMediaCache.cacheURL(for: firstReference, cachesDirectory: cachesDirectory))
        let secondURL = try #require(MessageMediaCache.cacheURL(for: secondReference, cachesDirectory: cachesDirectory))
        let thirdURL = try #require(MessageMediaCache.cacheURL(for: thirdReference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(
            Data(repeating: 0x01, count: 4),
            for: firstReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_000)
        )
        MessageMediaCache.store(
            Data(repeating: 0x02, count: 4),
            for: secondReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_006)
        )
        MessageMediaCache.store(
            Data(repeating: 0x03, count: 4),
            for: thirdReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_012)
        )

        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: thirdURL.path))
    }

    @Test func mediaCacheThrottlesDirectoryWideSweeps() throws {
        let policy = DecryptedMediaCacheEvictionPolicy(maxBytes: 8, maxAge: 60 * 60)
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheSweepThrottleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let firstReference = encryptedMediaReference(
            plaintextByte: "26",
            ciphertextByte: "27",
            sourceEpoch: 0
        )
        let secondReference = encryptedMediaReference(
            plaintextByte: "28",
            ciphertextByte: "29",
            sourceEpoch: 0
        )
        let thirdReference = encryptedMediaReference(
            plaintextByte: "2a",
            ciphertextByte: "2b",
            sourceEpoch: 0
        )
        let firstURL = try #require(MessageMediaCache.cacheURL(for: firstReference, cachesDirectory: cachesDirectory))
        let secondURL = try #require(MessageMediaCache.cacheURL(for: secondReference, cachesDirectory: cachesDirectory))
        let thirdURL = try #require(MessageMediaCache.cacheURL(for: thirdReference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(
            Data(repeating: 0x01, count: 4),
            for: firstReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_000)
        )
        MessageMediaCache.store(
            Data(repeating: 0x02, count: 4),
            for: secondReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_001)
        )
        MessageMediaCache.store(
            Data(repeating: 0x03, count: 4),
            for: thirdReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_002)
        )

        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: thirdURL.path))

        _ = MessageMediaCache.cachedData(
            for: thirdReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_006)
        )

        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: thirdURL.path))
    }

    @Test func playbackStoreReusesContentAddressedMediaCacheForReferencedItems() throws {
        let reference = encryptedMediaReference(
            fileName: "clip.mp4",
            plaintextByte: "30",
            ciphertextByte: "31",
            mediaType: "video/mp4",
            sourceEpoch: 0
        )
        let item = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPlaybackReuseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let expectedURL = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory))

        let playbackURL = try #require(
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x04, 0x05, 0x06]),
                cachesDirectory: cachesDirectory,
                mediaPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                playbackPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                now: Date(timeIntervalSince1970: 1_000)
            )
        )

        #expect(playbackURL == expectedURL)
        #expect(try Data(contentsOf: expectedURL) == Data([0x04, 0x05, 0x06]))
        #expect(!FileManager.default.fileExists(atPath: cachesDirectory.appendingPathComponent("EncryptedMediaPlayback").path))
    }

    @Test func playbackStoreUsesContentHashForUnreferencedItems() throws {
        let item = MessageMediaAttachment(
            id: "draft-reused-id",
            reference: nil,
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            dim: nil,
            localData: nil
        )
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPlaybackContentHashTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        let firstURL = try #require(
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x01]),
                cachesDirectory: cachesDirectory,
                mediaPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                playbackPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
        let secondURL = try #require(
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x02]),
                cachesDirectory: cachesDirectory,
                mediaPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                playbackPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                now: Date(timeIntervalSince1970: 1_001)
            )
        )

        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == Data([0x01]))
        #expect(try Data(contentsOf: secondURL) == Data([0x02]))
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
}

@MainActor
struct MediaComposerAvailabilityTests {

    @Test func v2MediaComponentEnablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "media-ready")
        )

        #expect(viewModel.canSendMediaAttachments)
    }

    @Test func v1MediaComponentStillEnablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(
                name: "legacy-media-ready",
                encryptedMedia: encryptedMediaComponent(version: .v1)
            )
        )

        #expect(viewModel.canSendMediaAttachments)
    }

    @Test func untypedMediaComponentDoesNotEnableAttachmentsFromLegacyString() throws {
        let component = AppGroupEncryptedMediaComponentFfi(
            componentId: 0x800b,
            component: "marmot.group.encrypted-media.v2",
            required: true,
            version: nil,
            mediaFormat: EncryptedMediaVersionFfi.v2.wireValue,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: []
        )
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "unknown-media", encryptedMedia: component)
        )

        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func legacyGroupWithoutMediaComponentDisablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "legacy", encryptedMedia: legacyEncryptedMediaComponent())
        )

        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func pendingInviteDisablesComposerAndAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "invited", pendingConfirmation: true)
        )

        #expect(viewModel.hasPendingInvite)
        #expect(!viewModel.canSendMessages)
        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func inactiveMembershipDisablesComposerAndAttachments() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "removed")
        )
        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "removed", admins: [other]),
                    members: [
                        groupMember(memberIdHex: other, isAdmin: true, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: false,
                    isLastAdmin: false,
                    canInvite: false,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: false,
                    memberActions: [
                        GroupMemberActionStateFfi(
                            memberIdHex: other,
                            isSelf: false,
                            isAdmin: true,
                            canRemove: false,
                            canPromote: false,
                            canDemote: false
                        )
                    ]
                )
            )
        )

        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.inactiveGroupComposerMessage)
        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func durablePendingLeaveFromGroupDetailsDisablesComposer() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "leaving"),
            leaveRequestPending: true
        )

        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "leaving", admins: [other], leaveRequestPending: true),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: false, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: true, isSelf: false),
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: false,
                    isLastAdmin: false,
                    canInvite: false,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: false,
                    leaveRequestPending: true,
                    leaveRequestedAtMs: 1_000,
                    memberActions: [
                        GroupMemberActionStateFfi(
                            memberIdHex: me,
                            isSelf: true,
                            isAdmin: false,
                            canRemove: false,
                            canPromote: false,
                            canDemote: false
                        )
                    ]
                )
            )
        )

        #expect(viewModel.leaveRequestPending)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.leavingGroupComposerMessage)
        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func resolvedTerminalLeaveClearsPendingProjection() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "leaving"),
            leaveRequestPending: true
        )

        viewModel.applyGroupRecord(group(
            name: "left",
            selfMembership: .left
        ))

        #expect(!viewModel.leaveRequestPending)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.leftGroupComposerMessage)
    }

    @Test func publishedTerminalLeaveCanRemainPending() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: group(name: "leaving")
        )

        viewModel.applyGroupRecord(group(
            name: "leaving",
            selfMembership: .left,
            leaveRequestPending: true
        ))

        #expect(viewModel.leaveRequestPending)
        #expect(!viewModel.canSendMessages)
        // The departure is settled even though the group has not committed the
        // removal, and that commit may never arrive — reporting it as progress
        // is what stranded these chats.
        #expect(viewModel.departureStatus == .membershipEnded(.left))
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.leftGroupComposerMessage)
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

    @Test func inactiveComposerReplacesMessageInput() {
        #expect(ComposerAvailabilityPresentation.showsInput(disabledMessage: nil))
        #expect(!ComposerAvailabilityPresentation.showsInput(
            disabledMessage: GroupManagementPresentation.leftGroupComposerMessage
        ))
    }
}

struct ConversationInvitePresentationTests {
    @Test func centeredPromptRequiresPendingInviteWithoutMessages() {
        let systemOnly = [
            TimelineItem.systemEvent(id: "created", event: .groupCreated, timestamp: 1)
        ]
        let withMessage = systemOnly + [TimelineItem.message(message(id: hex("91")))]

        #expect(ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: false,
            timeline: []
        ))
        #expect(ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: false,
            timeline: systemOnly
        ))
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: false,
            timeline: withMessage
        ))
    }

    @Test func invitationTextNamesTheInviterAndFallsBackWhenUnknown() {
        #expect(ConversationInvitePresentation.invitationText(inviterName: "Alice")
            == L10n.formatted("%@ has invited you to a secure chat", "Alice"))
        #expect(ConversationInvitePresentation.invitationText(inviterName: " Alice\n")
            == L10n.formatted("%@ has invited you to a secure chat", "Alice"))
        #expect(ConversationInvitePresentation.invitationText(inviterName: nil)
            == L10n.formatted("%@ has invited you to a secure chat", L10n.string("Someone")))
        #expect(ConversationInvitePresentation.invitationText(inviterName: "   ")
            == L10n.formatted("%@ has invited you to a secure chat", L10n.string("Someone")))
    }

    @Test func inviterAccountIdNormalizationTrimsAndLowercasesForBothSurfaces() {
        let mixedCase = String(repeating: "AB", count: 32)
        let lowercased = String(repeating: "ab", count: 32)

        #expect(ConversationInvitePresentation
            .normalizedInviterAccountId("  \(mixedCase)\n") == lowercased)
        #expect(ConversationInvitePresentation.normalizedInviterAccountId(nil) == nil)
        #expect(ConversationInvitePresentation.normalizedInviterAccountId("   ") == nil)
        #expect(ChatsListViewModel.inviterAccountIdHex(
            pendingConfirmation: true,
            welcomerAccountIdHex: mixedCase,
            directPeerAccountIdHex: nil
        ) == lowercased)
    }

    @Test func centeredPromptDoesNotHideLoadingErrorsOrAcceptedChats() {
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: true,
            isLoading: false,
            timeline: []
        ))
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: true,
            timeline: []
        ))
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: false,
            hasError: false,
            isLoading: false,
            timeline: []
        ))
    }
}

@MainActor
struct ConversationInviteActionTests {
    @Test func acceptClearsPendingStateInPlace() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(
            name: "invited",
            pendingConfirmation: true,
            welcomerAccountIdHex: hex("44")
        )
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        var receivedArguments: (String, String)?
        viewModel.acceptGroupInviteForTesting = { accountRef, groupIdHex in
            receivedArguments = (accountRef, groupIdHex)
            return group(name: "invited", id: groupIdHex)
        }

        let updated = await viewModel.acceptInvite()

        #expect(receivedArguments?.0 == "account-ref")
        #expect(receivedArguments?.1 == pending.groupIdHex)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func declineAppliesArchivedInactiveGroup() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        let declined = group(
            name: "invited",
            id: pending.groupIdHex,
            archived: true,
            selfMembership: .left
        )
        viewModel.declineGroupInviteForTesting = { _, _ in
            GroupInviteDeclineResultFfi(
                group: declined,
                summary: SendSummaryFfi(published: 1, messageIds: [])
            )
        }

        let updated = await viewModel.declineInvite()

        #expect(updated == declined)
        #expect(viewModel.group == declined)
        #expect(!viewModel.hasPendingInvite)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func acceptRetriesOnceWhenWorkerIsDefinitelyBusy() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        var attempts = 0
        var refreshes = 0
        viewModel.acceptGroupInviteForTesting = { _, groupIdHex in
            attempts += 1
            if attempts == 1 {
                throw MarmotKitError.AccountWorkerBusy
            }
            return group(name: "invited", id: groupIdHex)
        }
        viewModel.refreshInviteStateForTesting = {
            refreshes += 1
            return true
        }

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 2)
        #expect(refreshes == 1)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
    }

    @Test func acceptTimeoutRefreshesStateWithoutRetryingAmbiguousOperation() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        var attempts = 0
        viewModel.acceptGroupInviteForTesting = { _, _ in
            attempts += 1
            throw MarmotKitError.AccountWorkerResponseTimedOut
        }
        viewModel.refreshInviteStateForTesting = {
            viewModel.applyGroupRecord(group(name: "invited", id: pending.groupIdHex))
            return true
        }

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 1)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
    }

    @Test func staleAcceptRefreshesTheTerminalGroupWithoutRetrying() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        let terminal = group(
            name: "invited",
            id: pending.groupIdHex,
            archived: true,
            selfMembership: .left
        )
        var attempts = 0
        viewModel.acceptGroupInviteForTesting = { _, _ in
            attempts += 1
            throw MarmotKitError.GroupInviteNotPending
        }
        viewModel.refreshInviteStateForTesting = {
            viewModel.applyGroupRecord(terminal)
            return true
        }

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 1)
        #expect(updated == terminal)
        #expect(!viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func unrecoverableGroupDisablesComposerBeforeSend() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "damaged", unrecoverable: true)
        )

        #expect(viewModel.isGroupUnrecoverable)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage?.contains("rejoined") == true)
    }
}

struct MarmotKitMasterIntegrationTests {
    @Test func sendAcceptancePolicyDistinguishesPublishedFromDurablyPending() {
        let published = SendSummaryFfi(
            published: 1,
            messageIds: ["message-id"],
            acceptDisposition: .published,
            maintenanceDisposition: .ready
        )
        let pending = SendSummaryFfi(
            published: 0,
            messageIds: [],
            acceptDisposition: .acceptedPending,
            maintenanceDisposition: .postJoinRotationPendingRetryable
        )
        let completionUnknown = SendSummaryFfi(
            published: 0,
            messageIds: [],
            acceptDisposition: .completionUnknown,
            maintenanceDisposition: .ready
        )

        #expect(SendAcceptancePolicy.action(for: published) == .confirmPublished(messageId: "message-id"))
        #expect(SendAcceptancePolicy.action(for: pending) == .awaitDurableProjection)
        #expect(SendAcceptancePolicy.action(for: completionUnknown) == .awaitDurableProjection)
    }

    @MainActor
    @Test func durablyAcceptedComposerOutcomesKeepClockWithoutFailureUI() async throws {
        for disposition in [SendAcceptDispositionFfi.acceptedPending, .completionUnknown] {
            let appState = AppState(client: try MarmotClient.testClient())
            appState.activeAccountRef = "account-ref"
            let timelineStore = TimelineStore(appState: appState, groupIdHex: hex("aa"))
            let composer = ComposerModel(
                appState: appState,
                groupIdHex: hex("aa"),
                timelineStore: timelineStore
            )
            composer.canSendMessages = { true }
            var surfacedErrors: [String] = []
            composer.onError = { surfacedErrors.append($0) }
            composer.sendTextForTesting = { _, _, _, _ in
                SendSummaryFfi(
                    published: 0,
                    messageIds: [],
                    acceptDisposition: disposition,
                    maintenanceDisposition: .ready
                )
            }

            await composer.send("durably retained")

            let statuses = timelineStore.timeline.compactMap { item -> MessageStatus? in
                guard case .message(_, let status) = item.kind else { return nil }
                return status
            }
            #expect(statuses == [.sending])
            #expect(surfacedErrors.isEmpty)
            #expect(appState.activeToast == nil)
        }
    }

    @MainActor
    @Test func thrownTransientComposerSendRendersFailedAndSurfacesFailure() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let timelineStore = TimelineStore(appState: appState, groupIdHex: hex("aa"))
        let composer = ComposerModel(
            appState: appState,
            groupIdHex: hex("aa"),
            timelineStore: timelineStore
        )
        composer.canSendMessages = { true }
        var surfacedErrors: [String] = []
        composer.onError = { surfacedErrors.append($0) }
        composer.sendTextForTesting = { _, _, _, _ in
            throw NSError(domain: "ComposerSendTests", code: 1)
        }

        await composer.send("not retained")

        let statuses = timelineStore.timeline.compactMap { item -> MessageStatus? in
            guard case .message(_, let status) = item.kind else { return nil }
            return status
        }
        #expect(statuses == [.failed])
        #expect(surfacedErrors.count == 1)
        #expect(appState.activeToast != nil)
    }

    @Test func accountWorkerErrorsExposeRetrySafetySemantics() {
        #expect(MarmotKitError.AccountWorkerBusy.isAccountWorkerBusy)
        #expect(!MarmotKitError.AccountWorkerBusy.isAccountWorkerResponseTimedOut)
        #expect(MarmotKitError.AccountWorkerResponseTimedOut.isAccountWorkerResponseTimedOut)
        #expect(!MarmotKitError.AccountWorkerResponseTimedOut.isAccountWorkerBusy)
    }

    @Test func convergenceRetryPolicyRefreshesAmbiguousResultsAndStopsUnrecoverableGroups() {
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.AccountWorkerBusy
        ) == .retry)
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.AccountWorkerResponseTimedOut
        ) == .refreshBeforeRetry)
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: "group")
        ) == .stop)
    }

    @Test @MainActor func hostPerformanceSnapshotRoundTripsThroughBindings() throws {
        let client = try MarmotClient.testClient()
        let before = client.appPerformanceSnapshot().hostSplashReady

        client.recordHostPerformance(
            operation: .splashReady,
            durationMs: 250,
            outcome: .success
        )
        let after = client.appPerformanceSnapshot().hostSplashReady

        #expect(after.attempts >= before.attempts + 1)
        #expect(after.successes >= before.successes + 1)
        #expect(after.durationMs.sumMs >= before.durationMs.sumMs + 250)
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

    @Test func rejectsSVGFromImageClassificationAndSupport() {
        #expect(MediaAttachmentPolicy.isDecodableImageMediaType("image/png"))
        #expect(MediaAttachmentPolicy.isDecodableImageMediaType("image/jpeg"))
        #expect(!MediaAttachmentPolicy.isDecodableImageMediaType("image/svg+xml"))
        #expect(!MediaAttachmentPolicy.isDecodableImageMediaType("image/svg+xml; charset=utf-8"))
        #expect(!MediaAttachmentPolicy.isDecodableImageMediaType("IMAGE/SVG+XML"))

        // SVG must not classify as an image (it would otherwise reach the
        // ImageIO thumbnail decoder via the peer-controlled MLS media path).
        #expect(MediaAttachmentKind.classify(mediaType: "image/png") == .image)
        #expect(MediaAttachmentKind.classify(mediaType: "image/svg+xml") == .unsupported)
        #expect(!MediaAttachmentPolicy.isSupported(mediaType: "image/svg+xml"))
    }

    @Test func fileExtensionFallsBackWhenPeerFilenameExtensionIsUnsafe() {
        #expect(MediaAttachmentPolicy.fileExtension(for: "image/png", fileName: "safe.PNG") == "png")
        #expect(MediaAttachmentPolicy.fileExtension(for: "image/png", fileName: "nested/x/y") == "png")
        #expect(MediaAttachmentPolicy.fileExtension(for: "application/pdf", fileName: "report.\(String(repeating: "a", count: 13))") == "pdf")
        #expect(MediaAttachmentPolicy.mediaType(forFileExtension: "x/y") == nil)
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
        #expect(attachment.thumbhash == nil)
    }

    @Test func imageDraftGeneratesDimAndThumbhashForUpload() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120), format: format)
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 60))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 60, width: 240, height: 60))
        }

        let attachment = try MediaDraftProcessor.attachment(
            from: data,
            fileName: "photo.jpg",
            typeIdentifier: "public.jpeg"
        )

        #expect(attachment.mediaType == "image/jpeg")
        #expect(attachment.dim == "240x120")

        let thumbhash = try #require(attachment.thumbhash)
        #expect(!thumbhash.isEmpty)
        // A ThumbHash is ~25 bytes -> ~34 base64 chars; comfortably under the
        // 128-char encrypted-media bound and standard-base64 alphabet.
        #expect(thumbhash.count <= 128)
        #expect(Data(base64Encoded: thumbhash) != nil)

        // The upload request must carry the generated render hints through to
        // the binding layer.
        let request = attachment.uploadRequest
        #expect(request.dim == "240x120")
        #expect(request.thumbhash == thumbhash)
    }

    @Test func imageThumbhashSurvivesImetaRoundTrip() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }

        let attachment = try MediaDraftProcessor.attachment(
            from: data,
            fileName: "photo.jpg",
            typeIdentifier: "public.jpeg"
        )
        let thumbhash = try #require(attachment.thumbhash)

        let reference = MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(
                kind: "blossom-v1",
                value: "https://example.com/\(String(repeating: "a", count: 64)).bin"
            )],
            ciphertextSha256: String(repeating: "a", count: 64),
            plaintextSha256: String(repeating: "b", count: 64),
            nonceHex: String(repeating: "c", count: 24),
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            version: .v1,
            sourceEpoch: 7,
            dim: attachment.dim,
            thumbhash: thumbhash
        )

        let tag = MessageSemantics.imetaTag(for: reference)
        #expect(tag.values.contains("thumbhash \(thumbhash)"))

        let decoded = try #require(MessageSemantics.mediaAttachments(
            from: [tag],
            sourceEpoch: 7
        ))
        #expect(decoded.count == 1)
        #expect(decoded[0].thumbhash == thumbhash)
        #expect(decoded[0].dim == attachment.dim)
    }

    @Test func voiceGestureOnlyLocksAfterSlideUpThreshold() {
        #expect(!VoiceRecordingGesturePolicy.shouldLock(translation: CGSize(width: 0, height: -40)))
        #expect(VoiceRecordingGesturePolicy.shouldLock(translation: CGSize(width: 0, height: -90)))
    }
}

struct ThumbHashDecoderTests {

    @Test func rejectsMalformedAndOversizedHashes() {
        #expect(ThumbHash.decodedImage(from: "") == nil)
        #expect(ThumbHash.decodedImage(from: "!!!!") == nil)
        #expect(ThumbHash.decodedImage(from: Data([0, 1, 2, 3]).base64EncodedString()) == nil)
        #expect(ThumbHash.decodedImage(from: Data(repeating: 0, count: 65).base64EncodedString()) == nil)
        #expect(ThumbHash.decodedImage(from: String(repeating: "A", count: 65)) == nil)
    }

    @Test func decodesNeutralPortraitPixelsWithinNaturalBounds() throws {
        let bytes: [UInt8] = [0x20, 0x08, 0x02, 0x05, 0x00] + Array(repeating: 0, count: 16)
        let decoded = try #require(ThumbHash.decodedImage(from: Data(bytes).base64EncodedString()))

        #expect(decoded.width == 23)
        #expect(decoded.height == 32)
        #expect(decoded.rgba.count == decoded.width * decoded.height * 4)
        let center = ((decoded.height / 2) * decoded.width + decoded.width / 2) * 4
        #expect(abs(Int(decoded.rgba[center]) - 127) <= 8)
        #expect(abs(Int(decoded.rgba[center + 1]) - 127) <= 8)
        #expect(abs(Int(decoded.rgba[center + 2]) - 127) <= 8)
        #expect(decoded.rgba[center + 3] == 255)
    }

    @Test func decodesLandscapeAndUnpaddedBase64() throws {
        let bytes: [UInt8] = [0x20, 0x08, 0x02, 0x04, 0x80] + Array(repeating: 0, count: 15)
        let unpadded = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let decoded = try #require(ThumbHash.decodedImage(from: unpadded))

        #expect(decoded.width == 32)
        #expect(decoded.height == 18)
        #expect(decoded.rgba.count == decoded.width * decoded.height * 4)
    }

    @MainActor
    @Test func imageCacheCoalescesConcurrentDecodes() async {
        let probe = ThumbHashDecoderProbe(shouldSuspend: true)
        let cache = ThumbHashImageCache { encoded in
            await probe.decode(encoded)
        }

        let first = Task { @MainActor in await cache.image(for: "same") }
        await probe.waitUntilStarted()
        let second = Task { @MainActor in await cache.image(for: "same") }
        for _ in 0..<10 { await Task.yield() }

        #expect(await probe.callCount() == 1)
        await probe.release()
        let firstImage = await first.value
        let secondImage = await second.value
        #expect(firstImage == nil)
        #expect(secondImage == nil)
    }

    @MainActor
    @Test func imageCacheClearsCompletedDecode() async {
        let probe = ThumbHashDecoderProbe(shouldSuspend: false)
        let cache = ThumbHashImageCache { encoded in
            await probe.decode(encoded)
        }

        let firstImage = await cache.image(for: "same")
        let secondImage = await cache.image(for: "same")
        #expect(firstImage == nil)
        #expect(secondImage == nil)
        #expect(await probe.callCount() == 2)
    }
}

private actor ThumbHashDecoderProbe {
    private let shouldSuspend: Bool
    private var decodeCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(shouldSuspend: Bool) {
        self.shouldSuspend = shouldSuspend
    }

    func decode(_: String) async -> ThumbHash.DecodedImage? {
        decodeCount += 1
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll()

        if shouldSuspend, !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return nil
    }

    func waitUntilStarted() async {
        guard decodeCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }

    func callCount() -> Int {
        decodeCount
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

/// Regression coverage for WhiteNoise-ios#208: received audio is peer-controlled
/// and `MediaWaveformAnalyzer` must keep decoded-PCM memory bounded rather than
/// allocating one buffer sized to the whole (attacker-influenced) file length.
struct MediaWaveformAnalyzerBoundsTests {

    @Test func analyzedFrameCountClampsHostileDeclaredLength() {
        // A near-cap AAC file can declare a huge decoded length. The analyzer
        // must never analyze more than the hard ceiling regardless.
        let hostile: AVAudioFramePosition = 50_000_000_000
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: hostile)
            == MediaWaveformAnalyzer.maxAnalyzedFrames)
    }

    @Test func analyzedFrameCountPassesShortFilesThrough() {
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: 1_000) == 1_000)
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: 0) == 0)
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: -5) == 0)
    }

    @Test func nextChunkNeverExceedsFixedCapacity() {
        // The core memory invariant: no single read allocates more than the
        // chunk capacity, even when billions of frames remain.
        let analyzed = MediaWaveformAnalyzer.maxAnalyzedFrames
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        let first = MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: 0,
            chunkCapacity: capacity
        )
        #expect(first == capacity)
    }

    @Test func nextChunkShrinksToRemainderOnFinalRead() {
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        let cap = AVAudioFramePosition(capacity)
        let analyzed = cap + 100
        let last = MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: cap,
            chunkCapacity: capacity
        )
        #expect(last == 100)
    }

    @Test func nextChunkReturnsZeroWhenComplete() {
        let analyzed: AVAudioFramePosition = 1_000
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        #expect(MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: analyzed,
            chunkCapacity: capacity
        ) == 0)
        #expect(MediaWaveformAnalyzer.nextChunkFrameCount(
            analyzedFrames: analyzed,
            framesProcessed: analyzed + 50,
            chunkCapacity: capacity
        ) == 0)
    }

    @Test func chunkFrameCapacityBoundsAllocationBytesAgainstHostileChannelCount() {
        // The byte-budget invariant (WhiteNoise-ios#208 adversarial finding): a
        // fixed frame count alone does NOT bound memory because per-frame cost
        // scales with the peer-controlled channel count. Derive frame capacity
        // from a fixed PCM byte budget and assert the resulting buffer allocation
        // never exceeds that budget, regardless of channels.
        let bytesPerSample = MemoryLayout<Float>.size // 4 (float PCM)
        for channels: AVAudioChannelCount in [1, 2, 6, 8, 32, 1_024, 65_535] {
            let frames = MediaWaveformAnalyzer.chunkFrameCapacity(
                channelCount: channels,
                bytesPerSample: bytesPerSample
            )
            #expect(frames >= 1) // never degenerates to a zero-frame read
            let allocationBytes = Int(frames) * Int(channels) * bytesPerSample
            #expect(allocationBytes <= MediaWaveformAnalyzer.maxChunkBytes)
        }
    }

    @Test func chunkFrameCapacityHonoursFrameCeilingForNarrowAudio() {
        // Mono/stereo files fit far more frames than the ceiling within the byte
        // budget, so the frame ceiling (not the byte budget) governs there.
        let frames = MediaWaveformAnalyzer.chunkFrameCapacity(
            channelCount: 1,
            bytesPerSample: MemoryLayout<Float>.size
        )
        #expect(frames == MediaWaveformAnalyzer.chunkFrameCapacityCeiling)
    }

    @Test func chunkFrameCapacityToleratesDegenerateInputs() {
        // Zero / nonsense inputs must still yield at least one frame so the
        // streaming loop terminates rather than spinning on zero-frame reads.
        #expect(MediaWaveformAnalyzer.chunkFrameCapacity(channelCount: 0, bytesPerSample: 0) >= 1)
        #expect(MediaWaveformAnalyzer.chunkFrameCapacity(channelCount: 1, bytesPerSample: 0) >= 1)
    }

    @Test func chunkedReadsCoverEveryFrameExactlyOnce() {
        // Simulate the streaming loop and confirm it terminates and processes
        // exactly `analyzedFrames` frames without overrun — no infinite loop on
        // a hostile length, no double counting.
        let capacity = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        let analyzed = AVAudioFramePosition(capacity) * 3 + 17
        var processed: AVAudioFramePosition = 0
        var iterations = 0
        while true {
            let toRead = MediaWaveformAnalyzer.nextChunkFrameCount(
                analyzedFrames: analyzed,
                framesProcessed: processed,
                chunkCapacity: capacity
            )
            if toRead == 0 { break }
            #expect(toRead <= capacity)
            processed += AVAudioFramePosition(toRead)
            iterations += 1
            #expect(iterations < 10_000) // guard against a non-terminating loop
        }
        #expect(processed == analyzed)
        #expect(iterations == 4)
    }

    @Test func bucketIndexSpreadsFramesAcrossBucketsInOrder() {
        let analyzed: AVAudioFramePosition = 360
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 0, analyzedFrames: analyzed) == 0)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 359, analyzedFrames: analyzed)
            == MediaWaveformAnalyzer.sampleCount - 1)
        // Monotonic non-decreasing mapping.
        var previous = 0
        for frame in stride(from: AVAudioFramePosition(0), to: analyzed, by: 1) {
            let bucket = MediaWaveformAnalyzer.bucketIndex(forFrame: frame, analyzedFrames: analyzed)
            #expect(bucket >= previous)
            previous = bucket
        }
    }

    @Test func bucketIndexClampsOutOfRangeFrames() {
        let analyzed: AVAudioFramePosition = 100
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: -10, analyzedFrames: analyzed) == 0)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 10_000, analyzedFrames: analyzed)
            == MediaWaveformAnalyzer.sampleCount - 1)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 5, analyzedFrames: 0) == 0)
    }
}

struct ComposerAudioDraftPreviewPresentationTests {

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

    @Test func durationLabelClampsNonFiniteDraftDurations() {
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(.nan) == "0:00")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(.infinity) == "0:00")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(-.infinity) == "0:00")
    }

    @Test func durationLabelUsesLocalizedDigits() {
        let locale = Locale(identifier: "ar_EG")
        let expected = L10n.formatted(
            "%@:%@",
            arguments: [
                String(format: "%lld", locale: locale, Int64(1)),
                String(format: "%02lld", locale: locale, Int64(5))
            ],
            locale: locale
        )

        #expect(AudioDurationLabel.label(for: 65, locale: locale) == expected)
        #expect(AudioDurationLabel.label(for: 65, locale: locale) != "1:05")
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
        // The size gate runs before any bytes are materialized in memory.
        #expect(!PhotoLibrarySelection.admitsSelection(bytes: 0, cap: 100))
        #expect(PhotoLibrarySelection.admitsSelection(bytes: 100, cap: 100))
        #expect(!PhotoLibrarySelection.admitsSelection(bytes: 101, cap: 100))
        // Under the per-item cap but over the remaining session budget: the
        // sum of accepted selections is bounded, not just each item.
        #expect(!PhotoLibrarySelection.admitsSelection(bytes: 80, cap: 100, remaining: 50))
        #expect(PhotoLibrarySelection.admitsSelection(bytes: 50, cap: 100, remaining: 50))

        let selections = PhotoLibrarySelection.compactPreservingPickerOrder([first, nil, third])

        #expect(selections.map(\.fileName) == ["first.jpg", "third.jpg"])
    }
}

struct MessageMediaGridPresentationTests {

    @Test func gridShowsAtMostFiveTilesAndCountsHiddenAttachments() {
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 4) == 4)
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 6) == 5)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 4) == 0)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 6) == 1)
    }

    @Test func gridUsesSingleTileOneRowOrTwoByTwoLayouts() {
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 2) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 2) == 1)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 3) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 3) == 2)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 10) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 10) == 3)
    }

    @Test func galleryCompositionMatchesDesignedTwoThreeAndFiveItemFrames() {
        let two = MessageMediaGridPresentation.layout(totalCount: 2, maxWidth: 256)
        #expect(two.size == CGSize(width: 256, height: 127))
        #expect(two.frames == [
            CGRect(x: 0, y: 0, width: 127, height: 127),
            CGRect(x: 129, y: 0, width: 127, height: 127),
        ])

        let three = MessageMediaGridPresentation.layout(totalCount: 3, maxWidth: 256)
        #expect(three.size == CGSize(width: 256, height: 170))
        #expect(three.frames == [
            CGRect(x: 0, y: 0, width: 170, height: 170),
            CGRect(x: 172, y: 0, width: 84, height: 84),
            CGRect(x: 172, y: 86, width: 84, height: 84),
        ])

        let overflow = MessageMediaGridPresentation.layout(totalCount: 7, maxWidth: 256)
        #expect(overflow.size == CGSize(width: 256, height: 213))
        #expect(overflow.frames.count == 5)
        #expect(overflow.overflowCount == 2)
    }

    @Test func galleryCompositionScalesToTheAvailableBubbleWidth() {
        let layout = MessageMediaGridPresentation.layout(totalCount: 2, maxWidth: 128)
        #expect(layout.size == CGSize(width: 128, height: 63.5))
        #expect(layout.frames[0] == CGRect(x: 0, y: 0, width: 63.5, height: 63.5))
        #expect(layout.frames[1] == CGRect(x: 64.5, y: 0, width: 63.5, height: 63.5))
    }

    @Test func gridRoundsOnlyOuterTileCorners() {
        let single = MessageMediaGridPresentation.roundedCorners(totalCount: 1, tileIndex: 0)
        #expect(single.topLeading)
        #expect(single.topTrailing)
        #expect(single.bottomLeading)
        #expect(single.bottomTrailing)

        let leadingTile = MessageMediaGridPresentation.roundedCorners(totalCount: 2, tileIndex: 0)
        #expect(leadingTile.topLeading)
        #expect(!leadingTile.topTrailing)
        #expect(leadingTile.bottomLeading)
        #expect(!leadingTile.bottomTrailing)

        let trailingTile = MessageMediaGridPresentation.roundedCorners(totalCount: 2, tileIndex: 1)
        #expect(!trailingTile.topLeading)
        #expect(trailingTile.topTrailing)
        #expect(!trailingTile.bottomLeading)
        #expect(trailingTile.bottomTrailing)

        let bottomRight = MessageMediaGridPresentation.roundedCorners(totalCount: 4, tileIndex: 3)
        #expect(!bottomRight.topLeading)
        #expect(!bottomRight.topTrailing)
        #expect(!bottomRight.bottomLeading)
        #expect(bottomRight.bottomTrailing)

        let sparseBottomLeft = MessageMediaGridPresentation.roundedCorners(totalCount: 3, tileIndex: 2)
        #expect(!sparseBottomLeft.topLeading)
        #expect(!sparseBottomLeft.topTrailing)
        #expect(sparseBottomLeft.bottomLeading)
        #expect(sparseBottomLeft.bottomTrailing)

        let sparseEmptySlot = MessageMediaGridPresentation.roundedCorners(totalCount: 3, tileIndex: 3)
        #expect(!sparseEmptySlot.hasRoundedCorners)

        let negativeIndex = MessageMediaGridPresentation.roundedCorners(totalCount: 3, tileIndex: -1)
        #expect(!negativeIndex.hasRoundedCorners)
    }

    @Test func semanticGridCornersMirrorForRightToLeftLayout() {
        let leadingCorners = MessageMediaTileCornerRadii(
            topLeading: true,
            topTrailing: false,
            bottomLeading: true,
            bottomTrailing: false
        )
        let trailingCorners = MessageMediaTileCornerRadii(
            topLeading: false,
            topTrailing: true,
            bottomLeading: false,
            bottomTrailing: true
        )

        let leadingLeftToRight = leadingCorners.uiRectCorners(layoutDirection: .leftToRight)
        #expect(leadingLeftToRight.contains(.topLeft))
        #expect(leadingLeftToRight.contains(.bottomLeft))
        #expect(!leadingLeftToRight.contains(.topRight))
        #expect(!leadingLeftToRight.contains(.bottomRight))

        let leadingRightToLeft = leadingCorners.uiRectCorners(layoutDirection: .rightToLeft)
        #expect(!leadingRightToLeft.contains(.topLeft))
        #expect(!leadingRightToLeft.contains(.bottomLeft))
        #expect(leadingRightToLeft.contains(.topRight))
        #expect(leadingRightToLeft.contains(.bottomRight))

        let trailingLeftToRight = trailingCorners.uiRectCorners(layoutDirection: .leftToRight)
        #expect(!trailingLeftToRight.contains(.topLeft))
        #expect(!trailingLeftToRight.contains(.bottomLeft))
        #expect(trailingLeftToRight.contains(.topRight))
        #expect(trailingLeftToRight.contains(.bottomRight))

        let trailingRightToLeft = trailingCorners.uiRectCorners(layoutDirection: .rightToLeft)
        #expect(trailingRightToLeft.contains(.topLeft))
        #expect(trailingRightToLeft.contains(.bottomLeft))
        #expect(!trailingRightToLeft.contains(.topRight))
        #expect(!trailingRightToLeft.contains(.bottomRight))
    }
}

struct MessageMediaThumbnailPresentationTests {

    @Test func thumbnailCacheKeySurvivesSourceEpochRefresh() {
        let initial = attachment(
            id: "row:\(hex("33")):0:0",
            reference: encryptedMediaReference(
                fileName: "photo.jpg",
                mediaType: "image/jpeg",
                dim: "640x480",
                sourceEpoch: 0
            )
        )
        let refreshed = attachment(
            id: "row:\(hex("33")):42:0",
            reference: encryptedMediaReference(
                fileName: "photo.jpg",
                mediaType: "image/jpeg",
                dim: "640x480",
                sourceEpoch: 42
            )
        )

        #expect(MessageMediaThumbnailPresentation.cacheKey(for: initial) == MessageMediaThumbnailPresentation.cacheKey(for: refreshed))
    }

    @Test func thumbnailCacheKeyFallsBackToItemIdForLocalImage() {
        let local = attachment(id: "local-image", reference: nil)

        #expect(MessageMediaThumbnailPresentation.cacheKey(for: local) == "item:local-image")
    }

    private func attachment(
        id: String,
        reference: MediaAttachmentReferenceFfi?
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: reference,
            fileName: reference?.fileName ?? "local.jpg",
            mediaType: reference?.mediaType ?? "image/jpeg",
            dim: reference?.dim,
            localData: nil
        )
    }
}

struct MessageImageBubblePresentationTests {

    @Test func mediaOnlyPortraitBubbleWrapsRenderedImageWidth() {
        let renderedSize = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "1080x1920"
        )

        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: renderedSize.width,
            hasCaption: false,
            hasReply: false
        ) == renderedSize.width)
    }

    @Test func captionOrReplyKeepsRichMediaBubbleReadable() {
        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: 228,
            hasCaption: true,
            hasReply: false
        ) == 300)
        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: 228,
            hasCaption: false,
            hasReply: true
        ) == 300)
    }

    @Test func landscapeImageUsesActualAspectRatio() {
        let size = MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "640x360")

        #expect(size.width == 300)
        #expect(size.height == 169)
    }

    @Test func portraitImageNarrowsAndCapsItsHeight() {
        let size = MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "1080x1920")

        #expect(size.width == 228)
        #expect(size.height == 405)
    }

    @Test func missingOrMalformedImageDimensionsUseSquareFallback() {
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: nil) == CGSize(width: 300, height: 300))
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "bad") == CGSize(width: 300, height: 300))
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "0x400") == CGSize(width: 300, height: 300))
    }

    @Test func extremeImageDimensionsAreClamped() {
        #expect(MessageImageBubblePresentation.aspectRatio(dim: "10000x1") == 4)
        #expect(MessageImageBubblePresentation.aspectRatio(dim: "1x10000") == 0.25)
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
    @Test func playbackIconReflectsPlayerState() {
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: false, didFail: false) == "play.fill")
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: true, didFail: false) == "pause.fill")
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: false, didFail: true) == "arrow.clockwise")
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: true, didFail: true) == "pause.fill")
    }

    @Test func missingDurationDoesNotReserveLabelSpace() {
        #expect(MessageAudioBubblePresentation.durationLabel(nil) == nil)
    }

    @Test func durationLabelMatchesBubbleFormat() {
        #expect(MessageAudioBubblePresentation.durationLabel(2.9) == "0:02")
        #expect(MessageAudioBubblePresentation.durationLabel(65) == "1:05")
    }

    @Test func nonFiniteDurationDoesNotReserveLabelSpace() {
        #expect(MessageAudioBubblePresentation.durationLabel(.nan) == nil)
        #expect(MessageAudioBubblePresentation.durationLabel(.infinity) == nil)
        #expect(MessageAudioBubblePresentation.durationLabel(-.infinity) == nil)
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

struct ComposerMediaDraftLayoutTests {
    @Test func visualPreviewPreservesAspectRatioWithinShelfBounds() {
        #expect(ComposerMediaDraftLayout.previewWidth(dim: "1600x900", thumbnailSize: nil) == 199)
        #expect(ComposerMediaDraftLayout.previewWidth(dim: "400x1200", thumbnailSize: nil) == 68)
        #expect(ComposerMediaDraftLayout.previewWidth(dim: "4000x500", thumbnailSize: nil) == 200)
    }

    @Test func malformedDimensionsUsePreparedThumbnailOrSquareFallback() {
        #expect(ComposerMediaDraftLayout.previewWidth(
            dim: "not-dimensions",
            thumbnailSize: CGSize(width: 150, height: 100)
        ) == 168)
        #expect(ComposerMediaDraftLayout.previewWidth(dim: "0x10", thumbnailSize: nil) == 112)
    }

    @Test func mediaSelectionReviewsOnlyVisualDraftsAndPreservesOtherAttachmentOrder() throws {
        let firstImage = MediaDraftAttachment(
            fileName: "first.jpg",
            mediaType: "image/jpeg",
            data: Data([1]),
            dim: "100x100"
        )
        let document = MediaDraftAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data([2]),
            dim: nil
        )
        let video = MediaDraftAttachment(
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            data: Data([3]),
            dim: "1920x1080"
        )
        let all = [firstImage, document, video]
        let selection = try #require(ComposerMediaSelection(
            attachments: all,
            initialItemID: firstImage.id
        ))

        #expect(selection.attachments.map(\.id) == [firstImage.id, video.id])
        #expect(selection.applying(includedItemIDs: [video.id], to: all).map(\.id) == [document.id, video.id])
        #expect(selection.applying(includedItemIDs: [], to: all).map(\.id) == [document.id])
    }
}

@MainActor
struct MessageMediaGalleryTests {

    @Test func galleryRejectsNonVisualInitialItem() {
        let image = attachment(id: "image", mediaType: "image/png")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = MessageMediaGallery(
            items: [image, document],
            initialItem: document,
            initialImageData: Data()
        )

        #expect(gallery == nil)
    }

    @Test func galleryKeepsImageAndVideoPagesWhenInitialImageIsInList() throws {
        let image = attachment(id: "image", mediaType: "image/png")
        let video = attachment(id: "video", mediaType: "video/mp4")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = try #require(MessageMediaGallery(
            items: [image, video, document],
            initialItem: image,
            initialImageData: imageData()
        ))

        #expect(gallery.items.map(\.id) == ["image", "video"])
        #expect(gallery.initialItemID == "image")
    }

    @Test func galleryRetainsMessageDestinationsForVisualItems() throws {
        let image = attachment(id: "image", mediaType: "image/png")
        let video = attachment(id: "video", mediaType: "video/mp4")
        let document = attachment(id: "document", mediaType: "application/pdf")
        let messageIds = [
            image.id: "image-message",
            video.id: "video-message",
            document.id: "document-message",
        ]

        let gallery = try #require(MessageMediaGallery(
            items: [image, video, document],
            initialItem: image,
            messageIdByItemID: messageIds
        ))

        #expect(gallery.messageIdByItemID[image.id] == "image-message")
        #expect(gallery.messageIdByItemID[video.id] == "video-message")
    }

    @Test func galleryAcceptsVideoInitialItem() throws {
        let image = attachment(id: "image", mediaType: "image/png")
        let video = attachment(id: "video", mediaType: "video/mp4")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = try #require(MessageMediaGallery(
            items: [image, video, document],
            initialItem: video,
            initialMediaData: nil
        ))

        #expect(gallery.items.map(\.id) == ["image", "video"])
        #expect(gallery.initialItemID == "video")
        #expect(gallery.initialData(for: video) == nil)
    }

    @Test func galleryPrependsMissingVisualInitialItem() throws {
        let initial = attachment(id: "initial", mediaType: "image/png")
        let otherImage = attachment(id: "other", mediaType: "image/jpeg")
        let video = attachment(id: "video", mediaType: "video/quicktime")
        let document = attachment(id: "document", mediaType: "application/pdf")
        let data = imageData()

        let gallery = try #require(MessageMediaGallery(
            items: [document, otherImage, video],
            initialItem: initial,
            initialImageData: data
        ))

        #expect(gallery.items.map(\.id) == ["initial", "other", "video"])
        #expect(gallery.initialData(for: initial) == data)
        #expect(gallery.initialData(for: otherImage) == nil)
    }

    @Test func pageCountLabelUsesLocalizedCatalogPhrase() {
        #expect(MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: 1,
            totalCount: 12,
            locale: Locale(identifier: "fr")
        ) == "2 sur 12")
    }

    @Test func pageCountLabelLocalizesDigits() {
        let locale = Locale(identifier: "ar_EG")
        let label = MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: 1,
            totalCount: 12,
            locale: locale
        )

        #expect(label.contains(LocalizedNumberLabel.decimal(2, locale: locale)))
        #expect(label.contains(LocalizedNumberLabel.decimal(12, locale: locale)))
        #expect(label != "2 of 12")
    }

    @Test func pageCountLabelFallsBackToEmptyWhenSelectionIsMissing() {
        #expect(MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: nil,
            totalCount: 3
        ).isEmpty)
    }

    @Test func fullscreenActionsRequireTheirRuntimeInputs() {
        #expect(MessageMediaFullscreenGalleryPresentation.canGoToMessage(
            messageId: "message-id",
            hasHandler: true
        ))
        #expect(!MessageMediaFullscreenGalleryPresentation.canGoToMessage(
            messageId: "",
            hasHandler: true
        ))
        #expect(!MessageMediaFullscreenGalleryPresentation.canGoToMessage(
            messageId: "message-id",
            hasHandler: false
        ))
        #expect(MessageMediaFullscreenGalleryPresentation.canForward(
            hasPreparedMedia: true,
            hasForwardingContext: true
        ))
        #expect(!MessageMediaFullscreenGalleryPresentation.canForward(
            hasPreparedMedia: false,
            hasForwardingContext: true
        ))
    }

    @Test func fullscreenInitialDecodeFailureIsExplicit() async {
        // Invalid bytes decode to nil off-main rather than crashing or
        // returning a bogus image.
        #expect(await MessageMediaFullscreenPresentation.decodedImage(
            from: Data([0x00]),
            maxPixelSize: 64,
            scale: 1
        ) == nil)
        // Nil data short-circuits to nil without touching the decoder.
        #expect(await MessageMediaFullscreenPresentation.decodedImage(
            from: nil,
            maxPixelSize: 64,
            scale: 1
        ) == nil)
        // Valid bytes decode to a bounded, non-empty image.
        let decoded = await MessageMediaFullscreenPresentation.decodedImage(
            from: imageData(),
            maxPixelSize: 64,
            scale: 1
        )
        #expect(decoded != nil)
        #expect((decoded?.size.width ?? 0) > 0)
    }

    @Test func fullscreenMaxPixelSizeIsScreenBoundedAndPositive() {
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: 2532) == 2532)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: 0) == 1)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: -10) == 1)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: .infinity) == 1)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: 100.4) == 101)
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

struct CameraCapturePresentationTests {
    @Test func recordingDurationUsesMinuteAndZeroPaddedSecondFields() {
        #expect(CameraCapturePresentation.durationLabel(0) == "0:00")
        #expect(CameraCapturePresentation.durationLabel(9.99) == "0:09")
        #expect(CameraCapturePresentation.durationLabel(65) == "1:05")
        #expect(CameraCapturePresentation.durationLabel(-2) == "0:00")
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
        nonisolated(unsafe) let completionWriter = writer
        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                if completionWriter.status == AVAssetWriter.Status.completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: completionWriter.error ?? VideoThumbnailFixtureError.writerFailed)
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

    @Test func recognizerBeginsOnlyForRightwardHorizontalIntent() {
        #expect(ReplySwipe.shouldBegin(velocity: CGPoint(x: 180, y: 30)))
        #expect(!ReplySwipe.shouldBegin(velocity: CGPoint(x: 30, y: 180)))
        #expect(!ReplySwipe.shouldBegin(velocity: CGPoint(x: -180, y: 20)))
    }

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
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 20, height: 1)) == 0)
    }

    @Test func completionNudgeStaysBelowMaximumFeedback() {
        #expect(ReplySwipe.minimumDistance >= 20)
        #expect(ReplySwipe.completionOffset < ReplySwipe.maximumFeedbackOffset)
        #expect(ReplySwipe.completionOffset <= 12)
        #expect(ReplySwipe.completionPauseNanoseconds <= 20_000_000)
    }
}

@MainActor
struct TimelineKeyboardDismissControllerTests {

    @Test func installsNonCancellingTapDirectlyOnScrollView() {
        var tapCount = 0
        let controller = TimelineKeyboardDismissController { tapCount += 1 }
        let scrollView = UIScrollView()

        controller.install(on: scrollView)

        #expect(controller.installedScrollView === scrollView)
        #expect(controller.recognizer.view === scrollView)
        #expect(!controller.recognizer.cancelsTouchesInView)
        #expect(!controller.recognizer.delaysTouchesBegan)
        #expect(!controller.recognizer.delaysTouchesEnded)
        #expect(!controller.gestureRecognizer(
            controller.recognizer,
            shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer
        ))
        #expect(controller.gestureRecognizer(
            controller.recognizer,
            shouldRequireFailureOf: scrollView.panGestureRecognizer
        ))
        let otherTap = UITapGestureRecognizer()
        #expect(controller.gestureRecognizer(
            controller.recognizer,
            shouldRecognizeSimultaneouslyWith: otherTap
        ))
        #expect(!controller.gestureRecognizer(
            controller.recognizer,
            shouldRequireFailureOf: otherTap
        ))

        controller.handleRecognizedTap()
        #expect(tapCount == 1)

        controller.uninstall()
        #expect(controller.installedScrollView == nil)
        #expect(controller.recognizer.view == nil)
    }

    @Test func attachmentResolvesTheEnclosingTimelineScrollView() {
        let controller = TimelineKeyboardDismissController {}
        let scrollView = UIScrollView()
        let contentView = UIView()
        let attachmentView = TimelineKeyboardDismissAttachmentView()
        attachmentView.controller = controller

        scrollView.addSubview(contentView)
        contentView.addSubview(attachmentView)
        attachmentView.resolveScrollView()

        #expect(controller.installedScrollView === scrollView)
        #expect(controller.recognizer.view === scrollView)

        controller.uninstall()
    }
}

private struct TimelineSemanticPositionHarness: View {
    let target: TimelineInitialPositionTarget
    let onViewportChanged: (TimelineBottomViewport) -> Void
    let onVisibleTargetsChanged: (Set<String>) -> Void
    @State private var requestGeneration = 0

    init(
        target: TimelineInitialPositionTarget,
        onViewportChanged: @escaping (TimelineBottomViewport) -> Void,
        onVisibleTargetsChanged: @escaping (Set<String>) -> Void = { _ in }
    ) {
        self.target = target
        self.onViewportChanged = onViewportChanged
        self.onVisibleTargetsChanged = onVisibleTargetsChanged
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Section {
                        ForEach(0..<120, id: \.self) { index in
                            Text("Row \(index)")
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: index.isMultiple(of: 11) ? 180 : 40
                                )
                                .id("row-\(index)")
                        }
                    }
                    ForEach(["bottom"], id: \.self) { _ in
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                }
                .scrollTargetLayout()
            }
            .onScrollGeometryChange(for: TimelineBottomViewport.self) { geometry in
                TimelineBottomViewport(
                    contentHeight: geometry.contentSize.height,
                    visibleBottomY: geometry.visibleRect.maxY,
                    bottomContentInset: geometry.contentInsets.bottom
                )
            } action: { _, viewport in
                onViewportChanged(viewport)
                requestGeneration &+= 1
            }
            .task(id: requestGeneration) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                requestTarget(proxy: proxy)
            }
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: TimelineViewportVisibility.minimumVisibleFraction
            ) { visibleIDs in
                onVisibleTargetsChanged(Set(visibleIDs))
            }
        }
    }

    private func requestTarget(proxy: ScrollViewProxy) {
        switch target {
        case .item(let id, let anchor):
            proxy.scrollTo(id, anchor: anchor.unitPoint)
        case .latest(let id):
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

@MainActor
private final class TimelineResizeHarnessModel: ObservableObject {
    @Published var viewportHeight: CGFloat = 700
}

private struct TimelineShortContentResizeHarness: View {
    @ObservedObject var model: TimelineResizeHarnessModel
    let onVisibleTargetsChanged: (Set<String>) -> Void

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    Text("Only message")
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .id("message")
                }
                .scrollTargetLayout()
                .frame(minHeight: max(0, viewport.size.height), alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: TimelineViewportVisibility.minimumVisibleFraction
            ) { visibleIDs in
                onVisibleTargetsChanged(Set(visibleIDs))
            }
        }
        .frame(height: model.viewportHeight)
    }
}

@MainActor
struct TimelineBottomTests {

    @Test func shortTimelineRemainsVisibleWhenViewportShrinks() async throws {
        let model = TimelineResizeHarnessModel()
        var visibleTargets = Set<String>()
        let controller = UIHostingController(
            rootView: TimelineShortContentResizeHarness(model: model) {
                visibleTargets = $0
            }
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        for _ in 0..<100 where !visibleTargets.contains("message") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(visibleTargets.contains("message"))

        model.viewportHeight = 390
        try await Task.sleep(for: .milliseconds(100))

        #expect(visibleTargets.contains("message"))
        window.isHidden = true
    }

    @Test func swiftUIStableTimelineResolvesSemanticBottomTarget() async throws {
        let target = TimelineInitialPositionTarget.latest(id: "bottom")
        var didReachTarget = false
        var didSeeBottomTarget = false
        var lastViewport: TimelineBottomViewport?
        let controller = UIHostingController(
            rootView: TimelineSemanticPositionHarness(
                target: target,
                onViewportChanged: {
                    lastViewport = $0
                    didReachTarget = $0.isPinned
                },
                onVisibleTargetsChanged: {
                    didSeeBottomTarget = $0.contains("bottom")
                }
            )
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        for _ in 0..<100 where !didReachTarget || !didSeeBottomTarget {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(didReachTarget, "Last viewport: \(String(describing: lastViewport))")
        #expect(didSeeBottomTarget)
        window.isHidden = true
    }

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
            targetItemId: "msg-target",
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .target(.item(id: "msg-target", anchor: .center)))
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: nil,
            targetItemId: nil,
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .target(.latest(id: "msg-latest")))
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: "message-target",
            targetItemId: nil,
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .none)
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: true,
            targetMessageIdHex: "message-target",
            targetItemId: "msg-target",
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .none)
    }

    @Test func unreadAndLatestEntriesUseSemanticAnchors() {
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: "message-target",
            targetItemId: "unread:message-target",
            latestItemId: "msg-latest",
            unreadMessageIdHex: "message-target"
        ) == .target(.item(id: "unread:message-target", anchor: .top)))
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: nil,
            targetItemId: nil,
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .target(.latest(id: "msg-latest")))
    }

    @Test func initialTimelineRemainsConcealedUntilSemanticPositionSettles() {
        #expect(TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: false
        ))
        #expect(!TimelineInitialScroll.shouldConcealContent(
            hasItems: false,
            didFinishInitialPositioning: false
        ))
        #expect(!TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: true
        ))
    }

    @Test func missingInitialTargetLoadsHistoryBeforeFallingBack() {
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: nil,
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true
        ) == .ready)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: "msg:target",
            hasMoreBefore: true,
            canLoadOlder: true
        ) == .ready)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true
        ) == .loadOlder)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: false
        ) == .waitForPagination)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: false,
            canLoadOlder: false
        ) == .fallbackToBottom)
    }

    @Test func initialTargetHuntFallsBackToBottomOnceItsPageBudgetIsSpent() {
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true,
            loadedHistoryPages: TimelineInitialTargetPolicy.maximumHistoryPages - 1
        ) == .loadOlder)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true,
            loadedHistoryPages: TimelineInitialTargetPolicy.maximumHistoryPages
        ) == .fallbackToBottom)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: false,
            loadedHistoryPages: TimelineInitialTargetPolicy.maximumHistoryPages
        ) == .fallbackToBottom)
    }

    @Test func scrollToBottomDrainsForwardPagesUpToItsCap() {
        #expect(TimelineBottom.shouldDrainNewerPage(hasMoreAfter: true, drainedPages: 0))
        #expect(TimelineBottom.shouldDrainNewerPage(
            hasMoreAfter: true,
            drainedPages: TimelineBottom.maximumScrollToBottomPageDrains - 1
        ))
        #expect(!TimelineBottom.shouldDrainNewerPage(
            hasMoreAfter: true,
            drainedPages: TimelineBottom.maximumScrollToBottomPageDrains
        ))
        #expect(!TimelineBottom.shouldDrainNewerPage(hasMoreAfter: false, drainedPages: 0))
    }

    @Test func ownSendRepinsTheViewportWhateverItWasBefore() {
        #expect(!TimelineBottom.movedAwayFromBottomAfterOwnSend(previous: true))
        #expect(!TimelineBottom.movedAwayFromBottomAfterOwnSend(previous: false))
    }

    @Test func ownSendBottomScrollIsTreatedAsUserInitiated() {
        #expect(TimelineBottomScrollReason.send.isUserInitiated)
        // Same exemption `.buttonTap` gets: an explicit send must not be
        // swallowed while initial positioning is still unfinished.
        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: true,
            didFinishPositioning: false,
            reason: .send
        ))
        // And it wins coalescing against an automatic follow-up either way round.
        let send = TimelineBottomScrollRequest(animated: false, reason: .send, targetID: "sent")
        let automatic = TimelineBottomScrollRequest(
            animated: true,
            reason: .timelineChange,
            targetID: "tail"
        )
        #expect(send.coalesced(with: automatic).reason == .send)
        #expect(automatic.coalesced(with: send).reason == .send)
    }

    @Test func semanticTargetPositioningRejectsAutomaticBottomScrolls() {
        for reason in [TimelineBottomScrollReason.timelineChange, .layoutChange] {
            #expect(TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
                hasPositionIntent: true,
                didFinishPositioning: false,
                reason: reason
            ))
        }

        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: true,
            didFinishPositioning: false,
            reason: .buttonTap
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: false,
            didFinishPositioning: false,
            reason: .timelineChange
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: true,
            didFinishPositioning: true,
            reason: .timelineChange
        ))
    }

    @Test func initialPositionSettlesOnlyWhenItsSemanticTargetIsVisible() {
        let target = TimelineInitialPositionTarget.item(
            id: "unread:message-target",
            anchor: .top
        )

        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: target,
            visibleTargetIDs: ["msg:older", "msg:newer"]
        ))
        #expect(TimelineInitialTargetScrollPolicy.shouldSettle(
            target: target,
            visibleTargetIDs: ["msg:older", "unread:message-target"]
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: nil,
            visibleTargetIDs: ["unread:message-target"]
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: .latest(id: "msg-latest"),
            visibleTargetIDs: []
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: .latest(id: "msg-latest"),
            visibleTargetIDs: ["msg:older"]
        ))
        #expect(TimelineInitialTargetScrollPolicy.shouldSettle(
            target: .latest(id: "msg-latest"),
            visibleTargetIDs: ["msg-latest"]
        ))
    }

    @Test func timelineVisibilityStorePublishesOnlyVisibilityEdges() {
        let visibility = TimelineVisibilityStore()

        #expect(visibility.set("message-a", isVisible: true))
        #expect(!visibility.set("message-a", isVisible: true))
        #expect(visibility.visibleRowKeys == Set(["message-a"]))
        #expect(visibility.set("message-a", isVisible: false))
        #expect(!visibility.set("message-a", isVisible: false))
        #expect(visibility.visibleRowKeys.isEmpty)
    }

    @Test func timelineTargetVisibilityStoreRetainsTheLatestScrollCallbackSnapshot() {
        let visibility = TimelineTargetVisibilityStore()

        visibility.replace(with: ["message-a", "message-b"])
        #expect(visibility.visibleTargetIDs == ["message-a", "message-b"])

        visibility.replace(with: ["message-b"])
        #expect(visibility.visibleTargetIDs == ["message-b"])
    }

    @Test func timelineVisibilityThresholdIncludesPartiallyVisibleTallRows() {
        let onePointOfTallRow = 1.0 / 400.0

        #expect(TimelineViewportVisibility.minimumVisibleFraction <= onePointOfTallRow)
        #expect(TimelineViewportVisibility.minimumVisibleFraction < 0.5)
    }

    @Test func unreadDividerAppearsOnlyBeforePersistedFirstUnreadMessage() {
        let unreadId = hex("71")
        let unread = TimelineItem.message(message(id: unreadId, kind: MessageSemantics.kindChat))
        let other = TimelineItem.message(message(id: hex("72"), kind: MessageSemantics.kindChat))

        #expect(TimelineUnreadDivider.shouldShow(
            before: unread,
            firstUnreadMessageIdHex: unreadId
        ))
        #expect(!TimelineUnreadDivider.shouldShow(
            before: other,
            firstUnreadMessageIdHex: unreadId
        ))
        #expect(!TimelineUnreadDivider.shouldShow(
            before: unread,
            firstUnreadMessageIdHex: nil
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

    @Test func bottomOverscrollMeasuresViewportBelowLegalContentBottom() {
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
        #expect(belowContent.overscrollPastBottom == 70)
    }

    @Test func bottomBounceDoesNotMarkTheUserAsMovedAway() {
        #expect(TimelineBottom.userMovedAwayState(
            previous: false,
            viewportIsPinned: true,
            isUserScrolling: true
        ) == false)
        #expect(TimelineBottom.userMovedAwayState(
            previous: true,
            viewportIsPinned: true,
            isUserScrolling: true
        ) == false)
    }

    @Test func draggingBeyondTheBottomThresholdMarksTheUserAsMovedAway() {
        #expect(TimelineBottom.userMovedAwayState(
            previous: false,
            viewportIsPinned: false,
            isUserScrolling: true
        ))
        #expect(TimelineBottom.userMovedAwayState(
            previous: true,
            viewportIsPinned: false,
            isUserScrolling: false
        ))
    }

    @Test func scrollButtonTapOptimisticallyPinsTimeline() {
        #expect(TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: false))
        #expect(TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: true))
    }

    @Test func paginationTriggerRequestsOnlyOncePerVisibleAppearance() {
        #expect(TimelinePaginationTrigger.shouldRequestPage(
            hasMore: true,
            isTriggerAlreadyVisible: false
        ))
        #expect(!TimelinePaginationTrigger.shouldRequestPage(
            hasMore: true,
            isTriggerAlreadyVisible: true
        ))
        #expect(!TimelinePaginationTrigger.shouldRequestPage(
            hasMore: false,
            isTriggerAlreadyVisible: false
        ))
    }

    @Test func bottomScrollRequestsCoalesceToLatestTimelineTarget() {
        let timelineChange = TimelineBottomScrollRequest(
            animated: true,
            reason: .timelineChange,
            targetID: "message-a"
        )
        let nextTimelineChange = TimelineBottomScrollRequest(
            animated: false,
            reason: .timelineChange,
            targetID: "message-b"
        )

        let result = TimelineBottomScrollCoordinator.coalesced(timelineChange, with: nextTimelineChange)

        #expect(result.animated == false)
        #expect(result.reason == .timelineChange)
        #expect(result.targetID == "message-b")
    }

    @Test func userInitiatedBottomScrollWinsPendingAutomaticFollowUps() {
        let timelineChange = TimelineBottomScrollRequest(
            animated: false,
            reason: .timelineChange,
            targetID: "message-a"
        )
        let buttonTap = TimelineBottomScrollRequest(
            animated: true,
            reason: .buttonTap,
            targetID: "message-b"
        )

        let userWins = TimelineBottomScrollCoordinator.coalesced(timelineChange, with: buttonTap)
        let automaticDoesNotOverrideUser = TimelineBottomScrollCoordinator.coalesced(buttonTap, with: timelineChange)

        #expect(userWins.animated)
        #expect(userWins.reason == .buttonTap)
        #expect(userWins.targetID == "message-b")
        #expect(automaticDoesNotOverrideUser == buttonTap)
    }

    @Test func userScrollSuppressesAutomaticBottomRequestsButNotButtonTap() {
        for reason in [TimelineBottomScrollReason.timelineChange, .layoutChange] {
            #expect(!TimelineBottomScrollCoordinator.shouldExecute(
                reason: reason,
                isUserScrolling: true
            ))
            #expect(TimelineBottomScrollCoordinator.shouldExecute(
                reason: reason,
                isUserScrolling: false
            ))
        }

        #expect(TimelineBottomScrollCoordinator.shouldExecute(
            reason: .buttonTap,
            isUserScrolling: true
        ))
    }

    @Test func layoutChangesFollowBottomOnlyBeforeTheUserMovesAway() {
        #expect(TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: true,
            userMovedAwayFromBottom: false,
            isUserScrolling: false
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: false,
            userMovedAwayFromBottom: false,
            isUserScrolling: false
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: true,
            userMovedAwayFromBottom: true,
            isUserScrolling: false
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: true,
            userMovedAwayFromBottom: false,
            isUserScrolling: true
        ))
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

    @Test func messageActionsOverlayKeepsReactionsAboveAndActionsBelowMessage() {
        let source = CGRect(x: 0, y: 220, width: 390, height: 96)
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 320,
            showsReactions: true
        )

        let reactionBottom = layout.groupTop + MessageActionsPresentation.reactionHeight
        let previewTop = layout.previewCenterY - layout.previewHeight / 2
        let previewBottom = layout.previewCenterY + layout.previewHeight / 2
        let actionsTop = layout.groupTop + layout.groupHeight - 320

        #expect(previewTop - reactionBottom == MessageActionsPresentation.surfaceGap)
        #expect(actionsTop - previewBottom == MessageActionsPresentation.surfaceGap)
    }

    @Test func messageActionsOverlayShiftsTheWholeCompositionOnShortScreens() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 650, width: 390, height: 300),
            containerHeight: 760,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.groupTop >= MessageActionsPresentation.verticalMargin)
        #expect(layout.groupTop + layout.groupHeight <= 760 - MessageActionsPresentation.verticalMargin)
        #expect(layout.previewScale < 1)
    }

    @Test func messageActionsOverlayDoesNotReserveAReactionSurfaceWhenInteractionIsDisabled() {
        let source = CGRect(x: 0, y: 180, width: 390, height: 80)
        let withReactions = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 220,
            showsReactions: true
        )
        let withoutReactions = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 220,
            showsReactions: false
        )

        #expect(withoutReactions.groupHeight
            == withReactions.groupHeight
                - MessageActionsPresentation.reactionHeight
                - MessageActionsPresentation.surfaceGap)
    }
}

@MainActor
struct KeyboardFrameChangeTests {

    @Test func animationParametersPreserveKeyboardTiming() {
        let parameters = KeyboardFrameChange.animationParameters(duration: 0.42, rawCurve: 1)
        #expect(parameters.duration == 0.42)
        #expect(parameters.curve == .easeIn)
    }

    @Test func animationParametersUseStableDefaultsForUnknownCurve() {
        let parameters = KeyboardFrameChange.animationParameters(duration: nil, rawCurve: 7)
        #expect(parameters.duration == 0.25)
        #expect(parameters.curve == .easeInOut)
    }

    @Test func bottomGapUpdatesOnlyForMaterialChanges() {
        #expect(!KeyboardFrameChange.shouldUpdateBottomGap(current: 16, next: 16.25))
        #expect(KeyboardFrameChange.shouldUpdateBottomGap(current: 0, next: 16))
    }

    @Test func visibilityUpdatesOnlyWhenValueChanges() {
        #expect(!KeyboardFrameChange.shouldUpdateVisibility(current: true, next: true))
        #expect(KeyboardFrameChange.shouldUpdateVisibility(current: false, next: true))
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

    @Test func clearWipesPasteboardWhenUserHasNotChangedItSinceCapture() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        pasteboard.string = secret
        let token = SensitiveClipboard.capture(from: pasteboard)

        SensitiveClipboard.clear(matching: token, from: pasteboard)

        #expect(pasteboard.string == nil || pasteboard.string?.isEmpty == true)
        #expect(!pasteboard.hasStrings)
    }

    @Test func clearLeavesPasteboardAloneWhenUserCopiedSomethingElseAfterCapture() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        pasteboard.string = secret
        let token = SensitiveClipboard.capture(from: pasteboard)

        // User copies something new after the secret was captured — this bumps
        // the pasteboard's changeCount, so the clear must back off.
        let unrelated = "https://example.com/some-link"
        pasteboard.string = unrelated

        SensitiveClipboard.clear(matching: token, from: pasteboard)

        #expect(pasteboard.string == unrelated)
    }

    @Test func clearIsNoOpWhenPasteboardHasNoStringEvenIfChangeCountMatches() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.items = []
        let token = SensitiveClipboard.capture(from: pasteboard)

        SensitiveClipboard.clear(matching: token, from: pasteboard)

        #expect(!pasteboard.hasStrings)
    }

    @Test func copyStoresSensitiveTextWithExpirationOptions() throws {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let expiry = Date().addingTimeInterval(120)

        SensitiveClipboard.copy("private message", to: pasteboard, expiresAt: expiry)

        #expect(pasteboard.string == "private message")
    }

    // Regression test for the #409 PR review BLOCKING finding: a nil token
    // (no genuine paste observed — the nsec was typed/autofilled, or the user
    // pasted then copied unrelated content so the token was never captured for
    // the live generation) must NEVER wipe the clipboard.
    @Test func shouldClearReturnsFalseWhenNoPasteWasObserved() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: nil,
            currentChangeCount: 7,
            hasStrings: true
        ) == false)
    }

    @Test func shouldClearReturnsTrueWhenGenerationUnchangedAndHasStrings() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: 4,
            currentChangeCount: 4,
            hasStrings: true
        ) == true)
    }

    // User copied something after the paste: the generation advanced, so we
    // must not clobber their newer content.
    @Test func shouldClearReturnsFalseWhenGenerationAdvancedAfterPaste() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: 4,
            currentChangeCount: 5,
            hasStrings: true
        ) == false)
    }

    @Test func shouldClearReturnsFalseWhenPasteboardHasNoStrings() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: 4,
            currentChangeCount: 4,
            hasStrings: false
        ) == false)
    }

    // A nil token routed through clear(matching:) must be a guaranteed no-op,
    // even when the pasteboard currently holds an unrelated string — this is
    // the typed/autofilled or paste-then-copy-unrelated case from the #409
    // blocking finding.
    @Test func clearIsNoOpWhenTokenIsNilEvenIfPasteboardHasStrings() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let unrelated = "https://example.com/unrelated"
        pasteboard.string = unrelated

        SensitiveClipboard.clear(matching: nil, from: pasteboard)

        #expect(pasteboard.string == unrelated)
    }

    @Test func importClearIgnoresNilTokenFromPartialPasteIntoExistingText() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let fragment = "nsec-fragment-from-clipboard"
        let resultingNsec = validNsec(filledWith: "d")
        pasteboard.string = fragment
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(nil, resultingIdentity: resultingNsec)
        SensitiveClipboard.clear(
            matching: model.clipboardTokenForImportedIdentity(resultingNsec),
            from: pasteboard
        )

        #expect(pasteboard.string == fragment)
    }

    @Test func importClearIgnoresTokenFromNonNsecPasteEditedIntoNsec() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let unrelated = "https://example.com/unrelated"
        pasteboard.string = unrelated
        let token = SensitiveClipboard.capture(from: pasteboard)
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(token, resultingIdentity: unrelated)
        SensitiveClipboard.clear(
            matching: model.clipboardTokenForImportedIdentity(validNsec(filledWith: "a")),
            from: pasteboard
        )

        #expect(pasteboard.string == unrelated)
    }

    @Test func importClearIgnoresTokenWhenPastedNsecWasEditedToDifferentNsec() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let pastedNsec = validNsec(filledWith: "a")
        let importedNsec = validNsec(filledWith: "b")
        pasteboard.string = pastedNsec
        let token = SensitiveClipboard.capture(from: pasteboard)
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(token, resultingIdentity: pastedNsec)
        SensitiveClipboard.clear(
            matching: model.clipboardTokenForImportedIdentity(importedNsec),
            from: pasteboard
        )

        #expect(pasteboard.string == pastedNsec)
    }

    @Test func importClearUsesTokenWhenImportedNsecStillMatchesPastedNsec() {
        let pasteboard = makeIsolatedPasteboard()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let nsec = validNsec(filledWith: "c")
        pasteboard.string = nsec
        let token = SensitiveClipboard.capture(from: pasteboard)
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(token, resultingIdentity: " \n\(nsec)\n ")
        let clipboardToken = model.consumeClipboardTokenForImportedIdentity(nsec)
        SensitiveClipboard.clear(
            matching: clipboardToken,
            from: pasteboard
        )

        #expect(clipboardToken != nil)
        #expect(model.clipboardTokenForImportedIdentity(nsec) == nil)
        #expect(!pasteboard.hasStrings)
    }

    private func makeIsolatedPasteboard() -> UIPasteboard {
        let name = UIPasteboard.Name("dev.ipf.WhiteNoise.tests.sensitive-clipboard-\(UUID().uuidString)")
        return UIPasteboard(name: name, create: true)!
    }

    private func validNsec(filledWith character: Character) -> String {
        switch character {
        case "a":
            "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn"
        case "b":
            "nsec12kcgs78l06p30jz7z7h3n2x2cy99nw2z6zspjdp7qc206887mwvs95lnkx"
        case "c":
            "nsec1c9wh8xy5eqdzln7n5t0ctgxjcrdug73gp5yj0x03gntn67h83twssdfhel"
        case "d":
            "nsec18t096ty4lzm8k3d86rn0yszmwrcrntmaylkavjgwwvh6w90a9wus2u8rgf"
        default:
            preconditionFailure("Missing valid nsec fixture")
        }
    }
}

/// Scopes the app language to the calling task. Writing the shared test
/// defaults instead would leak the language into concurrently-running suites
/// (parallel Swift Testing) and intermittently fail English-asserting tests.
func withAppLanguage<T>(_ language: AppLanguage, perform body: () throws -> T) rethrows -> T {
    try AppLanguage.$testCurrentOverride.withValue(language, operation: body)
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
    // Delivered by default, mirroring the engine (received rows always carry
    // a source id; own rows carry one once delivered). Pass `.some(nil)` to
    // build a committed-but-undelivered own row.
    sourceMessageIdHex: String?? = nil,
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
    media: [MediaAttachmentReferenceFfi] = [],
    agentTextStreamJson: String? = nil,
    reactions: TimelineReactionSummaryFfi = TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
    deleted: Bool = false,
    deletedByMessageIdHex: String? = nil,
    invalidationStatus: String? = nil
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: sourceMessageIdHex ?? messageIdHex,
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
        media: media,
        agentTextStreamJson: agentTextStreamJson,
        reactions: reactions,
        deleted: deleted,
        deletedByMessageIdHex: deletedByMessageIdHex,
        invalidationStatus: invalidationStatus
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
    nonce: String = String(repeating: "22", count: 12),
    version: EncryptedMediaVersionFfi = .v1
) -> MessageTagFfi {
    MessageTagFfi(values: [
        MessageSemantics.imetaTag,
        "v \(version.wireValue)",
        "locator blossom-v1 https://media.example/\(hex(ciphertextByte)).bin",
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
        locators: [MediaLocatorFfi(
            kind: "blossom-v1",
            value: "https://media.example/\(hex(ciphertextByte)).bin"
        )],
        ciphertextSha256: hex(ciphertextByte),
        plaintextSha256: hex(plaintextByte),
        nonceHex: nonce,
        fileName: fileName,
        mediaType: mediaType,
        version: .v1,
        sourceEpoch: sourceEpoch,
        dim: dim,
        thumbhash: nil
    )
}

private func mediaRecord(
    messageIdHex: String,
    attachmentIndex: UInt32,
    reference: MediaAttachmentReferenceFfi,
    direction: String = "received",
    recordedAt: UInt64 = 1
) -> MediaRecordFfi {
    MediaRecordFfi(
        messageIdHex: messageIdHex,
        attachmentIndex: attachmentIndex,
        direction: direction,
        groupIdHex: hex("aa"),
        sender: hex("11"),
        reference: reference,
        caption: nil,
        recordedAt: recordedAt,
        receivedAt: recordedAt
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

private func encryptedMediaComponent(
    version: EncryptedMediaVersionFfi = .v2
) -> AppGroupEncryptedMediaComponentFfi {
    AppGroupEncryptedMediaComponentFfi(
        componentId: version == .v1 ? 0x8008 : 0x800b,
        component: version == .v1
            ? "marmot.group.encrypted-media.v1"
            : "marmot.group.encrypted-media.v2",
        required: true,
        version: version,
        mediaFormat: version.wireValue,
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
        version: nil,
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
    pendingConfirmation: Bool = false,
    unrecoverable: Bool = false,
    selfMembership: SelfMembershipFfi = .member,
    leaveRequestPending: Bool = false,
    disbanding: Bool = false,
    disbandRequest: DisbandRequestFfi? = nil,
    disbanded: Bool = false,
    welcomerAccountIdHex: String? = nil,
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
        pendingConfirmation: pendingConfirmation,
        unrecoverable: unrecoverable,
        selfMembership: selfMembership,
        leaveRequestPending: leaveRequestPending,
        leaveRequestedAtMs: leaveRequestPending ? 1_000 : nil,
        disbanding: disbanding,
        disbandRequest: disbandRequest,
        disbanded: disbanded,
        welcomerAccountIdHex: welcomerAccountIdHex,
        viaWelcomeMessageIdHex: nil
    )
}

private func chatListPreview(
    messageIdHex: String,
    sender: String = hex("11"),
    senderDisplayName: String? = nil,
    plaintext: String = "hello",
    contentTokens: MarkdownDocumentFfi = .emptyDocument,
    kind: UInt64 = MessageSemantics.kindChat,
    timelineAt: UInt64 = 1,
    deleted: Bool = false
) -> ChatListMessagePreviewFfi {
    ChatListMessagePreviewFfi(
        messageIdHex: messageIdHex,
        sender: sender,
        senderDisplayName: senderDisplayName,
        plaintext: plaintext,
        contentTokens: contentTokens,
        kind: kind,
        timelineAt: timelineAt,
        deleted: deleted
    )
}

private func presentedChatSnapshot(_ rows: [ChatListRowFfi]) -> PresentedChatListSnapshotFfi {
    PresentedChatListSnapshotFfi(
        rows: rows.map { row in
            PresentedChatRowFfi(
                row: row,
                presentation: ConversationPresentationFfi(
                    title: .literal(text: row.title),
                    avatar: .placeholder(stableSeed: row.groupIdHex, source: .groupFallback),
                    titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
                )
            )
        },
        presentationVersion: PresentationVersionFfi(accountStoreEpoch: Data([1]), revision: 1)
    )
}

private func chatListRow(
    groupIdHex: String,
    pinned: Bool = false,
    pinnedPosition: UInt32? = nil,
    archived: Bool = false,
    pendingConfirmation: Bool = false,
    title: String,
    groupName: String? = nil,
    avatar: ChatListAvatarFfi? = nil,
    avatarUrl: String? = nil,
    lastMessage: ChatListMessagePreviewFfi? = nil,
    unreadCount: UInt64 = 0,
    manuallyMarkedUnread: Bool = false,
    unreadMentionCount: UInt64 = 0,
    unreadMention: Bool = false,
    firstUnreadMessageIdHex: String? = nil,
    lastReadMessageIdHex: String? = nil,
    lastReadTimelineAt: UInt64? = nil,
    conversationCreatedAt: UInt64? = nil,
    activitySortAt: UInt64? = nil,
    updatedAt: UInt64 = 1,
    selfMembership: SelfMembershipFfi = .member,
    conversationKind: ChatConversationKindFfi = .group,
    muted: Bool = false,
    mutedUntilMs: Int64? = nil,
    leaveRequestPending: Bool = false
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: groupIdHex,
        pinned: pinned,
        pinnedPosition: pinnedPosition,
        archived: archived,
        pendingConfirmation: pendingConfirmation,
        title: title,
        groupName: groupName ?? title,
        avatarUrl: avatarUrl,
        avatar: avatar,
        lastMessage: lastMessage,
        unreadCount: unreadCount,
        hasUnread: unreadCount > 0 || manuallyMarkedUnread,
        manuallyMarkedUnread: manuallyMarkedUnread,
        unreadMentionCount: unreadMentionCount,
        unreadMention: unreadMention,
        firstUnreadMessageIdHex: firstUnreadMessageIdHex,
        lastReadMessageIdHex: lastReadMessageIdHex,
        lastReadTimelineAt: lastReadTimelineAt,
        conversationCreatedAt: conversationCreatedAt ?? updatedAt,
        activitySortAt: activitySortAt ?? updatedAt,
        updatedAt: updatedAt,
        selfMembership: selfMembership,
        conversationKind: conversationKind,
        muted: muted,
        mutedUntilMs: mutedUntilMs,
        leaveRequestPending: leaveRequestPending,
        leaveRequestedAtMs: leaveRequestPending ? updatedAt * 1_000 : nil
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
    isMention: Bool = false,
    groupName: String? = nil,
    senderName: String? = "Alice",
    previewText: String? = "Hello",
    reactionEmoji: String? = nil,
    reactedToPreview: String? = nil,
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
        isMention: isMention,
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
        reactionEmoji: reactionEmoji,
        reactedToPreview: reactedToPreview,
        timestampMs: timestampMs,
        isFromSelf: isFromSelf
    )
}

private func managementState(
    isSelfAdmin: Bool,
    isLastAdmin: Bool,
    canLeave: Bool? = nil,
    requiresSelfDemoteBeforeLeave: Bool? = nil,
    leaveRequestPending: Bool = false,
    lifecycleState: GroupLifecycleStateFfi = .stable,
    disbandingEnabled: Bool = false,
    disbanding: Bool = false,
    canEnableDisbanding: Bool = false,
    canDisband: Bool = false,
    disbandingBlockers: [String] = [],
    disbandRequest: DisbandRequestFfi? = nil
) -> GroupManagementStateFfi {
    GroupManagementStateFfi(
        myAccountIdHex: hex("11"),
        isSelfAdmin: isSelfAdmin,
        isLastAdmin: isLastAdmin,
        canInvite: isSelfAdmin,
        canLeave: leaveRequestPending ? false : (canLeave ?? !isSelfAdmin),
        requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave ?? isSelfAdmin,
        leaveRequestPending: leaveRequestPending,
        leaveRequestedAtMs: leaveRequestPending ? 1_000 : nil,
        lifecycleState: lifecycleState,
        disbandingEnabled: disbandingEnabled,
        disbanding: disbanding,
        canEnableDisbanding: canEnableDisbanding,
        canDisband: canDisband,
        disbandingBlockers: disbandingBlockers,
        disbandRequest: disbandRequest,
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

private actor AsyncTestCheckpoint {
    private var isPaused = false
    private var isReleased = false
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        let waiters = pausedWaiters
        pausedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pausedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor AsyncTestGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
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

private struct CompletedAccountSetupTestClient: AccountSetupClient {
    let snapshot: OnboardingSnapshotFfi

    func subscribe() async throws -> AccountSetupSubscription {
        AccountSetupSubscription(snapshot: snapshot, next: { nil })
    }

    func perform(_ command: AccountSetupCommand) async throws -> OnboardingSnapshotFfi? { snapshot }
}

@MainActor
struct PresentedChatListTests {
    @Test func snapshotTimingWaitsForDeferredPresentationAndRequiresConsent() async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        let model = ChatsListViewModel(appState: appState)
        let snapshot = presentedChatSnapshot([chatListRow(groupIdHex: "timed", title: "Selected")])
        model.applyPresentedSnapshot(snapshot)
        let stages = Mutex<[ProductTimingStage]>([])
        appState.productAnalytics.activateSink(timing: { stage, _, _ in stages.withLock { $0.append(stage) } }) { _ in }
        let transition = model.beginPinOrderUITransition()
        model.applyPresentedSnapshot(snapshot)
        #expect(stages.withLock { $0.isEmpty })
        #expect(model.finishPinOrderUITransition(transitionID: transition, orderedGroupIds: nil))
        try await waitForExpectation { stages.withLock { $0.contains(.inboxSnapshot) } }
        #expect(stages.withLock { $0.filter { $0 == .inboxSnapshot }.count } == 1)
        appState.productAnalytics.replaceSink(nil)
        try await client.marmot.shutdownAndClose()
    }

    @Test func createdChatResolvesBeforeAndAfterMissingPresentedRowRead() async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        appState.setPhase(.ready)
        appState.setAppSceneActive(true)
        let model = ChatsListViewModel(appState: appState)
        await model.bind(accountRef: "account")
        let row = chatListRow(groupIdHex: "created", title: "Created chat")
        appState.noteCreatedChatListRow(accountRef: "account", row: row)
        model.presentedRowForTesting = { account, group in
            #expect(account == "account" && group == "created")
            #expect(model.item(groupIdHex: group)?.title == "Created chat")
            return nil
        }
        appState.presentChat(groupIdHex: row.groupIdHex)
        await model.refreshRow(groupIdHex: row.groupIdHex)
        #expect(model.item(groupIdHex: row.groupIdHex)?.title == "Created chat")
        model.presentedRowForTesting = nil
        await model.bind(accountRef: nil)
        try await client.marmot.shutdownAndClose()
    }

    @Test(arguments: [false, true])
    func targetedReadSurvivesUnrelatedRowsButPreservesNewerTarget(targetChanges: Bool) async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        appState.setPhase(.ready)
        appState.setAppSceneActive(true)
        let model = ChatsListViewModel(appState: appState)
        await model.bind(accountRef: "account")
        let selected = ConversationPresentationFfi(
            title: .literal(text: "Selected title"), avatar: .placeholder(stableSeed: "stable", source: .groupFallback),
            titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
        )
        let row = chatListRow(groupIdHex: "target", title: "Old title")
        model.presentedRowForTesting = { _, _ in
            model.applyChatListRow(chatListRow(groupIdHex: "unrelated", title: "Other chat"))
            if targetChanges { model.applyChatListRow(chatListRow(groupIdHex: "target", title: "Newer title")) }
            return PresentedChatRowFfi(row: row, presentation: selected)
        }
        await model.refreshRow(groupIdHex: row.groupIdHex)
        #expect(model.item(groupIdHex: row.groupIdHex)?.title == (targetChanges ? "Newer title" : "Selected title"))
        #expect(model.item(groupIdHex: "unrelated") != nil)
        model.presentedRowForTesting = nil
        await model.bind(accountRef: nil)
        try await client.marmot.shutdownAndClose()
    }

    @Test func selectedPresentationWinsOverLegacyFieldsAndPreservesUnreadChanges() throws {
        var row = chatListRow(groupIdHex: "presented", title: "Legacy title", avatarUrl: "https://legacy.example/avatar")
        let selected = ConversationPresentationFfi(
            title: .literal(text: "Selected title"),
            avatar: .placeholder(stableSeed: "stable", source: .groupFallback),
            titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
        )
        let appState = AppState(client: try MarmotClient.testClient())
        let model = ChatsListViewModel(appState: appState)
        let version = PresentationVersionFfi(accountStoreEpoch: Data([1]), revision: 1)
        model.applyPresentedSnapshot(PresentedChatListSnapshotFfi(
            rows: [PresentedChatRowFfi(row: row, presentation: selected)], presentationVersion: version
        ))
        #expect(model.items.first?.title == "Selected title")
        #expect(model.items.first?.avatarURL == nil)
        #expect(model.items.first?.avatarSeed == "stable")
        row.unreadCount = 4
        row.hasUnread = true
        model.applyPresentedSnapshot(PresentedChatListSnapshotFfi(
            rows: [PresentedChatRowFfi(row: row, presentation: selected)], presentationVersion: version
        ))
        #expect(model.items.first?.unreadCount == 4)
        model.applyPresentedSnapshot(PresentedChatListSnapshotFfi(rows: [], presentationVersion: version))
        #expect(model.items.isEmpty)
    }

    @Test func selectedAvatarRejectsPrivateURLsAndUsesLocalizableFallbacks() {
        let row = chatListRow(groupIdHex: "presented", title: "Legacy title")
        let selected = ConversationPresentationFfi(
            title: .unavailableConversation, avatar: .remoteImage(url: "https://127.0.0.1/private", cacheKey: "selected"),
            titleSource: .unknownFallback, avatarSource: .peerProfile, peerId: "peer", resolution: .fallback
        )
        let display = SelectedChatPresentation.display(selected, row: row)
        #expect(display.avatarURL == nil)
        #expect(display.title == L10n.string("Conversation unavailable"))
        #expect(display.avatarSeed == "selected")
    }
}
