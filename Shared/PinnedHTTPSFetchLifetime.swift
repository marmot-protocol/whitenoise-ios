import Foundation
import Synchronization

nonisolated protocol PinnedFetchTimer: Sendable {
    func cancel()
}

nonisolated protocol PinnedFetchClock: Sendable {
    func now() -> ContinuousClock.Instant
    func schedule(
        at deadline: ContinuousClock.Instant,
        _ action: @escaping @Sendable () -> Void
    ) -> any PinnedFetchTimer
}

nonisolated struct SystemPinnedFetchClock: PinnedFetchClock {
    private struct Timer: PinnedFetchTimer {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }

    func now() -> ContinuousClock.Instant { ContinuousClock.now }

    func schedule(
        at deadline: ContinuousClock.Instant,
        _ action: @escaping @Sendable () -> Void
    ) -> any PinnedFetchTimer {
        Timer(task: Task.detached(priority: .utility) {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                try Task.checkCancellation()
                action()
            } catch {
                // A completed or cancelled wait no longer needs its wakeup.
            }
        })
    }
}

/// One monotonic budget; an executor-delayed timer cannot admit an expired result.
nonisolated struct PinnedFetchDeadline: Sendable {
    static let totalBudget: Duration = .seconds(60)
    let clock: any PinnedFetchClock
    let expiry: ContinuousClock.Instant

    init(clock: any PinnedFetchClock = SystemPinnedFetchClock()) {
        self.clock = clock
        expiry = clock.now().advanced(by: Self.totalBudget)
    }

    func check() throws {
        try Task.checkCancellation()
        guard clock.now() < expiry else { throw URLError(.timedOut) }
    }

    func attemptNanoseconds(maximum: UInt64) throws -> UInt64 {
        try check()
        let remaining = clock.now().duration(to: expiry).components
        // check() and this read can race expiry, but never create a fresh budget.
        guard remaining.seconds >= 0, remaining.attoseconds >= 0 else { throw URLError(.timedOut) }
        let nanos = UInt64(remaining.seconds) * 1_000_000_000
            + UInt64(remaining.attoseconds / 1_000_000_000)
        guard nanos > 0 else { throw URLError(.timedOut) }
        return min(maximum, nanos)
    }

    func attemptExpiry(maximum: UInt64) throws -> ContinuousClock.Instant {
        let timeout = try attemptNanoseconds(maximum: maximum)
        return min(expiry, clock.now().advanced(by: .nanoseconds(Int64(clamping: timeout))))
    }
}

/// Remember completion before installation; callbacks and cancellation resume exactly once.
nonisolated final class PinnedFetchWaitGate<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case waiting
        case installed(CheckedContinuation<Value, Error>)
        case delivered(Result<Value, Error>)
        case finished
    }

    private let state = Mutex<State>(.waiting)

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let previous = state.withLock { state -> State in
            let previous = state
            switch state {
            case .waiting: state = .installed(continuation)
            case .delivered: state = .finished
            case .installed, .finished: break
            }
            return previous
        }
        switch previous {
        case .waiting:
            return true
        case .delivered(let result):
            continuation.resume(with: result)
        case .installed, .finished:
            continuation.resume(throwing: CancellationError())
        }
        return false
    }

    @discardableResult
    func complete(_ result: Result<Value, Error>) -> Bool {
        let previous = state.withLock { state -> State in
            let previous = state
            switch state {
            case .waiting: state = .delivered(result)
            case .installed: state = .finished
            case .delivered, .finished: break
            }
            return previous
        }
        switch previous {
        case .waiting:
            return true
        case .installed(let continuation):
            continuation.resume(with: result)
            return true
        case .delivered, .finished:
            return false
        }
    }

    func wait(_ start: @Sendable (PinnedFetchWaitGate<Value>) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if install(continuation) { start(self) }
            }
        } onCancel: {
            self.complete(.failure(CancellationError()))
        }
    }
}

/// No queue. A reservation counts the synchronous worker, not its abandoned caller.
nonisolated final class PinnedDNSResolutionSlots: Sendable {
    private let count = Mutex(0)
    private let onRelease: (@Sendable () -> Void)?
    let limit: Int

    init(limit: Int, onRelease: (@Sendable () -> Void)? = nil) {
        self.limit = max(0, limit)
        self.onRelease = onRelease
    }

    func claim() -> Bool {
        count.withLock { PinnedHTTPSFetcher.claimDnsSlot(&$0, limit: limit) }
    }

    func release() {
        count.withLock { $0 = max(0, $0 - 1) }
        // A test observer sees actual worker exit, never caller abandonment.
        onRelease?()
    }

    var inFlight: Int { count.withLock { $0 } }
}

nonisolated enum PinnedDNSWait {
    static func resolve(
        url: URL,
        resolver: @escaping HostResolutionGuard.Resolver,
        deadline: PinnedFetchDeadline,
        slots: PinnedDNSResolutionSlots
    ) async throws -> [PinnedHTTPSFetcher.Endpoint] {
        try deadline.check()
        let gate = PinnedFetchWaitGate<[PinnedHTTPSFetcher.Endpoint]>()
        let timer = deadline.clock.schedule(at: deadline.expiry) {
            gate.complete(.failure(URLError(.timedOut)))
        }
        defer { timer.cancel() }
        let endpoints = try await gate.wait { gate in
            guard slots.claim() else {
                gate.complete(.failure(URLError(.cannotConnectToHost)))
                return
            }
            // getaddrinfo is synchronous: do not pin a cooperative Swift executor thread.
            DispatchQueue.global(qos: .utility).async {
                defer { slots.release() }
                // Never await this worker's value or free its slot when the caller leaves.
                gate.complete(Result { try PinnedHTTPSFetcher.endpoints(for: url, resolver: resolver) })
            }
        }
        try deadline.check()
        return endpoints
    }
}
