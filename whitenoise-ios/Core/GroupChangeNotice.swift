import Foundation
import MarmotKit

enum GroupChangeNotice {
    static func toast(for event: MarmotEventFfi) -> Toast? {
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
}
