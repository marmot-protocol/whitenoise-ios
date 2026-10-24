import Foundation
import Observation

nonisolated enum ChatListLeavePresentation {
    struct Target: Equatable {
        let groupIdHex: String
        let title: String
    }

    static func confirmationTitle(for target: Target) -> String {
        L10n.formatted("Leave “%@”?", target.title)
    }

    static var confirmationMessage: String {
        L10n.string(
            "You'll stop receiving new messages. This chat will remain on this device as read-only history until you delete it."
        )
    }

    static var failureTitle: String {
        L10n.string("Couldn't leave chat")
    }

    static var failureMessage: String {
        L10n.string("Try again.")
    }

    /// The note after a bulk leave with no failures, for chats where the user chose
    /// Wait. The per-chat copy holds only when every selected chat waited.
    static func bulkWaitNotice(waitMessage: String?, waitedCount: Int, targetCount: Int) -> String? {
        guard let waitMessage, waitedCount > 0 else { return nil }
        return waitedCount < targetCount ? L10n.string("Some chats weren't left. Try them again later.") : waitMessage
    }
}

@MainActor
@Observable
final class ChatListLeaveActionState {
    private(set) var pendingConfirmation: ChatListLeavePresentation.Target?
    private(set) var preparingGroupIds = Set<String>()
    private(set) var leavingGroupIds = Set<String>()

    func beginPreparation(for target: ChatListLeavePresentation.Target) -> Bool {
        guard !isBusy(groupIdHex: target.groupIdHex),
              pendingConfirmation == nil,
              preparingGroupIds.isEmpty
        else { return false }
        preparingGroupIds.insert(target.groupIdHex)
        return true
    }

    func finishPreparation(
        for target: ChatListLeavePresentation.Target,
        canPresentConfirmation: Bool
    ) {
        guard preparingGroupIds.remove(target.groupIdHex) != nil else { return }
        if canPresentConfirmation {
            pendingConfirmation = target
        }
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    func beginConfirmedLeave(for target: ChatListLeavePresentation.Target) -> Bool {
        guard pendingConfirmation == target,
              !isBusy(groupIdHex: target.groupIdHex)
        else { return false }
        pendingConfirmation = nil
        leavingGroupIds.insert(target.groupIdHex)
        return true
    }

    func finishLeave(groupIdHex: String) {
        leavingGroupIds.remove(groupIdHex)
    }

    func isBusy(groupIdHex: String) -> Bool {
        preparingGroupIds.contains(groupIdHex) || leavingGroupIds.contains(groupIdHex)
    }
}
