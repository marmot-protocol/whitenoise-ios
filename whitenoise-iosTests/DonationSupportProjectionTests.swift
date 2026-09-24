import Foundation
import Testing
@testable import whitenoise_ios

struct DonationSupportProjectionTests {
    @Test func multipleSubscriptionsAndBillingStatesRemainDistinct() throws {
        let active = try decodeSubscription(
            #"{"record_id":"sub.one","amount_cents":2500,"currency":"usd","status":"active","next_billing_at":1800000000,"scheduled_cancel_at":null,"ended_at":null}"#
        )
        let canceled = try decodeSubscription(
            #"{"record_id":"sub.two","amount_cents":1000,"currency":"usd","status":"canceled","next_billing_at":null,"scheduled_cancel_at":null,"ended_at":1790000000}"#
        )
        let pending = try decodePayment(
            #"{"record_id":"inv.pending","amount_cents":2500,"currency":"usd","date":1790000000,"cadence":"monthly","payment_state":"pending","has_document":true}"#
        )
        let paid = try decodePayment(
            #"{"record_id":"pay.paid","amount_cents":1000,"currency":"usd","date":1789000000,"cadence":"one_time","payment_state":"succeeded","has_document":false}"#
        )

        let summary = DonationSupportProjection.summary(subscriptions: [active, canceled], payments: [pending, paid])

        #expect(summary.monthlies.map(\.id) == ["sub.one", "sub.two"])
        #expect(summary.monthlies.map(\.status) == [.active, .canceled])
        #expect(summary.monthlies[1].endDate == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(summary.payments.map(\.paymentState) == [.pending, .succeeded])
        #expect(summary.payments[0].invoice == .recordID("inv.pending"))
        #expect(summary.payments[1].invoice == .unavailable)
    }

    private func decodeSubscription(_ json: String) throws -> DonationSubscriptionRecord {
        try JSONDecoder().decode(DonationSubscriptionRecord.self, from: Data(json.utf8))
    }

    private func decodePayment(_ json: String) throws -> DonationBillingRecord {
        try JSONDecoder().decode(DonationBillingRecord.self, from: Data(json.utf8))
    }
}
