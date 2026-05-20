import SwiftUI
import MarmotKit

/// Generate a brand-new Nostr identity. The keypair is created and stored
/// in the iOS Keychain inside marmot-app; we don't see the nsec in Swift.
struct CreateIdentityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false
    @State private var error: String?
    @State private var created: AccountSummaryFfi?

    var body: some View {
        Form {
            Section {
                Text("Generates a fresh Nostr identity and stores the secret key in your device's secure enclave.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let created {
                Section("Your new identity") {
                    LabeledContent("Account") {
                        Text(IdentityFormatter.short(created.accountIdHex))
                            .font(.system(.callout, design: .monospaced))
                    }
                    LabeledContent("Local signing") {
                        Image(systemName: created.localSigning ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(created.localSigning ? .green : .red)
                    }
                }

                Section {
                    Button {
                        dismiss()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                Section {
                    Button {
                        Task { await runCreate() }
                    } label: {
                        HStack {
                            if isCreating {
                                ProgressView().controlSize(.small)
                            }
                            Text(isCreating ? "Creating…" : "Generate Identity")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isCreating)
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("New Identity")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isCreating)
    }

    @MainActor
    private func runCreate() async {
        isCreating = true
        error = nil
        do {
            let summary = try await appState.createIdentity()
            created = summary
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }
}
