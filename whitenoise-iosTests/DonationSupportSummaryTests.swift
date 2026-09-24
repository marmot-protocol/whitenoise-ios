import Foundation
import Testing
@testable import whitenoise_ios

struct DonationSupportSummaryTests {
    @Test func historyShowsLatestThreeAndKeepsAllRecordsForTheFullList() {
        let donations = [2, 5, 1, 4, 3].map { index in
            DonationPayment(
                id: String(index),
                amountCents: index * 100,
                date: Date(timeIntervalSince1970: TimeInterval(index * 86_400)),
                cadence: index.isMultiple(of: 2) ? .monthly : .oneTime
            )
        }
        let summary = DonationSupportSummary(payments: donations)

        #expect(summary.recentPayments.map(\.id) == ["5", "4", "3"])
        #expect(summary.payments.map(\.id) == ["5", "4", "3", "2", "1"])
        #expect(summary.recentPayments.map(\.cadence) == [.oneTime, .monthly, .oneTime])
    }

    @Test func equalDatesHaveStableOrderingWithoutLosingDonations() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let summary = DonationSupportSummary(payments: [
            DonationPayment(id: "b", amountCents: 2_500, date: date),
            DonationPayment(id: "a", amountCents: 1_000, date: date)
        ])

        #expect(summary.recentPayments.map(\.id) == ["a", "b"])
    }

    @Test func noHistoryDoesNotInventDonationOrSubscriptionRecords() {
        let summary = DonationSupportSummary()

        #expect(summary.monthly == nil)
        #expect(summary.payments.isEmpty)
        #expect(summary.recentPayments.isEmpty)
    }
}
