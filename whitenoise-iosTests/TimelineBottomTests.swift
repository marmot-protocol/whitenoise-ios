import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct TimelineBottomTests {

    @Test func initialEntryStartsAtBottomWhenMessagesExist() {
        #expect(TimelineInitialScroll.shouldStartAtBottom(hasItems: true, didPerformInitialScroll: false))
        #expect(!TimelineInitialScroll.shouldStartAtBottom(hasItems: false, didPerformInitialScroll: false))
        #expect(!TimelineInitialScroll.shouldStartAtBottom(hasItems: true, didPerformInitialScroll: true))
    }

    @Test func initialEntryFromNotificationPrefersTargetMessage() {
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: "message-target",
            targetItemId: "msg-target",
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .target(.item(id: "msg-target", anchor: .center)))
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: nil,
            targetItemId: nil,
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .target(.latest(id: "msg-latest")))
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: "message-target",
            targetItemId: nil,
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .none)
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: true,
            targetMessageIdHex: "message-target",
            targetItemId: "msg-target",
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .none)
    }

    @Test func unreadAndLatestEntriesUseSemanticAnchors() {
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: "message-target",
            targetItemId: "unread:message-target",
            latestItemId: "msg-latest",
            unreadMessageIdHex: "message-target"
        ) == .target(.item(id: "unread:message-target", anchor: .top)))
        #expect(TimelineInitialScroll.destination(
            hasItems: true,
            didPerformInitialScroll: false,
            targetMessageIdHex: nil,
            targetItemId: nil,
            latestItemId: "msg-latest",
            unreadMessageIdHex: nil
        ) == .target(.latest(id: "msg-latest")))
    }

    @Test func initialTimelineRemainsConcealedUntilSemanticPositionSettles() {
        #expect(TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: false
        ))
        #expect(!TimelineInitialScroll.shouldConcealContent(
            hasItems: false,
            didFinishInitialPositioning: false
        ))
        #expect(!TimelineInitialScroll.shouldConcealContent(
            hasItems: true,
            didFinishInitialPositioning: true
        ))
    }

    @Test func missingInitialTargetLoadsHistoryBeforeFallingBack() {
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: nil,
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true
        ) == .ready)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: "msg:target",
            hasMoreBefore: true,
            canLoadOlder: true
        ) == .ready)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true
        ) == .loadOlder)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: false
        ) == .waitForPagination)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: false,
            canLoadOlder: false
        ) == .fallbackToBottom)
    }

    @Test func initialTargetHuntFallsBackToBottomOnceItsPageBudgetIsSpent() {
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true,
            loadedHistoryPages: TimelineInitialTargetPolicy.maximumHistoryPages - 1
        ) == .loadOlder)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: true,
            loadedHistoryPages: TimelineInitialTargetPolicy.maximumHistoryPages
        ) == .fallbackToBottom)
        #expect(TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: "target",
            targetItemId: nil,
            hasMoreBefore: true,
            canLoadOlder: false,
            loadedHistoryPages: TimelineInitialTargetPolicy.maximumHistoryPages
        ) == .fallbackToBottom)
    }

    @Test func scrollToBottomDrainsForwardPagesUpToItsCap() {
        #expect(TimelineBottom.shouldDrainNewerPage(hasMoreAfter: true, drainedPages: 0))
        #expect(TimelineBottom.shouldDrainNewerPage(
            hasMoreAfter: true,
            drainedPages: TimelineBottom.maximumScrollToBottomPageDrains - 1
        ))
        #expect(!TimelineBottom.shouldDrainNewerPage(
            hasMoreAfter: true,
            drainedPages: TimelineBottom.maximumScrollToBottomPageDrains
        ))
        #expect(!TimelineBottom.shouldDrainNewerPage(hasMoreAfter: false, drainedPages: 0))
    }

    @Test func ownSendRepinsTheViewportWhateverItWasBefore() {
        #expect(!TimelineBottom.movedAwayFromBottomAfterOwnSend(previous: true))
        #expect(!TimelineBottom.movedAwayFromBottomAfterOwnSend(previous: false))
    }

    @Test func ownSendBottomScrollIsTreatedAsUserInitiated() {
        #expect(TimelineBottomScrollReason.send.isUserInitiated)
        // Same exemption `.buttonTap` gets: an explicit send must not be
        // swallowed while initial positioning is still unfinished.
        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: true,
            didFinishPositioning: false,
            reason: .send
        ))
        // And it wins coalescing against an automatic follow-up either way round.
        let send = TimelineBottomScrollRequest(animated: false, reason: .send, targetID: "sent")
        let automatic = TimelineBottomScrollRequest(
            animated: true,
            reason: .timelineChange,
            targetID: "tail"
        )
        #expect(send.coalesced(with: automatic).reason == .send)
        #expect(automatic.coalesced(with: send).reason == .send)
    }

    @Test func semanticTargetPositioningRejectsAutomaticBottomScrolls() {
        for reason in [TimelineBottomScrollReason.timelineChange, .layoutChange] {
            #expect(TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
                hasPositionIntent: true,
                didFinishPositioning: false,
                reason: reason
            ))
        }

        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: true,
            didFinishPositioning: false,
            reason: .buttonTap
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: false,
            didFinishPositioning: false,
            reason: .timelineChange
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasPositionIntent: true,
            didFinishPositioning: true,
            reason: .timelineChange
        ))
    }

    @Test func initialPositionSettlesOnlyWhenItsSemanticTargetIsVisible() {
        let target = TimelineInitialPositionTarget.item(
            id: "unread:message-target",
            anchor: .top
        )

        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: target,
            visibleTargetIDs: ["msg:older", "msg:newer"],
            didApplyRequestedPosition: true
        ))
        #expect(TimelineInitialTargetScrollPolicy.shouldSettle(
            target: target,
            visibleTargetIDs: ["msg:older", "unread:message-target"],
            didApplyRequestedPosition: true
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: nil,
            visibleTargetIDs: ["unread:message-target"],
            didApplyRequestedPosition: true
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: .latest(id: "msg-latest"),
            visibleTargetIDs: [],
            didApplyRequestedPosition: true
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: .latest(id: "msg-latest"),
            visibleTargetIDs: ["msg:older"],
            didApplyRequestedPosition: true
        ))
        #expect(TimelineInitialTargetScrollPolicy.shouldSettle(
            target: .latest(id: "msg-latest"),
            visibleTargetIDs: ["msg-latest"],
            didApplyRequestedPosition: true
        ))
    }

    @Test func initialPositionSettlesOnlyAfterTheRequestedScrollIsApplied() {
        let target = TimelineInitialPositionTarget.item(
            id: "unread:message-target",
            anchor: .top
        )

        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: target,
            visibleTargetIDs: ["unread:message-target"],
            didApplyRequestedPosition: false
        ))
        #expect(TimelineInitialTargetScrollPolicy.shouldSettle(
            target: target,
            visibleTargetIDs: ["unread:message-target"],
            didApplyRequestedPosition: true
        ))
        #expect(!TimelineInitialTargetScrollPolicy.shouldSettle(
            target: .latest(id: "msg-latest"),
            visibleTargetIDs: ["msg-latest"],
            didApplyRequestedPosition: false
        ))
    }

    @Test func timelineVisibilityStorePublishesOnlyVisibilityEdges() {
        let visibility = TimelineVisibilityStore()

        #expect(visibility.set("message-a", isVisible: true))
        #expect(!visibility.set("message-a", isVisible: true))
        #expect(visibility.visibleRowKeys == Set(["message-a"]))
        #expect(visibility.set("message-a", isVisible: false))
        #expect(!visibility.set("message-a", isVisible: false))
        #expect(visibility.visibleRowKeys.isEmpty)
    }

    @Test func timelineTargetVisibilityStoreRetainsTheLatestScrollCallbackSnapshot() {
        let visibility = TimelineTargetVisibilityStore()

        visibility.replace(with: ["message-a", "message-b"])
        #expect(visibility.visibleTargetIDs == ["message-a", "message-b"])

        visibility.replace(with: ["message-b"])
        #expect(visibility.visibleTargetIDs == ["message-b"])
    }

    @Test func timelineVisibilityThresholdIncludesPartiallyVisibleTallRows() {
        let onePointOfTallRow = 1.0 / 400.0

        #expect(TimelineViewportVisibility.minimumVisibleFraction <= onePointOfTallRow)
        #expect(TimelineViewportVisibility.minimumVisibleFraction < 0.5)
    }

    @Test func unreadDividerAppearsOnlyBeforePersistedFirstUnreadMessage() {
        let unreadId = hex("71")
        let unread = TimelineItem.message(message(id: unreadId, kind: MessageSemantics.kindChat))
        let other = TimelineItem.message(message(id: hex("72"), kind: MessageSemantics.kindChat))

        #expect(TimelineUnreadDivider.shouldShow(
            before: unread,
            firstUnreadMessageIdHex: unreadId
        ))
        #expect(!TimelineUnreadDivider.shouldShow(
            before: other,
            firstUnreadMessageIdHex: unreadId
        ))
        #expect(!TimelineUnreadDivider.shouldShow(
            before: unread,
            firstUnreadMessageIdHex: nil
        ))
    }

    @Test func bottomStateAllowsSmallLayoutDrift() {
        #expect(TimelineBottom.isPinned(bottomY: 1030, viewportBottomY: 1000))
    }

    @Test func bottomStateDetectsScrolledUpHistory() {
        #expect(!TimelineBottom.isPinned(bottomY: 1090, viewportBottomY: 1000))
    }

    @Test func scrollToBottomButtonAppearsOnlyAwayFromBottom() {
        #expect(!TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: 12))
        #expect(!TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: TimelineBottom.pinnedThreshold))
        #expect(TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: 90))
    }

    @Test func bottomDistanceAccountsForScrollContentInset() {
        let distance = TimelineBottom.distanceToBottom(
            contentHeight: 1_000,
            visibleBottomY: 1_000,
            bottomContentInset: 50
        )

        #expect(distance == 50)
        #expect(TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: distance))

        let insetAdjustedBottom = TimelineBottom.distanceToBottom(
            contentHeight: 1_000,
            visibleBottomY: 1_050,
            bottomContentInset: 50
        )
        #expect(insetAdjustedBottom == 0)
        #expect(!TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: insetAdjustedBottom))
    }

    @Test func bottomOverscrollMeasuresViewportBelowLegalContentBottom() {
        let validBottom = TimelineBottomViewport(
            contentHeight: 1_000,
            visibleBottomY: 1_050,
            bottomContentInset: 50
        )
        let belowContent = TimelineBottomViewport(
            contentHeight: 1_000,
            visibleBottomY: 1_120,
            bottomContentInset: 50
        )

        #expect(validBottom.overscrollPastBottom == 0)
        #expect(belowContent.overscrollPastBottom == 70)
    }

    @Test func bottomBounceDoesNotMarkTheUserAsMovedAway() {
        #expect(TimelineBottom.userMovedAwayState(
            previous: false,
            viewportIsPinned: true,
            isUserScrolling: true
        ) == false)
        #expect(TimelineBottom.userMovedAwayState(
            previous: true,
            viewportIsPinned: true,
            isUserScrolling: true
        ) == false)
    }

    @Test func draggingBeyondTheBottomThresholdMarksTheUserAsMovedAway() {
        #expect(TimelineBottom.userMovedAwayState(
            previous: false,
            viewportIsPinned: false,
            isUserScrolling: true
        ))
        #expect(TimelineBottom.userMovedAwayState(
            previous: true,
            viewportIsPinned: false,
            isUserScrolling: false
        ))
    }

    @Test func scrollButtonTapOptimisticallyPinsTimeline() {
        #expect(TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: false))
        #expect(TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: true))
    }

    @Test func programmaticScrollsDoNotImpersonateUserGestures() {
        #expect(!TimelineBottomScrollCoordinator.isUserDriven(.idle))
        #expect(!TimelineBottomScrollCoordinator.isUserDriven(.animating))
        #expect(TimelineBottomScrollCoordinator.isUserDriven(.tracking))
        #expect(TimelineBottomScrollCoordinator.isUserDriven(.interacting))
        #expect(TimelineBottomScrollCoordinator.isUserDriven(.decelerating))

        let movedAway = TimelineBottom.userMovedAwayState(
            previous: false,
            viewportIsPinned: false,
            isUserScrolling: TimelineBottomScrollCoordinator.isUserDriven(.animating)
        )
        #expect(!movedAway)
        #expect(TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: true,
            userMovedAwayFromBottom: movedAway,
            isUserScrolling: TimelineBottomScrollCoordinator.isUserDriven(.animating)
        ))
    }

    @Test func bottomScrollRequestsCoalesceToLatestTimelineTarget() {
        let timelineChange = TimelineBottomScrollRequest(
            animated: true,
            reason: .timelineChange,
            targetID: "message-a"
        )
        let nextTimelineChange = TimelineBottomScrollRequest(
            animated: false,
            reason: .timelineChange,
            targetID: "message-b"
        )

        let result = TimelineBottomScrollCoordinator.coalesced(timelineChange, with: nextTimelineChange)

        #expect(result.animated == false)
        #expect(result.reason == .timelineChange)
        #expect(result.targetID == "message-b")
    }

    @Test func userInitiatedBottomScrollWinsPendingAutomaticFollowUps() {
        let timelineChange = TimelineBottomScrollRequest(
            animated: false,
            reason: .timelineChange,
            targetID: "message-a"
        )
        let buttonTap = TimelineBottomScrollRequest(
            animated: true,
            reason: .buttonTap,
            targetID: "message-b"
        )

        let userWins = TimelineBottomScrollCoordinator.coalesced(timelineChange, with: buttonTap)
        let automaticDoesNotOverrideUser = TimelineBottomScrollCoordinator.coalesced(buttonTap, with: timelineChange)

        #expect(userWins.animated)
        #expect(userWins.reason == .buttonTap)
        #expect(userWins.targetID == "message-b")
        #expect(automaticDoesNotOverrideUser == buttonTap)
    }

    @Test func userScrollSuppressesAutomaticBottomRequestsButNotButtonTap() {
        for reason in [TimelineBottomScrollReason.timelineChange, .layoutChange] {
            #expect(!TimelineBottomScrollCoordinator.shouldExecute(
                reason: reason,
                isUserScrolling: true
            ))
            #expect(TimelineBottomScrollCoordinator.shouldExecute(
                reason: reason,
                isUserScrolling: false
            ))
        }

        #expect(TimelineBottomScrollCoordinator.shouldExecute(
            reason: .buttonTap,
            isUserScrolling: true
        ))
    }

    @Test func layoutChangesFollowBottomOnlyBeforeTheUserMovesAway() {
        #expect(TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: true,
            userMovedAwayFromBottom: false,
            isUserScrolling: false
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: false,
            userMovedAwayFromBottom: false,
            isUserScrolling: false
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: true,
            userMovedAwayFromBottom: true,
            isUserScrolling: false
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
            didFinishInitialPositioning: true,
            userMovedAwayFromBottom: false,
            isUserScrolling: true
        ))
    }

    @Test func timelineScrollRequestsSkipAlreadyHandledTarget() {
        #expect(TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
            lastAutomaticTargetID: "message-a",
            nextTargetID: "message-a"
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
            lastAutomaticTargetID: "message-a",
            nextTargetID: "message-b"
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
            lastAutomaticTargetID: nil,
            nextTargetID: "message-a"
        ))
    }
}
