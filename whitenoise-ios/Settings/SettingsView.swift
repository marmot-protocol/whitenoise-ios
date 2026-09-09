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
    @State private var showAccountActions = false

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
                    showAccountActions = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(appState.activeAccount == nil)
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
        .sheet(isPresented: $showAccountActions) {
            AccountActionsSheet().appAppearance()
        }
        .onChange(of: appState.activeAccountRef) { oldValue, newValue in
            if oldValue != nil, oldValue != newValue {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var activeProfileRow: some View {
        if let active = appState.activeAccount {
            NavigationLink {
                ShareAndConnectView(accountIdHex: active.accountIdHex)
                    .wnBackButton()
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
        case .profileKeys: IdentityView().wnBackButton()
        case .notifications: NotificationSettingsView().wnBackButton()
        case .appearance: AppearanceSettingsView().wnBackButton()
        case .privacyAndSecurity: PrivacySecuritySettingsView().wnBackButton()
        case .dataUsage: DataAndStorageView().wnBackButton()
        case .relays: RelaysView().wnBackButton()
        case .aiAgents: AIAgentsSettingsView().wnBackButton()
        case .support: SupportChatView().wnBackButton()
        case .donate: DonateView().wnBackButton()
        case .developerTools: DeveloperToolsSettingsView().wnBackButton()
        }
    }

    private var inactiveAccounts: [AccountSummaryFfi] {
        appState.accounts.filter { $0.label != appState.activeAccountRef }
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

private struct AccountActionsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var shouldWipeData = true
    @State private var confirmation = ""
    @State private var isBusy = false
    @State private var profileRef: String?
    @State private var profileName = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    profileSummaryRow
                    Toggle("Wipe Data From This Device", isOn: $shouldWipeData)
                        .wnNeutralToggleTint()
                } footer: {
                    Text(shouldWipeData
                         ? "This profile and all local data will be permanently removed. Previous chats won’t return."
                         : "This profile and its local data will stay on this device.")
                }
                if shouldWipeData {
                    Section {
                        TextField("Profile name", text: $confirmation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: {
                        Text("Enter Profile Name").wnSectionHeader()
                    } footer: {
                        Text(L10n.formatted("Enter %@ exactly to confirm.", profileName))
                    }
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Section {
                    Button(role: .destructive) { signOut() } label: {
                        HStack {
                            if isBusy { ProgressView() }
                            Text(isBusy ? (shouldWipeData ? "Signing out and wiping data…" : "Signing out…") : "Sign Out")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    .disabled(!ProfileExitConfirmation.canSignOut(
                        wiping: shouldWipeData, input: confirmation, profileName: profileName,
                        busy: isBusy || appState.isAccountExitInProgress || profileRef != appState.activeAccountRef
                    ))
                }
            }
            .disabled(isBusy)
            .navigationTitle("Sign Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close").disabled(isBusy)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            profileRef = appState.activeAccountRef
            if let account = appState.activeAccount {
                profileName = appState.displayName(forAccountIdHex: account.accountIdHex)
            }
        }
    }

    @ViewBuilder
    private var profileSummaryRow: some View {
        if let active = appState.activeAccount, active.label == profileRef {
            AccountIdentitySummary(account: active, avatarSize: 48)
        } else {
            Text(profileName).font(.headline)
        }
    }

    private func signOut() {
        guard profileRef == appState.activeAccountRef,
              ProfileExitConfirmation.canSignOut(wiping: shouldWipeData, input: confirmation,
                                                profileName: profileName, busy: isBusy || appState.isAccountExitInProgress) else { return }
        isBusy = true
        error = nil
        let wiping = shouldWipeData
        Task {
            let success = wiping ? await appState.signOutAndWipeActiveAccount() : await appState.signOut()
            isBusy = false
            if success { dismiss() } else { error = L10n.string("Couldn’t sign out. Try again.") }
        }
    }
}
