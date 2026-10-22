import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct NativePushEnableCoordinatorTests {

    @Test func enableWritesPreferenceBeforeSyncingRegistration() async throws {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            syncPushRegistration: {
                operations.append("sync")
            }
        )

        let settings = try await coordinator.enable()

        #expect(settings.nativePushEnabled == true)
        #expect(operations == ["set:true", "sync"])
    }

    @Test func enableDoesNotSyncRegistrationWhenPreferenceWriteFails() async {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                throw NativePushEnableTestError.writeFailed
            },
            syncPushRegistration: {
                operations.append("sync")
            }
        )

        do {
            _ = try await coordinator.enable()
            Issue.record("Expected preference write failure")
        } catch {
            #expect(error as? NativePushEnableTestError == .writeFailed)
        }

        #expect(operations == ["set:true"])
    }

    @Test func enableKeepsPreferenceOnWhenWaitingForApnsToken() async throws {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            syncPushRegistration: {
                operations.append("sync")
                throw NotificationSettingsActionError.missingApnsToken
            }
        )

        let settings = try await coordinator.enable()

        #expect(settings.nativePushEnabled == true)
        #expect(operations == ["set:true", "sync"])
    }

    @Test func enableRollsPreferenceBackWhenRegistrationSyncFails() async {
        var operations: [String] = []
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            syncPushRegistration: {
                operations.append("sync")
                throw NativePushEnableTestError.syncFailed
            }
        )

        do {
            _ = try await coordinator.enable()
            Issue.record("Expected registration sync failure")
        } catch {
            #expect(error as? NativePushEnableTestError == .syncFailed)
        }

        #expect(operations == ["set:true", "sync", "set:false"])
    }

    private static func settings(nativePushEnabled: Bool) -> NotificationSettingsFfi {
        NotificationSettingsFfi(
            accountRef: "account-a",
            accountIdHex: hex("11"),
            localNotificationsEnabled: true,
            nativePushEnabled: nativePushEnabled
        )
    }
}

private enum NativePushEnableTestError: Error, Equatable {
    case writeFailed
    case syncFailed
}
