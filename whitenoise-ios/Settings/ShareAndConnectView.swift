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

    private var npub: String? {
        appState.npub(forAccountIdHex: accountIdHex)
    }

    private var deepLink: String? {
        npub.map { DeepLink.profile(npub: $0).url.absoluteString }
    }

    var body: some View {
        ZStack {
            if mode == .share {
                shareContent
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
            }

            if mode == .share, let deepLink {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: deepLink) {
                        Label("Share Profile", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .task(id: deepLink) {
            qrImage = deepLink.flatMap { QRCode.image(from: $0) }
        }
        .navigationDestination(isPresented: scannedProfileIsPresented) {
            if let scannedNpub {
                ProfileView(npub: scannedNpub)
            }
        }
    }

    private var shareContent: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AvatarBubble(
                        seed: accountIdHex,
                        title: appState.displayName(forAccountIdHex: accountIdHex),
                        pictureURL: appState.avatarURL(forAccountIdHex: accountIdHex)
                    )
                    .frame(width: 96, height: 96)

                    Text(appState.displayName(forAccountIdHex: accountIdHex))
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    if let npub {
                        CopyableValueChip(
                            display: IdentityFormatter.short(npub),
                            copyValue: npub,
                            copiedToastTitle: L10n.string("npub")
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                VStack(spacing: 6) {
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 225, height: 225)
                            .padding(16)
                            .background(.white, in: .rect(cornerRadius: 20))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.quaternary, lineWidth: 0.5)
                            }
                            .accessibilityLabel("Profile QR code")
                    } else {
                        ProgressView()
                            .frame(width: 257, height: 257)
                    }

                    Text("Scan to connect.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 32)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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
