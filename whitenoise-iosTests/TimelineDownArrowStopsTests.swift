import Testing
@testable import whitenoise_ios

struct TimelineDownArrowStopsTests {
    private typealias Stop = TimelineDownArrowPolicy.Stop
    private typealias Placement = TimelineDownArrowStopPlacement
    private typealias Key = TimelineHistoryOrderKey

    private static func key(epoch: UInt64? = 10, at timelineAt: UInt64, id: String = "m",
                            source: String? = nil, kind: UInt64 = 9) -> Key {
        Key(sourceMessageIdHex: source, sourceEpoch: epoch, kind: kind, timelineAt: timelineAt, messageIdHex: id)
    }

    private static let page = key(at: 100)...key(at: 200)

    private func loaded(_ index: Int, visible: ClosedRange<Int>?) -> Placement {
        Placement.of(targetIndex: index, visibleIndices: visible, orderKey: nil,
                     loadedOrderKeys: Self.page, hasMoreAfter: false)
    }

    private func unloaded(orderKey: Key?, loaded: ClosedRange<Key>? = page,
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
        #expect(unloaded(orderKey: Self.key(at: 50), hasMoreAfter: true) == .unloadedOlder)
        #expect(unloaded(orderKey: Self.key(at: 250), hasMoreAfter: true) == .unloadedNewer)
        #expect(unloaded(orderKey: Self.key(at: 250), hasMoreAfter: false) == .unknown)
        #expect(unloaded(orderKey: Self.key(at: 150), hasMoreAfter: true) == .unknown)
        #expect(unloaded(orderKey: nil, hasMoreAfter: true) == .unknown)
        #expect(unloaded(orderKey: Self.key(at: 250), loaded: nil, hasMoreAfter: true) == .unknown)
    }

    /// A later epoch is newer history even when its clock reads earlier.
    @Test func unloadedPlacementFollowsEpochBeforeTimestamp() {
        let epochTenPage = Self.key(epoch: 10, at: 200, id: "a")...Self.key(epoch: 10, at: 210, id: "b")
        #expect(unloaded(orderKey: Self.key(epoch: 11, at: 100), loaded: epochTenPage,
                         hasMoreAfter: true) == .unloadedNewer)
        #expect(unloaded(orderKey: Self.key(epoch: 9, at: 300), loaded: epochTenPage,
                         hasMoreAfter: true) == .unloadedOlder)
    }

    /// Rows sharing the page edge's timestamp are placed by message id, as MDK pages them.
    @Test func unloadedPlacementBreaksTimestampTiesByMessageId() {
        let page = Self.key(at: 100, id: "b")...Self.key(at: 200, id: "b")
        #expect(unloaded(orderKey: Self.key(at: 200, id: "c"), loaded: page, hasMoreAfter: true) == .unloadedNewer)
        #expect(unloaded(orderKey: Self.key(at: 100, id: "a"), loaded: page, hasMoreAfter: true) == .unloadedOlder)
    }

    @Test func historyOrderMatchesMDKCanonicalOrder() {
        let sourcedWithoutEpoch = Self.key(epoch: nil, at: 900, source: "s")
        let groupState = Self.key(epoch: 10, at: 500, id: "z", kind: MessageSemantics.kindGroupSystem)
        let chat = Self.key(epoch: 10, at: 1, id: "a")
        let nextEpoch = Self.key(epoch: 11, at: 0)
        let localSend = Self.key(epoch: nil, at: 0)
        #expect([localSend, nextEpoch, chat, groupState, sourcedWithoutEpoch].sorted()
            == [sourcedWithoutEpoch, groupState, chat, nextEpoch, localSend])
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

    /// MDK cannot place a first unread outside an opening page it never
    /// loaded, so a stop the reader never had on screen or ahead survives.
    @Test func onlyAStopOnceOnScreenOrAheadCanBePassed() {
        #expect(!TimelineDownArrowPolicy.hasPassed(.above, wasOnScreenOrAhead: false))
        #expect(!TimelineDownArrowPolicy.hasPassed(.unloadedOlder, wasOnScreenOrAhead: false))
        #expect(TimelineDownArrowPolicy.hasPassed(.above, wasOnScreenOrAhead: true))
        #expect(TimelineDownArrowPolicy.hasPassed(.unloadedOlder, wasOnScreenOrAhead: true))
        #expect(!TimelineDownArrowPolicy.hasPassed(.below, wasOnScreenOrAhead: true))
        #expect(!TimelineDownArrowPolicy.hasPassed(.unknown, wasOnScreenOrAhead: true))
        #expect(Placement.visible.isOnScreenOrAhead)
        #expect(Placement.below.isOnScreenOrAhead)
        #expect(Placement.unloadedNewer.isOnScreenOrAhead)
        #expect(!Placement.above.isOnScreenOrAhead)
        #expect(!Placement.unknown.isOnScreenOrAhead)
    }

    @Test func onlyLandingOnTheFirstUnreadConsumesIt() {
        #expect(TimelineDownArrowPolicy.consumesFirstUnread(.firstUnread(messageIdHex: "unread")))
        #expect(!TimelineDownArrowPolicy.consumesFirstUnread(.latest))
        #expect(!TimelineDownArrowPolicy.consumesFirstUnread(.replyOrigin(messageIdHex: "origin")))
    }

    /// Open on the divider, tap to latest, scroll back above the divider:
    /// the next tap lands on the divider rather than skipping the unread.
    @Test func jumpingToLatestPastTheDividerKeepsItAsAStop() {
        let unreadIndex = 5
        #expect(loaded(unreadIndex, visible: 3...8).isOnScreenOrAhead)
        let tap = TimelineDownArrowPolicy.destination(
            replyOrigin: nil, firstUnread: Stop(messageIdHex: "unread", placement: loaded(unreadIndex, visible: 3...8)))
        #expect(tap == .latest)
        #expect(!TimelineDownArrowPolicy.consumesFirstUnread(tap))
        // The jump forgets the sighting.
        var seen = false
        // Scrolling up from the bottom with the divider still above does not retire it.
        #expect(!TimelineDownArrowPolicy.hasPassed(loaded(unreadIndex, visible: 40...48), wasOnScreenOrAhead: seen))
        seen = seen || loaded(unreadIndex, visible: 4...9).isOnScreenOrAhead
        let afterScrollingAbove = loaded(unreadIndex, visible: 0...3)
        #expect(!TimelineDownArrowPolicy.hasPassed(afterScrollingAbove, wasOnScreenOrAhead: seen))
        #expect(TimelineDownArrowPolicy.destination(
            replyOrigin: nil, firstUnread: Stop(messageIdHex: "unread", placement: afterScrollingAbove)
        ) == .firstUnread(messageIdHex: "unread"))
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
