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

    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
        var timeout: Task<Void, Never>?
    }

    private struct State {
        var isSignalled = false
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = Mutex(State())

    init() {}

    var isSignalled: Bool { state.withLock { $0.isSignalled } }

    func signal() {
        let waiters = state.withLock { state -> [Waiter] in
            guard !state.isSignalled else { return [] }
            state.isSignalled = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.timeout?.cancel()
            waiter.continuation.resume()
        }
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
                state.waiters[id] = Waiter(continuation: continuation, timeout: nil)
                return false
            }
            if isOpen { return continuation.resume() }
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                self.fail(id, TestWaitTimeout(what: "TestLatch signal", timeout: timeout, sourceLocation: sourceLocation))
            }
            // Signalled in between: the waiter is already resumed, so stop the timer.
            let isWaiting = state.withLock { state -> Bool in
                guard state.waiters[id] != nil else { return false }
                state.waiters[id]?.timeout = timer
                return true
            }
            if !isWaiting { timer.cancel() }
        }
    }

    /// `wait(timeout:)` for holders inside non-throwing closures: a missing
    /// signal records a test issue at `sourceLocation` instead of resuming
    /// silently, so the test fails rather than running on unreleased.
    func hold(
        timeout: Duration = TestLatch.defaultTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            try await wait(timeout: timeout, sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    private func fail(_ id: UUID, _ error: any Error) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume(throwing: error)
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

/// Stands in for a long backoff or wait that the code under test must
/// cancel: suspends until the current task is cancelled, then throws
/// `CancellationError` as `Task.sleep` would. Throws `TestWaitTimeout` when
/// no cancellation arrives within `timeout`.
func parkUntilCancelled(
    timeout: Duration = TestLatch.defaultTimeout,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let cancelled = TestLatch()
    try await withTaskCancellationHandler {
        try await cancelled.wait(timeout: timeout, sourceLocation: sourceLocation)
    } onCancel: {
        cancelled.signal()
    }
    try Task.checkCancellation()
}
