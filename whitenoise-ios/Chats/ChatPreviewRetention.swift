import Foundation
import MarmotKit

nonisolated enum ChatPreviewRetention {
    static func expiry(_ preview: ChatListMessagePreviewFfi?) -> Date? {
        guard let preview, let duration = preview.retentionSeconds, duration > 0,
              let expiry = preview.retentionExpiresAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiry))
    }

    static func isExpired(_ preview: ChatListMessagePreviewFfi?, at now: Date) -> Bool {
        expiry(preview).map { $0 <= now } ?? false
    }
}
