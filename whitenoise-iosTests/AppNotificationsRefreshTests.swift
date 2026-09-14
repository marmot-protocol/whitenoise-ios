import Foundation
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
        var removedIdentifiers: [String] = []
        let notifications = AppNotifications(
            deliveredNotificationDescriptorsProvider: { Self.deliveredDescriptors() },
            deliveredNotificationIdentifiersRemover: { removedIdentifiers = $0 }
        )

        await notifications.reconcileDeliveredNotificationsAfterRead(
            accountRef: "account-a",
            groupIdHex: "group-a",
            readMessageIdHexes: ["message-2"],
            conversationStillHasUnread: false
        )

        #expect(removedIdentifiers == ["request-1", "request-2"])
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
