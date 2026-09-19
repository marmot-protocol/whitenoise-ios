import SwiftUI
import MarmotKit

nonisolated enum ProfileReferenceResolution {
    static func referenceForResolution(_ raw: String) -> String? {
        // The current MarmotKit account resolver accepts npub/hex, so validated
        // nprofile values cross the binding boundary as their canonical hex key.
        NostrProfileReference.memberRef(from: raw)
    }

    static func accountIdHex(_ raw: String) -> String? {
        guard let reference = referenceForResolution(raw) else { return nil }
        return Hex.normalized32Bytes(reference)
            ?? NostrProfileReference.pubkeyHex(fromBech32: reference)
    }
}

/// Profile destination for QR scans and deep links: the reusable profile
/// content inside its own navigation chrome. Conversational contexts push
/// `ProfileContentView` directly so they can attach moderation scope.
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss

    let npub: String

    var body: some View {
        NavigationStack {
            ProfileContentView(npub: npub)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
