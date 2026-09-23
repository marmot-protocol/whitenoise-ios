import Foundation
import Observation

nonisolated enum DonationSupportLoadState: Equatable, Sendable {
    case none, loading, loaded, failed, accessExpired
}

@MainActor
@Observable
final class DonateViewModel {
    var cadence: DonationCadence = .oneTime
    var amountSelection: DonationAmountSelection = .preset(DonatePresentation.defaultAmountCents)
    var customAmountText = ""
    private var rejectedAmountInput: CustomDonationAmountValidation?
    private(set) var availability: DonationApplePayAvailability = .notConfigured
    var isProcessing: Bool { activePaymentID != nil }
    private(set) var errorMessage: String?
    private(set) var successfulPayment: DonationPayment?
    var paymentSucceeded: Bool { successfulPayment != nil }
    private(set) var completedPayments: [DonationPayment] = []
    private(set) var support = DonationSupportSummary()
    private(set) var supportState: DonationSupportLoadState = .none
    private(set) var historyNextCursor: String?
    private(set) var isLoadingMoreHistory = false
    private(set) var historyLoadFailed = false
    private(set) var accessSaveFailed = false
    private(set) var isApplePayPrepared = false
    private(set) var isPreparingApplePay = false
    private(set) var applePayPreparationFailed = false
    let managementURL: URL?

    private let client: (any DonationClient)?
    private let coordinator: (any DonationPaymentCoordinating)?
    private let accessStore: (any DonationAccessStoring)?
    private let locale: Locale
    private var paymentTask: Task<Void, Never>?
    private var activePaymentID: UUID?
    private var preparationID: UUID?
    private var supportLoadID: UUID?

    init(
        client: (any DonationClient)?,
        coordinator: (any DonationPaymentCoordinating)?,
        accessStore: (any DonationAccessStoring)? = nil,
        managementURL: URL? = nil,
        locale: Locale = .autoupdatingCurrent,
        isApplePayPrepared: Bool = true
    ) {
        self.client = client
        self.coordinator = coordinator
        self.accessStore = accessStore
        self.managementURL = managementURL
        self.locale = locale
        self.isApplePayPrepared = coordinator != nil && isApplePayPrepared
        isPreparingApplePay = coordinator != nil && !isApplePayPrepared
        refreshApplePayAvailability()
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
        switch rejectedAmountInput ?? customAmountValidation {
        case .empty:
            return nil
        case .invalid:
            return L10n.string("Enter a valid USD amount.")
        case .tooPrecise:
            return L10n.string("Use up to two decimal places.")
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

    func refreshApplePayAvailability() {
        guard let coordinator, isApplePayPrepared else {
            availability = .notConfigured
            return
        }
        let availabilityDraft = DonationDraft(
            amountCents: DonatePresentation.defaultAmountCents,
            cadence: cadence
        )
        availability = coordinator.availability(for: availabilityDraft)
    }

    var canDonate: Bool {
        draft != nil && rejectedAmountInput == nil && availability == .ready && !isProcessing
    }

    func prepareApplePay() async {
        guard !isApplePayPrepared, let coordinator else { return }
        let id = UUID()
        preparationID = id
        applePayPreparationFailed = false
        isPreparingApplePay = true
        defer {
            if preparationID == id {
                preparationID = nil
                isPreparingApplePay = false
                refreshApplePayAvailability()
            }
        }
        do {
            try await coordinator.prepare()
            try Task.checkCancellation()
            guard preparationID == id else { return }
            isApplePayPrepared = true
        } catch {
            guard preparationID == id else { return }
            isApplePayPrepared = false
            applePayPreparationFailed = !(error is CancellationError) && !Task.isCancelled
        }
    }

    func selectPreset(_ cents: Int) {
        guard !isProcessing else { return }
        amountSelection = .preset(cents)
        customAmountText = ""
        rejectedAmountInput = nil
        resetResult()
    }

    func cadenceChanged() {
        guard !isProcessing else { return }
        refreshApplePayAvailability()
        resetResult()
    }

    func decideAmountEdit(current: String, range: NSRange, replacement: String, isPaste: Bool) -> DonationAmountEdit {
        guard !isProcessing else { return .reject(nil) }
        let decision = DonatePresentation.amountEdit(
            current: current, range: range, replacement: replacement, isPaste: isPaste, locale: locale
        )
        if case let .reject(error?) = decision {
            amountSelection = .custom
            rejectedAmountInput = error
        }
        return decision
    }

    func updateCustomAmount(_ text: String) {
        guard !isProcessing else { return }
        customAmountText = text
        amountSelection = .custom
        rejectedAmountInput = nil
        resetResult()
    }

    func startDonation() {
        guard paymentTask == nil, canDonate,
              let draft,
              let coordinator
        else { return }

        errorMessage = nil
        successfulPayment = nil
        accessSaveFailed = false
        let paymentID = UUID()
        activePaymentID = paymentID

        paymentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if activePaymentID == paymentID {
                    activePaymentID = nil
                    paymentTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let success = try await coordinator.donate(draft)
                try Task.checkCancellation()
                guard activePaymentID == paymentID else { return }
                let payment = DonationPayment(
                    id: UUID().uuidString,
                    amountCents: draft.amountCents,
                    date: .now,
                    cadence: draft.cadence,
                    invoice: .receiptToken(success.receiptToken)
                )
                completedPayments.insert(payment, at: 0)
                if let credential = success.credential, let accessStore {
                    do {
                        try accessStore.save(credential)
                    } catch {
                        accessSaveFailed = true
                        supportState = .failed
                    }
                }
                successfulPayment = payment
            } catch is CancellationError {
                return
            } catch let error as DonationPaymentCoordinatorError {
                guard !Task.isCancelled, activePaymentID == paymentID else { return }
                if error == .accessExpired {
                    support = DonationSupportSummary()
                    supportState = .accessExpired
                }
                errorMessage = Self.message(for: error)
            } catch {
                guard !Task.isCancelled, activePaymentID == paymentID else { return }
                errorMessage = L10n.string("The donation couldn't be completed. Please try again.")
            }
        }
    }

    func receipt(for token: String) async throws -> DonationReceiptResponse {
        guard let client else { throw DonationClientError.serviceUnavailable }
        do {
            let response = try await client.receipt(for: token)
            try Task.checkCancellation()
            if let index = completedPayments.firstIndex(where: { $0.invoice == .receiptToken(token) }) {
                completedPayments[index].receipt = response
                completedPayments[index].receiptFailed = false
            }
            return response
        } catch {
            try Task.checkCancellation()
            if !(error is CancellationError),
               let index = completedPayments.firstIndex(where: { $0.invoice == .receiptToken(token) }) {
                completedPayments[index].receiptFailed = true
            }
            throw error
        }
    }

    func document(for recordID: String) async throws -> DonationReceiptResponse {
        guard let client, let accessStore, let credential = try accessStore.load() else {
            throw DonationClientError.invalidDonorAccess
        }
        do {
            return try await client.document(token: credential.token, recordID: recordID)
        } catch DonationClientError.invalidDonorAccess {
            try? accessStore.markLostAccess()
            support = DonationSupportSummary()
            supportState = .accessExpired
            throw DonationClientError.invalidDonorAccess
        }
    }

    func refreshSupport() async {
        guard let client, let accessStore else { return }
        let loadID = UUID()
        supportLoadID = loadID
        do {
            guard var credential = try accessStore.load() else {
                support = DonationSupportSummary()
                supportState = try accessStore.hasLostAccess() ? .accessExpired : .none
                return
            }
            guard credential.expiresAt > .now else {
                try? accessStore.markLostAccess()
                support = DonationSupportSummary()
                supportState = .accessExpired
                return
            }
            supportState = .loading
            if credential.expiresAt.timeIntervalSinceNow < 30 * 86_400 {
                let renewed = try await client.renew(
                    token: credential.token, renewalID: UUID(), requestedAt: Int64(Date.now.timeIntervalSince1970)
                )
                credential = DonationAccessCredential(
                    token: renewed.donorAccessToken,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(renewed.donorAccessExpiresAt))
                )
                try accessStore.save(credential)
            }
            guard supportLoadID == loadID else { return }

            var subscriptions: [DonationSubscriptionRecord] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                let page = try await client.supportSummary(token: credential.token, cursor: cursor)
                subscriptions += page.subscriptions
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted { throw DonationClientError.invalidResponse }
                if seen.count > 50 { throw DonationClientError.invalidResponse }
                try Task.checkCancellation()
            } while cursor != nil

            var history: [DonationBillingRecord] = []
            cursor = nil
            seen.removeAll()
            repeat {
                let page = try await client.billingHistory(token: credential.token, cursor: cursor)
                history += page.items
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted { throw DonationClientError.invalidResponse }
                if seen.count > 10 { throw DonationClientError.invalidResponse }
                try Task.checkCancellation()
            } while history.count < 3 && cursor != nil

            guard supportLoadID == loadID else { return }
            support = DonationSupportProjection.summary(subscriptions: subscriptions, payments: history)
            historyNextCursor = cursor
            historyLoadFailed = false
            supportState = .loaded
        } catch is CancellationError {
            return
        } catch DonationClientError.invalidDonorAccess {
            guard supportLoadID == loadID else { return }
            try? accessStore.markLostAccess()
            support = DonationSupportSummary()
            supportState = .accessExpired
        } catch {
            guard supportLoadID == loadID else { return }
            supportState = .failed
        }
    }

    func loadMoreHistory() async {
        guard !isLoadingMoreHistory, let cursor = historyNextCursor,
              let client, let accessStore else { return }
        let loadID = supportLoadID
        isLoadingMoreHistory = true
        historyLoadFailed = false
        defer { isLoadingMoreHistory = false }
        do {
            guard let credential = try accessStore.load() else { throw DonationClientError.invalidDonorAccess }
            var pageCursor: String? = cursor
            var records: [DonationBillingRecord] = []
            var seen = Set<String>()
            repeat {
                guard let currentCursor = pageCursor, seen.insert(currentCursor).inserted,
                      seen.count <= 10 else { throw DonationClientError.invalidResponse }
                let page = try await client.billingHistory(token: credential.token, cursor: currentCursor)
                try Task.checkCancellation()
                guard page.nextCursor != currentCursor else { throw DonationClientError.invalidResponse }
                records += page.items
                pageCursor = page.nextCursor
            } while records.isEmpty && pageCursor != nil
            guard supportLoadID == loadID else { return }
            let existing = Set(support.payments.map(\.id))
            let new = DonationSupportProjection.summary(subscriptions: [], payments: records).payments
                .filter { !existing.contains($0.id) }
            support = DonationSupportSummary(
                monthly: support.monthly,
                additionalMonthlies: support.additionalMonthlies,
                payments: support.payments + new
            )
            historyNextCursor = pageCursor
        } catch DonationClientError.invalidDonorAccess {
            guard supportLoadID == loadID else { return }
            try? accessStore.markLostAccess()
            support = DonationSupportSummary()
            supportState = .accessExpired
        } catch is CancellationError {
            return
        } catch {
            if supportLoadID == loadID { historyLoadFailed = true }
        }
    }

    func openPaymentSetup() {
        guard availability == .setupRequired else { return }
        coordinator?.openPaymentSetup()
        refreshApplePayAvailability()
    }

    func cancel() {
        paymentTask?.cancel()
        paymentTask = nil
        activePaymentID = nil
        coordinator?.cancel()
    }

    private func resetResult() {
        errorMessage = nil
        successfulPayment = nil
    }

    private static func message(for error: DonationPaymentCoordinatorError) -> String? {
        switch error {
        case .missingDonorContact:
            // Required contact details are handled inside the Apple Pay sheet.
            nil
        case .unavailable, .invalidPaymentRequest:
            L10n.string("Apple Pay isn't available for this donation.")
        case .alreadyActive:
            L10n.string("A donation is already in progress.")
        case .paymentFailed:
            L10n.string("The donation couldn't be completed. Please try again.")
        case .accessExpired:
            nil
        }
    }
}
