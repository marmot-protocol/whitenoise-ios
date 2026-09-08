import SwiftUI

/// Support surface reachable from Settings: the project's public donation
/// addresses, each with a scannable QR and a tap-to-copy monospaced row.
struct DonateView: View {
    @State private var selectedMethodID = DonatePresentation.lightning.id
    @State private var qrImages: [String: UIImage] = [:]

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "heart")
                        .font(.largeTitle)
                        .foregroundStyle(.primary)
                    Text("Support White Noise")
                        .font(.headline)
                    Text("White Noise is free and open source. Donations help us improve it and keep it available to everyone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let selectedMethod {
                methodSection(selectedMethod)
            }
        }
        .localizedNavigationTitle("Donate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Donation method", selection: $selectedMethodID) {
                    Text("Lightning").tag(DonatePresentation.lightning.id)
                    Text("Bitcoin").tag(DonatePresentation.bitcoinSilentPayment.id)
                }
                .labelsHidden()
                .pickerStyle(.palette)
                .controlSize(.extraLarge)
                .frame(width: 180)
            }
        }
        .task {
            for method in DonatePresentation.methods where qrImages[method.id] == nil {
                qrImages[method.id] = QRCode.image(from: method.qrPayload)
            }
        }
    }

    private var selectedMethod: DonatePresentation.Method? {
        DonatePresentation.methods.first { $0.id == selectedMethodID }
    }

    private func methodSection(_ method: DonatePresentation.Method) -> some View {
        Section {
            VStack(spacing: 0) {
                qrCard(for: method)
                addressChip(for: method)
                    .padding(.top, 18)
                Text(addressTitle(for: method))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func qrCard(for method: DonatePresentation.Method) -> some View {
        Group {
            if let image = qrImages[method.id] {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .accessibilityLabel(Text(qrAccessibilityLabel(for: method)))
            } else {
                Text("Couldn't render QR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerRelativeFrame(.horizontal) { length, _ in
            DonatePresentation.qrCardWidth(forContainerWidth: length)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }

    private func addressChip(for method: DonatePresentation.Method) -> some View {
        CopyableValueChip(
            display: method.displayAddress,
            copyValue: method.address,
            copiedToastTitle: localizedAddressTitle(for: method),
            fillsAvailableWidth: true
        )
        .id(method.id)
        .containerRelativeFrame(.horizontal) { length, _ in
            DonatePresentation.addressChipWidth(forContainerWidth: length)
        }
    }

    private func isLightning(_ method: DonatePresentation.Method) -> Bool {
        method.id == DonatePresentation.lightning.id
    }

    private func addressTitle(for method: DonatePresentation.Method) -> LocalizedStringKey {
        isLightning(method) ? "Lightning Address" : "Bitcoin Silent Payment"
    }

    private func localizedAddressTitle(for method: DonatePresentation.Method) -> String {
        isLightning(method)
            ? L10n.string("Lightning Address")
            : L10n.string("Bitcoin Silent Payment")
    }

    private func qrAccessibilityLabel(for method: DonatePresentation.Method) -> LocalizedStringKey {
        isLightning(method) ? "Lightning Address QR code" : "Bitcoin Silent Payment QR code"
    }
}
