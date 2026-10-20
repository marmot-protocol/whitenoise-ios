import SwiftUI
import MarmotKit

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var initiallyActiveAccountRef: String?
    @State private var selectedDetent: PresentationDetent
    let showsCloseButton: Bool
    let requiresSelection: Bool
    let onAddProfile: () -> Void

    init(
        activeAccountRef: String?,
        signedInAccountCount: Int,
        showsCloseButton: Bool = false,
        requiresSelection: Bool = false,
        onAddProfile: @escaping () -> Void
    ) {
        _initiallyActiveAccountRef = State(initialValue: activeAccountRef)
        _selectedDetent = State(initialValue: requiresSelection || signedInAccountCount >= 4 ? .large : .medium)
        self.showsCloseButton = showsCloseButton
        self.requiresSelection = requiresSelection
        self.onAddProfile = onAddProfile
    }

    var body: some View {
        List {
            Section {
                ForEach(orderedAccounts, id: \.label) { account in
                    Button {
                        Task {
                            let returnsToSettings = requiresSelection
                                && appState.accountStore.returnsToSettingsAfterSelection
                            await appState.activateAccount(account.label)
                            guard appState.activeAccountRef == account.label else { return }
                            if returnsToSettings {
                                appState.openSettingsAfterProfileSelection = true
                            }
                            if showsCloseButton, !requiresSelection { dismiss() }
                        }
                    } label: {
                        AccountSummaryRow(account: account, usesCompactLayout: true)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color(uiColor: .tertiarySystemFill))
                    .disabled(appState.isAccountExitInProgress)
                }
            } header: {
                if requiresSelection {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose a profile")
                            .font(.title.bold())
                            .foregroundStyle(Color(uiColor: .label))
                        Text("You’ve signed out of your previous profile. Choose another profile to continue, or tap Add Profile to sign in or create a new account.")
                            .font(.body)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textCase(nil)
                    .padding(.vertical, 16)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .modifier(WNOnboardingActionBar {
            WNButton(
                title: "Add Profile",
                systemImage: "person.crop.circle.badge.plus",
                action: onAddProfile
            )
            .padding()
        })
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .productScreen(.settings, section: .account, isEnabled: !requiresSelection)
        .localizedNavigationTitle("Switch Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton, !requiresSelection {
                ToolbarItem(placement: .cancellationAction) {
                    WNIconButton(
                        title: "Close",
                        systemImage: "xmark",
                        chrome: .container
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .task { await appState.refreshAccountUnreadSummaries() }
        .presentationDetents(requiresSelection ? [.large] : [.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(requiresSelection ? .hidden : .visible)
        .interactiveDismissDisabled(requiresSelection)
        .presentationContentInteraction(.resizes)
    }

    private var orderedAccounts: [AccountSummaryFfi] {
        // Reorder on the next presentation, not while the selected row dismisses.
        Self.switcherAccounts(appState.accounts, activeAccountRef: initiallyActiveAccountRef)
    }

    static func switcherAccounts(
        _ accounts: [AccountSummaryFfi],
        activeAccountRef: String?
    ) -> [AccountSummaryFfi] {
        let signedIn = accounts.filter { !$0.signedOut }
        return signedIn.filter { $0.label == activeAccountRef }
            + signedIn.filter { $0.label != activeAccountRef }
    }

    /// The unread count a Profiles row shows for an account, or `nil` when the
    /// badge should be hidden — no summary yet, or nothing unread.
    static func unreadBadgeCount(for summary: AccountUnreadFfi?) -> UInt64? {
        guard let summary, summary.hasUnread else { return nil }
        return max(summary.unreadCount, 1)
    }
}

struct AccountSummaryRow: View {
    /// What the row marks at its trailing edge, beyond any unread count. Being
    /// the active profile outranks the signed-out and read-only markers.
    nonisolated enum Status: Equatable {
        case active
        case signedOut
        case readOnly
        case unmarked

        static func resolve(
            isActive: Bool,
            signedOut: Bool,
            localSigning: Bool
        ) -> Status {
            if isActive { return .active }
            if signedOut { return .signedOut }
            if !localSigning { return .readOnly }
            return .unmarked
        }
    }

    @Environment(AppState.self) private var appState
    let account: AccountSummaryFfi
    var usesCompactLayout = false

    var body: some View {
        HStack(spacing: usesCompactLayout ? nil : 12) {
            AccountIdentitySummary(account: account, avatarSize: 48, spacing: usesCompactLayout ? nil : 12)
            Spacer()
            HStack(spacing: 8) {
                if appState.accountUnreadIsUnavailable(forAccountIdHex: account.accountIdHex) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.string("Unread count unavailable"))
                } else if let unreadCount = appState.accountUnreadBadgeCount(
                    forAccountIdHex: account.accountIdHex
                ) {
                    UnreadCountBadge(count: unreadCount)
                }
                status
            }
        }
        .padding(.vertical, usesCompactLayout ? 0 : 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var status: some View {
        switch Status.resolve(
            isActive: account.label == appState.activeAccountRef,
            signedOut: account.signedOut,
            localSigning: account.localSigning
        ) {
        case .active:
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .accessibilityLabel(L10n.string("Current profile"))
        case .signedOut:
            WNBadge(text: L10n.string("Signed out"), emphasis: .neutral)
        case .readOnly:
            WNBadge(text: L10n.string("Read-only"), emphasis: .neutral)
        case .unmarked:
            EmptyView()
        }
    }

    static func unreadBadgeCount(for summary: AccountUnreadFfi?) -> UInt64? {
        AccountsView.unreadBadgeCount(for: summary)
    }
}

/// Settings stays behind the required switcher until a profile is activated.
struct SignedOutProfilesView: View {
    @Environment(AppState.self) private var appState
    let canPresentProfiles: Bool
    @State private var chatsViewModel: ChatsListViewModel
    @State private var showProfiles = false
    @State private var showAdd = false

    init(appState: AppState, canPresentProfiles: Bool) {
        self.canPresentProfiles = canPresentProfiles
        // The disabled Settings backdrop needs a model, but never binds its chat list.
        _chatsViewModel = State(initialValue: ChatsListViewModel(appState: appState))
    }

    var body: some View {
        NavigationStack {
            SettingsView(
                chatsViewModel: chatsViewModel,
                onAddProfile: { showAdd = true },
                recordsScreenView: false
            )
            .disabled(true)
        }
        .onChange(of: canPresentProfiles, initial: true) { _, canPresent in
            showProfiles = canPresent
        }
        .sheet(isPresented: $showProfiles) {
            NavigationStack {
                AccountsView(
                    activeAccountRef: nil,
                    signedInAccountCount: appState.accounts.filter { !$0.signedOut }.count,
                    requiresSelection: true,
                    onAddProfile: { showAdd = true }
                )
            }
            .appAppearance()
            .sheet(isPresented: $showAdd) {
                AddProfileSheet()
            }
        }
    }
}

struct AddProfileSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var content = OnboardingSheetContent.welcome
    @State private var selectedDetent = PresentationDetent.large
    var onCompletion: (() -> Void)?

    var body: some View {
        NavigationStack {
            WelcomeView(
                isAddingProfile: true,
                onSheetContentChange: { content in
                    self.content = content
                    selectedDetent = content.prefersCompactHeight ? .medium : .large
                },
                onSignInExpansionChange: { isExpanded in
                    selectedDetent = isExpanded ? .large : .medium
                },
                onChatsOpened: {
                    if let onCompletion { onCompletion() } else { dismiss() }
                }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WNButton(
                        title: "Cancel",
                        emphasis: .secondary,
                        size: .compact
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .appAppearance()
        .presentationDetents(supportedDetents, selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        // Sign Up pushes into this sheet, so iPad needs room for its form.
        .presentationSizing(.page)
        .onAppear { appState.diagnosticsConsent.onboardingVisible = true }
        .onDisappear {
            appState.diagnosticsConsent.onboardingVisible = false
            content = .welcome
            selectedDetent = .large
        }
    }

    private var supportedDetents: Set<PresentationDetent> {
        content.prefersCompactHeight ? [.medium, .large] : [.large]
    }
}
