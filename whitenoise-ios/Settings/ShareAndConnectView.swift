import SwiftUI

struct ShareAndConnectView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case share = "Share"
        case connect = "Connect"

        var id: Self { self }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode = Mode.share
    @State private var qrImage: UIImage?
    @State private var scannedNpub: String?
    @State private var scanHint: String?
    @State private var cameraFailure: QRScannerFailure?
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
        .onChange(of: scenePhase) { oldPhase, _ in
            if mode == .connect,
               QRScannerScenePolicy.restartsScanner(leavingPhase: oldPhase, showingFailure: cameraFailure != nil) {
                restartScanner()
            }
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

    @ViewBuilder
    private var scannerContent: some View {
        if let cameraFailure {
            QRScannerUnavailableView(failure: cameraFailure, retry: restartScanner)
        } else if QRScannerScenePolicy.mountsCamera(in: scenePhase) {
            liveScanner
        } else {
            ProgressView("Preparing Camera")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var liveScanner: some View {
        ZStack(alignment: .bottom) {
            ShareAndConnectChrome.viewfinderBackdrop
            QRScannerView(
                onScan: handleScan,
                onError: { cameraFailure = $0 }
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
        QRScannerUnavailableView(failure: .denied, retry: {})
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
