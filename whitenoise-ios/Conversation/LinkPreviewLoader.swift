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

    /// Reference-counted in-flight load. Individual callers cancel immediately
    /// without cancelling peers sharing the same URL; the underlying fetch task
    /// is cancelled as soon as the last waiter cancels.
    @MainActor
    private final class SharedInFlight<Value: Sendable> {
        // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
        // https://github.com/swiftlang/swift/issues/88036
        nonisolated deinit {}

        let id = UUID()
        private var task: Task<Void, Never>?
        private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
        private var outcome: Result<Value, Error>?
        private let onClear: @MainActor () -> Void
        private let onSuccess: @MainActor (Value) -> Void

        init(
            onClear: @escaping @MainActor () -> Void,
            onSuccess: @escaping @MainActor (Value) -> Void
        ) {
            self.onClear = onClear
            self.onSuccess = onSuccess
        }

        func start(_ operation: @escaping @Sendable () async throws -> Value) {
            task = Task { @MainActor [weak self] in
                do {
                    let value = try await operation()
                    guard !Task.isCancelled else {
                        self?.finish(with: .failure(CancellationError()))
                        return
                    }
                    self?.finish(with: .success(value))
                } catch {
                    self?.finish(with: .failure(error))
                }
            }
        }

        func wait() async throws -> Value {
            try Task.checkCancellation()
            if let outcome { return try outcome.get() }
            let waiterID = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        if waiters.isEmpty, outcome == nil {
                            cancelUnderlying()
                        }
                    } else if let outcome {
                        continuation.resume(with: outcome)
                    } else {
                        waiters[waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelWaiter(waiterID)
                }
            }
        }

        func cancelAll() {
            guard outcome == nil else { return }
            outcome = .failure(CancellationError())
            task?.cancel()
            task = nil
            let pending = waiters
            waiters.removeAll()
            onClear()
            for continuation in pending.values {
                continuation.resume(throwing: CancellationError())
            }
        }

        private func cancelWaiter(_ waiterID: UUID) {
            guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
            continuation.resume(throwing: CancellationError())
            if waiters.isEmpty, outcome == nil {
                cancelUnderlying()
            }
        }

        private func cancelUnderlying() {
            outcome = .failure(CancellationError())
            task?.cancel()
            task = nil
            onClear()
        }

        private func finish(with result: Result<Value, Error>) {
            guard outcome == nil else { return }
            outcome = result
            task = nil
            let pending = waiters
            waiters.removeAll()
            onClear()
            if case .success(let value) = result {
                onSuccess(value)
            }
            for continuation in pending.values {
                continuation.resume(with: result)
            }
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

    private static var inFlightMetadata: [String: SharedInFlight<LinkPreviewMetadata?>] = [:]
    private static var inFlightImages: [String: SharedInFlight<UIImage>] = [:]
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
        if let inFlight = inFlightMetadata[key] { return try await inFlight.wait() }

        let generation = cacheGeneration
        let activeLimiter = limiter ?? loadLimiter
        var entryID = UUID()
        let entry = SharedInFlight<LinkPreviewMetadata?>(
            onClear: {
                if inFlightMetadata[key]?.id == entryID {
                    inFlightMetadata[key] = nil
                }
            },
            onSuccess: { metadata in
                guard generation == cacheGeneration, !AvatarCacheErasure.isInProgress else { return }
                metadataCache.setObject(CachedMetadata(metadata), forKey: key as NSString)
            }
        )
        entryID = entry.id
        inFlightMetadata[key] = entry
        entry.start {
            try await withLimiter(activeLimiter) {
                try await fetchMetadata(for: url, fetch: fetch)
            }
        }
        return try await entry.wait()
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
        if let inFlight = inFlightImages[key] { return try await inFlight.wait() }

        let generation = cacheGeneration
        let activeLimiter = limiter ?? loadLimiter
        var entryID = UUID()
        let entry = SharedInFlight<UIImage>(
            onClear: {
                if inFlightImages[key]?.id == entryID {
                    inFlightImages[key] = nil
                }
            },
            onSuccess: { image in
                guard generation == cacheGeneration, !AvatarCacheErasure.isInProgress else { return }
                imageCache.setObject(
                    CachedImage(image),
                    forKey: key as NSString,
                    cost: DecodedImageCost.decodedBitmapByteCost(for: image)
                )
            }
        )
        entryID = entry.id
        inFlightImages[key] = entry
        entry.start {
            try await withLimiter(activeLimiter) {
                try await fetchImage(
                    for: url,
                    maxPixelSize: maxPixelSize,
                    scale: scale,
                    fetch: fetch
                )
            }
        }
        return try await entry.wait()
    }

    static func clearCaches() {
        cacheGeneration &+= 1
        metadataCache.removeAllObjects()
        imageCache.removeAllObjects()
        let pendingMetadata = Array(inFlightMetadata.values)
        inFlightMetadata.removeAll()
        pendingMetadata.forEach { $0.cancelAll() }
        let pendingImages = Array(inFlightImages.values)
        inFlightImages.removeAll()
        pendingImages.forEach { $0.cancelAll() }
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
