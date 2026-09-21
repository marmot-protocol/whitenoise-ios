import Foundation

/// Geometry belongs to a particular rendered page, not whichever page arrives next.
struct TimelineTailMeasurement: Equatable {
    let lastRowID: String?
    let isPinned: Bool

    init(lastRowID: String? = nil, distanceToBottom: CGFloat = .infinity) {
        self.lastRowID = lastRowID
        isPinned = distanceToBottom <= TimelineBottom.pinnedThreshold
    }

    func isConversationTail(currentLastRowID: String?, hasMoreAfter: Bool, isPaging: Bool) -> Bool {
        guard let lastRowID, lastRowID == currentLastRowID else { return false }
        return !hasMoreAfter && !isPaging && isPinned
    }
}
