import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

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

        // The driver clears its task after the runner returns and offers no
        // completion hook short of stopping it, so this is a bounded poll.
        try await eventually { !driver.isRunning }
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
