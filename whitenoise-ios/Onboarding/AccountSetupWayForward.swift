import Foundation
import MarmotKit

/// Keeps every blocking setup state actionable. Setup never renders MDK's
/// `reconnectSigner` (sign-in imports a key; there is no external signer to
/// reconnect) or `editFollows` (setup never publishes a follow list), so a sheet
/// whose step offers nothing else falls back to Cancel Sign-In.
nonisolated enum AccountSetupWayForward {
    /// The Follows sheet renders only Try Again, Back and Continue.
    static func followsNeedsCancelSignIn(_ actions: [OnboardingActionFfi]) -> Bool {
        !actions.contains { $0 == .retry || $0 == .cancelRepair || $0 == .continueWithout }
    }

    /// MDK's run returns once a step needs attention, so a finished run that leaves
    /// the current step waiting or checking needs another run to continue.
    static func needsCheckAgain(
        _ snapshot: OnboardingSnapshotFfi, isBusy: Bool, isConnected: Bool, hasFailure: Bool, isCancelled: Bool
    ) -> Bool {
        guard isConnected, !isBusy, !hasFailure, !isCancelled, !snapshot.ready, !snapshot.cancellationPending,
              let step = snapshot.steps.first(where: { $0.status != .passed && $0.status != .skipped })
        else { return false }
        return step.status == .pending || step.status == .checking
    }

    static var checkAgainHeader: (title: String, subtitle: String) {
        (L10n.string("Checks didn’t finish"), L10n.string("Check again to continue signing in."))
    }
}
