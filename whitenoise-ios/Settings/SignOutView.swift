import SwiftUI
import MarmotKit

struct SignOutView: View {
    @Environment(AppState.self) private var appState
    @State private var shouldWipeData = false
    @State private var confirmation = ""
    @State private var isBusy = false
    @State private var profileRef: String?
    @State private var profileName = ""
    @State private var error: String?

    var body: some View {
        SignOutForm(
            shouldWipeData: $shouldWipeData,
            confirmation: $confirmation,
            profileName: profileName,
            isBusy: isBusy,
            canSignOut: canSignOut,
            error: error,
            onClose: { appState.showSignOut = false },
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
                wiping: shouldWipeData,
                input: confirmation,
                profileName: profileName,
                busy: isBusy
            )
    }

    @ViewBuilder
    private var profileSummaryRow: some View {
        if let active = appState.activeAccount, active.label == profileRef {
            AccountIdentitySummary(account: active, avatarSize: 48)
        } else {
            Text(profileName).font(.headline)
        }
    }

    private func showError(_ failure: Toast) {
        error = failure.message.map { "\(failure.title)\n\($0)" } ?? failure.title
    }

    private func signOut() {
        guard canSignOut else { return }
        let wiping = shouldWipeData
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
                appState.showSignOut = false
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
