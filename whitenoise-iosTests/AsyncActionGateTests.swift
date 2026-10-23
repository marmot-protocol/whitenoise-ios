import Testing
@testable import whitenoise_ios

/// Focused coverage for the re-entrancy contract behind `NotificationSettingsViewModel`.
/// The view model funnels every mutating action through `AsyncActionGate`, so
/// these tests pin the gate's serialization guarantee directly — no `AppState` needed.
@MainActor
struct AsyncActionGateTests {
    @Test func tryBeginSucceedsWhenIdle() {
        var gate = AsyncActionGate()
        #expect(gate.isRunning == false)
        #expect(gate.tryBegin() == true)
        #expect(gate.isRunning == true)
    }

    @Test func tryBeginRejectsWhileRunning() {
        var gate = AsyncActionGate()
        #expect(gate.tryBegin() == true)
        // A second action arriving while the first is in flight must be rejected,
        // so it cannot start an overlapping mutation.
        #expect(gate.tryBegin() == false)
        #expect(gate.isRunning == true)
    }

    @Test func endReleasesGateForNextAction() {
        var gate = AsyncActionGate()
        #expect(gate.tryBegin() == true)
        gate.end()
        #expect(gate.isRunning == false)
        // Once released, a subsequent action may claim the gate again.
        #expect(gate.tryBegin() == true)
    }

    @Test func repeatedRejectionsDoNotReleaseTheGate() {
        var gate = AsyncActionGate()
        #expect(gate.tryBegin() == true)
        // Rapid repeated taps each fail and leave the in-flight action's claim intact.
        #expect(gate.tryBegin() == false)
        #expect(gate.tryBegin() == false)
        #expect(gate.isRunning == true)
        // Only the original action's completion releases it.
        gate.end()
        #expect(gate.isRunning == false)
    }

    @Test func reloadTicketIsUnavailableWhileActionIsRunning() {
        var gate = AsyncActionGate()
        #expect(gate.tryBegin() == true)
        #expect(gate.reloadTicket() == nil)
    }

    @Test func actionStartInvalidatesExistingReloadTicket() {
        var gate = AsyncActionGate()
        let ticket = gate.reloadTicket()
        #expect(ticket != nil)
        #expect(gate.canApplyReload(startedAt: ticket!) == true)

        #expect(gate.tryBegin() == true)
        #expect(gate.canApplyReload(startedAt: ticket!) == false)
        gate.end()
        #expect(gate.canApplyReload(startedAt: ticket!) == false)
    }
}
