import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct DonateViewModelTests {
    @Test func unavailableConfigurationKeepsApplePayDisabled() {
        let model = DonateViewModel(config: nil)

        #expect(model.availability == .notConfigured)
        #expect(!model.canDonate)
        #expect(model.selectedAmountCents == 2_500)
    }

    @Test func selectionAndCustomValidationDriveTheDraft() {
        let client = DonationClientFake(receipts: [])
        let coordinator = DonationCoordinatorFake()
        let model = DonateViewModel(
            client: client,
            coordinator: coordinator,
            locale: Locale(identifier: "en_US")
        )

        model.selectCustom()
        model.customAmountText = "10.25"
        model.customAmountChanged()
        #expect(model.selectedAmountCents == 1_025)
        #expect(model.draft == DonationDraft(amountCents: 1_025, cadence: .oneTime))

        model.customAmountText = "10.001"
        model.customAmountChanged()
        #expect(model.selectedAmountCents == nil)
        #expect(model.customAmountErrorMessage == L10n.string(
            "Enter a valid USD amount with no more than two decimal places."
        ))
    }

    @Test func successfulDonationShowsCompletionAndAvailableReceipt() async {
        let receiptURL = URL(string: "https://dashboard.stripe.com/receipt/example")!
        let client = DonationClientFake(receipts: [
            .success(DonationReceiptResponse(status: .available, url: receiptURL))
        ])
        let coordinator = DonationCoordinatorFake(
            donationResult: .success(DonationPaymentSuccess(receiptToken: "receipt-token"))
        )
        let model = DonateViewModel(client: client, coordinator: coordinator)

        model.startDonation()
        await waitUntil { !model.isProcessing }

        #expect(model.paymentSucceeded)
        #expect(model.receiptStatus == .available)
        #expect(model.receiptURL == receiptURL)
        #expect(model.errorMessage == nil)
        #expect(coordinator.drafts == [DonationDraft(amountCents: 2_500, cadence: .oneTime)])
        #expect(await client.receiptTokens() == ["receipt-token"])
    }

    @Test func pendingReceiptCanBeCheckedManually() async {
        let receiptURL = URL(string: "https://dashboard.stripe.com/receipt/example")!
        let client = DonationClientFake(receipts: [
            .success(DonationReceiptResponse(status: .pending, url: nil)),
            .success(DonationReceiptResponse(status: .available, url: receiptURL))
        ])
        let coordinator = DonationCoordinatorFake(
            donationResult: .success(DonationPaymentSuccess(receiptToken: "receipt-token"))
        )
        let model = DonateViewModel(client: client, coordinator: coordinator)

        model.startDonation()
        await waitUntil { !model.isProcessing }
        #expect(model.receiptStatus == .pending)
        #expect(model.canCheckReceipt)

        model.checkReceipt()
        await waitUntil { model.receiptURL != nil }
        #expect(model.receiptStatus == .available)
        #expect(model.receiptURL == receiptURL)
    }

    @Test func paymentFailuresUseAppOwnedLocalizedCopy() async {
        let client = DonationClientFake(receipts: [])
        let coordinator = DonationCoordinatorFake(
            donationResult: .failure(DonationPaymentCoordinatorError.paymentFailed)
        )
        let model = DonateViewModel(client: client, coordinator: coordinator)

        model.startDonation()
        await waitUntil { !model.isProcessing }

        #expect(!model.paymentSucceeded)
        #expect(model.errorMessage == L10n.string(
            "The donation couldn't be completed. Please try again."
        ))
    }

    @Test func missingMonthlyContactHasSpecificGuidance() async {
        let client = DonationClientFake(receipts: [])
        let coordinator = DonationCoordinatorFake(
            donationResult: .failure(DonationPaymentCoordinatorError.missingDonorContact)
        )
        let model = DonateViewModel(client: client, coordinator: coordinator)
        model.cadence = .monthly
        model.cadenceChanged()

        model.startDonation()
        await waitUntil { !model.isProcessing }

        #expect(model.errorMessage == L10n.string(
            "Apple Pay needs your name and email for monthly donations."
        ))
    }

    @Test func cancellationClearsProcessingAndCancelsCoordinator() async {
        let client = DonationClientFake(receipts: [])
        let coordinator = DonationCoordinatorFake(waitForCancellation: true)
        let model = DonateViewModel(client: client, coordinator: coordinator)

        model.startDonation()
        await Task.yield()
        #expect(model.isProcessing)

        model.cancel()
        await Task.yield()
        #expect(!model.isProcessing)
        #expect(coordinator.cancelCallCount == 1)
    }

    @Test func preparingApplePayEnablesRuntimeConfiguredCoordinator() async {
        let client = DonationClientFake(receipts: [])
        let coordinator = DonationCoordinatorFake()
        let model = DonateViewModel(
            client: client,
            coordinator: coordinator,
            isApplePayPrepared: false
        )

        #expect(model.availability == .notConfigured)
        await model.prepareApplePay()
        #expect(model.availability == .ready)
        #expect(coordinator.prepareCallCount == 1)
    }

    @Test func failedPreparationCanRetryWithoutReopeningDonate() async {
        let coordinator = DonationCoordinatorFake()
        coordinator.prepareResults = [
            .failure(DonationClientError.serviceUnavailable),
            .success(())
        ]
        let model = DonateViewModel(
            client: DonationClientFake(receipts: []),
            coordinator: coordinator,
            isApplePayPrepared: false
        )

        await model.prepareApplePay()
        #expect(model.availability == .notConfigured)
        #expect(model.applePayPreparationFailed)
        #expect(!model.isPreparingApplePay)

        await model.prepareApplePay()
        #expect(model.availability == .ready)
        #expect(!model.applePayPreparationFailed)
        #expect(coordinator.prepareCallCount == 2)
    }

    @Test func cancelledPreparationDoesNotShowRetryError() async {
        let coordinator = DonationCoordinatorFake()
        coordinator.prepareResults = [.failure(CancellationError())]
        let model = DonateViewModel(
            client: DonationClientFake(receipts: []),
            coordinator: coordinator,
            isApplePayPrepared: false
        )

        await model.prepareApplePay()

        #expect(model.availability == .notConfigured)
        #expect(!model.applePayPreparationFailed)
    }

    @Test func availabilityRefreshDetectsCardAddedDuringWalletSetup() {
        let coordinator = DonationCoordinatorFake()
        coordinator.availabilityValue = .setupRequired
        let model = DonateViewModel(
            client: DonationClientFake(receipts: []),
            coordinator: coordinator
        )
        #expect(model.availability == .setupRequired)

        coordinator.availabilityValue = .ready
        model.refreshApplePayAvailability()

        #expect(model.availability == .ready)
        #expect(model.canDonate)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}

private actor DonationClientFake: DonationClient {
    private var receipts: [Result<DonationReceiptResponse, Error>]
    private var requestedReceiptTokens: [String] = []

    init(receipts: [Result<DonationReceiptResponse, Error>]) {
        self.receipts = receipts
    }

    func configuration() async throws -> DonationRuntimeConfig {
        DonationRuntimeConfig(stripePublishableKey: "pk_test_example", stripeMode: .test)
    }

    func createDonation(_ request: DonationCreateRequest) async throws -> DonationCreateResponse {
        throw DonationClientError.serviceUnavailable
    }

    func receipt(for token: String) async throws -> DonationReceiptResponse {
        requestedReceiptTokens.append(token)
        guard !receipts.isEmpty else { throw DonationClientError.serviceUnavailable }
        return try receipts.removeFirst().get()
    }

    func receiptTokens() -> [String] {
        requestedReceiptTokens
    }
}

@MainActor
private final class DonationCoordinatorFake: DonationPaymentCoordinating {
    var availabilityValue: DonationApplePayAvailability = .ready
    var donationResult: Result<DonationPaymentSuccess, Error>
    var drafts: [DonationDraft] = []
    var cancelCallCount = 0
    var prepareCallCount = 0
    var prepareResults: [Result<Void, Error>] = []
    private let waitForCancellation: Bool

    init(
        donationResult: Result<DonationPaymentSuccess, Error> = .failure(CancellationError()),
        waitForCancellation: Bool = false
    ) {
        self.donationResult = donationResult
        self.waitForCancellation = waitForCancellation
    }

    func prepare() async throws {
        prepareCallCount += 1
        if !prepareResults.isEmpty {
            try prepareResults.removeFirst().get()
        }
    }

    func availability(for draft: DonationDraft) -> DonationApplePayAvailability {
        availabilityValue
    }

    func donate(_ draft: DonationDraft) async throws -> DonationPaymentSuccess {
        drafts.append(draft)
        if waitForCancellation {
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        return try donationResult.get()
    }

    func openPaymentSetup() {}

    func cancel() {
        cancelCallCount += 1
    }
}
