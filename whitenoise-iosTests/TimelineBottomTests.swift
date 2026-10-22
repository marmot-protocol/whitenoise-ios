import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

private struct TimelineSemanticPositionHarness: View {
    let target: TimelineInitialPositionTarget
    let onViewportChanged: (TimelineBottomViewport) -> Void
    let onVisibleTargetsChanged: (Set<String>) -> Void
    @State private var requestGeneration = 0

    init(
        target: TimelineInitialPositionTarget,
        onViewportChanged: @escaping (TimelineBottomViewport) -> Void,
        onVisibleTargetsChanged: @escaping (Set<String>) -> Void = { _ in }
    ) {
        self.target = target
        self.onViewportChanged = onViewportChanged
        self.onVisibleTargetsChanged = onVisibleTargetsChanged
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Section {
                        ForEach(0..<120, id: \.self) { index in
                            Text("Row \(index)")
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: index.isMultiple(of: 11) ? 180 : 40
                                )
                                .id("row-\(index)")
                        }
                    }
                    ForEach(["bottom"], id: \.self) { _ in
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                }
                .scrollTargetLayout()
            }
            .onScrollGeometryChange(for: TimelineBottomViewport.self) { geometry in
                TimelineBottomViewport(
                    contentHeight: geometry.contentSize.height,
                    visibleBottomY: geometry.visibleRect.maxY,
                    bottomContentInset: geometry.contentInsets.bottom
                )
            } action: { _, viewport in
                onViewportChanged(viewport)
                requestGeneration &+= 1
            }
            .task(id: requestGeneration) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                requestTarget(proxy: proxy)
            }
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: TimelineViewportVisibility.minimumVisibleFraction
            ) { visibleIDs in
                onVisibleTargetsChanged(Set(visibleIDs))
            }
        }
    }

    private func requestTarget(proxy: ScrollViewProxy) {
        switch target {
        case .item(let id, let anchor):
            proxy.scrollTo(id, anchor: anchor.unitPoint)
        case .latest(let id):
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

@MainActor
private final class TimelineResizeHarnessModel: ObservableObject {
    @Published var viewportHeight: CGFloat = 700
}

private struct TimelineShortContentResizeHarness: View {
    @ObservedObject var model: TimelineResizeHarnessModel
    let onVisibleTargetsChanged: (Set<String>) -> Void

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    Text("Only message")
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .id("message")
                }
                .scrollTargetLayout()
                .frame(minHeight: max(0, viewport.size.height), alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: TimelineViewportVisibility.minimumVisibleFraction
            ) { visibleIDs in
                onVisibleTargetsChanged(Set(visibleIDs))
            }
        }
        .frame(height: model.viewportHeight)
    }
}

@MainActor
struct TimelineBottomTests {

    @Test func shortTimelineRemainsVisibleWhenViewportShrinks() async throws {
        let model = TimelineResizeHarnessModel()
        var visibleTargets = Set<String>()
        let controller = UIHostingController(
            rootView: TimelineShortContentResizeHarness(model: model) {
                visibleTargets = $0
            }
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        for _ in 0..<100 where !visibleTargets.contains("message") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(visibleTargets.contains("message"))

        model.viewportHeight = 390
        try await Task.sleep(for: .milliseconds(100))

        #expect(visibleTargets.contains("message"))
        window.isHidden = true
    }

    @Test func swiftUIStableTimelineResolvesSemanticBottomTarget() async throws {
        let target = TimelineInitialPositionTarget.latest(id: "bottom")
        var didReachTarget = false
        var didSeeBottomTarget = false
        var lastViewport: TimelineBottomViewport?
        let controller = UIHostingController(
            rootView: TimelineSemanticPositionHarness(
                target: target,
                onViewportChanged: {
                    lastViewport = $0
                    didReachTarget = $0.isPinned
                },
                onVisibleTargetsChanged: {
                    didSeeBottomTarget = $0.contains("bottom")
                }
            )
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        for _ in 0..<100 where !didReachTarget || !didSeeBottomTarget {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(didReachTarget, "Last viewport: \(String(describing: lastViewport))")
        #expect(didSeeBottomTarget)
        window.isHidden = true
    }

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

    @Test func messageActionsOverlayKeepsReactionsAboveAndActionsBelowMessage() {
        let source = CGRect(x: 0, y: 220, width: 390, height: 96)
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 320,
            showsReactions: true
        )

        let reactionBottom = layout.groupTop + MessageActionsPresentation.reactionHeight
        let previewTop = layout.previewCenterY - layout.previewHeight / 2
        let previewBottom = layout.previewCenterY + layout.previewHeight / 2
        let actionsTop = layout.groupTop + layout.groupHeight - 320

        #expect(previewTop - reactionBottom == MessageActionsPresentation.surfaceGap)
        #expect(actionsTop - previewBottom == MessageActionsPresentation.surfaceGap)
    }

    @Test func messageActionsOverlayShiftsTheWholeCompositionOnShortScreens() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 650, width: 390, height: 300),
            containerHeight: 760,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.groupTop >= MessageActionsPresentation.verticalMargin)
        #expect(layout.groupTop + layout.groupHeight <= 760 - MessageActionsPresentation.verticalMargin)
        #expect(layout.previewScale < 1)
    }

    @Test func messageActionsOverlayClipsMessagesTallerThanTheViewportInsteadOfShrinkingThem() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: -900, width: 320, height: 2400),
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.previewScale >= MessageActionsPresentation.minimumPreviewScale)
        #expect(layout.previewIsTruncated)
        #expect(layout.previewContentHeight < 2400)
        #expect(abs(layout.previewContentHeight * layout.previewScale - layout.previewHeight) < 0.001)
        #expect(layout.groupTop >= MessageActionsPresentation.verticalMargin)
        #expect(layout.groupTop + layout.groupHeight <= 844 - MessageActionsPresentation.verticalMargin)
    }

    @Test(arguments: [CGFloat(2400), CGFloat(5000), CGFloat(20000)])
    func messageActionsOverlayKeepsTallPreviewsBoundedAndDeterministic(sourceHeight: CGFloat) {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: sourceHeight),
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )
        let reference = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: 2400),
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.previewScale == MessageActionsPresentation.minimumPreviewScale)
        #expect(layout.previewHeight == reference.previewHeight)
        #expect(layout.previewContentHeight == reference.previewContentHeight)
        #expect(layout.groupHeight == reference.groupHeight)
    }

    @Test func messageActionsOverlayLeavesMessagesThatAlreadyFitUntouched() {
        let source = CGRect(x: 0, y: 220, width: 390, height: 96)
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 320,
            showsReactions: true
        )

        #expect(layout.previewScale == 1)
        #expect(!layout.previewIsTruncated)
        #expect(layout.previewContentHeight == source.height)
        #expect(layout.previewHeight == source.height)
    }

    @Test func messageActionsOverlayStillScalesModeratelyTallMessagesWithoutClipping() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 650, width: 390, height: 300),
            containerHeight: 760,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.previewScale < 1)
        #expect(layout.previewScale > MessageActionsPresentation.minimumPreviewScale)
        #expect(!layout.previewIsTruncated)
        #expect(layout.previewContentHeight == 300)
    }

    @Test func messageActionsOverlayKeyboardSizedContainerStillRendersAReadablePreview() {
        let source = CGRect(x: 0, y: 40, width: 320, height: 1200)
        let keyboardOpen = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 508,
            actionMenuHeight: 300,
            showsReactions: true
        )
        let keyboardClosed = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(keyboardOpen.previewScale == MessageActionsPresentation.minimumPreviewScale)
        #expect(keyboardClosed.previewHeight > keyboardOpen.previewHeight)
        #expect(keyboardClosed.previewContentHeight > keyboardOpen.previewContentHeight)
    }

    @Test func messageActionsOverlayDoesNotReserveAReactionSurfaceWhenInteractionIsDisabled() {
        let source = CGRect(x: 0, y: 180, width: 390, height: 80)
        let withReactions = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 220,
            showsReactions: true
        )
        let withoutReactions = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 220,
            showsReactions: false
        )

        #expect(withoutReactions.groupHeight
            == withReactions.groupHeight
                - MessageActionsPresentation.reactionHeight
                - MessageActionsPresentation.surfaceGap)
    }
}
