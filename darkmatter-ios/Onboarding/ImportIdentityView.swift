import SwiftUI
import MarmotKit

/// Import an existing local-signing Nostr identity. `npub...` is only a public
/// identity and is intentionally not accepted as a sign-in credential.
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
                    .privacySensitive()
            } header: {
                Text("Identity")
            } footer: {
                Text("Paste your nsec (bech32 secret key). Public npub values are for sharing and cannot sign in.")
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
                        Text(isImporting ? L10n.string("Importing…") : L10n.string("Import"))
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
            SensitiveClipboard.clear(trimmed)
            identity = ""
            Haptics.success()
            appState.present(.success(L10n.string("Welcome back"), message: L10n.string("Identity imported.")))
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Import failed"), message: error.localizedDescription))
        }
        isImporting = false
    }
}
