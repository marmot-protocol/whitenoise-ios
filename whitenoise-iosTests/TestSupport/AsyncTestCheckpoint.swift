import Testing

/// Holds the code under test at a known point: it calls `pause()`, the test
/// awaits `waitUntilPaused()`, inspects state, then calls `release()`.
/// Both waits are bounded like `TestLatch.hold`: a pause or a release that
/// never comes records a test issue at the caller and carries on, so the
/// test fails instead of hanging the suite.
actor AsyncTestCheckpoint {
    private let paused = TestLatch()
    private let released = TestLatch()

    func pause(
        timeout: Duration = TestLatch.defaultTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        paused.signal()
        await hold(released, "The checkpoint was never released", timeout, sourceLocation)
    }

    func waitUntilPaused(
        timeout: Duration = TestLatch.defaultTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await hold(paused, "The checkpoint was never paused", timeout, sourceLocation)
    }

    func release() {
        released.signal()
    }

    private func hold(
        _ latch: TestLatch,
        _ comment: Comment,
        _ timeout: Duration,
        _ sourceLocation: SourceLocation
    ) async {
        do {
            try await latch.wait(timeout: timeout, sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, comment, sourceLocation: sourceLocation)
        }
    }
}
