import Foundation

/// Display data only; no donation history or subscription lookup is connected yet.
nonisolated struct DonationSupportSummary: Equatable, Sendable {
    let monthly: MonthlyDonationSummary?
    let payments: [DonationPayment]

    init(monthly: MonthlyDonationSummary? = nil, payments: [DonationPayment] = []) {
        self.monthly = monthly
        self.payments = payments.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return $0.date > $1.date
        }
    }

    var recentPayments: [DonationPayment] {
        Array(payments.prefix(3))
    }
}

nonisolated struct MonthlyDonationSummary: Equatable, Sendable {
    let status: DonationMonthlyStatus
    let amountCents: Int
    let nextPaymentDate: Date?
    var cancellationDate: Date? = nil
}

nonisolated struct DonationPayment: Identifiable, Equatable, Sendable {
    let id: String
    let amountCents: Int
    let date: Date
    var cadence: DonationCadence = .oneTime
    var invoice: DonationInvoiceSource = .unavailable
    var receipt: DonationReceiptResponse?
    var receiptFailed = false
}

nonisolated enum DonationInvoiceSource: Equatable, Sendable {
    case receiptToken(String)
    case url(URL)
    case unavailable
}
