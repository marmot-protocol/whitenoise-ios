import SwiftUI
import MarmotKit

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAdd = false

    var body: some View {
        Form {
            Section("Identities") {
                ForEach(appState.accounts, id: \.label) { account in
                    Button {
                        appState.activeAccountRef = account.label
                    } label: {
                        accountRow(account)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("Add Account", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                WelcomeView()
            }
        }
    }

    private func accountRow(_ account: AccountSummaryFfi) -> some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: account.accountIdHex,
                title: IdentityFormatter.displayName(
                    label: account.label,
                    accountIdHex: account.accountIdHex
                )
            )
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(IdentityFormatter.displayName(
                    label: account.label,
                    accountIdHex: account.accountIdHex
                ))
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                Text(IdentityFormatter.short(account.accountIdHex))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if account.label == appState.activeAccountRef {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if !account.localSigning {
                    Text("Read-only")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
