import Testing
@testable import whitenoise_ios

/// A notification action races its completion against a deadline and UIKit's
/// background expiration. The first outcome must win: a late completion after
/// expiry must not report success, and a late expiry must not undo a reply
/// that already went out.
@MainActor
struct NotificationActionDeadlineGateTests {
    typealias Outcome = NotificationActionDeadlineGate.Outcome

    /// Waits on the gate from its own task, with a bound, so a gate that never
    /// answers fails the test instead of hanging the run.
    private func outcome(
        of gate: NotificationActionDeadlineGate,
        parked: TestLatch? = nil
    ) async throws -> Outcome? {
        let received = TestLatch()
        var outcome: Outcome?
        Task { @MainActor in
            parked?.signal()
            outcome = await gate.wait()
            received.signal()
        }
        try await received.wait()
        return outcome
    }

    @Test(arguments: [
        Outcome.completed(succeeded: true),
        .completed(succeeded: false),
        .expired,
    ])
    func theFirstOutcomeWinsOverLaterOnes(_ first: Outcome) async throws {
        let gate = NotificationActionDeadlineGate()

        gate.resolve(first)
        gate.resolve(first == .expired ? .completed(succeeded: true) : .expired)

        #expect(try await outcome(of: gate) == first)
        // Waiting does not consume the outcome.
        #expect(try await outcome(of: gate) == first)
    }

    @Test func aWaiterParkedBeforeTheOutcomeReceivesIt() async throws {
        let gate = NotificationActionDeadlineGate()
        let parked = TestLatch()
        async let received = outcome(of: gate, parked: parked)
        // The waiter parks on the gate before this resumes: both run on the
        // MainActor and nothing suspends between the signal and the park.
        try await parked.wait()

        gate.resolve(.expired)
        gate.resolve(.completed(succeeded: true))

        #expect(try await received == .expired)
    }
}
