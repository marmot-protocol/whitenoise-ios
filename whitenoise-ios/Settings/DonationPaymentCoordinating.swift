import Foundation

nonisolated enum DonationApplePayAvailability: Equatable {
    case ready
    case setupRequired
    case unavailable
    case notConfigured
}

nonisolated struct DonationPaymentSuccess: Equatable {
    let receiptToken: String
}

nonisolated struct DonationAuthorizationContext: Equatable, Sendable {
    let attemptID: UUID
    let draft: DonationDraft

    init(draft: DonationDraft, attemptID: UUID = UUID()) {
        self.draft = draft
        self.attemptID = attemptID
    }

    func request(
        paymentMethodID: String,
        donor: DonationDonor?
    ) -> DonationCreateRequest {
        DonationCreateRequest(
            attemptID: attemptID,
            amountCents: draft.amountCents,
            cadence: draft.cadence,
            paymentMethodID: paymentMethodID,
            donor: donor
        )
    }
}

nonisolated enum DonationPaymentCoordinatorError: Error, Equatable {
    case alreadyActive
    case unavailable
    case invalidPaymentRequest
    case missingDonorContact
    case paymentFailed

    static func completionError(_ error: Error?) -> Self {
        error as? Self ?? .paymentFailed
    }
}

@MainActor
protocol DonationPaymentCoordinating: AnyObject {
    func prepare() async throws
    func availability(for draft: DonationDraft) -> DonationApplePayAvailability
    func donate(_ draft: DonationDraft) async throws -> DonationPaymentSuccess
    func openPaymentSetup()
    func cancel()
}
