import AVFoundation
import SwiftUI

private enum PrivateKeyCameraState {
    case checking, scanning
    case failed(QRScannerFailure)
}

struct PrivateKeyQRScanner: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = PrivateKeyCameraState.checking
    @State private var showInvalidCode = false
    @State private var scanAttempt = 0
    @State private var cameraAttempt = 0
    let onScan: (String) -> Void

    var body: some View {
        cameraContent
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase == .active ? cameraAttempt : nil) {
                guard scenePhase == .active else {
                    state = .checking
                    return
                }
                await prepareCamera()
            }
            .alert("Can’t Use This QR Code", isPresented: $showInvalidCode) {
                Button("Try Again") { scanAttempt += 1 }
            } message: {
                Text("This QR code doesn’t contain a private key.")
            }
    }

    @ViewBuilder
    private var cameraContent: some View {
        switch state {
        case .checking:
            ProgressView("Preparing Camera")
        case .scanning:
            QRScannerView(
                onScan: onScan,
                onError: { state = .failed($0) },
                validate: ImportIdentityView.isPlausibleNsec,
                onInvalidPayload: { showInvalidCode = true },
                scanAttempt: scanAttempt
            )
            .ignoresSafeArea()
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        case .failed(let failure):
            QRScannerUnavailableView(
                failure: failure,
                retry: {
                    state = .checking
                    cameraAttempt += 1
                }
            )
        }
    }

    private func prepareCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if let failure = QRScannerFailure.preflight(
            authorization: status, hasCamera: AVCaptureDevice.default(for: .video) != nil
        ) {
            state = .failed(failure)
            return
        }
        switch status {
        case .authorized:
            state = .scanning
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled, scenePhase == .active else { return }
            state = granted ? .scanning : .failed(
                AVCaptureDevice.authorizationStatus(for: .video) == .restricted ? .restricted : .denied
            )
        case .denied:
            state = .failed(.denied)
        case .restricted:
            state = .failed(.restricted)
        @unknown default:
            state = .failed(.configurationFailed)
        }
    }
}
