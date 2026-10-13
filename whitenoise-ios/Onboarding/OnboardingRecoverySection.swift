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
    @State private var failure: (accountID: String, action: Action)?

    let isPushed: Bool
    @Binding var isWorking: Bool
    let onSignIn: (String?) -> Void

    var body: some View {
        GeometryReader { geometry in
            // Match the prototype Form’s 20-point horizontal content margins.
            recoveryContent(avatarDiameter: max(0, geometry.size.width - 40) / 3)
        }
    }

    private func recoveryContent(avatarDiameter: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset setup to sign in again")
                        .font(.title.bold())
                    Group {
                        if appState.onboardingRecoveryAccounts.count > 1 {
                            Text("We couldn’t restore these profiles’ saved sign-in setup. Choose Recover Setup for the profile you want to use, then sign in again with its private key.")
                        } else {
                            Text("We couldn’t restore this profile’s saved sign-in setup. Choose Recover Setup below, then sign in again with its private key.")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                ForEach(appState.onboardingRecoveryAccounts, id: \.accountIdHex) { account in
                    recoveryCard(account, avatarDiameter: avatarDiameter)
                }
            }
            .safeAreaPadding(.horizontal, 16)
            .safeAreaPadding(.vertical, 24)
        }
        .modifier(WNOnboardingActionBar {
            WNOnboardingButton(title: "Sign In with Another Account") {
                onSignIn(nil)
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
                Text("This removes the profile and its saved private key from this device. It does not remove anything already published to relays. Keep a copy of your private key if you want to sign in again. Local message history cannot be restored by signing in again.")
            } else {
                Text("This signs the profile out and resets its setup. You’ll need its private key to sign in again.\n\nOnly the latest recovery record is kept. Nothing on relays changes.")
            }
        }
    }

    private func recoveryCard(_ account: AccountSummaryFfi, avatarDiameter: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            recoveryIdentity(account, avatarDiameter: avatarDiameter)

            VStack(spacing: 8) {
                WNButton(
                    title: "Recover Setup",
                    emphasis: .secondary,
                    isLoading: operation == .recover && selected?.accountIdHex == account.accountIdHex
                ) { confirm(.recover, account: account) }
                .disabled(operation != nil)

                actionError(.recover, accountID: account.accountIdHex)

                Button(role: .destructive) { confirm(.remove, account: account) } label: {
                    ZStack {
                        Text("Remove Profile from This Device")
                            .opacity(operation == .remove && selected?.accountIdHex == account.accountIdHex ? 0 : 1)
                        if operation == .remove && selected?.accountIdHex == account.accountIdHex {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.red)
                        }
                    }
                    .foregroundStyle(operation == nil ? .red : .secondary)
                    .wnButtonLabelSizing(.large)
                }
                .wnSecondaryButtonStyle()
                .wnButtonChrome(emphasis: .secondary)
                .controlSize(.extraLarge)
                .wnButtonSizing()
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
        let profile = appState.cachedProfile(forAccountIdHex: account.accountIdHex)
        let name = IdentityPresentation.text(
            accountIdHex: account.accountIdHex,
            knownName: AppState.resolvedKnownDisplayName(profile: profile, projectedName: nil, localAccountLabel: nil)
        )
        let npub = IdentityPresentation.canonicalNpub(accountIdHex: account.accountIdHex)
        return ProfileIdentityHeader(
            name: name,
            npub: npub,
            nostrAddress: ContentSanitizer.profileAddress(profile?.nip05),
            publicKeyUsesFilledStyle: true,
            avatarDiameter: avatarDiameter
        ) { size in
            AvatarBubble(
                seed: npub ?? account.accountIdHex,
                title: name,
                pictureURL: ContentSanitizer.imageURL(profile?.picture),
                monogramFont: .subheadline.weight(.semibold)
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
        operation = action
        isWorking = true
        failure = nil
        Task {
            defer { operation = nil; isWorking = false }
            do {
                switch action {
                case .recover:
                    try await appState.recoverOnboardingSetup(accountID: account.accountIdHex)
                    onSignIn(L10n.string("Setup recovered. Enter this profile’s private key to begin a new sign-in."))
                case .remove:
                    try await appState.removeOnboardingRecoveryAccount(account)
                    if appState.onboardingRecoveryAccounts.isEmpty {
                        onSignIn(L10n.string("Profile removed from this device."))
                    }
                }
            } catch {
                failure = (account.accountIdHex, action)
            }
        }
    }
}
