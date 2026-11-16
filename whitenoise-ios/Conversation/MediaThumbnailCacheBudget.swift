import UIKit

/// Decoded thumbnails live in memory, so their budget follows the device's
/// memory rather than its free disk space.
nonisolated enum MediaThumbnailCacheBudget {
    static let minimumBytes = 64 * 1024 * 1024
    static let maximumBytes = 1024 * 1024 * 1024

    /// An eighth of the device's memory, so a long photo-heavy chat stays decoded
    /// while scrolling back through it.
    static func bytes(physicalMemory: UInt64) -> Int {
        let share = physicalMemory / 8
        return Int(min(max(share, UInt64(minimumBytes)), UInt64(maximumBytes)))
    }

    static let images = bytes(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    static let videoPosters = images / 4

    /// A suspended app holding a budget this size is the first one the system
    /// reclaims, so the cache empties when the app leaves the foreground.
    static func emptyOnBackground<Value: AnyObject>(_ cache: NSCache<NSString, Value>) {
        let eviction = ThumbnailCacheEviction(cache)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in eviction.removeAllObjects() }
    }
}

/// NSCache supports concurrent eviction. This handle only removes entries; it
/// never transfers the cached values or keeps the cache alive.
/// https://developer.apple.com/documentation/foundation/nscache
// swiftlint:disable:next no_unchecked_sendable
nonisolated private final class ThumbnailCacheEviction<Value: AnyObject>: @unchecked Sendable {
    private weak var cache: NSCache<NSString, Value>?

    init(_ cache: NSCache<NSString, Value>) {
        self.cache = cache
    }

    func removeAllObjects() {
        cache?.removeAllObjects()
    }
}
