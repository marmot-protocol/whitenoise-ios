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
    // Nil only for the disabled Settings background while a profile is being chosen.
    var chatsViewModel: ChatsListViewModel? = nil

    @Environment(AppState.self) private var appState
    @State private var showDeleteProfile = false
    @State private var showAccounts = false
    @State private var addProfileAfterSwitcherCloses = false
    let onAddProfile: () -> Void
    @State private var supportEntry = SupportChatEntryModel()
    @State private var supportRequestID: UUID?

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
                    showDeleteProfile = true
                } label: {
                    Label("Delete Profile", systemImage: "trash")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .disabled(appState.activeAccount == nil || appState.isAccountExitInProgress)
                .accessibilityIdentifier("settings.deleteProfile")

                Button {
                    appState.accountExitIntent = .signOut
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
        .navigationDestination(isPresented: $showDeleteProfile) {
            SignOutView(intent: .deleteProfile) {
                showDeleteProfile = false
            }
        }
        .productScreen(.settings)
        .localizedNavigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.activeAccount?.accountIdHex) {
            guard chatsViewModel != nil, let id = appState.activeAccount?.accountIdHex else { return }
            await appState.reloadProfileProjection(forAccountIdHex: id)
        }
        .task(id: supportRequestID) {
            guard supportRequestID != nil, let chatsViewModel else { return }
            await supportEntry.prepare(using: appState) { groupIdHex in
                if chatsViewModel.item(groupIdHex: groupIdHex) == nil {
                    await chatsViewModel.refreshRow(groupIdHex: groupIdHex)
                }
                chatsViewModel.retainDestination(groupIdHex: groupIdHex)
            }
        }
        .onDisappear { supportRequestID = nil }
        .navigationDestination(item: $supportEntry.destination) { destination in
            if let chatsViewModel {
                SupportChatView(chatsViewModel: chatsViewModel, initialTarget: destination.chatTarget)
            }
        }
        .onChange(of: supportEntry.destination) { previous, _ in
            previous?.chatTarget?.performance?.finish(.cancelled, recorder: appState.productAnalytics)
        }
        .alert(SupportChatPresentation.failureTitle, isPresented: $supportEntry.showsFailure) {
            Button("Try Again") { supportRequestID = UUID() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(SupportChatPresentation.failureMessage)
        }
        .sheet(isPresented: $showAccounts, onDismiss: {
            guard addProfileAfterSwitcherCloses else { return }
            addProfileAfterSwitcherCloses = false
            onAddProfile()
        }) {
            NavigationStack {
                AccountsView(
                    activeAccountRef: appState.activeAccountRef,
                    signedInAccountCount: appState.accounts.filter { !$0.signedOut }.count,
                    showsCloseButton: true,
                    onAddProfile: {
                        addProfileAfterSwitcherCloses = true
                        showAccounts = false
                    }
                )
            }
            .appAppearance()
        }
        .onChange(of: appState.activeAccountRef) { _, _ in
            showDeleteProfile = false
        }
    }

    @ViewBuilder
    private var activeProfileRow: some View {
        if let active = appState.activeAccount {
            NavigationLink {
                ShareAndConnectView(accountIdHex: active.accountIdHex)
            } label: {
                HStack {
                    AccountIdentitySummary(account: active, avatarSize: 56, spacing: nil)
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
                onAddProfile()
            } label: {
                Label("Add Profile", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
        } else if inactiveAccounts.count == 1, let alternate = inactiveAccounts.first {
            Button {
                showAccounts = true
            } label: {
                HStack {
                    AvatarBubble(
                        seed: alternate.accountIdHex,
                        title: appState.displayName(forAccountIdHex: alternate.accountIdHex),
                        pictureURL: appState.avatarURL(forAccountIdHex: alternate.accountIdHex)
                    )
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                    Text(appState.displayName(forAccountIdHex: alternate.accountIdHex))
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
            .accessibilityValue(appState.shortNpub(forAccountIdHex: alternate.accountIdHex))
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
        }
    }

    private func destinationSection(_ destinations: [SettingsDestination]) -> some View {
        Section {
            ForEach(destinations, id: \.self) { destination in
                Group {
                    if destination == .support {
                        supportRow
                    } else {
                        NavigationLink {
                            destinationView(destination)
                        } label: {
                            Label(destination.title, systemImage: destination.symbol)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .accessibilityIdentifier("settings.\(destination.rawValue)")
            }
        }
    }

    private var supportRow: some View {
        Button {
            supportRequestID = UUID()
        } label: {
            HStack {
                Label("Chat with support", systemImage: "message")
                    .foregroundStyle(.primary)
                Spacer()
                if supportEntry.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(supportEntry.isLoading)
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
        case .support: EmptyView() // Support resolves its destination before pushing.
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
    var spacing: CGFloat? = 12

    var body: some View {
        HStack(spacing: spacing) {
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
