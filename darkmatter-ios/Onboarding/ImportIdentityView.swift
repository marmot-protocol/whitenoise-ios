import SwiftUI
import MarmotKit

/// Import an existing local-signing Nostr identity. `npub...` is only a public
/// identity and is intentionally not accepted as a sign-in credential.
struct ImportIdentityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = ImportIdentityViewModel()

    private var canSubmit: Bool {
        !model.isImporting && Self.isPlausibleNsec(model.identity)
    }

    /// A bech32 `nsec` is a fixed-width encoding of a 32-byte key: the `nsec1`
    /// human-readable prefix plus 58 data/checksum characters, 63 in total.
    /// Gating on `hasPrefix("nsec")` alone enabled Import for incomplete input
    /// like `nsec` or `nsecfoo` (issue #40); require the full canonical shape so
    /// the button only enables once a complete key has been entered.
    static func isPlausibleNsec(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("nsec1") && trimmed.count == 63
    }

    static func consumeIdentityForImport(_ raw: inout String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = ""
        return trimmed
    }

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                TextField("nsec1…", text: $model.identity, axis: .vertical)
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
                    Task { await model.runImport(using: appState, dismiss: { dismiss() }) }
                } label: {
                    HStack {
                        if model.isImporting {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isImporting ? L10n.string("Importing…") : L10n.string("Import"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
            }

            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Import Identity")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(model.isImporting)
        .onDisappear {
            model.identity = ""
        }
    }
}
