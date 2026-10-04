import Testing
@testable import whitenoise_ios

struct TimelineDownArrowStopsTests {
    private typealias Stop = TimelineDownArrowPolicy.Stop

    @Test func placementComparesTargetWithVisibleRows() {
        #expect(TimelineDownArrowStopPlacement.of(targetIndex: 2, visibleIndices: 5...9) == .above)
        #expect(TimelineDownArrowStopPlacement.of(targetIndex: 5, visibleIndices: 5...9) == .visible)
        #expect(TimelineDownArrowStopPlacement.of(targetIndex: 9, visibleIndices: 5...9) == .visible)
        #expect(TimelineDownArrowStopPlacement.of(targetIndex: 10, visibleIndices: 5...9) == .below)
        #expect(TimelineDownArrowStopPlacement.of(targetIndex: nil, visibleIndices: 5...9) == .unloaded)
        #expect(TimelineDownArrowStopPlacement.of(targetIndex: 3, visibleIndices: nil) == .unloaded)
    }

    @Test func onlyAStopAboveTheViewportIsPassed() {
        #expect(TimelineDownArrowStopPlacement.above.isPassed)
        #expect(!TimelineDownArrowStopPlacement.visible.isPassed)
        #expect(!TimelineDownArrowStopPlacement.below.isPassed)
        #expect(!TimelineDownArrowStopPlacement.unloaded.isPassed)
    }

    @Test func replyOriginBelowTheViewportComesFirst() {
        let destination = TimelineDownArrowPolicy.destination(
            replyOrigin: Stop(messageIdHex: "origin", placement: .below),
            firstUnread: Stop(messageIdHex: "unread", placement: .below),
            hasMoreAfter: false
        )
        #expect(destination == .replyOrigin(messageIdHex: "origin"))
    }

    @Test func firstUnreadBelowTheViewportComesBeforeLatest() {
        let destination = TimelineDownArrowPolicy.destination(
            replyOrigin: nil,
            firstUnread: Stop(messageIdHex: "unread", placement: .below),
            hasMoreAfter: false
        )
        #expect(destination == .firstUnread(messageIdHex: "unread"))
    }

    @Test func stopsOnScreenOrAlreadyPassedFallThroughToLatest() {
        let destination = TimelineDownArrowPolicy.destination(
            replyOrigin: Stop(messageIdHex: "origin", placement: .visible),
            firstUnread: Stop(messageIdHex: "unread", placement: .above),
            hasMoreAfter: true
        )
        #expect(destination == .latest)
        #expect(TimelineDownArrowPolicy.destination(replyOrigin: nil, firstUnread: nil, hasMoreAfter: true) == .latest)
    }

    @Test func unloadedStopIsAheadOnlyWhileNewerHistoryRemains() {
        let origin = Stop(messageIdHex: "origin", placement: .unloaded)
        #expect(TimelineDownArrowPolicy.destination(replyOrigin: origin, firstUnread: nil, hasMoreAfter: true)
            == .replyOrigin(messageIdHex: "origin"))
        #expect(TimelineDownArrowPolicy.destination(replyOrigin: origin, firstUnread: nil, hasMoreAfter: false)
            == .latest)
    }

    @Test func visibleIndicesSpanFirstToLastVisibleRow() {
        let rows = ["a", "b", "c", "d", "e"]
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: ["d", "b"]) == 1...3)
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: ["c"]) == 2...2)
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: []) == nil)
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: ["unknown"]) == nil)
    }
}
