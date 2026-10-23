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
// Keep .marmotRuntimeConcurrencyLimit before .closesTestRuntimes so cleanup runs inside the gate.
@Suite(.marmotRuntimeConcurrencyLimit, .closesTestRuntimes, .tags(.runtime))
struct AppStateBootstrapTests {

    private let accountDefaults = IsolatedAccountDefaults.make()

    @Test func bootstrapWithoutAccountsTransitionsToOnboarding() async throws {
        // Use a fresh AppState backed by a tempdir-based MarmotClient so
        // we don't collide with the user's real Application Support data.
        let appState = try testAppState()
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        #expect(appState.accounts.isEmpty)
    }

    @Test func erasurePreparationDrainsMaintenanceAndReleasesRootLease() async throws {
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

    @Test func openChatsKeepsSetupWhenItsAccountIsExcludedAndCanRetry() async throws {
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
        for _ in 0..<200 where !model.canFinish { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.canFinish)
        appState.activeAccountRef = nil
        appState.setPhase(.onboarding)
        appState.signInAttempts.begin(account.accountIdHex)
        appState.pendingAccountSetup = model
        appState.isAccountSetupPresented = true
        appState.beforeOnboardingSnapshotReadForTesting = { accountID in
            if accountID == account.accountIdHex { throw CocoaError(.fileReadCorruptFile) }
        }

        await appState.finishAccountSetup()

        #expect(appState.pendingAccountSetup === model)
        #expect(appState.isAccountSetupPresented)
        #expect(appState.signInAttempts.accountIDs.contains(account.accountIdHex))
        #expect(appState.accounts.isEmpty)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.phase == .onboarding)
        #expect(model.errorMessage != nil)
        #expect(!model.canFinish)
        #expect(!appState.isFinishingAccountSetup)

        appState.beforeOnboardingSnapshotReadForTesting = nil
        await model.connect(CompletedAccountSetupTestClient(snapshot: completed))
        for _ in 0..<200 where !model.canFinish { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.canFinish)
        await appState.finishAccountSetup()
        #expect(appState.pendingAccountSetup == nil)
        #expect(!appState.isAccountSetupPresented)
        #expect(!appState.signInAttempts.accountIDs.contains(account.accountIdHex))
        #expect(appState.activeAccountRef == account.label)
        #expect(appState.phase == .ready)
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
        for _ in 0..<200 where !model.canFinish { try await Task.sleep(for: .milliseconds(10)) }
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
        let appState = try ownedAppState(
            client: try ownedTestClient(), notifications: deniedNotifications(),
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
        let appState = try ownedAppState(
            client: try reopenedClient(rootPath: root, relayUrls: relays),
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
        for _ in 0..<200 where !model.canFinish { try await Task.sleep(for: .milliseconds(10)) }
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
        let seedClient = try ownedTestClient()
        do {
            try await seedClient.startRuntime()
            _ = try await seedClient.marmot.createIdentityWithProfile(
                defaultRelays: seedClient.relayUrls, bootstrapRelays: seedClient.relayUrls
            )
        } catch {
            try? await seedClient.marmot.shutdownAndClose()
            throw error
        }
        // Cold launch must not restart a live runtime while its setup worker writes the journal.
        try await seedClient.marmot.shutdownAndClose()
        let appState = try ownedAppState(
            client: try TestRuntimeScope.own(seedClient.freshRuntime()), notifications: deniedNotifications(),
            accountDefaults: accountDefaults, runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(delays: [.zero])
        )
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
        let appState = try ownedAppState(
            client: try ownedTestClient(),
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
        var originalClient: MarmotClient? = try ownedTestClient()
        let originalRootPath = originalClient!.rootPath
        let originalRelayUrls = originalClient!.relayUrls
        let original = try ownedAppState(
            client: originalClient!,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )
        await original.bootstrap()
        _ = try await original.createIdentity()
        await stopReadyRuntime(original)
        originalClient = nil

        let relaunched = try ownedAppState(
            client: try reopenedClient(
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

    @Test func coldBootstrapReportsSharedHostStagesToMDK() async throws {
        let appState = try testAppState()
        appState.hostWindowInitStartedAt = .now
        appState.noteHostWindowInitialized()

        await appState.bootstrap()

        let operations = try #require(appState.client).appPerformanceSnapshot().runtimeOperations
        func successes(_ name: String) -> UInt64? { operations.first { $0.operation == name }?.successes }
        #expect(successes("host_window_init") == 1)
        #expect(successes("host_runtime_init") == 1)
        #expect(successes("host_account_load") == 1)
        #expect(successes("host_fonts_init") == 0)

        await stopReadyRuntime(appState)
    }

    @Test func foregroundRebuildReportsRuntimeAndAccountStagesAgain() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        await appState.startRuntimeSuspension().value

        var stages: [(HostPerformanceOperationFfi, HostPerformanceOutcomeFfi)] = []
        appState.runtimeLifecycle.hostPerformanceObserverForTesting = { operation, _, outcome in
            stages.append((operation, outcome))
        }
        await appState.startForegroundActivation().value
        appState.runtimeLifecycle.hostPerformanceObserverForTesting = nil

        #expect(stages.contains { $0.0 == .runtimeInit && $0.1 == .success })
        #expect(stages.contains { $0.0 == .accountLoad && $0.1 == .success })

        await appState.notificationCoordinator.drainConnectivityCatchUpTaskForTesting()
        await stopReadyRuntime(appState)
    }

    @Test func accountSwitchReportsSharedHostStage() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let target = try #require(seeded.accounts.first).label
        #expect(await appState.signOut())

        await appState.activateAccount(target)

        #expect(appState.activeAccountRef == target)
        let operations = try #require(appState.client).appPerformanceSnapshot().runtimeOperations
        #expect(operations.first { $0.operation == "host_account_switch" }?.successes == 1)

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
        let appState = try ownedAppState(
            client: try reopenedClient(rootPath: seedRootPath, relayUrls: seedRelayUrls),
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

    @Test func accountAttentionChangesSynchronizeApplicationBadge() async throws {
        var appliedBadgeCounts: [Int] = []
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .denied },
            remoteNotificationRegistrar: {},
            applicationBadgeCountSetter: { count in
                appliedBadgeCounts.append(count)
            }
        )
        let seeded = try await readyAppStateWithCreatedIdentities(notifications: notifications)
        let appState = seeded.appState
        await notifications.drainApplicationBadgeUpdates()
        appliedBadgeCounts.removeAll()

        // Isolate delivery of the host projection from the live native producer.
        await appState.drainUnreadSummaryRefresh()
        for (index, counts) in [(4, 0), (4, 1), (0, 0)].enumerated() {
            appState.applyAccountAttention(AccountAttentionSnapshotFfi(
                subscriptionGeneration: "test", sequence: UInt64(index), accounts: [
                    AccountAttentionEntryFfi(accountIdHex: seeded.accounts[0].accountIdHex, state: .ready(
                        total: AccountAttentionTotalFfi(
                            unreadCount: UInt64(counts.0), unreadMentionCount: 0,
                            unreadConversations: counts.0 > 0 ? 1 : 0,
                            attentionOnlyConversations: UInt64(counts.1)
                        )
                    )),
                ]
            ))
            await notifications.drainApplicationBadgeUpdates()
            #expect(appliedBadgeCounts.last == counts.0 + counts.1)
        }
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

    @Test func destructiveWipeClearsProfileProjectionState() async throws {
        // A destructive wipe into onboarding is the one place a whole-map reset is
        // safe: with no active account `canRefreshProfiles` is false, so no
        // in-flight load can re-bump a token for the gone account ids or
        // repopulate the cache and race the reset. Signing out the last account
        // must reclaim accumulated cached projections (#366) and version entries
        // (#353).
        let seeded = try await readyAppStateWithCreatedIdentities()
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

    @Test func signOutDisablesNativePushForTheDepartingAccount() async throws {
        // Regression for issue #7: signing out must clear the signed-out
        // account's push registration so the push server stops delivering its
        // notifications to this device. The companion assertion that sign-out
        // switches to a surviving account needed a second activated identity,
        // which MDK 0.10.0 cannot produce without publishing to a real relay.
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let account = seeded.accounts[0]
        appState.activeAccountRef = account.label

        // The production path goes through `setNativePushEnabled(_:)`, which
        // needs an APNS token unavailable in unit tests; calling marmot
        // directly flips the same local preference.
        let marmot = try #require(appState.client?.marmot)
        _ = try await marmot.setNativePushEnabled(accountRef: account.label, enabled: true)
        #expect(await appState.notificationSettings(for: account.label)?.nativePushEnabled == true)

        await appState.signOut()

        #expect(appState.activeAccountRef == nil)
        #expect(appState.accounts.first(where: { $0.label == account.label })?.signedOut == true)
        #expect(await appState.notificationSettings(for: account.label)?.nativePushEnabled == false)

        await stopReadyRuntime(appState)
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
        // teardown and cleared before `signOut()` returns. Otherwise every later
        // token-driven reschedule would stay suppressed.
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        appState.activeAccountRef = seeded.accounts[0].label

        #expect(!appState.isSigningOutForTesting)

        var failure: Toast?
        let signedOut = await appState.signOut(onError: { failure = $0 })

        // The guard clears on every exit path, including a failed sign-out.
        #expect(!appState.isSigningOutForTesting)
        try #require(signedOut, "Sign-out failed: \(failure?.title ?? "-") \(failure?.message ?? "")")
        #expect(appState.activeAccountRef == nil)
        // A reschedule is permitted again; it must not trap or re-raise the flag.
        appState.scheduleNativePushRegistrationIfEnabled()
        #expect(!appState.isSigningOutForTesting)

        await appState.drainRuntimeLifecycleTasksForTesting()
        await stopReadyRuntime(appState)
    }

    @Test func signOutCancelsNewIdentityNotificationDefaultsBeforeClearingPush() async throws {
        // Identity creation enables notifications and native push in a
        // follow-up task. Sign-out must cancel and await it, or it can land
        // after the push cleanup and re-register the signed-out account.
        let permissionRequested = TestLatch()
        let permissionAnswered = TestLatch()
        let notifications = AppNotifications(
            requestAuthorizationHandler: {
                permissionRequested.signal()
                try await withTaskCancellationHandler {
                    try await permissionAnswered.wait()
                } onCancel: {
                    permissionAnswered.signal()
                }
                try Task.checkCancellation()
                return true
            },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {}
        )
        notifications.recordDeviceToken(Data([0xab, 0xcd]))
        let seeded = try await readyAppStateWithCreatedIdentities(notifications: notifications)
        let appState = seeded.appState
        let account = seeded.accounts[0]
        try await permissionRequested.wait()
        // Answer the prompt once sign-out has begun, while MDK is still
        // deactivating the account and accepts settings writes.
        appState.afterAccountExitClientCapturedForTesting = {
            permissionAnswered.signal()
        }

        let signedOut = await appState.signOut()
        await appState.drainRuntimeLifecycleTasksForTesting()

        #expect(signedOut)
        #expect(await appState.notificationSettings(for: account.label)?.nativePushEnabled == false)
        #expect(await appState.pushRegistration(for: account.label) == nil)

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

    @Test func signOutOfOnlyAccountClearsPersistedActiveAccountRef() async throws {
        // Without this, the next launch reads the stale label from
        // UserDefaults and bootstrap points at an account that was removed
        // from local Marmot storage.
        resetPersistedActiveAccountRef()
        var client: MarmotClient? = try ownedTestClient()
        let rootPath = client!.rootPath
        let relayUrls = client!.relayUrls
        let appState = try ownedAppState(
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
        let reborn = try ownedAppState(
            client: try reopenedClient(rootPath: rootPath, relayUrls: relayUrls),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )
        #expect(reborn.activeAccountRef == nil)
    }

    private func testAppState(
        notifications: AppNotifications? = nil,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig? = nil,
        relayUrls: [String] = MarmotClient.unreachableTestRelays
    ) throws -> AppState {
        resetPersistedActiveAccountRef()
        return try ownedAppState(
            client: try ownedTestClient(relayUrls: relayUrls),
            notifications: notifications ?? deniedNotifications(),
            accountDefaults: accountDefaults,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig ?? TelemetryBuildConfig.current()
        )
    }

    /// Owned by the test's `TestRuntimeScope`, which also removes the root.
    private func ownedTestClient(
        relayUrls: [String] = MarmotClient.unreachableTestRelays
    ) throws -> MarmotClient {
        try TestRuntimeScope.own(MarmotClient.testClient(relayUrls: relayUrls), ownsRoot: true)
    }

    /// Reopens an owned root, as a relaunch would. The root is removed by the
    /// client that created it.
    private func reopenedClient(rootPath: String, relayUrls: [String]) throws -> MarmotClient {
        try TestRuntimeScope.own(MarmotClient(rootPath: rootPath, relayUrls: relayUrls))
    }

    private func ownedAppState(
        client: MarmotClient,
        notifications: AppNotifications,
        accountDefaults: UserDefaults,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = TelemetryBuildConfig.current(),
        runtimeRetrySleeper: @escaping RuntimeLifecycle.RetrySleeper = AppStateTestResources.immediateRetry,
        runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground
    ) throws -> AppState {
        try TestRuntimeScope.own(AppState.test(
            client: client,
            notifications: notifications,
            accountDefaults: accountDefaults,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig,
            runtimeRetrySleeper: runtimeRetrySleeper,
            runtimeConstructionRetryPolicy: runtimeConstructionRetryPolicy
        ))
    }

    /// Seeds a single generated identity against unreachable relays. MDK
    /// coalesces generated-identity calls until the previous account has
    /// published, so a second activated account would need a real relay —
    /// which unit tests must never contact.
    private func readyAppStateWithCreatedIdentities(
        notifications: AppNotifications? = nil
    ) async throws -> (appState: AppState, accounts: [AccountSummaryFfi]) {
        let appState = try testAppState(notifications: notifications)
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        let account = try await appState.createIdentity()
        #expect(appState.phase == .ready)
        return (appState, [account])
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

private struct SensitiveNotificationSubscriptionError: LocalizedError {
    var errorDescription: String? {
        "relay failed at wss://relay.internal.invalid/path?token=secret"
    }
}

private struct CompletedAccountSetupTestClient: AccountSetupClient {
    let snapshot: OnboardingSnapshotFfi

    func subscribe() async throws -> AccountSetupSubscription {
        AccountSetupSubscription(snapshot: snapshot, next: { nil })
    }

    func perform(_ command: AccountSetupCommand) async throws -> OnboardingSnapshotFfi? { snapshot }
}
