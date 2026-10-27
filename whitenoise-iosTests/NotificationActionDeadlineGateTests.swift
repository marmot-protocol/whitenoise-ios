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
        let waiter = Task { @MainActor in
            waiting.signal()
            return await gate.wait()
        }
        try await waiting.wait()

        gate.resolve(.expired)
        gate.resolve(.completed(succeeded: true))

        #expect(await waiter.value == .expired)
    }

    @Test func everyLaterWaitSeesTheSameOutcome() async {
        let gate = NotificationActionDeadlineGate()
        gate.resolve(.completed(succeeded: true))

        #expect(await gate.wait() == .completed(succeeded: true))
        #expect(await gate.wait() == .completed(succeeded: true))
    }
}
