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

    private func badge(for action: ChatListSwipeAction) -> UIImage? {
        WNSwipeActionBadge.image(
            systemImage: action.systemImage,
            tint: action.tint,
            diameter: Self.diameter,
            colorScheme: .light
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
                colorScheme: .light
            )
        )
        let dark = try #require(
            WNSwipeActionBadge.image(
                systemImage: ChatListSwipeAction.mute.systemImage,
                tint: ChatListSwipeAction.mute.tint,
                diameter: Self.diameter,
                colorScheme: .dark
            )
        )
        #expect(light !== dark)
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
