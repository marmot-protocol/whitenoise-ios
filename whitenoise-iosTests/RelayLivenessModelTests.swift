import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@MainActor
struct RelayLivenessModelTests {
    private let eu = "wss://relay.eu.whitenoise.chat"
    private let us = "wss://relay.us.whitenoise.chat"

    @Test func appliesTheSnapshotThenEachLaterList() async throws {
        let subscription = FakeRelayLivenessSubscription(snapshot: [relay(eu, .connecting)])
        let source = RelayLivenessDataSourceStub(subscription: subscription)
        let model = RelayLivenessModel()

        let watch = Task { await model.observe(accountRef: "account", using: source) }
        try await eventually { model.relays == [relay(eu, .connecting)] }
        #expect(source.subscribedAccountRefs == ["account"])

        subscription.deliver([relay(eu, .connected), relay(us, .offline)])
        try await eventually { model.relays == [relay(eu, .connected), relay(us, .offline)] }

        watch.cancel()
        await watch.value
    }

    @Test func cancellingTheWatchCancelsTheSubscription() async throws {
        let subscription = FakeRelayLivenessSubscription(snapshot: [relay(eu, .connected)])
        let model = RelayLivenessModel()

        let watch = Task {
            await model.observe(accountRef: "account", using: RelayLivenessDataSourceStub(subscription: subscription))
        }
        try await eventually { model.relays != nil }
        #expect(!subscription.isCancelled)

        watch.cancel()
        await watch.value
        #expect(subscription.isCancelled)
    }

    @Test func aRuntimeShutdownEndsTheWatchAndKeepsTheLastList() async throws {
        let subscription = FakeRelayLivenessSubscription(snapshot: [relay(eu, .connected)])
        let model = RelayLivenessModel()

        let watch = Task {
            await model.observe(accountRef: "account", using: RelayLivenessDataSourceStub(subscription: subscription))
        }
        try await eventually { model.relays != nil }
        subscription.finish()
        await watch.value

        #expect(model.relays == [relay(eu, .connected)])
    }

    @Test func aFailedSubscribeIsReportedAndNoAccountShowsNothing() async {
        let model = RelayLivenessModel()
        let source = RelayLivenessDataSourceStub(subscription: nil)

        await model.observe(accountRef: "account", using: source)
        #expect(model.loadFailed)
        #expect(model.relays == nil)

        await model.observe(accountRef: nil, using: source)
        #expect(!model.loadFailed)
        #expect(model.relays == nil)
        #expect(source.subscribedAccountRefs == ["account"])
    }

    @Test func aReconnectResultCannotOverwriteANewerList() async throws {
        let subscription = FakeRelayLivenessSubscription(snapshot: [relay(eu, .offline), relay(us, .connected)])
        let source = RelayLivenessDataSourceStub(subscription: subscription)
        source.reconnectResult = .success(relay(eu, .connecting))
        let gate = (entered: TestLatch(), released: TestLatch())
        source.reconnectGate = gate
        let model = RelayLivenessModel()
        let watch = Task { await model.observe(accountRef: "account", using: source) }
        try await eventually { model.relays != nil }

        let reconnect = Task { await model.reconnect(url: eu, using: source) }
        try await gate.entered.wait()
        #expect(model.reconnectingURLs == [eu])
        subscription.deliver([relay(eu, .connected), relay(us, .connected)])
        try await eventually { model.relays?.first?.status == .connected }
        gate.released.signal()
        await reconnect.value

        #expect(source.reconnects == [ReconnectCall(accountRef: "account", url: eu)])
        #expect(model.relays == [relay(eu, .connected), relay(us, .connected)])
        #expect(model.reconnectingURLs.isEmpty)
        #expect(source.presentedToasts.isEmpty)
        watch.cancel()
        await watch.value
    }

    @Test func aFailedReceiveClearsTheListAndARetryWatchesAgain() async throws {
        let first = FakeRelayLivenessSubscription(snapshot: [relay(eu, .connected)])
        let model = RelayLivenessModel()
        let failing = Task {
            await model.observe(accountRef: "account", using: RelayLivenessDataSourceStub(subscription: first))
        }
        try await eventually { model.relays != nil }
        first.fail()
        await failing.value
        #expect(model.relays == nil)
        #expect(model.loadFailed)

        let second = FakeRelayLivenessSubscription(snapshot: [relay(eu, .offline)])
        let retry = Task {
            await model.observe(accountRef: "account", using: RelayLivenessDataSourceStub(subscription: second))
        }
        try await eventually { model.relays == [relay(eu, .offline)] }
        #expect(!model.loadFailed)
        retry.cancel()
        await retry.value
    }

    @Test func aFailedReconnectKeepsTheRowAndTellsTheUser() async throws {
        let subscription = FakeRelayLivenessSubscription(snapshot: [relay(eu, .offline)])
        let source = RelayLivenessDataSourceStub(subscription: subscription)
        source.reconnectResult = .failure(MarmotKitError.Runtime(details: "relay not configured"))
        let model = RelayLivenessModel()
        let watch = Task { await model.observe(accountRef: "account", using: source) }
        try await eventually { model.relays != nil }

        await model.reconnect(url: eu, using: source)

        #expect(model.relays == [relay(eu, .offline)])
        #expect(source.presentedToasts.count == 1)
        #expect(model.reconnectingURLs.isEmpty)
        watch.cancel()
        await watch.value
    }

    @Test func onlyRelaysThatAreNotConnectedOrDiallingOfferReconnect() {
        let offering = [RelayStatusFfi.unknown, .connecting, .connected, .offline]
            .filter(RelayLivenessPresentation.canReconnect)
        #expect(offering == [.unknown, .offline])
    }

    @Test func rowsKeepMDKsOrderAndOnlyUnconnectedRelaysShowTheLastAttempt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveMinutesAgo = UInt64(now.timeIntervalSince1970) - 300
        let rows = RelayLivenessPresentation.rows([
            relay(us, .offline, lastAttempt: fiveMinutesAgo),
            relay(eu, .connected, lastAttempt: fiveMinutesAgo),
            relay("wss://never.example", .unknown),
        ], now: now, locale: Locale(identifier: "en"))

        #expect(rows.map(\.url) == [us, eu, "wss://never.example"])
        #expect(rows[0].detail != nil)
        #expect(rows[1].detail == nil)
        #expect(rows[2].detail == nil)
        #expect(Set(rows.map(\.statusText)).count == 3)
    }

    @Test func anAttemptTodayShowsItsTimeAndAnOlderOneAlsoItsDate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "en")
        let today = RelayLivenessPresentation.detail(
            relay(eu, .offline, lastAttempt: UInt64(now.timeIntervalSince1970) - 60), now: now, locale: locale)
        let lastWeek = RelayLivenessPresentation.detail(
            relay(eu, .offline, lastAttempt: UInt64(now.timeIntervalSince1970) - 7 * 86_400), now: now, locale: locale)

        let todayText = try #require(today)
        let lastWeekText = try #require(lastWeek)
        #expect(lastWeekText.count > todayText.count)
    }

    @Test func relayURLsAreSanitizedForDisplay() {
        let spoofed = "wss://relay.\u{202E}moc.live\u{202C}.example"
        let row = RelayLivenessPresentation.rows([relay(spoofed, .offline)], now: Date())[0]
        #expect(row.url == spoofed)
        #expect(!row.display.unicodeScalars.contains("\u{202E}"))
    }

    private func relay(_ url: String, _ status: RelayStatusFfi, lastAttempt: UInt64? = nil) -> RelayLivenessFfi {
        RelayLivenessFfi(url: url, status: status, lastAttemptUnix: lastAttempt, lastError: nil)
    }
}

private struct ReconnectCall: Equatable {
    let accountRef: String
    let url: String
}

@MainActor
private final class RelayLivenessDataSourceStub: RelayLivenessDataSource {
    let subscription: FakeRelayLivenessSubscription?
    var reconnectResult: Result<RelayLivenessFfi, any Error> = .failure(CancellationError())
    var reconnectGate: (entered: TestLatch, released: TestLatch)?
    private(set) var subscribedAccountRefs: [String] = []
    private(set) var reconnects: [ReconnectCall] = []
    private(set) var presentedToasts: [Toast] = []

    private struct SubscribeFailed: Error {}

    init(subscription: FakeRelayLivenessSubscription?) {
        self.subscription = subscription
    }

    func subscribeRelayLiveness(accountRef: String) async throws -> any RelayLivenessSubscriptionProtocol {
        subscribedAccountRefs.append(accountRef)
        guard let subscription else { throw SubscribeFailed() }
        return subscription
    }

    func reconnectRelay(accountRef: String, url: String) async throws -> RelayLivenessFfi {
        reconnects.append(ReconnectCall(accountRef: accountRef, url: url))
        if let reconnectGate {
            reconnectGate.entered.signal()
            await reconnectGate.released.hold()
        }
        return try reconnectResult.get()
    }

    func present(_ toast: Toast) {
        presentedToasts.append(toast)
    }
}

/// Stands in for MDK's subscription: `next()` waits for `deliver`, returns
/// nil after `cancel()` or `finish()`, as MDK does after cancel or runtime
/// shutdown, and throws after `fail()`.
private final class FakeRelayLivenessSubscription: RelayLivenessSubscriptionProtocol {
    private struct State {
        var pending: [[RelayLivenessFfi]] = []
        var waiter: CheckedContinuation<[RelayLivenessFfi]?, any Error>?
        var ended = false
        var failed = false
        var cancelled = false
    }

    private let initial: [RelayLivenessFfi]
    private let state = Mutex(State())

    init(snapshot: [RelayLivenessFfi]) {
        initial = snapshot
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func snapshot() -> [RelayLivenessFfi] { initial }

    private struct ReceiveFailed: Error {}

    func next() async throws -> [RelayLivenessFfi]? {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<[RelayLivenessFfi]?, any Error>? = state.withLock { state in
                if !state.pending.isEmpty { return .success(state.pending.removeFirst()) }
                if state.failed { return .failure(ReceiveFailed()) }
                if state.ended { return .success(nil) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func fail() {
        let waiter = state.withLock { state -> CheckedContinuation<[RelayLivenessFfi]?, any Error>? in
            state.failed = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: ReceiveFailed())
    }

    func deliver(_ relays: [RelayLivenessFfi]) {
        let waiter = state.withLock { state -> CheckedContinuation<[RelayLivenessFfi]?, any Error>? in
            guard !state.ended else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.pending.append(relays)
            return nil
        }
        waiter?.resume(returning: relays)
    }

    func cancel() {
        end(cancelled: true)
    }

    func finish() {
        end(cancelled: false)
    }

    private func end(cancelled: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<[RelayLivenessFfi]?, any Error>? in
            state.ended = true
            if cancelled { state.cancelled = true }
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}
