import SwiftUI
import MarmotKit

/// Per-account identity inspector. Shows the public key (hex) and its npub
/// (bech32) as tap-to-copy rows, plus signing + runtime status. Local-signing
/// accounts can export raw or encrypted nsec backups through Marmot's audited
/// keystore APIs. Profile fields (display name, etc.) are edited separately in
/// `ProfileEditView`.
struct IdentityView: View {
    @Environment(AppState.self) private var appState
    @State private var model = IdentityViewModel()

    var body: some View {
        @Bindable var model = model
        return Form {
            if let active = appState.activeAccount {
                Section {
                    CopyableValueRow(
                        label: "Public key",
                        display: IdentityFormatter.short(active.accountIdHex),
                        copyValue: active.accountIdHex
                    )
                    CopyableValueRow(
                        label: "npub",
                        display: appState.shortNpub(forAccountIdHex: active.accountIdHex),
                        copyValue: appState.npub(forAccountIdHex: active.accountIdHex)
                    )
                    LabeledContent("Local signing") {
                        Image(systemName: active.localSigning ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(active.localSigning ? .green : .red)
                    }
                    LabeledContent("Status") {
                        Text(active.running ? L10n.string("Online") : L10n.string("Idle"))
                            .foregroundStyle(active.running ? .green : .secondary)
                    }
                } footer: {
                    Text("“Online” means this account's runtime worker is active in the app right now (subscribed to its relays). It doesn't reflect key access.")
                        .font(.footnote)
                }

                if active.localSigning {
                    Section {
                        Button {
                            model.exportError = nil
                            model.showRawExportConfirm = true
                        } label: {
                            Label("Export raw nsec", systemImage: "key.fill")
                        }
                        .disabled(model.exportInFlight)

                        Button {
                            model.exportError = nil
                            model.showEncryptedExportSheet = true
                        } label: {
                            Label("Export encrypted nsec", systemImage: "lock.fill")
                        }
                        .disabled(model.exportInFlight)

                        if model.exportInFlight {
                            ProgressView("Preparing export")
                        }

                        if let exportError = model.exportError {
                            Label(exportError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    } header: {
                        Text("Backup")
                    } footer: {
                        Text("Raw export reveals your private key in plaintext and permanently marks it as handled insecurely. Encrypted export creates an ncryptsec1 backup protected by your passphrase without revealing the raw key.")
                            .font(.footnote)
                    }
                }
            } else {
                Section {
                    Text("No active account.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Identity")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $model.showRawExportConfirm) {
            FullScreenConfirmationDialog(
                title: "Export raw nsec?",
                message: "This reveals your private key in plaintext. The export is logged, and this account's key will be permanently marked as handled insecurely.",
                systemImage: "key.fill",
                destructiveTitle: "Export raw nsec",
                onConfirm: {
                    model.showRawExportConfirm = false
                    Task { await model.exportRawNsec(using: appState) }
                },
                onCancel: { model.showRawExportConfirm = false }
            )
            .appAppearance()
        }
        .sheet(isPresented: $model.showEncryptedExportSheet) {
            EncryptedNsecExportSheet(
                isExporting: model.exportInFlight,
                errorMessage: model.exportError,
                onCancel: {
                    model.showEncryptedExportSheet = false
                    model.exportError = nil
                },
                onExport: { passphrase in
                    Task { await model.exportEncryptedNsec(passphrase: passphrase, using: appState) }
                }
            )
            .appAppearance()
        }
        .sheet(isPresented: Binding(
            get: { model.exportShareText != nil },
            set: { if !$0 { model.exportShareText = nil } }
        )) {
            if let exportShareText = model.exportShareText {
                ActivityShareSheet(items: [exportShareText]) {
                    model.exportShareText = nil
                }
                .appAppearance()
            }
        }
    }
}

private struct EncryptedNsecExportSheet: View {
    let isExporting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onExport: (String) -> Void

    @State private var passphrase = ""
    @FocusState private var passphraseFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.password)
                        .focused($passphraseFocused)
                        .disabled(isExporting)
                } footer: {
                    Text("Your passphrase encrypts the exported ncryptsec1 backup. Marmot never stores it.")
                        .font(.footnote)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Encrypted export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        onExport(passphrase)
                    }
                    .disabled(isExporting || passphrase.isEmpty)
                }
            }
            .onAppear {
                passphraseFocused = true
            }
        }
        .interactiveDismissDisabled(isExporting)
    }
}

/// A LabeledContent row whose value copies to the clipboard on tap. Shows a
/// short form; copies the full value. Gives haptic feedback and a brief
/// inline "Copied" + checkmark affordance.
private struct CopyableValueRow: View {
    let label: String
    let display: String
    let copyValue: String

    @State private var justCopied = false

    var body: some View {
        Button(action: copy) {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(justCopied ? L10n.string("Copied") : display)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(justCopied ? Color.green : Color.secondary)
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(justCopied ? Color.green : Color.accentColor)
                }
                .contentShape(.rect)
            } label: {
                Text(LocalizedStringKey(label))
            }
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        UIPasteboard.general.string = copyValue
        Haptics.selection()
        withAnimation(.smooth(duration: 0.15)) { justCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.smooth(duration: 0.2)) { justCopied = false }
        }
    }
}
