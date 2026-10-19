import SwiftUI
import MarmotKit

private enum SettingsDestination: String, CaseIterable, Hashable {
    case profile
    case profileKeys
    case notifications
    case appearance
    case privacyAndSecurity
    case dataUsage
    case relays
    case aiAgents
    case support
    case donate
    case developerTools

    var title: LocalizedStringKey {
        switch self {
        case .profile: "Profile"
        case .profileKeys: "Profile Keys"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .privacyAndSecurity: "Privacy & Security"
        case .dataUsage: "Data Usage"
        case .relays: "Relays"
        case .aiAgents: "AI Agents"
        case .support: "Chat with support"
        case .donate: "Donate"
        case .developerTools: "Developer Tools"
        }
    }

    var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .profileKeys: "key"
        case .notifications: "bell"
        case .appearance: "circle.lefthalf.filled"
        case .privacyAndSecurity: "hand.raised"
        case .dataUsage: "externaldrive"
        case .relays: "antenna.radiowaves.left.and.right"
        case .aiAgents: "sparkles"
        case .support: "message"
        case .donate: "heart"
        case .developerTools: "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showAccounts = false
    @State private var showAddProfile = false

    var body: some View {
        Form {
            Section {
                activeProfileRow
                profileManagementRow
            }

            destinationSection([
                .profile,
                .profileKeys,
                .notifications,
                .appearance,
                .privacyAndSecurity,
                .dataUsage,
                .relays,
                .aiAgents,
            ])

            destinationSection([.support, .donate, .developerTools])

            Section {
                Button {
                    appState.showSignOut = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .disabled(appState.activeAccount == nil || appState.isAccountExitInProgress)
                .accessibilityIdentifier("settings.signOut")
            } footer: {
                Text("White Noise · \(appVersion)")
                    .frame(maxWidth: .infinity)
            }
        }
        .productScreen(.settings)
        .localizedNavigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.activeAccount?.accountIdHex) {
            guard let id = appState.activeAccount?.accountIdHex else { return }
            await appState.reloadProfileProjection(forAccountIdHex: id)
        }
        .sheet(isPresented: $showAccounts) {
            NavigationStack {
                AccountsView(showsCloseButton: true)
            }
            .appAppearance()
        }
        .sheet(isPresented: $showAddProfile) {
            AddProfileSheet()
        }
        .onChange(of: appState.activeAccountRef) { oldValue, newValue in
            if oldValue != nil, oldValue != newValue, !appState.appReviewDemo.isRunning {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var activeProfileRow: some View {
        if let active = appState.activeAccount {
            NavigationLink {
                ShareAndConnectView(accountIdHex: active.accountIdHex)
            } label: {
                HStack(spacing: 12) {
                    AccountIdentitySummary(account: active, avatarSize: 56)
                    Spacer()
                    Image(systemName: "qrcode")
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(
                L10n.formatted(
                    "Open Share and Connect for %@",
                    appState.displayName(forAccountIdHex: active.accountIdHex)
                )
            )
        }
    }

    @ViewBuilder
    private var profileManagementRow: some View {
        if inactiveAccounts.isEmpty {
            Button {
                showAddProfile = true
            } label: {
                Label("Add Profile", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else if inactiveAccounts.count == 1, let alternate = inactiveAccounts.first {
            Button {
                showAccounts = true
            } label: {
                HStack(spacing: 12) {
                    AccountIdentitySummary(account: alternate, avatarSize: 56)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                showAccounts = true
            } label: {
                HStack {
                    AccountAvatarStack(accounts: inactiveAccounts)
                    Text("Switch Profile")
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func destinationSection(_ destinations: [SettingsDestination]) -> some View {
        Section {
            ForEach(destinations, id: \.self) { destination in
                NavigationLink {
                    destinationView(destination)
                } label: {
                    Label(destination.title, systemImage: destination.symbol)
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("settings.\(destination.rawValue)")
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .profile: ProfileEditView()
        case .profileKeys: IdentityView()
        case .notifications: NotificationSettingsView()
        case .appearance: AppearanceSettingsView()
        case .privacyAndSecurity: PrivacySecuritySettingsView()
        case .dataUsage: DataAndStorageView()
        case .relays: RelaysView()
        case .aiAgents: AIAgentsSettingsView()
        case .support: SupportChatView()
        case .donate:
            DonateView()
        case .developerTools: DeveloperToolsSettingsView()
        }
    }

    private var inactiveAccounts: [AccountSummaryFfi] {
        AccountsView.switcherAccounts(appState.accounts, activeAccountRef: appState.activeAccountRef)
            .filter { $0.label != appState.activeAccountRef }
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

}

struct AccountIdentitySummary: View {
    @Environment(AppState.self) private var appState
    let account: AccountSummaryFfi
    let avatarSize: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: account.accountIdHex,
                title: appState.displayName(forAccountIdHex: account.accountIdHex),
                pictureURL: appState.avatarURL(forAccountIdHex: account.accountIdHex)
            )
            .frame(width: avatarSize, height: avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.displayName(forAccountIdHex: account.accountIdHex))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(appState.shortNpub(forAccountIdHex: account.accountIdHex))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AccountAvatarStack: View {
    @Environment(AppState.self) private var appState
    let accounts: [AccountSummaryFfi]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(accounts.prefix(3), id: \.label) { account in
                AvatarBubble(
                    seed: account.accountIdHex,
                    title: appState.displayName(forAccountIdHex: account.accountIdHex),
                    pictureURL: appState.avatarURL(forAccountIdHex: account.accountIdHex)
                )
                .frame(width: 32, height: 32)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                .overlay {
                    Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2)
                }
            }

            if accounts.count > 3 {
                Text("+\(accounts.count - 3)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 32, height: 32)
                    .background(Color(uiColor: .systemGray5), in: Circle())
                    .overlay {
                        Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

nonisolated enum MarmotKitBuildLabel {
    static func text(tag: String, sha: String) -> String {
        let isSourceBuild = sha.hasSuffix("-dirty")
        let shortHash = sha
            .replacingOccurrences(of: "-dirty", with: "")
            .prefix(8)

        if !isSourceBuild, let version = version(from: tag) {
            return "MarmotKit v\(version) (\(shortHash))"
        }
        return "MarmotKit (\(shortHash))"
    }

    private static func version(from tag: String) -> Substring? {
        let prefix = "marmotkit-v"
        guard tag.hasPrefix(prefix) else { return nil }
        let version = tag.dropFirst(prefix.count)
        return version.isEmpty ? nil : version
    }
}
