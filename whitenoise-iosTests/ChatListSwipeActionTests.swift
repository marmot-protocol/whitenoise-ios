import MarmotKit
import SwiftUI
import Testing
import UIKit

@testable import whitenoise_ios

struct ChatListSwipeActionTests {
    @Test func everyActionResolvesItsSymbol() {
        for action in ChatListSwipeAction.allCases {
            #expect(
                UIImage(systemName: action.systemImage) != nil,
                "\(action.rawValue) has no SF Symbol named \(action.systemImage)"
            )
        }
    }

    /// The glyph is the whole control, so the title is the only name VoiceOver
    /// can read. Archive and unarchive share a glyph, which makes distinct
    /// titles load-bearing rather than cosmetic.
    @Test func everyActionHasADistinctNonEmptyTitle() {
        var seen: Set<String> = []
        for action in ChatListSwipeAction.allCases {
            let title = action.title
            #expect(!title.isEmpty, "\(action.rawValue) has an empty title")
            #expect(seen.insert(title).inserted, "\(action.rawValue) reuses the title \(title)")
        }
    }

    @Test func tintsGroupOppositeActionsTogether() {
        #expect(ChatListSwipeAction.read.tint == ChatListSwipeAction.unread.tint)
        #expect(ChatListSwipeAction.pin.tint == ChatListSwipeAction.unpin.tint)
        #expect(ChatListSwipeAction.mute.tint == ChatListSwipeAction.unmute.tint)
        #expect(ChatListSwipeAction.archive.tint == ChatListSwipeAction.unarchive.tint)
        #expect(ChatListSwipeAction.leave.tint == ChatListSwipeAction.delete.tint)
        #expect(ChatListSwipeAction.archive.tint != ChatListSwipeAction.delete.tint)
        #expect(ChatListSwipeAction.read.tint != ChatListSwipeAction.pin.tint)
    }

    // MARK: - Departure status and action

    private static let memberships: [SelfMembershipFfi] = [.member, .left, .removed]

    /// The regression this section exists to pin. Marmot derives
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

    // MARK: - Membership actions

    @Test func activeMemberShowsLeaveAndArchive() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.leave))
        #expect(actions.contains(.archive))
        #expect(!actions.contains(.delete))
        #expect(!actions.contains(.unarchive))
    }

    @Test func archivedActiveMemberShowsUnarchiveAndLeave() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: true,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.unarchive))
        #expect(actions.contains(.leave))
        #expect(!actions.contains(.delete))
        #expect(!actions.contains(.archive))
    }

    @Test func archivedInactiveMemberShowsUnarchiveAndDelete() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: true,
            selfMembership: .left,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.unarchive))
        #expect(actions.contains(.delete))
        #expect(!actions.contains(.leave))
        #expect(!actions.contains(.archive))
    }

    // MARK: - Mute and read/pin actions

    @Test func unmutedRowOffersMuteOnly() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.mute))
        #expect(!actions.contains(.unmute))
    }

    @Test func mutedRowOffersUnmuteOnly() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: true
        )
        #expect(actions.contains(.unmute))
        #expect(!actions.contains(.mute))
    }

    @Test func leadingSwipeOffersReadAndUnpinForUnreadPinnedRows() {
        let actions = ChatListSwipeActionsPresentation.leadingActions(
            hasUnread: true,
            isPinned: true,
            isArchived: false
        )
        #expect(actions.contains(.read))
        #expect(!actions.contains(.unread))
        #expect(actions.contains(.unpin))
        #expect(!actions.contains(.pin))
    }

    @Test func leadingSwipeOffersUnreadAndPinForReadUnpinnedRows() {
        let actions = ChatListSwipeActionsPresentation.leadingActions(
            hasUnread: false,
            isPinned: false,
            isArchived: false
        )
        #expect(actions.contains(.unread))
        #expect(!actions.contains(.read))
        #expect(actions.contains(.pin))
        #expect(!actions.contains(.unpin))
    }

    /// A muted member with a leave outstanding keeps only archiving: the mute
    /// toggle is withheld along with both destructive actions.
    @Test func pendingLeaveOffersOnlyArchiveControl() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .member,
            leaveRequestPending: true,
            isMuted: true
        )
        #expect(actions == [.archive])
    }

    @Test func archivedRowsKeepReadControlButDoNotOfferPinning() {
        let actions = ChatListSwipeActionsPresentation.leadingActions(
            hasUnread: false,
            isPinned: false,
            isArchived: true
        )
        #expect(actions == [.unread])
    }

    // MARK: - Bulk selection

    @Test func projectedActionsControlGestures() {
        let hints = PresentedChatRowFfi.testActions(unpin: true, mute: true, restore: true, delete: true)
        #expect(ChatListSwipeActionsPresentation.leadingActions(hints) == [.unpin])
        #expect(ChatListSwipeActionsPresentation.trailingActions(hints, isMuted: false) == [.unarchive, .mute, .delete])
        #expect(ChatListSwipeActionsPresentation.trailingActions(hints, isMuted: true) == [.unarchive, .unmute, .delete])
        let pending = PresentedChatRowFfi.testActions(archive: true)
        #expect(ChatListSwipeActionsPresentation.leadingActions(pending).isEmpty)
        #expect(ChatListSwipeActionsPresentation.trailingActions(pending, isMuted: false) == [.archive])
    }

    @Test func bulkLocalDeleteRequiresEverySelectedMembershipToBeInactive() {
        #expect(!ChatListSelection.canDeleteLocally([]))
        #expect(ChatListSelection.canDeleteLocally([.deleteLocally]))
        #expect(ChatListSelection.canDeleteLocally([.deleteLocally, .deleteLocally]))
        #expect(!ChatListSelection.canDeleteLocally([.leave]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, .leave]))
        #expect(!ChatListSelection.canDeleteLocally([nil]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, nil]))
    }
}

struct ChatListSwipeActionOrderTests {
    @Test func leadingPutsReadStateBeforePinning() {
        #expect(
            ChatListSwipeActionsPresentation.leadingActions(
                hasUnread: true,
                isPinned: false,
                isArchived: false
            ) == [.read, .pin]
        )
        #expect(
            ChatListSwipeActionsPresentation.leadingActions(
                hasUnread: false,
                isPinned: false,
                isArchived: false
            ) == [.unread, .pin]
        )
        #expect(
            ChatListSwipeActionsPresentation.leadingActions(
                hasUnread: true,
                isPinned: true,
                isArchived: false
            ) == [.read, .unpin]
        )
    }

    @Test func archivedRowsDropPinningAndKeepReadState() {
        #expect(
            ChatListSwipeActionsPresentation.leadingActions(
                hasUnread: true,
                isPinned: false,
                isArchived: true
            ) == [.read]
        )
        #expect(
            ChatListSwipeActionsPresentation.leadingActions(
                hasUnread: false,
                isPinned: true,
                isArchived: true
            ) == [.unread]
        )
    }

    /// The leading edge's first action is what a full swipe triggers, so read
    /// state must stay ahead of pinning regardless of the other flags.
    @Test func leadingFullSwipeAlwaysTogglesReadState() {
        for hasUnread in [true, false] {
            for isPinned in [true, false] {
                for isArchived in [true, false] {
                    let first = ChatListSwipeActionsPresentation.leadingActions(
                        hasUnread: hasUnread,
                        isPinned: isPinned,
                        isArchived: isArchived
                    ).first
                    #expect(first == (hasUnread ? .read : .unread))
                }
            }
        }
    }

    @Test func trailingKeepsMuteNearestTheEdgeForActiveMembers() {
        #expect(
            ChatListSwipeActionsPresentation.trailingActions(
                isArchived: false,
                selfMembership: .member,
                leaveRequestPending: false,
                isMuted: false
            ) == [.mute, .leave, .archive]
        )
        #expect(
            ChatListSwipeActionsPresentation.trailingActions(
                isArchived: false,
                selfMembership: .member,
                leaveRequestPending: false,
                isMuted: true
            ) == [.unmute, .leave, .archive]
        )
    }

    @Test func trailingSwapsLeaveForDeleteOnInactiveMemberships() {
        for membership in [SelfMembershipFfi.left, .removed] {
            #expect(
                ChatListSwipeActionsPresentation.trailingActions(
                    isArchived: false,
                    selfMembership: membership,
                    leaveRequestPending: false,
                    isMuted: false
                ) == [.delete, .archive]
            )
        }
    }

    @Test func archivedTrailingLeadsWithUnarchive() {
        #expect(
            ChatListSwipeActionsPresentation.trailingActions(
                isArchived: true,
                selfMembership: .member,
                leaveRequestPending: false,
                isMuted: false
            ) == [.unarchive, .leave]
        )
        #expect(
            ChatListSwipeActionsPresentation.trailingActions(
                isArchived: true,
                selfMembership: .left,
                leaveRequestPending: false,
                isMuted: false
            ) == [.unarchive, .delete]
        )
    }

    /// The outstanding commit withholds only a *second* leave. A membership
    /// that has already ended is on the wire, so its local copy stays
    /// droppable — gating that is what stranded departed chats (#983).
    @Test func endedMembershipKeepsDeleteWhileALeaveCommitIsPending() {
        for membership in [SelfMembershipFfi.left, .removed] {
            #expect(
                ChatListSwipeActionsPresentation.trailingActions(
                    isArchived: false,
                    selfMembership: membership,
                    leaveRequestPending: true,
                    isMuted: false
                ) == [.delete, .archive]
            )
            #expect(
                ChatListSwipeActionsPresentation.trailingActions(
                    isArchived: true,
                    selfMembership: membership,
                    leaveRequestPending: true,
                    isMuted: false
                ) == [.unarchive, .delete]
            )
        }
    }

    /// Still a member with a leave outstanding: neither destructive action is
    /// honest yet, so only archiving is offered.
    @Test func pendingLeaveOffersOnlyArchiving() {
        #expect(
            ChatListSwipeActionsPresentation.trailingActions(
                isArchived: false,
                selfMembership: .member,
                leaveRequestPending: true,
                isMuted: false
            ) == [.archive]
        )
        #expect(
            ChatListSwipeActionsPresentation.trailingActions(
                isArchived: true,
                selfMembership: .member,
                leaveRequestPending: true,
                isMuted: false
            ) == [.unarchive]
        )
    }

    /// Archive and unarchive are mutually exclusive because they share a
    /// glyph; showing both at once would give a row two identical buttons.
    @Test func archiveAndUnarchiveNeverAppearTogether() {
        for isArchived in [true, false] {
            for membership in [SelfMembershipFfi.member, .left, .removed] {
                for pending in [true, false] {
                    for muted in [true, false] {
                        let actions = ChatListSwipeActionsPresentation.trailingActions(
                            isArchived: isArchived,
                            selfMembership: membership,
                            leaveRequestPending: pending,
                            isMuted: muted
                        )
                        #expect(!(actions.contains(.archive) && actions.contains(.unarchive)))
                        #expect(!(actions.contains(.leave) && actions.contains(.delete)))
                        #expect(!(actions.contains(.mute) && actions.contains(.unmute)))
                        #expect(Set(actions).count == actions.count)
                    }
                }
            }
        }
    }
}

@MainActor
struct WNSwipeActionBadgeTests {
    private static let diameter: CGFloat = 40
    private static let displayScale: CGFloat = 2

    private func badge(for action: ChatListSwipeAction) -> UIImage? {
        WNSwipeActionBadge.image(
            systemImage: action.systemImage,
            tint: action.tint,
            diameter: Self.diameter,
            colorScheme: .light,
            displayScale: Self.displayScale
        )
    }

    /// UIKit repaints a template image flat white, which would erase the tint
    /// the circle exists to carry.
    @Test func everyActionRendersAnUntemplatedBadgeAtTheRequestedSize() throws {
        for action in ChatListSwipeAction.allCases {
            let image = try #require(badge(for: action), "\(action.rawValue) rendered no badge")
            #expect(abs(image.size.width - Self.diameter) < 1)
            #expect(abs(image.size.height - Self.diameter) < 1)
            #expect(image.renderingMode == .alwaysOriginal)
        }
    }

    /// The whole point of the iOS 18 path: a corner outside the circle stays
    /// clear while the middle is filled, which a square fill would not do.
    @Test func badgeIsACircleAndNotAFilledSquare() throws {
        for action in ChatListSwipeAction.allCases {
            let image = try #require(badge(for: action))
            let cg = try #require(image.cgImage)
            let corner = try #require(Self.alpha(of: cg, atX: 0, y: 0))
            let centre = try #require(
                Self.alpha(of: cg, atX: cg.width / 2, y: cg.height / 2)
            )
            #expect(corner < 32, "\(action.rawValue) painted its corner (alpha \(corner))")
            #expect(centre > 224, "\(action.rawValue) left its middle unpainted")
        }
    }

    /// The fallback glyph is still a template image, which UIKit repaints flat
    /// white, so a slot left at the row background would hide it in light mode.
    @Test func aMissingBadgeMovesTheTintOntoTheSlot() {
        for action in ChatListSwipeAction.allCases {
            let slot = WNSwipeActionBadge.slotTint(tint: action.tint, hasBadge: false)
            #expect(slot == action.tint, "\(action.rawValue) left its slot unpainted")
            #expect(slot != Color(.systemBackground))
        }
    }

    /// The rendered badge carries its own circle, so the slot behind it has to
    /// disappear into the row.
    @Test func aRenderedBadgeKeepsTheSlotAtTheRowBackground() {
        for action in ChatListSwipeAction.allCases {
            #expect(
                WNSwipeActionBadge.slotTint(tint: action.tint, hasBadge: true)
                    == Color(.systemBackground)
            )
        }
    }

    @Test func badgesAreCachedRatherThanReRenderedPerSwipeFrame() throws {
        let first = try #require(badge(for: .archive))
        let second = try #require(badge(for: .archive))
        #expect(first === second)
    }

    @Test func lightAndDarkRendersAreKeptApart() throws {
        let light = try #require(
            WNSwipeActionBadge.image(
                systemImage: ChatListSwipeAction.mute.systemImage,
                tint: ChatListSwipeAction.mute.tint,
                diameter: Self.diameter,
                colorScheme: .light,
                displayScale: Self.displayScale
            )
        )
        let dark = try #require(
            WNSwipeActionBadge.image(
                systemImage: ChatListSwipeAction.mute.systemImage,
                tint: ChatListSwipeAction.mute.tint,
                diameter: Self.diameter,
                colorScheme: .dark,
                displayScale: Self.displayScale
            )
        )
        #expect(light !== dark)
    }

    /// The cache outlives any one window, so a render made for another screen
    /// would otherwise be handed back at the wrong pixel density.
    @Test func rendersAtDifferentDisplayScalesAreKeptApart() throws {
        let twoX = try #require(badge(at: 2))
        let threeX = try #require(badge(at: 3))
        #expect(twoX !== threeX)
    }

    /// Keying on the scale is only half the fix: it also has to reach the
    /// renderer, or every entry holds the same pixels under a different key.
    @Test func theRequestedScaleDrivesThePixelsThatAreRendered() throws {
        for scale in [CGFloat(2), CGFloat(3)] {
            let image = try #require(badge(at: scale))
            let cg = try #require(image.cgImage)
            #expect(abs(image.scale - scale) < 0.01)
            #expect(abs(CGFloat(cg.width) - Self.diameter * scale) < scale)
        }
    }

    private func badge(at displayScale: CGFloat) -> UIImage? {
        WNSwipeActionBadge.image(
            systemImage: ChatListSwipeAction.pin.systemImage,
            tint: ChatListSwipeAction.pin.tint,
            diameter: Self.diameter,
            colorScheme: .light,
            displayScale: displayScale
        )
    }

    private static func alpha(of image: CGImage, atX x: Int, y: Int) -> UInt8? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            image,
            in: CGRect(x: -x, y: -y, width: image.width, height: image.height)
        )
        return pixel[3]
    }
}
