import SwiftUI

/// The one device item the Chats list shows above the chats.
struct DeviceAttentionBannerView: View {
    let banner: DeviceAttentionBanner
    let onOpenDevices: () -> Void

    @Environment(AppState.self) private var appState

    private var store: DeviceLinkStore { appState.deviceLinks }

    var body: some View {
        switch banner {
        case .compromiseWarning:
            card(
                systemImage: "exclamationmark.shield.fill", tint: .red,
                title: "Someone else may have your private key",
                message: "Someone published from your profile where your devices didn’t."
            ) {
                Button("Review", action: onOpenDevices)
            }
        case .linkRequest(let promptID):
            card(
                systemImage: "laptopcomputer.and.iphone", tint: .accentColor,
                title: "A device wants to link",
                message: "Compare the emoji on both devices before linking it."
            ) {
                Button("Review") { store.present(.approve(promptID: promptID)) }
            }
        case .linkingThisDevice:
            card(
                systemImage: "hourglass", tint: .accentColor,
                title: "Linking this device",
                message: "Continue on your other device."
            ) {
                Button("Show") { store.present(.linkThisDevice) }
            }
        }
    }

    private func card(
        systemImage: String,
        tint: Color,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) { actions() }
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
