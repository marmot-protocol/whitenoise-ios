import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios
import UserNotifications

@MainActor
struct AppNotificationsRefreshTests {
    @Test func partialConversationReadRemovesOnlyTheConfirmedMessages() {
        let notifications = Self.deliveredDescriptors()

        let identifiers = DeliveredNotificationReadCleanupPolicy.identifiersToRemove(
            from: notifications,
            accountRef: "account-a",
            groupIdHex: "group-a",
            readMessageIdHexes: ["message-2"],
            removeEntireConversation: false
        )

        #expect(identifiers == ["request-2"])
    }

    @Test func fullyReadConversationRemovesItsMessageStackWithoutCrossingRoutes() {
        let identifiers = DeliveredNotificationReadCleanupPolicy.identifiersToRemove(
            from: Self.deliveredDescriptors(),
            accountRef: "account-a",
            groupIdHex: "group-a",
            readMessageIdHexes: ["message-2"],
            removeEntireConversation: true
        )

        #expect(identifiers == ["request-1", "request-2"])
    }

    @Test func deliveredNotificationReconciliationUsesSystemRequestIdentifiers() async {
        let removedIdentifiers = Mutex<[String]>([])
        let notifications = AppNotifications(
            deliveredNotificationDescriptorsProvider: { Self.deliveredDescriptors() },
            deliveredNotificationIdentifiersRemover: { identifiers in
                removedIdentifiers.withLock { $0 = identifiers }
            }
        )

        await notifications.reconcileDeliveredNotificationsAfterRead(
            accountRef: "account-a",
            groupIdHex: "group-a",
            readMessageIdHexes: ["message-2"],
            conversationStillHasUnread: false
        )
        await notifications.drainNotificationCenterMutations()

        #expect(removedIdentifiers.withLock { $0 } == ["request-1", "request-2"])
    }

    /// The pending-request removal is a blocking XPC round trip; sign-out calls
    /// this on the main actor, so it must return while the removal is stuck.
    @Test func cancellingForegroundBatchesDoesNotBlockTheMainActorOnNotificationCenter() async {
        let release = DispatchSemaphore(value: 0)
        let removals = Mutex<[(identifiers: [String], onMainThread: Bool, timedOut: Bool)]>([])
        var scheduled: [String] = []
        let notifications = AppNotifications(
            pendingNotificationRequestsRemover: { identifiers in
                let onMainThread = Thread.isMainThread
                let timedOut = release.wait(timeout: .now() + 5) == .timedOut
                removals.withLock { $0.append((identifiers, onMainThread, timedOut)) }
            },
            notificationRequestScheduler: { scheduled.append($0.identifier) },
            notificationClock: { 10 }
        )
        await notifications.present(update: Self.messageUpdate("message-1"))
        let batchIdentifier = ForegroundNotificationBatch.identifier(account: "account-a", group: "group-a")

        notifications.cancelForegroundBatches(accountRef: "account-a")
        release.signal()
        await notifications.drainNotificationCenterMutations()

        let recorded = removals.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.identifiers == [batchIdentifier])
        #expect(recorded.first?.onMainThread == false)
        #expect(recorded.first?.timedOut == false)
        #expect(scheduled == [batchIdentifier])
    }

    @Test func requestsScheduledAfterCancellationLandAfterTheRemoval() async {
        let events = Mutex<[String]>([])
        let notifications = AppNotifications(
            pendingNotificationRequestsRemover: { identifiers in
                // Models a slow synchronous removal, not a wait.
                // swiftlint:disable:next no_test_sleep
                Thread.sleep(forTimeInterval: 0.05)
                events.withLock { $0.append(contentsOf: identifiers.map { "remove \($0)" }) }
            },
            notificationRequestScheduler: { request in
                events.withLock { $0.append("add \(request.identifier)") }
            },
            notificationClock: { 10 }
        )
        let batchIdentifier = ForegroundNotificationBatch.identifier(account: "account-a", group: "group-a")

        await notifications.present(update: Self.messageUpdate("message-1"))
        notifications.cancelForegroundBatches(accountRef: "account-a")
        await notifications.present(update: Self.messageUpdate("message-2"))

        #expect(events.withLock { $0 } == [
            "add \(batchIdentifier)",
            "remove \(batchIdentifier)",
            "add \(batchIdentifier)",
        ])
    }

    @Test func cancellingWithoutPendingBatchesSkipsNotificationCenter() async {
        let removals = Mutex(0)
        let notifications = AppNotifications(
            pendingNotificationRequestsRemover: { _ in removals.withLock { $0 += 1 } }
        )

        notifications.cancelForegroundBatches(accountRef: "account-a")
        await notifications.drainNotificationCenterMutations()

        #expect(removals.withLock { $0 } == 0)
    }

    @Test func applicationBadgeWritesRemainInUnreadProjectionOrder() async {
        var appliedCounts: [Int] = []
        let notifications = AppNotifications(
            applicationBadgeCountSetter: { count in
                appliedCounts.append(count)
            }
        )

        notifications.scheduleApplicationBadgeCount(3)
        notifications.scheduleApplicationBadgeCount(8)
        notifications.scheduleApplicationBadgeCount(0)
        await notifications.drainApplicationBadgeUpdates()

        #expect(appliedCounts == [3, 8, 0])
    }

    @Test func refreshClearsCachedTokenBeforeReregistering() async throws {
        var clearedBeforeRegister = false
        var notifications: AppNotifications?
        let created = AppNotifications(
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {
                if notifications?.apnsTokenHex == nil {
                    clearedBeforeRegister = true
                    notifications?.recordDeviceToken(Data([0x01, 0x02]))
                }
            }
        )
        notifications = created
        created.recordDeviceToken(Data([0xab, 0xcd]))

        _ = try await created.refreshApnsToken(
            timeoutNanoseconds: 500_000_000,
            pollIntervalNanoseconds: 10_000_000
        )

        #expect(clearedBeforeRegister)
    }

    @Test func refreshReturnsTokenDeliveredAfterReregistration() async throws {
        var notifications: AppNotifications?
        let created = AppNotifications(
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {
                notifications?.recordDeviceToken(Data([0x01, 0x02]))
            }
        )
        notifications = created
        created.recordDeviceToken(Data([0xab, 0xcd]))

        let token = try await created.refreshApnsToken(
            timeoutNanoseconds: 500_000_000,
            pollIntervalNanoseconds: 10_000_000
        )
        #expect(token == "0102")
    }

    @Test func refreshThrowsWhenPermissionIsDenied() async {
        let notifications = AppNotifications(
            authorizationStatusProvider: { .denied },
            remoteNotificationRegistrar: {
                Issue.record("should not request remote registration when permission is denied")
            }
        )
        notifications.recordDeviceToken(Data([0x01]))

        do {
            _ = try await notifications.refreshApnsToken(
                timeoutNanoseconds: 50_000_000,
                pollIntervalNanoseconds: 10_000_000
            )
            Issue.record("expected permissionDenied")
        } catch let error as NotificationSettingsActionError {
            guard case .permissionDenied = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(notifications.apnsTokenHex == "01")
    }

    @Test func refreshThrowsWhenRegistrationFails() async {
        // Inject the failure through the registrar so it is recorded after
        // refreshApnsToken clears prior state, rather than racing a fixed sleep
        // against task scheduling (which flakes under load).
        var notifications: AppNotifications?
        let created = AppNotifications(
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {
                notifications?.recordRegistrationFailure(
                    NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulator unavailable"])
                )
            }
        )
        notifications = created
        created.recordDeviceToken(Data([0x01]))

        do {
            _ = try await created.refreshApnsToken(
                timeoutNanoseconds: 500_000_000,
                pollIntervalNanoseconds: 10_000_000
            )
            Issue.record("expected refresh to fail when APNS registration fails")
        } catch let error as NotificationSettingsActionError {
            guard case let .apnsRegistrationFailed(message) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(message == "Simulator unavailable")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func refreshThrowsWhenTokenDoesNotArriveInTime() async {
        let notifications = AppNotifications(
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {}
        )
        notifications.recordDeviceToken(Data([0x01]))

        do {
            _ = try await notifications.refreshApnsToken(
                timeoutNanoseconds: 50_000_000,
                pollIntervalNanoseconds: 10_000_000
            )
            Issue.record("expected apnsTokenRefreshTimedOut")
        } catch let error as NotificationSettingsActionError {
            guard case .apnsTokenRefreshTimedOut = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(notifications.apnsTokenHex == nil)
    }

    private static func messageUpdate(_ messageIdHex: String) -> NotificationUpdateFfi {
        NotificationUpdateFfi(notificationKey: messageIdHex, conversationKey: "chat", trigger: .newMessage,
            accountRef: "account-a", accountIdHex: "owner", groupIdHex: "group-a", groupName: "Group", isDm: false,
            isMention: false, messageIdHex: messageIdHex,
            sender: NotificationUserFfi(accountIdHex: "sender", displayName: "Alice", pictureUrl: nil),
            receiver: NotificationUserFfi(accountIdHex: "owner", displayName: "Me", pictureUrl: nil),
            previewText: "Hi", reactionEmoji: nil, reactedToPreview: nil, timestampMs: 1, isFromSelf: false)
    }

    private static func deliveredDescriptors() -> [DeliveredNotificationDescriptor] {
        [
            descriptor(identifier: "request-1", messageIdHex: "message-1"),
            descriptor(identifier: "request-2", messageIdHex: "message-2"),
            descriptor(identifier: "other-group", groupIdHex: "group-b", messageIdHex: "message-3"),
            descriptor(identifier: "other-account", accountRef: "account-b", messageIdHex: "message-4"),
            descriptor(identifier: "action-failure", messageIdHex: "message-2", isActionFailure: true),
            DeliveredNotificationDescriptor(
                identifier: "group-invite",
                route: LocalNotificationRoute(
                    accountRef: "account-a",
                    groupIdHex: "group-a",
                    notificationKey: "invite",
                    messageIdHex: nil
                ),
                isMessageNotification: false,
                isActionFailure: false
            ),
        ]
    }

    private static func descriptor(
        identifier: String,
        accountRef: String = "account-a",
        groupIdHex: String = "group-a",
        messageIdHex: String,
        isActionFailure: Bool = false
    ) -> DeliveredNotificationDescriptor {
        DeliveredNotificationDescriptor(
            identifier: identifier,
            route: LocalNotificationRoute(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                notificationKey: "notification-\(identifier)",
                messageIdHex: messageIdHex
            ),
            isMessageNotification: true,
            isActionFailure: isActionFailure
        )
    }
}
