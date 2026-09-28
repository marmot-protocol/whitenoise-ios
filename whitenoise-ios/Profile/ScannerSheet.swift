import SwiftUI

struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onScan: (String) -> Void
    @State private var failure: QRScannerFailure?
    @State private var scanSession = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    QRScannerUnavailableView(failure: failure, retry: restartScanner)
                } else if QRScannerScenePolicy.mountsCamera(in: scenePhase) {
                    liveScanner
                } else {
                    ProgressView("Preparing Camera")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: scenePhase) { oldPhase, _ in
                if QRScannerScenePolicy.restartsScanner(leavingPhase: oldPhase, showingFailure: failure != nil) {
                    restartScanner()
                }
            }
        }
    }

    private var liveScanner: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            QRScannerView(onScan: onScan, onError: { failure = $0 })
                .id(scanSession)
                .ignoresSafeArea()

            Text("Point the camera at a White Noise profile QR")
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding()
                .background(.black.opacity(0.5), in: .capsule)
                .padding(.horizontal)
                .padding(.bottom, 40)
        }
    }

    private func restartScanner() {
        failure = nil
        scanSession = UUID()
    }
}
