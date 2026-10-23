import Foundation
import Synchronization
import Testing

/// Thrown by `TestLatch.wait(timeout:)` and `eventually(timeout:_:)` when the
/// bounded budget runs out, so a broken handshake fails the test instead of
/// hanging until the CI timeout.
struct TestWaitTimeout: Error, CustomStringConvertible {
    let what: String
    let timeout: Duration
    let sourceLocation: SourceLocation

    var description: String { "\(what) did not happen within \(timeout) (\(sourceLocation))" }
}

/// One-shot gate. `signal()` opens it for every current and future waiter;
/// `wait(timeout:)` returns once it is open and throws `TestWaitTimeout`
/// otherwise. Safe to signal from any isolation, including synchronous code.
final class TestLatch: Sendable {
    static let defaultTimeout = Duration.seconds(30)

    private struct State {
        var isSignalled = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    init() {}

    var isSignalled: Bool { state.withLock { $0.isSignalled } }

    func signal() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard !state.isSignalled else { return [] }
            state.isSignalled = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait(
        timeout: Duration = TestLatch.defaultTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        // Like the hand-rolled gates it replaces, waiting ignores task
        // cancellation: a cancelled holder stays parked until its release.
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let isOpen = state.withLock { state -> Bool in
                if state.isSignalled { return true }
                state.waiters[id] = continuation
                return false
            }
            if isOpen { return continuation.resume() }
            Task {
                try? await Task.sleep(for: timeout)
                self.fail(id, TestWaitTimeout(what: "TestLatch signal", timeout: timeout, sourceLocation: sourceLocation))
            }
        }
    }

    private func fail(_ id: UUID, _ error: any Error) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: error)
    }
}

/// Polls `condition` until it holds, yielding first and then sleeping briefly
/// between checks. Throws `TestWaitTimeout` when `timeout` elapses; never
/// returns silently with the condition still false.
func eventually(
    timeout: Duration = TestLatch.defaultTimeout,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var attempts = 0
    while true {
        if try await condition() { return }
        guard ContinuousClock.now < deadline else {
            throw TestWaitTimeout(what: "condition", timeout: timeout, sourceLocation: sourceLocation)
        }
        attempts += 1
        if attempts < 100 {
            await Task.yield()
        } else {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
