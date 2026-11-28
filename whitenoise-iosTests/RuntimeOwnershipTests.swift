import Foundation
import SwiftUI
import Synchronization
import Testing
import UserNotifications
@testable import MarmotKit
@testable import whitenoise_ios

private actor ScriptedRuntimeFactory {
    private var failures: [MarmotKitError]
    private var runtimeBusyFailuresRemaining: Int
    private var attempts = 0
    private var constructionsInFlight = 0
    private var maximumConstructionsInFlight = 0

    init(busyFailures: Int) {
        failures = []
        runtimeBusyFailuresRemaining = busyFailures
    }

    init(failures: [MarmotKitError]) {
        self.failures = failures
        runtimeBusyFailuresRemaining = 0
    }

    func allowNextConstructionToSucceed() {
        failures.removeAll()
        runtimeBusyFailuresRemaining = 0
    }

    func make(
        rootPath: String,
        relayUrls: [String],
        cursorPersistence: CursorPersistenceFfi,
        telemetryConfig: TelemetryBuildConfig
    ) async throws -> MarmotClient {
        attempts += 1
        constructionsInFlight += 1
        maximumConstructionsInFlight = max(
            maximumConstructionsInFlight,
            constructionsInFlight
        )
        defer { constructionsInFlight -= 1 }

        if !failures.isEmpty {
            throw failures.removeFirst()
        }
        if runtimeBusyFailuresRemaining > 0 {
            runtimeBusyFailuresRemaining -= 1
            throw MarmotKitError.RuntimeBusy
        }
        return try TestRuntimeScope.own(MarmotClient.testClient(), ownsRoot: true)
    }

    func snapshot() -> (attempts: Int, maximumInFlight: Int) {
        (attempts, maximumConstructionsInFlight)
    }
}

@MainActor
private func runtimeOwnershipDeniedNotifications() -> AppNotifications {
    AppNotifications(
        requestAuthorizationHandler: { false },
        authorizationStatusProvider: { .denied },
        remoteNotificationRegistrar: {}
    )
}

private actor RuntimeRetryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private let entered = TestLatch()

    func sleep(_: Duration) async throws {
        entered.signal()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.release() }
        }
        try Task.checkCancellation()
    }

    func waitUntilEntered() async throws {
        try await entered.wait()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite(.serialized, .marmotRuntimeConcurrencyLimit, .closesTestRuntimes)
struct RuntimeOwnershipTests {
    // The native cancellation test for MarmotKit's generated
    // PresentedChatListSubscription.nextCancellable() (AGENTS.md, Rust Bindings):
    // keep it and run it on every binding refresh.
    @Test func publishedPresentationSubscriptionCancelsWithoutAnotherEvent() async throws {
        try await withTestClient { client in
            try await client.startRuntime()
            let creation = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            )
            let account = creation.account
            let subscription = try await client.openPresentedChatList(accountRef: account.label, includeArchived: true)
            let initial = await client.presentedChatListSubscriptionSnapshot(subscription)
            #expect(initial?.sequence == 0)
            #expect(await client.presentedChatListSubscriptionSnapshot(subscription) == nil)
            let watchdog = MarmotFixtureWatchdog.start(
                "Cancellation required a runtime shutdown to unblock", breaking: client)
            defer { watchdog.cancel() }
            for _ in 0..<16 {
                let reader = Task.detached { try await subscription.nextCancellable() }
                await Task.yield()
                reader.cancel()
                do {
                    _ = try await reader.value
                    Issue.record("Expected task cancellation to reach the native future")
                } catch is CancellationError {
                    // This completes before any new chat-list event or shutdown.
                }
            }
            // Cancelling one next call leaves the handle usable for a later read.
            let reader = Task<PresentedChatListUpdateFfi?, Error>.detached {
                while let update = try await subscription.nextCancellable() {
                    if !update.snapshot.rows.isEmpty { return update }
                }
                return nil as PresentedChatListUpdateFfi?
            }
            let created = try await client.createGroupWithOptionsDetailed(
                accountRef: account.label, name: "Selected presentation", memberRefs: [],
                options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0)
            ).requireCreated()
            let update = try #require(try await reader.value)
            #expect(update.subscriptionGeneration == initial?.subscriptionGeneration)
            #expect(update.sequence > 0)
            #expect(update.snapshot.rows.contains { $0.row.groupIdHex == created.groupIdHex })
            let recovery = try await client.groupRecoveryStatus(accountRef: account.label, groupIdHex: created.groupIdHex)
            #expect(!recovery.automaticRecoveryFailed && recovery.rejoinInvitations.isEmpty)
            #expect(try await !client.onboardingRecoveryRequired(accountRef: account.label))
            try await client.marmot.shutdownAndClose()
            #expect(client.marmot.storageIsClosed())
        }
    }

    @Test func inactiveLaunchBootstrapsWithoutTreatingInactiveAsCancellation() async throws {
        let factory = ScriptedRuntimeFactory(busyFailures: 0)
        let appState = AppState.test(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            }
        )
        appState.setAppSceneActive(false)

        await appState.bootstrap()

        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
        let inactiveSnapshot = await factory.snapshot()
        #expect(inactiveSnapshot.attempts == 1)

        await appState.startRuntimeSuspension().value
    }

    @Test func coldBackgroundLaunchClosesRuntimeAfterBootstrap() async throws {
        var injectedClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(injectedClient?.marmot)
        weak let releasedClient = injectedClient
        let appState = AppState.test(
            client: injectedClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        injectedClient = nil

        let suspension = appState.startRuntimeSuspension()
        await appState.bootstrap()
        await suspension.value

        #expect(appState.phase == .onboarding)
        #expect(appState.client == nil)
        #expect(releasedClient == nil)
        #expect(marmot.storageIsClosed())
    }

    @Test func bootstrapRetriesRuntimeBusySeriallyAndInstallsOneClient() async throws {
        let factory = ScriptedRuntimeFactory(busyFailures: 2)
        let appState = AppState.test(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(
                delays: [.zero, .zero, .zero]
            )
        )
        appState.setAppSceneActive(true)

        async let first: Void = appState.bootstrap()
        async let second: Void = appState.bootstrap()
        await first
        await second

        let snapshot = await factory.snapshot()
        #expect(snapshot.attempts == 3)
        #expect(snapshot.maximumInFlight == 1)
        #expect(appState.client != nil)
        #expect(appState.phase == .onboarding)
    }

    @Test func bootstrapRetriesTransientStorageAndKeystoreReadiness() async throws {
        let factory = ScriptedRuntimeFactory(failures: [
            .StorageBusy(details: "database is locked"),
            .KeystoreUnavailable(details: "protected data unavailable"),
        ])
        let appState = AppState.test(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(
                delays: [.zero, .zero]
            )
        )
        appState.setAppSceneActive(true)

        await appState.bootstrap()

        let snapshot = await factory.snapshot()
        #expect(snapshot.attempts == 3)
        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
    }

    @Test func bootstrapStopsRetryingWhenAppBackgrounds() async throws {
        let factory = ScriptedRuntimeFactory(busyFailures: .max)
        let retryGate = RuntimeRetryGate()
        let appState = AppState.test(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeRetrySleeper: retryGate.sleep,
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(
                delays: [.seconds(10), .seconds(10)]
            )
        )
        appState.setAppSceneActive(true)
        let bootstrap = Task { await appState.bootstrap() }
        try await retryGate.waitUntilEntered()

        appState.setAppSceneActive(false)
        await retryGate.release()
        await bootstrap.value

        let snapshot = await factory.snapshot()
        #expect(snapshot.attempts == 1)
        #expect(appState.client == nil)
        #expect(appState.phase == .bootstrapping)
    }

    @Test func exhaustedContentionIsRecoverableAndASecondBootstrapCanSucceed() async throws {
        let factory = ScriptedRuntimeFactory(busyFailures: 2)
        let appState = AppState.test(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(delays: [.zero])
        )
        appState.setAppSceneActive(true)

        await appState.bootstrap()

        guard case .failed(let message) = appState.phase else {
            Issue.record("Expected recoverable startup failure")
            return
        }
        #expect(message.contains("secure background operation"))
        #expect(!message.localizedCaseInsensitiveContains("database"))
        #expect(appState.client == nil)

        await factory.allowNextConstructionToSucceed()
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
    }

    @Test func backgroundSuspensionDropsTheFinalClientReference() async throws {
        var injectedClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(injectedClient?.marmot)
        weak let releasedClient = injectedClient
        let appState = AppState.test(
            client: injectedClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        injectedClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        await appState.startRuntimeSuspension().value

        #expect(appState.client == nil)
        #expect(releasedClient == nil)
        #expect(marmot.storageIsClosed())
    }

    @Test func suspensionCancelsAndDrainsOwnedMutationFollowup() async throws {
        // A new identity asks for notification permission in a follow-up that
        // holds the runtime; keep that prompt open across the suspension.
        let promptStarted = TestLatch()
        let promptAnswered = TestLatch()
        let promptCancelled = TestLatch()
        let notifications = AppNotifications(
            requestAuthorizationHandler: {
                promptStarted.signal()
                try await withTaskCancellationHandler {
                    try await promptAnswered.wait()
                } onCancel: {
                    promptCancelled.signal()
                    promptAnswered.signal()
                }
                try Task.checkCancellation()
                return true
            },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {}
        )
        var injectedClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(injectedClient?.marmot)
        let appState = AppState.test(
            client: injectedClient,
            notifications: notifications,
            accountDefaults: IsolatedAccountDefaults.make()
        )
        injectedClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        try await promptStarted.wait()

        await appState.startRuntimeSuspension().value

        #expect(promptCancelled.isSignalled)
        #expect(appState.client == nil)
        #expect(marmot.storageIsClosed())
    }

    @Test func userInitiatedMutationJoinsForegroundRuntimeRebuild() async throws {
        let appState = try TestRuntimeScope.own(AppState.test(
            client: TestRuntimeScope.own(MarmotClient.testClient(), ownsRoot: true),
            notifications: runtimeOwnershipDeniedNotifications(),
            accountDefaults: IsolatedAccountDefaults.make()
        ))
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        await appState.startRuntimeSuspension().value

        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        let lease = try await appState.runtimeLifecycle.beginUserInitiatedForegroundRuntimeMutation()

        #expect(lease.client === appState.client)
        #expect(appState.client != nil)
        #expect(!appState.runtimeSuspendedForBackground)
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)

        await appState.startRuntimeSuspension().value
    }

    @Test func runtimeLeaseRejectsASecondOwnerUntilTheFinalHandleDrops() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var first: Marmot? = try Marmot.newWithCursorPersistence(
            rootPath: root.path,
            relayUrls: ["wss://relay.invalid.test"],
            cursorPersistence: .advance,
            deployment: marmotDeploymentWhiteNoise()
        )

        do {
            _ = try Marmot.newWithCursorPersistence(
                rootPath: root.path,
                relayUrls: ["wss://relay.invalid.test"],
                cursorPersistence: .frozen,
                deployment: marmotDeploymentWhiteNoise()
            )
            Issue.record("Expected the second runtime owner to be rejected")
        } catch let error as MarmotKitError {
            #expect(error.isRuntimeOwnershipContention)
        }

        try await first?.shutdownAndClose()
        first = nil

        let replacement = try Marmot.newWithCursorPersistence(
            rootPath: root.path,
            relayUrls: ["wss://relay.invalid.test"],
            cursorPersistence: .advance,
            deployment: marmotDeploymentWhiteNoise()
        )
        try await replacement.shutdownAndClose()
    }

    @Test func notificationActionContentionFailsImmediatelyAndReleasesSuspensionGate() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, _, _ in
                throw MarmotKitError.RuntimeBusy
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value

        do {
            _ = try await appState.runtimeLifecycle.startRuntimeForNotificationAction(actionID: UUID())
            Issue.record("Expected notification action contention to fall back")
        } catch let error as NotificationActionError {
            guard case .runtimeUnavailable = error else {
                Issue.record("Unexpected notification action error")
                return
            }
        }

        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
    }

    @Test func notificationActionRefusesToOpenStorageWithoutBackgroundAssertionOrBudget() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        var factoryCalls = 0
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, _, _ in
                factoryCalls += 1
                return try TestRuntimeScope.own(MarmotClient.testClient(), ownsRoot: true)
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value
        #expect(!appState.isAppSceneActive)

        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "budget-group",
            notificationKey: "budget-key",
            messageIdHex: "budget-msg"
        )
        var performCalls = 0

        // 1. UIKit refuses background assertion (`.invalid`) while backgrounded.
        await appState.runNotificationAction(
            route: route,
            failureTitle: "Action failed",
            backgroundTimeRemaining: { 30 },
            makeBackgroundTask: { name, onExpiration in
                BackgroundRuntimeSuspensionTask(
                    name: name,
                    onExpiration: onExpiration,
                    beginBackgroundTask: { _, _ in .invalid },
                    endBackgroundTask: { _ in }
                )
            },
            perform: { _, _ in performCalls += 1 }
        )

        // 2. Remaining background budget cannot fit teardown reserve + work.
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        let grantedTaskID = UIBackgroundTaskIdentifier(rawValue: 99)
        await appState.runNotificationAction(
            route: route,
            failureTitle: "Action failed",
            backgroundTimeRemaining: { 5 },
            makeBackgroundTask: { name, onExpiration in
                BackgroundRuntimeSuspensionTask(
                    name: name,
                    onExpiration: onExpiration,
                    beginBackgroundTask: { _, _ in grantedTaskID },
                    endBackgroundTask: { endedTaskIDs.append($0) }
                )
            },
            perform: { _, _ in performCalls += 1 }
        )

        #expect(factoryCalls == 0)
        #expect(performCalls == 0)
        #expect(endedTaskIDs == [grantedTaskID])
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        // 3. Cold UI-less launch (`!sceneHasReportedPhase`, optimistic
        //    `isAppSceneActive == true`) refuses when UIKit returns `.invalid`
        //    AND posts a local failure notification (not a windowless toast).
        var coldFactoryCalls = 0
        var scheduledFailureTitles: [String] = []
        let coldNotifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {},
            notificationRequestScheduler: { request in
                scheduledFailureTitles.append(request.content.title)
            }
        )
        let coldAppState = AppState.test(
            client: nil,
            notifications: coldNotifications,
            runtimeClientFactory: { _, _, _, _ in
                coldFactoryCalls += 1
                return try TestRuntimeScope.own(MarmotClient.testClient(), ownsRoot: true)
            }
        )
        #expect(!coldAppState.sceneHasReportedPhase)
        #expect(coldAppState.isAppSceneActive)
        await coldAppState.runNotificationAction(
            route: route,
            failureTitle: "Cold invalid assertion",
            backgroundTimeRemaining: { 30 },
            makeBackgroundTask: { name, onExpiration in
                BackgroundRuntimeSuspensionTask(
                    name: name,
                    onExpiration: onExpiration,
                    beginBackgroundTask: { _, _ in .invalid },
                    endBackgroundTask: { _ in }
                )
            },
            perform: { _, _ in performCalls += 1 }
        )
        #expect(coldFactoryCalls == 0)
        #expect(performCalls == 0)
        #expect(coldAppState.client == nil)
        #expect(scheduledFailureTitles == ["Cold invalid assertion"])
    }

    @Test func notificationActionPreLeaseExpirationDuringEphemeralStartClosesStorageAndReleasesGate() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let rootPath = try #require(initialClient?.rootPath)
        let relayUrls = try #require(initialClient?.relayUrls)
        let startCheckpoint = AsyncTestCheckpoint()
        var startedEphemeral: MarmotClient?
        var shouldPauseNextStart = false

        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootPath,
                        relayUrls: relayUrls,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
            },
            runtimeStarter: { client in
                if shouldPauseNextStart {
                    shouldPauseNextStart = false
                    startedEphemeral = client
                    await startCheckpoint.pause()
                    try Task.checkCancellation()
                }
                try await client.startRuntime()
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value

        shouldPauseNextStart = true
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "prelease-start-group",
            notificationKey: "prelease-start-key",
            messageIdHex: "prelease-start-msg"
        )
        let triggerDeadline = TestLatch()
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        let taskID = UIBackgroundTaskIdentifier(rawValue: 101)
        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Action expired",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await triggerDeadline.wait() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in taskID },
                        endBackgroundTask: { endedTaskIDs.append($0) }
                    )
                },
                perform: { _, _ in }
            )
        }
        await startCheckpoint.waitUntilPaused()
        let ephemeral = try #require(startedEphemeral)

        // Deadline expires while ephemeral `startRuntime()` is parked: storage
        // must close, the suspension gate must release, and the background task
        // must end without waiting on the stuck start.
        triggerDeadline.signal()
        await action.value
        #expect(ephemeral.marmot.storageIsClosed())
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(endedTaskIDs == [taskID])

        // Foreground activation must rebuild cleanly once the gate is released.
        await appState.startForegroundActivation().value
        #expect(appState.client != nil)
        #expect(!appState.runtimeSuspendedForBackground)

        await startCheckpoint.release()
        await appState.startRuntimeSuspension().value
    }

    @Test func notificationActionPreLeaseExpirationDuringConstructionClosesLateBuiltClient() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let rootPath = try #require(initialClient?.rootPath)
        let relayUrls = try #require(initialClient?.relayUrls)
        let factoryEntered = TestLatch()
        let factoryCancelled = TestLatch()
        let factoryRelease = TestLatch()
        var builtEphemeral: MarmotClient?
        var shouldPauseNextConstruction = false

        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                if shouldPauseNextConstruction {
                    shouldPauseNextConstruction = false
                    factoryEntered.signal()
                    await withTaskCancellationHandler {
                        try? await factoryRelease.wait()
                    } onCancel: {
                        factoryCancelled.signal()
                    }
                    let built = try TestRuntimeScope.own(
                        MarmotClient(
                            rootPath: rootPath,
                            relayUrls: relayUrls,
                            cursorPersistence: cursorPersistence,
                            telemetryConfig: telemetryConfig
                        ),
                        ownsRoot: false,
                        retainingClient: false
                    )
                    builtEphemeral = built
                    return built
                }
                return try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootPath,
                        relayUrls: relayUrls,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value

        shouldPauseNextConstruction = true
        let triggerDeadline = TestLatch()
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "prelease-construct-group",
            notificationKey: "prelease-construct-key",
            messageIdHex: "prelease-construct-msg"
        )
        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Action expired",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await triggerDeadline.wait() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 102) },
                        endBackgroundTask: { _ in }
                    )
                },
                perform: { _, _ in }
            )
        }
        try await factoryEntered.wait()

        // Fire the deadline while construction is paused, wait until expiration
        // cancels the construction task, then let construction return its
        // late-built client; expiration cleanup must close it before returning
        // and releasing the suspension gate.
        triggerDeadline.signal()
        try await factoryCancelled.wait()
        factoryRelease.signal()
        await action.value

        let lateClient = try #require(builtEphemeral)
        #expect(lateClient.marmot.storageIsClosed())
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
    }

    @Test func expiringQueuedNotificationActionDoesNotTearDownActiveActionLease() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        let liveMarmot = try #require(initialClient?.marmot)
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        let firstEntered = AsyncTestCheckpoint()
        var firstCompleted = false
        var secondPerformRan = false
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "queued-action-group",
            notificationKey: "queued-action-key",
            messageIdHex: "queued-action-msg"
        )

        let firstAction = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "First failed",
                deadline: .seconds(10)
            ) { _, _ in
                await firstEntered.pause()
                firstCompleted = true
            }
        }
        await firstEntered.waitUntilPaused()

        // Second action queues behind the first and expires immediately. Its
        // expiration is scoped to its own actionID and must leave the first
        // action's live runtime untouched.
        await appState.runNotificationAction(
            route: route,
            failureTitle: "Second expired",
            deadline: .seconds(20),
            deadlineSleeper: { _ in }
        ) { _, _ in
            secondPerformRan = true
        }

        #expect(!secondPerformRan)
        #expect(!liveMarmot.storageIsClosed())
        #expect(appState.client != nil)
        #expect(appState.runtimeLifecycle.isRuntimeSuspendingNow)

        await firstEntered.release()
        await firstAction.value
        #expect(firstCompleted)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(!liveMarmot.storageIsClosed())

        await appState.startRuntimeSuspension().value
    }

    @Test func coldLaunchNotificationActionUsesEphemeralFrozenRuntimeAndClosesOnExpiration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdEphemeralExpire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let startCheckpoint = AsyncTestCheckpoint()
        var shouldPauseStart = true
        var constructedModes: [CursorPersistenceFfi] = []
        var coldEphemeral: MarmotClient?

        let appState = AppState.test(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                constructedModes.append(cursorPersistence)
                let built = try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootURL.path,
                        relayUrls: MarmotClient.unreachableTestRelays,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
                if coldEphemeral == nil {
                    coldEphemeral = built
                }
                return built
            },
            runtimeStarter: { client in
                if shouldPauseStart {
                    shouldPauseStart = false
                    await startCheckpoint.pause()
                    try Task.checkCancellation()
                }
                try await client.startRuntime()
            }
        )
        #expect(appState.phase == .bootstrapping)
        #expect(!appState.sceneHasReportedPhase)

        let triggerDeadline = TestLatch()
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "cold-ephemeral-group",
            notificationKey: "cold-ephemeral-key",
            messageIdHex: "cold-ephemeral-msg"
        )
        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Cold action expired",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await triggerDeadline.wait() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 103) },
                        endBackgroundTask: { _ in }
                    )
                },
                perform: { _, _ in }
            )
        }
        await startCheckpoint.waitUntilPaused()
        triggerDeadline.signal()
        await action.value

        // Cold UI-less actions run on an ephemeral `.frozen` runtime without
        // mutating durable bootstrap state. Expiration closes SQLCipher and
        // leaves phase `.bootstrapping` so a foreground launch boots `.advance`.
        let expiredClient = try #require(coldEphemeral)
        #expect(expiredClient.marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.phase == .bootstrapping)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(constructedModes == [.frozen])

        await startCheckpoint.release()
        await appState.startForegroundActivation().value
        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
        #expect(appState.client?.cursorPersistence == .advance)
        #expect(constructedModes == [.frozen, .advance])

        await appState.startRuntimeSuspension().value
    }

    @Test func coldLaunchNotificationActionCompletesOnEphemeralFrozenRuntimeAndRefreshesUnreadBadge() async throws {
        // Seed one real account on disk and release the seed runtime.
        let seedClient = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let rootPath = seedClient.rootPath
        let relayUrls = seedClient.relayUrls
        let seedState = AppState.test(
            client: seedClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            accountDefaults: IsolatedAccountDefaults.make()
        )
        seedState.setAppSceneActive(true)
        await seedState.bootstrap()
        let account = try await seedState.createIdentity()
        await seedState.startRuntimeSuspension().value

        var recordedBadges: [Int] = []
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {},
            applicationBadgeCountSetter: { count in
                recordedBadges.append(count)
            }
        )
        var leasedClient: MarmotClient?
        let coldAppState = AppState.test(
            client: nil,
            notifications: notifications,
            accountDefaults: IsolatedAccountDefaults.make(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                let built = try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootPath,
                        relayUrls: relayUrls,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
                leasedClient = built
                return built
            }
        )
        #expect(coldAppState.phase == .bootstrapping)
        #expect(!coldAppState.sceneHasReportedPhase)
        #expect(coldAppState.accounts.isEmpty)

        var observedCursorMode: CursorPersistenceFfi?
        let route = LocalNotificationRoute(
            accountRef: account.label,
            groupIdHex: "cold-complete-group",
            notificationKey: "cold-complete-key",
            messageIdHex: "cold-complete-msg"
        )
        await coldAppState.runNotificationAction(
            route: route,
            failureTitle: "Cold action failed",
            deadline: .seconds(20),
            backgroundTimeRemaining: { 30 },
            makeBackgroundTask: { name, onExpiration in
                BackgroundRuntimeSuspensionTask(
                    name: name,
                    onExpiration: onExpiration,
                    beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 112) },
                    endBackgroundTask: { _ in }
                )
            }
        ) { client, markSucceeded in
            observedCursorMode = client.cursorPersistence
            markSucceeded()
            await coldAppState.refreshAccountUnreadSummaries(using: client)
        }

        let closedEphemeral = try #require(leasedClient)
        #expect(observedCursorMode == .frozen)
        #expect(closedEphemeral.marmot.storageIsClosed())
        #expect(coldAppState.phase == .bootstrapping)
        #expect(coldAppState.client == nil)
        #expect(!coldAppState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(recordedBadges == [0])
        #expect(coldAppState.accountUnreadSummary(forAccountIdHex: account.accountIdHex) != nil)
    }

    @Test func coldLaunchNotificationActionExpirationDuringPostLeaseSuspensionAwaitsStorageClose() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(initialClient?.marmot)
        let drainEntered = TestLatch()
        let drainRelease = TestLatch()
        var scheduledFailureTitles: [String] = []
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {},
            notificationRequestScheduler: { request in
                scheduledFailureTitles.append(request.content.title)
            }
        )
        let appState = AppState.test(
            client: initialClient,
            notifications: notifications,
            mutationDrainSleeper: { _ in
                drainEntered.signal()
                try? await drainRelease.wait()
            }
        )
        initialClient = nil
        await appState.bootstrap()
        #expect(!appState.sceneHasReportedPhase)
        #expect(appState.client != nil)

        // Hold a mutation lease so cold post-lease `startRuntimeSuspension()`
        // pauses inside its pre-close drain while the action deadline fires.
        let mutationLease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        let taskID = UIBackgroundTaskIdentifier(rawValue: 104)
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "cold-teardown-group",
            notificationKey: "cold-teardown-key",
            messageIdHex: "cold-teardown-msg"
        )

        let triggerDeadline = TestLatch()
        let deadlineFired = TestLatch()
        var actionFinished = false
        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Cold teardown expired",
                deadline: .seconds(20),
                deadlineSleeper: { _ in
                    try await triggerDeadline.wait()
                    deadlineFired.signal()
                },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in taskID },
                        endBackgroundTask: { endedTaskIDs.append($0) }
                    )
                },
                perform: { _, _ in }
            )
            actionFinished = true
        }

        // Wait until `perform` finished and cold post-lease suspension entered
        // pre-close drain, then fire the deadline deterministically.
        try await drainEntered.wait()
        triggerDeadline.signal()
        try await deadlineFired.wait()
        await Task.yield()

        // Expiration must keep waiting on the cold teardown task — and keep the
        // UIKit background assertion active — until SQLCipher finishes closing.
        #expect(!actionFinished)
        #expect(endedTaskIDs.isEmpty)
        #expect(!marmot.storageIsClosed())

        appState.runtimeLifecycle.endForegroundRuntimeMutation(mutationLease)
        drainRelease.signal()
        await action.value

        #expect(actionFinished)
        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(endedTaskIDs == [taskID])
        // The operation itself succeeded before teardown; expiring during cold
        // post-lease storage close must NOT falsely present "Reply not sent".
        #expect(scheduledFailureTitles.isEmpty)
        #expect(appState.toastState.activeToast == nil)
    }

    @Test func notificationActionUIKitExpirationCallbackClosesStorageAndEndsAssertionOnce() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let rootPath = try #require(initialClient?.rootPath)
        let relayUrls = try #require(initialClient?.relayUrls)
        var leasedEphemeral: MarmotClient?
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                let built = try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootPath,
                        relayUrls: relayUrls,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
                leasedEphemeral = built
                return built
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value

        let performPaused = AsyncTestCheckpoint()
        var capturedUIKitExpiration: (() -> Void)?
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        let taskID = UIBackgroundTaskIdentifier(rawValue: 105)
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "uikit-expire-group",
            notificationKey: "uikit-expire-key",
            messageIdHex: "uikit-expire-msg"
        )

        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Expired by UIKit",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await parkUntilCancelled() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, expirationHandler in
                            capturedUIKitExpiration = expirationHandler
                            return taskID
                        },
                        endBackgroundTask: { endedTaskIDs.append($0) }
                    )
                },
                perform: { _, _ in
                    await performPaused.pause()
                    try Task.checkCancellation()
                }
            )
        }
        await performPaused.waitUntilPaused()
        let ephemeral = try #require(leasedEphemeral)
        let fireUIKitExpiration = try #require(capturedUIKitExpiration)

        // Fire UIKit's background expiration callback while backgrounded:
        // BackgroundRuntimeSuspensionTask ends `taskID` promptly once, and
        // expiration closes SQLCipher and releases the suspension gate without
        // waiting on the stuck `perform`.
        fireUIKitExpiration()
        await action.value

        #expect(endedTaskIDs == [taskID])
        #expect(ephemeral.marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)

        await performPaused.release()
    }

    @Test func foregroundNotificationActionExpiresProactivelyWhenBackgroundedWithInsufficientReserve() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(initialClient?.marmot)
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        let performPaused = AsyncTestCheckpoint()
        var simulatedRemaining: TimeInterval = .greatestFiniteMagnitude
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        let taskID = UIBackgroundTaskIdentifier(rawValue: 106)
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "fg-to-bg-group",
            notificationKey: "fg-to-bg-key",
            messageIdHex: "fg-to-bg-msg"
        )

        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Tightened on background",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await parkUntilCancelled() },
                backgroundTimeRemaining: { simulatedRemaining },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in taskID },
                        endBackgroundTask: { endedTaskIDs.append($0) }
                    )
                },
                perform: { _, _ in
                    await performPaused.pause()
                    try Task.checkCancellation()
                }
            )
        }
        await performPaused.waitUntilPaused()

        // The user backgrounds the app while UIKit reports less time remaining
        // than `storageCloseReserveSeconds + minimumWorkSeconds`. Background
        // entry must proactively expire the in-flight action and close SQLCipher
        // rather than keeping the foreground's 20-second deadline.
        simulatedRemaining = NotificationActionBackgroundBudget.storageCloseReserveSeconds - 1
        let suspension = appState.startRuntimeSuspension()
        await action.value
        await suspension.value

        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(endedTaskIDs == [taskID])

        await performPaused.release()
    }

    @Test func foregroundBootstrapWaitsForExpiredColdLaunchCloseBarrierBeforeConstructingRuntime() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdCloseBarrier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstConstructEntered = TestLatch()
        let firstConstructCancelled = TestLatch()
        let firstConstructRelease = TestLatch()
        let triggerDeadline = TestLatch()
        var constructionModes: [CursorPersistenceFfi] = []
        var lateFirstClient: MarmotClient?

        let appState = AppState.test(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                constructionModes.append(cursorPersistence)
                if constructionModes.count == 1 {
                    firstConstructEntered.signal()
                    await withTaskCancellationHandler {
                        try? await firstConstructRelease.wait()
                    } onCancel: {
                        firstConstructCancelled.signal()
                    }
                    let built = try TestRuntimeScope.own(
                        MarmotClient(
                            rootPath: rootURL.path,
                            relayUrls: MarmotClient.unreachableTestRelays,
                            cursorPersistence: cursorPersistence,
                            telemetryConfig: telemetryConfig
                        ),
                        ownsRoot: false,
                        retainingClient: false
                    )
                    lateFirstClient = built
                    return built
                }
                return try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootURL.path,
                        relayUrls: MarmotClient.unreachableTestRelays,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
            }
        )
        #expect(appState.phase == .bootstrapping)
        #expect(!appState.sceneHasReportedPhase)

        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "barrier-group",
            notificationKey: "barrier-key",
            messageIdHex: "barrier-msg"
        )
        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Cold barrier expired",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await triggerDeadline.wait() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 107) },
                        endBackgroundTask: { _ in }
                    )
                },
                perform: { _, _ in }
            )
        }
        try await firstConstructEntered.wait()

        // Expire the cold-launch action while construction #1 is still parked.
        triggerDeadline.signal()
        try await firstConstructCancelled.wait()

        // The user opens the app while the expired cold-launch constructor is
        // still draining. Foreground activation must wait on the close barrier
        // instead of racing a second Marmot construction over the same root.
        let activation = appState.startForegroundActivation()
        await Task.yield()
        #expect(constructionModes == [.frozen])

        firstConstructRelease.signal()
        await action.value
        await activation.value

        let closedFirst = try #require(lateFirstClient)
        #expect(closedFirst.marmot.storageIsClosed())
        #expect(constructionModes == [.frozen, .advance])
        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
        #expect(appState.client?.cursorPersistence == .advance)

        await appState.startRuntimeSuspension().value
    }

    @Test func coldActionTeardownDoesNotDeadlockOnForegroundActivationAndReBackgroundDuringClose() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(initialClient?.marmot)
        let drainEntered = TestLatch()
        let drainRelease = TestLatch()
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            mutationDrainSleeper: { _ in
                drainEntered.signal()
                try? await drainRelease.wait()
            }
        )
        initialClient = nil
        await appState.bootstrap()
        #expect(!appState.sceneHasReportedPhase)

        let mutationLease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "cold-rebg-group",
            notificationKey: "cold-rebg-key",
            messageIdHex: "cold-rebg-msg"
        )
        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Cold re-bg failed",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await parkUntilCancelled() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 108) },
                        endBackgroundTask: { _ in }
                    )
                },
                perform: { _, _ in }
            )
        }

        try await drainEntered.wait()

        // User activates foreground while cold post-lease teardown is paused,
        // then immediately re-backgrounds before storage close finishes. Neither
        // `foregroundActivationTask` nor `drainPendingMaintenanceDrains` may
        // form a deadlock cycle with `notificationActionReleaseTask`.
        let activation = appState.startForegroundActivation()
        await Task.yield()
        let suspension = appState.startRuntimeSuspension()

        appState.runtimeLifecycle.endForegroundRuntimeMutation(mutationLease)
        drainRelease.signal()

        await action.value
        await activation.value
        await suspension.value

        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
    }

    @Test func coldLaunchActionDeadlineIsNeverExtendedByPermissiveBackgroundEntry() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        initialClient = nil
        await appState.bootstrap()
        #expect(!appState.sceneHasReportedPhase)

        let cap = NotificationActionBackgroundBudget.coldLaunchMaximumWorkSeconds
        let requested: Duration = .seconds(cap + 5)
        let recordedDeadlines = Mutex<[Duration]>([])
        let firstDeadlineRegistered = TestLatch()
        let performPaused = AsyncTestCheckpoint()
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "cold-monotonic-group",
            notificationKey: "cold-monotonic-key",
            messageIdHex: "cold-monotonic-msg"
        )

        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Cold monotonic failed",
                deadline: requested,
                deadlineSleeper: { duration in
                    recordedDeadlines.withLock { $0.append(duration) }
                    firstDeadlineRegistered.signal()
                    try await parkUntilCancelled()
                },
                backgroundTimeRemaining: { .greatestFiniteMagnitude },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 109) },
                        endBackgroundTask: { _ in }
                    )
                },
                perform: { _, _ in
                    await performPaused.pause()
                }
            )
        }
        await performPaused.waitUntilPaused()
        try await firstDeadlineRegistered.wait()

        // Background entry with a permissive `.greatestFiniteMagnitude`
        // reading must keep the tighter cold-launch cap rather than extending
        // it back up to `requested`.
        let suspension = appState.startRuntimeSuspension()

        await performPaused.release()
        await action.value
        await suspension.value

        let deadlines = recordedDeadlines.withLock { $0 }
        #expect(deadlines.count == 1)
        let firstDeadline = try #require(deadlines.first)
        #expect(firstDeadline <= .seconds(cap))
        #expect(firstDeadline < requested)
    }

    @Test func notificationActionExpirationDuringPostMutationFollowUpDoesNotReportFailure() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let rootPath = try #require(initialClient?.rootPath)
        let relayUrls = try #require(initialClient?.relayUrls)
        var leasedEphemeral: MarmotClient?
        var scheduledFailureTitles: [String] = []
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {},
            notificationRequestScheduler: { request in
                scheduledFailureTitles.append(request.content.title)
            }
        )
        let appState = AppState.test(
            client: initialClient,
            notifications: notifications,
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                let built = try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootPath,
                        relayUrls: relayUrls,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
                leasedEphemeral = built
                return built
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value

        let followUpPaused = AsyncTestCheckpoint()
        let triggerDeadline = TestLatch()
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "post-mutation-group",
            notificationKey: "post-mutation-key",
            messageIdHex: "post-mutation-msg"
        )

        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Reply not sent",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await triggerDeadline.wait() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 110) },
                        endBackgroundTask: { _ in }
                    )
                }
            ) { _, markSucceeded in
                markSucceeded()
                await followUpPaused.pause()
                try Task.checkCancellation()
            }
        }

        await followUpPaused.waitUntilPaused()
        triggerDeadline.signal()
        await action.value

        let ephemeral = try #require(leasedEphemeral)
        #expect(ephemeral.marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(scheduledFailureTitles.isEmpty)
        #expect(appState.toastState.activeToast == nil)

        await followUpPaused.release()
    }

    @Test func foregroundActionBackgroundedHoldsAssertionUntilSceneSuspensionClosesStorage() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(initialClient?.marmot)
        let drainEntered = TestLatch()
        let drainRelease = TestLatch()
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            mutationDrainSleeper: { _ in
                drainEntered.signal()
                try? await drainRelease.wait()
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        // Hold a mutation lease so scene suspension pauses before closing SQLCipher.
        let mutationLease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        let performPaused = AsyncTestCheckpoint()
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        let actionTaskID = UIBackgroundTaskIdentifier(rawValue: 111)
        var actionFinished = false
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "scene-handoff-group",
            notificationKey: "scene-handoff-key",
            messageIdHex: "scene-handoff-msg"
        )

        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Scene handoff failed",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await parkUntilCancelled() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in actionTaskID },
                        endBackgroundTask: { endedTaskIDs.append($0) }
                    )
                }
            ) { _, _ in
                await performPaused.pause()
            }
            actionFinished = true
        }
        await performPaused.waitUntilPaused()

        // User backgrounds the app while the action holds the live client
        // lease. Even without a separate scene background assertion, the
        // action must keep its own assertion active until scene suspension
        // finishes closing SQLCipher.
        let suspension = appState.startRuntimeSuspension()

        await performPaused.release()
        try await drainEntered.wait()
        await Task.yield()

        #expect(!actionFinished)
        #expect(endedTaskIDs.isEmpty)
        #expect(!marmot.storageIsClosed())

        appState.runtimeLifecycle.endForegroundRuntimeMutation(mutationLease)
        drainRelease.signal()
        await action.value
        await suspension.value

        #expect(actionFinished)
        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(endedTaskIDs == [actionTaskID])
    }

    @Test func appNotificationsColdLaunchDispatchesBackgroundActionsImmediatelyWhileBufferingOpenChat() async throws {
        // Seed one account and one group on disk so a cold UI-less reply action
        // executes end-to-end through `AppNotifications.dispatchActionResponse`.
        let seedClient = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let rootPath = seedClient.rootPath
        let relayUrls = seedClient.relayUrls
        let seedState = AppState.test(
            client: seedClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            accountDefaults: IsolatedAccountDefaults.make()
        )
        seedState.setAppSceneActive(true)
        await seedState.bootstrap()
        let account = try await seedState.createIdentity()
        let created = try await seedClient.createGroupWithOptionsDetailed(
            accountRef: account.label,
            name: "Cold launch reply",
            memberRefs: [],
            options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0)
        ).requireCreated()
        await seedState.startRuntimeSuspension().value

        var scheduledFailureTitles: [String] = []
        let removedDeliveredIDs = Mutex<[[String]]>([])
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {},
            deliveredNotificationIdentifiersRemover: { ids in
                removedDeliveredIDs.withLock { $0.append(ids) }
            },
            notificationRequestScheduler: { request in
                scheduledFailureTitles.append(request.content.title)
            }
        )
        var constructedModes: [CursorPersistenceFfi] = []
        var ephemeralClients: [MarmotClient] = []
        let coldAppState = AppState.test(
            client: nil,
            notifications: notifications,
            accountDefaults: IsolatedAccountDefaults.make(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                constructedModes.append(cursorPersistence)
                let built = try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootPath,
                        relayUrls: relayUrls,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
                if cursorPersistence == .frozen {
                    ephemeralClients.append(built)
                }
                return built
            }
        )
        // Mirror `whitenoise_iosApp.init()` wiring before any scene phase or bootstrap.
        notifications.configure(appState: coldAppState)
        #expect(coldAppState.phase == .bootstrapping)
        #expect(!coldAppState.sceneHasReportedPhase)

        let route = LocalNotificationRoute(
            accountRef: account.label,
            groupIdHex: created.groupIdHex,
            notificationKey: "cold-delegate-key",
            messageIdHex: nil
        )

        // 1. A notification tap before bootstrap must stay buffered rather than
        //    being dropped against the empty account list.
        await notifications.dispatchActionResponse(.openChat(route))
        #expect(coldAppState.pendingChatId == nil)

        // 2. A rejected reply (and any background action) dispatches immediately
        //    through the delegate path before any scene phase or bootstrap.
        await notifications.dispatchActionResponse(.rejectedReply(route))
        #expect(scheduledFailureTitles.count == 1)
        #expect(constructedModes.isEmpty)

        // 3. A reply action dispatches immediately on a cold UI-less launch via
        //    the ephemeral `.frozen` runtime and closes SQLCipher on return.
        scheduledFailureTitles.removeAll()
        await notifications.dispatchActionResponse(.reply(route, text: "hello from cold launch"))
        await notifications.drainNotificationCenterMutations()
        let ephemeral = try #require(ephemeralClients.first)
        #expect(constructedModes == [.frozen])
        #expect(ephemeral.marmot.storageIsClosed())
        #expect(coldAppState.phase == .bootstrapping)
        #expect(coldAppState.client == nil)
        #expect(scheduledFailureTitles.isEmpty)
        #expect(removedDeliveredIDs.withLock { $0 }.contains(["cold-delegate-key"]))

        // 4. Later foreground bootstrap flushes the buffered `.openChat` route
        //    once `.ready` wires `configureNotifications()`.
        coldAppState.setAppSceneActive(true)
        await coldAppState.bootstrap()
        #expect(coldAppState.phase == .ready)
        #expect(coldAppState.pendingChatId == created.groupIdHex)
        #expect(coldAppState.client?.cursorPersistence == .advance)
        #expect(constructedModes == [.frozen, .advance])

        await coldAppState.startRuntimeSuspension().value
    }

    @Test func foregroundActionWithInvalidAssertionExpiresImmediatelyOnBackgroundEntry() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(initialClient?.marmot)
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        let performPaused = AsyncTestCheckpoint()
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "invalid-assertion-bg-group",
            notificationKey: "invalid-assertion-bg-key",
            messageIdHex: "invalid-assertion-bg-msg"
        )

        let action = Task { @MainActor in
            await appState.runNotificationAction(
                route: route,
                failureTitle: "No assertion on background",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await parkUntilCancelled() },
                backgroundTimeRemaining: { .greatestFiniteMagnitude },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in .invalid },
                        endBackgroundTask: { _ in }
                    )
                },
                perform: { _, _ in
                    await performPaused.pause()
                    try Task.checkCancellation()
                }
            )
        }
        await performPaused.waitUntilPaused()

        // The action started in foreground (where `.invalid` assertion is allowed).
        // Entering `.background` with an invalid assertion must expire it
        // immediately even when `backgroundTimeRemaining` is permissive.
        let suspension = appState.startRuntimeSuspension()
        await action.value
        await suspension.value

        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)

        await performPaused.release()
    }

    @Test func foregroundActionBackgroundedEndsAssertionOnceStorageClosesEvenWhilePostCloseDrainIsParked() async throws {
        var initialClient: MarmotClient? = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let marmot = try #require(initialClient?.marmot)
        // Return immediately from `mutationDrainSleeper` so the 2 s pre-close
        // wait times out immediately and proceeds to terminal SQLCipher close,
        // while `drainForegroundMaintenance` remains parked on the held lease.
        let appState = AppState.test(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            mutationDrainSleeper: { _ in }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        let mutationLease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        var releasedMutationLease = false
        func releaseMutationLeaseIfNeeded() {
            guard !releasedMutationLease else { return }
            releasedMutationLease = true
            appState.runtimeLifecycle.endForegroundRuntimeMutation(mutationLease)
        }
        defer { releaseMutationLeaseIfNeeded() }
        let performPaused = AsyncTestCheckpoint()
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        let actionTaskID = UIBackgroundTaskIdentifier(rawValue: 113)
        let actionFinished = TestLatch()
        let route = LocalNotificationRoute(
            accountRef: "test-account",
            groupIdHex: "post-close-drain-group",
            notificationKey: "post-close-drain-key",
            messageIdHex: "post-close-drain-msg"
        )

        let action = Task { @MainActor in
            defer { actionFinished.signal() }
            await appState.runNotificationAction(
                route: route,
                failureTitle: "Post-close drain failed",
                deadline: .seconds(20),
                deadlineSleeper: { _ in try await parkUntilCancelled() },
                backgroundTimeRemaining: { 30 },
                makeBackgroundTask: { name, onExpiration in
                    BackgroundRuntimeSuspensionTask(
                        name: name,
                        onExpiration: onExpiration,
                        beginBackgroundTask: { _, _ in actionTaskID },
                        endBackgroundTask: { endedTaskIDs.append($0) }
                    )
                }
            ) { _, _ in
                await performPaused.pause()
            }
        }
        await performPaused.waitUntilPaused()

        var suspensionFinished = false
        let suspension = Task { @MainActor in
            await appState.startRuntimeSuspension().value
            suspensionFinished = true
        }
        await performPaused.release()

        // Action must finish and end its UIKit assertion as soon as SQLCipher
        // closes, without blocking on the unrelated mutation lease parked in
        // post-close `drainForegroundMaintenance`. Use a bounded latch so a
        // regression fails instead of hanging.
        try await actionFinished.wait()
        await action.value
        #expect(marmot.storageIsClosed())
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
        #expect(endedTaskIDs == [actionTaskID])
        #expect(!suspensionFinished)

        releaseMutationLeaseIfNeeded()
        await suspension.value
        #expect(suspensionFinished)
    }

    @Test func queuedColdLaunchNotificationActionsShareBatchCutoffAndResetWhenQueueDrains() async throws {
        // Seed an account + group so real queued `.reply` operations execute
        // end-to-end through `AppNotifications`' serial action queue.
        let seedClient = try TestRuntimeScope.own(
            MarmotClient.testClient(), ownsRoot: true, retainingClient: false)
        let rootPath = seedClient.rootPath
        let relayUrls = seedClient.relayUrls
        let seedState = AppState.test(
            client: seedClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            accountDefaults: IsolatedAccountDefaults.make()
        )
        seedState.setAppSceneActive(true)
        await seedState.bootstrap()
        let account = try await seedState.createIdentity()
        let created = try await seedClient.createGroupWithOptionsDetailed(
            accountRef: account.label,
            name: "Cold Queue Batch",
            memberRefs: [],
            options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0)
        ).requireCreated()
        await seedState.startRuntimeSuspension().value

        var fakeNow = ContinuousClock.now
        var scheduledFailureTitles: [String] = []
        let notifications = AppNotifications(
            requestAuthorizationHandler: { false },
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {},
            notificationRequestScheduler: { request in
                scheduledFailureTitles.append(request.content.title)
            },
            actionClock: { fakeNow }
        )
        let firstFactoryEntered = TestLatch()
        let firstFactoryRelease = TestLatch()
        defer { firstFactoryRelease.signal() }
        var factoryCalls = 0
        var ephemeralClients: [MarmotClient] = []
        let appState = AppState.test(
            client: nil,
            notifications: notifications,
            accountDefaults: IsolatedAccountDefaults.make(),
            runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                factoryCalls += 1
                let call = factoryCalls
                if call == 1 {
                    firstFactoryEntered.signal()
                    await firstFactoryRelease.hold()
                }
                let built = try TestRuntimeScope.own(
                    MarmotClient(
                        rootPath: rootPath,
                        relayUrls: relayUrls,
                        cursorPersistence: cursorPersistence,
                        telemetryConfig: telemetryConfig
                    ),
                    ownsRoot: false,
                    retainingClient: false
                )
                ephemeralClients.append(built)
                return built
            }
        )
        notifications.configure(appState: appState)
        #expect(appState.phase == .bootstrapping)
        #expect(!appState.sceneHasReportedPhase)

        let route = LocalNotificationRoute(
            accountRef: account.label,
            groupIdHex: created.groupIdHex,
            notificationKey: "batch-cutoff-key",
            messageIdHex: nil
        )

        // 1. Start response #1 and hold it in the factory. Advance the clock
        //    past BOTH 18 s and 30 s BEFORE queuing response #2: only a shared
        //    batch cutoff causes response #2 to inherit `t0 + 18 s` (expired)
        //    instead of minting a fresh `t0 + 35 + 18 s` cutoff.
        let firstResponse = Task { @MainActor in
            await notifications.dispatchActionResponse(.reply(route, text: "first"))
        }
        try await firstFactoryEntered.wait()

        fakeNow = fakeNow.advanced(by: .seconds(35))
        let secondEnteredMainActor = TestLatch()
        let secondResponse = Task { @MainActor in
            // Because `dispatchActionResponse` runs synchronously on MainActor
            // through `enqueueActionOperations` before its first suspension point,
            // resuming from `secondEnteredMainActor.wait()` guarantees #2 is
            // already enqueued before `firstFactoryRelease` runs.
            secondEnteredMainActor.signal()
            await notifications.dispatchActionResponse(.reply(route, text: "second queued"))
        }
        try await secondEnteredMainActor.wait()

        // 2. Release response #1: response #2 must still see the shared expired
        //    cutoff, refuse SQLCipher, and report a failure notification.
        firstFactoryRelease.signal()
        await firstResponse.value
        await secondResponse.value

        #expect(factoryCalls == 1)
        #expect(ephemeralClients.count == 1)
        #expect(ephemeralClients[0].marmot.storageIsClosed())
        #expect(scheduledFailureTitles == [L10n.string("Reply not sent")])

        // 3. The queue has now drained, retiring the batch cutoff. A fresh
        //    response arriving just 5 seconds later on the same resident UI-less
        //    process (still `!sceneHasReportedPhase`) must receive a fresh 18 s
        //    budget and succeed rather than hitting a 30 s false rejection.
        scheduledFailureTitles.removeAll()
        fakeNow = fakeNow.advanced(by: .seconds(5))
        await notifications.dispatchActionResponse(.reply(route, text: "fresh wake"))
        await notifications.drainNotificationCenterMutations()

        #expect(factoryCalls == 2)
        #expect(ephemeralClients.count == 2)
        #expect(ephemeralClients[1].marmot.storageIsClosed())
        #expect(scheduledFailureTitles.isEmpty)
    }
}

/// Pure classifiers the runtime lifecycle branches on; no runtime, so no gate.
@MainActor
struct RuntimeLifecycleClassifierTests {
    @Test func initialSceneRuntimeActionDistinguishesBackgroundFromInactive() {
        #expect(SceneRuntimeAction.resolve(.active) == .activate)
        #expect(SceneRuntimeAction.resolve(.inactive) == .remainInactive)
        #expect(SceneRuntimeAction.resolve(.background) == .suspend)
    }

    // An ambiguous timeout must not be treated as "busy, safe to resubmit".
    @Test func accountWorkerBusyClassifierExcludesAmbiguousTimeouts() {
        #expect(MarmotKitError.AccountWorkerBusy.isAccountWorkerBusy)
        #expect(!MarmotKitError.AccountWorkerBusy.isAccountWorkerResponseTimedOut)
        #expect(MarmotKitError.AccountWorkerResponseTimedOut.isAccountWorkerResponseTimedOut)
        #expect(!MarmotKitError.AccountWorkerResponseTimedOut.isAccountWorkerBusy)
    }

    @Test func notificationContentionUsesTypedImmediateFallbackClassification() {
        #expect(MarmotKitError.RuntimeBusy.isRuntimeOwnershipContention)
        #expect(!MarmotKitError.RuntimeStopping.isRuntimeOwnershipContention)
    }

    @Test func startupReadinessClassifierIsNarrowAndTyped() {
        #expect(MarmotKitError.RuntimeBusy.isTransientStartupReadinessFailure)
        #expect(MarmotKitError.StorageBusy(details: "busy").isTransientStartupReadinessFailure)
        #expect(MarmotKitError.KeystoreUnavailable(details: "locked").isTransientStartupReadinessFailure)
        #expect(!MarmotKitError.StorageClosed(details: "closed").isTransientStartupReadinessFailure)
        #expect(!MarmotKitError.InvalidGroupMembershipPage(maxGroups: 100).isTransientStartupReadinessFailure)
        #expect(!MarmotKitError.Io(details: "disk failed").isTransientStartupReadinessFailure)
    }
}
