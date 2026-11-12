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

    @Test func reconnectReplacesOnlyThatRelaysRow() async throws {
        let subscription = FakeRelayLivenessSubscription(snapshot: [relay(eu, .offline), relay(us, .connected)])
        let source = RelayLivenessDataSourceStub(subscription: subscription)
        source.reconnectResult = .success(relay(eu, .connected))
        let model = RelayLivenessModel()
        let watch = Task { await model.observe(accountRef: "account", using: source) }
        try await eventually { model.relays != nil }

        await model.reconnect(url: eu, using: source)

        #expect(source.reconnects == [ReconnectCall(accountRef: "account", url: eu)])
        #expect(model.relays == [relay(eu, .connected), relay(us, .connected)])
        #expect(model.reconnectingURLs.isEmpty)
        #expect(source.presentedToasts.isEmpty)
        watch.cancel()
        await watch.value
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

    @Test func aFutureAttemptTimeReadsAsNowRatherThanAhead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = relay(eu, .offline, lastAttempt: UInt64(now.timeIntervalSince1970) + 3_600)
        let present = relay(eu, .offline, lastAttempt: UInt64(now.timeIntervalSince1970))
        let locale = Locale(identifier: "en")

        #expect(RelayLivenessPresentation.detail(future, now: now, locale: locale)
            == RelayLivenessPresentation.detail(present, now: now, locale: locale))
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
        return try reconnectResult.get()
    }

    func present(_ toast: Toast) {
        presentedToasts.append(toast)
    }
}

/// Stands in for MDK's subscription: `next()` waits for `deliver`, and
/// returns nil after `cancel()` or `finish()`, as MDK does after cancel or
/// runtime shutdown.
private final class FakeRelayLivenessSubscription: RelayLivenessSubscriptionProtocol {
    private struct State {
        var pending: [[RelayLivenessFfi]] = []
        var waiter: CheckedContinuation<[RelayLivenessFfi]?, Never>?
        var ended = false
        var cancelled = false
    }

    private let initial: [RelayLivenessFfi]
    private let state = Mutex(State())

    init(snapshot: [RelayLivenessFfi]) {
        initial = snapshot
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func snapshot() -> [RelayLivenessFfi] { initial }

    func next() async throws -> [RelayLivenessFfi]? {
        await withCheckedContinuation { continuation in
            let ready: [RelayLivenessFfi]?? = state.withLock { state in
                if !state.pending.isEmpty { return .some(state.pending.removeFirst()) }
                if state.ended { return .some(nil) }
                state.waiter = continuation
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func deliver(_ relays: [RelayLivenessFfi]) {
        let waiter = state.withLock { state -> CheckedContinuation<[RelayLivenessFfi]?, Never>? in
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
        let waiter = state.withLock { state -> CheckedContinuation<[RelayLivenessFfi]?, Never>? in
            state.ended = true
            if cancelled { state.cancelled = true }
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}
