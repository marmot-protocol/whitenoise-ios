import SwiftUI
import MarmotKit

nonisolated enum AccountExitIntent: Hashable {
    case signOut
    case deleteProfile
}

struct SignOutView: View {
    let intent: AccountExitIntent
    @Environment(AppState.self) private var appState
    @State private var shouldWipeData = false
    @State private var confirmation = ""
    @State private var isBusy = false
    @State private var profileRef: String?
    @State private var profileName = ""
    @State private var error: String?

    private var isWiping: Bool { intent == .deleteProfile || shouldWipeData }

    var body: some View {
        SignOutForm(
            intent: intent,
            shouldWipeData: $shouldWipeData,
            confirmation: $confirmation,
            profileName: profileName,
            isBusy: isBusy,
            canSignOut: canSignOut,
            error: error,
            onClose: { appState.accountExitIntent = nil },
            onSignOut: signOut
        ) {
            profileSummaryRow
        }
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
            }
        }
    }

    private var canSignOut: Bool {
        profileRef != nil
            && profileRef == appState.activeAccountRef
            && !appState.isAccountExitInProgress
            && ProfileExitConfirmation.canSignOut(
                wiping: isWiping,
                input: confirmation,
                profileName: profileName,
                busy: isBusy
            )
    }

    @ViewBuilder
    private var profileSummaryRow: some View {
        if let active = appState.activeAccount, active.label == profileRef {
            if intent == .deleteProfile {
                ProfileIdentityHeader(
                    name: profileName,
                    npub: appState.npub(forAccountIdHex: active.accountIdHex),
                    publicKeyUsesFilledStyle: true
                ) { size in
                    AvatarBubble(
                        seed: active.accountIdHex,
                        title: profileName,
                        pictureURL: appState.avatarURL(forAccountIdHex: active.accountIdHex)
                    )
                    .frame(width: size, height: size)
                }
            } else {
                AccountIdentitySummary(account: active, avatarSize: 48)
            }
        } else {
            Text(profileName).font(.headline)
        }
    }

    private func showError(_ failure: Toast) {
        error = failure.message.map { "\(failure.title)\n\($0)" } ?? failure.title
    }

    private func signOut() {
        guard canSignOut else { return }
        let wiping = isWiping
        isBusy = true
        error = nil
        Task {
            let success: Bool
            if wiping {
                success = await appState.signOutAndWipeActiveAccount(onError: showError)
            } else {
                success = await appState.signOut(onError: showError)
            }
            if success {
                appState.accountExitIntent = nil
            } else {
                isBusy = false
                if error == nil {
                    error = wiping
                        ? L10n.string("Couldn't wipe profile")
                        : L10n.string("Couldn’t sign out. Try again.")
                }
            }
        }
    }
}
