import Foundation

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

    /// `orderKey` is the stop's `recordedAt`, captured when the stop was taken,
    /// so a row the bounded window has dropped can still be placed.
    static func of(
        targetIndex: Int?,
        visibleIndices: ClosedRange<Int>?,
        orderKey: UInt64?,
        loadedOrderKeys: ClosedRange<UInt64>?,
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
