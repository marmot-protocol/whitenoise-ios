import Foundation
import Synchronization
import Testing
import UserNotifications
@testable import MarmotKit
@testable import whitenoise_ios

@MainActor
struct NotificationServiceWakeCoordinatorTests {
    @Test func wakeCoordinatorIsolatesWakeOneExpirationFromWakeTwoAndSerializesRuntimeShutdown() async throws {
        let events = WakeEventLog()
        let wake1CollectEntered = TestLatch()
        let wake1CollectRelease = TestLatch()
        let wake1ShutdownEntered = TestLatch()
        let wake1ShutdownRelease = TestLatch()
        let wake2Delivered = TestLatch()
        var wake1Contents: [UNNotificationContent] = []
        var wake2Contents: [UNNotificationContent] = []
        var runtimeIndex = 0

        let wake2Update = notificationUpdate(
            notificationKey: "wake-2-msg",
            senderName: "Bob",
            previewText: "Fresh message for wake 2",
            timestampMs: 2_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onCollect: { _ in
                            wake1CollectEntered.signal()
                            try await wake1CollectRelease.wait()
                            return BackgroundNotificationCollectionFfi(status: .noData, notifications: [], error: nil)
                        },
                        onShutdown: {
                            wake1ShutdownEntered.signal()
                            try await wake1ShutdownRelease.wait()
                            wake1CollectRelease.signal()
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wake2Update],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let req1 = UNNotificationRequest(identifier: "wake-1", content: UNNotificationContent(), trigger: nil)
        let req2 = UNNotificationRequest(identifier: "wake-2", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(req1, ownerID: owner) { content in
            wake1Contents.append(content)
        }
        try await wake1CollectEntered.wait()

        // Hard expiration must deliver wake #1's best prepared primary
        // synchronously without waiting on `shutdownAndClose()`, while still
        // launching runtime #1 shutdown as the barrier for wake #2.
        coordinator.serviceExtensionTimeWillExpire(ownerID: owner)
        #expect(wake1Contents.count == 1)
        #expect(wake1Contents.first?.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)
        try await wake1ShutdownEntered.wait()

        // iOS reuses the same extension instance for wake #2 while wake #1's
        // shutdown is still paused.
        coordinator.didReceive(req2, ownerID: owner) { content in
            wake2Contents.append(content)
            wake2Delivered.signal()
        }
        await Task.yield()

        // Wake #2 must not open runtime #2 while runtime #1 still holds the lock.
        #expect(runtimeIndex == 1)
        #expect(wake2Contents.isEmpty)

        // Complete runtime #1's shutdown.
        wake1ShutdownRelease.signal()
        try await wake2Delivered.wait()

        #expect(wake1Contents.count == 1)
        #expect(wake2Contents.count == 1)
        #expect(wake2Contents.first?.title == "Bob")
        #expect(wake2Contents.first?.body == "Fresh message for wake 2")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorCancelsActiveWakeOneAndClosesItsRuntimeBeforeWakeTwoOpens() async throws {
        let events = WakeEventLog()
        let wake1StartEntered = TestLatch()
        let wake1StartRelease = TestLatch()
        let wake1Delivered = TestLatch()
        let wake2Delivered = TestLatch()
        var wake1Contents: [UNNotificationContent] = []
        var wake2Contents: [UNNotificationContent] = []
        var runtimeIndex = 0

        let wake2Update = notificationUpdate(
            notificationKey: "wake-2-active-replace",
            senderName: "Alice",
            previewText: "Hello on reused instance",
            timestampMs: 3_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onStart: {
                            wake1StartEntered.signal()
                            try await wake1StartRelease.wait()
                        },
                        onCollect: { _ in
                            BackgroundNotificationCollectionFfi(status: .noData, notifications: [], error: nil)
                        },
                        onShutdown: {
                            wake1StartRelease.signal()
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wake2Update],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let req1 = UNNotificationRequest(identifier: "active-1", content: UNNotificationContent(), trigger: nil)
        let req2 = UNNotificationRequest(identifier: "active-2", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(req1, ownerID: owner) { content in
            wake1Contents.append(content)
            wake1Delivered.signal()
        }
        try await wake1StartEntered.wait()

        // Wake #2 arrives while wake #1 is still starting (before collection has
        // entered MDK). Wake #1 must be cancelled and shut down before wake #2
        // opens its runtime.
        coordinator.didReceive(req2, ownerID: owner) { content in
            wake2Contents.append(content)
            wake2Delivered.signal()
        }

        try await wake1Delivered.wait()
        try await wake2Delivered.wait()

        #expect(wake1Contents.count == 1)
        #expect(wake1Contents.first?.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)
        #expect(wake2Contents.count == 1)
        #expect(wake2Contents.first?.title == "Alice")
        #expect(wake2Contents.first?.body == "Hello on reused instance")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorPreservesBatchWhenWakeTwoArrivesWhileCollectionIsInFlight() async throws {
        let events = WakeEventLog()
        let wake1CollectEntered = TestLatch()
        let wake1CollectRelease = TestLatch()
        let wake1Delivered = TestLatch()
        let wake2Delivered = TestLatch()
        var wake1Contents: [UNNotificationContent] = []
        var wake2Contents: [UNNotificationContent] = []
        let additionalTitles = Mutex<[String]>([])
        var runtimeIndex = 0

        let wake1Primary = notificationUpdate(
            notificationKey: "wake-1-inflight-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "In-flight primary",
            timestampMs: 4_000
        )
        let wake1Extra = notificationUpdate(
            notificationKey: "wake-1-inflight-extra",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Bob",
            previewText: "In-flight extra",
            timestampMs: 3_500
        )
        let wake2Update = notificationUpdate(
            notificationKey: "wake-2-after-inflight",
            groupIdHex: String(repeating: "33", count: 16),
            senderName: "Carol",
            previewText: "Wake 2 message",
            timestampMs: 5_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onCollect: { _ in
                            wake1CollectEntered.signal()
                            try await wake1CollectRelease.wait()
                            return BackgroundNotificationCollectionFfi(
                                status: .newData,
                                notifications: [wake1Extra, wake1Primary],
                                error: nil
                            )
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wake2Update],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let req1 = UNNotificationRequest(identifier: "inflight-1", content: UNNotificationContent(), trigger: nil)
        let req2 = UNNotificationRequest(identifier: "inflight-2", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(req1, ownerID: owner) { content in
            wake1Contents.append(content)
            wake1Delivered.signal()
        }
        try await wake1CollectEntered.wait()

        // Wake #2 arrives while wake #1 is already inside
        // `collectNotificationsAfterWake`. MDK may already have advanced the
        // background delivery cursor, so wake #1 must finish receiving,
        // projecting, delivering, and shutting down before wake #2 opens.
        coordinator.didReceive(req2, ownerID: owner) { content in
            wake2Contents.append(content)
            wake2Delivered.signal()
        }
        await Task.yield()
        #expect(runtimeIndex == 1)

        wake1CollectRelease.signal()
        try await wake1Delivered.wait()
        try await wake2Delivered.wait()

        #expect(wake1Contents.count == 1)
        #expect(wake1Contents.first?.title == "Alice")
        #expect(wake1Contents.first?.body == "In-flight primary")
        #expect(additionalTitles.withLock { $0 } == ["Bob"])
        #expect(wake2Contents.count == 1)
        #expect(wake2Contents.first?.title == "Carol")
        #expect(wake2Contents.first?.body == "Wake 2 message")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorPreservesConsumedNotificationsWhenWakeTwoReplacesDuringProjection() async throws {
        let events = WakeEventLog()
        let wake1LocalCheckEntered = TestLatch()
        let wake1LocalCheckRelease = TestLatch()
        let wake1Delivered = TestLatch()
        let wake2Delivered = TestLatch()
        var wake1Contents: [UNNotificationContent] = []
        var wake2Contents: [UNNotificationContent] = []
        let additionalTitles = Mutex<[String]>([])
        var runtimeIndex = 0

        let wake1Primary = notificationUpdate(
            notificationKey: "wake-1-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Consumed primary",
            timestampMs: 4_000
        )
        let wake1Extra = notificationUpdate(
            notificationKey: "wake-1-extra",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Bob",
            previewText: "Consumed extra",
            timestampMs: 3_500
        )
        let wake2Update = notificationUpdate(
            notificationKey: "wake-2-after-consumed",
            groupIdHex: String(repeating: "33", count: 16),
            senderName: "Carol",
            previewText: "Wake 2 message",
            timestampMs: 5_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onCollect: { _ in
                            BackgroundNotificationCollectionFfi(
                                status: .newData,
                                notifications: [wake1Extra, wake1Primary],
                                error: nil
                            )
                        },
                        onLocalNotificationsEnabled: {
                            wake1LocalCheckEntered.signal()
                            try? await wake1LocalCheckRelease.wait()
                            return [:]
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wake2Update],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let req1 = UNNotificationRequest(identifier: "consumed-1", content: UNNotificationContent(), trigger: nil)
        let req2 = UNNotificationRequest(identifier: "consumed-2", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(req1, ownerID: owner) { content in
            wake1Contents.append(content)
            wake1Delivered.signal()
        }
        try await wake1LocalCheckEntered.wait()

        // Wake #2 arrives after wake #1 already drained notifications from MDK's
        // background cursor. Wake #1 must finish projecting, delivering,
        // enqueuing its additional notification, and shutting down before wake #2
        // opens a runtime.
        coordinator.didReceive(req2, ownerID: owner) { content in
            wake2Contents.append(content)
            wake2Delivered.signal()
        }
        await Task.yield()
        #expect(runtimeIndex == 1)

        wake1LocalCheckRelease.signal()
        try await wake1Delivered.wait()
        try await wake2Delivered.wait()

        #expect(wake1Contents.count == 1)
        #expect(wake1Contents.first?.title == "Alice")
        #expect(wake1Contents.first?.body == "Consumed primary")
        #expect(additionalTitles.withLock { $0 } == ["Bob"])
        #expect(wake2Contents.count == 1)
        #expect(wake2Contents.first?.title == "Carol")
        #expect(wake2Contents.first?.body == "Wake 2 message")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorPreservesBatchWhenProactiveWatchdogFiresDuringInFlightCollection() async throws {
        let events = WakeEventLog()
        let wake1CollectEntered = TestLatch()
        let wake1CollectRelease = TestLatch()
        let triggerWatchdog = TestLatch()
        let watchdogFired = TestLatch()
        let wake1Delivered = TestLatch()
        var wake1Contents: [UNNotificationContent] = []
        let additionalTitles = Mutex<[String]>([])
        let badgeQueries = Mutex(0)
        let observedMaxWaitMs = Mutex<UInt32?>(nil)
        var runtimeIndex = 0

        let wake1Primary = notificationUpdate(
            notificationKey: "wake-1-watchdog-primary",
            accountRef: "enabled-account",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Kept past watchdog",
            timestampMs: 4_000
        )
        let wake1Disabled = notificationUpdate(
            notificationKey: "wake-1-watchdog-disabled",
            accountRef: "disabled-account",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Hidden",
            previewText: "Must stay suppressed",
            timestampMs: 4_500
        )
        let wake1Extra = notificationUpdate(
            notificationKey: "wake-1-watchdog-extra",
            accountRef: "enabled-account",
            groupIdHex: String(repeating: "33", count: 16),
            senderName: "Bob",
            previewText: "Extra kept past watchdog",
            timestampMs: 3_500
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { maxWaitMs in
                        observedMaxWaitMs.withLock { $0 = maxWaitMs }
                        wake1CollectEntered.signal()
                        try await wake1CollectRelease.wait()
                        return BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wake1Extra, wake1Primary, wake1Disabled],
                            error: nil
                        )
                    },
                    onApplicationBadgeCount: {
                        badgeQueries.withLock { $0 += 1 }
                        return 7
                    },
                    onLocalNotificationsEnabled: {
                        [
                            "enabled-account": true,
                            "disabled-account": false,
                        ]
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: .milliseconds(1_500),
            sleep: { _ in
                try await triggerWatchdog.wait()
                watchdogFired.signal()
            },
            enqueueAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let req1 = UNNotificationRequest(identifier: "wd-1", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(req1, ownerID: owner) { content in
            wake1Contents.append(content)
            wake1Delivered.signal()
        }
        try await wake1CollectEntered.wait()

        // Collection wait must be bounded by the wake's remaining proactive
        // budget rather than blindly passing the full configured 8 s window.
        let passedMaxWait = try #require(observedMaxWaitMs.withLock { $0 })
        #expect(passedMaxWait <= 1_500)
        #expect(passedMaxWait >= NotificationServiceTimeoutPolicy.minimumCollectionWaitMs)

        // Fire the proactive watchdog while `collectNotificationsAfterWake` is
        // still in flight: MDK may already have advanced its background cursor,
        // so the wake must let collection return, skip optional badge reads,
        // apply privacy filtering, and deliver primary + extra notifications.
        triggerWatchdog.signal()
        try await watchdogFired.wait()
        await Task.yield()

        #expect(wake1Contents.isEmpty)
        #expect(runtimeIndex == 1)

        wake1CollectRelease.signal()
        try await wake1Delivered.wait()

        #expect(wake1Contents.count == 1)
        #expect(wake1Contents.first?.title == "Alice")
        #expect(wake1Contents.first?.body == "Kept past watchdog")
        #expect(additionalTitles.withLock { $0 } == ["Bob"])
        #expect(badgeQueries.withLock { $0 } == 0)
    }

    @Test func effectiveCollectionWaitMsBoundsToRemainingProactiveBudget() {
        #expect(NotificationServiceTimeoutPolicy.effectiveCollectionWaitMs(
            configuredMaxWaitMs: 8_000,
            proactiveBudget: .seconds(18),
            elapsed: .seconds(2)
        ) == 8_000)

        #expect(NotificationServiceTimeoutPolicy.effectiveCollectionWaitMs(
            configuredMaxWaitMs: 8_000,
            proactiveBudget: .seconds(18),
            elapsed: .seconds(15)
        ) == 3_000)

        // Near-exhausted budget preserves the explicit 250 ms grace floor.
        #expect(NotificationServiceTimeoutPolicy.effectiveCollectionWaitMs(
            configuredMaxWaitMs: 8_000,
            proactiveBudget: .seconds(18),
            elapsed: .milliseconds(17_900)
        ) == NotificationServiceTimeoutPolicy.minimumCollectionWaitMs)

        #expect(NotificationServiceTimeoutPolicy.effectiveCollectionWaitMs(
            configuredMaxWaitMs: 8_000,
            proactiveBudget: .seconds(18),
            elapsed: .seconds(20)
        ) == NotificationServiceTimeoutPolicy.minimumCollectionWaitMs)

        // Configured ceiling still caps the grace floor.
        #expect(NotificationServiceTimeoutPolicy.effectiveCollectionWaitMs(
            configuredMaxWaitMs: 100,
            proactiveBudget: .seconds(18),
            elapsed: .seconds(20)
        ) == 100)
    }

    @Test func wakeCoordinatorHardExpiryDuringParkedBadgeReadOrShutdownStillSubmitsExtrasAndHoldsStorageBarrier() async throws {
        let events = WakeEventLog()
        let badgeEntered = TestLatch()
        let badgeRelease = TestLatch()
        let badgeFinished = TestLatch()
        defer { badgeRelease.signal() }
        let extraSubmitted = TestLatch()
        let wakeBDelivered = TestLatch()
        var wakeAContents: [UNNotificationContent] = []
        var wakeBContents: [UNNotificationContent] = []
        let additionalTitles = Mutex<[String]>([])
        var runtimeIndex = 0

        let primary = notificationUpdate(
            notificationKey: "badge-parked-primary",
            accountRef: "enabled-account",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Delivered past stalled badge read",
            timestampMs: 4_000
        )
        let disabled = notificationUpdate(
            notificationKey: "badge-parked-disabled",
            accountRef: "disabled-account",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Hidden",
            previewText: "Must stay suppressed",
            timestampMs: 4_500
        )
        let extra = notificationUpdate(
            notificationKey: "badge-parked-extra",
            accountRef: "enabled-account",
            groupIdHex: String(repeating: "33", count: 16),
            senderName: "Bob",
            previewText: "Extra kept past hard expiry",
            timestampMs: 3_500
        )
        let wakeBUpdate = notificationUpdate(
            notificationKey: "wake-b-after-admitted-read",
            accountRef: "enabled-account",
            groupIdHex: String(repeating: "44", count: 16),
            senderName: "Carol",
            previewText: "Wake B waited for admitted SQLite read",
            timestampMs: 5_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onCollect: { _ in
                            BackgroundNotificationCollectionFfi(
                                status: .newData,
                                notifications: [extra, primary, disabled],
                                error: nil
                            )
                        },
                        onApplicationBadgeCount: {
                            badgeEntered.signal()
                            await badgeRelease.hold()
                            badgeFinished.signal()
                            return 9
                        },
                        onLocalNotificationsEnabled: {
                            [
                                "enabled-account": true,
                                "disabled-account": false,
                            ]
                        },
                        onShutdown: {
                            // Accurately model MDK's `shutdownAndClose()` waiting
                            // for an already-admitted synchronous SQLite read.
                            await badgeFinished.hold()
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wakeBUpdate],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
                extraSubmitted.signal()
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let ownerA = UUID()
        let ownerB = UUID()
        let reqA = UNNotificationRequest(identifier: "wd-badge-a", content: UNNotificationContent(), trigger: nil)
        let reqB = UNNotificationRequest(identifier: "wd-badge-b", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(reqA, ownerID: ownerA) { content in
            wakeAContents.append(content)
        }
        try await badgeEntered.wait()

        // Hard expiration while the optional badge read is admitted in SQLite:
        // primary must deliver synchronously (decorated, not fallback), the
        // already-projected extra must still be submitted independently of the
        // cancelled collection task, AND wake B must wait until the admitted
        // read + shutdown complete before opening runtime #2.
        coordinator.serviceExtensionTimeWillExpire(ownerID: ownerA)

        #expect(wakeAContents.count == 1)
        #expect(wakeAContents.first?.title == "Alice")
        #expect(wakeAContents.first?.body == "Delivered past stalled badge read")
        try await extraSubmitted.wait()
        #expect(additionalTitles.withLock { $0 } == ["Bob"])

        coordinator.didReceive(reqB, ownerID: ownerB) { content in
            wakeBContents.append(content)
            wakeBDelivered.signal()
        }
        await Task.yield()
        #expect(runtimeIndex == 1)
        #expect(wakeBContents.isEmpty)

        badgeRelease.signal()
        try await wakeBDelivered.wait()
        #expect(wakeBContents.first?.title == "Carol")
        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorHardExpiryWhileShutdownIsParkedStillSubmitsProjectedExtras() async throws {
        let events = WakeEventLog()
        let shutdownEntered = TestLatch()
        let shutdownRelease = TestLatch()
        defer { shutdownRelease.signal() }
        let extraSubmitted = TestLatch()
        var wakeAContents: [UNNotificationContent] = []
        let additionalTitles = Mutex<[String]>([])

        let primary = notificationUpdate(
            notificationKey: "shutdown-parked-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Primary before shutdown expiry",
            timestampMs: 5_000
        )
        let extra = notificationUpdate(
            notificationKey: "shutdown-parked-extra",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Bob",
            previewText: "Extra submitted despite shutdown expiry",
            timestampMs: 4_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                events.append("created-1")
                return FakeNotificationServiceWakeRuntime(
                    id: 1,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [extra, primary],
                            error: nil
                        )
                    },
                    onShutdown: {
                        shutdownEntered.signal()
                        await shutdownRelease.hold()
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
                extraSubmitted.signal()
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let request = UNNotificationRequest(identifier: "shutdown-exp", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(request, ownerID: owner) { content in
            wakeAContents.append(content)
        }
        try await shutdownEntered.wait()

        coordinator.serviceExtensionTimeWillExpire(ownerID: owner)

        #expect(wakeAContents.count == 1)
        #expect(wakeAContents.first?.title == "Alice")
        #expect(wakeAContents.first?.body == "Primary before shutdown expiry")

        try await extraSubmitted.wait()
        #expect(additionalTitles.withLock { $0 } == ["Bob"])
    }

    @Test func wakeCoordinatorProactiveWatchdogDeliversPrimaryWhileAdditionalEnqueueIsParked() async throws {
        let events = WakeEventLog()
        let enqueueEntered = TestLatch()
        let enqueueRelease = TestLatch()
        defer { enqueueRelease.signal() }
        let triggerWatchdog = TestLatch()
        let wakeADelivered = TestLatch()
        let wakeBDelivered = TestLatch()
        var wakeAContents: [UNNotificationContent] = []
        var wakeBContents: [UNNotificationContent] = []
        var runtimeIndex = 0

        let wakeAPrimary = notificationUpdate(
            notificationKey: "parked-enqueue-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Primary delivered on proactive watchdog",
            timestampMs: 5_000
        )
        let wakeAExtra = notificationUpdate(
            notificationKey: "parked-enqueue-extra",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Bob",
            previewText: "Parked extra",
            timestampMs: 4_000
        )
        let wakeBUpdate = notificationUpdate(
            notificationKey: "unblocked-wake-b",
            groupIdHex: String(repeating: "33", count: 16),
            senderName: "Eve",
            previewText: "Wake B unblocked after shutdown",
            timestampMs: 6_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onCollect: { _ in
                            BackgroundNotificationCollectionFfi(
                                status: .newData,
                                notifications: [wakeAExtra, wakeAPrimary],
                                error: nil
                            )
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wakeBUpdate],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in
                try await triggerWatchdog.wait()
            },
            enqueueAdditionalPresentation: { _, _ in
                enqueueEntered.signal()
                await enqueueRelease.hold()
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let ownerA = UUID()
        let ownerB = UUID()
        let reqA = UNNotificationRequest(identifier: "enqueue-a", content: UNNotificationContent(), trigger: nil)
        let reqB = UNNotificationRequest(identifier: "enqueue-b", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(reqA, ownerID: ownerA) { content in
            wakeAContents.append(content)
            wakeADelivered.signal()
        }
        try await enqueueEntered.wait()

        // Runtime #1 has already closed before enqueueing started.
        #expect(events.snapshot().contains("shutdown-done-1"))

        // Fire ONLY the proactive watchdog (not hard expiration): owner A must
        // deliver its prepared primary BEFORE `enqueueRelease` is signalled,
        // and wake B on a distinct owner must open runtime #2 and deliver even
        // while owner A's enqueue stays parked.
        triggerWatchdog.signal()
        try await wakeADelivered.wait()
        #expect(wakeAContents.count == 1)
        #expect(wakeAContents.first?.title == "Alice")
        #expect(wakeAContents.first?.body == "Primary delivered on proactive watchdog")

        coordinator.didReceive(reqB, ownerID: ownerB) { content in
            wakeBContents.append(content)
            wakeBDelivered.signal()
        }
        try await wakeBDelivered.wait()
        #expect(runtimeIndex == 2)
        #expect(wakeBContents.count == 1)
        #expect(wakeBContents.first?.title == "Eve")
        #expect(wakeBContents.first?.body == "Wake B unblocked after shutdown")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorScopesHardExpirationToOwningExtensionInstanceWhileSerializingShutdown() async throws {
        let events = WakeEventLog()
        let instanceACollectEntered = TestLatch()
        let instanceACollectRelease = TestLatch()
        let instanceAShutdownEntered = TestLatch()
        let instanceAShutdownRelease = TestLatch()
        let instanceBDelivered = TestLatch()
        var instanceAContents: [UNNotificationContent] = []
        var instanceBContents: [UNNotificationContent] = []
        var runtimeIndex = 0

        let instanceBUpdate = notificationUpdate(
            notificationKey: "instance-b-msg",
            senderName: "Eve",
            previewText: "Instance B survived instance A expiration",
            timestampMs: 7_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onCollect: { _ in
                            instanceACollectEntered.signal()
                            try await instanceACollectRelease.wait()
                            return BackgroundNotificationCollectionFfi(status: .noData, notifications: [], error: nil)
                        },
                        onShutdown: {
                            instanceAShutdownEntered.signal()
                            try await instanceAShutdownRelease.wait()
                            instanceACollectRelease.signal()
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [instanceBUpdate],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let ownerA = UUID()
        let ownerB = UUID()
        let reqA = UNNotificationRequest(identifier: "inst-a", content: UNNotificationContent(), trigger: nil)
        let reqB = UNNotificationRequest(identifier: "inst-b", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(reqA, ownerID: ownerA) { content in
            instanceAContents.append(content)
        }
        try await instanceACollectEntered.wait()

        // A second extension instance receives push B while instance A is still
        // inside collection; A moves to draining and B parks behind A's shutdown.
        coordinator.didReceive(reqB, ownerID: ownerB) { content in
            instanceBContents.append(content)
            instanceBDelivered.signal()
        }
        await Task.yield()
        #expect(runtimeIndex == 1)

        // iOS now expires instance A AFTER instance B registered. Hard
        // expiration must deliver A's fallback immediately while runtime #1
        // shutdown is still held, without cancelling B, and B must wait until
        // runtime #1 finishes shutting down before constructing runtime #2.
        coordinator.serviceExtensionTimeWillExpire(ownerID: ownerA)
        #expect(instanceAContents.count == 1)
        #expect(instanceAContents.first?.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)

        try await instanceAShutdownEntered.wait()
        await Task.yield()
        #expect(runtimeIndex == 1)
        #expect(instanceBContents.isEmpty)

        instanceAShutdownRelease.signal()
        try await instanceBDelivered.wait()

        #expect(instanceAContents.count == 1)
        #expect(instanceBContents.count == 1)
        #expect(instanceBContents.first?.title == "Eve")
        #expect(instanceBContents.first?.body == "Instance B survived instance A expiration")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorDrainsWakeOneAcrossThreeWakesWhenWakeTwoExpiresBeforeOpeningRuntime() async throws {
        let events = WakeEventLog()
        let wake1StartEntered = TestLatch()
        let wake1StartRelease = TestLatch()
        let wake1ShutdownEntered = TestLatch()
        let wake1ShutdownRelease = TestLatch()
        let wake1Delivered = TestLatch()
        let wake3Delivered = TestLatch()
        var wake2Contents: [UNNotificationContent] = []
        var wake3Contents: [UNNotificationContent] = []
        var runtimeIndex = 0

        let wake3Update = notificationUpdate(
            notificationKey: "wake-3-after-chain",
            senderName: "Dave",
            previewText: "Wake 3 waited for wake 1",
            timestampMs: 6_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                if id == 1 {
                    return FakeNotificationServiceWakeRuntime(
                        id: id,
                        events: events,
                        onStart: {
                            wake1StartEntered.signal()
                            try await wake1StartRelease.wait()
                        },
                        onCollect: { _ in
                            BackgroundNotificationCollectionFfi(status: .noData, notifications: [], error: nil)
                        },
                        onShutdown: {
                            wake1ShutdownEntered.signal()
                            try await wake1ShutdownRelease.wait()
                            wake1StartRelease.signal()
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wake3Update],
                            error: nil
                        )
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            sleep: { _ in try await parkUntilCancelled() },
            enqueueAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let req1 = UNNotificationRequest(identifier: "chain-1", content: UNNotificationContent(), trigger: nil)
        let req2 = UNNotificationRequest(identifier: "chain-2", content: UNNotificationContent(), trigger: nil)
        let req3 = UNNotificationRequest(identifier: "chain-3", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(req1, ownerID: owner) { _ in wake1Delivered.signal() }
        try await wake1StartEntered.wait()

        // Wake #2 replaces wake #1 and parks on wake #1's shutdown.
        coordinator.didReceive(req2, ownerID: owner) { content in
            wake2Contents.append(content)
        }
        try await wake1ShutdownEntered.wait()

        // Wake #2 expires before ever opening a runtime, then wake #3 arrives
        // while wake #1's shutdown is STILL paused.
        coordinator.serviceExtensionTimeWillExpire(ownerID: owner)
        #expect(wake2Contents.first?.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)

        coordinator.didReceive(req3, ownerID: owner) { content in
            wake3Contents.append(content)
            wake3Delivered.signal()
        }
        await Task.yield()

        // Wake #3 must still wait for wake #1's shutdown even though wake #2
        // already finished without opening a runtime.
        #expect(runtimeIndex == 1)
        #expect(wake3Contents.isEmpty)

        wake1ShutdownRelease.signal()
        try await wake1Delivered.wait()
        try await wake3Delivered.wait()

        #expect(wake3Contents.count == 1)
        #expect(wake3Contents.first?.title == "Dave")
        #expect(wake3Contents.first?.body == "Wake 3 waited for wake 1")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    private static func allVisiblePolicySnapshot() -> NotificationServiceWakePolicySnapshot {
        NotificationServiceWakePolicySnapshot(
            notifyMode: { _, _ in .all },
            mentionsBreakThroughMute: true,
            nickname: { _, _ in nil },
            previewMode: .senderAndMessage
        )
    }
}

private final class WakeEventLog: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ event: String) {
        storage.withLock { $0.append(event) }
    }

    func snapshot() -> [String] {
        storage.withLock { $0 }
    }
}

private final class FakeNotificationServiceWakeRuntime: NotificationServiceWakeRuntime {
    let id: Int
    let events: WakeEventLog
    let onStart: @Sendable () async throws -> Void
    let onCollect: @Sendable (UInt32) async throws -> BackgroundNotificationCollectionFfi
    let onApplicationBadgeCount: @Sendable () async -> Int?
    let onLocalNotificationsEnabled: @Sendable () async -> [String: Bool]
    let onShutdown: @Sendable () async throws -> Void

    init(
        id: Int,
        events: WakeEventLog,
        onStart: @escaping @Sendable () async throws -> Void = {},
        onCollect: @escaping @Sendable (UInt32) async throws -> BackgroundNotificationCollectionFfi,
        onApplicationBadgeCount: @escaping @Sendable () async -> Int? = { nil },
        onLocalNotificationsEnabled: @escaping @Sendable () async -> [String: Bool] = { [:] },
        onShutdown: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.id = id
        self.events = events
        self.onStart = onStart
        self.onCollect = onCollect
        self.onApplicationBadgeCount = onApplicationBadgeCount
        self.onLocalNotificationsEnabled = onLocalNotificationsEnabled
        self.onShutdown = onShutdown
    }

    func setAuditLogSource(source: AuditLogSourceFfi) throws {}

    func start() async throws {
        try await onStart()
    }

    func collectNotificationsAfterWake(
        maxWaitMs: UInt32,
        source: NotificationWakeSourceFfi
    ) async throws -> BackgroundNotificationCollectionFfi {
        try await onCollect(maxWaitMs)
    }

    func applicationBadgeCount() async -> Int? {
        await onApplicationBadgeCount()
    }

    func localNotificationsEnabled(accountRefs: Set<String>) async -> [String: Bool] {
        await onLocalNotificationsEnabled()
    }

    func archivedChatKeys(accountRefs: Set<String>) async -> Set<String> { [] }

    func shutdownAndClose() async throws {
        events.append("shutdown-start-\(id)")
        try await onShutdown()
        events.append("shutdown-done-\(id)")
    }
}
