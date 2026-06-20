import SwiftUI
import MarmotKit

/// Per-account identity inspector. Shows the projected display name, the
/// public key (hex) and its npub (bech32) as tap-to-copy rows, plus signing
/// + runtime status. Exporting the nsec is intentionally not surfaced —
/// marmot-app's policy is "private key export disabled" and the iOS app
/// honors the same posture.
struct IdentityView: View {
    @Environment(AppState.self) private var appState
    @State private var showSignOutConfirm = false

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
