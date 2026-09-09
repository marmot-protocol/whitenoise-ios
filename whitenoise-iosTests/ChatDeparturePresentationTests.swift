import MarmotKit
import Testing

@testable import whitenoise_ios

struct ChatDeparturePresentationTests {
    private static let memberships: [SelfMembershipFfi] = [.member, .left, .removed]

    /// The regression this suite exists to pin. Marmot derives
    /// `leaveRequestPending` from an uncommitted leave request, so it stays true
    /// until a remaining member commits the removal — for a quiet group, never.
    /// Reading it ahead of membership parked departed chats on a "Leaving…"
    /// badge they could never escape.
    @Test func departedChatReportsTheSettledMembershipRatherThanAnUnresolvedLeave() {
        #expect(
            ChatDepartureStatus.status(
                membership: .left,
                leaveRequestPending: true,
                pendingConfirmation: false
            ) == .membershipEnded(.left)
        )
        #expect(
            ChatDepartureStatus.status(
                membership: .removed,
                leaveRequestPending: true,
                pendingConfirmation: false
            ) == .membershipEnded(.removed)
        )
    }

    @Test func stillAMemberWithAnOutstandingRequestReportsTheLeaveInFlight() {
        #expect(
            ChatDepartureStatus.status(
                membership: .member,
                leaveRequestPending: true,
                pendingConfirmation: false
            ) == .leaving
        )
    }

    @Test func anEndedMembershipSupersedesAPendingInvite() {
        #expect(
            ChatDepartureStatus.status(
                membership: .removed,
                leaveRequestPending: true,
                pendingConfirmation: true
            ) == .membershipEnded(.removed)
        )
        #expect(
            ChatDepartureStatus.status(
                membership: .member,
                leaveRequestPending: false,
                pendingConfirmation: true
            ) == .pendingInvite
        )
        #expect(
            ChatDepartureStatus.status(
                membership: .member,
                leaveRequestPending: false,
                pendingConfirmation: false
            ) == nil
        )
    }

    /// The other half of the stranding: withholding the local delete left a
    /// departed chat with a badge and no action that could clear it.
    @Test func departedChatOffersLocalDeleteEvenWithAnUnresolvedLeaveRequest() {
        for membership in [SelfMembershipFfi.left, .removed] {
            for pending in [false, true] {
                #expect(
                    ChatDepartureAction.action(
                        membership: membership,
                        leaveRequestPending: pending
                    ) == .deleteLocally,
                    "\(membership) with pending=\(pending) must still offer the local delete"
                )
            }
        }
    }

    @Test func pendingLeaveSuppressesTheLeaveOnlyWhileStillAMember() {
        #expect(
            ChatDepartureAction.action(membership: .member, leaveRequestPending: true) == nil
        )
        #expect(
            ChatDepartureAction.action(membership: .member, leaveRequestPending: false) == .leave
        )
    }

    /// Badge and menu are two readings of one state: no chat may show a leave in
    /// progress while offering a destructive action, and none may sit on
    /// `.leaving` with no way out.
    @Test func onlyTheLeavingStateWithholdsEveryDestructiveAction() {
        for membership in Self.memberships {
            for pending in [false, true] {
                for invited in [false, true] {
                    let status = ChatDepartureStatus.status(
                        membership: membership,
                        leaveRequestPending: pending,
                        pendingConfirmation: invited
                    )
                    let action = ChatDepartureAction.action(
                        membership: membership,
                        leaveRequestPending: pending
                    )
                    #expect(
                        (status == .leaving) == (action == nil),
                        "\(membership)/pending=\(pending): a stuck badge needs an action, and vice versa"
                    )
                }
            }
        }
    }

    @Test func departedChatSwipeAlwaysOffersDeleteDespiteAnUnresolvedLeave() {
        for isArchived in [false, true] {
            let actions = ChatListSwipeActionsPresentation.trailingActions(
                isArchived: isArchived,
                selfMembership: .left,
                leaveRequestPending: true,
                isMuted: false
            )
            #expect(actions.contains(.delete), "archived=\(isArchived) must offer the local delete")
            #expect(!actions.contains(.leave))
            #expect(actions.contains(isArchived ? .unarchive : .archive))
        }
    }

    @Test func memberWithLeaveInFlightOffersOnlyArchiveControls() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .member,
            leaveRequestPending: true,
            isMuted: false
        )
        #expect(actions == [.archive])
    }
}
