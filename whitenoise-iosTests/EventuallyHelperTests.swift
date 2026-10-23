import Testing

@testable import whitenoise_ios

struct EventuallyHelperTests {
    @Test func timeoutAloneStopsAfterTheDeadline() async {
        var checks = 0
        await #expect(throws: TestWaitTimeout.self) {
            try await eventually(timeout: .zero) {
                checks += 1
                return false
            }
        }
        #expect(checks == 1)
    }

    @Test func minimumAttemptsKeepPollingPastTheDeadline() async {
        var checks = 0
        await #expect(throws: TestWaitTimeout.self) {
            try await eventually(timeout: .zero, minimumAttempts: 5) {
                checks += 1
                return false
            }
        }
        #expect(checks == 6)
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
