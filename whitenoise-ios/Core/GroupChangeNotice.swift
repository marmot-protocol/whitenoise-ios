import Foundation
import MarmotKit

enum GroupChangeNotice {
    static func toast(for event: MarmotEventFfi) -> Toast? {
        if case .groupEvent(_, _, _, .queuedIntentRefused(_, let intentKind, let reason)) = event {
            return refusedIntentToast(intentKind: intentKind, reason: reason)
        }
        guard case .groupChangeSuperseded(_, _, _, _, let kind, let outcome, _) = event,
              outcome != "reissued" else { return nil }

        let message: String
        switch outcome {
        case "already_satisfied":
            message = L10n.string("Another group update replaced your change. Check the current chat details.")
        case "not_member":
            message = L10n.string("A group change could not be kept because you are no longer a member of that chat.")
        default:
            switch kind {
            case "invite":
                message = L10n.string("A group invitation was superseded. Check the chat members before inviting again.")
            case "remove_members":
                message = L10n.string("A member removal was superseded. Check the chat members before trying again.")
            default:
                message = L10n.string("A group update was superseded. Check the current chat details before trying again.")
            }
        }
        return .warning(L10n.string("Review group changes"), message: message, duration: 6)
    }

    /// A send that waited for the group to settle and was then dropped unsent:
    /// the settled state refused it and nothing retries it. `reason` is MDK's
    /// stable tag; any other detail stays out of the toast.
    static func refusedIntentToast(intentKind: String, reason: String) -> Toast {
        let title: String
        switch intentKind {
        case "invite":
            title = L10n.string("Invitation not sent")
        case "remove_members":
            title = L10n.string("Member not removed")
        case "update_group_data", "update_app_components":
            title = L10n.string("Group details not updated")
        case "leave":
            title = L10n.string("Couldn't leave group")
        case "disband", "enable_disbanding":
            title = L10n.string("Couldn't end the group")
        case "app_message":
            title = L10n.string("Message not sent")
        default:
            title = L10n.string("Group change not made")
        }
        let message: String
        switch reason {
        case "not_group_admin":
            message = L10n.string("You're no longer an admin of this group.")
        case "not_a_member":
            message = L10n.string("You're no longer a member of this group.")
        default:
            message = L10n.string("The group changed while this was waiting to send. Check the chat, then try again.")
        }
        return .warning(title, message: message, duration: 6)
    }
}

/// MDK may deliver the same refusal more than once; announce each dropped
/// send once. Bounded, so a long session cannot grow it without limit.
struct RefusedIntentAnnouncements {
    private var seen: [String] = []
    private let capacity = 64

    /// Whether `event` is a refusal not announced before; records it if so.
    mutating func admit(_ event: MarmotEventFfi) -> Bool {
        guard case .groupEvent(_, _, _, .queuedIntentRefused(let intentIdHex, _, _)) = event else { return true }
        guard !seen.contains(intentIdHex) else { return false }
        seen.append(intentIdHex)
        if seen.count > capacity { seen.removeFirst(seen.count - capacity) }
        return true
    }
}
