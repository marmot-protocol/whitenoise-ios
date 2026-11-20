import SwiftUI

/// On a device that already has the chats: what to do on the new device. The
/// new device asks to link; its request replaces this sheet when it arrives.
struct AddDeviceView: View {
    @Environment(AppState.self) private var appState

    private var store: DeviceLinkStore { appState.deviceLinks }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    DeviceLinkStatusHeader(
                        systemImage: "laptopcomputer.and.iphone",
                        title: L10n.string("Add a New Device"),
                        message: L10n.string("Your new device asks to link, and you approve it here.")
                    )
                    VStack(alignment: .leading, spacing: 14) {
                        instruction(1, L10n.string("On the new device, install White Noise and sign in with this profile’s private key."))
                        instruction(2, L10n.string("There, open Settings → Devices and tap Link to Another Device."))
                        instruction(3, L10n.string("Check that both devices show the same emoji, confirm on the new device, then approve here."))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    NavigationLink {
                        IdentityView()
                    } label: {
                        Label("Show This Profile’s Keys", systemImage: "key")
                    }

                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for a request…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    Text("Both devices need an up-to-date version of White Noise.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .localizedNavigationTitle("Add a New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { store.sheetDismissed() }
                }
            }
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 28, height: 28)
                .background(Color(.secondarySystemFill), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
