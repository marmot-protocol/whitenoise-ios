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
            Button {
                showAdd = true
            } label: {
                Label("Add Profile", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .wnPrimaryButtonStyle()
            .controlSize(.extraLarge)
            .padding()
            .background(.bar)
        }
        .localizedNavigationTitle("Switch Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
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
                } else if !account.localSigning {
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
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Profile", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
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
