import SwiftUI

struct DonationMonthlySupportCard: View {
    let donation: MonthlyDonationSummary
    let managementURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Thank you for your support")
                } icon: {
                    Image(systemName: donation.status.symbolName)
                        .accessibilityHidden(true)
                }
                .font(.headline)
                .foregroundStyle(donation.status.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(donation.status.title)

                Text(supportMessage)
                    .foregroundStyle(.secondary)
            }

            if paymentDetail != nil || managementURL != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let paymentDetail {
                        Text(paymentDetail)
                            .foregroundStyle(.secondary)
                    }
                    if let managementURL {
                        Link(destination: managementURL) {
                            Text("Manage monthly donation")
                                // Expand the tap area without adding visible spacing.
                                .contentShape(Rectangle().inset(by: -14))
                        }
                    }
                }
                .font(.footnote)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var supportMessage: String {
        switch donation.status {
        case .active:
            L10n.formatted(
                "You’re donating %@ each month to help people communicate freely and privately.",
                DonatePresentation.formattedAmount(cents: donation.amountCents)
            )
        case .overdue:
            L10n.string("Your monthly payment couldn’t be completed. Please check your payment method to continue your support.")
        case .cancellationScheduled:
            L10n.string("Your monthly donation is scheduled to end. Your support has helped us build tools for private communication.")
        case .incomplete:
            L10n.string("Your monthly donation has not started yet. Check your payment method to complete it.")
        case .canceled:
            L10n.string("This monthly donation has ended.")
        case .unsupported:
            L10n.string("This monthly donation's status is unavailable. Check Stripe to manage it.")
        }
    }

    private var paymentDetail: String? {
        switch donation.status {
        case .active:
            donation.nextPaymentDate.map {
                L10n.formatted("Next payment: %@", $0.formatted(date: .long, time: .omitted))
            }
        case .cancellationScheduled:
            donation.cancellationDate.map {
                L10n.formatted("Payments stop on %@", $0.formatted(date: .long, time: .omitted))
            }
        case .overdue:
            nil
        case .canceled:
            donation.endDate.map { L10n.formatted("Ended on %@", $0.formatted(date: .long, time: .omitted)) }
        case .incomplete, .unsupported:
            nil
        }
    }

}

private extension DonationMonthlyStatus {
    var title: String {
        switch self {
        case .active: L10n.string("Monthly donation active")
        case .cancellationScheduled: L10n.string("Cancellation scheduled")
        case .overdue: L10n.string("Monthly donation overdue")
        case .incomplete: L10n.string("Monthly donation not yet active")
        case .canceled: L10n.string("Monthly donation ended")
        case .unsupported: L10n.string("Monthly donation status unavailable")
        }
    }

    var symbolName: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .cancellationScheduled: "clock.fill"
        case .overdue: "exclamationmark.circle.fill"
        case .incomplete, .unsupported: "questionmark.circle.fill"
        case .canceled: "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .cancellationScheduled: .orange
        case .overdue: .red
        case .incomplete, .unsupported: .orange
        case .canceled: .secondary
        }
    }
}
