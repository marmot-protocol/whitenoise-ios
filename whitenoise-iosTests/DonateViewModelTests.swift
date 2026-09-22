import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct DonateViewModelTests {
    @Test func unavailableConfigurationKeepsApplePayDisabled() {
        let model = DonateViewModel(client: nil, coordinator: nil)

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

        model.updateCustomAmount("10.25")
        #expect(model.selectedAmountCents == 1_025)
        #expect(model.draft == DonationDraft(amountCents: 1_025, cadence: .oneTime))

        model.updateCustomAmount("10.001")
        #expect(model.selectedAmountCents == nil)
        #expect(model.customAmountErrorMessage == L10n.string(
            "Use up to two decimal places."
        ))
    }

    @Test func editingVisibleCustomAmountSelectsCustomAndPresetClearsIt() {
        let model = DonateViewModel(
            client: DonationClientFake(receipts: []),
            coordinator: DonationCoordinatorFake(),
            locale: Locale(identifier: "en_US")
        )

        model.updateCustomAmount("12.50")
        #expect(model.amountSelection == .custom)
        #expect(model.selectedAmountCents == 1_250)

        model.selectPreset(5_000)
        #expect(model.amountSelection == .preset(5_000))
        #expect(model.customAmountText.isEmpty)
        #expect(model.selectedAmountCents == 5_000)

        model.updateCustomAmount("")
        #expect(model.amountSelection == .custom)
        #expect(!model.canDonate)
    }

    @Test func rejectedPastePreservesAmountAndBlocksPaymentUntilCorrected() {
        let coordinator = DonationCoordinatorFake()
        let model = DonateViewModel(client: DonationClientFake(receipts: []), coordinator: coordinator,
                                    locale: Locale(identifier: "en_US"))
        model.updateCustomAmount("25")
        #expect(model.decideAmountEdit(current: "25", range: NSRange(location: 0, length: 2), replacement: "10.001", isPaste: true) == .reject(.tooPrecise))
        #expect(model.customAmountText == "25")
        #expect(model.customAmountErrorMessage == L10n.string("Use up to two decimal places."))
        #expect(!model.canDonate)
        model.startDonation()
        #expect(!model.isProcessing)
        #expect(coordinator.drafts.isEmpty)
        model.updateCustomAmount("10.25")
        #expect(model.canDonate)
        #expect(model.customAmountErrorMessage == nil)
    }

    @Test func applePaySetupAndUnavailableRemainDistinctAndRefreshOnReturn() {
        let coordinator = DonationCoordinatorFake()
        coordinator.availabilityValue = .setupRequired
        let model = DonateViewModel(client: DonationClientFake(receipts: []), coordinator: coordinator)
        #expect(model.availability == .setupRequired)
        #expect(!model.canDonate)
        model.openPaymentSetup()
        #expect(coordinator.setupCallCount == 1)
        coordinator.availabilityValue = .ready
        model.refreshApplePayAvailability()
        #expect(model.availability == .ready)
        #expect(model.canDonate)
        coordinator.availabilityValue = .unavailable
        model.refreshApplePayAvailability()
        model.openPaymentSetup()
        #expect(coordinator.setupCallCount == 1)
        #expect(!model.canDonate)
    }

    @Test func customAmountCannotChangeDuringPayment() {
        let model = DonateViewModel(client: DonationClientFake(receipts: []), coordinator: DonationCoordinatorFake())
        model.startDonation()
        defer { model.cancel() }

        model.updateCustomAmount("99")
        #expect(model.amountSelection == .preset(2_500))
        #expect(model.customAmountText.isEmpty)
    }

    @Test func successfulDonationDefersReceiptLoadingUntilInvoiceIsOpened() async throws {
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
        #expect(model.completedPayments.first?.receipt == nil)
        #expect(await client.receiptTokens().isEmpty)
        #expect(model.successfulPayment?.cadence == .oneTime)
        #expect(model.errorMessage == nil)
        _ = try await model.receipt(for: "receipt-token")
        #expect(model.completedPayments.first?.receipt?.url == receiptURL)
        #expect(coordinator.drafts == [DonationDraft(amountCents: 2_500, cadence: .oneTime)])
        #expect(await client.receiptTokens() == ["receipt-token"])
    }

    @Test func completedPaymentsKeepTheirCadenceAndInvoiceAfterEditingTheForm() async throws {
        let response = DonationReceiptResponse(status: .pending, url: nil)
        let client = DonationClientFake(receipts: [.success(response), .success(response), .success(response)])
        let coordinator = DonationCoordinatorFake(
            donationResult: .success(DonationPaymentSuccess(receiptToken: "original-receipt"))
        )
        let model = DonateViewModel(client: client, coordinator: coordinator)
        model.startDonation()
        await waitUntil { !model.isProcessing }
        model.cadence = .monthly
        model.selectPreset(5_000)
        model.startDonation()
        await waitUntil { !model.isProcessing }

        #expect(model.completedPayments.count == 2)
        #expect(model.completedPayments.map(\.cadence) == [.monthly, .oneTime])
        #expect(model.completedPayments.map(\.amountCents) == [5_000, 2_500])
        #expect(Set(model.completedPayments.map(\.id)).count == 2)
        model.updateCustomAmount("100")
        let payment = try #require(model.completedPayments.last)
        guard case let .receiptToken(token) = payment.invoice else {
            Issue.record("Missing invoice token")
            return
        }
        let invoice = try await model.receipt(for: token)
        #expect(invoice.status == .pending)
        #expect(await client.receiptTokens().last == "original-receipt")
        #expect(coordinator.drafts.count == 2)
    }

    @Test func pendingInvoiceCanBeRetriedFromPaymentHistory() async throws {
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
        _ = try await model.receipt(for: "receipt-token")
        #expect(model.completedPayments.first?.receipt?.status == .pending)

        _ = try await model.receipt(for: "receipt-token")
        #expect(model.completedPayments.first?.receipt?.status == .available)
        #expect(model.completedPayments.first?.receipt?.url == receiptURL)
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
        #expect(model.completedPayments.isEmpty)
        #expect(model.errorMessage == L10n.string(
            "The donation couldn't be completed. Please try again."
        ))
    }

    @Test func missingContactRestoresTheFormWithoutDuplicatingApplePayValidation() async {
        let model = DonateViewModel(
            client: DonationClientFake(receipts: []),
            coordinator: DonationCoordinatorFake(donationResult: .failure(DonationPaymentCoordinatorError.missingDonorContact))
        )
        model.cadence = .monthly
        model.startDonation()
        await waitUntil { !model.isProcessing }

        #expect(model.errorMessage == nil)
        #expect(!model.paymentSucceeded)
        #expect(model.completedPayments.isEmpty)
        #expect(model.canDonate)
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

    @Test func canceledAttemptCannotClearANewerPaymentOrPublishAnError() async {
        let coordinator = ControlledDonationCoordinator()
        let model = DonateViewModel(client: DonationClientFake(receipts: []), coordinator: coordinator)
        model.startDonation()
        await waitUntil { coordinator.pending.count == 1 }
        model.cancel()
        model.startDonation()
        await waitUntil { coordinator.pending.count == 2 }

        coordinator.pending[0].resume(throwing: DonationPaymentCoordinatorError.paymentFailed)
        await waitUntil { coordinator.returned == 1 }
        #expect(model.isProcessing)
        #expect(model.errorMessage == nil)
        #expect(model.completedPayments.isEmpty)
        model.startDonation()
        #expect(coordinator.pending.count == 2)

        coordinator.pending[1].resume(returning: DonationPaymentSuccess(receiptToken: "new-payment"))
        await waitUntil { !model.isProcessing }
        #expect(model.completedPayments.count == 1)
        #expect(model.completedPayments.first?.invoice == .receiptToken("new-payment"))
        #expect(model.paymentSucceeded)
    }

    @Test func changingCadenceDoesNotAcceptARejectedPaste() {
        let model = DonateViewModel(client: DonationClientFake(receipts: []), coordinator: DonationCoordinatorFake(),
                                    locale: Locale(identifier: "en_US"))
        model.updateCustomAmount("25")
        _ = model.decideAmountEdit(current: "25", range: NSRange(location: 0, length: 2), replacement: "10.001", isPaste: true)
        model.cadence = .monthly
        model.cadenceChanged()
        #expect(!model.canDonate)
        #expect(model.customAmountErrorMessage != nil)
        model.selectPreset(2_500)
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
    var setupCallCount = 0
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

    func openPaymentSetup() { setupCallCount += 1 }

    func cancel() {
        cancelCallCount += 1
    }
}

@MainActor
private final class ControlledDonationCoordinator: DonationPaymentCoordinating {
    var pending: [CheckedContinuation<DonationPaymentSuccess, Error>] = []
    var returned = 0

    func prepare() async throws {}
    func availability(for draft: DonationDraft) -> DonationApplePayAvailability { .ready }
    func donate(_ draft: DonationDraft) async throws -> DonationPaymentSuccess {
        defer { returned += 1 }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func openPaymentSetup() {}
    func cancel() {} // Intentionally delivers late callbacks to exercise stale completions.
}
