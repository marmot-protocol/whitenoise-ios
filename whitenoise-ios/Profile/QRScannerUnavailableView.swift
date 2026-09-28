import SwiftUI

struct QRScannerUnavailableView: View {
    @Environment(\.openURL) private var openURL
    @State private var settingsFeedback: String?

    let failure: QRScannerFailure
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("QR Scanning Unavailable", systemImage: "qrcode.viewfinder")
        } description: {
            Text(message)
        } actions: {
            VStack(spacing: 12) {
                switch failure.recovery {
                case .settings:
                    WNButton(title: "Open Settings", size: .standard, action: openSettings)
                case .retry:
                    WNButton(title: "Try Again", size: .standard, action: retry)
                case .none:
                    EmptyView()
                }
                if let settingsFeedback {
                    Text(settingsFeedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 320)
        }
        .onChange(of: failure) { _, _ in settingsFeedback = nil }
    }

    private var message: String {
        switch failure {
        case .denied:
            L10n.string("Camera access denied. Enable it in Settings to scan QR codes.")
        case .restricted:
            L10n.string("Camera access is restricted by device controls. It can’t be enabled from this app.")
        case .noCamera:
            L10n.string("No camera available on this device.")
        case .configurationFailed:
            L10n.string("Couldn't start the camera.")
        case .cameraInUse:
            L10n.string("Another app is using the camera. Close it, then try again.")
        case .requiresFullScreen:
            L10n.string("Use White Noise full screen, then try scanning again.")
        case .interrupted:
            L10n.string("Camera use was interrupted. Wait a moment, then try again.")
        }
    }

    private func openSettings() {
        settingsFeedback = nil
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            showSettingsFailure()
            return
        }
        openURL(url) { accepted in
            if !accepted { showSettingsFailure() }
        }
    }

    private func showSettingsFailure() {
        settingsFeedback = L10n.string("Couldn’t open Settings. Open the Settings app and allow camera access for White Noise.")
    }
}
