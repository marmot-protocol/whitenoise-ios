import SwiftUI
import MarmotKit

struct OnboardingRecoverySection: View {
    private enum Action {
        case recover, remove
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: AccountSummaryFfi?
    @State private var confirmation: Action?
    @State private var operation: Action?
    @State private var operationIdentity: UserProfileMetadataFfi?
    @State private var operationProfiles: (recovery: [AccountSummaryFfi], ready: [AccountSummaryFfi])?
    @State private var failure: (accountID: String, action: Action)?

    let isPushed: Bool
    @Binding var isWorking: Bool
    let readyProfiles: [AccountSummaryFfi]
    let onRecovered: (AccountSummaryFfi) -> Void
    let onSignIn: (AccountSummaryFfi?, String?) -> Void

    var body: some View {
        GeometryReader { geometry in
            // Match the prototype Form’s 20-point horizontal content margins.
            recoveryContent(avatarDiameter: max(0, geometry.size.width - 40) / 3)
        }
    }

    private func recoveryContent(avatarDiameter: CGFloat) -> some View {
        let recoveryAccounts = operationProfiles?.recovery ?? appState.onboardingRecoveryAccounts
        let readyAccounts = operationProfiles?.ready ?? readyProfiles
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !recoveryAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reset setup to sign in again")
                            .font(.title.bold())
                        Group {
                            if recoveryAccounts.count > 1 {
                                Text("We couldn’t restore these profiles’ saved sign-in setup. Choose Recover Setup for the profile you want to use, then sign in again with its private key.")
                            } else {
                                Text("We couldn’t restore this profile’s saved sign-in setup. Choose Recover Setup below, then sign in again with its private key.")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(recoveryAccounts, id: \.accountIdHex) { account in
                        recoveryCard(account, avatarDiameter: avatarDiameter)
                    }
                }
                if !readyAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ready to sign in")
                            .font(.title.bold())
                        Group {
                            if readyAccounts.count == 1 {
                                Text("Sign in with this profile’s private key.")
                            } else {
                                Text("Choose a profile and sign in with its private key.")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, recoveryAccounts.isEmpty ? 0 : 8)

                    ForEach(readyAccounts, id: \.accountIdHex) { account in
                        readyCard(account)
                    }
                }
            }
            .safeAreaPadding(.horizontal, 16)
            .safeAreaPadding(.vertical, 24)
        }
        .modifier(WNOnboardingActionBar {
            WNOnboardingButton(title: "Sign In with Another Account") {
                onSignIn(nil, nil)
            }
            .disabled(operation != nil)
            .safeAreaPadding(.horizontal, 16)
            .safeAreaPadding(.bottom)
        })
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Sign-In Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WNIconButton(
                    title: isPushed ? "Back" : "Close",
                    systemImage: isPushed ? "chevron.backward" : "xmark",
                    chrome: .container
                ) { dismiss() }
                    .disabled(operation != nil)
            }
        }
        .interactiveDismissDisabled(operation != nil)
        .alert(confirmation == .remove ? L10n.string("Remove Profile from This Device?") : L10n.string("Recover Sign-In Setup?"),
               isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
               presenting: confirmation) { action in
            Button(action == .remove ? L10n.string("Remove Profile") : L10n.string("Recover Setup"), role: .destructive) {
                guard let selected else { return }
                perform(action, account: selected)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            if action == .remove {
                Text("Your saved key and local chats will be deleted. Keep your private key to sign in again. Published data stays on relays.")
            } else {
                Text("This signs the profile out and resets its setup. You’ll need its private key to sign in again.\n\nOnly the latest recovery record is kept. Nothing on relays changes.")
            }
        }
    }

    private func readyCard(_ account: AccountSummaryFfi) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingRecoveryProfileSummary(account: account)
            WNGrayButton(title: L10n.string("Sign In")) {
                onSignIn(account, L10n.string("Enter this profile’s private key to sign in."))
            }
            .disabled(operation != nil)
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: WNGroupedCardMetrics.cornerRadius))
    }

    private func recoveryCard(_ account: AccountSummaryFfi, avatarDiameter: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            recoveryIdentity(account, avatarDiameter: avatarDiameter)

            VStack(spacing: 8) {
                WNGrayButton(
                    title: L10n.string("Recover Setup"),
                    isLoading: operation == .recover && selected?.accountIdHex == account.accountIdHex
                ) { confirm(.recover, account: account) }
                .disabled(operation != nil)

                actionError(.recover, accountID: account.accountIdHex)

                WNGrayButton(
                    title: L10n.string("Remove Profile from This Device"),
                    isDestructive: true,
                    isLoading: operation == .remove && selected?.accountIdHex == account.accountIdHex
                ) { confirm(.remove, account: account) }
                .disabled(operation != nil)

                actionError(.remove, accountID: account.accountIdHex)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: WNGroupedCardMetrics.cornerRadius))
        .task(id: appState.runtimeGeneration) {
            appState.warmProfileProjection(forAccountIdHex: account.accountIdHex, refreshAfterLoad: false)
        }
    }

    @ViewBuilder private func actionError(_ action: Action, accountID: String) -> some View {
        if let failure, failure.accountID == accountID, failure.action == action {
            Text(verbatim: action == .remove
                 ? L10n.string("Couldn’t remove this profile. Try again.")
                 : L10n.string("Couldn’t recover setup. Try again."))
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.bottom, action == .recover ? 8 : 0)
        }
    }

    private func recoveryIdentity(_ account: AccountSummaryFfi, avatarDiameter: CGFloat) -> some View {
        let profile = operation != nil && selected?.accountIdHex == account.accountIdHex
            ? operationIdentity : appState.cachedProfile(forAccountIdHex: account.accountIdHex)
        let identity = IdentityPresentation.resolve(
            accountIdHex: account.accountIdHex,
            knownName: AppState.resolvedKnownDisplayName(profile: profile, projectedName: nil, localAccountLabel: nil)
        )
        let hasName = identity.source == .name
        let name = hasName ? identity.text : L10n.string("Unnamed profile")
        let npub = IdentityPresentation.canonicalNpub(accountIdHex: account.accountIdHex)
        return ProfileIdentityHeader(
            name: name,
            npub: npub,
            nostrAddress: ContentSanitizer.profileAddress(profile?.nip05),
            publicKeyUsesFilledStyle: true,
            avatarDiameter: avatarDiameter
        ) { size in
            AvatarBubble(
                seed: account.accountIdHex,
                title: name,
                pictureURL: ContentSanitizer.imageURL(profile?.picture),
                placeholderSystemImage: hasName ? nil : "person.fill"
            )
            .frame(width: size, height: size)
        }
    }

    private func confirm(_ action: Action, account: AccountSummaryFfi) {
        selected = account
        confirmation = action
    }

    private func perform(_ action: Action, account: AccountSummaryFfi) {
        guard operation == nil else { return }
        // Keep the initiating card visible while the committed action refreshes accounts.
        operationProfiles = (appState.onboardingRecoveryAccounts, readyProfiles)
        operationIdentity = appState.cachedProfile(forAccountIdHex: account.accountIdHex)
        operation = action
        isWorking = true
        failure = nil
        Task {
            defer {
                operation = nil
                operationProfiles = nil
                operationIdentity = nil
                isWorking = false
            }
            do {
                switch action {
                case .recover:
                    try await appState.recoverOnboardingSetup(accountID: account.accountIdHex)
                    onRecovered(account)
                case .remove:
                    try await appState.removeOnboardingRecoveryAccount(account)
                    if appState.onboardingRecoveryAccounts.isEmpty && readyProfiles.isEmpty {
                        onSignIn(nil, L10n.string("Profile removed from this device."))
                    }
                }
            } catch MarmotKitError.OnboardingActionUnavailable {
                try? await appState.refreshAccounts(refreshUnreadSummaries: false)
                if appState.onboardingRecoveryAccounts.isEmpty && readyProfiles.isEmpty {
                    onSignIn(nil, nil)
                } else if appState.onboardingRecoveryAccounts.contains(where: { $0.accountIdHex == account.accountIdHex }) {
                    failure = (account.accountIdHex, action)
                }
            } catch {
                failure = (account.accountIdHex, action)
            }
        }
    }
}
