import Foundation
import SwiftUI
import Testing
@testable import whitenoise_ios

struct TimelineHistoryPagingTests {
    @Test func nativeSizeAnchorOnlyFollowsSettledLatestContent() {
        #expect(TimelineBottomScrollCoordinator.sizeChangeAnchor(
            didFinishInitialPositioning: true, userMovedAwayFromBottom: false,
            isUserScrolling: false, hasMoreAfter: false, isPaging: false) == .bottom)
        for gate in 0..<5 {
            #expect(TimelineBottomScrollCoordinator.sizeChangeAnchor(
                didFinishInitialPositioning: gate != 0, userMovedAwayFromBottom: gate == 1,
                isUserScrolling: gate == 2, hasMoreAfter: gate == 3, isPaging: gate == 4) == nil)
        }
    }
    @Test func readingThroughMultiplePagesNeverEnablesAutomaticFollowing() {
        var readingHistory = true
        for page in 1...3 {
            let last = "page-\(page)"
            let edge = TimelineTailMeasurement(lastRowID: last, distanceToBottom: 0)
            #expect(!edge.isConversationTail(currentLastRowID: last, hasMoreAfter: true, isPaging: false))
            readingHistory = TimelineBottom.userMovedAwayState(
                previous: readingHistory, viewportIsPinned: true, isUserScrolling: false, hasMoreAfter: true
            )
            #expect(readingHistory)
            #expect(!TimelineBottomScrollCoordinator.shouldExecute(
                reason: .timelineChange, isUserScrolling: false,
                userMovedAwayFromBottom: readingHistory, hasMoreAfter: true
            ))
        }
        // The final page closes the forward edge before its new geometry arrives.
        let oldGeometry = TimelineTailMeasurement(lastRowID: "page-3", distanceToBottom: 0)
        #expect(!oldGeometry.isConversationTail(currentLastRowID: "final", hasMoreAfter: false, isPaging: false))
        #expect(!TimelineBottomScrollCoordinator.shouldExecute(
            reason: .layoutChange, isUserScrolling: false,
            userMovedAwayFromBottom: readingHistory, hasMoreAfter: false
        ))
        let readingFinalPage = TimelineTailMeasurement(lastRowID: "final", distanceToBottom: 700)
        #expect(!readingFinalPage.isConversationTail(currentLastRowID: "final", hasMoreAfter: false, isPaging: false))
        let actualEnd = TimelineTailMeasurement(lastRowID: "final", distanceToBottom: 0)
        readingHistory = TimelineBottom.userMovedAwayState(
            previous: readingHistory,
            viewportIsPinned: actualEnd.isConversationTail(currentLastRowID: "final", hasMoreAfter: false, isPaging: false),
            isUserScrolling: true
        )
        #expect(!readingHistory)
        #expect(TimelineBottomScrollCoordinator.shouldExecute(
            reason: .timelineChange, isUserScrolling: false, userMovedAwayFromBottom: readingHistory
        ))
    }

    @Test func inFlightPageAndUnmeasuredTailCannotMarkConversationRead() {
        let edge = TimelineTailMeasurement(lastRowID: "end", distanceToBottom: 0)
        #expect(!edge.isConversationTail(currentLastRowID: "end", hasMoreAfter: false, isPaging: true))
        #expect(!TimelineTailMeasurement().isConversationTail(currentLastRowID: "end", hasMoreAfter: false, isPaging: false))
    }

    @Test func queuedAutomaticScrollMustRecheckReadingIntent() {
        #expect(TimelineBottomScrollCoordinator.shouldExecute(reason: .layoutChange, isUserScrolling: false))
        #expect(!TimelineBottomScrollCoordinator.shouldExecute(
            reason: .layoutChange, isUserScrolling: false, userMovedAwayFromBottom: true
        ))
        #expect(!TimelineBottomScrollCoordinator.shouldExecute(
            reason: .layoutChange, isUserScrolling: false, isPaging: true
        ))
    }

    @Test(arguments: [TimelineBottomScrollReason.send, .buttonTap])
    func explicitActionsStillReachLatest(reason: TimelineBottomScrollReason) {
        #expect(TimelineBottomScrollCoordinator.shouldExecute(
            reason: reason, isUserScrolling: false,
            userMovedAwayFromBottom: true, hasMoreAfter: true, isPaging: true
        ))
    }
}
