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
        return !isImporting && (trimmed.hasPrefix("nsec") || trimmed.hasPrefix("npub"))
    }

    var body: some View {
        Form {
            Section {
                TextField("nsec1… or npub1…", text: $identity, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...6)
            } header: {
                Text("Identity")
            } footer: {
                Text("Pasting an nsec stores it in the device keychain. Pasting an npub tracks the account read-only — you won't be able to send messages.")
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
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isImporting = false
    }
}
