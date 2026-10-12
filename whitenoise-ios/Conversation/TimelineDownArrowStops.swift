import Foundation
import MarmotKit

/// MDK's canonical history order, mirrored from `canonical_timeline_order_key`
/// in mdk `crates/storage-sqlite/src/timeline.rs`. Window pages arrive in this
/// order; `timelineAt` alone is not monotonic across epochs.
nonisolated struct TimelineHistoryOrderKey: Comparable {
    private let rank: UInt8
    private let primary: UInt64
    private let phase: UInt8
    private let intraEpochAt: UInt64
    private let messageIdHex: String

    init(sourceMessageIdHex: String?, sourceEpoch: UInt64?, kind: UInt64, timelineAt: UInt64, messageIdHex: String) {
        switch (sourceEpoch, sourceMessageIdHex) {
        case (let epoch?, _): (rank, primary) = (1, epoch)
        // Unresolved local projections stay at the optimistic head.
        case (nil, nil): (rank, primary) = (2, timelineAt)
        case (nil, _?): (rank, primary) = (0, timelineAt)
        }
        // Authenticated group-state rows lead their epoch.
        phase = kind == MessageSemantics.kindGroupSystem && sourceMessageIdHex == nil && sourceEpoch != nil ? 0 : 1
        intraEpochAt = phase == 0 ? 0 : timelineAt
        self.messageIdHex = messageIdHex
    }

    init(_ record: TimelineMessageRecordFfi) {
        self.init(sourceMessageIdHex: record.sourceMessageIdHex, sourceEpoch: record.sourceEpoch,
                  kind: record.kind, timelineAt: record.timelineAt, messageIdHex: record.messageIdHex)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.rank, lhs.primary, lhs.phase, lhs.intraEpochAt, lhs.messageIdHex)
            < (rhs.rank, rhs.primary, rhs.phase, rhs.intraEpochAt, rhs.messageIdHex)
    }
}

/// Where a down-arrow stop sits relative to the rows on screen.
nonisolated enum TimelineDownArrowStopPlacement: Equatable {
    case above
    case visible
    case below
    /// Dropped from the loaded window on its older side.
    case unloadedOlder
    /// Not loaded yet, and newer than everything that is.
    case unloadedNewer
    /// Nothing visible yet, or the row is missing from inside the loaded range.
    case unknown

    /// `orderKey` is captured while the stop's row is in the window, so a row
    /// the bounded window has dropped can still be placed.
    static func of(
        targetIndex: Int?,
        visibleIndices: ClosedRange<Int>?,
        orderKey: TimelineHistoryOrderKey?,
        loadedOrderKeys: ClosedRange<TimelineHistoryOrderKey>?,
        hasMoreAfter: Bool
    ) -> Self {
        if let targetIndex {
            guard let visibleIndices else { return .unknown }
            if targetIndex < visibleIndices.lowerBound { return .above }
            if targetIndex > visibleIndices.upperBound { return .below }
            return .visible
        }
        guard let orderKey, let loadedOrderKeys else { return .unknown }
        if orderKey < loadedOrderKeys.lowerBound { return .unloadedOlder }
        if orderKey > loadedOrderKeys.upperBound, hasMoreAfter { return .unloadedNewer }
        return .unknown
    }

    /// A stop behind the reader no longer applies.
    var isPassed: Bool { self == .above || self == .unloadedOlder }

    var isAhead: Bool { self == .below || self == .unloadedNewer }

    var isOnScreenOrAhead: Bool { self == .visible || isAhead }
}

nonisolated enum TimelineDownArrowDestination: Equatable {
    case replyOrigin(messageIdHex: String)
    case firstUnread(messageIdHex: String)
    case latest
}

/// The down arrow steps back toward the tail one stop at a time: the message
/// whose quote the user tapped, then the first unread message, then the latest.
nonisolated enum TimelineDownArrowPolicy {
    struct Stop: Equatable {
        let messageIdHex: String
        let placement: TimelineDownArrowStopPlacement
    }

    static func destination(replyOrigin: Stop?, firstUnread: Stop?) -> TimelineDownArrowDestination {
        if let replyOrigin, replyOrigin.placement.isAhead {
            return .replyOrigin(messageIdHex: replyOrigin.messageIdHex)
        }
        if let firstUnread, firstUnread.placement.isAhead {
            return .firstUnread(messageIdHex: firstUnread.messageIdHex)
        }
        return .latest
    }

    /// Only the reader's own scrolling retires a stop. Initial positioning
    /// starts bottom-anchored and programmatic jumps pass rows the reader
    /// never chose to pass.
    static func mayRetirePassedStops(isInitialPositionSettled: Bool, isUserScrolling: Bool) -> Bool {
        isInitialPositionSettled && isUserScrolling
    }

    /// The reader passes a stop only by moving beyond it after having it on
    /// screen or ahead. MDK cannot place a row outside the window that was never
    /// loaded, so a stop behind an opening page stays until the reader reaches it.
    static func hasPassed(_ placement: TimelineDownArrowStopPlacement, wasOnScreenOrAhead: Bool) -> Bool {
        wasOnScreenOrAhead && placement.isPassed
    }

    /// Only landing on the first unread consumes it. Jumping past it is not
    /// reading past it, so the caller forgets its sighting and it stays a stop
    /// until the reader sees it and scrolls past it.
    static func consumesFirstUnread(_ destination: TimelineDownArrowDestination) -> Bool {
        if case .firstUnread = destination { return true }
        return false
    }

    static func orderKeyRange<Keys: Sequence>(_ keys: Keys) -> ClosedRange<Keys.Element>? where Keys.Element: Comparable {
        var range: ClosedRange<Keys.Element>?
        for key in keys {
            range = range.map { min($0.lowerBound, key)...max($0.upperBound, key) } ?? key...key
        }
        return range
    }

    /// Index range of the visible rows in timeline order, or nil when none are.
    static func visibleIndices<RowKeys: BidirectionalCollection>(
        rowKeys: RowKeys,
        visibleRowKeys: Set<String>
    ) -> ClosedRange<Int>? where RowKeys.Element == String, RowKeys.Index == Int {
        guard !visibleRowKeys.isEmpty,
              let first = rowKeys.firstIndex(where: visibleRowKeys.contains),
              let last = rowKeys.lastIndex(where: visibleRowKeys.contains)
        else { return nil }
        return first...last
    }
}
