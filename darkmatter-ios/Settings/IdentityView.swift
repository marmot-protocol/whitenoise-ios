import SwiftUI
import MarmotKit

/// Per-account identity inspector. Shows the projected display name, the
/// public key (hex) and its npub (bech32) as tap-to-copy rows, plus signing
/// + runtime status. Local-signing accounts can export raw or encrypted nsec
/// backups through Marmot's audited keystore APIs.
struct IdentityView: View {
    @Environment(AppState.self) private var appState
    @State private var showSignOutConfirm = false
    @State private var showRawExportConfirm = false
    @State private var showEncryptedExportSheet = false
    @State private var exportShareText: String?
    @State private var exportInFlight = false
    @State private var exportError: String?

    var body: some View {
        Form {
            if let active = appState.activeAccount {
                Section {
                    LabeledContent("Display name") {
                        Text(appState.displayName(forAccountIdHex: active.accountIdHex))
                            .foregroundStyle(.primary)
                    }
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
                            exportError = nil
                            showRawExportConfirm = true
                        } label: {
                            Label("Export raw nsec", systemImage: "key.fill")
                        }
                        .disabled(exportInFlight)

                        Button {
                            exportError = nil
                            showEncryptedExportSheet = true
                        } label: {
                            Label("Export encrypted nsec", systemImage: "lock.fill")
                        }
                        .disabled(exportInFlight)

                        if exportInFlight {
                            ProgressView("Preparing export")
                        }

                        if let exportError {
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

            Section {
                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    Label("Sign out of this account", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(appState.activeAccount == nil)
            } footer: {
                Text("Signing out removes this account and its local key material from this device.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Identity")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showSignOutConfirm) {
            FullScreenConfirmationDialog(
                title: "Sign out?",
                message: "Signing out removes this account and its local key material from this device.",
                systemImage: "rectangle.portrait.and.arrow.right",
                destructiveTitle: "Sign out",
                onConfirm: {
                    showSignOutConfirm = false
                    Task { await appState.signOut() }
                },
                onCancel: { showSignOutConfirm = false }
            )
            .appAppearance()
        }
        .fullScreenCover(isPresented: $showRawExportConfirm) {
            FullScreenConfirmationDialog(
                title: "Export raw nsec?",
                message: "This reveals your private key in plaintext. The export is logged, and this account's key will be permanently marked as handled insecurely.",
                systemImage: "key.fill",
                destructiveTitle: "Export raw nsec",
                onConfirm: {
                    showRawExportConfirm = false
                    Task { await exportRawNsec() }
                },
                onCancel: { showRawExportConfirm = false }
            )
            .appAppearance()
        }
        .sheet(isPresented: $showEncryptedExportSheet) {
            EncryptedNsecExportSheet(
                isExporting: exportInFlight,
                errorMessage: exportError,
                onCancel: {
                    showEncryptedExportSheet = false
                    exportError = nil
                },
                onExport: { passphrase in
                    Task { await exportEncryptedNsec(passphrase: passphrase) }
                }
            )
            .appAppearance()
        }
        .sheet(isPresented: exportSharePresented) {
            if let exportShareText {
                ActivityShareSheet(items: [exportShareText]) {
                    self.exportShareText = nil
                }
                .appAppearance()
            }
        }
    }

    private var exportSharePresented: Binding<Bool> {
        Binding(
            get: { exportShareText != nil },
            set: { isPresented in
                if !isPresented {
                    exportShareText = nil
                }
            }
        )
    }

    @MainActor
    private func exportRawNsec() async {
        guard let accountRef = appState.activeAccountRef else { return }
        exportInFlight = true
        exportError = nil
        defer { exportInFlight = false }

        do {
            let nsec = try await appState.revealNsec(accountRef: accountRef)
            exportShareText = nsec
            Haptics.success()
        } catch {
            Haptics.error()
            exportError = IdentityKeyExportPresentation.errorMessage(for: error)
        }
    }

    @MainActor
    private func exportEncryptedNsec(passphrase: String) async {
        guard let accountRef = appState.activeAccountRef else { return }
        exportInFlight = true
        exportError = nil
        defer { exportInFlight = false }

        do {
            let ncryptsec = try await appState.exportEncryptedSecretKey(
                accountRef: accountRef,
                passphrase: passphrase
            )
            showEncryptedExportSheet = false
            exportShareText = ncryptsec
            Haptics.success()
        } catch {
            Haptics.error()
            exportError = IdentityKeyExportPresentation.errorMessage(for: error)
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
