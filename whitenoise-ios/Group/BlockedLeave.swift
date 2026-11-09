import Foundation
import MarmotKit

/// A pending leave MDK cannot finish because this account is the group's last
/// active admin. Chat rows keep reading it as leaving; group details and the
/// conversation explain why and offer MDK's device-local `cancelLeave`, which
/// makes the chat joined again.
nonisolated enum BlockedLeavePresentation {
    static let title = L10n.string("Can't leave: you're the only admin")
    static let detail = L10n.string(
        "Cancel leaving to keep using this chat, then make another member an admin before you leave."
    )
    static let cancelAction = L10n.string("Cancel Leaving")

    static func isBlocked(leaveRequestPending: Bool, leaveBlocked: Bool) -> Bool {
        leaveRequestPending && leaveBlocked
    }

    static func isBlocked(_ state: GroupManagementStateFfi?) -> Bool {
        guard let state else { return false }
        return isBlocked(leaveRequestPending: state.leaveRequestPending, leaveBlocked: state.leaveBlocked)
    }

    /// MDK rechecks the state when the command runs, so this only decides
    /// whether to show the action.
    static func offersCancel(_ state: GroupManagementStateFfi?) -> Bool {
        isBlocked(state) && state?.canCancelLeave == true
    }
}

/// Cancels a blocked leave and re-reads group state either way, so the screen
/// shows what MDK settled on rather than what the tap assumed.
@MainActor
enum BlockedLeaveCancellation {
    enum Outcome {
        case rejoined
        /// MDK refused with `LeaveNotBlocked`: the leave finished or stopped
        /// being blocked between the read and the tap.
        case noLongerBlocked
        case cancelled
        case failed(any Error)
    }

    static func perform(
        cancelLeave: () async throws -> Void,
        refresh: () async -> Void
    ) async -> Outcome {
        do {
            try await cancelLeave()
        } catch {
            await refresh()
            if Task.isCancelled || error is CancellationError { return .cancelled }
            if let error = error as? MarmotKitError, case .LeaveNotBlocked = error {
                return .noLongerBlocked
            }
            return .failed(error)
        }
        await refresh()
        return .rejoined
    }

    /// The toast for each outcome; `nil` when nothing should be announced.
    static func toast(for outcome: Outcome) -> Toast? {
        switch outcome {
        case .rejoined:
            return .success(L10n.string("You're still in this group"))
        case .noLongerBlocked:
            return .warning(
                L10n.string("Couldn't cancel leaving"),
                message: L10n.string("This leave is no longer blocked.")
            )
        case .cancelled:
            return nil
        case .failed(let error):
            return UserFacingError.toast(title: L10n.string("Couldn't cancel leaving"), error: error)
        }
    }
}
