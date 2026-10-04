import Foundation
import Synchronization
import Testing

@testable import whitenoise_ios

@Suite(.timeLimit(.minutes(1)))
struct PinnedHTTPSFetchLifetimeTests {
    @Test func gateRemembersCancellationBeforeInstallation() async throws {
        let gate = PinnedFetchWaitGate<Int>()
        #expect(gate.complete(.failure(CancellationError())))
        #expect(!gate.complete(.success(4)))
        do {
            _ = try await gate.wait { _ in Issue.record("Cancelled gate started work") }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected, without starting the callback operation.
        }
    }

    @Test func gateDeliversOnlyOneOfConcurrentCompletions() async throws {
        let gate = PinnedFetchWaitGate<Int>()
        let wins = Mutex(0)
        let result = Task { try await gate.wait { _ in } }
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<20 {
                group.addTask {
                    if gate.complete(.success(value)) { wins.withLock { $0 += 1 } }
                }
            }
        }
        #expect((0..<20).contains(try await result.value))
        #expect(wins.withLock { $0 } == 1)
    }

    @Test func absoluteAttemptExpiryCannotSlidePastTotalDeadline() throws {
        let clock = VirtualFetchClock()
        let deadline = PinnedFetchDeadline(clock: clock)
        clock.advance(by: .seconds(55))
        let attemptExpiry = try deadline.attemptExpiry(maximum: 12_000_000_000)
        #expect(attemptExpiry == deadline.expiry)
        clock.advance(by: .seconds(5))
        #expect(throws: URLError(.timedOut)) {
            try deadline.attemptExpiry(maximum: 12_000_000_000)
        }
    }

    @Test func blockedDNSCancellationReturnsBeforeWorkerRelease() async throws {
        let fixture = BlockingDNS()
        defer { fixture.release() }
        let exited = PinnedFetchWaitGate<Void>()
        let slots = PinnedDNSResolutionSlots(limit: 1, onRelease: { exited.complete(.success(())) })
        let task = Task {
            try await PinnedDNSWait.resolve(
                url: URL(string: "https://cdn.example/avatar.png")!,
                resolver: fixture.resolve,
                deadline: PinnedFetchDeadline(clock: VirtualFetchClock()),
                slots: slots
            )
        }
        _ = try await fixture.started.wait { _ in }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation before resolver release")
        } catch is CancellationError {
            #expect(slots.inFlight == 1)
            #expect(!slots.claim())
        }
        #expect(!fixture.didTimeOut)
        fixture.release()
        _ = try await exited.wait { _ in }
        #expect(slots.inFlight == 0)
    }

    @Test func blockedDNSDeadlineReturnsBeforeWorkerReleaseAndDoesNotConnect() async throws {
        let fixture = BlockingDNS()
        defer { fixture.release() }
        let clock = VirtualFetchClock()
        let exited = PinnedFetchWaitGate<Void>()
        let slots = PinnedDNSResolutionSlots(limit: 1, onRelease: { exited.complete(.success(())) })
        let connections = Mutex(0)
        let task = Task {
            _ = try await PinnedHTTPSFetcher.fetch(
                URLRequest(url: URL(string: "https://cdn.example/avatar.png")!),
                maximumResponseBytes: 1024,
                resolver: fixture.resolve,
                clock: clock,
                slots: slots,
                attempt: { _, _, _, _, _ in
                    connections.withLock { $0 += 1 }
                    throw URLError(.cannotConnectToHost)
                }
            )
        }
        _ = try await fixture.started.wait { _ in }
        clock.advance(by: .seconds(60))
        do {
            _ = try await task.value
            Issue.record("Expected total deadline before resolver release")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(slots.inFlight == 1)
            #expect(connections.withLock { $0 } == 0)
        }
        #expect(!fixture.didTimeOut)
        fixture.release()
        _ = try await exited.wait { _ in }
        // A late worker completion has no continuation capable of starting a connection.
        #expect(slots.inFlight == 0)
        #expect(connections.withLock { $0 } == 0)
    }

    @Test func sixAbandonedDNSWorkersRetainTheirSlotsUntilTheyActuallyExit() async throws {
        let fixtures = (0..<6).map { _ in BlockingDNS() }
        defer { fixtures.forEach { $0.release() } }
        let exited = PinnedFetchWaitGate<Void>()
        let exits = Mutex(0)
        let slots = PinnedDNSResolutionSlots(limit: 6, onRelease: {
            let allExited = exits.withLock { count in count += 1; return count == 6 }
            if allExited { exited.complete(.success(())) }
        })
        let url = try #require(URL(string: "https://cdn.example/avatar.png"))
        let tasks = fixtures.map { fixture in
            Task {
                _ = try await PinnedDNSWait.resolve(
                    url: url, resolver: fixture.resolve,
                    deadline: PinnedFetchDeadline(clock: VirtualFetchClock()), slots: slots
                )
            }
        }
        for fixture in fixtures { _ = try await fixture.started.wait { _ in } }
        #expect(slots.inFlight == 6)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
        await #expect(throws: URLError(.cannotConnectToHost)) {
            _ = try await PinnedDNSWait.resolve(
                url: url,
                resolver: { _ in Issue.record("Saturated slots started another resolver"); return ["8.8.8.8"] },
                deadline: PinnedFetchDeadline(clock: VirtualFetchClock()), slots: slots
            )
        }
        #expect(slots.inFlight == 6)
        #expect(fixtures.allSatisfy { !$0.didTimeOut })
        fixtures.forEach { $0.release() }
        _ = try await exited.wait { _ in }
        #expect(slots.inFlight == 0)
        #expect(exits.withLock { $0 } == 6)
        #expect(slots.claim())
        slots.release()
    }

    @Test func resolverFailureReleasesItsReservation() async throws {
        let exited = PinnedFetchWaitGate<Void>()
        let slots = PinnedDNSResolutionSlots(limit: 1, onRelease: { exited.complete(.success(())) })
        await #expect(throws: HostResolutionGuard.GuardError.resolvesToPrivateAddress) {
            _ = try await PinnedDNSWait.resolve(
                url: try #require(URL(string: "https://cdn.example/avatar.png")),
                resolver: { _ in ["127.0.0.1"] },
                deadline: PinnedFetchDeadline(clock: VirtualFetchClock()), slots: slots
            )
        }
        _ = try await exited.wait { _ in }
        #expect(slots.inFlight == 0)
    }

    @Test func endpointFallbackBeyondTwelveSecondsUsesRemainingTotalBudget() async throws {
        let clock = VirtualFetchClock()
        let budgets = Mutex<[UInt64]>([])
        let response = try await PinnedHTTPSFetcher.fetch(
            URLRequest(url: URL(string: "https://cdn.example/avatar.png")!, timeoutInterval: 12),
            maximumResponseBytes: 1024,
            resolver: { _ in ["8.8.8.8", "1.1.1.1"] },
            clock: clock,
            slots: PinnedDNSResolutionSlots(limit: 6),
            attempt: { _, url, endpoint, _, budget in
                budgets.withLock { $0.append(budget) }
                if endpoint.address == "8.8.8.8" {
                    clock.advance(by: .seconds(12))
                    throw URLError(.timedOut)
                }
                clock.advance(by: .seconds(2))
                return PinnedHTTPSFetcher.PinnedResponse(
                    data: Data([1]),
                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                )
            }
        )
        #expect(response.0 == Data([1]))
        #expect(budgets.withLock { $0 } == [12_000_000_000, 12_000_000_000])
    }

    @Test func redirectsAndEndpointsNeverResetTotalBudget() async throws {
        let clock = VirtualFetchClock()
        let budgets = Mutex<[UInt64]>([])
        let resolutions = Mutex(0)
        do {
            _ = try await PinnedHTTPSFetcher.fetch(
                URLRequest(url: URL(string: "https://cdn.example/start")!, timeoutInterval: 12),
                maximumResponseBytes: 1024,
                resolver: { _ in
                    resolutions.withLock { $0 += 1 }
                    return ["8.8.8.8", "1.1.1.1"]
                },
                clock: clock,
                slots: PinnedDNSResolutionSlots(limit: 6),
                attempt: { _, url, endpoint, _, budget in
                    budgets.withLock { $0.append(budget) }
                    clock.advance(by: .seconds(11))
                    if endpoint.address == "8.8.8.8" { throw URLError(.timedOut) }
                    return PinnedHTTPSFetcher.PinnedResponse(
                        data: Data(),
                        response: HTTPURLResponse(
                            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                            headerFields: ["Location": "/next"]
                        )!
                    )
                }
            )
            Issue.record("Expected one shared deadline")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(budgets.withLock { $0 }.count == 6)
            #expect(budgets.withLock { $0.last } == 5_000_000_000)
            #expect(resolutions.withLock { $0 } == 3)
        }
    }
}

// Condition-protected state; a watchdog also releases a worker if an awaited drain regresses.
// swiftlint:disable:next no_unchecked_sendable
nonisolated final class BlockingDNS: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var timedOut = false
    let started = PinnedFetchWaitGate<Void>()

    func resolve(_ host: String) -> [String] {
        started.complete(.success(()))
        condition.lock()
        defer { condition.unlock() }
        let watchdog = Date().addingTimeInterval(30)
        while !released {
            guard condition.wait(until: watchdog) else {
                timedOut = true
                break
            }
        }
        return ["8.8.8.8"]
    }

    var didTimeOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return timedOut
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

nonisolated private final class VirtualFetchClock: PinnedFetchClock {
    private struct Entry: Sendable {
        let deadline: ContinuousClock.Instant
        let action: @Sendable () -> Void
        let timer: Timer
    }

    private final class Timer: PinnedFetchTimer {
        private let cancelled = Mutex(false)
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    private struct State: Sendable {
        var now = ContinuousClock.now
        var entries: [Entry] = []
    }

    private let state = Mutex(State())

    func now() -> ContinuousClock.Instant { state.withLock { $0.now } }

    func schedule(
        at deadline: ContinuousClock.Instant,
        _ action: @escaping @Sendable () -> Void
    ) -> any PinnedFetchTimer {
        let timer = Timer()
        let isDue = state.withLock { state -> Bool in
            guard deadline > state.now else { return true }
            state.entries.append(Entry(deadline: deadline, action: action, timer: timer))
            return false
        }
        if isDue { action() }
        return timer
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Entry] in
            state.now = state.now.advanced(by: duration)
            let due = state.entries.filter { $0.deadline <= state.now }
            state.entries.removeAll { $0.deadline <= state.now }
            return due
        }
        for entry in due where !entry.timer.isCancelled { entry.action() }
    }
}
