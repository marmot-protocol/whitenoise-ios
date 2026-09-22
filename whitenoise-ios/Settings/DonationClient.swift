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

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id"
        case amountCents = "amount_cents"
        case cadence
        case paymentMethodID = "payment_method_id"
        case donor
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
    }
}

nonisolated struct DonationCreateResponse: Decodable, Equatable, Sendable {
    let clientSecret: String
    let receiptToken: String

    private enum CodingKeys: String, CodingKey {
        case clientSecret = "client_secret"
        case receiptToken = "receipt_token"
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
}

nonisolated protocol DonationClient: Sendable {
    func configuration() async throws -> DonationRuntimeConfig
    func createDonation(_ request: DonationCreateRequest) async throws -> DonationCreateResponse
    func receipt(for token: String) async throws -> DonationReceiptResponse
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

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        return try await loadAndDecode(request)
    }

    private func loadAndDecode<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await loadWithOneTransientRetry(request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else { throw DonationClientError.serviceUnavailable }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DonationClientError.invalidResponse
        }
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
