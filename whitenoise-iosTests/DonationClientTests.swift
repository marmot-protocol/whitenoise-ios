import Foundation
import Testing
@testable import whitenoise_ios

struct DonationClientTests {
    @Test func configurationGetsRuntimeStripeSettings() async throws {
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(
                status: 200,
                body: #"{"stripe_publishable_key":"pk_test_example","stripe_mode":"test"}"#
            ))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )

        let config = try await client.configuration()

        #expect(config == DonationRuntimeConfig(
            stripePublishableKey: "pk_test_example",
            stripeMode: .test
        ))
        let request = try #require(await loader.capturedRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/apple-pay/config")
        #expect(request.httpBody == nil)
    }

    @Test func createDonationPostsContractAndDecodesSuccess() async throws {
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(
                status: 200,
                body: #"{"client_secret":"pi_test_secret_value","receipt_token":"receipt-token"}"#
            ))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )
        let attemptID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let response = try await client.createDonation(DonationCreateRequest(
            attemptID: attemptID,
            amountCents: 2_500,
            cadence: .monthly,
            paymentMethodID: "pm_test",
            donor: DonationDonor(name: "Donor Name", email: "donor@example.com")
        ))

        #expect(response == DonationCreateResponse(
            clientSecret: "pi_test_secret_value",
            receiptToken: "receipt-token"
        ))
        let requests = await loader.capturedRequests()
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/apple-pay/donations")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["amount_cents"] as? Int == 2_500)
        #expect(object["cadence"] as? String == "monthly")
        #expect((object["donor"] as? [String: String])?["email"] == "donor@example.com")
    }

    @Test func transientFailureRetriesTheExactRequestOnce() async throws {
        let loader = DonationLoaderStub(outcomes: [
            .failure(URLError(.timedOut)),
            .success(httpResponse(
                status: 200,
                body: #"{"client_secret":"pi_test_secret_value","receipt_token":"receipt-token"}"#
            ))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )
        let request = DonationCreateRequest(
            attemptID: UUID(),
            amountCents: 1_000,
            cadence: .oneTime,
            paymentMethodID: "pm_test",
            donor: nil
        )

        _ = try await client.createDonation(request)

        let requests = await loader.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url == requests[1].url)
        #expect(requests[0].httpBody == requests[1].httpBody)
    }

    @Test(arguments: [400, 404, 500, 503])
    func nonSuccessResponsesAreServiceUnavailable(status: Int) async {
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(status: status, body: #"{"error":"do not display me"}"#))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )

        await #expect(throws: DonationClientError.serviceUnavailable) {
            try await client.createDonation(sampleRequest())
        }
    }

    @Test func malformedSuccessIsInvalidResponse() async {
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(status: 200, body: #"{"unexpected":true}"#))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )

        await #expect(throws: DonationClientError.invalidResponse) {
            try await client.createDonation(sampleRequest())
        }
    }

    @Test func cancellationIsPreserved() async {
        let loader = DonationLoaderStub(outcomes: [.failure(CancellationError())])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )

        await #expect(throws: CancellationError.self) {
            try await client.createDonation(sampleRequest())
        }
    }

    @Test(arguments: [false, true])
    func urlSessionCancellationIsPreservedIncludingAfterRetry(_ afterRetry: Bool) async {
        var outcomes: [Result<(Data, URLResponse), Error>] = []
        if afterRetry { outcomes.append(.failure(URLError(.timedOut))) }
        outcomes.append(.failure(URLError(.cancelled)))
        let loader = DonationLoaderStub(outcomes: outcomes)
        let client = URLSessionDonationClient(baseURL: URL(string: "https://payments.example")!, loader: loader)
        await #expect(throws: CancellationError.self) {
            try await client.receipt(for: "receipt-token")
        }
        #expect(await loader.capturedRequests().count == (afterRetry ? 2 : 1))
    }

    @Test func timeoutRetriesOnceThenMapsToServiceUnavailable() async {
        let loader = DonationLoaderStub(outcomes: [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )

        await #expect(throws: DonationClientError.serviceUnavailable) {
            try await client.createDonation(sampleRequest())
        }
        #expect(await loader.capturedRequests().count == 2)
    }

    @Test(arguments: [
        ("pending", nil),
        ("failed", nil),
        ("available", "https://pay.stripe.com/receipts/example")
    ])
    func decodesReceiptStates(status: String, url: String?) async throws {
        let urlFragment = url.map { #", "url":"\#($0)""# } ?? ""
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(status: 200, body: #"{"status":"\#(status)"\#(urlFragment)}"#))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )

        let response = try await client.receipt(for: "opaque-token")

        #expect(response.status.rawValue == status)
        #expect(response.url?.absoluteString == url)
        let request = try #require(await loader.capturedRequests().first)
        #expect(request.url?.path == "/v1/apple-pay/donations/receipt")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(object == ["receipt_token": "opaque-token"])
    }

    @Test func rejectsNonHTTPSAvailableReceipt() async {
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(
                status: 200,
                body: #"{"status":"available","url":"http://example.com/receipt"}"#
            ))
        ])
        let client = URLSessionDonationClient(
            baseURL: URL(string: "https://payments.example")!,
            loader: loader
        )

        await #expect(throws: DonationClientError.invalidResponse) {
            try await client.receipt(for: "opaque-token")
        }
    }

    @Test(arguments: [
        "https://evil.example/receipt",
        "https://pay.stripe.com.evil.example/receipt",
        "https://pay.stripe.com:8443/receipt",
        "https://user@pay.stripe.com/receipt"
    ])
    func rejectsUntrustedAvailableReceipt(_ url: String) async {
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(status: 200, body: #"{"status":"available","url":"\#(url)"}"#))
        ])
        let client = URLSessionDonationClient(baseURL: URL(string: "https://payments.example")!, loader: loader)
        await #expect(throws: DonationClientError.invalidResponse) {
            try await client.receipt(for: "opaque-token")
        }
    }

    @Test func linkedDonationSendsNonceAndDecodesCredential() async throws {
        let loader = DonationLoaderStub(outcomes: [.success(httpResponse(
            status: 200,
            body: #"{"client_secret":"pi_test_secret_value","receipt_token":"receipt","donor_access_token":"grant","donor_access_expires_at":1947680000}"#
        ))])
        let client = URLSessionDonationClient(baseURL: URL(string: "https://payments.example")!, loader: loader)
        let response = try await client.createDonation(DonationCreateRequest(
            attemptID: UUID(), amountCents: 1_000, cadence: .oneTime,
            paymentMethodID: "pm_test", donor: nil, donorAccessNonce: String(repeating: "A", count: 43)
        ))
        #expect(response.donorAccessToken == "grant")
        #expect(response.donorAccessExpiresAt == 1_947_680_000)
        let body = try #require(await loader.capturedRequests().first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["donor_access_nonce"] as? String == String(repeating: "A", count: 43))
        #expect(object["donor_access_token"] == nil)
    }

    @Test func donorReadsUseBearerAndDecodePagedStatus() async throws {
        let loader = DonationLoaderStub(outcomes: [.success(httpResponse(
            status: 200,
            body: #"{"version":1,"subscriptions":[{"record_id":"sub.opaque","amount_cents":2500,"currency":"usd","status":"cancellation_scheduled","next_billing_at":null,"scheduled_cancel_at":1800000000,"ended_at":null}],"next_cursor":"next"}"#
        ))])
        let client = URLSessionDonationClient(baseURL: URL(string: "https://payments.example")!, loader: loader)
        let page = try await client.supportSummary(token: "secret", cursor: nil)
        #expect(page.subscriptions.first?.status == .cancellationScheduled)
        #expect(page.nextCursor == "next")
        let request = try #require(await loader.capturedRequests().first)
        #expect(request.url?.path == "/v1/donor/support-summary")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["limit"] as? Int == 20)
        #expect(object["cursor"] is NSNull)
    }

    @Test func revokedDonorAccessIsDistinctFromTemporaryFailure() async {
        let loader = DonationLoaderStub(outcomes: [.success(httpResponse(
            status: 401, body: #"{"error":{"code":"invalid_donor_access"}}"#
        ))])
        let client = URLSessionDonationClient(baseURL: URL(string: "https://payments.example")!, loader: loader)
        await #expect(throws: DonationClientError.invalidDonorAccess) {
            try await client.billingHistory(token: "secret", cursor: nil)
        }
    }

    @Test func documentAndRenewalUseAuthenticatedPostBodies() async throws {
        let loader = DonationLoaderStub(outcomes: [
            .success(httpResponse(status: 200, body: #"{"status":"available","url":"https://invoice.stripe.com/i/example"}"#)),
            .success(httpResponse(status: 200, body: #"{"version":1,"donor_access_token":"grant","donor_access_expires_at":1947680000}"#))
        ])
        let client = URLSessionDonationClient(baseURL: URL(string: "https://payments.example")!, loader: loader)
        let document = try await client.document(token: "grant", recordID: "inv.opaque")
        #expect(document.status == .available)
        let renewalID = UUID()
        let renewed = try await client.renew(token: "grant", renewalID: renewalID, requestedAt: 1_790_000_000)
        #expect(renewed.donorAccessExpiresAt == 1_947_680_000)
        let requests = await loader.capturedRequests()
        #expect(requests.map { $0.url?.path } == ["/v1/donor/document", "/v1/donor/access/renew"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer grant" })
        let documentData = try #require(requests[0].httpBody)
        let documentBody = try #require(JSONSerialization.jsonObject(with: documentData) as? [String: String])
        #expect(documentBody["record_id"] == "inv.opaque")
        let renewalData = try #require(requests[1].httpBody)
        let renewalBody = try #require(JSONSerialization.jsonObject(with: renewalData) as? [String: Any])
        #expect(renewalBody["renewal_id"] as? String == renewalID.uuidString.lowercased())
        #expect(renewalBody["requested_at"] as? Int == 1_790_000_000)
    }

    private func sampleRequest() -> DonationCreateRequest {
        DonationCreateRequest(
            attemptID: UUID(),
            amountCents: 2_500,
            cadence: .oneTime,
            paymentMethodID: "pm_test",
            donor: nil
        )
    }
}

private actor DonationLoaderStub: DonationDataLoading {
    private var outcomes: [Result<(Data, URLResponse), Error>]
    private var requests: [URLRequest] = []

    init(outcomes: [Result<(Data, URLResponse), Error>]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !outcomes.isEmpty else { throw URLError(.unknown) }
        return try outcomes.removeFirst().get()
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private func httpResponse(status: Int, body: String) -> (Data, URLResponse) {
    let url = URL(string: "https://payments.example")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}
