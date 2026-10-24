import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct AppStateGateTests {
    @Test func toastSleepDurationIsClampedBeforeNanosecondConversion() {
        #expect(ToastState.sleepNanoseconds(forDuration: -1) == 0)
        #expect(ToastState.sleepNanoseconds(forDuration: .nan) == 0)
        #expect(ToastState.sleepNanoseconds(forDuration: .infinity) == UInt64.max)
        #expect(ToastState.sleepNanoseconds(forDuration: 1.25) == 1_250_000_000)
        #expect(ToastState.sleepNanoseconds(
            forDuration: TimeInterval(UInt64.max) / 1_000_000_000
        ) == UInt64.max)
        #expect(ToastState.sleepNanoseconds(forDuration: .greatestFiniteMagnitude) == UInt64.max)
    }

    @Test func notificationPresentationRuntimeGateRequiresForegroundRuntime() {
        #expect(NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: true,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            isSigningOut: false,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: true,
            hasRuntimeClient: true
        ))
        #expect(!NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false,
            hasRuntimeClient: false
        ))
    }

    @Test func archivedNotificationCacheKeepsEntriesForInterleavedAccounts() {
        var cache = NotificationArchivedKeysCache()
        let now = ContinuousClock.now
        let lifetime: Duration = .seconds(2)
        cache.store(["group-a"], for: "account-a", readAt: now, lifetime: lifetime)
        cache.store(["group-b"], for: "account-b", readAt: now, lifetime: lifetime)

        #expect(cache.keys(for: "account-a", now: now, lifetime: lifetime) == ["group-a"])
        #expect(cache.keys(for: "account-b", now: now, lifetime: lifetime) == ["group-b"])
    }

    @Test func settingsReadRuntimeGateRejectsSuspensionWindows() {
        #expect(SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: true,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            hasRuntimeClient: true
        ))
        #expect(!SettingsReadRuntimeGate.canRead(
            isTaskCancelled: false,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: false
        ))
    }

    @Test func foregroundRuntimeWorkIsGatedDuringBackgroundSuspension() {
        #expect(ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            hasRuntimeClient: true
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: false
        ))

        #expect(ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false
        ))
        #expect(!ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true
        ))
    }

    @Test func chatListSubscriptionScopeChangesWhenSceneBecomesActive() {
        let inactive = ChatsListView.SubscriptionScope(
            accountRef: "account-a",
            runtimeGeneration: 4,
            isAppSceneActive: false
        )
        let active = ChatsListView.SubscriptionScope(
            accountRef: "account-a",
            runtimeGeneration: 4,
            isAppSceneActive: true
        )

        #expect(inactive != active)
    }

    @Test func nativePushRegistrationScheduleGateBlocksDuringSignOut() {
        // Regression for issue #320: a system-driven APNS device-token callback
        // (`recordDeviceToken`) can land on one of `signOut()`'s `await`
        // suspension points and call `scheduleNativePushRegistrationIfEnabled()`.
        // While the departing account is still on disk (push enabled) and still
        // in the in-memory `accounts` list, that fresh sync would
        // re-`upsertPushRegistration` it — resurrecting a server-side push
        // registration for a signed-out account (residual of #7/#111). The
        // sign-out guard must suppress scheduling, exactly like the existing
        // scene-inactive / runtime-suspended guards.
        #expect(NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false
        ))
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: true
        ))
        // The pre-existing guards must keep blocking regardless of the new flag.
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            isSigningOut: false
        ))
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: true,
            isRuntimeSuspending: false,
            isSigningOut: false
        ))
        #expect(!NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: true,
            isSigningOut: false
        ))
    }
}
