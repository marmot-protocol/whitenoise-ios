import MarmotKit

/// Pure swipe-action policy for chat-list rows (#345). Inactive memberships
/// (`left` / `removed`) keep archive controls but swap leave for local delete.
/// Order is part of the policy: the first entry sits nearest the swiped edge
/// and is what a full swipe triggers.
nonisolated enum ChatListSwipeActionsPresentation {
    static func leadingActions(_ hints: ChatListRowActionsFfi) -> [ChatListSwipeAction] {
        var actions: [ChatListSwipeAction] = []
        if hints.canMarkRead { actions.append(.read) }
        if hints.canMarkUnread { actions.append(.unread) }
        if hints.canPin { actions.append(.pin) }
        if hints.canUnpin { actions.append(.unpin) }
        return actions
    }

    static func trailingActions(_ hints: ChatListRowActionsFfi, isMuted: Bool) -> [ChatListSwipeAction] {
        var actions: [ChatListSwipeAction] = []
        if hints.canRestore { actions.append(.unarchive) }
        // iOS notification mode is device-local; MDK supplies availability.
        if hints.canMute || hints.canUnmute { actions.append(isMuted ? .unmute : .mute) }
        if hints.canStartLeave { actions.append(.leave) }
        if hints.canDeleteLocal { actions.append(.delete) }
        if hints.canArchive { actions.append(.archive) }
        return actions
    }

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
