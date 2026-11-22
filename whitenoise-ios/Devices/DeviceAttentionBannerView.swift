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
                title: Text("Someone else may have your private key"),
                message: Text("Someone published from your profile where your devices didn’t.")
            ) {
                Button("Review", action: onOpenDevices)
            }
        case .linkRequest(let promptID):
            card(
                systemImage: "laptopcomputer.and.iphone", tint: .accentColor,
                title: Text("A device wants to link"),
                message: Text("Compare the emoji on both devices before linking it.")
            ) {
                Button("Review") { store.present(.approve(promptID: promptID)) }
            }
        case .otherProfileLinkRequest(let request):
            card(
                systemImage: "laptopcomputer.and.iphone", tint: .accentColor,
                title: Text(verbatim: L10n.formatted(
                    "A device wants to link %@.", appState.displayName(forAccountIdHex: request.accountIdHex)
                )),
                message: Text("Review switches to that profile to compare the emoji.")
            ) {
                Button("Review") {
                    Task { await store.reviewOtherProfileRequest(request, using: appState) }
                }
            }
        case .linkingThisDevice:
            card(
                systemImage: "hourglass", tint: .accentColor,
                title: Text("Linking this device"),
                message: Text("Continue on your other device.")
            ) {
                Button("Show") { store.present(.linkThisDevice) }
            }
        }
    }

    private func card(
        systemImage: String,
        tint: Color,
        title: Text,
        message: Text,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.subheadline.weight(.semibold))
                message
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
