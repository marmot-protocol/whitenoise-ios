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
    @State private var showSignOut = false

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
                    showSignOut = true
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
        .sheet(isPresented: $showSignOut) {
            SignOutView()
                .appAppearance()
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

private struct SignOutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var shouldWipeData = true
    @State private var confirmation = ""
    @State private var isBusy = false
    @State private var profileRef: String?
    @State private var profileName = ""
    @State private var error: String?
    @FocusState private var confirmationFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    profileSummaryRow
                    Toggle("Wipe Data From This Device", isOn: $shouldWipeData)
                        .disabled(isBusy)
                        .accessibilityIdentifier("sign-out.wipe-data-toggle")
                } footer: {
                    if shouldWipeData {
                        Text("This profile and all local data will be permanently removed. Signing in again won’t restore previous chats. You’ll need a new invitation to each chat.")
                    } else {
                        Text("This profile and its local data will stay on this device.")
                    }
                }

                if shouldWipeData {
                    Section {
                        TextField("Profile name", text: $confirmation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($confirmationFocused)
                            .disabled(isBusy)
                            .accessibilityIdentifier("wipe-profile.confirmation-field")
                    } header: {
                        Text("Enter Profile Name").wnSectionHeader()
                    } footer: {
                        Text(confirmationHint)
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.orange)
                }

                Section {
                    Button(role: .destructive, action: signOut) {
                        Text("Sign Out")
                            .font(.body.weight(.regular))
                            .frame(maxWidth: .infinity)
                            .opacity(isBusy ? 0 : 1)
                            .overlay {
                                if isBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                            }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .disabled(!isBusy && !canSignOut)
                    .allowsHitTesting(!isBusy)
                    .accessibilityLabel(busyTitle)
                    .accessibilityIdentifier(shouldWipeData ? "wipe-profile.confirm" : "sign-out.keep-data")
                }
            }
            .navigationTitle("Sign Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .disabled(isBusy)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            guard profileRef == nil else { return }
            profileRef = appState.activeAccountRef
            if let account = appState.activeAccount {
                profileName = appState.displayName(forAccountIdHex: account.accountIdHex)
            }
        }
        .onChange(of: shouldWipeData) { _, wiping in
            error = nil
            if !wiping {
                confirmation = ""
                confirmationFocused = false
            }
        }
    }

    private var canSignOut: Bool {
        profileRef != nil
            && profileRef == appState.activeAccountRef
            && !appState.isAccountExitInProgress
            && ProfileExitConfirmation.canSignOut(
                wiping: shouldWipeData,
                input: confirmation,
                profileName: profileName,
                busy: isBusy
            )
    }

    private var confirmationHint: AttributedString {
        // Style the argument, even when a profile name also occurs in the surrounding copy.
        let placeholder = "\u{FFFC}"
        var hint = AttributedString(L10n.formatted("Enter %@ exactly to confirm.", placeholder))
        hint.foregroundColor = .secondary
        if let range = hint.range(of: placeholder) {
            var name = AttributedString(profileName)
            name.foregroundColor = Color(uiColor: .label)
            hint.replaceSubrange(range, with: name)
        }
        return hint
    }

    /// Keep the action label in the hierarchy while showing its spinner.
    private var busyTitle: LocalizedStringKey {
        guard isBusy else { return "Sign Out" }
        return shouldWipeData ? "Signing out and wiping data…" : "Signing out…"
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
        guard canSignOut else { return }
        confirmationFocused = false
        let wiping = shouldWipeData
        isBusy = true
        error = nil
        Task {
            let success: Bool
            if wiping {
                success = await appState.signOutAndWipeActiveAccount()
            } else {
                success = await appState.signOut()
            }
            if success {
                dismiss()
            } else {
                isBusy = false
                error = wiping
                    ? L10n.string("Couldn't wipe profile")
                    : L10n.string("Couldn’t sign out. Try again.")
            }
        }
    }
}
