import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct NativePushDisableCoordinatorTests {

    @Test func disableWritesPreferenceBeforeClearingRegistration() async throws {
        var operations: [String] = []
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            clearPushRegistration: {
                operations.append("clear")
            }
        )

        let settings = try await coordinator.disable()

        #expect(settings.nativePushEnabled == false)
        #expect(operations == ["set:false", "clear"])
    }

    @Test func disableDoesNotClearRegistrationWhenPreferenceWriteFails() async {
        var operations: [String] = []
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                throw NativePushDisableTestError.writeFailed
            },
            clearPushRegistration: {
                operations.append("clear")
            }
        )

        do {
            _ = try await coordinator.disable()
            Issue.record("Expected preference write failure")
        } catch {
            #expect(error as? NativePushDisableTestError == .writeFailed)
        }

        #expect(operations == ["set:false"])
    }

    @Test func disableRollsPreferenceBackWhenRegistrationClearFails() async {
        var operations: [String] = []
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { enabled in
                operations.append("set:\(enabled)")
                return Self.settings(nativePushEnabled: enabled)
            },
            clearPushRegistration: {
                operations.append("clear")
                throw NativePushDisableTestError.clearFailed
            }
        )

        do {
            _ = try await coordinator.disable()
            Issue.record("Expected registration clear failure")
        } catch {
            #expect(error as? NativePushDisableTestError == .clearFailed)
        }

        #expect(operations == ["set:false", "clear", "set:true"])
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

private enum NativePushDisableTestError: Error, Equatable {
    case writeFailed
    case clearFailed
}
