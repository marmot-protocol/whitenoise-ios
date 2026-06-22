import SwiftUI
import MarmotKit

/// Account picker presented from the Chats toolbar avatar. Tapping a row
/// switches the active account; the trailing QR icon opens that account's
/// shareable profile-code screen.
struct AccountSwitcherSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var qrAccount: QRAccount?

    struct QRAccount: Identifiable {
        let hex: String
        var id: String { hex }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.accounts, id: \.label) { account in
                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    await appState.activateAccount(account.label)
                                    Haptics.selection()
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarBubble(
                                        seed: account.accountIdHex,
                                        title: appState.displayName(forAccountIdHex: account.accountIdHex),
                                        pictureURL: appState.avatarURL(forAccountIdHex: account.accountIdHex)
                                    )
                                    .frame(width: 40, height: 40)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(appState.displayName(forAccountIdHex: account.accountIdHex))
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(appState.shortNpub(forAccountIdHex: account.accountIdHex))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)

                                    if let summary = appState.accountUnreadSummary(
                                        forAccountIdHex: account.accountIdHex
                                    ), summary.hasUnread {
                                        Text(unreadBadgeText(summary.unreadCount))
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .monospacedDigit()
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.accentColor))
                                            .accessibilityLabel(L10n.plural(
                                                "%llu unread messages",
                                                summary.unreadCount
                                            ))
                                    }

                                    if account.label == appState.activeAccountRef {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else if account.signedOut {
                                        Text(L10n.string("Signed out"))
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.18), in: Capsule())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)

                            Button {
                                qrAccount = QRAccount(hex: account.accountIdHex)
                            } label: {
                                Image(systemName: "qrcode")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                                    .padding(.leading, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show profile QR code")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } footer: {
                    Text(appVersion)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $qrAccount) { account in
                ProfileQRView(accountIdHex: account.hex)
                    .appAppearance()
            }
            .task {
                await appState.refreshAccountUnreadSummaries()
            }
        }
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? "—"
        return L10n.formatted("Version %@ (%@)", version, build)
    }

    private func unreadBadgeText(_ count: UInt64) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}
