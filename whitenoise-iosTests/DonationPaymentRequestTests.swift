import Foundation
import PassKit
import Testing
@testable import whitenoise_ios

@MainActor
struct DonationPaymentRequestTests {
    private let config = DonationBuildConfig(
        environment: .staging,
        serviceURL: URL(string: "https://payments-staging.ipf.dev")!,
        merchantIdentifier: "merchant.dev.ipf.whitenoise"
    )

    @Test func oneTimeRequestHasImmediateSummaryAndNoContactRequirement() throws {
        let request = DonationPaymentRequestFactory.make(
            draft: DonationDraft(amountCents: 2_500, cadence: .oneTime),
            config: config
        )

        #expect(request.merchantIdentifier == "merchant.dev.ipf.whitenoise")
        #expect(request.countryCode == "US")
        #expect(request.currencyCode == "USD")
        #expect(request.requiredBillingContactFields.isEmpty)
        #expect(request.requiredShippingContactFields.isEmpty)
        #expect(request.recurringPaymentRequest == nil)
        let item = try #require(request.paymentSummaryItems.first)
        #expect(item.amount == NSDecimalNumber(string: "25"))
        #expect(!(item is PKRecurringPaymentSummaryItem))
    }

    @Test func monthlyRequestHasRecurringSummaryManagementAndContactFields() throws {
        let request = DonationPaymentRequestFactory.make(
            draft: DonationDraft(amountCents: 1_025, cadence: .monthly),
            config: config
        )

        let item = try #require(request.paymentSummaryItems.first as? PKRecurringPaymentSummaryItem)
        #expect(item.amount == NSDecimalNumber(string: "10.25"))
        #expect(item.intervalUnit == .month)
        #expect(item.intervalCount == 1)
        #expect(request.requiredBillingContactFields.isEmpty)
        #expect(request.requiredShippingContactFields == [.name, .emailAddress])

        let recurring = try #require(request.recurringPaymentRequest)
        #expect(recurring.managementURL == URL(string: "https://payments-staging.ipf.dev/manage"))
        #expect(recurring.regularBilling.amount == NSDecimalNumber(string: "10.25"))
        #expect(recurring.billingAgreement?.isEmpty == false)
    }

    @Test func monthlyDonorUsesAuthorizedContactNameAndEmail() throws {
        let contact = PKContact()
        var name = PersonNameComponents()
        name.givenName = "Ada"
        name.familyName = "Lovelace"
        contact.name = name
        contact.emailAddress = "  ada@example.com  "

        let donor = try DonationDonorFactory.make(from: contact)

        #expect(donor == DonationDonor(name: "Ada Lovelace", email: "ada@example.com"))
    }

    @Test func monthlyDonorRejectsMissingContactFields() {
        let contact = PKContact()
        contact.emailAddress = "donor@example.com"

        #expect(throws: DonationPaymentCoordinatorError.missingDonorContact) {
            try DonationDonorFactory.make(from: contact)
        }
    }

    @Test func completionPreservesOnlyAppOwnedErrors() {
        #expect(DonationPaymentCoordinatorError.completionError(
            DonationPaymentCoordinatorError.missingDonorContact
        ) == .missingDonorContact)
        #expect(DonationPaymentCoordinatorError.completionError(
            DonationClientError.serviceUnavailable
        ) == .paymentFailed)
        #expect(DonationPaymentCoordinatorError.completionError(nil) == .paymentFailed)
    }

    @Test func donorNonceAndAttemptStayStableWithinOneAuthorization() throws {
        let nonce = try DonationAccessNonce.generate()
        #expect(nonce.count == 43)
        #expect(nonce.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        let authorization = DonationAuthorizationContext(
            draft: DonationDraft(amountCents: 2_500, cadence: .oneTime), accessNonce: nonce
        )
        let first = authorization.request(paymentMethodID: "pm_one", donor: nil)
        let retry = authorization.request(paymentMethodID: "pm_one", donor: nil)
        #expect(first == retry)
        #expect(first.donorAccessNonce == nonce)
        #expect(first.donorAccessToken == nil)
        #expect(DonationAuthorizationContext(draft: authorization.draft).attemptID != authorization.attemptID)
    }
}
