import Foundation
import SwiftUI
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
        return try MarmotClient.testClient()
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
    private var didEnter = false

    func sleep(_: Duration) async throws {
        didEnter = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.release() }
        }
        try Task.checkCancellation()
    }

    func waitUntilEntered() async {
        while !didEnter {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite(.serialized)
struct RuntimeOwnershipTests {
    @Test func releasedMembershipPageLimitCrossesTheRealBinding() async throws {
        let client = try MarmotClient.testClient()
        do {
            _ = try await client.groupMemberIdsPage(
                accountRef: "unused",
                groupIdsHex: (0...100).map { String(format: "%032x", $0) }
            )
            Issue.record("Expected the 100-group binding limit to be enforced")
        } catch let error as MarmotKitError {
            guard case .InvalidGroupMembershipPage(let maximum) = error else {
                Issue.record("Unexpected membership page error: \(error)")
                return
            }
            #expect(maximum == 100)
        }
        try await client.marmot.shutdownAndClose()
    }

    @Test func newlyCreatedGroupIsImmediatelyReadableThroughRosterAndPage() async throws {
        let client = try MarmotClient.testClient()
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentity(
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
            )
            let created = try await client.createGroupWithOptionsDetailed(
                accountRef: account.label,
                name: "Local readiness",
                memberRefs: [],
                options: CreateGroupOptionsFfi(
                    description: "Available when create returns",
                    initialImage: nil,
                    disappearingMessageSecs: 3_600
                )
            )
            let groupIdHex = created.groupIdHex

            let roster = try await client.groupRoster(
                accountRef: account.label,
                groupIdHex: groupIdHex
            )
            let page = try await client.groupMemberIdsPage(
                accountRef: account.label,
                groupIdsHex: [groupIdHex]
            )
            let storedRow = try await client.chatListRow(
                accountRef: account.label,
                groupIdHex: groupIdHex
            )
            let row = try #require(storedRow)
            let snapshot = try await client.groupConversationSnapshot(
                accountRef: account.label,
                groupIdHex: groupIdHex
            )

            #expect(roster.groupIdHex == groupIdHex)
            #expect(roster.memberCount == 1)
            #expect(roster.selfMembership == .member)
            #expect(roster.members.count == 1)
            #expect(page.map(\.groupIdHex) == [groupIdHex])
            #expect(page.first?.memberIdsHex == roster.members.map(\.memberIdHex))
            #expect(row.groupIdHex == groupIdHex)
            #expect(row.groupName == "Local readiness")
            var createdRow = created.chatListRow
            // Projection refreshes may advance updatedAt between these separate reads.
            createdRow.updatedAt = row.updatedAt
            #expect(createdRow == row)
            #expect(snapshot.details.group.groupIdHex == groupIdHex)
            #expect(snapshot.details.group.disappearingMessageSecs == 3_600)
            #expect(snapshot.managementState.myAccountIdHex == account.accountIdHex)
            #expect(snapshot.managementState.isSelfAdmin)
            try await client.marmot.shutdownAndClose()
            #expect(client.marmot.storageIsClosed())
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func publishedPresentationSubscriptionCancelsWithoutAnotherEvent() async throws {
        let client = try MarmotClient.testClient()
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentity(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            )
            let subscription = try await client.openPresentedChatList(accountRef: account.label, includeArchived: true)
            let initial = await client.presentedChatListSubscriptionSnapshot(subscription)
            #expect(initial?.sequence == 0)
            #expect(await client.presentedChatListSubscriptionSnapshot(subscription) == nil)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(10))
                Issue.record("Cancellation required a runtime shutdown to unblock")
                try await client.marmot.shutdownAndClose()
            }
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
            let reader = Task.detached { try await subscription.nextCancellable() }
            let created = try await client.createGroupWithOptionsDetailed(
                accountRef: account.label, name: "Selected presentation", memberRefs: [],
                options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0)
            )
            let update = try #require(try await reader.value)
            #expect(update.subscriptionGeneration == initial?.subscriptionGeneration)
            #expect(update.sequence > 0)
            #expect(update.snapshot.rows.contains { $0.row.groupIdHex == created.groupIdHex })
            let recovery = try await client.groupRecoveryStatus(accountRef: account.label, groupIdHex: created.groupIdHex)
            #expect(!recovery.automaticRecoveryFailed && recovery.rejoinInvitations.isEmpty)
            #expect(try await !client.onboardingRecoveryRequired(accountRef: account.label))
            try await client.marmot.shutdownAndClose()
            #expect(client.marmot.storageIsClosed())
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func inactiveLaunchBootstrapsWithoutTreatingInactiveAsCancellation() async {
        let factory = ScriptedRuntimeFactory(busyFailures: 0)
        let appState = AppState(
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

    @Test func initialSceneRuntimeActionDistinguishesBackgroundFromInactive() {
        #expect(SceneRuntimeAction.resolve(.active) == .activate)
        #expect(SceneRuntimeAction.resolve(.inactive) == .remainInactive)
        #expect(SceneRuntimeAction.resolve(.background) == .suspend)
    }

    @Test func coldBackgroundLaunchClosesRuntimeAfterBootstrap() async throws {
        var injectedClient: MarmotClient? = try MarmotClient.testClient()
        let marmot = try #require(injectedClient?.marmot)
        weak let releasedClient = injectedClient
        let appState = AppState(
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

    @Test func bootstrapRetriesRuntimeBusySeriallyAndInstallsOneClient() async {
        let factory = ScriptedRuntimeFactory(busyFailures: 2)
        let appState = AppState(
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

    @Test func bootstrapRetriesTransientStorageAndKeystoreReadiness() async {
        let factory = ScriptedRuntimeFactory(failures: [
            .StorageBusy(details: "database is locked"),
            .KeystoreUnavailable(details: "protected data unavailable"),
        ])
        let appState = AppState(
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

    @Test func bootstrapStopsRetryingWhenAppBackgrounds() async {
        let factory = ScriptedRuntimeFactory(busyFailures: .max)
        let retryGate = RuntimeRetryGate()
        let appState = AppState(
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
        await retryGate.waitUntilEntered()

        appState.setAppSceneActive(false)
        await retryGate.release()
        await bootstrap.value

        let snapshot = await factory.snapshot()
        #expect(snapshot.attempts == 1)
        #expect(appState.client == nil)
        #expect(appState.phase == .bootstrapping)
    }

    @Test func exhaustedContentionIsRecoverableAndASecondBootstrapCanSucceed() async {
        let factory = ScriptedRuntimeFactory(busyFailures: 2)
        let appState = AppState(
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
        var injectedClient: MarmotClient? = try MarmotClient.testClient()
        let marmot = try #require(injectedClient?.marmot)
        weak let releasedClient = injectedClient
        let appState = AppState(
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
        var injectedClient: MarmotClient? = try MarmotClient.testClient()
        let marmot = try #require(injectedClient?.marmot)
        let gate = RuntimeRetryGate()
        let appState = AppState(
            client: injectedClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        injectedClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        appState.scheduleForegroundMutationFollowupForTesting {
            try? await gate.sleep(.seconds(30))
        }
        await gate.waitUntilEntered()

        await appState.startRuntimeSuspension().value

        #expect(appState.client == nil)
        #expect(marmot.storageIsClosed())
    }

    @Test func runtimeLeaseRejectsASecondOwnerUntilTheFinalHandleDrops() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var first: Marmot? = try Marmot.newWithCursorPersistence(
            rootPath: root.path,
            relayUrls: ["wss://relay.invalid.test"],
            cursorPersistence: .advance
        )

        do {
            _ = try Marmot.newWithCursorPersistence(
                rootPath: root.path,
                relayUrls: ["wss://relay.invalid.test"],
                cursorPersistence: .frozen
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
            cursorPersistence: .advance
        )
        try await replacement.shutdownAndClose()
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

    @Test func notificationActionContentionFailsImmediatelyAndReleasesSuspensionGate() async throws {
        var initialClient: MarmotClient? = try MarmotClient.testClient()
        let appState = AppState(
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
            _ = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
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

    @Test func notificationDeliveryGateWinsAnExpirationRaceExactlyOnce() {
        let gate = OneShotNotificationDelivery()
        var delivered: [String] = []
        gate.reset { delivered.append($0.title) }

        let timeoutFallback = UNMutableNotificationContent()
        timeoutFallback.title = "timeout fallback"
        let lateCollectionResult = UNMutableNotificationContent()
        lateCollectionResult.title = "late collection result"

        #expect(gate.deliver(timeoutFallback))
        #expect(!gate.deliver(lateCollectionResult))
        #expect(delivered == ["timeout fallback"])
    }
}
