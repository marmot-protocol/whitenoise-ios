import Foundation
import PassKit
import StripeApplePay

@MainActor
enum DonationPaymentRequestFactory {
    static func make(draft: DonationDraft, config: DonationBuildConfig) -> PKPaymentRequest {
        let request = StripeAPI.paymentRequest(
            withMerchantIdentifier: config.merchantIdentifier,
            country: "US",
            currency: "USD"
        )
        let amount = NSDecimalNumber(value: draft.amountCents).dividing(by: 100)

        switch draft.cadence {
        case .oneTime:
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(
                    label: L10n.string("IPF General Fund Donation"),
                    amount: amount
                )
            ]
            request.requiredBillingContactFields = []
            request.requiredShippingContactFields = []
        case .monthly:
            let regularBilling = PKRecurringPaymentSummaryItem(
                label: L10n.string("IPF General Fund Donation"),
                amount: amount
            )
            regularBilling.intervalUnit = .month
            regularBilling.intervalCount = 1
            request.paymentSummaryItems = [regularBilling]

            let recurringRequest = PKRecurringPaymentRequest(
                paymentDescription: L10n.string("Monthly donation to IPF"),
                regularBilling: regularBilling,
                managementURL: config.managementURL
            )
            recurringRequest.billingAgreement = L10n.formatted(
                "%@ will be donated each month until you cancel.",
                DonatePresentation.formattedAmount(cents: draft.amountCents)
            )
            request.recurringPaymentRequest = recurringRequest
            request.requiredBillingContactFields = []
            request.requiredShippingContactFields = [.name, .emailAddress]
        }

        return request
    }
}

@MainActor
enum DonationDonorFactory {
    static func make(from contact: PKContact?) throws -> DonationDonor {
        guard let contact,
              let nameComponents = contact.name,
              let email = contact.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else { throw DonationPaymentCoordinatorError.missingDonorContact }

        let name = PersonNameComponentsFormatter.localizedString(
            from: nameComponents,
            style: .default,
            options: []
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DonationPaymentCoordinatorError.missingDonorContact }

        return DonationDonor(
            name: String(name.prefix(200)),
            email: String(email.prefix(320))
        )
    }
}

@MainActor
final class ApplePayDonationCoordinator: NSObject, DonationPaymentCoordinating, ApplePayContextDelegate {
    private let config: DonationBuildConfig
    private let client: any DonationClient
    private let accessStore: (any DonationAccessStoring)?

    private var context: STPApplePayContext?
    private var authorization: DonationAuthorizationContext?
    private var receiptToken: String?
    private var pendingCredential: DonationAccessCredential?
    private var pendingHistoryAccessUnavailable = false
    private var continuation: CheckedContinuation<DonationPaymentSuccess, Error>?
    private var isConfigured = false

    init(config: DonationBuildConfig, client: any DonationClient, accessStore: (any DonationAccessStoring)? = nil) {
        self.config = config
        self.client = client
        self.accessStore = accessStore
    }

    func prepare() async throws {
        guard !isConfigured else { return }
        let runtimeConfig = try await client.configuration()
        try Task.checkCancellation()
        guard config.validates(runtimeConfig) else {
            throw DonationPaymentCoordinatorError.unavailable
        }
        STPAPIClient.shared.publishableKey = runtimeConfig.stripePublishableKey
        isConfigured = true
    }

    func availability(for draft: DonationDraft) -> DonationApplePayAvailability {
        guard isConfigured else { return .notConfigured }
        guard PKPaymentAuthorizationController.canMakePayments() else { return .unavailable }
        let request = DonationPaymentRequestFactory.make(draft: draft, config: config)
        return PKPaymentAuthorizationController.canMakePayments(usingNetworks: request.supportedNetworks)
            ? .ready : .setupRequired
    }

    func donate(_ draft: DonationDraft) async throws -> DonationPaymentSuccess {
        guard continuation == nil, context == nil else {
            throw DonationPaymentCoordinatorError.alreadyActive
        }
        guard availability(for: draft) == .ready else {
            throw DonationPaymentCoordinatorError.unavailable
        }

        let credential: DonationAccessCredential?
        do { credential = try accessStore?.load() }
        catch { throw DonationPaymentCoordinatorError.unavailable }
        if let credential, credential.expiresAt <= .now {
            try? accessStore?.markLostAccess()
            throw DonationPaymentCoordinatorError.accessExpired
        }
        var nonce: String?
        if credential == nil, accessStore != nil {
            do { nonce = try DonationAccessNonce.generate() }
            catch { throw DonationPaymentCoordinatorError.unavailable }
        }

        let request = DonationPaymentRequestFactory.make(draft: draft, config: config)
        guard let context = STPApplePayContext(paymentRequest: request, delegate: self) else {
            throw DonationPaymentCoordinatorError.invalidPaymentRequest
        }

        context.apiClient = STPAPIClient.shared
        self.context = context
        authorization = DonationAuthorizationContext(draft: draft, accessToken: credential?.token, accessNonce: nonce)
        receiptToken = nil
        pendingCredential = nil
        pendingHistoryAccessUnavailable = false

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            context.presentApplePay()
        }
    }

    func openPaymentSetup() {
        PKPassLibrary().openPaymentSetup()
    }

    func cancel() {
        guard context != nil || continuation != nil else { return }
        let dismissedContext = context
        finish(.failure(CancellationError()))
        dismissedContext?.dismiss()
    }

    func applePayContext(
        _ context: STPApplePayContext,
        didCreatePaymentMethod paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment
    ) async throws -> String {
        guard context === self.context,
              let authorization
        else { throw CancellationError() }

        let donor: DonationDonor?
        switch authorization.draft.cadence {
        case .oneTime:
            donor = nil
        case .monthly:
            donor = try DonationDonorFactory.make(from: paymentInformation.shippingContact)
        }

        let response: DonationCreateResponse
        do {
            response = try await client.createDonation(
                authorization.request(paymentMethodID: paymentMethod.id, donor: donor)
            )
        } catch DonationClientError.invalidDonorAccess {
            try? accessStore?.markLostAccess()
            throw DonationPaymentCoordinatorError.accessExpired
        }
        guard context === self.context else { throw CancellationError() }
        if accessStore != nil {
            if let token = response.donorAccessToken, !token.isEmpty,
               let expiry = response.donorAccessExpiresAt,
               expiry > Int64(Date.now.timeIntervalSince1970) {
                pendingCredential = DonationAccessCredential(token: token, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)))
            } else {
                pendingCredential = nil
                pendingHistoryAccessUnavailable = authorization.accessToken == nil
            }
        }
        receiptToken = response.receiptToken
        return response.clientSecret
    }

    func applePayContext(
        _ context: STPApplePayContext,
        didCompleteWith status: STPApplePayContext.PaymentStatus,
        error: Error?
    ) {
        guard context === self.context else { return }
        switch status {
        case .success:
            guard let receiptToken else {
                finish(.failure(DonationPaymentCoordinatorError.paymentFailed))
                return
            }
            finish(.success(DonationPaymentSuccess(
                receiptToken: receiptToken,
                credential: pendingCredential,
                historyAccessUnavailable: pendingHistoryAccessUnavailable
            )))
        case .error:
            finish(.failure(DonationPaymentCoordinatorError.completionError(error)))
        case .userCancellation:
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<DonationPaymentSuccess, Error>) {
        let continuation = continuation
        self.continuation = nil
        context = nil
        authorization = nil
        receiptToken = nil
        pendingCredential = nil
        pendingHistoryAccessUnavailable = false
        continuation?.resume(with: result)
    }
}

extension DonateViewModel {
    convenience init(
        config: DonationBuildConfig? = DonationBuildConfig.current(),
        locale: Locale = .autoupdatingCurrent
    ) {
        guard let config else {
            self.init(client: nil, coordinator: nil, locale: locale)
            return
        }
        let client = URLSessionDonationClient(baseURL: config.serviceURL)
        let accessStore = DonationKeychainAccessStore(environment: config.environment)
        self.init(
            client: client,
            coordinator: ApplePayDonationCoordinator(config: config, client: client, accessStore: accessStore),
            accessStore: accessStore,
            managementURL: config.managementURL,
            locale: locale,
            isApplePayPrepared: false
        )
    }
}
