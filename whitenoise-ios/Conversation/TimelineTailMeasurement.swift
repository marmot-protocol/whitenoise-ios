import SwiftUI

/// Geometry belongs to a particular rendered page, not whichever page arrives next.
struct TimelineTailMeasurement: Equatable {
    let lastRowID: String?
    let isPinned: Bool
    private let openingOverscroll: CGFloat
    var isPastEnd: Bool { openingOverscroll > 0 }

    init(lastRowID: String? = nil, distanceToBottom: CGFloat = .infinity, openingOverscroll: CGFloat = 0) {
        self.lastRowID = lastRowID
        self.openingOverscroll = openingOverscroll > TimelineBottomScrollCoordinator.overscrollTolerance ? openingOverscroll : 0
        isPinned = distanceToBottom <= TimelineBottom.pinnedThreshold
    }

    init(lastRowID: String?, geometry: ScrollGeometry, isOpening: Bool) {
        let end = Self.bottomOffset(contentHeight: geometry.contentSize.height, viewportHeight: geometry.containerSize.height,
                                    topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom)
        self.init(lastRowID: lastRowID,
                  distanceToBottom: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
                  openingOverscroll: isOpening ? geometry.contentOffset.y - end : 0)
    }

    static func bottomOffset(contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(-topInset, contentHeight + bottomInset - viewportHeight)
    }

    func permitsOpeningConfirmation(lastRowID current: String?) -> Bool {
        // A stale measurement cannot veto direct visibility of a target in the new window.
        !(lastRowID == current && isPastEnd)
    }

    func isConversationTail(currentLastRowID: String?, hasMoreAfter: Bool, isPaging: Bool) -> Bool {
        guard let lastRowID, lastRowID == currentLastRowID else { return false }
        return !hasMoreAfter && !isPaging && isPinned
    }
}
