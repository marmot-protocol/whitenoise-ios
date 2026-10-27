import Testing
@testable import whitenoise_ios

/// A notification action races its completion against a deadline and UIKit's
/// background expiration. The first outcome must win: a late completion after
/// expiry must not report success, and a late expiry must not undo a reply
/// that already went out.
@MainActor
struct NotificationActionDeadlineGateTests {
    @Test(arguments: [
        NotificationActionDeadlineGate.Outcome.completed(succeeded: true),
        .completed(succeeded: false),
        .expired,
    ])
    func theFirstOutcomeWinsOverLaterOnes(_ first: NotificationActionDeadlineGate.Outcome) async {
        let gate = NotificationActionDeadlineGate()

        gate.resolve(first)
        gate.resolve(first == .expired ? .completed(succeeded: true) : .expired)

        #expect(await gate.wait() == first)
    }

    @Test func aWaiterParkedBeforeTheOutcomeReceivesIt() async throws {
        let gate = NotificationActionDeadlineGate()
        let waiting = TestLatch()
        let received = TestLatch()
        var outcome: NotificationActionDeadlineGate.Outcome?
        Task { @MainActor in
            waiting.signal()
            outcome = await gate.wait()
            received.signal()
        }
        // The waiter parks on the gate before this resumes: both run on the
        // MainActor and nothing suspends between the signal and the park.
        try await waiting.wait()

        gate.resolve(.expired)
        gate.resolve(.completed(succeeded: true))
        // Bounded, so a parked waiter that is never resumed fails the test.
        try await received.wait()

        #expect(outcome == .expired)
        // A later wait sees the same outcome; waiting does not consume it.
        #expect(await gate.wait() == .expired)
    }
}
