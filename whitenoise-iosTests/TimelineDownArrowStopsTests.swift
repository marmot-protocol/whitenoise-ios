import Testing
@testable import whitenoise_ios

struct TimelineDownArrowStopsTests {
    private typealias Stop = TimelineDownArrowPolicy.Stop
    private typealias Placement = TimelineDownArrowStopPlacement

    private func loaded(_ index: Int, visible: ClosedRange<Int>?) -> Placement {
        Placement.of(targetIndex: index, visibleIndices: visible, orderKey: nil,
                     loadedOrderKeys: 100...200, hasMoreAfter: false)
    }

    private func unloaded(orderKey: UInt64?, loaded: ClosedRange<UInt64>? = 100...200,
                          hasMoreAfter: Bool) -> Placement {
        Placement.of(targetIndex: nil, visibleIndices: 5...9, orderKey: orderKey,
                     loadedOrderKeys: loaded, hasMoreAfter: hasMoreAfter)
    }

    @Test func loadedPlacementComparesTargetWithVisibleRows() {
        #expect(loaded(2, visible: 5...9) == .above)
        #expect(loaded(5, visible: 5...9) == .visible)
        #expect(loaded(9, visible: 5...9) == .visible)
        #expect(loaded(10, visible: 5...9) == .below)
        #expect(loaded(3, visible: nil) == .unknown)
    }

    @Test func unloadedPlacementUsesTheCapturedOrderKey() {
        #expect(unloaded(orderKey: 50, hasMoreAfter: true) == .unloadedOlder)
        #expect(unloaded(orderKey: 250, hasMoreAfter: true) == .unloadedNewer)
        #expect(unloaded(orderKey: 250, hasMoreAfter: false) == .unknown)
        #expect(unloaded(orderKey: 150, hasMoreAfter: true) == .unknown)
        #expect(unloaded(orderKey: nil, hasMoreAfter: true) == .unknown)
        #expect(unloaded(orderKey: 250, loaded: nil, hasMoreAfter: true) == .unknown)
    }

    @Test func stopsBehindTheReaderArePassedAndOnlyStopsInFrontAreAhead() {
        #expect(Placement.above.isPassed)
        #expect(Placement.unloadedOlder.isPassed)
        #expect(!Placement.visible.isPassed)
        #expect(!Placement.unknown.isPassed)
        #expect(Placement.below.isAhead)
        #expect(Placement.unloadedNewer.isAhead)
        #expect(!Placement.unloadedOlder.isAhead)
        #expect(!Placement.visible.isAhead)
        #expect(!Placement.unknown.isAhead)
    }

    @Test func replyOriginAheadComesFirst() {
        let destination = TimelineDownArrowPolicy.destination(
            replyOrigin: Stop(messageIdHex: "origin", placement: .below),
            firstUnread: Stop(messageIdHex: "unread", placement: .below)
        )
        #expect(destination == .replyOrigin(messageIdHex: "origin"))
    }

    @Test func firstUnreadAheadComesBeforeLatest() {
        #expect(TimelineDownArrowPolicy.destination(
            replyOrigin: nil,
            firstUnread: Stop(messageIdHex: "unread", placement: .below)
        ) == .firstUnread(messageIdHex: "unread"))
        #expect(TimelineDownArrowPolicy.destination(
            replyOrigin: Stop(messageIdHex: "origin", placement: .visible),
            firstUnread: Stop(messageIdHex: "unread", placement: .unloadedNewer)
        ) == .firstUnread(messageIdHex: "unread"))
    }

    @Test func stopsThatAreNotAheadFallThroughToLatest() {
        #expect(TimelineDownArrowPolicy.destination(
            replyOrigin: Stop(messageIdHex: "origin", placement: .unloadedOlder),
            firstUnread: Stop(messageIdHex: "unread", placement: .above)
        ) == .latest)
        #expect(TimelineDownArrowPolicy.destination(
            replyOrigin: Stop(messageIdHex: "origin", placement: .unknown),
            firstUnread: nil
        ) == .latest)
        #expect(TimelineDownArrowPolicy.destination(replyOrigin: nil, firstUnread: nil) == .latest)
    }

    /// The first frame is bottom-anchored, so the first unread row starts
    /// above the viewport before the requested unread position settles.
    @Test func onlyTheReadersOwnScrollingAfterSettlingRetiresStops() {
        #expect(!TimelineDownArrowPolicy.mayRetirePassedStops(
            isInitialPositionSettled: false, isUserScrolling: false))
        #expect(!TimelineDownArrowPolicy.mayRetirePassedStops(
            isInitialPositionSettled: false, isUserScrolling: true))
        #expect(!TimelineDownArrowPolicy.mayRetirePassedStops(
            isInitialPositionSettled: true, isUserScrolling: false))
        #expect(TimelineDownArrowPolicy.mayRetirePassedStops(
            isInitialPositionSettled: true, isUserScrolling: true))
    }

    /// A stop that leaves the top during the reader's scroll is retired, so
    /// scrolling back above it later does not revive it as a destination.
    @Test func stopRetiredWhenItExitsTheTopStaysRetired() {
        let stopIndex = 5
        #expect(loaded(stopIndex, visible: 3...7).isPassed == false)
        let afterExit = loaded(stopIndex, visible: 6...10)
        #expect(afterExit.isPassed)
        #expect(TimelineDownArrowPolicy.mayRetirePassedStops(
            isInitialPositionSettled: true, isUserScrolling: true))
        // Back above the stop: it would be ahead, but a retired stop is not offered.
        #expect(loaded(stopIndex, visible: 0...4) == .below)
        #expect(TimelineDownArrowPolicy.destination(replyOrigin: nil, firstUnread: nil) == .latest)
    }

    @Test func orderKeyRangeSpansTheGivenKeys() {
        #expect(TimelineDownArrowPolicy.orderKeyRange([150, 120, 180]) == 120...180)
        #expect(TimelineDownArrowPolicy.orderKeyRange([42]) == 42...42)
        #expect(TimelineDownArrowPolicy.orderKeyRange([UInt64]()) == nil)
    }

    @Test func visibleIndicesSpanFirstToLastVisibleRow() {
        let rows = ["a", "b", "c", "d", "e"]
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: ["d", "b"]) == 1...3)
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: ["c"]) == 2...2)
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: []) == nil)
        #expect(TimelineDownArrowPolicy.visibleIndices(rowKeys: rows, visibleRowKeys: ["unknown"]) == nil)
    }
}
