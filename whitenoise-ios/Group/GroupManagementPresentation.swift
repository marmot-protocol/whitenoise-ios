import Foundation
import MarmotKit

nonisolated enum GroupMemberManagementAction: Equatable {
    case remove
    case promote
    case demote
    case selfDemote
}

nonisolated enum GroupDisbandStatus: Equatable {
    case none
    case pending
    case failed(DisbandFailureReasonFfi)
    case disbanded
}

nonisolated enum GroupManagementPresentation {
    static let inactiveGroupComposerMessage = L10n.string("This group is inactive. You can't send new messages.")
    static let leftGroupComposerMessage = L10n.string("You left the group")
    static let leavingGroupComposerMessage = L10n.string("Leaving group…")
    static let disbandingComposerMessage = L10n.string("This group is ending. New messages are disabled.")
    static let disbandedComposerMessage = L10n.string("This group has ended. New messages are disabled.")
    static let disbandConfirmationMessage = L10n.string(
        "Everyone will be removed and the group will be permanently disbanded. No one will be able to send new messages. This can't be undone."
    )

    static func isActiveChatListMember(_ membership: SelfMembershipFfi) -> Bool {
        membership == .member
    }

    static func memberActions(
        for action: GroupMemberActionStateFfi,
        state: GroupManagementStateFfi?
    ) -> [GroupMemberManagementAction] {
        var actions: [GroupMemberManagementAction] = []
        if action.canPromote { actions.append(.promote) }
        if action.canDemote { actions.append(.demote) }
        if action.isSelf, canSelfDemote(state: state) { actions.append(.selfDemote) }
        if action.canRemove { actions.append(.remove) }
        return actions
    }

    static func canInvite(state: GroupManagementStateFfi?, fallbackIsAdmin: Bool) -> Bool {
        state?.canInvite ?? fallbackIsAdmin
    }

    static func disbandStatus(
        group: AppGroupRecordFfi,
        state: GroupManagementStateFfi?
    ) -> GroupDisbandStatus {
        if group.disbanded || state?.lifecycleState == .disbanded {
            return .disbanded
        }
        if case .some(.failed(_, let reason)) = group.disbandRequest {
            return .failed(reason)
        }
        if case .some(.failed(_, let reason)) = state?.disbandRequest {
            return .failed(reason)
        }
        if group.disbanding || state?.disbanding == true {
            return .pending
        }
        return .none
    }

    static func canEndGroup(state: GroupManagementStateFfi?) -> Bool {
        guard let state, state.isSelfAdmin, state.lifecycleState != .disbanded,
              !state.disbanding
        else { return false }
        return state.canDisband || state.canEnableDisbanding
    }

    static func shouldShowEndGroup(state: GroupManagementStateFfi?) -> Bool {
        guard let state else { return false }
        return state.isSelfAdmin
            && state.lifecycleState != .disbanded
            && !state.disbanding
            && state.disbandRequest == nil
    }

    static func disbandBlockerMessage(state: GroupManagementStateFfi?) -> String? {
        guard let state, state.isSelfAdmin, !canEndGroup(state: state),
              !state.disbanding, state.lifecycleState != .disbanded,
              !state.disbandingBlockers.isEmpty
        else { return nil }
        return L10n.plural(
            "%lld members must update White Noise before you can end this group.",
            Int64(state.disbandingBlockers.count)
        )
    }

    static func disbandFailureMessage(_ reason: DisbandFailureReasonFfi) -> String {
        switch reason {
        case .noLongerAdmin:
            return L10n.string("The group wasn't ended because you're no longer an admin.")
        case .noLongerMember:
            return L10n.string("The group wasn't ended because you're no longer a member.")
        }
    }

    static func isActiveMember(
        state: GroupManagementStateFfi?,
        members: [AppGroupMemberRecordFfi],
        groupMemberDetails: [GroupMemberDetailsFfi],
        myAccountId: String?,
        fallbackSelfMembership: SelfMembershipFfi = .member
    ) -> Bool {
        guard isActiveChatListMember(fallbackSelfMembership) else { return false }

        if let state {
            return state.lifecycleState != .disbanded && !state.disbanding
                && !state.leaveRequestPending && (
                state.isSelfAdmin
                || state.canLeave
                || state.requiresSelfDemoteBeforeLeave
                || state.memberActions.contains { $0.isSelf }
            )
        }

        if !groupMemberDetails.isEmpty {
            return groupMemberDetails.contains { member in
                member.isSelf || member.memberIdHex == myAccountId
            }
        }

        if !members.isEmpty {
            return members.contains { member in
                member.local || member.memberIdHex == myAccountId
            }
        }

        return true
    }

    static func canLeave(state: GroupManagementStateFfi?, fallbackIsLastAdmin: Bool) -> Bool {
        if state?.isLastAdmin == true || fallbackIsLastAdmin { return false }
        guard let state else { return !fallbackIsLastAdmin }
        guard !state.leaveRequestPending else { return false }
        return state.canLeave || shouldSelfDemoteBeforeLeave(state: state)
    }

    static func canSelfDemote(state: GroupManagementStateFfi?) -> Bool {
        guard let state else { return false }
        return state.isSelfAdmin && !state.isLastAdmin
    }

    static func shouldSelfDemoteBeforeLeave(state: GroupManagementStateFfi?) -> Bool {
        guard let state else { return false }
        return state.requiresSelfDemoteBeforeLeave && canSelfDemote(state: state)
    }

    static func leaveConfirmationMessage(state: GroupManagementStateFfi?) -> String {
        if shouldSelfDemoteBeforeLeave(state: state) {
            return L10n.string("You'll step down as admin first, then stop receiving messages from this group.")
        }
        return L10n.string("You'll stop receiving messages from this group. Other members will see a system message.")
    }

    static func leaveHelpMessage(
        state: GroupManagementStateFfi?,
        fallbackIsLastAdmin: Bool
    ) -> String {
        if BlockedLeavePresentation.isBlocked(state) {
            return BlockedLeavePresentation.title
        }
        if state?.leaveRequestPending == true {
            return leavingGroupComposerMessage
        }
        if state?.isLastAdmin == true || fallbackIsLastAdmin {
            return L10n.string("You're the only admin. Make another member an admin before you leave.")
        }
        return leaveConfirmationMessage(state: state)
    }

    static func leaveFooter(state: GroupManagementStateFfi?, fallbackIsLastAdmin: Bool) -> String? {
        if BlockedLeavePresentation.isBlocked(state) {
            return BlockedLeavePresentation.detail
        }
        if state?.leaveRequestPending == true {
            return leavingGroupComposerMessage
        }
        if state?.isLastAdmin == true || fallbackIsLastAdmin {
            return L10n.string("You're the only admin. Make another member an admin before you leave.")
        }
        if shouldSelfDemoteBeforeLeave(state: state) {
            return L10n.string("Leaving will step you down as admin first.")
        }
        return nil
    }
}

enum GroupRelaysPresentation {
    static let emptyMessage = L10n.string("No relays configured.")

    static func rows(for relays: [String]) -> [String] {
        guard !relays.isEmpty else { return [emptyMessage] }
        let sanitized = relays.compactMap { ContentSanitizer.relayDisplayLine($0, maxLength: 120) }
        return sanitized.isEmpty ? [emptyMessage] : sanitized
    }

    static func summary(for relays: [String]) -> String {
        let count = rows(for: relays).filter { $0 != emptyMessage }.count
        return count == 0
            ? emptyMessage
            : LocalizedNumberLabel.decimal(UInt64(count))
    }
}
