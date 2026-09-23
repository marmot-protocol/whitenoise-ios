import Foundation

nonisolated enum DonationStripeMode: String, Decodable, Equatable, Sendable {
    case test
    case live
}

nonisolated struct DonationRuntimeConfig: Decodable, Equatable, Sendable {
    let stripePublishableKey: String
    let stripeMode: DonationStripeMode

    private enum CodingKeys: String, CodingKey {
        case stripePublishableKey = "stripe_publishable_key"
        case stripeMode = "stripe_mode"
    }
}

nonisolated struct DonationDonor: Codable, Equatable, Sendable {
    let name: String
    let email: String
}

nonisolated struct DonationCreateRequest: Encodable, Equatable, Sendable {
    let attemptID: UUID
    let amountCents: Int
    let cadence: DonationCadence
    let paymentMethodID: String
    let donor: DonationDonor?
    var donorAccessToken: String? = nil
    var donorAccessNonce: String? = nil

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id"
        case amountCents = "amount_cents"
        case cadence
        case paymentMethodID = "payment_method_id"
        case donor
        case donorAccessToken = "donor_access_token"
        case donorAccessNonce = "donor_access_nonce"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attemptID.uuidString.lowercased(), forKey: .attemptID)
        try container.encode(amountCents, forKey: .amountCents)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(paymentMethodID, forKey: .paymentMethodID)
        if let donor {
            try container.encode(donor, forKey: .donor)
        } else {
            try container.encodeNil(forKey: .donor)
        }
        try container.encodeIfPresent(donorAccessToken, forKey: .donorAccessToken)
        try container.encodeIfPresent(donorAccessNonce, forKey: .donorAccessNonce)
    }
}

nonisolated struct DonationCreateResponse: Decodable, Equatable, Sendable {
    let clientSecret: String
    let receiptToken: String
    let donorAccessToken: String?
    let donorAccessExpiresAt: Int64?

    init(clientSecret: String, receiptToken: String, donorAccessToken: String? = nil, donorAccessExpiresAt: Int64? = nil) {
        self.clientSecret = clientSecret
        self.receiptToken = receiptToken
        self.donorAccessToken = donorAccessToken
        self.donorAccessExpiresAt = donorAccessExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case clientSecret = "client_secret"
        case receiptToken = "receipt_token"
        case donorAccessToken = "donor_access_token"
        case donorAccessExpiresAt = "donor_access_expires_at"
    }
}

nonisolated struct DonationPageRequest: Encodable, Sendable {
    let limit: Int
    let cursor: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(limit, forKey: .limit)
        if let cursor { try container.encode(cursor, forKey: .cursor) }
        else { try container.encodeNil(forKey: .cursor) }
    }

    private enum CodingKeys: String, CodingKey { case limit, cursor }
}

nonisolated struct DonationSupportPage: Decodable, Sendable {
    let version: Int
    let subscriptions: [DonationSubscriptionRecord]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case version, subscriptions, nextCursor = "next_cursor" }
}

nonisolated struct DonationSubscriptionRecord: Decodable, Identifiable, Sendable {
    let recordID: String
    let amountCents: Int
    let currency: String
    let status: DonationSubscriptionStatus
    let nextBillingAt: Int64?
    let scheduledCancelAt: Int64?
    let endedAt: Int64?
    var id: String { recordID }
    enum CodingKeys: String, CodingKey {
        case recordID = "record_id", amountCents = "amount_cents", currency, status
        case nextBillingAt = "next_billing_at", scheduledCancelAt = "scheduled_cancel_at", endedAt = "ended_at"
    }
}

nonisolated enum DonationSubscriptionStatus: String, Decodable, Sendable {
    case active, cancellationScheduled = "cancellation_scheduled", pastDue = "past_due"
    case unpaid, incomplete, canceled, unsupported
}

nonisolated struct DonationHistoryPage: Decodable, Sendable {
    let version: Int
    let items: [DonationBillingRecord]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case version, items, nextCursor = "next_cursor" }
}

nonisolated struct DonationBillingRecord: Decodable, Identifiable, Sendable {
    let recordID: String
    let amountCents: Int
    let currency: String
    let date: Int64
    let cadence: DonationCadence
    let paymentState: DonationBillingState
    let hasDocument: Bool
    var id: String { recordID }
    enum CodingKeys: String, CodingKey {
        case recordID = "record_id", amountCents = "amount_cents", currency, date, cadence
        case paymentState = "payment_state", hasDocument = "has_document"
    }
}

nonisolated enum DonationBillingState: String, Decodable, Sendable {
    case succeeded, pending, failed, credited, manualPaid = "manual_paid"
}

nonisolated struct DonationRenewalResponse: Decodable, Sendable {
    let version: Int
    let donorAccessToken: String
    let donorAccessExpiresAt: Int64
    enum CodingKeys: String, CodingKey {
        case version, donorAccessToken = "donor_access_token", donorAccessExpiresAt = "donor_access_expires_at"
    }
}

nonisolated enum DonationReceiptStatus: String, Decodable, Equatable, Sendable {
    case pending
    case failed
    case available
}

nonisolated struct DonationReceiptResponse: Decodable, Equatable, Sendable {
    let status: DonationReceiptStatus
    let url: URL?
}

nonisolated enum DonationClientError: Error, Equatable, Sendable {
    case invalidResponse
    case serviceUnavailable
    case invalidDonorAccess
}

nonisolated protocol DonationClient: Sendable {
    func configuration() async throws -> DonationRuntimeConfig
    func createDonation(_ request: DonationCreateRequest) async throws -> DonationCreateResponse
    func receipt(for token: String) async throws -> DonationReceiptResponse
    func supportSummary(token: String, cursor: String?) async throws -> DonationSupportPage
    func billingHistory(token: String, cursor: String?) async throws -> DonationHistoryPage
    func document(token: String, recordID: String) async throws -> DonationReceiptResponse
    func renew(token: String, renewalID: UUID, requestedAt: Int64) async throws -> DonationRenewalResponse
}

extension DonationClient {
    func supportSummary(token: String, cursor: String?) async throws -> DonationSupportPage { throw DonationClientError.serviceUnavailable }
    func billingHistory(token: String, cursor: String?) async throws -> DonationHistoryPage { throw DonationClientError.serviceUnavailable }
    func document(token: String, recordID: String) async throws -> DonationReceiptResponse { throw DonationClientError.serviceUnavailable }
    func renew(token: String, renewalID: UUID, requestedAt: Int64) async throws -> DonationRenewalResponse { throw DonationClientError.serviceUnavailable }
}

nonisolated protocol DonationDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DonationDataLoading {}

nonisolated final class URLSessionDonationClient: DonationClient {
    private let baseURL: URL
    private let loader: any DonationDataLoading

    init(baseURL: URL, loader: any DonationDataLoading = URLSessionDonationClient.ephemeralSession()) {
        self.baseURL = baseURL
        self.loader = loader
    }

    func configuration() async throws -> DonationRuntimeConfig {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/apple-pay/config"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: DonationRuntimeConfig = try await loadAndDecode(request)
        guard !response.stripePublishableKey.isEmpty else {
            throw DonationClientError.invalidResponse
        }
        return response
    }

    func createDonation(_ request: DonationCreateRequest) async throws -> DonationCreateResponse {
        let response: DonationCreateResponse = try await post(
            path: "v1/apple-pay/donations",
            body: request
        )
        guard !response.clientSecret.isEmpty, !response.receiptToken.isEmpty else {
            throw DonationClientError.invalidResponse
        }
        return response
    }

    func receipt(for token: String) async throws -> DonationReceiptResponse {
        struct ReceiptRequest: Encodable {
            let receiptToken: String

            private enum CodingKeys: String, CodingKey {
                case receiptToken = "receipt_token"
            }
        }

        let response: DonationReceiptResponse = try await post(
            path: "v1/apple-pay/donations/receipt",
            body: ReceiptRequest(receiptToken: token)
        )
        if response.status == .available {
            guard let url = response.url,
                  url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false
            else { throw DonationClientError.invalidResponse }
        }
        return response
    }

    func supportSummary(token: String, cursor: String?) async throws -> DonationSupportPage {
        let page: DonationSupportPage = try await post(
            path: "v1/donor/support-summary", body: DonationPageRequest(limit: 20, cursor: cursor), bearer: token
        )
        guard page.version == 1, page.subscriptions.allSatisfy({ $0.currency == "usd" && $0.amountCents > 0 }) else {
            throw DonationClientError.invalidResponse
        }
        return page
    }

    func billingHistory(token: String, cursor: String?) async throws -> DonationHistoryPage {
        let page: DonationHistoryPage = try await post(
            path: "v1/donor/billing-history", body: DonationPageRequest(limit: 20, cursor: cursor), bearer: token
        )
        guard page.version == 1, page.items.allSatisfy({ $0.currency == "usd" && $0.amountCents >= 0 }) else {
            throw DonationClientError.invalidResponse
        }
        return page
    }

    func document(token: String, recordID: String) async throws -> DonationReceiptResponse {
        struct Body: Encodable { let record_id: String }
        let response: DonationReceiptResponse = try await post(
            path: "v1/donor/document", body: Body(record_id: recordID), bearer: token
        )
        try validateReceipt(response)
        return response
    }

    func renew(token: String, renewalID: UUID, requestedAt: Int64) async throws -> DonationRenewalResponse {
        struct Body: Encodable { let renewal_id: String; let requested_at: Int64 }
        let response: DonationRenewalResponse = try await post(
            path: "v1/donor/access/renew",
            body: Body(renewal_id: renewalID.uuidString.lowercased(), requested_at: requestedAt), bearer: token
        )
        guard response.version == 1, !response.donorAccessToken.isEmpty,
              response.donorAccessExpiresAt > requestedAt else { throw DonationClientError.invalidResponse }
        return response
    }

    private func validateReceipt(_ response: DonationReceiptResponse) throws {
        if response.status == .available {
            guard let url = response.url, url.scheme?.lowercased() == "https",
                  ["pay.stripe.com", "invoice.stripe.com"].contains(url.host?.lowercased() ?? "")
            else { throw DonationClientError.invalidResponse }
        }
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        bearer: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)

        return try await loadAndDecode(request)
    }

    private func loadAndDecode<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await loadWithOneTransientRetry(request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else { throw DonationClientError.invalidResponse }
        if httpResponse.statusCode == 401,
           let code = try? JSONDecoder().decode(DonationErrorEnvelope.self, from: data).error.code,
           code == "invalid_donor_access" {
            throw DonationClientError.invalidDonorAccess
        }
        guard (200..<300).contains(httpResponse.statusCode) else { throw DonationClientError.serviceUnavailable }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DonationClientError.invalidResponse
        }
    }

    private struct DonationErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    private func loadWithOneTransientRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await loader.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where Self.isTransient(error) {
            try Task.checkCancellation()
            do {
                return try await loader.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw DonationClientError.serviceUnavailable
            }
        } catch {
            throw DonationClientError.serviceUnavailable
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet:
            true
        default:
            false
        }
    }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }
}
