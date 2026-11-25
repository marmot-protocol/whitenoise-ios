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
        defer { wake1CollectRelease.signal() }
        let wake1ShutdownEntered = TestLatch()
        let wake1ShutdownRelease = TestLatch()
        defer { wake1ShutdownRelease.signal() }
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
            submitAdditionalPresentation: { _, _ in }
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
        defer { wake1StartRelease.signal() }
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
            submitAdditionalPresentation: { _, _ in }
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
        defer { wake1CollectRelease.signal() }
        let wake1Delivered = TestLatch()
        let wake2Delivered = TestLatch()
        let extraSubmitted = TestLatch()
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
            submitAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
                extraSubmitted.signal()
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
        // projecting, submitting extras, shutting down, and delivering before
        // wake #2 opens.
        coordinator.didReceive(req2, ownerID: owner) { content in
            wake2Contents.append(content)
            wake2Delivered.signal()
        }
        await Task.yield()
        #expect(runtimeIndex == 1)

        wake1CollectRelease.signal()
        try await wake1Delivered.wait()
        try await extraSubmitted.wait()
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
        defer { wake1LocalCheckRelease.signal() }
        let wake1Delivered = TestLatch()
        let wake2Delivered = TestLatch()
        let extraSubmitted = TestLatch()
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
            submitAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
                extraSubmitted.signal()
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
        // background cursor. Wake #1 must finish projecting, submitting its
        // additional notification, shutting down, and delivering before wake #2
        // opens a runtime.
        coordinator.didReceive(req2, ownerID: owner) { content in
            wake2Contents.append(content)
            wake2Delivered.signal()
        }
        await Task.yield()
        #expect(runtimeIndex == 1)

        wake1LocalCheckRelease.signal()
        try await wake1Delivered.wait()
        try await extraSubmitted.wait()
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

    @Test(arguments: [true, false])
    func wakeCoordinatorPreservesBatchWhenProactiveWatchdogFiresDuringInFlightCollection(
        watchdogFires: Bool
    ) async throws {
        let events = WakeEventLog()
        let clock = MutableContinuousClock(initial: ContinuousClock.now)
        let wake1CollectEntered = TestLatch()
        let wake1CollectRelease = TestLatch()
        defer { wake1CollectRelease.signal() }
        let triggerWatchdog = TestLatch()
        defer { triggerWatchdog.signal() }
        let watchdogFired = TestLatch()
        let wake1Delivered = TestLatch()
        let extraSubmitted = TestLatch()
        var wake1Contents: [UNNotificationContent] = []
        let additionalTitles = Mutex<[String]>([])
        let badgeCalls = Mutex(0)
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

        // Use the full 18 s budget (well above the 6 s badge-scan threshold) so
        // the control case (`watchdogFires == false`) performs the badge scan
        // and the expiry case (`watchdogFires == true`) proves the watchdog
        // branch itself suppressed the scan without dropping collected items.
        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                runtimeIndex += 1
                let id = runtimeIndex
                events.append("created-\(id)")
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        wake1CollectEntered.signal()
                        try await wake1CollectRelease.wait()
                        return BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wake1Extra, wake1Primary, wake1Disabled],
                            error: nil
                        )
                    },
                    onApplicationBadgeCount: {
                        badgeCalls.withLock { $0 += 1 }
                        return 9
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
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            now: { clock.now() },
            sleep: { _ in
                if watchdogFires {
                    try await triggerWatchdog.wait()
                    watchdogFired.signal()
                } else {
                    try await parkUntilCancelled()
                }
            },
            submitAdditionalPresentation: { presentation, _ in
                additionalTitles.withLock { $0.append(presentation.title) }
                extraSubmitted.signal()
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

        if watchdogFires {
            // Fire the proactive watchdog while `collectNotificationsAfterWake`
            // is still in flight. Because `sleep` runs on `@MainActor`,
            // returning from `sleep` executes `handleProactiveWatchdogExpiration`
            // in the same MainActor turn before `watchdogFired.wait()` resumes.
            triggerWatchdog.signal()
            try await watchdogFired.wait()

            #expect(wake1Contents.isEmpty)
            #expect(runtimeIndex == 1)
        }

        wake1CollectRelease.signal()
        try await wake1Delivered.wait()
        try await extraSubmitted.wait()

        #expect(wake1Contents.count == 1)
        #expect(wake1Contents.first?.title == "Alice")
        #expect(wake1Contents.first?.body == "Kept past watchdog")
        #expect(additionalTitles.withLock { $0 } == ["Bob"])
        if watchdogFires {
            #expect(wake1Contents.first?.badge == nil)
            #expect(badgeCalls.withLock { $0 } == 0)
        } else {
            #expect(wake1Contents.first?.badge == 9)
            #expect(badgeCalls.withLock { $0 } == 1)
        }
    }

    @Test func wakeCoordinatorCountsPreStartMainActorDelayAgainstProactiveBudget() async throws {
        let events = WakeEventLog()
        let clock = MutableContinuousClock(initial: ContinuousClock.now)
        let observedMaxWaitMs = Mutex<UInt32?>(nil)
        let observedWatchdogSleep = Mutex<Duration?>(nil)
        let badgeCalls = Mutex(0)
        let delivered = TestLatch()
        var deliveredContents: [UNNotificationContent] = []

        let update = notificationUpdate(
            notificationKey: "prestart-delay-msg",
            senderName: "Alice",
            previewText: "Budget started at didReceive",
            timestampMs: 5_000
        )

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                events.append("created-1")
                return FakeNotificationServiceWakeRuntime(
                    id: 1,
                    events: events,
                    onCollect: { maxWaitMs in
                        observedMaxWaitMs.withLock { $0 = maxWaitMs }
                        return BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [update],
                            error: nil
                        )
                    },
                    onApplicationBadgeCount: {
                        badgeCalls.withLock { $0 += 1 }
                        return 3
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            now: { clock.now() },
            sleep: { duration in
                observedWatchdogSleep.withLock { $0 = duration }
                try await parkUntilCancelled()
            },
            submitAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let request = UNNotificationRequest(identifier: "prestart-delay", content: UNNotificationContent(), trigger: nil)

        // `didReceive` accepts the wake at T0 and queues the MainActor drain.
        coordinator.didReceive(request, ownerID: owner) { content in
            deliveredContents.append(content)
            delivered.signal()
        }
        // Simulate 14 s of synchronous MainActor contention before the drain
        // constructs the session: only 4 s remain out of the 18 s budget.
        clock.advance(by: .seconds(14))

        try await delivered.wait()

        #expect(observedWatchdogSleep.withLock { $0 } == .seconds(4))
        #expect(observedMaxWaitMs.withLock { $0 } == 4_000)
        #expect(badgeCalls.withLock { $0 } == 0)
        #expect(deliveredContents.count == 1)
        #expect(deliveredContents.first?.title == "Alice")
        #expect(deliveredContents.first?.badge == nil)
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

    @Test func wakeCoordinatorSubmitsBoundedExtrasBeforeShutdownEvenOnHardExpiry() async throws {
        let events = WakeEventLog()
        let clock = MutableContinuousClock(initial: ContinuousClock.now)
        let shutdownEntered = TestLatch()
        let shutdownRelease = TestLatch()
        defer { shutdownRelease.signal() }
        let deliveredTitles = Mutex<[String]>([])
        let deliveredBodies = Mutex<[String]>([])
        let deliveredBadges = Mutex<[Int?]>([])
        let submittedExtras = Mutex<[(title: String, badge: Int?)]>([])

        let primary = notificationUpdate(
            notificationKey: "sync-extra-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Primary prepared before shutdown",
            timestampMs: 5_000
        )
        let extra1 = notificationUpdate(
            notificationKey: "sync-extra-1",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Bob",
            previewText: "First extra",
            timestampMs: 4_000
        )
        let extra2 = notificationUpdate(
            notificationKey: "sync-extra-2",
            groupIdHex: String(repeating: "33", count: 16),
            senderName: "Carol",
            previewText: "Second extra",
            timestampMs: 3_000
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
                            notifications: [extra2, extra1, primary],
                            error: nil
                        )
                    },
                    onApplicationBadgeCount: { 7 },
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
            now: { clock.now() },
            sleep: { _ in try await parkUntilCancelled() },
            submitAdditionalPresentation: { presentation, badgeCount in
                events.append("extra-\(presentation.title)")
                submittedExtras.withLock { $0.append((presentation.title, badgeCount)) }
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let request = UNNotificationRequest(identifier: "sync-extra-exp", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(request, ownerID: owner) { content in
            deliveredTitles.withLock { $0.append(content.title) }
            deliveredBodies.withLock { $0.append(content.body) }
            deliveredBadges.withLock { $0.append(content.badge?.intValue) }
        }

        // Wait until shutdown starts: primary snapshot must already be frozen
        // and bounded extras must ALREADY have been handed off synchronously
        // before `shutdownAndClose()` started.
        try await shutdownEntered.wait()
        let extras = submittedExtras.withLock { $0 }
        #expect(Set(extras.map(\.title)) == ["Bob", "Carol"])
        #expect(extras.allSatisfy { $0.badge == 7 })
        let snapshot = events.snapshot()
        let extraBob = try #require(snapshot.firstIndex(of: "extra-Bob"))
        let extraCarol = try #require(snapshot.firstIndex(of: "extra-Carol"))
        let shutdownStart = try #require(snapshot.firstIndex(of: "shutdown-start-1"))
        #expect(extraBob < shutdownStart)
        #expect(extraCarol < shutdownStart)
        #expect(!snapshot.contains("shutdown-done-1"))

        // Fire hard expiration from a dedicated background thread (matching
        // Apple's contract without queuing behind GCD's global concurrent pool)
        // while shutdown is still parked: primary must deliver synchronously
        // with the prepared decorated snapshot and badge.
        let bgExpiryDone = TestLatch()
        let titlesAtExpiryReturn = Mutex<[String]>([])
        let bodiesAtExpiryReturn = Mutex<[String]>([])
        let badgesAtExpiryReturn = Mutex<[Int?]>([])
        Self.runOnBackgroundThread {
            coordinator.serviceExtensionTimeWillExpire(ownerID: owner)
            titlesAtExpiryReturn.withLock { $0 = deliveredTitles.withLock { $0 } }
            bodiesAtExpiryReturn.withLock { $0 = deliveredBodies.withLock { $0 } }
            badgesAtExpiryReturn.withLock { $0 = deliveredBadges.withLock { $0 } }
            bgExpiryDone.signal()
        }
        try await bgExpiryDone.wait()
        #expect(titlesAtExpiryReturn.withLock { $0 } == ["Alice"])
        #expect(bodiesAtExpiryReturn.withLock { $0 } == ["Primary prepared before shutdown"])
        #expect(badgesAtExpiryReturn.withLock { $0 } == [7])
        #expect(deliveredTitles.withLock { $0 } == ["Alice"])
    }

    @Test func wakeCoordinatorHandlesBackgroundThreadExpirationCompetingWithNormalDelivery() async throws {
        let events = WakeEventLog()
        let clock = MutableContinuousClock(initial: ContinuousClock.now)
        let deliveryCount = Mutex(0)
        let deliveredTitles = Mutex<[String]>([])
        let deliveredBodies = Mutex<[String]>([])
        let deliveredFromBackgroundThread = Mutex(false)
        let shutdownRelease = TestLatch()
        defer { shutdownRelease.signal() }
        let shutdownEntered = TestLatch()
        let delivered = TestLatch()

        let update = notificationUpdate(
            notificationKey: "bg-race-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Prepared before thread race",
            timestampMs: 5_000
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
                            notifications: [update],
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
            now: { clock.now() },
            sleep: { _ in try await parkUntilCancelled() },
            submitAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let request = UNNotificationRequest(identifier: "bg-race", content: UNNotificationContent(), trigger: nil)

        // Dispatch `didReceive` itself from a dedicated background thread,
        // matching iOS without stalling behind GCD's global concurrent pool.
        Self.runOnBackgroundThread {
            coordinator.didReceive(request, ownerID: owner) { content in
                deliveredTitles.withLock { $0.append(content.title) }
                deliveredBodies.withLock { $0.append(content.body) }
                deliveryCount.withLock { $0 += 1 }
                if !Thread.isMainThread {
                    deliveredFromBackgroundThread.withLock { $0 = true }
                }
                delivered.signal()
            }
        }
        try await shutdownEntered.wait()

        // Race background-thread hard expiration against releasing normal
        // completion on MainActor: the handler must run exactly once.
        let bgDone = TestLatch()
        Self.runOnBackgroundThread {
            coordinator.serviceExtensionTimeWillExpire(ownerID: owner)
            bgDone.signal()
        }
        shutdownRelease.signal()

        try await bgDone.wait()
        try await delivered.wait()
        await Task.yield()

        #expect(deliveryCount.withLock { $0 } == 1)
        #expect(deliveredTitles.withLock { $0 } == ["Alice"])
        #expect(deliveredBodies.withLock { $0 } == ["Prepared before thread race"])
    }

    @Test(arguments: [true, false])
    func wakeCoordinatorAppliesBadgeCountOnlyWhileProactiveBudgetRemains(
        withinBudget: Bool
    ) async throws {
        let events = WakeEventLog()
        let clock = MutableContinuousClock(initial: ContinuousClock.now)
        let badgeCalls = Mutex(0)
        let delivered = TestLatch()
        var deliveredContents: [UNNotificationContent] = []
        let extraBadges = Mutex<[Int?]>([])

        let primary = notificationUpdate(
            notificationKey: "badge-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Primary badge check",
            timestampMs: 5_000
        )
        let extra = notificationUpdate(
            notificationKey: "badge-extra",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Bob",
            previewText: "Extra badge check",
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
                    onApplicationBadgeCount: {
                        badgeCalls.withLock { $0 += 1 }
                        return 5
                    }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: withinBudget
                ? NotificationServiceTimeoutPolicy.proactiveExpirationDelay
                : .seconds(5),
            now: { clock.now() },
            sleep: { _ in try await parkUntilCancelled() },
            submitAdditionalPresentation: { _, badgeCount in
                extraBadges.withLock { $0.append(badgeCount) }
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let request = UNNotificationRequest(identifier: "badge-check", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(request, ownerID: owner) { content in
            deliveredContents.append(content)
            delivered.signal()
        }
        try await delivered.wait()

        #expect(deliveredContents.count == 1)
        #expect(deliveredContents.first?.title == "Alice")
        if withinBudget {
            #expect(badgeCalls.withLock { $0 } == 1)
            #expect(deliveredContents.first?.badge == 5)
            #expect(extraBadges.withLock { $0 } == [5])
        } else {
            #expect(badgeCalls.withLock { $0 } == 0)
            #expect(deliveredContents.first?.badge == nil)
            #expect(extraBadges.withLock { $0 } == [nil])
        }
    }

    @Test func wakeCoordinatorHardExpirationOfWakeADoesNotCancelWakeBStartingOnSameInstance() async throws {
        let events = WakeEventLog()
        let wakeACollectEntered = TestLatch()
        let wakeACollectRelease = TestLatch()
        defer { wakeACollectRelease.signal() }
        let wakeAShutdownEntered = TestLatch()
        let wakeAShutdownRelease = TestLatch()
        defer { wakeAShutdownRelease.signal() }
        let wakeBDelivered = TestLatch()
        var wakeAContents: [UNNotificationContent] = []
        var wakeBContents: [UNNotificationContent] = []
        var runtimeIndex = 0

        let wakeBUpdate = notificationUpdate(
            notificationKey: "same-owner-wake-b",
            senderName: "Eve",
            previewText: "Wake B survived wake A expiration on same owner",
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
                            wakeACollectEntered.signal()
                            try await wakeACollectRelease.wait()
                            return BackgroundNotificationCollectionFfi(status: .noData, notifications: [], error: nil)
                        },
                        onShutdown: {
                            wakeAShutdownEntered.signal()
                            await wakeAShutdownRelease.hold()
                            wakeACollectRelease.signal()
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
            submitAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let reusedOwner = UUID()
        let reqA = UNNotificationRequest(identifier: "same-owner-a", content: UNNotificationContent(), trigger: nil)
        let reqB = UNNotificationRequest(identifier: "same-owner-b", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(reqA, ownerID: reusedOwner) { content in
            wakeAContents.append(content)
        }
        try await wakeACollectEntered.wait()

        // Expire wake A synchronously AND immediately register wake B on the
        // SAME `ownerID` before wake A's asynchronous MainActor cleanup runs.
        // Wake A's cleanup is scoped to wake A's delivery ID and must never
        // cancel wake B or drop wake A's runtime shutdown barrier.
        coordinator.serviceExtensionTimeWillExpire(ownerID: reusedOwner)
        coordinator.didReceive(reqB, ownerID: reusedOwner) { content in
            wakeBContents.append(content)
            wakeBDelivered.signal()
        }

        #expect(wakeAContents.count == 1)
        #expect(wakeAContents.first?.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)
        try await wakeAShutdownEntered.wait()
        await Task.yield()
        #expect(runtimeIndex == 1)
        #expect(wakeBContents.isEmpty)

        wakeAShutdownRelease.signal()
        try await wakeBDelivered.wait()

        #expect(wakeAContents.count == 1)
        #expect(wakeBContents.count == 1)
        #expect(wakeBContents.first?.title == "Eve")
        #expect(wakeBContents.first?.body == "Wake B survived wake A expiration on same owner")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorScopesHardExpirationToOwningExtensionInstanceWhileSerializingShutdown() async throws {
        let events = WakeEventLog()
        let instanceACollectEntered = TestLatch()
        let instanceACollectRelease = TestLatch()
        defer { instanceACollectRelease.signal() }
        let instanceAShutdownEntered = TestLatch()
        let instanceAShutdownRelease = TestLatch()
        defer { instanceAShutdownRelease.signal() }
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
            submitAdditionalPresentation: { _, _ in }
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
        // inside collection; B parks behind A's storage-close barrier.
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
        defer { wake1StartRelease.signal() }
        let wake1ShutdownEntered = TestLatch()
        let wake1ShutdownRelease = TestLatch()
        defer { wake1ShutdownRelease.signal() }
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
            submitAdditionalPresentation: { _, _ in }
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

    @Test func wakeCoordinatorCancelsReplacedWaitingWakeWithoutWaitingForStalledPriorShutdown() async throws {
        let events = WakeEventLog()
        let wakeAStartEntered = TestLatch()
        let wakeAStartRelease = TestLatch()
        defer { wakeAStartRelease.signal() }
        let wakeAShutdownEntered = TestLatch()
        let wakeAShutdownRelease = TestLatch()
        defer { wakeAShutdownRelease.signal() }
        let wakeADelivered = TestLatch()
        let wakeBDelivered = TestLatch()
        let wakeBContentDeallocated = TestLatch()
        let wakeCDelivered = TestLatch()
        var wakeBDispositions: [String?] = []
        var wakeCContents: [UNNotificationContent] = []
        var runtimeIndex = 0

        let wakeCUpdate = notificationUpdate(
            notificationKey: "wake-c-after-replaced-b",
            senderName: "Grace",
            previewText: "Wake C still respected A's barrier",
            timestampMs: 8_000
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
                            wakeAStartEntered.signal()
                            try await wakeAStartRelease.wait()
                        },
                        onCollect: { _ in
                            BackgroundNotificationCollectionFfi(status: .noData, notifications: [], error: nil)
                        },
                        onShutdown: {
                            wakeAShutdownEntered.signal()
                            await wakeAShutdownRelease.hold()
                            wakeAStartRelease.signal()
                        }
                    )
                }
                return FakeNotificationServiceWakeRuntime(
                    id: id,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [wakeCUpdate],
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
            submitAdditionalPresentation: { _, _ in }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        let owner = UUID()
        let reqA = UNNotificationRequest(identifier: "stall-a", content: UNNotificationContent(), trigger: nil)
        let reqC = UNNotificationRequest(identifier: "stall-c", content: UNNotificationContent(), trigger: nil)

        coordinator.didReceive(reqA, ownerID: owner) { _ in wakeADelivered.signal() }
        try await wakeAStartEntered.wait()

        // Wake B replaces wake A (putting A into a stalled shutdown) and parks
        // on A's barrier. Scope `reqB` and its `DeinitProbe` locally so the
        // coordinator/session/task are the only owners of wake B's content.
        do {
            let probe = DeinitProbe {
                wakeBContentDeallocated.signal()
            }
            let trackedContent = TrackedNotificationContent(probe: probe)
            let reqB = UNNotificationRequest(identifier: "stall-b", content: trackedContent, trigger: nil)
            coordinator.didReceive(reqB, ownerID: owner) { content in
                wakeBDispositions.append(
                    content.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
                )
                wakeBDelivered.signal()
            }
        }
        try await wakeAShutdownEntered.wait()

        // Wake C replaces wake B while wake A's shutdown is STILL stalled.
        // Wake B must immediately deliver fallback AND exit its barrier wait
        // (releasing its waiting task, session, and content) without waiting
        // for wake A or cancelling wake A's close barrier for wake C.
        coordinator.didReceive(reqC, ownerID: owner) { content in
            wakeCContents.append(content)
            wakeCDelivered.signal()
        }

        try await wakeBDelivered.wait()
        try await wakeBContentDeallocated.wait()

        #expect(wakeBDispositions == [LocalNotificationProjection.fallbackDisposition])
        #expect(runtimeIndex == 1)
        #expect(wakeCContents.isEmpty)

        // Now release wake A's shutdown: wake C proceeds strictly after A closes.
        wakeAShutdownRelease.signal()
        try await wakeADelivered.wait()
        try await wakeCDelivered.wait()

        #expect(wakeCContents.count == 1)
        #expect(wakeCContents.first?.title == "Grace")
        #expect(wakeCContents.first?.body == "Wake C still respected A's barrier")

        let recordedEvents = events.snapshot()
        let shutdown1Done = try #require(recordedEvents.firstIndex(of: "shutdown-done-1"))
        let created2 = try #require(recordedEvents.firstIndex(of: "created-2"))
        #expect(shutdown1Done < created2)
    }

    @Test func wakeCoordinatorHardExpiryDuringFirstExtraSubmissionStillDeliversPreparedPrimary() async throws {
        let events = WakeEventLog()
        let clock = MutableContinuousClock(initial: ContinuousClock.now)
        let deliveredTitles = Mutex<[String]>([])
        let deliveredBodies = Mutex<[String]>([])
        let deliveredBadges = Mutex<[Int?]>([])
        let deliveredOffMainThread = Mutex(false)
        let expiryRanOffMainThread = Mutex(false)
        let expiryWaitResult = Mutex<DispatchTimeoutResult?>(nil)
        let submittedExtras = Mutex<[String]>([])
        let expiryFinished = TestLatch()

        let primary = notificationUpdate(
            notificationKey: "mid-extra-primary",
            groupIdHex: String(repeating: "11", count: 16),
            senderName: "Alice",
            previewText: "Frozen before extras",
            timestampMs: 5_000
        )
        let extra1 = notificationUpdate(
            notificationKey: "mid-extra-1",
            groupIdHex: String(repeating: "22", count: 16),
            senderName: "Bob",
            previewText: "First extra triggers expiry",
            timestampMs: 4_000
        )

        var coordinatorRef: NotificationServiceWakeCoordinator?
        let owner = UUID()

        let environment = NotificationServiceWakeEnvironment(
            makeRuntime: {
                events.append("created-1")
                return FakeNotificationServiceWakeRuntime(
                    id: 1,
                    events: events,
                    onCollect: { _ in
                        BackgroundNotificationCollectionFfi(
                            status: .newData,
                            notifications: [extra1, primary],
                            error: nil
                        )
                    },
                    onApplicationBadgeCount: { 4 }
                )
            },
            auditLogSource: { AuditLogSourceBuildConfig.current() },
            loadPolicySnapshot: Self.allVisiblePolicySnapshot,
            maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
            proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
            now: { clock.now() },
            sleep: { _ in try await parkUntilCancelled() },
            submitAdditionalPresentation: { presentation, _ in
                submittedExtras.withLock { $0.append(presentation.title) }
                // Run hard expiration on a dedicated background pthread while
                // keeping this MainActor extra submission on the stack so the
                // test proves `serviceExtensionTimeWillExpire` never blocks on
                // MainActor without starving behind GCD's global concurrent
                // queue under parallel test load.
                if let coordinator = coordinatorRef {
                    let semaphore = DispatchSemaphore(value: 0)
                    Self.runOnBackgroundThread {
                        expiryRanOffMainThread.withLock { $0 = !Thread.isMainThread }
                        coordinator.serviceExtensionTimeWillExpire(ownerID: owner)
                        semaphore.signal()
                    }
                    let waited = semaphore.wait(timeout: .now() + .seconds(15))
                    expiryWaitResult.withLock { $0 = waited }
                    expiryFinished.signal()
                }
            }
        )

        let coordinator = NotificationServiceWakeCoordinator(environment: environment)
        coordinatorRef = coordinator
        let request = UNNotificationRequest(identifier: "mid-extra-exp", content: UNNotificationContent(), trigger: nil)

        // Dispatch `didReceive` itself from a dedicated background thread to
        // verify nonisolated entry under Swift 6.2 default `@MainActor`
        // isolation without queuing behind GCD's global concurrent pool.
        Self.runOnBackgroundThread {
            coordinator.didReceive(request, ownerID: owner) { content in
                deliveredOffMainThread.withLock { $0 = !Thread.isMainThread }
                deliveredTitles.withLock { $0.append(content.title) }
                deliveredBodies.withLock { $0.append(content.body) }
                deliveredBadges.withLock { $0.append(content.badge?.intValue) }
            }
        }

        try await expiryFinished.wait()
        await Task.yield()

        #expect(expiryWaitResult.withLock { $0 } == .success)
        #expect(expiryRanOffMainThread.withLock { $0 })
        #expect(deliveredOffMainThread.withLock { $0 })
        #expect(submittedExtras.withLock { $0 } == ["Bob"])
        #expect(deliveredTitles.withLock { $0 } == ["Alice"])
        #expect(deliveredBodies.withLock { $0 } == ["Frozen before extras"])
        #expect(deliveredBadges.withLock { $0 } == [4])
    }

    private nonisolated static func runOnBackgroundThread(_ body: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            body()
        }
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

nonisolated private final class MutableContinuousClock: Sendable {
    private let current: Mutex<ContinuousClock.Instant>

    init(initial: ContinuousClock.Instant) {
        current = Mutex(initial)
    }

    func now() -> ContinuousClock.Instant {
        current.withLock { $0 }
    }

    func advance(by duration: Duration) {
        current.withLock { $0 = $0.advanced(by: duration) }
    }
}

nonisolated private final class DeinitProbe: Sendable {
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

nonisolated private final class TrackedNotificationContent: UNMutableNotificationContent {
    private let probe: DeinitProbe

    init(probe: DeinitProbe) {
        self.probe = probe
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = TrackedNotificationContent(probe: probe)
        copy.title = title
        copy.body = body
        copy.userInfo = userInfo
        return copy
    }

    override func mutableCopy(with zone: NSZone? = nil) -> Any {
        copy(with: zone)
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
