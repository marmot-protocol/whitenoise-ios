import SwiftUI

struct DonationHistoryView: View {
    let payments: [DonationPayment]
    let model: DonateViewModel
    @State private var selectedPayment: DonationPayment?

    var body: some View {
        List {
            ForEach(DonationSupportSummary(payments: model.completedPayments + payments).payments) { payment in
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
        .localizedNavigationTitle("Payments")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPayment) { payment in
            DonationInvoiceView(payment: payment, loadReceipt: model.receipt)
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
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(donation.date.formatted(date: .abbreviated, time: .omitted))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
