import Foundation
import Testing
@testable import darkmatter_ios

/// Focused coverage for the re-entrancy contract behind `NotificationSettingsViewModel`.
/// The view model funnels every mutating action through `NotificationActionGate`, so
/// these tests pin the gate's serialization guarantee directly — no `AppState` needed.
@MainActor
struct NotificationActionGateTests {
    @Test func tryBeginSucceedsWhenIdle() {
        var gate = NotificationActionGate()
        #expect(gate.isRunning == false)
        #expect(gate.tryBegin() == true)
        #expect(gate.isRunning == true)
    }

    @Test func tryBeginRejectsWhileRunning() {
        var gate = NotificationActionGate()
        #expect(gate.tryBegin() == true)
        // A second action arriving while the first is in flight must be rejected,
        // so it cannot start an overlapping mutation.
        #expect(gate.tryBegin() == false)
        #expect(gate.isRunning == true)
    }

    @Test func endReleasesGateForNextAction() {
        var gate = NotificationActionGate()
        #expect(gate.tryBegin() == true)
        gate.end()
        #expect(gate.isRunning == false)
        // Once released, a subsequent action may claim the gate again.
        #expect(gate.tryBegin() == true)
    }

    @Test func repeatedRejectionsDoNotReleaseTheGate() {
        var gate = NotificationActionGate()
        #expect(gate.tryBegin() == true)
        // Rapid repeated taps each fail and leave the in-flight action's claim intact.
        #expect(gate.tryBegin() == false)
        #expect(gate.tryBegin() == false)
        #expect(gate.isRunning == true)
        // Only the original action's completion releases it.
        gate.end()
        #expect(gate.isRunning == false)
    }
}

/// Verifies the view model exposes the gate's state through `isSaving`, which the
/// view reads to disable controls while an action is in flight.
@MainActor
struct NotificationSettingsViewModelTests {
    @Test func isSavingDefaultsToFalse() {
        let model = NotificationSettingsViewModel()
        #expect(model.isSaving == false)
    }

    @Test func nativePushToggleDisabledWhenSettingsMissing() {
        let model = NotificationSettingsViewModel()
        // No settings loaded yet -> the native push toggle stays disabled.
        #expect(model.nativePushToggleDisabled == true)
    }

    @Test func canRefreshApnsTokenFalseWhenNotDetermined() {
        let model = NotificationSettingsViewModel()
        // Authorization defaults to .notDetermined -> refresh is gated off.
        #expect(model.canRefreshApnsToken == false)
    }
}
