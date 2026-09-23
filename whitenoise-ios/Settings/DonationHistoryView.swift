import SwiftUI

struct DonationHistoryView: View {
    let model: DonateViewModel
    @State private var selectedPayment: DonationPayment?
    @State private var nextPageAttempt = 0

    private var allPayments: [DonationPayment] {
        model.displayedPayments.payments
    }

    var body: some View {
        List {
            if model.supportState == .accessExpired {
                Text("Donation history access is no longer available on this device.")
            }
            ForEach(allPayments) { payment in
                if payment.invoice == .unavailable {
                    DonationHistoryRow(donation: payment)
                } else {
                    Button {
                        selectedPayment = payment
                    } label: {
                        HStack(spacing: 12) {
                            DonationHistoryRow(donation: payment)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.historyNextCursor != nil {
                Button(model.isLoadingMoreHistory ? L10n.string("Loading…") : L10n.string("Load more")) {
                    nextPageAttempt += 1
                }
                .disabled(model.isLoadingMoreHistory)
            }
            if model.historyLoadFailed {
                Text("More billing activity couldn't be loaded. Try again.")
                    .foregroundStyle(.secondary)
            }
        }
        .localizedNavigationTitle("Payments")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: nextPageAttempt) {
            if nextPageAttempt > 0 { await model.loadMoreHistory() }
        }
        .sheet(item: $selectedPayment) { payment in
            DonationInvoiceView(payment: payment, loadReceipt: model.receipt, loadDocument: model.document)
        }
    }
}

struct DonationHistoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let donation: DonationPayment

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))

        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(DonatePresentation.formattedAmount(cents: donation.amountCents))
                    .fontWeight(.medium)
                Text(donation.cadence == .monthly ? L10n.string("Monthly") : L10n.string("One time"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if donation.paymentState != .succeeded {
                    Text(donation.paymentState.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(donation.date.formatted(date: .abbreviated, time: .omitted))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension DonationBillingState {
    var title: String {
        switch self {
        case .succeeded: L10n.string("Paid")
        case .pending: L10n.string("Pending")
        case .failed: L10n.string("Payment failed")
        case .credited: L10n.string("Credited")
        case .manualPaid: L10n.string("Paid outside the app")
        }
    }
}
