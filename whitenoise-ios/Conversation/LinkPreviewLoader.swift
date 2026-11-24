import Foundation
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

    private struct InFlightLoad<Value: Sendable> {
        let task: Task<Value, Error>
        var waiters: Set<UUID>
    }

    private static var inFlightMetadata: [String: InFlightLoad<LinkPreviewMetadata?>] = [:]
    private static var inFlightImages: [String: InFlightLoad<UIImage>] = [:]

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
        let task: Task<LinkPreviewMetadata?, Error>
        if var existing = inFlightMetadata[key] {
            existing.waiters.insert(waiterID)
            inFlightMetadata[key] = existing
            task = existing.task
        } else {
            let activeLimiter = limiter ?? loadLimiter
            let created = Task {
                let metadata = try await withLimiter(activeLimiter) {
                    try await fetchMetadata(for: url, fetch: fetch)
                }
                if !AvatarCacheErasure.isInProgress {
                    metadataCache.setObject(CachedMetadata(metadata), forKey: key as NSString)
                }
                return metadata
            }
            inFlightMetadata[key] = InFlightLoad(task: created, waiters: [waiterID])
            task = created
        }

        defer { releaseMetadataWaiter(key: key, task: task, waiterID: waiterID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in
                releaseMetadataWaiter(key: key, task: task, waiterID: waiterID)
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
        let task: Task<UIImage, Error>
        if var existing = inFlightImages[key] {
            existing.waiters.insert(waiterID)
            inFlightImages[key] = existing
            task = existing.task
        } else {
            let activeLimiter = limiter ?? loadLimiter
            let created = Task {
                let image = try await withLimiter(activeLimiter) {
                    try await fetchImage(
                        for: url,
                        maxPixelSize: maxPixelSize,
                        scale: scale,
                        fetch: fetch
                    )
                }
                if !AvatarCacheErasure.isInProgress {
                    imageCache.setObject(
                        CachedImage(image),
                        forKey: key as NSString,
                        cost: DecodedImageCost.decodedBitmapByteCost(for: image)
                    )
                }
                return image
            }
            inFlightImages[key] = InFlightLoad(task: created, waiters: [waiterID])
            task = created
        }

        defer { releaseImageWaiter(key: key, task: task, waiterID: waiterID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in
                releaseImageWaiter(key: key, task: task, waiterID: waiterID)
            }
        }
    }

    private static func releaseMetadataWaiter(
        key: String,
        task: Task<LinkPreviewMetadata?, Error>,
        waiterID: UUID
    ) {
        guard var entry = inFlightMetadata[key],
              entry.task == task,
              entry.waiters.remove(waiterID) != nil
        else { return }
        if entry.waiters.isEmpty {
            inFlightMetadata.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            inFlightMetadata[key] = entry
        }
    }

    private static func releaseImageWaiter(
        key: String,
        task: Task<UIImage, Error>,
        waiterID: UUID
    ) {
        guard var entry = inFlightImages[key],
              entry.task == task,
              entry.waiters.remove(waiterID) != nil
        else { return }
        if entry.waiters.isEmpty {
            inFlightImages.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            inFlightImages[key] = entry
        }
    }

    static func clearCaches() {
        metadataCache.removeAllObjects()
        imageCache.removeAllObjects()
        inFlightMetadata.values.forEach { $0.task.cancel() }
        inFlightMetadata.removeAll()
        inFlightImages.values.forEach { $0.task.cancel() }
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
