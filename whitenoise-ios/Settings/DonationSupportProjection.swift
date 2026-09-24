import Foundation

nonisolated enum DonationSupportProjection {
    static func summary(subscriptions: [DonationSubscriptionRecord], payments: [DonationBillingRecord]) -> DonationSupportSummary {
        let monthlies = subscriptions.map { record in
            MonthlyDonationSummary(
                id: record.recordID,
                status: status(record.status),
                amountCents: record.amountCents,
                nextPaymentDate: record.nextBillingAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                cancellationDate: record.scheduledCancelAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                endDate: record.endedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
        let history = payments.map { record in
            DonationPayment(
                id: record.recordID,
                amountCents: record.amountCents,
                date: Date(timeIntervalSince1970: TimeInterval(record.date)),
                cadence: record.cadence,
                paymentState: record.paymentState,
                invoice: record.hasDocument ? .recordID(record.recordID) : .unavailable
            )
        }
        return DonationSupportSummary(
            monthly: monthlies.first,
            additionalMonthlies: Array(monthlies.dropFirst()),
            payments: history
        )
    }

    private static func status(_ status: DonationSubscriptionStatus) -> DonationMonthlyStatus {
        switch status {
        case .active: .active
        case .cancellationScheduled: .cancellationScheduled
        case .pastDue, .unpaid: .overdue
        case .incomplete: .incomplete
        case .canceled: .canceled
        case .unsupported: .unsupported
        }
    }
}
