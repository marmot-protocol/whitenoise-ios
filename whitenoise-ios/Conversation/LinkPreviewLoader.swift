import Foundation
import UIKit

@MainActor
enum LinkPreviewLoader {
    typealias PageFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private final class CachedMetadata: NSObject {
        let metadata: LinkPreviewMetadata?

        init(_ metadata: LinkPreviewMetadata?) {
            self.metadata = metadata
        }
    }

    private struct InFlight<Value> {
        let owner: UUID
        let task: Task<Value, Error>
    }

    private final class CachedImage: NSObject {
        let image: UIImage

        init(_ image: UIImage) {
            self.image = image
        }
    }

    nonisolated static let htmlMIMETypes: Set<String> = ["text/html", "application/xhtml+xml"]
    nonisolated private static let acceptHeader = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"

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

    private static var inFlightMetadata: [String: InFlight<LinkPreviewMetadata?>] = [:]
    private static var inFlightImages: [String: InFlight<UIImage>] = [:]

    static func cachedMetadata(for url: URL) -> LinkPreviewMetadata?? {
        metadataCache.object(forKey: url.absoluteString as NSString).map(\.metadata)
    }

    static func metadata(for url: URL) async throws -> LinkPreviewMetadata? {
        try checkLoadAllowed()
        let key = url.absoluteString
        if let cached = metadataCache.object(forKey: key as NSString) { return cached.metadata }
        if let inFlight = inFlightMetadata[key] { return try await inFlight.task.value }

        let owner = UUID()
        let task = Task { try await fetchMetadata(for: url) }
        inFlightMetadata[key] = InFlight(owner: owner, task: task)
        defer { if inFlightMetadata[key]?.owner == owner { inFlightMetadata[key] = nil } }
        let metadata = try await task.value
        guard !AvatarCacheErasure.isInProgress else { throw CancellationError() }
        metadataCache.setObject(CachedMetadata(metadata), forKey: key as NSString)
        return metadata
    }

    static func imageCacheKey(for url: URL, maxPixelSize: Int, scale: CGFloat) -> String {
        "\(url.absoluteString)|\(maxPixelSize)|\(scale)"
    }

    static func image(for url: URL, maxPixelSize: Int, scale: CGFloat) async throws -> UIImage {
        try checkLoadAllowed()
        let key = imageCacheKey(for: url, maxPixelSize: maxPixelSize, scale: scale)
        if let cached = imageCache.object(forKey: key as NSString) { return cached.image }
        if let inFlight = inFlightImages[key] { return try await inFlight.task.value }

        let task = Task {
            let data = try await RemoteImageFetch.imageData(for: url)
            guard let image = await RemoteImageDecoder.downsampledImage(
                from: data,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) else { throw URLError(.cannotDecodeContentData) }
            return image
        }
        let owner = UUID()
        inFlightImages[key] = InFlight(owner: owner, task: task)
        defer { if inFlightImages[key]?.owner == owner { inFlightImages[key] = nil } }
        let image = try await task.value
        guard !AvatarCacheErasure.isInProgress else { throw CancellationError() }
        imageCache.setObject(
            CachedImage(image),
            forKey: key as NSString,
            cost: DecodedImageCost.decodedBitmapByteCost(for: image)
        )
        return image
    }

    static func clearCaches() {
        metadataCache.removeAllObjects()
        imageCache.removeAllObjects()
        inFlightMetadata.values.forEach { $0.task.cancel() }
        inFlightMetadata.removeAll()
        inFlightImages.values.forEach { $0.task.cancel() }
        inFlightImages.removeAll()
    }

    @concurrent
    nonisolated static func fetchMetadata(
        for url: URL,
        fetch: PageFetch = RemoteImageFetch.data(for:)
    ) async throws -> LinkPreviewMetadata? {
        guard let validated = ContentSanitizer.imageURL(url.absoluteString) else { return nil }
        let request = RemoteImageFetch.request(for: validated, accept: acceptHeader)
        let (data, response) = try await fetch(request)
        guard let mimeType = response.mimeType?.lowercased(), htmlMIMETypes.contains(mimeType) else { return nil }
        return LinkPreviewMetadata.parse(html: data, baseURL: response.url ?? validated)
    }

    private static func checkLoadAllowed() throws {
        try Task.checkCancellation()
        guard !AvatarCacheErasure.isInProgress else { throw CancellationError() }
    }
}
