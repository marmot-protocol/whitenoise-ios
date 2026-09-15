import SwiftUI

struct ShareAndConnectView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case share = "Share"
        case connect = "Connect"

        var id: Self { self }
    }

    @Environment(AppState.self) private var appState
    @State private var mode = Mode.share
    @State private var qrImage: UIImage?
    @State private var scannedNpub: String?
    @State private var scanError: String?

    let accountIdHex: String

    private var npub: String {
        appState.npub(forAccountIdHex: accountIdHex)
    }

    private var deepLink: String {
        DeepLink.profile(npub: npub).url.absoluteString
    }

    var body: some View {
        ZStack {
            if mode == .share {
                ShareProfileContent(
                    accountIdHex: accountIdHex,
                    displayName: appState.displayName(forAccountIdHex: accountIdHex),
                    avatarURL: appState.avatarURL(forAccountIdHex: accountIdHex),
                    npub: npub,
                    shortNpub: appState.shortNpub(forAccountIdHex: accountIdHex),
                    qrImage: qrImage
                )
                .transition(.opacity)
            } else {
                scannerContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: mode)
        .localizedNavigationTitle("Share & Connect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(mode == .connect ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.palette)
                .controlSize(.extraLarge)
                .frame(width: 180)
                .wnNeutralAccentTint()
            }

            if mode == .share {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: deepLink) {
                        Label("Share Profile", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .wnNeutralAccentTint()
                }
            }
        }
        .task(id: deepLink) {
            qrImage = QRCode.image(from: deepLink, removesQuietZone: true)
        }
        .navigationDestination(isPresented: scannedProfileIsPresented) {
            if let scannedNpub {
                ProfileView(npub: scannedNpub)
            }
        }
    }

    private var scannerContent: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            QRScannerView(
                onScan: handleScan,
                onError: { scanError = ContentSanitizer.displayName($0) ?? L10n.string("Camera unavailable") }
            )
            .ignoresSafeArea()

            Text(scanError ?? L10n.string("Point the camera at a White Noise profile QR"))
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding()
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
    }

    private func handleScan(_ raw: String) {
        guard case let .profile(scannedNpub) = DeepLink.parse(string: raw) else {
            scanError = L10n.string("That QR code isn't a White Noise profile.")
            Haptics.error()
            return
        }

        Haptics.success()
        mode = .share
        self.scannedNpub = scannedNpub
    }

    private var scannedProfileIsPresented: Binding<Bool> {
        Binding(
            get: { scannedNpub != nil },
            set: { if !$0 { scannedNpub = nil } }
        )
    }
}

private struct ShareProfileContent: View {
    let accountIdHex: String
    let displayName: String
    let avatarURL: URL?
    let npub: String
    let shortNpub: String
    let qrImage: UIImage?

    var body: some View {
        Form {
            Section {
                ShareProfileIdentityHeader(
                    accountIdHex: accountIdHex,
                    displayName: displayName,
                    avatarURL: avatarURL,
                    npub: npub,
                    shortNpub: shortNpub
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                ShareProfileQRCode(image: qrImage)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}

private struct ShareProfileIdentityHeader: View {
    let accountIdHex: String
    let displayName: String
    let avatarURL: URL?
    let npub: String
    let shortNpub: String

    var body: some View {
        VStack(spacing: 8) {
            AvatarBubble(seed: accountIdHex, title: displayName, pictureURL: avatarURL)
                .frame(width: 96, height: 96)

            Text(displayName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            CopyableValueChip(
                display: shortNpub,
                copyValue: npub,
                valueName: L10n.string("npub")
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct ShareProfileQRCode: View {
    let image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            WNQRCodeCard(image: image, accessibilityLabel: "Profile QR code")

            Text("Scan to connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
    }
}

#Preview("Share profile") {
    NavigationStack {
        ShareProfileContent(
            accountIdHex: "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
            displayName: "Ada Lovelace",
            avatarURL: nil,
            npub: "npub1exampleexampleexampleexamplef4k2",
            shortNpub: "npub1exam…f4k2",
            qrImage: QRCode.image(
                from: "marmot://profile/npub1exampleexampleexampleexamplef4k2",
                removesQuietZone: true
            )
        )
        .navigationTitle("Share & Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}
