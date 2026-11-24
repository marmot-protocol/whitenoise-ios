import Foundation
import Synchronization
import UIKit

@MainActor
enum LinkPreviewLoader {
    typealias PageFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias ImageFetch = @Sendable (URL) async throws -> Data

    nonisolated static let maximumConcurrentLoads = 3
    nonisolated static let maximumHTMLBytes = LinkPreviewMetadata.maximumScannedBytes
    nonisolated static let htmlMIMETypes: Set<String> = ["text/html", "application/xhtml+xml"]
    nonisolated private static let acceptHeader = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"

    private final class CachedMetadata: NSObject {
        let metadata: LinkPreviewMetadata?

        init(_ metadata: LinkPreviewMetadata?) {
            self.metadata = metadata
        }
    }

    private final class CachedImage: NSObject {
        let image: UIImage

        init(_ image: UIImage) {
            self.image = image
        }
    }

    /// Thread-safe waiter set so `withTaskCancellationHandler.onCancel` removes
    /// a cancelled waiter and cancels the underlying task synchronously without
    /// waiting for a MainActor hop that could race a limiter permit release.
    private final class WaiterState: Sendable {
        private struct State {
            var waiters: Set<UUID>
            var cancelled: Bool
        }

        private let state: Mutex<State>

        init(initialWaiter: UUID) {
            state = Mutex(State(waiters: [initialWaiter], cancelled: false))
        }

        func addWaiter(_ id: UUID) -> Bool {
            state.withLock {
                guard !$0.cancelled else { return false }
                $0.waiters.insert(id)
                return true
            }
        }

        /// Removes `id` and returns `true` when this call removed the last live
        /// waiter (transitioning the load to cancelled).
        func removeWaiter(_ id: UUID) -> Bool {
            state.withLock {
                guard $0.waiters.remove(id) != nil else { return false }
                guard $0.waiters.isEmpty else { return false }
                $0.cancelled = true
                return true
            }
        }

        func cancelAll() {
            state.withLock {
                $0.waiters.removeAll()
                $0.cancelled = true
            }
        }

        var hasActiveWaiters: Bool {
            state.withLock { !$0.cancelled && !$0.waiters.isEmpty }
        }
    }

    private struct InFlightLoad<Value: Sendable> {
        let id: UUID
        let task: Task<Value, Error>
        let waiters: WaiterState
    }

    private static let loadLimiter = CancellableLoadLimiter(
        maximumConcurrentLoads: maximumConcurrentLoads
    )

    private static let metadataCache: NSCache<NSString, CachedMetadata> = {
        let cache = NSCache<NSString, CachedMetadata>()
        cache.countLimit = 300
        return cache
    }()

    private static let imageCache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private static var inFlightMetadata: [String: InFlightLoad<LinkPreviewMetadata?>] = [:]
    private static var inFlightImages: [String: InFlightLoad<UIImage>] = [:]
    private static var cacheGeneration: UInt64 = 0

    static func cachedMetadata(for url: URL) -> LinkPreviewMetadata?? {
        metadataCache.object(forKey: url.absoluteString as NSString).map(\.metadata)
    }

    static func metadata(
        for url: URL,
        fetch: @escaping PageFetch = fetchHTML(for:),
        limiter: CancellableLoadLimiter? = nil
    ) async throws -> LinkPreviewMetadata? {
        try checkLoadAllowed()
        let key = url.absoluteString
        if let cached = metadataCache.object(forKey: key as NSString) { return cached.metadata }

        let waiterID = UUID()
        let load: InFlightLoad<LinkPreviewMetadata?>
        if let existing = inFlightMetadata[key], existing.waiters.addWaiter(waiterID) {
            load = existing
        } else {
            let activeLimiter = limiter ?? loadLimiter
            let loadID = UUID()
            let startedGeneration = cacheGeneration
            let waiters = WaiterState(initialWaiter: waiterID)
            let created = Task {
                let metadata = try await withLimiter(activeLimiter) {
                    try Task.checkCancellation()
                    guard waiters.hasActiveWaiters else { throw CancellationError() }
                    return try await fetchMetadata(for: url, fetch: fetch)
                }
                if !AvatarCacheErasure.isInProgress,
                   cacheGeneration == startedGeneration,
                   inFlightMetadata[key]?.id == loadID {
                    metadataCache.setObject(CachedMetadata(metadata), forKey: key as NSString)
                }
                return metadata
            }
            let newLoad = InFlightLoad(id: loadID, task: created, waiters: waiters)
            inFlightMetadata[key] = newLoad
            load = newLoad
        }

        defer {
            if load.waiters.removeWaiter(waiterID) {
                load.task.cancel()
            }
            if !load.waiters.hasActiveWaiters, inFlightMetadata[key]?.id == load.id {
                inFlightMetadata.removeValue(forKey: key)
            }
        }
        return try await withTaskCancellationHandler {
            try await load.task.value
        } onCancel: {
            if load.waiters.removeWaiter(waiterID) {
                load.task.cancel()
            }
            Task { @MainActor in
                if !load.waiters.hasActiveWaiters, inFlightMetadata[key]?.id == load.id {
                    inFlightMetadata.removeValue(forKey: key)
                }
            }
        }
    }

    static func imageCacheKey(for url: URL, maxPixelSize: Int, scale: CGFloat) -> String {
        "\(url.absoluteString)|\(maxPixelSize)|\(scale)"
    }

    static func image(
        for url: URL,
        maxPixelSize: Int,
        scale: CGFloat,
        fetch: @escaping ImageFetch = RemoteImageFetch.imageData(for:),
        limiter: CancellableLoadLimiter? = nil
    ) async throws -> UIImage {
        try checkLoadAllowed()
        let key = imageCacheKey(for: url, maxPixelSize: maxPixelSize, scale: scale)
        if let cached = imageCache.object(forKey: key as NSString) { return cached.image }

        let waiterID = UUID()
        let load: InFlightLoad<UIImage>
        if let existing = inFlightImages[key], existing.waiters.addWaiter(waiterID) {
            load = existing
        } else {
            let activeLimiter = limiter ?? loadLimiter
            let loadID = UUID()
            let startedGeneration = cacheGeneration
            let waiters = WaiterState(initialWaiter: waiterID)
            let created = Task {
                let image = try await withLimiter(activeLimiter) {
                    try Task.checkCancellation()
                    guard waiters.hasActiveWaiters else { throw CancellationError() }
                    return try await fetchImage(
                        for: url,
                        maxPixelSize: maxPixelSize,
                        scale: scale,
                        fetch: fetch
                    )
                }
                if !AvatarCacheErasure.isInProgress,
                   cacheGeneration == startedGeneration,
                   inFlightImages[key]?.id == loadID {
                    imageCache.setObject(
                        CachedImage(image),
                        forKey: key as NSString,
                        cost: DecodedImageCost.decodedBitmapByteCost(for: image)
                    )
                }
                return image
            }
            let newLoad = InFlightLoad(id: loadID, task: created, waiters: waiters)
            inFlightImages[key] = newLoad
            load = newLoad
        }

        defer {
            if load.waiters.removeWaiter(waiterID) {
                load.task.cancel()
            }
            if !load.waiters.hasActiveWaiters, inFlightImages[key]?.id == load.id {
                inFlightImages.removeValue(forKey: key)
            }
        }
        return try await withTaskCancellationHandler {
            try await load.task.value
        } onCancel: {
            if load.waiters.removeWaiter(waiterID) {
                load.task.cancel()
            }
            Task { @MainActor in
                if !load.waiters.hasActiveWaiters, inFlightImages[key]?.id == load.id {
                    inFlightImages.removeValue(forKey: key)
                }
            }
        }
    }

    static func clearCaches() {
        cacheGeneration &+= 1
        metadataCache.removeAllObjects()
        imageCache.removeAllObjects()
        for load in inFlightMetadata.values {
            load.waiters.cancelAll()
            load.task.cancel()
        }
        inFlightMetadata.removeAll()
        for load in inFlightImages.values {
            load.waiters.cancelAll()
            load.task.cancel()
        }
        inFlightImages.removeAll()
    }

    nonisolated static func fetchHTML(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await PinnedHTTPSFetcher.fetch(request, maximumResponseBytes: maximumHTMLBytes)
    }

    @concurrent
    nonisolated static func fetchMetadata(
        for url: URL,
        fetch: PageFetch = fetchHTML(for:)
    ) async throws -> LinkPreviewMetadata? {
        guard let validated = ContentSanitizer.imageURL(url.absoluteString) else { return nil }
        let request = RemoteImageFetch.request(for: validated, accept: acceptHeader)
        let (data, response) = try await fetch(request)
        guard let mimeType = response.mimeType?.lowercased(), htmlMIMETypes.contains(mimeType) else { return nil }
        return LinkPreviewMetadata.parse(html: data, baseURL: response.url ?? validated)
    }

    @concurrent
    nonisolated private static func fetchImage(
        for url: URL,
        maxPixelSize: Int,
        scale: CGFloat,
        fetch: ImageFetch
    ) async throws -> UIImage {
        let data = try await fetch(url)
        try Task.checkCancellation()
        guard let image = await RemoteImageDecoder.downsampledImage(
            from: data,
            maxPixelSize: maxPixelSize,
            scale: scale
        ) else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    nonisolated private static func withLimiter<Value: Sendable>(
        _ limiter: CancellableLoadLimiter,
        work: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let reservation = await limiter.acquire() else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            let value = try await work()
            await limiter.release(reservation)
            return value
        } catch {
            await limiter.release(reservation)
            throw error
        }
    }

    private static func checkLoadAllowed() throws {
        try Task.checkCancellation()
        guard !AvatarCacheErasure.isInProgress else { throw CancellationError() }
    }
}
