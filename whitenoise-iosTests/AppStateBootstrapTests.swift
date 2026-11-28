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
@Suite(.marmotRuntimeConcurrencyLimit, .closesTestRuntimes)
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
        let sweeps = ControlledSleeper()
        let seeded = try await readyAppStateWithCreatedIdentities(sweepSleeper: sweeps)
        let appState = seeded.appState
        let client = try #require(appState.client)
        let root = URL(fileURLWithPath: client.rootPath, isDirectory: true)
        // The retention sweep ran its first pass and waits for the next one.
        try await eventually { sweeps.sleepingCount == 1 }
        let cancelledSweeps = sweeps.cancelledCount
        await appState.runtimeLifecycle.prepareForAppErasure()
        #expect(!appState.notificationSubscriptionActive)
        // Preparation awaits the sweep loop, so it has already ended.
        #expect(sweeps.sleepingCount == 0)
        #expect(sweeps.cancelledCount == cancelledSweeps + 1)
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

    @Test(.sharedAvatarCacheAccess)
    func destructiveWipeWithSurvivingProfileStillPurgesGroupAndProfileAvatarCaches() async throws {
        let survivingAccountID = Mutex<String?>(nil)
        let reads = AccountRefreshReads(
            listAccounts: AccountRefreshReads.live.listAccounts,
            onboardingSnapshot: { client, accountID in
                if accountID == survivingAccountID.withLock({ $0 }) { return nil }
                return try await AccountRefreshReads.live.onboardingSnapshot(client, accountID)
            }
        )
        let appState = try ownedAppState(
            client: try ownedTestClient(),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            accountRefreshReads: reads
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        let wipedAccount = try await appState.createIdentity()
        let client = try #require(appState.client)
        let importedSnapshot = try await client.marmot.beginOnboarding(
            nsec: TestKeys.randomNsec(),
            options: AccountSetupOptions.importOptions(runtimeRelays: client.relayUrls)
        )
        survivingAccountID.withLock { $0 = importedSnapshot.accountIdHex }
        try await appState.refreshAccounts(refreshUnreadSummaries: false)
        appState.activeAccountRef = wipedAccount.label

        let avatarURL = try #require(URL(string: "https://example.com/wipe-surviving-\(UUID().uuidString).png"))
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        _ = try await RemoteAvatarImageLoader.image(for: avatarURL, maxPixelSize: 16, scale: 1) { _ in png }
        let rawGroupKey = GroupAvatarCacheKey.rawData(accountRef: wipedAccount.label, imageHashHex: hex("77"))
        let thumbGroupKey = GroupAvatarCacheKey.thumbnail(
            accountRef: wipedAccount.label,
            imageHashHex: hex("77"),
            maxPixelSize: 16
        )
        await RemoteAvatarDiskCache.groupShared.store(png, forKey: rawGroupKey)
        await RemoteAvatarDiskCache.groupThumbnailShared.store(png, forKey: thumbGroupKey)
        #expect(await RemoteAvatarDiskCache.groupShared.data(forKey: rawGroupKey) == png)
        #expect(await RemoteAvatarDiskCache.groupThumbnailShared.data(forKey: thumbGroupKey) == png)

        #expect(await appState.signOutAndWipeActiveAccount())

        // Profile B remains signed in, yet profile A's cached avatars are purged.
        #expect(appState.phase == .ready)
        #expect(appState.accounts.contains { $0.accountIdHex == importedSnapshot.accountIdHex })
        #expect(RemoteAvatarImageLoader.cachedImage(for: avatarURL, maxPixelSize: 16) == nil)
        #expect(await RemoteAvatarDiskCache.shared.data(for: avatarURL) == nil)
        #expect(await RemoteAvatarDiskCache.groupShared.data(forKey: rawGroupKey) == nil)
        #expect(await RemoteAvatarDiskCache.groupThumbnailShared.data(forKey: thumbGroupKey) == nil)

        await stopReadyRuntime(appState)
    }

    @Test(.sharedAvatarCacheAccess) func eraseAppDataWhenBackgroundedKeepsSQLCipherClosedAndRecoversOnForeground() async throws {
        let rebuildCount = Mutex(0)
        let factory: RuntimeLifecycle.RuntimeClientFactory = { rootPath, relayUrls, cursorPersistence, telemetryConfig in
            rebuildCount.withLock { $0 += 1 }
            return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                rootPath: rootPath,
                relayUrls: relayUrls,
                cursorPersistence: cursorPersistence,
                telemetryConfig: telemetryConfig
            )
        }
        let appState = try ownedAppState(
            client: try ownedTestClient(),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: factory
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        let account = try await appState.createIdentity()
        #expect(appState.phase == .ready)
        #expect(appState.activeAccountRef == account.label)

        // Hold a foreground mutation lease so `eraseAppData()` pauses inside
        // `prepareForAppErasure()`, letting us deliver a real background
        // suspension mid-erasure before storage teardown finishes.
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let eraseTask = Task { @MainActor in
            try await appState.eraseAppData()
        }
        try await eventually { appState.isErasingAppData }

        let suspension = appState.startRuntimeSuspension()
        try await eventually { appState.client == nil && appState.runtimeSuspendedForBackground }

        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        await #expect(throws: (any Error).self) {
            try await eraseTask.value
        }
        await suspension.value

        // SQLCipher must stay closed while backgrounded (no 0xdead10cc reopen).
        #expect(rebuildCount.withLock { $0 } == 0)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.erasureState.needsRecovery)

        // Foreground return rebuilds cleanly straight into erasure recovery
        // without activating the surviving account or starting maintenance.
        await appState.startForegroundActivation().value
        #expect(rebuildCount.withLock { $0 } == 1)
        #expect(appState.client != nil)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.activeAccountRef == nil)
        #expect(!appState.notificationSubscriptionActive)
        #expect(appState.runtimeEventsGeneration == nil)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork
        ))

        // Opening and closing Control Center (`.inactive` -> `.active` with the
        // live client still open) must keep the surviving account out of
        // foreground maintenance and event observation until recovery finishes.
        appState.setAppSceneActive(false)
        await appState.startForegroundActivation().value
        #expect(rebuildCount.withLock { $0 } == 1)
        #expect(appState.client != nil)
        #expect(appState.activeAccountRef == nil)
        #expect(!appState.notificationSubscriptionActive)
        #expect(appState.runtimeEventsGeneration == nil)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork
        ))

        await stopReadyRuntime(appState)
    }

    @Test(.sharedAvatarCacheAccess) func closeForAppErasureDoesNotDeadlockWithBackgroundSuspension() async throws {
        let closeEntered = TestLatch()
        let closeRelease = TestLatch()
        defer { closeRelease.signal() }
        let shouldParkClose = Mutex(false)
        let heldLockFD = Mutex<Int32?>(nil)
        let initialClient = try ownedTestClient()
        let initialMarmot = initialClient.marmot
        let lockPath = URL(fileURLWithPath: initialClient.rootPath, isDirectory: true)
            .appendingPathComponent(AppDataErasure.runtimeLockName)
            .path
        defer {
            if let fd = heldLockFD.withLock({ fd -> Int32? in
                defer { fd = nil }
                return fd
            }) {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeCloser: { client in
                if shouldParkClose.withLock({ $0 }) {
                    shouldParkClose.withLock { $0 = false }
                    closeEntered.signal()
                    await closeRelease.hold()
                    try await client.marmot.shutdownAndClose()
                    // Hold `.marmot-runtime.lock` right after storage closes so
                    // `eraseClosedRuntime` fails with EBUSY before
                    // `clearContainerFiles()` touches shared `temporaryDirectory`.
                    let fd = open(lockPath, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
                    if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
                        heldLockFD.withLock { $0 = fd }
                    } else if fd >= 0 {
                        close(fd)
                    }
                    return
                }
                try await client.marmot.shutdownAndClose()
            },
            mutationDrainSleeper: { _ in }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        #expect(appState.phase == .ready)

        // Pause `eraseAppData()` in `prepareForAppErasure()`, then start
        // background suspension so it claims the storage-close gate and parks
        // BEFORE `shutdownAndClose()`. While `initialMarmot` is still open,
        // release the mutation lease so erasure removes accounts and reaches
        // `closeForAppErasure()` while suspension still owns the close gate.
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let eraseFinished = TestLatch()
        let eraseTask = Task { @MainActor in
            defer { eraseFinished.signal() }
            try await appState.eraseAppData()
        }
        try await eventually { appState.isErasingAppData }

        shouldParkClose.withLock { $0 = true }
        let suspensionFinished = TestLatch()
        let suspension = Task { @MainActor in
            defer { suspensionFinished.signal() }
            await appState.startRuntimeSuspension().value
        }
        try await closeEntered.wait()
        #expect(appState.runtimeLifecycle.isRuntimeSuspendingNow)

        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        // Wait until `eraseAppData()` has removed all local accounts and reached
        // `closeForAppErasure()` waiting on the suspension's close gate.
        try await eventually { (try? await initialClient.listAccounts().isEmpty) == true }
        #expect(appState.isErasingAppData)
        #expect(appState.runtimeLifecycle.isRuntimeSuspendingNow)

        // Release the suspension's close: `prepareForBackgroundSuspension` must
        // release the storage-close gate before awaiting `waitForAccountExitToFinish()`,
        // letting `closeForAppErasure()` return and both tasks finish cleanly.
        closeRelease.signal()
        try await eraseFinished.wait()
        do {
            try await eraseTask.value
            Issue.record("Expected EBUSY from eraseClosedRuntime")
        } catch let error as POSIXError {
            #expect(error.code == .EBUSY)
        }
        try await suspensionFinished.wait()
        await suspension.value

        #expect(initialMarmot.storageIsClosed())
        #expect(!appState.isErasingAppData)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
    }

    @Test(.sharedAvatarCacheAccess, arguments: [false, true])
    func inactiveErasureFailureParksStorageCloseBehindTrackedSuspension(
        returnToForeground: Bool
    ) async throws {
        let rebuildCount = Mutex(0)
        let rebuildEntered = TestLatch()
        let closeEntered = TestLatch()
        let closeRelease = TestLatch()
        let initialClient = try ownedTestClient()
        let initialMarmot = initialClient.marmot
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                rebuildCount.withLock { $0 += 1 }
                rebuildEntered.signal()
                return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeCloser: { client in
                closeEntered.signal()
                await closeRelease.hold()
                try await client.marmot.shutdownAndClose()
                throw URLError(.cannotCloseFile)
            }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        #expect(appState.phase == .ready)

        // Hold a mutation lease so `eraseAppData()` pauses in `prepareForAppErasure()`,
        // then move the scene to `.inactive` before letting `closeForAppErasure()`
        // enter `runtimeCloser` under `isBackgroundStorageCloseInProgress`.
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let eraseTask = Task { @MainActor in
            try await appState.eraseAppData()
        }
        try await eventually { appState.isErasingAppData }
        appState.setAppSceneActive(false)
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)

        try await closeEntered.wait()
        #expect(!initialMarmot.storageIsClosed())
        #expect(appState.runtimeLifecycle.isRuntimeSuspendingNow)

        let suspensionWaitReached = TestLatch()
        appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = { waitKind, isWaiting in
            if waitKind == .runtimeWork, isWaiting {
                suspensionWaitReached.signal()
            }
        }
        defer { appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = nil }

        let transitionCompleted = TestLatch()
        let transitionTask: Task<Void, Never>
        if returnToForeground {
            // While `isErasingAppData` is true, foreground activation records
            // `.active`; the actual rebuild runs in `finishAppErasureRuntimeTransition`
            // only AFTER `closeForAppErasure()` releases the storage-close gate.
            transitionTask = appState.startForegroundActivation()
            await transitionTask.value
            #expect(appState.isAppSceneActive)
            #expect(!rebuildEntered.isSignalled)
            #expect(rebuildCount.withLock { $0 } == 0)
            #expect(!initialMarmot.storageIsClosed())
        } else {
            transitionTask = appState.startRuntimeSuspension()
            let observer = Task { @MainActor in
                await transitionTask.value
                transitionCompleted.signal()
            }
            // Wait for the exact `prepareForBackgroundSuspension` wait boundary
            // before asserting that suspension stays parked until `closeRelease`.
            try await suspensionWaitReached.wait()
            #expect(!transitionCompleted.isSignalled)
            #expect(!initialMarmot.storageIsClosed())
            closeRelease.signal()
            do {
                try await eraseTask.value
                Issue.record("Expected injected close error")
            } catch let error as URLError {
                #expect(error.code == .cannotCloseFile)
            }
            await observer.value
            #expect(transitionCompleted.isSignalled)
            #expect(initialMarmot.storageIsClosed())
            #expect(appState.erasureState.needsRecovery)
            #expect(rebuildCount.withLock { $0 } == 0)
            #expect(appState.client == nil)
            #expect(appState.runtimeSuspendedForBackground)
            return
        }

        closeRelease.signal()
        do {
            try await eraseTask.value
            Issue.record("Expected injected close error")
        } catch let error as URLError {
            #expect(error.code == .cannotCloseFile)
        }

        #expect(initialMarmot.storageIsClosed())
        #expect(rebuildEntered.isSignalled)
        #expect(rebuildCount.withLock { $0 } == 1)
        #expect(appState.client != nil)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.activeAccountRef == nil)
        #expect(!appState.notificationSubscriptionActive)
        #expect(appState.runtimeEventsGeneration == nil)
        #expect(appState.erasureState.needsRecovery)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork
        ))
        await appState.startRuntimeSuspension().value
    }

    @Test(.sharedAvatarCacheAccess, arguments: [false, true])
    func foregroundErasureRecoveryWaitsForInFlightBackgroundCloseBeforeRebuilding(
        foregroundAfterErasureStartsWaiting: Bool
    ) async throws {
        let rebuildCount = Mutex(0)
        let closeEntered = TestLatch()
        let closeRelease = TestLatch()
        defer { closeRelease.signal() }
        let shouldParkClose = Mutex(false)
        let initialClient = try ownedTestClient()
        let initialMarmot = initialClient.marmot
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                rebuildCount.withLock { $0 += 1 }
                return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeCloser: { client in
                try await client.marmot.shutdownAndClose()
                if shouldParkClose.withLock({ $0 }) {
                    shouldParkClose.withLock { $0 = false }
                    closeEntered.signal()
                    await closeRelease.hold()
                }
            },
            mutationDrainSleeper: { _ in }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        #expect(appState.phase == .ready)

        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let eraseTask = Task { @MainActor in
            try await appState.eraseAppData()
        }
        try await eventually { appState.isErasingAppData }

        shouldParkClose.withLock { $0 = true }
        let suspension = appState.startRuntimeSuspension()
        try await closeEntered.wait()
        #expect(appState.isErasingAppData)
        #expect(appState.runtimeLifecycle.isRuntimeSuspendingNow)

        if !foregroundAfterErasureStartsWaiting {
            await appState.startForegroundActivation().value
            #expect(appState.isAppSceneActive)
        }

        // Release erasure: `erasingClient.listAccounts()` fails because storage is
        // already closed, jumping into `finishErasureRuntimeTransition`.
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        try await eventually { !appState.isErasingAppData }

        // A concurrent scene foreground activation arriving after `isErasingAppData`
        // clears must join the single startup owner (never build two runtimes).
        let concurrentActivation = appState.startForegroundActivation()
        #expect(rebuildCount.withLock { $0 } == 0)

        closeRelease.signal()

        await #expect(throws: (any Error).self) {
            try await eraseTask.value
        }
        await suspension.value
        await concurrentActivation.value

        #expect(initialMarmot.storageIsClosed())
        #expect(rebuildCount.withLock { $0 } == 1)
        #expect(appState.client != nil)
        #expect(appState.activeAccountRef == nil)
        #expect(!appState.notificationSubscriptionActive)
        #expect(appState.runtimeEventsGeneration == nil)
        #expect(appState.erasureState.needsRecovery)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork
        ))

        await appState.startRuntimeSuspension().value
    }

    @Test(.sharedAvatarCacheAccess) func failedRecoveryRetryKeepsRecoverySheetLatchedDuringRuntimeRebuild() async throws {
        let rebuildCount = Mutex(0)
        let rebuildEntered = TestLatch()
        let rebuildRelease = TestLatch()
        defer { rebuildRelease.signal() }
        let shouldFailClose = Mutex(true)
        let initialClient = try ownedTestClient()
        let initialMarmot = initialClient.marmot
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                rebuildCount.withLock { $0 += 1 }
                rebuildEntered.signal()
                await rebuildRelease.hold()
                return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeCloser: { client in
                // Model MDK's documented contract: `shutdownAndClose()` leaves
                // every database closed even when it throws an error.
                try await client.marmot.shutdownAndClose()
                if shouldFailClose.withLock({ $0 }) {
                    shouldFailClose.withLock { $0 = false }
                    throw MarmotKitError.Io(details: "injected recovery close failure")
                }
            }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        appState.erasureState.begin()
        appState.erasureState.failed()
        appState.erasureState.noteRecoveryPresented()
        #expect(appState.erasureState.needsRecovery)

        let retryTask = Task { @MainActor in
            try await appState.eraseAppData()
        }
        try await rebuildEntered.wait()

        #expect(initialMarmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(!appState.canUseRuntimeForLocalForegroundWork)
        #expect(appState.erasureState.recoveryInProgress)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork,
            phaseOwnsLiveRuntime: appState.phaseOwnsLiveRuntime
        ))

        rebuildRelease.signal()

        do {
            try await retryTask.value
            Issue.record("Expected injected close failure from runtimeCloser")
        } catch let error as MarmotKitError {
            guard case .Io = error else {
                Issue.record("Unexpected MarmotKitError: \(error)")
                return
            }
        }

        // Foreground recovery must have replaced the closed handle with a fresh
        // usable runtime rather than keeping the spent `StorageClosed` client.
        #expect(rebuildCount.withLock { $0 } == 1)
        let replacement = try #require(appState.client)
        #expect(replacement !== initialClient)
        #expect(!replacement.marmot.storageIsClosed())
        #expect(try await replacement.listAccounts().isEmpty)
        #expect(appState.canUseRuntimeForLocalForegroundWork)
        #expect(!appState.erasureState.recoveryInProgress)
        #expect(appState.erasureState.needsRecovery)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork,
            phaseOwnsLiveRuntime: appState.phaseOwnsLiveRuntime
        ))

        await appState.startRuntimeSuspension().value
    }

    @Test(.sharedAvatarCacheAccess) func failedRecoveryRetryKeepsSheetMountedWhenSceneStaysInactive() async throws {
        let rebuildEntered = TestLatch()
        let rebuildRelease = TestLatch()
        defer { rebuildRelease.signal() }
        let shouldFailClose = Mutex(true)
        let initialClient = try ownedTestClient()
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                rebuildEntered.signal()
                await rebuildRelease.hold()
                return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeCloser: { client in
                try await client.marmot.shutdownAndClose()
                if shouldFailClose.withLock({ $0 }) {
                    shouldFailClose.withLock { $0 = false }
                    throw MarmotKitError.Io(details: "injected inactive retry close failure")
                }
            }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        appState.erasureState.begin()
        appState.erasureState.failed()
        appState.erasureState.noteRecoveryPresented()

        let retryTask = Task { @MainActor in
            try await appState.eraseAppData()
        }
        try await rebuildEntered.wait()

        // Move the scene to `.inactive` (e.g. Control Center) during Retry's
        // rebuild and keep it inactive until `eraseAppData()` returns.
        appState.setAppSceneActive(false)
        rebuildRelease.signal()

        await #expect(throws: MarmotKitError.self) {
            try await retryTask.value
        }

        // The rebuild tore down its handle because the scene stayed `.inactive`,
        // yet the already-open recovery sheet must stay mounted (with Retry
        // disabled while `!canUseRuntimeForLocalForegroundWork`) instead of
        // dismissing and losing its inline error.
        #expect(appState.client == nil)
        #expect(!appState.canUseRuntimeForLocalForegroundWork)
        #expect(appState.erasureState.needsRecovery)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork,
            phaseOwnsLiveRuntime: appState.phaseOwnsLiveRuntime
        ))
        // Explicit handoff to startup recovery if the phase transitions to `.failed`.
        #expect(!appState.erasureState.shouldPresentRecovery(
            runtimeReady: false,
            phaseOwnsLiveRuntime: false
        ))

        // Returning to foreground rebuilds the runtime so Retry re-enables.
        await appState.startForegroundActivation().value
        #expect(appState.canUseRuntimeForLocalForegroundWork)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork,
            phaseOwnsLiveRuntime: appState.phaseOwnsLiveRuntime
        ))

        await appState.startRuntimeSuspension().value
    }

    @Test func pendingErasureRecoveryBlocksAndRevokesAutomaticAttachmentPermissions() async throws {
        @MainActor
        final class AllEnabledPermissionSource: AttachmentPermissionSource {
            private(set) var appliedCount = 0
            func attachmentPermission(accountID: String) -> AttachmentAutomaticPermissionFfi {
                AttachmentAutomaticPermissionFfi(images: true, videos: true, audio: true, files: true)
            }
            func didApplyAttachmentPermission() {
                appliedCount += 1
            }
        }

        let seeded = try await readyAppStateWithCreatedIdentities()
        let rootPath = try #require(seeded.appState.client).rootPath
        let relayUrls = try #require(seeded.appState.client).relayUrls
        await stopReadyRuntime(seeded.appState)

        let erasureSuite = "AttachmentPolicyErasure.\(UUID().uuidString)"
        let erasureDefaults = try #require(UserDefaults(suiteName: erasureSuite))
        defer { erasureDefaults.removePersistentDomain(forName: erasureSuite) }
        AppDataErasureState(defaults: erasureDefaults).begin()

        let relaunched = try ownedAppState(
            client: try reopenedClient(rootPath: rootPath, relayUrls: relayUrls),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            erasureDefaults: erasureDefaults
        )
        relaunched.setAppSceneActive(true)
        await relaunched.bootstrap()

        let client = try #require(relaunched.client)
        let permissions = AllEnabledPermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        // Pending erasure recovery must block both post-start automatic
        // attachment grants and relay profile refreshes even with a surviving
        // signed-in profile.
        #expect(!relaunched.allowsAutomaticAttachmentPolicySync)
        #expect(!relaunched.canRefreshProfiles)
        try await relaunched.synchronizeAutomaticAttachmentPolicyIfAllowed(bridge: bridge)
        #expect(permissions.appliedCount == 0)
        #expect(!bridge.isAttached(to: client))

        // Completing recovery re-enables attachment policy sync and profile refreshes.
        relaunched.erasureState.complete()
        #expect(relaunched.allowsAutomaticAttachmentPolicySync)
        #expect(relaunched.canRefreshProfiles)
        try await relaunched.synchronizeAutomaticAttachmentPolicyIfAllowed(bridge: bridge)
        #expect(permissions.appliedCount == 1)
        #expect(bridge.isAttached(to: client))

        // Revoking and detaching on erasure clears bridge attachment against the
        // live client and revokes MDK's permission generation without granting.
        await bridge.revokeAndDetach(client: client)
        #expect(!bridge.isAttached(to: client))
        #expect(permissions.appliedCount == 1)

        await stopReadyRuntime(relaunched)
    }

    @Test func pendingErasureRecoveryBlocksSignInAndProfileCreationDuringAndAfterForegroundRebuild() async throws {
        let rebuildEntered = TestLatch()
        let rebuildRelease = TestLatch()
        defer { rebuildRelease.signal() }
        let initialClient = try ownedTestClient()
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                rebuildEntered.signal()
                await rebuildRelease.hold()
                return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)

        appState.erasureState.begin()
        appState.erasureState.failed()
        await appState.startRuntimeSuspension().value
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        // Start foreground rebuild under pending erasure recovery and park in
        // `runtimeClientFactory`. A user-initiated sign-in attempt arriving mid-
        // rebuild must be refused immediately without waiting on the rebuild.
        let activation = appState.startForegroundActivation()
        try await rebuildEntered.wait()

        let nsec = TestKeys.randomNsec()
        let importFinished = TestLatch()
        let importTask = Task { @MainActor in
            defer { importFinished.signal() }
            try await appState.importIdentity(nsec)
        }
        try await importFinished.wait()
        await #expect(throws: ForegroundRuntimeMutationError.self) {
            try await importTask.value
        }
        rebuildRelease.signal()
        await activation.value

        let rebuiltClient = try #require(appState.client)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.pendingAccountSetup == nil)
        #expect(try await rebuiltClient.listAccounts().isEmpty)

        // Even once the runtime is rebuilt for retry, sign-in and identity
        // creation remain blocked until erasure recovery finishes.
        await #expect(throws: ForegroundRuntimeMutationError.self) {
            try await appState.importIdentity(nsec)
        }
        await #expect(throws: ForegroundRuntimeMutationError.self) {
            try await appState.createIdentity()
        }
        #expect(appState.activeAccountRef == nil)
        #expect(try await rebuiltClient.listAccounts().isEmpty)

        await appState.startRuntimeSuspension().value
    }

    @Test func foregroundActivationRecoversWhenSceneReturnsActiveDuringInactiveTeardown() async throws {
        let rebuildCount = Mutex(0)
        let teardownEntered = TestLatch()
        let teardownRelease = TestLatch()
        defer { teardownRelease.signal() }
        let shouldParkInactiveTeardown = Mutex(false)
        let initialClient = try ownedTestClient()
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                rebuildCount.withLock { $0 += 1 }
                return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeCloser: { client in
                if shouldParkInactiveTeardown.withLock({ $0 }) {
                    shouldParkInactiveTeardown.withLock { $0 = false }
                    teardownEntered.signal()
                    await teardownRelease.hold()
                }
                try await client.marmot.shutdownAndClose()
            }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        #expect(appState.phase == .ready)
        await appState.startRuntimeSuspension().value
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        // Simulate `.active` -> `.inactive` right after the first replacement
        // handle is constructed, pausing its teardown while `.active` returns.
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = {
            guard rebuildCount.withLock({ $0 }) == 1 else { return }
            shouldParkInactiveTeardown.withLock { $0 = true }
            appState.setAppSceneActive(false)
        }
        defer { appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = nil }

        let firstActivation = appState.startForegroundActivation()
        try await teardownEntered.wait()

        // Scene returns `.active` while the first activation is tearing down
        // the discarded handle; it joins the in-flight task, which must loop
        // and rebuild cleanly instead of leaving `client == nil`.
        let secondActivation = appState.startForegroundActivation()
        teardownRelease.signal()
        await firstActivation.value
        await secondActivation.value

        #expect(rebuildCount.withLock { $0 } == 2)
        #expect(appState.phase == .ready)
        #expect(appState.client != nil)
        #expect(!appState.runtimeSuspendedForBackground)

        await appState.startRuntimeSuspension().value
    }

    @Test func relaunchWithPendingErasureRecoverySkipsSignUpRestoration() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let rootPath = try #require(seeded.appState.client).rootPath
        let relayUrls = try #require(seeded.appState.client).relayUrls
        let surviving = seeded.accounts[0]
        await stopReadyRuntime(seeded.appState)

        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErasureSignUpDraft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftDir) }
        let draftStore = SignUpDraftStore(directory: draftDir)
        var draft = SignUpDraft()
        draft.stage = .publishing
        draft.accountID = surviving.accountIdHex
        draft.accountRef = surviving.label
        draft.displayName = "Interrupted Draft"
        try await draftStore.save(draft)

        let erasureSuite = "SignUpErasureRecovery.\(UUID().uuidString)"
        let erasureDefaults = try #require(UserDefaults(suiteName: erasureSuite))
        defer { erasureDefaults.removePersistentDomain(forName: erasureSuite) }
        AppDataErasureState(defaults: erasureDefaults).begin()

        let relaunched = try ownedAppState(
            client: try reopenedClient(rootPath: rootPath, relayUrls: relayUrls),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            signUpDraftStore: draftStore,
            erasureDefaults: erasureDefaults
        )
        relaunched.setAppSceneActive(true)
        await relaunched.bootstrap()

        // Erasure recovery must keep sign-up restoration suppressed so neither a
        // surviving identity is auto-selected nor the sign-up sheet competes
        // with `EraseAppDataView(isRecovery: true)`.
        #expect(relaunched.activeAccountRef == nil)
        #expect(!relaunched.hasRestoredSignUp)
        #expect(!relaunched.restoreSignUpPresentation)
        #expect(relaunched.erasureState.needsRecovery)
        #expect(relaunched.erasureState.shouldPresentRecovery(
            runtimeReady: relaunched.canUseRuntimeForLocalForegroundWork
        ))

        await stopReadyRuntime(relaunched)
    }

    @Test func pendingErasureRecoveryBlocksNotificationRoutingAndSystemCallbacks() async throws {
        let catchUp = NotificationCatchUpStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp)
        let appState = seeded.appState
        let account = seeded.accounts[0]

        appState.erasureState.begin()
        appState.erasureState.failed()
        appState.activeAccountRef = nil
        let stoppedTask = appState.stopNotificationSubscription()
        await stoppedTask?.value
        await appState.cancelRetentionSweeps()

        let route = LocalNotificationRoute(
            accountRef: account.label,
            groupIdHex: hex("11"),
            notificationKey: "pending-erasure-notif",
            messageIdHex: "msg-1"
        )
        var catchUpCalls = 0
        var connectivityRestoredCalls = 0
        catchUp.onCatchUp = { catchUpCalls += 1 }
        catchUp.onConnectivityRestored = { connectivityRestoredCalls += 1 }

        appState.presentNotification(route: route)
        appState.presentProfile(npub: "npub1recoveryblocked")
        await appState.activateAccount(account.label)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.pendingChatId == nil)
        #expect(appState.pendingProfile == nil)

        var unreadRefreshEntered = false
        appState.beforeUnreadSummaryRefreshForTesting = { unreadRefreshEntered = true }
        defer { appState.beforeUnreadSummaryRefreshForTesting = nil }
        appState.scheduleAccountUnreadSummaryRefresh()
        await appState.refreshAccountUnreadSummaries()
        #expect(!unreadRefreshEntered)
        #expect(!appState.hasPendingUnreadSummaryRefreshForTesting)

        appState.scheduleConnectivityCatchUp(connectivityRestored: true)
        await appState.catchUpAfterForegroundActivation()
        appState.scheduleNativePushRegistrationIfEnabled()
        await appState.syncNativePushRegistrationIfEnabled()
        appState.startReadyForegroundMaintenance()
        #expect(catchUpCalls == 0)
        #expect(connectivityRestoredCalls == 0)
        #expect(!appState.notificationSubscriptionActive)

        await #expect(throws: ForegroundRuntimeMutationError.self) {
            try await appState.removeUnlinkedAccount(accountRef: account.accountIdHex)
        }
        #expect(appState.deviceLinks.unlinkedNotice == nil)

        appState.erasureState.complete()
        await appState.activateAccount(account.label)
        #expect(appState.activeAccountRef == account.label)
        appState.presentNotification(route: route)
        #expect(appState.pendingChatId == hex("11"))

        await stopReadyRuntime(appState)
    }

    @Test func pendingErasureRecoveryBlocksNotificationActions() async throws {
        let rebuildCount = Mutex(0)
        let scheduledFailureNotifications = Mutex(0)
        let closeEntered = TestLatch()
        let closeRelease = TestLatch()
        defer { closeRelease.signal() }
        let shouldParkClose = Mutex(false)
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .denied },
            notificationRequestScheduler: { _ in
                scheduledFailureNotifications.withLock { $0 += 1 }
            }
        )
        let appState = try ownedAppState(
            client: try ownedTestClient(),
            notifications: notifications,
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                rebuildCount.withLock { $0 += 1 }
                return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeCloser: { client in
                if shouldParkClose.withLock({ $0 }) {
                    shouldParkClose.withLock { $0 = false }
                    closeEntered.signal()
                    await closeRelease.hold()
                }
                try await client.marmot.shutdownAndClose()
            }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        let account = try await appState.createIdentity()
        let route = LocalNotificationRoute(
            accountRef: account.label,
            groupIdHex: hex("22"),
            notificationKey: "pending-erasure-action",
            messageIdHex: "msg-2"
        )

        // 1. Mid-wait race: `startRuntimeForNotificationAction()` has no entry
        // guard, so it awaits the parked background suspension first; erasure
        // recovery begins while the suspension is still parked, and the
        // post-wait guard rejects without constructing an ephemeral runtime.
        shouldParkClose.withLock { $0 = true }
        let suspension = appState.startRuntimeSuspension()
        try await closeEntered.wait()

        let leaseStarted = TestLatch()
        let leaseFinished = TestLatch()
        let waitingLeaseTask = Task { @MainActor () -> NotificationActionRuntimeLease in
            defer { leaseFinished.signal() }
            leaseStarted.signal()
            return try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
        }
        try await leaseStarted.wait()
        // `waitingLeaseTask` runs on the MainActor: once `leaseStarted` fires,
        // `startRuntimeForNotificationAction()` has already entered its suspension
        // wait before returning control to this test task.
        appState.erasureState.begin()
        appState.erasureState.failed()
        #expect(!leaseFinished.isSignalled)

        closeRelease.signal()
        await suspension.value

        await #expect(throws: NotificationActionError.runtimeUnavailable) {
            _ = try await waitingLeaseTask.value
        }
        #expect(rebuildCount.withLock { $0 } == 0)

        // 2. While suspended in background with recovery pending, Reply, Mark Read,
        // rejectedReply, and direct lease requests must neither open an ephemeral
        // runtime nor schedule a failure notification referencing the wiped route.
        await appState.performNotificationAction(.reply(route, text: "stale"))
        await appState.performNotificationAction(.markRead(route, messageIdHex: "msg-2"))
        await appState.performNotificationAction(.rejectedReply(route))
        await #expect(throws: NotificationActionError.runtimeUnavailable) {
            _ = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
        }
        #expect(rebuildCount.withLock { $0 } == 0)
        #expect(scheduledFailureNotifications.withLock { $0 } == 0)

        // 3. Even with a live foreground client open for recovery, Reply, Mark Read,
        // and direct lease requests stay blocked until erasure completes.
        await appState.startForegroundActivation().value
        #expect(rebuildCount.withLock { $0 } == 1)
        #expect(appState.client != nil)
        await appState.performNotificationAction(.reply(route, text: "stale"))
        await appState.performNotificationAction(.markRead(route, messageIdHex: "msg-2"))
        await #expect(throws: NotificationActionError.runtimeUnavailable) {
            _ = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
        }
        #expect(scheduledFailureNotifications.withLock { $0 } == 0)

        await appState.startRuntimeSuspension().value
    }

    @Test func bootstrapWithPendingErasureRecoverySkipsAutoSelectionAndMaintenance() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let rootPath = try #require(seeded.appState.client).rootPath
        let relayUrls = try #require(seeded.appState.client).relayUrls
        let surviving = seeded.accounts[0]
        await stopReadyRuntime(seeded.appState)

        let erasureSuite = "BootstrapErasureRecovery.\(UUID().uuidString)"
        let erasureDefaults = try #require(UserDefaults(suiteName: erasureSuite))
        defer { erasureDefaults.removePersistentDomain(forName: erasureSuite) }
        AppDataErasureState(defaults: erasureDefaults).begin()

        let relaunched = try ownedAppState(
            client: try reopenedClient(rootPath: rootPath, relayUrls: relayUrls),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            erasureDefaults: erasureDefaults
        )
        relaunched.setAppSceneActive(true)
        await relaunched.bootstrap()

        #expect(relaunched.accounts.contains { $0.accountIdHex == surviving.accountIdHex })
        #expect(relaunched.activeAccountRef == nil)
        #expect(!relaunched.notificationSubscriptionActive)
        #expect(relaunched.erasureState.needsRecovery)
        #expect(relaunched.erasureState.shouldPresentRecovery(
            runtimeReady: relaunched.canUseRuntimeForLocalForegroundWork
        ))

        await stopReadyRuntime(relaunched)
    }

    @Test func bootstrapWhileSuspendedInBackgroundDoesNotReopenSQLCipher() async throws {
        let rebuildCount = Mutex(0)
        let factory: RuntimeLifecycle.RuntimeClientFactory = { rootPath, relayUrls, cursorPersistence, telemetryConfig in
            rebuildCount.withLock { $0 += 1 }
            return try await RuntimeLifecycle.defaultRuntimeClientFactory(
                rootPath: rootPath,
                relayUrls: relayUrls,
                cursorPersistence: cursorPersistence,
                telemetryConfig: telemetryConfig
            )
        }
        let appState = try ownedAppState(
            client: try ownedTestClient(),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: factory
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value

        #expect(!appState.isAppSceneActive)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)

        await appState.bootstrap()

        #expect(rebuildCount.withLock { $0 } == 0)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
    }

    @Test func foregroundReturnDuringExplicitBootstrapTeardownRebuildsRuntime() async throws {
        let pauseNextRefresh = Mutex(false)
        let checkpoint = AsyncTestCheckpoint()
        let reads = AccountRefreshReadsStub()
        reads.beforeListAccounts = {
            guard pauseNextRefresh.withLock({ $0 }) else { return }
            pauseNextRefresh.withLock { $0 = false }
            await checkpoint.pause()
        }
        let appState = try testAppState(refreshReads: reads)
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)

        await appState.startRuntimeSuspension().value
        #expect(appState.client == nil)
        appState.setAppSceneActive(true)
        pauseNextRefresh.withLock { $0 = true }

        let restartTask = Task { @MainActor in
            await appState.bootstrap()
        }
        await checkpoint.waitUntilPaused()

        appState.setAppSceneActive(false)
        await checkpoint.release()
        await restartTask.value

        #expect(appState.phase == .onboarding)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await appState.startForegroundActivation().value

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.client != nil)
        #expect(appState.canUseRuntimeForLocalForegroundWork)

        await appState.startRuntimeSuspension().value
    }

    @Test func backgroundSuspensionDuringExplicitBootstrapAwaitsStartupAndClosesStorage() async throws {
        let pauseReplacementMake = Mutex(false)
        let makeEntered = TestLatch()
        let makeRelease = TestLatch()
        let replacementMarmot = Mutex<Marmot?>(nil)
        let initialClient = try ownedTestClient()
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                let built = try await RuntimeLifecycle.defaultRuntimeClientFactory(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
                if pauseReplacementMake.withLock({ $0 }) {
                    pauseReplacementMake.withLock { $0 = false }
                    replacementMarmot.withLock { $0 = built.marmot }
                    makeEntered.signal()
                    await makeRelease.hold()
                }
                return built
            }
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)

        await appState.startRuntimeSuspension().value
        #expect(appState.phase == .onboarding)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(appState.client == nil)

        appState.setAppSceneActive(true)
        pauseReplacementMake.withLock { $0 = true }
        let restartTask = Task { @MainActor in
            await appState.bootstrap()
        }
        try await makeEntered.wait()
        let openedMarmot = try #require(replacementMarmot.withLock { $0 })
        #expect(!openedMarmot.storageIsClosed())

        let waitingForBootstrap = TestLatch()
        appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = { waitKind, isWaiting in
            if waitKind == .bootstrap, isWaiting {
                waitingForBootstrap.signal()
            }
        }
        defer { appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = nil }

        var suspensionFinished = false
        let suspensionTask = Task { @MainActor in
            await appState.startRuntimeSuspension().value
            suspensionFinished = true
        }
        try await waitingForBootstrap.wait()
        #expect(!suspensionFinished)

        makeRelease.signal()
        await suspensionTask.value
        await restartTask.value

        #expect(suspensionFinished)
        #expect(openedMarmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
    }

    @Test func runtimeEventsGenerationIsSuppressedWhileErasureRecoveryIsPending() async throws {
        let initialClient = try ownedTestClient()
        let rootPath = initialClient.rootPath
        let relayUrls = initialClient.relayUrls
        let appState = try ownedAppState(
            client: initialClient,
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults
        )
        appState.erasureState.begin()
        appState.erasureState.failed()
        #expect(appState.erasureState.blocksNormalAccountActivation)

        appState.setAppSceneActive(true)
        await appState.bootstrap()
        #expect(appState.client != nil)
        #expect(appState.runtimeEventsGeneration == nil)

        appState.erasureState.complete()
        #expect(appState.runtimeEventsGeneration == appState.runtimeGeneration)

        // Seed a real account on disk, then relaunch into pending erasure
        // recovery reporting that profile as unlinked: `refreshAccounts` must
        // not queue the Device Unlinked alert and `removeUnlinkedAccount` must
        // refuse while recovery is pending.
        let surviving = try await appState.createIdentity()
        await appState.startRuntimeSuspension().value

        let unlinkedSummary = AccountSummaryFfi(
            label: surviving.label,
            accountIdHex: surviving.accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false,
            unlinked: true
        )
        let unlinkedReads = AccountRefreshReads(
            listAccounts: { _ in [unlinkedSummary] },
            onboardingSnapshot: { _, _ in nil }
        )
        let unlinkedAppState = try ownedAppState(
            client: try reopenedClient(rootPath: rootPath, relayUrls: relayUrls),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            accountRefreshReads: unlinkedReads
        )
        unlinkedAppState.erasureState.begin()
        unlinkedAppState.erasureState.failed()
        unlinkedAppState.setAppSceneActive(true)
        await unlinkedAppState.bootstrap()
        #expect(unlinkedAppState.deviceLinks.unlinkedNotice == nil)
        await #expect(throws: ForegroundRuntimeMutationError.self) {
            try await unlinkedAppState.removeUnlinkedAccount(accountRef: unlinkedSummary.accountIdHex)
        }
        unlinkedAppState.erasureState.complete()
        try await unlinkedAppState.refreshAccounts(refreshUnreadSummaries: false)
        #expect(unlinkedAppState.deviceLinks.unlinkedNotice?.accountIdHex == unlinkedSummary.accountIdHex)

        await unlinkedAppState.startRuntimeSuspension().value
    }

    @Test func interruptedImportStaysGatedWithoutRestoringSetup() async throws {
        let appState = try testAppState()
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        let summary = try await appState.importIdentity(TestKeys.randomNsec())
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
        _ = try await appState.importIdentity(TestKeys.randomNsec())
        try await appState.refreshAccounts(refreshUnreadSummaries: false)
        #expect(appState.pendingAccountSetup != nil)
        #expect(appState.activeAccountRef == active)
        #expect(appState.accounts.count == 1)
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
    }

    @Test func accountRefreshStartedBeforeImportCannotDiscardItsNewSetup() async throws {
        let reads = AccountRefreshReadsStub()
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
        let appState = seeded.appState
        let active = appState.activeAccountRef
        let maintenance = appState.beginForegroundMaintenanceCancellation()
        for task in maintenance.mutationFollowups { await task.value }
        let checkpoint = AsyncTestCheckpoint()
        defer { Task { await checkpoint.release() } }
        reads.beforeOnboardingSnapshot = { _ in await checkpoint.pause() }
        let refresh = Task { try await appState.refreshAccounts(refreshUnreadSummaries: false) }
        await checkpoint.waitUntilPaused()
        reads.beforeOnboardingSnapshot = nil
        _ = try await appState.importIdentity(TestKeys.randomNsec())
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
        let reads = AccountRefreshReadsStub()
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
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
        try await eventually { model.canFinish }
        try #require(model.canFinish)
        appState.activeAccountRef = nil
        appState.setPhase(.onboarding)
        appState.signInAttempts.begin(account.accountIdHex)
        appState.pendingAccountSetup = model
        appState.isAccountSetupPresented = true
        reads.beforeOnboardingSnapshot = { accountID in
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

        reads.beforeOnboardingSnapshot = nil
        await model.connect(CompletedAccountSetupTestClient(snapshot: completed))
        try await eventually { model.canFinish }
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
        let reads = AccountRefreshReadsStub()
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
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
        try await eventually { model.canFinish }
        try #require(model.canFinish)
        appState.signInAttempts.begin(account.accountIdHex)
        appState.pendingAccountSetup = model
        let checkpoint = AsyncTestCheckpoint()
        defer { Task { await checkpoint.release() } }
        reads.beforeOnboardingSnapshot = { _ in
            await checkpoint.pause()
            throw CocoaError(.fileReadCorruptFile)
        }
        let refresh = Task { try await appState.refreshAccounts(refreshUnreadSummaries: false) }
        await checkpoint.waitUntilPaused()
        reads.beforeListAccounts = { throw CocoaError(.fileReadCorruptFile) }
        await appState.finishAccountSetup()
        try #require(appState.pendingAccountSetup === model)
        reads.beforeListAccounts = nil
        reads.beforeOnboardingSnapshot = nil
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
        let reads = AccountRefreshReadsStub()
        let appState = try ownedAppState(
            client: try ownedTestClient(), notifications: deniedNotifications(),
            accountDefaults: accountDefaults, runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(delays: [.zero]),
            accountRefreshReads: reads.reads
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value
        let generation = appState.runtimeGeneration
        var attempts = 0
        var retainedClient: MarmotClient?
        reads.beforeListAccounts = {
            attempts += 1
            retainedClient = appState.client
            if exhaustRetries || attempts == 1 { throw MarmotKitError.StorageBusy(details: "test contention") }
        }
        await appState.startForegroundActivation().value
        #expect(attempts == 2)
        if exhaustRetries {
            #expect(appState.client == nil)
            if case .failed = appState.phase {} else { Issue.record("Expected a recoverable startup failure") }
            reads.beforeListAccounts = nil
            // Keep the failed handle alive: Retry must still be able to reopen its root.
            #expect(retainedClient != nil)
            await appState.bootstrap()
        }
        #expect(appState.phase == .onboarding)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration > generation)
        #expect(appState.client != nil)
        reads.beforeListAccounts = nil
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
        let reads = AccountRefreshReadsStub()
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
        let appState = seeded.appState
        let healthy = seeded.accounts[0]
        let broken = try await appState.importIdentity(TestKeys.randomNsec())
        reads.beforeOnboardingSnapshot = { accountID in
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
        reads.beforeOnboardingSnapshot = nil
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
        let broken = try await original.importIdentity(TestKeys.randomNsec())
        let root = try #require(original.client?.rootPath)
        let relays = try #require(original.client?.relayUrls)
        original.setAppSceneActive(false)
        await original.startRuntimeSuspension().value
        accountDefaults.set(broken.label, forKey: AccountStore.activeAccountKey)
        let reads = AccountRefreshReadsStub()
        let appState = try ownedAppState(
            client: try reopenedClient(rootPath: root, relayUrls: relays),
            notifications: deniedNotifications(), accountDefaults: accountDefaults,
            accountRefreshReads: reads.reads
        )
        reads.beforeOnboardingSnapshot = { accountID in
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
            reads.beforeOnboardingSnapshot = nil
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
        try await eventually { model.canFinish }
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
        let reads = AccountRefreshReadsStub()
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
        let appState = seeded.appState
        let account = seeded.accounts[0]
        if signIn { #expect(await appState.signOut()) }
        reads.beforeOnboardingSnapshot = { _ in
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
        reads.beforeOnboardingSnapshot = nil
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
        let reads = AccountRefreshReadsStub()
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
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(delays: [.zero]),
            accountRefreshReads: reads.reads
        )
        var attempts = 0
        reads.beforeOnboardingSnapshot = { _ in
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
        let reads = AccountRefreshReadsStub()
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
        let appState = seeded.appState
        let originalIDs = appState.accounts.map(\.accountIdHex)
        reads.beforeOnboardingSnapshot = { _ in throw CancellationError() }
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
        let first = try await appState.importIdentity(TestKeys.randomNsec())
        let second = try await appState.importIdentity(TestKeys.randomNsec())
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

        let timings = HostPerformanceRecorderStub()
        let relaunched = try ownedAppState(
            client: try reopenedClient(
                rootPath: originalRootPath,
                relayUrls: originalRelayUrls
            ),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            hostPerformanceRecorder: timings.recorder
        )
        relaunched.setAppSceneActive(true)
        let checkpoint = AsyncTestCheckpoint()
        relaunched.beforeUnreadSummaryRefreshForTesting = {
            await checkpoint.pause()
        }
        var splashReadySuccesses = 0
        var phaseWhenSplashReadyWasRecorded: AppState.Phase?
        timings.onRecord = { operation, _, outcome in
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
        timings.onRecord = nil
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
            // Enabling native push is the notification-defaults follow-up's last write.
            try await eventually { await appState.notificationSettings(for: account.label)?.nativePushEnabled == true }

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
            // New accounts start with local notifications on; after a denied
            // request the follow-up writes them off and stops, with native push
            // still off, so nothing can register.
            try await eventually { await appState.notificationSettings(for: account.label)?.localNotificationsEnabled == false }

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
        let catchUp = NotificationCatchUpStub()
        let appState = try testAppState(catchUp: catchUp)
        await appState.bootstrap()
        var catchUpAttempts = 0
        catchUp.onCatchUp = {
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
        // In onboarding the scheduled catch-up stops at its gate before it
        // first suspends, so one main-actor turn lets it run to the end; a
        // gate that wrongly opened would have called the stub by then.
        await Task { @MainActor in }.value
        #expect(catchUpAttempts == 0)
        catchUp.onCatchUp = nil

        await appState.startRuntimeSuspension().value
        resetPersistedActiveAccountRef()
    }

    /// #222: a rapid `.background` → `.active` transition starts a runtime
    /// suspension and a foreground activation that race. Previously the
    /// suspension tore the runtime down even though the scene had returned to
    /// active (the resume task it cancelled returned early), stranding the app
    /// foregrounded with `client == nil` and nothing to re-trigger resume.
    /// Driving both synchronous entry points back-to-back and waiting for the
    /// rescheduled resume must leave a running runtime.
    @Test func backgroundThenForegroundRaceLeavesRuntimeRunning() async throws {
        let catchUp = NotificationCatchUpStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp)
        let appState = seeded.appState
        let generation = appState.runtimeGeneration
        var catchUpAttempts = 0
        catchUp.onCatchUp = { catchUpAttempts += 1 }

        // Interleave the entry points the way SwiftUI delivers a fast
        // background→foreground bounce: both run synchronously before either
        // task body executes.
        let suspension = appState.startRuntimeSuspension()
        appState.startForegroundActivation()
        // The suspension sees the scene active again and reschedules the resume,
        // whose last step schedules the catch-up: one call means it finished.
        await suspension.value
        try await eventually { catchUpAttempts == 1 }
        catchUp.onCatchUp = nil

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
        let catchUp = NotificationCatchUpStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp)
        let appState = seeded.appState
        var catchUpAttempts = 0
        catchUp.onCatchUp = { catchUpAttempts += 1 }

        appState.startForegroundActivation()
        let suspension = appState.startRuntimeSuspension()
        appState.startForegroundActivation()
        // As above: the rescheduled resume ends by scheduling the catch-up.
        await suspension.value
        try await eventually { catchUpAttempts == 1 }
        catchUp.onCatchUp = nil

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
        await Task.yield()

        #expect(foregroundRuntimeCreateCount == 1)

        await checkpoint.release()
        await firstActivation.value
        await secondActivation.value
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = nil
        // Both activations have finished, so a second runtime would be counted by now.
        #expect(foregroundRuntimeCreateCount == 1)

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
        let catchUp = NotificationCatchUpStub()
        let timings = HostPerformanceRecorderStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp, timings: timings)
        let appState = seeded.appState

        await appState.startRuntimeSuspension().value

        let checkpoint = AsyncTestCheckpoint()
        var catchUpAttempts = 0
        catchUp.onCatchUp = {
            catchUpAttempts += 1
            await checkpoint.pause()
        }
        var localReadySuccesses = 0
        var warmingUpWhenLocalReadyWasRecorded: Bool?
        timings.onRecord = { operation, _, outcome in
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
        #expect(appState.isConnectivityCatchUpInProgress)
        #expect(localReadySuccesses == 1)
        #expect(warmingUpWhenLocalReadyWasRecorded == false)

        await checkpoint.release()
        try await eventually { !appState.isConnectivityCatchUpInProgress }
        catchUp.onCatchUp = nil
        timings.onRecord = nil

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
        let timings = HostPerformanceRecorderStub()
        let seeded = try await readyAppStateWithCreatedIdentities(timings: timings)
        let appState = seeded.appState
        await appState.startRuntimeSuspension().value

        var stages: [(HostPerformanceOperationFfi, HostPerformanceOutcomeFfi)] = []
        timings.onRecord = { operation, _, outcome in
            stages.append((operation, outcome))
        }
        await appState.startForegroundActivation().value
        timings.onRecord = nil

        #expect(stages.contains { $0.0 == .runtimeInit && $0.1 == .success })
        #expect(stages.contains { $0.0 == .accountLoad && $0.1 == .success })

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
        let catchUp = NotificationCatchUpStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp)
        let appState = seeded.appState

        await appState.startRuntimeSuspension().value

        var catchUpAttempts = 0
        catchUp.onCatchUp = {
            catchUpAttempts += 1
            throw ForegroundRuntimeMutationError.runtimeUnavailable
        }

        await appState.startForegroundActivation().value
        try await eventually { catchUpAttempts == 1 && !appState.isConnectivityCatchUpInProgress }
        catchUp.onCatchUp = nil

        #expect(catchUpAttempts == 1)
        #expect(appState.phase == .ready)
        #expect(!appState.isRuntimeWarmingUp)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.client != nil)

        await stopReadyRuntime(appState)
    }

    @Test func connectivityRestoredWakesDurableRetriesBeforeCatchUp() async throws {
        let catchUp = NotificationCatchUpStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp)
        let appState = seeded.appState
        var operations: [String] = []
        let caughtUp = TestLatch()
        catchUp.onConnectivityRestored = {
            operations.append("wake")
        }
        catchUp.onCatchUp = {
            operations.append("catch-up")
            caughtUp.signal()
        }

        appState.scheduleConnectivityCatchUp(connectivityRestored: true)
        try await caughtUp.wait()

        #expect(operations == ["wake", "catch-up"])
        catchUp.onConnectivityRestored = nil
        catchUp.onCatchUp = nil
        await stopReadyRuntime(appState)
    }

    @Test func staleForegroundActivationDoesNotScheduleCatchUpAfterBackgroundWins() async throws {
        let catchUp = NotificationCatchUpStub()
        let timings = HostPerformanceRecorderStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp, timings: timings)
        let appState = seeded.appState

        await appState.startRuntimeSuspension().value

        let checkpoint = AsyncTestCheckpoint()
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = {
            await checkpoint.pause()
        }
        var catchUpAttempts = 0
        var localReadySamples = 0
        catchUp.onCatchUp = {
            catchUpAttempts += 1
        }
        timings.onRecord = { operation, _, _ in
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
        appState.runtimeLifecycle.afterForegroundRuntimeCreatedForTesting = nil
        timings.onRecord = nil
        catchUp.onCatchUp = nil

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

        var events: [String] = []
        let waitingForBootstrap = TestLatch()
        appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = { wait, isWaiting in
            guard wait == .bootstrap else { return }
            events.append(isWaiting ? "waiting" : "stopped waiting")
            if isWaiting {
                waitingForBootstrap.signal()
            } else {
                // The wait ends only once bootstrap has finished promoting the phase.
                #expect(appState.phase != .bootstrapping)
            }
        }
        defer { appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = nil }
        let suspensionTask = appState.startRuntimeSuspension()

        // `hold` records a missing signal and carries on, so the checkpoint is
        // still released below and the test fails instead of hanging.
        await waitingForBootstrap.hold()
        #expect(events == ["waiting"])
        #expect(appState.phase == .bootstrapping)
        #expect(appState.client != nil)

        events.append("bootstrap released")
        await checkpoint.release()
        await bootstrapTask.value
        await suspensionTask.value

        // Suspension waited until bootstrap was released, then tore down.
        #expect(events == ["waiting", "bootstrap released", "stopped waiting"])
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
        try await eventually {
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
        // A notification-action lease joins any in-flight activation or
        // suspension first; with no suspension started it leases the live
        // runtime instead of opening an ephemeral one.
        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction(actionID: UUID())
        #expect(!lease.ownsEphemeralRuntime)
        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)

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

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction(actionID: UUID())

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

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction(actionID: UUID())
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

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction(actionID: UUID())

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

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction(actionID: UUID())
        #expect(!lease.ownsEphemeralRuntime)
        #expect(lease.client === appState.client)
        #expect(appState.runtimeLifecycle.isRuntimeSuspendingNow)

        var events: [String] = []
        let waitingForLease = TestLatch()
        appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = { wait, isWaiting in
            guard wait == .runtimeWork else { return }
            events.append(isWaiting ? "waiting" : "stopped waiting")
            if isWaiting {
                waitingForLease.signal()
            } else {
                // The wait ends only once the lease has released the suspension gate.
                #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
            }
        }
        defer { appState.runtimeLifecycle.backgroundSuspensionWaitForTesting = nil }
        let suspension = appState.startRuntimeSuspension()

        // `hold` records a missing signal and carries on, so the lease is still
        // released below; otherwise runtime cleanup would wait on it forever.
        await waitingForLease.hold()
        #expect(events == ["waiting"])
        #expect(appState.client === lease.client)
        #expect(!appState.runtimeSuspendedForBackground)

        events.append("lease released")
        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)
        await suspension.value

        // Suspension waited until the lease was released, then tore down.
        #expect(events == ["waiting", "lease released", "stopped waiting"])
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
        let operationReturned = TestLatch()
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
            ) { _, _ in
                await checkpoint.pause(timeout: .seconds(600))
                operationReturned.signal()
                try Task.checkCancellation()
            }
        }
        await checkpoint.waitUntilPaused()

        let suspension = appState.startRuntimeSuspension()
        await action.value
        await suspension.value

        #expect(!operationReturned.isSignalled)
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

        let lease = try await appState.runtimeLifecycle.startRuntimeForNotificationAction(actionID: UUID())
        #expect(!lease.ownsEphemeralRuntime)

        await appState.runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)

        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await stopReadyRuntime(appState)
    }

    /// The resume-tail badge refresh runs in its own task. Suspension takes it
    /// over and drains it after storage closes, so the task can't outlive
    /// suspension. This checks the takeover; the drain clears the task before
    /// awaiting it, so the await itself isn't observed.
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

        try await eventually {
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

    @Test func backgroundSuspensionWaitsForDraftFlushBeforeClosingSQLCipher() async throws {
        // The drain timeout never fires: on a loaded machine the flush can
        // outlast the real 2 s bound, which the stuck-lease test below covers.
        let drainTimeout = ControlledSleeper()
        let seeded = try await readyAppStateWithCreatedIdentities(
            mutationDrainSleeper: { try await drainTimeout.sleep($0) }
        )
        let appState = seeded.appState
        let account = seeded.accounts[0]
        let client = try #require(appState.client)
        let created = try await client.createGroupWithOptionsDetailed(
            accountRef: account.label,
            name: "Draft Flush",
            memberRefs: [],
            options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0)
        ).requireCreated()

        // Record an unflushed composer edit, then simulate the real iOS
        // `.active → .inactive → .background` transition.
        appState.conversationDraftStore.setDraft(
            ConversationDraftSnapshot(
                canonicalText: "Last keystrokes before backgrounding",
                replyToMessageIdHex: nil,
                mediaAttachments: []
            ),
            accountRef: account.label,
            groupIdHex: created.groupIdHex
        )
        appState.setAppSceneActive(false)
        await appState.startRuntimeSuspension().value

        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        // Rebuild the runtime and verify the draft was flushed to SQLCipher
        // before suspension closed storage.
        await appState.startForegroundActivation().value
        let restored = try #require(appState.client)
        let persisted = try await restored.messageDraft(
            accountRef: account.label,
            groupIdHex: created.groupIdHex
        )
        #expect(persisted?.content == "Last keystrokes before backgrounding")

        await stopReadyRuntime(appState)
    }

    @Test func backgroundSuspensionBoundedTimeoutFallsThroughToStorageCloseOnStuckLease() async throws {
        let sleeperEntered = TestLatch()
        let sleeperRelease = TestLatch()
        let appState = try testAppState(
            mutationDrainSleeper: { _ in
                sleeperEntered.signal()
                try await sleeperRelease.wait()
            }
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        let liveClient = try #require(appState.client)
        let marmot = liveClient.marmot
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()

        let suspension = appState.startRuntimeSuspension()
        var suspensionCompleted = false
        let observer = Task { @MainActor in
            await suspension.value
            suspensionCompleted = true
        }

        // Suspension waits inside the bounded pre-close timeout while the
        // mutation lease is active; storage stays open until timeout fires.
        try await sleeperEntered.wait()
        #expect(!marmot.storageIsClosed())
        #expect(appState.client != nil)

        // Once the bounded timeout expires, terminal storage closure runs even
        // though the stuck mutation lease has not been released yet.
        sleeperRelease.signal()
        try await eventually {
            marmot.storageIsClosed()
        }
        #expect(!suspensionCompleted)
        #expect(appState.client == nil)

        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        await suspension.value
        await observer.value

        #expect(suspensionCompleted)
        #expect(appState.runtimeSuspendedForBackground)
        resetPersistedActiveAccountRef()
    }

    @Test func backgroundToActiveToBackgroundDuringDrainStillClosesStorage() async throws {
        let catchUp = NotificationCatchUpStub()
        let sleeperEntered = TestLatch()
        let sleeperExited = TestLatch()
        let checkpoint = AsyncTestCheckpoint()
        let appState = try testAppState(
            catchUp: catchUp,
            mutationDrainSleeper: { _ in
                defer { sleeperExited.signal() }
                sleeperEntered.signal()
                try await parkUntilCancelled()
            }
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        appState.setAppSceneActive(true)

        // Park a connectivity catch-up task so aborting suspension pauses in
        // `drainForegroundMaintenance` before returning.
        catchUp.onCatchUp = {
            await checkpoint.pause()
        }
        appState.scheduleConnectivityCatchUp()
        await checkpoint.waitUntilPaused()
        catchUp.onCatchUp = nil

        let liveClient = try #require(appState.client)
        let marmot = liveClient.marmot
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()

        // 1. Background: suspension parks in the pre-close mutation wait.
        let suspension1 = appState.startRuntimeSuspension()
        try await sleeperEntered.wait()

        // 2. Return to active: wakes the pre-close wait, cancels its timeout
        //    task (`sleeperExited`), and enters the abort drain (parked on
        //    `checkpoint`).
        _ = appState.startForegroundActivation()
        try await sleeperExited.wait()
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)

        // 3. Background again while the abort drain is still parked: the reused
        //    suspension task must interrupt the abort drain and close storage
        //    BEFORE the parked relay catch-up finishes (preventing 0xdead10cc).
        let suspension2 = appState.startRuntimeSuspension()
        try await eventually {
            marmot.storageIsClosed() && appState.runtimeSuspendedForBackground
        }
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await checkpoint.release()
        await suspension1.value
        await suspension2.value

        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        resetPersistedActiveAccountRef()
    }

    @Test func backgroundToActiveToInactiveDuringDrainKeepsLiveRuntime() async throws {
        let catchUp = NotificationCatchUpStub()
        let sleeperEntered = TestLatch()
        let sleeperExited = TestLatch()
        let checkpoint = AsyncTestCheckpoint()
        let appState = try testAppState(
            catchUp: catchUp,
            mutationDrainSleeper: { _ in
                defer { sleeperExited.signal() }
                sleeperEntered.signal()
                try await parkUntilCancelled()
            }
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        appState.setAppSceneActive(true)
        let initialClient = try #require(appState.client)
        let initialGeneration = appState.runtimeGeneration

        // Park connectivity catch-up so the abort drain suspends.
        catchUp.onCatchUp = {
            await checkpoint.pause()
        }
        appState.scheduleConnectivityCatchUp()
        await checkpoint.waitUntilPaused()
        catchUp.onCatchUp = nil

        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let suspension = appState.startRuntimeSuspension()
        try await sleeperEntered.wait()

        // Return to active (aborts suspension) and immediately lose active focus
        // to a transient `.inactive` overlay such as Face ID App Lock while the
        // abort drain is still parked.
        _ = appState.startForegroundActivation()
        try await sleeperExited.wait()
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        appState.setAppSceneActive(false)

        await checkpoint.release()
        await suspension.value

        // Transient `.inactive` must NOT revive the abandoned suspension.
        #expect(!initialClient.marmot.storageIsClosed())
        #expect(appState.client === initialClient)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == initialGeneration)
        await stopReadyRuntime(appState)
    }

    @Test func abortedSuspensionRestartsNotificationSubscriptionOnForegroundReturn() async throws {
        let sleeperEntered = TestLatch()
        let sleeperExited = TestLatch()
        let appState = try testAppState(
            mutationDrainSleeper: { _ in
                defer { sleeperExited.signal() }
                sleeperEntered.signal()
                try await parkUntilCancelled()
            }
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        appState.setAppSceneActive(true)
        let initialClient = try #require(appState.client)
        let initialGeneration = appState.runtimeGeneration
        try await eventually { appState.notificationSubscriptionActive }

        // Start a background suspension (which cancels the notification
        // subscription synchronously), then return to active before storage closes.
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let suspension = appState.startRuntimeSuspension()
        try await sleeperEntered.wait()
        #expect(!appState.notificationSubscriptionActive)

        let activation = appState.startForegroundActivation()
        try await sleeperExited.wait()
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        await suspension.value
        await activation.value

        // Non-restart foreground resume keeps the same runtime and restores
        // the notification subscription that the aborted suspension stopped.
        #expect(appState.client === initialClient)
        #expect(appState.runtimeGeneration == initialGeneration)
        #expect(!appState.runtimeSuspendedForBackground)
        try await eventually { appState.notificationSubscriptionActive }
        await stopReadyRuntime(appState)
    }

    @Test func foregroundActivationRecoversAfterSecondBackgroundDuringPostCloseDrain() async throws {
        let catchUp = NotificationCatchUpStub()
        let checkpoint = AsyncTestCheckpoint()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp)
        let appState = seeded.appState
        appState.setAppSceneActive(true)
        let generationBefore = appState.runtimeGeneration

        // Park connectivity catch-up so terminal suspension stays alive in its
        // post-close maintenance drain after SQLCipher is already closed.
        catchUp.onCatchUp = {
            await checkpoint.pause()
        }
        appState.scheduleConnectivityCatchUp()
        await checkpoint.waitUntilPaused()
        catchUp.onCatchUp = nil

        let initialClient = try #require(appState.client)
        let suspension1 = appState.startRuntimeSuspension()
        try await eventually {
            initialClient.marmot.storageIsClosed() && appState.runtimeSuspendedForBackground
        }
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        // Activate during the post-close drain, then immediately background
        // again before the drain finishes. The cancelled activation slot must
        // be cleared so the next foreground activation rebuilds the runtime.
        let cancelledActivation = appState.startForegroundActivation()
        let suspension2 = appState.startRuntimeSuspension()
        await checkpoint.release()
        await suspension1.value
        await suspension2.value
        await cancelledActivation.value

        let recoveredActivation = appState.startForegroundActivation()
        await recoveredActivation.value

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.client != nil)
        #expect(appState.runtimeGeneration == generationBefore + 1)
        await stopReadyRuntime(appState)
    }

    @Test func foregroundActivationCompletesWhileEarlierAbortedCatchUpDrainIsStillHeld() async throws {
        let catchUp = NotificationCatchUpStub()
        let checkpoint = AsyncTestCheckpoint()
        let sleeperEntered = TestLatch()
        let sleeperExited = TestLatch()
        let seeded = try await readyAppStateWithCreatedIdentities(
            catchUp: catchUp,
            mutationDrainSleeper: { _ in
                defer { sleeperExited.signal() }
                sleeperEntered.signal()
                try await parkUntilCancelled()
            }
        )
        let appState = seeded.appState
        appState.setAppSceneActive(true)
        let generationBefore = appState.runtimeGeneration

        // Park connectivity catch-up and hold a mutation lease so Suspension A
        // aborts before storage close and parks the catch-up drain.
        catchUp.onCatchUp = {
            await checkpoint.pause()
        }
        appState.scheduleConnectivityCatchUp()
        await checkpoint.waitUntilPaused()
        catchUp.onCatchUp = nil

        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let suspensionA = appState.startRuntimeSuspension()
        try await sleeperEntered.wait()

        let activationA = appState.startForegroundActivation()
        try await sleeperExited.wait()
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        await suspensionA.value
        await activationA.value

        // Run Suspension B to terminal storage closure while Suspension A's
        // parked catch-up is STILL held.
        let initialClient = try #require(appState.client)
        let suspensionB = appState.startRuntimeSuspension()
        try await eventually {
            initialClient.marmot.storageIsClosed() && appState.runtimeSuspendedForBackground
        }

        // Foreground activation must NOT stall behind Suspension A's unrelated
        // parked catch-up drain: it must rebuild the runtime immediately while
        // `checkpoint` is still held.
        let resumedActivation = appState.startForegroundActivation()
        await resumedActivation.value

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        let replacementClient = try #require(appState.client)
        #expect(appState.runtimeGeneration == generationBefore + 1)

        // Backgrounding again while Suspension A's parked catch-up is STILL
        // held must start a fresh suspension task and close the replacement
        // runtime rather than joining Suspension B's already-closed drain.
        let suspensionC = appState.startRuntimeSuspension()
        try await eventually {
            replacementClient.marmot.storageIsClosed()
                && appState.client == nil
                && appState.runtimeSuspendedForBackground
        }

        await checkpoint.release()
        await suspensionB.value
        await suspensionC.value
        await stopReadyRuntime(appState)
    }

    @Test(.sharedAvatarCacheAccess) func backgroundErasureRecoveryBecomesActionableWhileEarlierCatchUpDrainIsStillHeld() async throws {
        let catchUp = NotificationCatchUpStub()
        let catchUpCheckpoint = AsyncTestCheckpoint()
        let sleeperEntered = TestLatch()
        let sleeperExited = TestLatch()
        let failErasureClose = Mutex(false)
        let closeEntered = TestLatch()
        let closeRelease = TestLatch()
        let appState = try ownedAppState(
            client: try ownedTestClient(),
            notifications: deniedNotifications(),
            accountDefaults: accountDefaults,
            runtimeCloser: { client in
                if failErasureClose.withLock({ $0 }) {
                    failErasureClose.withLock { $0 = false }
                    closeEntered.signal()
                    await closeRelease.hold()
                    try? await client.marmot.shutdownAndClose()
                    throw MarmotKitError.Io(details: "simulated erasure close failure")
                }
                try await client.marmot.shutdownAndClose()
            },
            mutationDrainSleeper: { _ in
                defer { sleeperExited.signal() }
                sleeperEntered.signal()
                try await parkUntilCancelled()
            },
            notificationCatchUpCalls: catchUp.calls
        )
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()

        // Park connectivity catch-up and abort Suspension A so an unrelated
        // catch-up drain sits in `pendingMaintenanceDrains`.
        catchUp.onCatchUp = { await catchUpCheckpoint.pause() }
        appState.scheduleConnectivityCatchUp()
        await catchUpCheckpoint.waitUntilPaused()
        catchUp.onCatchUp = nil

        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let suspensionA = appState.startRuntimeSuspension()
        try await sleeperEntered.wait()
        let activationA = appState.startForegroundActivation()
        try await sleeperExited.wait()
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)
        await suspensionA.value
        await activationA.value

        // Start erasure, enter `closeForAppErasure()`, then background the app
        // so Suspension B queues behind erasure's storage-close gate while
        // Suspension A's parked catch-up is STILL held.
        failErasureClose.withLock { $0 = true }
        let erasureTask = Task { @MainActor () -> Bool in
            do {
                try await appState.eraseAppData()
                return true
            } catch {
                return false
            }
        }
        try await closeEntered.wait()
        let suspensionB = appState.startRuntimeSuspension()
        await Task.yield()

        // Let erasure's close fail. `suspendAfterBackgroundErasure()` must join
        // only Suspension B's storage-close slot (not `drainPendingMaintenanceDrains`)
        // so `eraseAppData()` finishes and latches recovery while `catchUpCheckpoint`
        // is still parked, and returning to foreground makes recovery actionable.
        closeRelease.signal()
        let succeeded = await erasureTask.value
        #expect(!succeeded)
        #expect(appState.erasureState.needsRecovery)
        #expect(!appState.erasureState.recoveryInProgress)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        await appState.startForegroundActivation().value
        #expect(appState.client != nil)
        #expect(appState.erasureState.shouldPresentRecovery(
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork
        ))

        await catchUpCheckpoint.release()
        await suspensionB.value
        await stopReadyRuntime(appState)
    }

    @Test func transientInactiveToActiveKeepsLiveRuntimeAndRestoresPushRegistration() async throws {
        let catchUp = NotificationCatchUpStub()
        var remoteRegisterCalls = 0
        let notifications = grantedNotifications(
            remoteNotificationRegistrar: { remoteRegisterCalls += 1 }
        )
        let seeded = try await readyAppStateWithCreatedIdentities(
            notifications: notifications,
            catchUp: catchUp
        )
        let appState = seeded.appState
        appState.setAppSceneActive(true)
        let generation = appState.runtimeGeneration
        let initialClient = try #require(appState.client)
        var catchUpAttempts = 0
        catchUp.onCatchUp = { catchUpAttempts += 1 }
        try await eventually { remoteRegisterCalls >= 1 }
        let registrationsBeforeInactive = remoteRegisterCalls

        // Transient `.inactive → .active` (Face ID, Control Center, Notification
        // Center, App Switcher) keeps the runtime live (no rebuild / generation
        // bump) while still restoring foreground maintenance such as push
        // registration that `.inactive` cancelled.
        appState.setAppSceneActive(false)
        await appState.startForegroundActivation().value
        try await eventually { catchUpAttempts >= 1 && remoteRegisterCalls > registrationsBeforeInactive }
        catchUp.onCatchUp = nil

        #expect(appState.isAppSceneActive)
        #expect(!appState.runtimeSuspendedForBackground)
        #expect(appState.runtimeGeneration == generation)
        #expect(appState.client === initialClient)
        #expect(remoteRegisterCalls > registrationsBeforeInactive)

        // Real `.background → .active` rebuilds the runtime and bumps generation.
        await appState.startRuntimeSuspension().value
        await appState.startForegroundActivation().value
        #expect(appState.runtimeGeneration == generation + 1)
        await stopReadyRuntime(appState)
    }

    @Test func suspensionClosesStorageBeforeConnectivityCatchUpDrains() async throws {
        let catchUp = NotificationCatchUpStub()
        let seeded = try await readyAppStateWithCreatedIdentities(catchUp: catchUp)
        let appState = seeded.appState
        let checkpoint = AsyncTestCheckpoint()

        await appState.startRuntimeSuspension().value
        catchUp.onCatchUp = {
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
        try await eventually {
            marmot.storageIsClosed()
        }

        #expect(!suspensionCompleted)
        #expect(appState.client == nil)

        await checkpoint.release()
        await suspension.value
        await observer.value
        catchUp.onCatchUp = nil

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

        let rewind = MarmotEventFfi.groupEvent(
            accountIdHex: account.accountIdHex, accountLabel: account.label, groupIdHex: "group",
            event: .groupHydrationQuarantined(reason: .rewindRestoreFailed)
        )
        appState.handleRuntimeEvent(rewind, generation: generation - 1)
        #expect(appState.activeToast == nil)
        appState.handleRuntimeEvent(.groupEvent(
            accountIdHex: "unavailable-account", accountLabel: "private", groupIdHex: "group",
            event: .groupHydrationQuarantined(reason: .rewindRestoreFailed)
        ), generation: generation)
        #expect(appState.activeToast == nil)
        appState.handleRuntimeEvent(rewind, generation: generation)
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

        appState.resumeProfileFetchQueueIfNeeded()
        let runner = try #require(appState.profileStore.profileFetchQueueTask)
        // The runner is main-actor work queued behind this test, so it first
        // runs after the scene has gone inactive.
        appState.setAppSceneActive(false)
        await runner.value

        #expect(appState.profileStore.queuedProfileFetchIDs == queued)
        #expect(appState.profileStore.scheduledProfileFetchIDs == Set(queued))
        #expect(appState.profileStore.activeProfileFetchID == nil)
        #expect(appState.profileStore.profileFetchQueueTask == nil)
        #expect(appState.profileStore.profileFetchQueueTaskID == nil)
    }

    @Test func aCancelledFetchRunnerFinishingLeavesItsReplacementInPlace() async throws {
        let appState = try testAppState()
        let store = appState.profileStore
        store.queuedProfileFetchIDs = [hex("44")]
        store.scheduledProfileFetchIDs = [hex("44")]
        appState.resumeProfileFetchQueueIfNeeded()
        let replaced = try #require(store.profileFetchQueueTask)
        // A background pause cancels the runner and keeps its ids; the next
        // foreground resume starts a replacement before the old one has run.
        _ = appState.pauseProfileFetchQueue()
        // Main-actor work runs in order: the cancelled runner, then this check,
        // then the replacement started below.
        let slotAfterOldRunner = Task { @MainActor in
            (store.profileFetchQueueTask, store.profileFetchQueueTaskID)
        }
        appState.resumeProfileFetchQueueIfNeeded()
        let replacement = try #require(store.profileFetchQueueTask)
        let replacementID = store.profileFetchQueueTaskID
        // Inactive before either runner runs, so neither starts a relay refresh.
        appState.setAppSceneActive(false)

        let (task, taskID) = await slotAfterOldRunner.value

        #expect(task == replacement)
        #expect(taskID == replacementID)
        await replaced.value
        await replacement.value
    }

    @Test func aCancelledProjectionRunnerFinishingLeavesItsReplacementInPlace() async throws {
        let appState = try testAppState()
        let store = appState.profileStore
        #expect(appState.knownDisplayName(forAccountIdHex: hex("45")) == nil)
        let replaced = try #require(store.profileProjectionLoadTask)
        _ = appState.pauseProfileFetchQueue()
        let slotAfterOldRunner = Task { @MainActor in
            (store.profileProjectionLoadTask, store.profileProjectionLoadTaskID)
        }
        appState.resumeProfileFetchQueueIfNeeded()
        let replacement = try #require(store.profileProjectionLoadTask)
        let replacementID = store.profileProjectionLoadTaskID
        appState.setAppSceneActive(false)

        let (task, taskID) = await slotAfterOldRunner.value

        #expect(task == replacement)
        #expect(taskID == replacementID)
        await replaced.value
        await replacement.value
    }

    @Test func aSettledProfileReloadPrunesItsLoadVersion() async throws {
        let appState = try testAppState()
        let store = appState.profileStore
        let id = hex("46")

        await store.reloadProfileProjection(forAccountIdHex: id)

        // A filled cache shows the reload took a version and applied its load.
        #expect(store.profileProjectionCache[id] != nil)
        #expect(store.profileProjectionLoadVersions[id] == nil)
    }

    @Test func aSettledQueuedProfileLoadPrunesItsLoadVersion() async throws {
        let appState = try testAppState()
        let store = appState.profileStore
        let id = hex("47")

        // Without refresh-after-load, the queued load never schedules a relay refresh.
        appState.warmProfileProjection(forAccountIdHex: id)
        let runner = try #require(store.profileProjectionLoadTask)
        await runner.value

        #expect(store.profileProjectionCache[id] != nil)
        #expect(store.profileProjectionLoadVersions[id] == nil)
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

    @Test(.sharedAvatarCacheAccess)
    func destructiveWipeClearsProfileProjectionState() async throws {
        // A destructive wipe into onboarding is the one place a whole-map reset is
        // safe: with no active account `canRefreshProfiles` is false, so no
        // in-flight load can re-bump a token for the gone account ids or
        // repopulate the cache and race the reset. Signing out the last account
        // must reclaim accumulated cached projections (#366), version entries
        // (#353), and shared avatar caches, while holding `AvatarCacheErasure`
        // across `refreshAccounts()` and routing so a still-displayed profile
        // cannot repopulate the cache mid-wipe.
        let pauseNextRefresh = Mutex(false)
        let refreshPaused = AsyncTestCheckpoint()
        let reads = AccountRefreshReadsStub()
        reads.beforeListAccounts = {
            guard pauseNextRefresh.withLock({ $0 }) else { return }
            pauseNextRefresh.withLock { $0 = false }
            await refreshPaused.pause()
        }
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
        let appState = seeded.appState
        let account = seeded.accounts[0]
        appState.activeAccountRef = account.label
        appState.profileStore.profileProjectionCache = [
            hex("aa"): ProfileDisplayProjection(profile: nil, projectedName: "Previous peer", localAccountLabel: nil),
            account.accountIdHex: ProfileDisplayProjection(profile: nil, projectedName: nil, localAccountLabel: account.label),
        ]
        appState.profileStore.profileProjectionLoadVersions = [hex("aa"): 9, account.accountIdHex: 2]

        let avatarURL = try #require(URL(string: "https://example.com/wipe-avatar-\(UUID().uuidString).png"))
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        _ = try await RemoteAvatarImageLoader.image(for: avatarURL, maxPixelSize: 16, scale: 1) { _ in png }
        let groupRequest = GroupAvatarImageRequest(
            accountRef: account.label,
            groupIdHex: hex("44"),
            imageHashHex: hex("55"),
            maxPixelSize: 16
        )
        GroupAvatarImageLoader.seed(
            data: png,
            accountRef: groupRequest.accountRef,
            groupIdHex: groupRequest.groupIdHex,
            replacingImageHashHex: nil
        )
        _ = try await GroupAvatarImageLoader.image(
            request: groupRequest,
            scale: 1,
            priority: .foreground,
            client: try appState.currentMarmotClient()
        )
        #expect(RemoteAvatarImageLoader.cachedImage(for: avatarURL, maxPixelSize: 16) != nil)
        #expect(GroupAvatarImageLoader.cachedImage(for: groupRequest) != nil)

        pauseNextRefresh.withLock { $0 = true }
        let wipeTask = Task { @MainActor in
            await appState.signOutAndWipeActiveAccount()
        }
        await refreshPaused.waitUntilPaused()

        // Disk cleanup already ran, while `refreshAccounts()` is still suspended
        // and the departing profile has not routed away yet. Avatar loads must
        // stay rejected so nothing writes back into the cleared cache.
        await #expect(throws: CancellationError.self) {
            _ = try await RemoteAvatarImageLoader.image(for: avatarURL, maxPixelSize: 16, scale: 1) { _ in png }
        }
        #expect(await RemoteAvatarDiskCache.shared.data(for: avatarURL) == nil)

        await refreshPaused.release()
        #expect(await wipeTask.value)

        #expect(appState.activeAccountRef == nil)
        #expect(appState.phase == .onboarding)
        #expect(appState.profileStore.profileProjectionCache.isEmpty)
        #expect(appState.profileStore.profileProjectionLoadVersions.isEmpty)
        #expect(RemoteAvatarImageLoader.cachedImage(for: avatarURL, maxPixelSize: 16) == nil)
        #expect(GroupAvatarImageLoader.cachedImage(for: groupRequest) == nil)
        #expect(await RemoteAvatarDiskCache.shared.data(for: avatarURL) == nil)
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

    @Test func laterLeavesAnUnlinkedProfileSignedOutWhenTheRefreshFails() async throws {
        let reads = AccountRefreshReadsStub()
        let seeded = try await readyAppStateWithCreatedIdentities(refreshReads: reads)
        let appState = seeded.appState
        let account = seeded.accounts[0]
        appState.activeAccountRef = account.label
        reads.beforeListAccounts = { throw URLError(.notConnectedToInternet) }

        await appState.leaveUnlinkedAccount(accountIdHex: account.accountIdHex)
        reads.beforeListAccounts = nil

        // The chooser offers only rows that aren't signed out.
        let row = try #require(appState.accounts.first { $0.accountIdHex == account.accountIdHex })
        #expect(row.signedOut && row.unlinked)
        #expect(appState.activeAccountRef == nil)
        #expect(appState.phase == .onboarding)

        await stopReadyRuntime(appState)
    }

    /// A Remove from an unlinked notice must not wipe a copy of that profile
    /// that was signed in again since, active or not.
    @Test(arguments: [true, false])
    func aStaleUnlinkedRemovalWipesNothing(active: Bool) async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let account = seeded.accounts[0]
        appState.activeAccountRef = account.label
        if !active { #expect(await appState.signOut()) }

        await #expect(throws: ProfileNotUnlinkedError.self) {
            try await appState.removeUnlinkedAccount(accountRef: account.accountIdHex)
        }

        #expect(!appState.isAccountExitInProgress)
        #expect(try await appState.client?.listAccounts().map(\.accountIdHex) == [account.accountIdHex])
        #expect(appState.activeAccountRef == (active ? account.label : nil))

        await stopReadyRuntime(appState)
    }

    @Test func explicitPushDisableSupersedesAnInterruptedExitsRestore() async throws {
        let seeded = try await readyAppStateWithCreatedIdentities()
        let appState = seeded.appState
        let account = seeded.accounts[0]
        appState.activeAccountRef = account.label
        let marmot = try #require(appState.client?.marmot)
        // An exit marked the restore and turned push off, then was interrupted.
        appState.nativePushRestoreIntents.mark(account.label)
        _ = try await marmot.setNativePushEnabled(accountRef: account.label, enabled: false)

        // A pending restore turns push back on for a profile still signed in.
        await appState.restorePendingNativePush()
        #expect(await appState.notificationSettings(for: account.label)?.nativePushEnabled == true)
        #expect(appState.nativePushRestoreIntents.accountRefs.isEmpty)

        // A newer explicit disable wins over a restore still pending.
        appState.nativePushRestoreIntents.mark(account.label)
        _ = try await appState.setNativePushEnabled(false)
        await appState.restorePendingNativePush()
        #expect(await appState.notificationSettings(for: account.label)?.nativePushEnabled == false)
        #expect(appState.nativePushRestoreIntents.accountRefs.isEmpty)

        await stopReadyRuntime(appState)
    }

    /// Suspension closes storage before draining account exit. Sign-out and
    /// wipe must therefore keep one captured client across awaits; re-reading
    /// the former non-optional AppState handle here was a fatal-error race.
    @Test(.sharedAvatarCacheAccess, arguments: [false, true])
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
        try await eventually {
            marmot.storageIsClosed() && appState.client == nil
        }
        await checkpoint.release()

        let succeeded = await accountExit.value
        await suspension.value
        appState.afterAccountExitClientCapturedForTesting = nil

        #expect(!succeeded)
        #expect(!appState.isAccountExitInProgress)
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

        #expect(!appState.isAccountExitInProgress)

        var failure: Toast?
        let signedOut = await appState.signOut(onError: { failure = $0 })

        // The guard clears on every exit path, including a failed sign-out.
        #expect(!appState.isAccountExitInProgress)
        try #require(signedOut, "Sign-out failed: \(failure?.title ?? "-") \(failure?.message ?? "")")
        #expect(appState.activeAccountRef == nil)
        // A reschedule is permitted again; it must not trap or re-raise the flag.
        appState.scheduleNativePushRegistrationIfEnabled()
        #expect(!appState.isAccountExitInProgress)

        await stopReadyRuntime(appState)
    }

    @Test func signOutCancelsNewIdentityNotificationDefaultsBeforeClearingPush() async throws {
        // Identity creation enables notifications and native push in a
        // follow-up task. Sign-out must cancel and await it, or it can land
        // after the push cleanup and re-register the signed-out account.
        let permissionRequested = TestLatch()
        let permissionAnswered = TestLatch()
        let promptCancelled = TestLatch()
        let notifications = AppNotifications(
            requestAuthorizationHandler: {
                permissionRequested.signal()
                try await withTaskCancellationHandler {
                    try await permissionAnswered.wait()
                } onCancel: {
                    promptCancelled.signal()
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

        #expect(signedOut)
        // The prompt is still waiting when sign-out cancels the follow-up; a
        // sign-out that skipped the cancel would let it be answered instead.
        #expect(promptCancelled.isSignalled)
        #expect(await appState.notificationSettings(for: account.label)?.nativePushEnabled == false)
        #expect(await appState.pushRegistration(for: account.label) == nil)

        await stopReadyRuntime(appState)
    }

    @Test func signOutOfOnlyAccountKeepsItAvailableForReactivation() async throws {
        let sweeps = ControlledSleeper()
        let seeded = try await readyAppStateWithCreatedIdentities(sweepSleeper: sweeps)
        let appState = seeded.appState
        let only = seeded.accounts[0]
        appState.activeAccountRef = only.label
        appState.profileStore.profileProjectionCache = [
            hex("aa"): ProfileDisplayProjection(profile: nil, projectedName: "Previous peer", localAccountLabel: nil)
        ]
        appState.profileStore.profileProjectionLoadVersions = [hex("aa"): 9]

        try await eventually { sweeps.sleepingCount == 1 }
        let cancelledSweeps = sweeps.cancelledCount
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
        try await eventually { sweeps.cancelledCount == cancelledSweeps + 1 }
        #expect(sweeps.sleepingCount == 0)

        await appState.activateAccount(only.label)

        #expect(appState.activeAccountRef == only.label)
        #expect(appState.accounts.first?.signedOut == false)
        // Reactivation must restart the maintenance the sign-out stopped;
        // nothing else (foreground resume, relaunch) heals it this session.
        #expect(appState.notificationSubscriptionActive)
        try await eventually { sweeps.sleepingCount == 1 }
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
        relayUrls: [String] = MarmotClient.unreachableTestRelays,
        catchUp: NotificationCatchUpStub? = nil,
        timings: HostPerformanceRecorderStub? = nil,
        sweepSleeper: ControlledSleeper? = nil,
        refreshReads: AccountRefreshReadsStub? = nil,
        mutationDrainSleeper: @escaping RuntimeLifecycle.RetrySleeper = RuntimeLifecycle.defaultRetrySleeper
    ) throws -> AppState {
        resetPersistedActiveAccountRef()
        return try ownedAppState(
            client: try ownedTestClient(relayUrls: relayUrls),
            notifications: notifications ?? deniedNotifications(),
            accountDefaults: accountDefaults,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig ?? TelemetryBuildConfig.current(),
            mutationDrainSleeper: mutationDrainSleeper,
            notificationCatchUpCalls: catchUp?.calls ?? .live,
            hostPerformanceRecorder: timings?.recorder ?? RuntimeLifecycle.recordHostPerformanceOnClient,
            retentionSweepSleep: sweepSleeper.map { sleeper in { try await sleeper.sleep(.nanoseconds($0)) } }
                ?? MessageRetentionSweeper.taskSleep,
            accountRefreshReads: refreshReads?.reads ?? .live
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
        signUpDraftStore: SignUpDraftStore? = nil,
        erasureDefaults: UserDefaults? = nil,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = TelemetryBuildConfig.current(),
        runtimeClientFactory: @escaping RuntimeLifecycle.RuntimeClientFactory =
            RuntimeLifecycle.defaultRuntimeClientFactory,
        runtimeCloser: @escaping RuntimeLifecycle.RuntimeCloser = RuntimeLifecycle.defaultRuntimeCloser,
        runtimeRetrySleeper: @escaping RuntimeLifecycle.RetrySleeper = AppStateTestResources.immediateRetry,
        runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground,
        mutationDrainSleeper: @escaping RuntimeLifecycle.RetrySleeper = RuntimeLifecycle.defaultRetrySleeper,
        notificationCatchUpCalls: NotificationCatchUpCalls = .live,
        hostPerformanceRecorder: @escaping RuntimeLifecycle.HostPerformanceRecorder =
            RuntimeLifecycle.recordHostPerformanceOnClient,
        retentionSweepSleep: @escaping MessageRetentionSweeper.Sleep = MessageRetentionSweeper.taskSleep,
        accountRefreshReads: AccountRefreshReads = .live
    ) throws -> AppState {
        try TestRuntimeScope.own(AppState.test(
            client: client,
            notifications: notifications,
            signUpDraftStore: signUpDraftStore,
            accountDefaults: accountDefaults,
            erasureDefaults: erasureDefaults,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig,
            runtimeClientFactory: runtimeClientFactory,
            runtimeCloser: runtimeCloser,
            runtimeRetrySleeper: runtimeRetrySleeper,
            runtimeConstructionRetryPolicy: runtimeConstructionRetryPolicy,
            mutationDrainSleeper: mutationDrainSleeper,
            notificationCatchUpCalls: notificationCatchUpCalls,
            hostPerformanceRecorder: hostPerformanceRecorder,
            retentionSweepSleep: retentionSweepSleep,
            accountRefreshReads: accountRefreshReads
        ))
    }

    /// Seeds a single generated identity against unreachable relays. MDK
    /// coalesces generated-identity calls until the previous account has
    /// published, so a second activated account would need a real relay —
    /// which unit tests must never contact.
    private func readyAppStateWithCreatedIdentities(
        notifications: AppNotifications? = nil,
        catchUp: NotificationCatchUpStub? = nil,
        timings: HostPerformanceRecorderStub? = nil,
        sweepSleeper: ControlledSleeper? = nil,
        refreshReads: AccountRefreshReadsStub? = nil,
        mutationDrainSleeper: @escaping RuntimeLifecycle.RetrySleeper = RuntimeLifecycle.defaultRetrySleeper
    ) async throws -> (appState: AppState, accounts: [AccountSummaryFfi]) {
        let appState = try testAppState(
            notifications: notifications, catchUp: catchUp, timings: timings, sweepSleeper: sweepSleeper,
            refreshReads: refreshReads, mutationDrainSleeper: mutationDrainSleeper
        )
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
