import SwiftUI

/// Wraps the scanner in its own nav chrome with a Cancel button + error
/// surface, so the camera view has a way out.
struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                QRScannerView(
                    onScan: { onScan($0) },
                    onError: { error = $0 }
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
                            .padding(.bottom, 40)
                    } else {
                        Text("Point the camera at a White Noise profile QR")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.5), in: .capsule)
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
