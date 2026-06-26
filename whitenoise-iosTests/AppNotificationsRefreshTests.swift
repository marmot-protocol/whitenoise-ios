import Foundation
import Testing
@testable import whitenoise_ios
import UserNotifications

@MainActor
struct AppNotificationsRefreshTests {
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

    @Test func refreshThrowsWhenRegistrationFails() async throws {
        let notifications = AppNotifications(
            authorizationStatusProvider: { .authorized },
            remoteNotificationRegistrar: {}
        )
        notifications.recordDeviceToken(Data([0x01]))

        let refreshTask = Task {
            try await notifications.refreshApnsToken(
                timeoutNanoseconds: 10_000_000_000,
                pollIntervalNanoseconds: 10_000_000
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        notifications.recordRegistrationFailure(
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulator unavailable"])
        )

        do {
            _ = try await refreshTask.value
            Issue.record("expected refresh to fail when APNS registration fails")
        } catch let error as NotificationSettingsActionError {
            guard case let .apnsRegistrationFailed(message) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(message == "simulator unavailable")
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
}
