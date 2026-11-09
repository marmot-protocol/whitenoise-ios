@testable import whitenoise_ios
import MarmotKit
import Testing

@MainActor
struct BlockedLeaveCancellationTests {
    private struct PublishFailure: Error {}

    @Test func cancelRefreshesAfterSuccessAndRejoins() async {
        var steps: [String] = []
        let outcome = await BlockedLeaveCancellation.perform(
            cancelLeave: { steps.append("cancel") },
            refresh: { steps.append("refresh") }
        )

        guard case .rejoined = outcome else {
            Issue.record("expected rejoined, got \(outcome)")
            return
        }
        #expect(steps == ["cancel", "refresh"])
        #expect(BlockedLeaveCancellation.toast(for: outcome)?.style == .success)
    }

    @Test func leaveThatIsNoLongerBlockedRefreshesAndWarns() async {
        var refreshes = 0
        let outcome = await BlockedLeaveCancellation.perform(
            cancelLeave: { throw MarmotKitError.LeaveNotBlocked(groupIdHex: hex("ab")) },
            refresh: { refreshes += 1 }
        )

        guard case .noLongerBlocked = outcome else {
            Issue.record("expected noLongerBlocked, got \(outcome)")
            return
        }
        #expect(refreshes == 1)
        #expect(BlockedLeaveCancellation.toast(for: outcome)?.style == .warning)
    }

    @Test func otherFailuresRefreshAndReportAnError() async {
        var refreshes = 0
        let outcome = await BlockedLeaveCancellation.perform(
            cancelLeave: { throw PublishFailure() },
            refresh: { refreshes += 1 }
        )

        guard case .failed(let error) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(error is PublishFailure)
        #expect(refreshes == 1)
        #expect(BlockedLeaveCancellation.toast(for: outcome)?.style == .error)
    }

    @Test func cancelledTaskAnnouncesNothing() async {
        let outcome = await BlockedLeaveCancellation.perform(
            cancelLeave: { throw CancellationError() },
            refresh: {}
        )

        guard case .cancelled = outcome else {
            Issue.record("expected cancelled, got \(outcome)")
            return
        }
        #expect(BlockedLeaveCancellation.toast(for: outcome) == nil)
    }
}
