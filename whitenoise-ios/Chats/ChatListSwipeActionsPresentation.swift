import MarmotKit

/// Pure swipe-action policy for chat-list rows (#345). Inactive memberships
/// (`left` / `removed`) keep archive controls but swap leave for local delete.
/// Order is part of the policy: the first entry sits nearest the swiped edge
/// and is what a full swipe triggers.
nonisolated enum ChatListSwipeActionsPresentation {
    static func leadingActions(
        hasUnread: Bool,
        isPinned: Bool,
        isArchived: Bool
    ) -> [ChatListSwipeAction] {
        var actions: [ChatListSwipeAction] = [hasUnread ? .read : .unread]
        if !isArchived {
            actions.append(isPinned ? .unpin : .pin)
        }
        return actions
    }

    static func trailingActions(
        isArchived: Bool,
        selfMembership: SelfMembershipFfi,
        leaveRequestPending: Bool,
        isMuted: Bool
    ) -> [ChatListSwipeAction] {
        let departureAction = ChatDepartureAction.action(
            membership: selfMembership,
            leaveRequestPending: leaveRequestPending
        )
        // No honest destructive action: the SelfRemove is out but the group has
        // not committed it, so a second leave is rejected and dropping the local
        // copy while still a member would strand the conversation.
        guard let departureAction else {
            return isArchived ? [.unarchive] : [.archive]
        }

        if isArchived {
            return [.unarchive, departureAction == .leave ? .leave : .delete]
        }

        var actions: [ChatListSwipeAction] = []
        if departureAction == .leave {
            actions.append(isMuted ? .unmute : .mute)
            actions.append(.leave)
        } else {
            actions.append(.delete)
        }
        actions.append(.archive)
        return actions
    }
}
