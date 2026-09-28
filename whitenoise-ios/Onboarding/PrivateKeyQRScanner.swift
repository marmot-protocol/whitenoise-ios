import SwiftUI

struct PrivateKeyQRScanner: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var failure: QRScannerFailure?
    @State private var scanSession = UUID()
    @State private var showInvalidCode = false
    @State private var scanAttempt = 0
    let onScan: (String) -> Void

    var body: some View {
        Group {
            if let failure {
                QRScannerUnavailableView(failure: failure, retry: restartScanner)
            } else if QRScannerScenePolicy.mountsCamera(in: scenePhase) {
                PrivateKeyLiveScanner(
                    scanSession: scanSession,
                    scanAttempt: scanAttempt,
                    onScan: onScan,
                    onError: { failure = $0 },
                    onInvalidPayload: { showInvalidCode = true }
                )
                .overlay {
                    if QRScannerScenePolicy.coversPreview(in: scenePhase) {
                        Color.black.ignoresSafeArea()
                    }
                }
            } else {
                ProgressView("Preparing Camera")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { oldPhase, _ in
            if QRScannerScenePolicy.restartsScanner(leavingPhase: oldPhase, showingFailure: failure != nil) {
                restartScanner()
            }
        }
        .alert("Can’t Use This QR Code", isPresented: $showInvalidCode) {
            Button("Try Again") { scanAttempt += 1 }
        } message: {
            Text("This QR code doesn’t contain a private key.")
        }
    }

    private func restartScanner() {
        failure = nil
        scanSession = UUID()
    }
}
