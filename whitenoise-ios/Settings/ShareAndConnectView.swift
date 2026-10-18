import AVFoundation
import MarmotKit
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
    @State private var qrUnavailable = false
    @State private var scannedNpub: String?
    @State private var previouslyScannedPayload: String?
    @State private var scanHint: String?
    @State private var scanHintID = UUID()
    @State private var cameraFailure: QRScannerFailure?
    @State private var scanSession = UUID()
    @State private var scanAttempt = 0
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
                    qrImage: qrImage,
                    qrUnavailable: qrUnavailable,
                    nostrAddress: ContentSanitizer.profileAddress(
                        appState.cachedProfile(forAccountIdHex: accountIdHex)?.nip05
                    )
                )
                .transition(.opacity)
            } else {
                scannerContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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
        .modifier(ShareAndConnectNavigationChrome(
            isScanning: mode == .connect && scannedNpub == nil && cameraFailureReason == nil
        ))
        .task(id: deepLink) {
            qrImage = deepLink.flatMap { QRCode.image(from: $0) }
            qrUnavailable = deepLink != nil && qrImage == nil
        }
        .task(id: scanHintID) {
            guard scanHint != nil else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled, scanHint != nil, scannedNpub == nil else { return }
            scanHint = nil
            // Allow the same invalid code to show feedback again after this message expires.
            scanAttempt &+= 1
        }
        .onChange(of: mode) { _, newValue in
            cancelPicture()
            if newValue == .connect { restartScanner() }
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active, mode == .connect, scannedNpub == nil { restartScanner() }
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
        .navigationDestination(item: $scannedNpub) { npub in
            // Reuse the current stack; ProfileView owns a stack for sheet presentation.
            ProfileContentView(npub: npub)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarRole(.editor)
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

    private var cameraFailureReason: QRScannerFailure? {
        cameraFailure ?? QRScannerFailure.preflight(
            authorization: AVCaptureDevice.authorizationStatus(for: .video),
            hasCamera: AVCaptureDevice.default(for: .video) != nil
        )
    }

    @ViewBuilder
    private var scannerContent: some View {
        if let cameraFailureReason {
            QRScannerUnavailableView(failure: cameraFailureReason, retry: restartScanner, usesSystemActions: true)
        } else if scenePhase == .active, scannedNpub == nil {
            liveScanner
        }
    }

    private var liveScanner: some View {
        ProfileScannerSurface(hint: scanHint) {
            QRScannerView(
                onScan: handleScan,
                onError: { cameraFailure = $0 },
                validate: { raw in
                    if case .profile = DeepLink.parse(string: raw) { true } else { false }
                },
                onInvalidPayload: showInvalidScanHint,
                scanAttempt: scanAttempt,
                continuesAfterInvalidPayload: true,
                previouslyScannedPayload: previouslyScannedPayload,
                onPreviousPayloadCleared: { previouslyScannedPayload = nil }
            )
            .id(scanSession)
        }
    }

    private func showInvalidScanHint() {
        guard scanHint == nil else { return }
        scanHintID = UUID()
        scanHint = L10n.string("That QR code isn't a White Noise profile.")
    }

    private func handleScan(_ raw: String) {
        guard case let .profile(scannedNpub) = DeepLink.parse(string: raw) else { return }

        Haptics.success()
        scanHint = nil
        previouslyScannedPayload = raw
        self.scannedNpub = scannedNpub
    }

    private func restartScanner() {
        scanHint = nil
        cameraFailure = nil
        scanSession = UUID()
    }
}

private struct ShareAndConnectNavigationChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isScanning: Bool

    func body(content: Content) -> some View {
        content
            .toolbarBackground(isScanning ? .hidden : .automatic, for: .navigationBar)
            .toolbarColorScheme(isScanning ? .dark : nil, for: .navigationBar)
            .environment(\.colorScheme, isScanning ? .dark : colorScheme)
            .tint(WNNeutralAccent.color(for: isScanning ? .dark : colorScheme))
    }
}

private struct ProfileScannerSurface<Camera: View>: View {
    var hint: String?
    @ViewBuilder let camera: () -> Camera

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            camera().ignoresSafeArea()
            // Keep the floating controls readable over a bright camera image.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            Label(hint ?? L10n.string("Scan a profile QR code"), systemImage: "qrcode.viewfinder")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding()
                .background(.black.opacity(0.4), in: Capsule())
                .padding()
        }
    }
}

private struct ShareProfileContent: View {
    let accountIdHex: String
    let displayName: String
    let avatarURL: URL?
    let npub: String?
    let qrImage: UIImage?
    var qrUnavailable = false
    var nostrAddress: String?

    var body: some View {
        Form {
            Section {
                ProfileIdentityHeader(
                    name: displayName, npub: npub,
                    nostrAddress: nostrAddress,
                    compactPublicKey: true
                ) { size in
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
                    ShareProfileQRCode(image: qrImage, unavailable: qrUnavailable)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }
}

private struct ShareProfileQRCode: View {
    let image: UIImage?
    var unavailable = false

    var body: some View {
        VStack(spacing: 6) {
            WNQRCodeCard(
                image: image,
                accessibilityLabel: unavailable ? "QR Code Unavailable" : "Profile QR code",
                unavailableDescription: unavailable
                    ? "You can still share your profile link from the Share menu." : nil
            )

            if !unavailable {
                Text("Scan to connect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
    }
}

#Preview("Scanner unavailable") {
    NavigationStack {
        QRScannerUnavailableView(failure: .denied, retry: {}, usesSystemActions: true)
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
