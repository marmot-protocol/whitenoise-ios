import Foundation

nonisolated struct MediaViewerChrome: Equatable {
    private(set) var isVisible: Bool

    init(isVisible: Bool = true) {
        self.isVisible = isVisible
    }

    mutating func toggle() {
        isVisible.toggle()
    }
}

nonisolated struct MediaViewerControlState: Equatable {
    let hasPreparedMedia: Bool
    let hasForwardingContext: Bool

    init(hasPreparedMedia: Bool, hasForwardingContext: Bool) {
        self.hasPreparedMedia = hasPreparedMedia
        self.hasForwardingContext = hasForwardingContext
    }

    var canSave: Bool { hasPreparedMedia }

    var canShare: Bool { hasPreparedMedia }

    var canForward: Bool { hasPreparedMedia && hasForwardingContext }
}
