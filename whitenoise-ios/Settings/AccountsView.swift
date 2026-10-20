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
        _selectedDetent = State(initialValue: signedInAccountCount >= 4 ? .large : .medium)
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
                            await appState.activateAccount(account.label)
                            if appState.activeAccountRef == account.label {
                                if returnsToSettings { appState.openSettingsAfterProfileSelection = true }
                                if showsCloseButton { dismiss() }
                            }
                        }
                    } label: {
                        AccountSummaryRow(account: account, usesCompactLayout: true)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color(uiColor: .tertiarySystemFill))
                    .disabled(appState.isAccountExitInProgress)
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
        .productScreen(.settings, section: .account)
        .localizedNavigationTitle(requiresSelection ? "Choose a profile" : "Switch Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
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
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled(requiresSelection)
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

struct SignedOutProfilesView: View {
    @Environment(AppState.self) private var appState
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Choose a profile")
                            .font(.title2.weight(.bold))
                        Text("Choose a signed-in profile, or add a new one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .listRowBackground(Color.clear)
                }

                Section("Profiles") {
                    ForEach(appState.accounts.filter { !$0.signedOut }, id: \.label) { account in
                        Button {
                            Task {
                                let returnsToSettings = appState.accountStore.returnsToSettingsAfterSelection
                                await appState.activateAccount(account.label)
                                if appState.activeAccountRef == account.label, returnsToSettings {
                                    appState.openSettingsAfterProfileSelection = true
                                }
                            }
                        } label: {
                            AccountSummaryRow(account: account)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isAccountExitInProgress)
                    }
                }

                Section {
                    WNButton(
                        title: "Add Profile",
                        systemImage: "person.crop.circle.badge.plus"
                    ) {
                        showAdd = true
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .localizedNavigationTitle("White Noise")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await appState.refreshAccountUnreadSummaries() }
        .sheet(isPresented: $showAdd) {
            AddProfileSheet()
        }
        .onChange(of: appState.accounts.filter { !$0.signedOut }.count) { _, _ in
            if showAdd { showAdd = false }
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
