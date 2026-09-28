import SwiftUI

struct PrivateKeyLiveScanner: View {
    let scanSession: UUID
    let scanAttempt: Int
    let onScan: (String) -> Void
    let onError: (QRScannerFailure) -> Void
    let onInvalidPayload: () -> Void

    var body: some View {
        QRScannerView(
            onScan: onScan,
            onError: onError,
            validate: ImportIdentityView.isPlausibleNsec,
            onInvalidPayload: onInvalidPayload,
            scanAttempt: scanAttempt
        )
        .id(scanSession)
        .ignoresSafeArea()
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

#Preview {
    PrivateKeyLiveScanner(
        scanSession: UUID(),
        scanAttempt: 0,
        onScan: { _ in },
        onError: { _ in },
        onInvalidPayload: {}
    )
}
