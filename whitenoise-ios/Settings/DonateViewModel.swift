import Foundation

@MainActor
@Observable
final class DonateViewModel {
    var cadence: DonationCadence = .oneTime
    var amountSelection: DonationAmountSelection = .preset(DonatePresentation.defaultAmountCents)
    var customAmountText = ""
    var isProcessing = false
    var errorMessage: String?
    var paymentSucceeded = false
    var receiptStatus: DonationReceiptStatus?
    var receiptURL: URL?
    var receiptCheckFailed = false
    var isCheckingReceipt = false
    private(set) var isApplePayPrepared = false
    private(set) var isPreparingApplePay = false
    let managementURL: URL?

    private let client: (any DonationClient)?
    private let coordinator: (any DonationPaymentCoordinating)?
    private let locale: Locale
    private var paymentTask: Task<Void, Never>?
    private var receiptTask: Task<Void, Never>?
    private var receiptToken: String?

    init(
        config: DonationBuildConfig? = DonationBuildConfig.current(),
        locale: Locale = .autoupdatingCurrent
    ) {
        self.locale = locale
        guard let config else {
            client = nil
            coordinator = nil
            managementURL = nil
            return
        }
        let client = URLSessionDonationClient(baseURL: config.serviceURL)
        self.client = client
        coordinator = ApplePayDonationCoordinator(config: config, client: client)
        managementURL = config.managementURL
        isPreparingApplePay = true
    }

    init(
        client: any DonationClient,
        coordinator: any DonationPaymentCoordinating,
        managementURL: URL? = nil,
        locale: Locale = .autoupdatingCurrent,
        isApplePayPrepared: Bool = true
    ) {
        self.client = client
        self.coordinator = coordinator
        self.managementURL = managementURL
        self.locale = locale
        self.isApplePayPrepared = isApplePayPrepared
        isPreparingApplePay = !isApplePayPrepared
    }

    var selectedAmountCents: Int? {
        switch amountSelection {
        case let .preset(cents):
            guard DonatePresentation.presetAmountsCents.contains(cents) else { return nil }
            return cents
        case .custom:
            return customAmountValidation.amountCents
        }
    }

    var customAmountValidation: CustomDonationAmountValidation {
        DonatePresentation.validateCustomAmount(customAmountText, locale: locale)
    }

    var customAmountErrorMessage: String? {
        guard amountSelection == .custom else { return nil }
        switch customAmountValidation {
        case .empty:
            return nil
        case .invalid:
            return L10n.string("Enter a valid USD amount with no more than two decimal places.")
        case .belowMinimum:
            return L10n.string("The minimum donation is $1.")
        case .aboveMaximum:
            return L10n.string("The maximum donation is $5,000.")
        case .valid:
            return nil
        }
    }

    var draft: DonationDraft? {
        guard let selectedAmountCents else { return nil }
        return DonationDraft(amountCents: selectedAmountCents, cadence: cadence)
    }

    var availability: DonationApplePayAvailability {
        guard let coordinator, isApplePayPrepared else { return .notConfigured }
        let availabilityDraft = draft ?? DonationDraft(
            amountCents: DonatePresentation.defaultAmountCents,
            cadence: cadence
        )
        return coordinator.availability(for: availabilityDraft)
    }

    var canDonate: Bool {
        draft != nil && availability == .ready && !isProcessing
    }

    var canCheckReceipt: Bool {
        paymentSucceeded && receiptToken != nil && !isProcessing && !isCheckingReceipt
    }

    func prepareApplePay() async {
        guard !isApplePayPrepared, let coordinator else { return }
        isPreparingApplePay = true
        defer { isPreparingApplePay = false }
        do {
            try await coordinator.prepare()
            try Task.checkCancellation()
            isApplePayPrepared = true
        } catch {
            isApplePayPrepared = false
        }
    }

    func selectPreset(_ cents: Int) {
        guard !isProcessing else { return }
        amountSelection = .preset(cents)
        resetResult()
    }

    func selectCustom() {
        guard !isProcessing else { return }
        amountSelection = .custom
        resetResult()
    }

    func cadenceChanged() {
        guard !isProcessing else { return }
        resetResult()
    }

    func customAmountChanged() {
        guard amountSelection == .custom, !isProcessing else { return }
        resetResult()
    }

    func startDonation() {
        guard paymentTask == nil,
              let draft,
              let coordinator
        else { return }

        errorMessage = nil
        paymentSucceeded = false
        receiptStatus = nil
        receiptURL = nil
        receiptCheckFailed = false
        receiptToken = nil
        isProcessing = true

        paymentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isProcessing = false
                paymentTask = nil
            }
            do {
                let success = try await coordinator.donate(draft)
                try Task.checkCancellation()
                receiptToken = success.receiptToken
                paymentSucceeded = true
                await loadReceipt(token: success.receiptToken)
            } catch is CancellationError {
                return
            } catch let error as DonationPaymentCoordinatorError {
                errorMessage = Self.message(for: error)
            } catch {
                errorMessage = L10n.string("The donation couldn't be completed. Please try again.")
            }
        }
    }

    func openPaymentSetup() {
        coordinator?.openPaymentSetup()
    }

    func checkReceipt() {
        guard receiptTask == nil,
              let receiptToken
        else { return }

        receiptCheckFailed = false
        isCheckingReceipt = true
        receiptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                receiptTask = nil
                isCheckingReceipt = false
            }
            await loadReceipt(token: receiptToken)
        }
    }

    func cancel() {
        paymentTask?.cancel()
        receiptTask?.cancel()
        paymentTask = nil
        receiptTask = nil
        coordinator?.cancel()
        isProcessing = false
        isCheckingReceipt = false
    }

    private func loadReceipt(token: String) async {
        guard let client else { return }
        do {
            let response = try await client.receipt(for: token)
            try Task.checkCancellation()
            receiptStatus = response.status
            receiptURL = response.status == .available ? response.url : nil
            receiptCheckFailed = false
        } catch is CancellationError {
            return
        } catch {
            receiptCheckFailed = true
        }
    }

    private func resetResult() {
        errorMessage = nil
        paymentSucceeded = false
        receiptStatus = nil
        receiptURL = nil
        receiptCheckFailed = false
        receiptToken = nil
    }

    private static func message(for error: DonationPaymentCoordinatorError) -> String {
        switch error {
        case .missingDonorContact:
            L10n.string("Apple Pay needs your name and email for monthly donations.")
        case .unavailable, .invalidPaymentRequest:
            L10n.string("Apple Pay isn't available for this donation.")
        case .alreadyActive:
            L10n.string("A donation is already in progress.")
        case .paymentFailed:
            L10n.string("The donation couldn't be completed. Please try again.")
        }
    }
}
