import SwiftUI
import MarmotKit

struct OnboardingRecoverySection: View {
    @Environment(AppState.self) private var appState
    @State private var selected: AccountSummaryFfi?
    @State private var isConfirming = false
    @State private var isRecovering = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(appState.onboardingRecoveryAccounts, id: \.accountIdHex) { account in
                VStack(alignment: .leading) {
                    Text("This profile’s saved sign-in setup needs recovery.")
                    Text(account.accountIdHex).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Recover Sign-In Setup") {
                        selected = account
                        isConfirming = true
                    }
                    .disabled(isRecovering)
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .task(id: appState.runtimeGeneration) { try? await appState.refreshAccounts(refreshUnreadSummaries: false) }
        .alert("Recover Sign-In Setup?", isPresented: $isConfirming) {
            Button("Recover Setup", role: .destructive) {
                guard let selected else { return }
                isRecovering = true
                Task {
                    defer { isRecovering = false }
                    do {
                        try await appState.recoverOnboardingSetup(accountID: selected.accountIdHex)
                        message = L10n.string("Setup recovered. Enter this profile’s private key to begin a new sign-in.")
                    } catch {
                        message = L10n.string("Couldn’t recover setup. Try again.")
                    }
                }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text("Recovery signs this profile out and replaces its unreadable setup checkpoint. Only the latest recovery evidence is retained. It does not undo earlier relay publications. You will need the private key to start a new sign-in; no publication is approved by this action.")
        }
        .interactiveDismissDisabled(isRecovering)
    }
}

extension AppState {
    func recoverOnboardingSetup(accountID: String) async throws {
        let lease = try await runtimeLifecycle.beginUserInitiatedForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        guard try await lease.client.onboardingRecoveryRequired(accountRef: accountID) else {
            throw MarmotKitError.OnboardingActionUnavailable
        }
        if let model = pendingAccountSetup, model.accountID == accountID {
            model.suspend()
            await model.drain()
        }
        _ = try await lease.client.recoverOnboarding(accountRef: accountID)
        signInAttempts.finish(accountID)
        try await refreshAccounts(refreshUnreadSummaries: false)
    }
}
