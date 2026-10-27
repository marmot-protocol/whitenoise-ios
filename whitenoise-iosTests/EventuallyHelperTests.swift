import Testing

@testable import whitenoise_ios

struct EventuallyHelperTests {
    @Test func timeoutAloneStopsAfterTheDeadline() async {
        var checks = 0
        await #expect(throws: TestWaitTimeout.self) {
            try await eventually(timeout: .zero, attemptsAfterDeadline: 0) {
                checks += 1
                return false
            }
        }
        #expect(checks == 1)
    }

    @Test func minimumAttemptsKeepPollingPastTheDeadline() async {
        var checks = 0
        await #expect(throws: TestWaitTimeout.self) {
            try await eventually(timeout: .zero, minimumAttempts: 5, attemptsAfterDeadline: 0) {
                checks += 1
                return false
            }
        }
        #expect(checks == 6)
    }

    @Test func aFalseConditionGetsTheDefaultChecksPastTheDeadline() async {
        var checks = 0
        await #expect(throws: TestWaitTimeout.self) {
            try await eventually(timeout: .zero) {
                checks += 1
                return false
            }
        }
        #expect(checks == 101)
    }

    /// Models a runner stall: the deadline has passed by the first check, and
    /// the awaited work completes a few turns later.
    @Test func aConditionThatHoldsSoonAfterTheDeadlineStillPasses() async throws {
        var checks = 0
        try await eventually(timeout: .zero) {
            checks += 1
            return checks == 20
        }
        #expect(checks == 20)
    }

    /// Models a runner stall: the latch's timer has expired by the time the
    /// signalling side gets its turn, a few turns later.
    @Test func aLatchSignalledJustAfterItsTimeoutStillOpens() async throws {
        let latch = TestLatch()
        let signaller = Task {
            for _ in 0..<5 { await Task.yield() }
            latch.signal()
        }
        try await latch.wait(timeout: .zero)
        await signaller.value
        #expect(latch.isSignalled)
    }

    @Test func aLatchThatIsNeverSignalledStillTimesOut() async {
        let latch = TestLatch()
        await #expect(throws: TestWaitTimeout.self) {
            try await latch.wait(timeout: .zero)
        }
    }

    @Test func aConditionThatBecomesTrueReturnsWithoutThrowing() async throws {
        var checks = 0
        try await eventually(timeout: .zero, minimumAttempts: 10) {
            checks += 1
            return checks == 3
        }
        #expect(checks == 3)
    }
}
