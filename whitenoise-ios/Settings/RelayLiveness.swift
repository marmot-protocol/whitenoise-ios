import Foundation
import MarmotKit

@MainActor
protocol RelayLivenessDataSource: AnyObject {
    func subscribeRelayLiveness(accountRef: String) async throws -> any RelayLivenessSubscriptionProtocol
    func reconnectRelay(accountRef: String, url: String) async throws -> RelayLivenessFfi
    func present(_ toast: Toast)
}

extension AppState: RelayLivenessDataSource {
    func subscribeRelayLiveness(accountRef: String) async throws -> any RelayLivenessSubscriptionProtocol {
        try await currentMarmotClient().subscribeRelayLiveness(accountRef: accountRef)
    }

    func reconnectRelay(accountRef: String, url: String) async throws -> RelayLivenessFfi {
        try await currentMarmotClient().reconnectRelay(accountRef: accountRef, url: url)
    }
}

/// Live connection state for the Relays screen's Connection Status section.
/// MDK lists every relay the account uses (default, bootstrap, NIP-65 and
/// inbox); reads never dial, and only Reconnect does.
@MainActor
@Observable
final class RelayLivenessModel {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    /// nil until the first snapshot arrives.
    private(set) var relays: [RelayLivenessFfi]?
    private(set) var loadFailed = false
    private(set) var reconnectingURLs: Set<String> = []

    private var accountRef: String?
    private var observation = 0

    /// Watches `accountRef` for as long as the calling task runs. Cancelling
    /// that task cancels the subscription, which ends MDK's pending `next()`.
    func observe(accountRef: String?, using dataSource: any RelayLivenessDataSource) async {
        observation &+= 1
        let ticket = observation
        self.accountRef = accountRef
        relays = nil
        loadFailed = false
        reconnectingURLs = []
        guard let accountRef else { return }

        let subscription: any RelayLivenessSubscriptionProtocol
        do {
            subscription = try await dataSource.subscribeRelayLiveness(accountRef: accountRef)
        } catch {
            if !Task.isCancelled, observation == ticket { loadFailed = true }
            return
        }
        await withTaskCancellationHandler {
            guard !Task.isCancelled, observation == ticket else { return }
            relays = subscription.snapshot()
            // nil after cancel() or runtime shutdown; an error also ends the watch
            // and keeps the last list, which the next observation replaces.
            while let next = try? await subscription.next() {
                guard !Task.isCancelled, observation == ticket else { break }
                relays = next
            }
        } onCancel: {
            subscription.cancel()
        }
        subscription.cancel()
    }

    func reconnect(url: String, using dataSource: any RelayLivenessDataSource) async {
        guard let accountRef, !reconnectingURLs.contains(url) else { return }
        let ticket = observation
        reconnectingURLs.insert(url)
        defer { if observation == ticket { reconnectingURLs.remove(url) } }
        do {
            let updated = try await dataSource.reconnectRelay(accountRef: accountRef, url: url)
            guard observation == ticket else { return }
            relays = RelayLivenessPresentation.replacing(updated, in: relays)
        } catch is CancellationError {
            return
        } catch {
            guard observation == ticket else { return }
            dataSource.present(UserFacingError.toast(title: L10n.string("Couldn't reconnect relay"), error: error))
        }
    }
}

nonisolated enum RelayLivenessPresentation {
    struct Row: Equatable {
        let url: String
        let display: String
        let status: RelayStatusFfi
        let statusText: String
        let detail: String?
        let canReconnect: Bool
    }

    static func rows(
        _ relays: [RelayLivenessFfi],
        now: Date = Date(),
        locale: Locale = AppLanguage.currentLocale
    ) -> [Row] {
        relays.map { relay in
            Row(
                url: relay.url,
                display: RelaySettings.editableRelayDisplay(relay.url),
                status: relay.status,
                statusText: statusText(relay.status),
                detail: detail(relay, now: now, locale: locale),
                canReconnect: canReconnect(relay.status)
            )
        }
    }

    static func statusText(_ status: RelayStatusFfi) -> String {
        switch status {
        case .connected: L10n.string("Connected")
        case .connecting: L10n.string("Connecting…")
        case .offline: L10n.string("Offline")
        case .unknown: L10n.string("Not checked yet")
        }
    }

    /// A relay that is connected or already dialling has nothing to retry.
    static func canReconnect(_ status: RelayStatusFfi) -> Bool {
        switch status {
        case .offline, .unknown: true
        case .connected, .connecting: false
        }
    }

    /// When the last attempt was, for relays that aren't connected.
    static func detail(_ relay: RelayLivenessFfi, now: Date, locale: Locale) -> String? {
        guard relay.status != .connected, let seconds = relay.lastAttemptUnix, seconds > 0 else { return nil }
        let attempt = Date(timeIntervalSince1970: TimeInterval(Int64(clamping: seconds)))
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return L10n.formatted("Last tried %@", formatter.localizedString(for: min(attempt, now), relativeTo: now))
    }

    /// Applies a Reconnect result to the current list by URL.
    static func replacing(_ updated: RelayLivenessFfi, in relays: [RelayLivenessFfi]?) -> [RelayLivenessFfi]? {
        relays.map { list in list.map { $0.url == updated.url ? updated : $0 } }
    }
}
