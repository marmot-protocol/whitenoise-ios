import Foundation
import Testing
@testable import whitenoise_ios

struct DonatePresentationTests {
    @Test func presetsAndDefaultMatchTheDonationDesign() {
        #expect(DonatePresentation.presetAmountsCents == [1_000, 2_500, 5_000, 10_000])
        #expect(DonatePresentation.defaultAmountCents == 2_500)
    }

    @Test func parsesLocaleAwareWholeAndFractionalAmounts() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")

        #expect(DonatePresentation.validateCustomAmount("25", locale: english) == .valid(2_500))
        #expect(DonatePresentation.validateCustomAmount("10.25", locale: english) == .valid(1_025))
        #expect(DonatePresentation.validateCustomAmount("10,25", locale: german) == .valid(1_025))
    }

    @Test func validatesLimitsAndRejectsFractionalCents() {
        let locale = Locale(identifier: "en_US")

        #expect(DonatePresentation.validateCustomAmount("", locale: locale) == .empty)
        #expect(DonatePresentation.validateCustomAmount("0.99", locale: locale) == .belowMinimum)
        #expect(DonatePresentation.validateCustomAmount("1", locale: locale) == .valid(100))
        #expect(DonatePresentation.validateCustomAmount("5000", locale: locale) == .valid(500_000))
        #expect(DonatePresentation.validateCustomAmount("5000.01", locale: locale) == .aboveMaximum)
        #expect(DonatePresentation.validateCustomAmount("10.001", locale: locale) == .tooPrecise)
        #expect(DonatePresentation.validateCustomAmount("not money", locale: locale) == .invalid)
    }

    @Test func formatsUSDWithoutUnnecessaryFractionDigits() {
        let locale = Locale(identifier: "en_US")

        #expect(DonatePresentation.formattedAmount(cents: 2_500, locale: locale) == "$25")
        #expect(DonatePresentation.formattedAmount(cents: 1_025, locale: locale) == "$10.25")
    }

    @Test func createRequestEncodesIntegerCentsAndNullDonor() throws {
        let attemptID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let request = DonationCreateRequest(
            attemptID: attemptID,
            amountCents: 2_500,
            cadence: .oneTime,
            paymentMethodID: "pm_test",
            donor: nil
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        #expect(object["attempt_id"] as? String == attemptID.uuidString.lowercased())
        #expect(object["amount_cents"] as? Int == 2_500)
        #expect(object["cadence"] as? String == "one_time")
        #expect(object["payment_method_id"] as? String == "pm_test")
        #expect(object["donor"] is NSNull)
    }

    @Test func authorizationKeepsItsAttemptIDButNewAuthorizationsDoNot() {
        let draft = DonationDraft(amountCents: 2_500, cadence: .oneTime)
        let first = DonationAuthorizationContext(draft: draft)
        let second = DonationAuthorizationContext(draft: draft)

        #expect(first.request(paymentMethodID: "pm_1", donor: nil).attemptID == first.attemptID)
        #expect(first.request(paymentMethodID: "pm_1", donor: nil).attemptID == first.attemptID)
        #expect(first.attemptID != second.attemptID)
    }
}
