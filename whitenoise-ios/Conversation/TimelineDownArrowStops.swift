import Foundation

/// Where a down-arrow stop sits relative to the rows on screen.
nonisolated enum TimelineDownArrowStopPlacement: Equatable {
    case above
    case visible
    case below
    /// The row is not in the loaded window, or nothing is visible yet.
    case unloaded

    static func of(targetIndex: Int?, visibleIndices: ClosedRange<Int>?) -> Self {
        guard let targetIndex, let visibleIndices else { return .unloaded }
        if targetIndex < visibleIndices.lowerBound { return .above }
        if targetIndex > visibleIndices.upperBound { return .below }
        return .visible
    }

    /// A stop the user has scrolled past on their own no longer applies.
    var isPassed: Bool { self == .above }

    /// Both stops are newer than where the user is reading, so an unloaded
    /// row is reachable only while newer history remains to be loaded.
    func isAhead(hasMoreAfter: Bool) -> Bool {
        switch self {
        case .below: true
        case .unloaded: hasMoreAfter
        case .above, .visible: false
        }
    }
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

    static func destination(
        replyOrigin: Stop?,
        firstUnread: Stop?,
        hasMoreAfter: Bool
    ) -> TimelineDownArrowDestination {
        if let replyOrigin, replyOrigin.placement.isAhead(hasMoreAfter: hasMoreAfter) {
            return .replyOrigin(messageIdHex: replyOrigin.messageIdHex)
        }
        if let firstUnread, firstUnread.placement.isAhead(hasMoreAfter: hasMoreAfter) {
            return .firstUnread(messageIdHex: firstUnread.messageIdHex)
        }
        return .latest
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
