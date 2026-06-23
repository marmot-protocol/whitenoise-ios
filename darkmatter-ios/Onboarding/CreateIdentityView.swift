import SwiftUI

/// Generate a brand-new Nostr identity. The keypair is created and stored in
/// the iOS Keychain inside marmot-app; we never see the nsec in Swift.
///
/// On success the parent routes automatically: during onboarding the app
/// advances to the main UI; when adding an account, the Accounts sheet
/// dismisses back to the accounts list. There's no intermediate "created"
/// screen.
struct CreateIdentityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = CreateIdentityViewModel()

    var body: some View {
        Form {
            Section {
                Text("Generates a fresh Nostr identity and stores the secret key securely in your device's Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await model.runCreate(using: appState, dismiss: { dismiss() }) }
                } label: {
                    HStack {
                        if model.isCreating {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isCreating ? L10n.string("Creating…") : L10n.string("Generate Identity"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isCreating)
            }

            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("New Identity")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(model.isCreating)
    }
}
