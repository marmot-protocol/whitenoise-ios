import SwiftUI
import MarmotKit

/// Per-account identity inspector. Shows the account id and offers a sign-out
/// affordance (which removes the account from the active list — the local
/// keychain entry is preserved). Exporting the nsec is intentionally not
/// surfaced in v1; marmot-app's CLI policy is "exporting private keys is
/// disabled" and the iOS app honors the same posture.
struct IdentityView: View {
    @Environment(AppState.self) private var appState
    @State private var showSignOutConfirm = false

    var body: some View {
        Form {
            if let active = appState.activeAccount {
                Section {
                    LabeledContent("Label") {
                        Text(active.label.isEmpty ? "—" : active.label)
                    }
                    LabeledContent("npub") {
                        Text(appState.shortNpub(forAccountIdHex: active.accountIdHex))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Local signing") {
                        Image(systemName: active.localSigning ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(active.localSigning ? .green : .red)
                    }
                    LabeledContent("Status") {
                        Text(active.running ? "Online" : "Idle")
                            .foregroundStyle(active.running ? .green : .secondary)
                    }
                }

                Section {
                    ShareLink(item: appState.npub(forAccountIdHex: active.accountIdHex)) {
                        Label("Share npub", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = appState.npub(forAccountIdHex: active.accountIdHex)
                        Haptics.selection()
                        appState.present(.success("Copied", message: "npub copied to clipboard."))
                    } label: {
                        Label("Copy npub", systemImage: "doc.on.doc")
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
                Text("Signing out only forgets which account is active. Identities and their key material stay in the device keychain so you can sign back in.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Identity")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                appState.activeAccountRef = appState.accounts
                    .first(where: { $0.label != appState.activeAccountRef })?
                    .label
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}
