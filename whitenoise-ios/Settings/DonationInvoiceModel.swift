import Foundation
import Observation

@MainActor
@Observable
final class DonationInvoiceModel {
    enum State: Equatable {
        case loading
        case pending
        case unavailable
        case available(URL)

        var url: URL? {
            guard case let .available(url) = self else { return nil }
            return url
        }
    }

    private(set) var state: State
    private let source: DonationInvoiceSource
    private var loadID: UUID?

    init(payment: DonationPayment) {
        source = payment.invoice
        if case let .url(url) = source {
            state = .available(url)
        } else if payment.receiptFailed || source == .unavailable {
            state = .unavailable
        } else if let receipt = payment.receipt {
            state = Self.state(for: receipt)
        } else {
            state = .loading
        }
    }

    var canRetry: Bool { source != .unavailable }

    func retry() {
        loadID = nil
        switch source {
        case let .url(url): state = .available(url)
        case .receiptToken, .recordID: state = .loading
        case .unavailable: state = .unavailable
        }
    }

    func load(
        using fetch: (String) async throws -> DonationReceiptResponse,
        fetchDocument: (String) async throws -> DonationReceiptResponse = { _ in throw DonationClientError.serviceUnavailable }
    ) async {
        guard state == .loading else { return }
        let id = UUID()
        loadID = id
        do {
            try Task.checkCancellation()
            let response: DonationReceiptResponse
            switch source {
            case let .receiptToken(token): response = try await fetch(token)
            case let .recordID(id): response = try await fetchDocument(id)
            case .url, .unavailable: return
            }
            try Task.checkCancellation()
            guard loadID == id else { return }
            state = Self.state(for: response)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), loadID == id else { return }
            state = .unavailable
        }
    }

    private static func state(for response: DonationReceiptResponse) -> State {
        switch response.status {
        case .pending: .pending
        case .failed: .unavailable
        case .available: response.url.map(State.available) ?? .unavailable
        }
    }
}
