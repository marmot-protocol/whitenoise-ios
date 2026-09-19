import AVFoundation
import SwiftUI

struct ShareAndConnectView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case share = "Share"
        case connect = "Connect"

        var id: Self { self }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode = Mode.share
    @State private var qrImage: UIImage?
    @State private var scannedNpub: String?
    @State private var scanHint: String?
    @State private var cameraFailure: String?
    @State private var scanSession = UUID()
    @State private var pictureTask: Task<Void, Never>?
    @State private var pictureRequestID: UUID?
    @State private var sharedPicture: SharedProfilePicture?
    @State private var pictureFailed = false

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
                ShareProfileContent(
                    accountIdHex: accountIdHex,
                    displayName: appState.displayName(forAccountIdHex: accountIdHex),
                    avatarURL: appState.avatarURL(forAccountIdHex: accountIdHex),
                    npub: npub,
                    qrImage: qrImage
                )
                .transition(.opacity)
            } else {
                scannerContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShareAndConnectChrome.pageBackdrop.ignoresSafeArea())
        .animation(.default, value: mode)
        .localizedNavigationTitle("Share & Connect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .wnPalettePicker()
                .frame(width: 180)
            }

            if mode == .share, let deepLink {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: deepLink) {
                            Label("Share Profile URL", systemImage: "link")
                        }
                        Button {
                            preparePicture(deepLink: deepLink)
                        } label: {
                            Label("Share Profile Picture", systemImage: "photo")
                        }
                        .disabled(pictureRequestID != nil)
                    } label: {
                        if pictureRequestID != nil {
                            ProgressView().accessibilityLabel("Preparing profile picture")
                        } else {
                            Label("Share Profile", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .wnIconButtonChrome(chrome: .container)
                }
            }
        }
        .task(id: deepLink) {
            qrImage = deepLink.flatMap { QRCode.image(from: $0) }
        }
        .onChange(of: mode) { _, newValue in
            cancelPicture()
            if newValue == .connect { restartScanner() }
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active, mode == .connect, cameraFailure != nil { restartScanner() }
        }
        .sheet(item: $sharedPicture) { picture in
            ActivityShareSheet(items: [picture.image])
        }
        .alert("Couldn't prepare profile picture", isPresented: $pictureFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try sharing again.")
        }
        .onDisappear { cancelPicture() }
        .onChange(of: accountIdHex) { _, _ in cancelPicture() }
        .onChange(of: appState.activeAccountRef) { _, _ in cancelPicture() }
        .onChange(of: appState.runtimeGeneration) { _, _ in cancelPicture() }
        .onChange(of: appState.isErasingAppData) { _, erasing in
            if erasing { cancelPicture() }
        }
        .navigationDestination(isPresented: scannedProfileIsPresented) {
            if let scannedNpub {
                ProfileView(npub: scannedNpub)
            }
        }
    }

    private func cancelPicture() {
        pictureTask?.cancel()
        pictureTask = nil
        pictureRequestID = nil
        sharedPicture = nil
    }

    private func preparePicture(deepLink: String) {
        guard pictureRequestID == nil, !appState.isErasingAppData else { return }
        let requestID = UUID()
        let displayName = appState.displayName(forAccountIdHex: accountIdHex)
        let avatarURL = appState.avatarURL(forAccountIdHex: accountIdHex)
        let erasureGeneration = AvatarCacheErasure.generation
        let runtimeGeneration = appState.runtimeGeneration
        let activeAccount = appState.activeAccountRef
        pictureRequestID = requestID
        pictureTask = Task { @MainActor in
            defer {
                if pictureRequestID == requestID {
                    pictureRequestID = nil
                    pictureTask = nil
                }
            }
            do {
                var avatar: UIImage?
                if let avatarURL {
                    let client = try appState.currentMarmotClient()
                    avatar = try await RemoteAvatarImageLoader.image(
                        for: avatarURL, maxPixelSize: 384, scale: 3,
                        fetch: { url in
                            try await client.downloadProfileImage(
                                url: url.absoluteString,
                                maxBytes: UInt64(RemoteImageFetch.maximumImageBytes)
                            )
                        }
                    )
                }
                try Task.checkCancellation()
                guard pictureRequestID == requestID,
                      erasureGeneration == AvatarCacheErasure.generation,
                      runtimeGeneration == appState.runtimeGeneration,
                      activeAccount == appState.activeAccountRef,
                      !appState.isErasingAppData else { return }
                let image = try ProfileShareCard.render(
                    accountIdHex: accountIdHex, displayName: displayName,
                    avatar: avatar, profileURL: deepLink
                )
                sharedPicture = SharedProfilePicture(image: image)
            } catch {
                guard !Task.isCancelled, pictureRequestID == requestID else { return }
                pictureFailed = true
            }
        }
    }

    private var cameraFailureMessage: String? {
        cameraFailure ?? Self.unavailableReason()
    }

    private static func unavailableReason() -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return L10n.string("Camera access denied. Enable it in Settings to scan QR codes.")
        default:
            return AVCaptureDevice.default(for: .video) == nil
                ? L10n.string("No camera available on this device.")
                : nil
        }
    }

    @ViewBuilder
    private var scannerContent: some View {
        if let cameraFailureMessage {
            ScannerUnavailableContent(
                message: cameraFailureMessage,
                offersSettings: AVCaptureDevice.authorizationStatus(for: .video) == .denied,
                openSettings: openAppSettings
            )
        } else {
            liveScanner
        }
    }

    private var liveScanner: some View {
        ZStack(alignment: .bottom) {
            ShareAndConnectChrome.viewfinderBackdrop
            QRScannerView(
                onScan: handleScan,
                onError: { cameraFailure = ContentSanitizer.displayName($0) ?? L10n.string("Camera unavailable") }
            )
            .id(scanSession)

            Text(scanHint ?? L10n.string("Point the camera at a White Noise profile QR"))
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .clipShape(.rect(cornerRadius: ShareAndConnectChrome.viewfinderCornerRadius, style: .continuous))
        .padding(ShareAndConnectChrome.viewfinderInset)
    }

    private func handleScan(_ raw: String) {
        guard case let .profile(scannedNpub) = DeepLink.parse(string: raw) else {
            scanHint = L10n.string("That QR code isn't a White Noise profile.")
            scanSession = UUID()
            Haptics.error()
            return
        }

        Haptics.success()
        mode = .share
        self.scannedNpub = scannedNpub
    }

    private func restartScanner() {
        scanHint = nil
        cameraFailure = nil
        scanSession = UUID()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var scannedProfileIsPresented: Binding<Bool> {
        Binding(
            get: { scannedNpub != nil },
            set: { if !$0 { scannedNpub = nil } }
        )
    }
}

nonisolated enum ShareAndConnectChrome {
    static let viewfinderCornerRadius: CGFloat = WNQRCodeCard.Metrics.cornerRadius
    static let viewfinderInset: CGFloat = 16
    static let viewfinderBackdrop = Color.black

    static let pageBackdrop = Color(uiColor: .systemGroupedBackground)
    static let barBackdrop = pageBackdrop
}

private struct ScannerUnavailableContent: View {
    let message: String
    let offersSettings: Bool
    let openSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("QR Scanning Unavailable", systemImage: "camera.fill")
        } description: {
            Text(message)
        } actions: {
            if offersSettings {
                WNButton(title: "Open Settings", size: .standard, action: openSettings)
                    .frame(maxWidth: 320)
            }
        }
    }
}

private struct ShareProfileContent: View {
    let accountIdHex: String
    let displayName: String
    let avatarURL: URL?
    let npub: String?
    let qrImage: UIImage?

    var body: some View {
        Form {
            Section {
                ProfileIdentityHeader(name: displayName, npub: npub) { size in
                    AvatarBubble(seed: accountIdHex, title: displayName, pictureURL: avatarURL)
                        .frame(width: size, height: size)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // No npub means no QR to render, so the affordance is withheld
            // rather than left spinning on a load that can never finish.
            if npub != nil {
                Section {
                    ShareProfileQRCode(image: qrImage)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
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

#Preview("Scanner unavailable") {
    NavigationStack {
        ScannerUnavailableContent(
            message: L10n.string("Camera access denied. Enable it in Settings to scan QR codes."),
            offersSettings: true,
            openSettings: {}
        )
        .navigationTitle("Share & Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Share profile") {
    NavigationStack {
        ShareProfileContent(
            accountIdHex: "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
            displayName: "Ada Lovelace",
            avatarURL: nil,
            npub: "npub1exampleexampleexampleexamplef4k2",
            qrImage: QRCode.image(from: "marmot://profile/npub1exampleexampleexampleexamplef4k2")
        )
        .navigationTitle("Share & Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SharedProfilePicture: Identifiable {
    let id = UUID()
    let image: UIImage
}
