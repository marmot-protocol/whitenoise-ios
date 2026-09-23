import Foundation

nonisolated struct DonationSupportSummary: Equatable, Sendable {
    let monthly: MonthlyDonationSummary?
    let additionalMonthlies: [MonthlyDonationSummary]
    let payments: [DonationPayment]

    init(monthly: MonthlyDonationSummary? = nil, additionalMonthlies: [MonthlyDonationSummary] = [], payments: [DonationPayment] = []) {
        self.monthly = monthly
        self.additionalMonthlies = additionalMonthlies
        self.payments = payments.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return $0.date > $1.date
        }
    }

    var recentPayments: [DonationPayment] {
        Array(payments.prefix(3))
    }

    var monthlies: [MonthlyDonationSummary] {
        (monthly.map { [$0] } ?? []) + additionalMonthlies
    }
}

nonisolated struct MonthlyDonationSummary: Equatable, Sendable {
    var id: String = "single"
    let status: DonationMonthlyStatus
    let amountCents: Int
    let nextPaymentDate: Date?
    var cancellationDate: Date? = nil
    var endDate: Date? = nil
}

nonisolated struct DonationPayment: Identifiable, Equatable, Sendable {
    let id: String
    let amountCents: Int
    let date: Date
    var cadence: DonationCadence = .oneTime
    var paymentState: DonationBillingState = .succeeded
    var invoice: DonationInvoiceSource = .unavailable
    var receipt: DonationReceiptResponse?
    var receiptFailed = false
}

nonisolated enum DonationInvoiceSource: Equatable, Sendable {
    case receiptToken(String)
    case recordID(String)
    case url(URL)
    case unavailable
}
