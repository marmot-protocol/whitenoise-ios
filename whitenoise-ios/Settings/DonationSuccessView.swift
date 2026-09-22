import SwiftUI

struct DonationSuccessView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let cadence: DonationCadence

    var body: some View {
        ScrollView {
            successContent
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                WNIconButton(title: "Close", systemImage: "xmark") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemBackground))
    }

    private var successContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(cadence == .monthly ? L10n.string("Thank you for your commitment") : L10n.string("Thank you for your support"))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(cadence == .monthly
                     ? L10n.string("By giving monthly, you help IPF keep building White Noise and tools for free, private communication.")
                     : L10n.string("Thank you for supporting IPF and White Noise. You’re helping people communicate freely and privately."))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }
}
