import SwiftUI
import MarmotKit

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    let showsCloseButton: Bool

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        List {
            Section {
                ForEach(orderedAccounts, id: \.label) { account in
                    Button {
                        Task {
                            await appState.activateAccount(account.label)
                            if appState.activeAccountRef == account.label, showsCloseButton {
                                dismiss()
                            }
                        }
                    } label: {
                        AccountSummaryRow(account: account)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isAccountExitInProgress)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WNButton(
                title: "Add Profile",
                systemImage: "person.crop.circle.badge.plus"
            ) {
                showAdd = true
            }
            .padding()
            .background(.bar)
        }
        .localizedNavigationTitle("Switch Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    WNIconButton(title: "Close", systemImage: "xmark") {
                        dismiss()
                    }
                }
            }
        }
        .task { await appState.refreshAccountUnreadSummaries() }
        .sheet(isPresented: $showAdd) {
            AddProfileSheet()
        }
        // Close the add-account sheet as soon as a new identity lands, so the
        // user returns straight to the (updated) accounts list rather than
        // being left on the creation flow.
        .onChange(of: appState.accounts.count) { _, _ in
            if showAdd { showAdd = false }
        }
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDetents(accountSheetDetents)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
    }

    private var accountSheetDetents: Set<PresentationDetent> {
        Self.prefersFullHeight(accountCount: appState.accounts.count)
            ? [.large]
            : [.medium, .large]
    }

    private var orderedAccounts: [AccountSummaryFfi] {
        guard let activeAccountRef = appState.activeAccountRef else {
            return appState.accounts
        }
        return appState.accounts.filter { $0.label == activeAccountRef }
            + appState.accounts.filter { $0.label != activeAccountRef }
    }

    /// The unread count a Profiles row shows for an account, or `nil` when the
    /// badge should be hidden — no summary yet, or nothing unread.
    static func unreadBadgeCount(for summary: AccountUnreadFfi?) -> UInt64? {
        guard let summary, summary.hasUnread else { return nil }
        return max(summary.unreadCount, 1)
    }

    static func prefersFullHeight(accountCount: Int) -> Bool {
        accountCount >= 3
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

    var body: some View {
        HStack(spacing: 12) {
            AccountIdentitySummary(account: account, avatarSize: 48)
            Spacer()
            HStack(spacing: 8) {
                if let unreadCount = appState.accountUnreadBadgeCount(
                    forAccountIdHex: account.accountIdHex
                ) {
                    UnreadCountBadge(count: unreadCount)
                }
                status
            }
        }
        .padding(.vertical, 4)
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
        .onChange(of: appState.accounts.count) { _, _ in
            if showAdd { showAdd = false }
        }
    }
}

struct AddProfileSheet: View {
    @Environment(AppState.self) private var appState
    @State private var content = OnboardingSheetContent.welcome
    @State private var selectedDetent = PresentationDetent.large

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
                }
            )
        }
        .appAppearance()
        .presentationDetents(supportedDetents, selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
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
