import MarmotKit

/// The one departure-related status a chat row reports, or `nil` for an
/// ordinary active chat.
///
/// Marmot derives `leaveRequestPending` from its `cgka_leave_requests` table at
/// read time: it turns true when the SelfRemove publishes and clears only once a
/// remaining member commits that removal, which for a group whose others never
/// come back online is never. `leaveGroup` meanwhile records `.left` locally
/// right away, so the durable post-leave state is `.left` *and* still pending.
/// Reading the flag first pinned every departed chat to a progress badge; the
/// settled membership is the fact worth reporting, and the outstanding commit
/// stays the protocol detail it is.
nonisolated enum ChatDepartureStatus: Equatable {
    /// A leave the group has not seen yet. Genuinely transient.
    case leaving
    /// The account left or was removed. Terminal.
    case membershipEnded(SelfMembershipFfi)
    case pendingInvite

    /// An ended membership also supersedes a pending invite, so a row shows one
    /// badge rather than a contradictory "Invite" + "Removed" pair.
    static func status(
        membership: SelfMembershipFfi,
        leaveRequestPending: Bool,
        pendingConfirmation: Bool
    ) -> ChatDepartureStatus? {
        guard GroupManagementPresentation.isActiveChatListMember(membership) else {
            return .membershipEnded(membership)
        }
        if leaveRequestPending { return .leaving }
        return pendingConfirmation ? .pendingInvite : nil
    }
}

/// The destructive action a chat surface may offer. The two are mutually
/// exclusive: a chat you can still leave is not one you may silently drop from
/// this device, because deleting a live membership strands every later message
/// the group sends with nothing on the wire to say so.
nonisolated enum ChatDepartureAction: Equatable {
    case leave
    case deleteLocally

    /// `leaveRequestPending` only ever withholds a *second* leave; it never
    /// withholds the local delete. Once membership has ended the departure is
    /// already on the wire and the local copy is the user's to drop — gating
    /// that on the pending commit is what stranded departed chats.
    static func action(
        membership: SelfMembershipFfi,
        leaveRequestPending: Bool
    ) -> ChatDepartureAction? {
        guard GroupManagementPresentation.isActiveChatListMember(membership) else {
            return .deleteLocally
        }
        // Still a member with a request outstanding: the SelfRemove has not
        // reached the group, so neither action is honest yet.
        return leaveRequestPending ? nil : .leave
    }
}
