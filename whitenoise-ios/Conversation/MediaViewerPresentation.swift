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
    let hasSourceMessage: Bool

    init(hasPreparedMedia: Bool, hasForwardingContext: Bool, hasSourceMessage: Bool = false) {
        self.hasPreparedMedia = hasPreparedMedia
        self.hasForwardingContext = hasForwardingContext
        self.hasSourceMessage = hasSourceMessage
    }

    var canSave: Bool { hasPreparedMedia }

    var canShare: Bool { hasPreparedMedia }

    var canForward: Bool { hasPreparedMedia && hasForwardingContext }

    /// Unlike saving and sharing this never becomes available while the page
    /// stays put, so the menu hides it rather than showing a dead row.
    var canGoToMessage: Bool { hasSourceMessage }
}

nonisolated enum MediaViewerMessageNavigation {
    static func sourceMessageIdHex(
        forItemID itemID: String?,
        messageIdByItemID: [String: String]
    ) -> String? {
        guard let itemID,
              let messageIdHex = messageIdByItemID[itemID]?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !messageIdHex.isEmpty
        else { return nil }
        return messageIdHex
    }
}
