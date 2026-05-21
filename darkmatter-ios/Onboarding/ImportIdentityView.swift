import SwiftUI
import MarmotKit

/// Import an existing Nostr identity. Accepts an `nsec...` (local signing) or
/// `npub...` (read-only / tracked) bech32 string.
struct ImportIdentityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var identity: String = ""
    @State private var isImporting = false
    @State private var error: String?

    private var canSubmit: Bool {
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isImporting && trimmed.hasPrefix("nsec")
    }

    var body: some View {
        Form {
            Section {
                TextField("nsec1…", text: $identity, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...6)
            } header: {
                Text("Identity")
            } footer: {
                Text("Paste your nsec (bech32 secret key). It's stored securely in your device's Keychain.")
                    .font(.footnote)
            }

            Section {
                Button {
                    Task { await runImport() }
                } label: {
                    HStack {
                        if isImporting {
                            ProgressView().controlSize(.small)
                        }
                        Text(isImporting ? "Importing…" : "Import")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Import Identity")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isImporting)
    }

    @MainActor
    private func runImport() async {
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        isImporting = true
        error = nil
        do {
            try await appState.importIdentity(trimmed)
            Haptics.success()
            appState.present(.success("Welcome back", message: "Identity imported."))
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error("Import failed", message: error.localizedDescription))
        }
        isImporting = false
    }
}
