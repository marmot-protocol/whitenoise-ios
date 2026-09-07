import CryptoKit
import Foundation
import ImageIO
import OSLog
import UIKit
import UniformTypeIdentifiers

actor CancellableLoadLimiter {
    private struct Waiter {
        let id: UUID
        let priority: Int
        let sequence: UInt64
    }

    private let maximumConcurrentLoads: Int
    private var reservations: Set<UUID> = []
    private var waiterOrder: [Waiter] = []
    private var waiters: [UUID: CheckedContinuation<UUID?, Never>] = [:]
    private var nextSequence: UInt64 = 0

    init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
    }

    func acquire(priority: Int = 0) async -> UUID? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if reservations.count < maximumConcurrentLoads {
                    let reservation = UUID()
                    reservations.insert(reservation)
                    continuation.resume(returning: reservation)
                } else {
                    waiterOrder.append(Waiter(
                        id: waiterID,
                        priority: priority,
                        sequence: nextSequence
                    ))
                    nextSequence &+= 1
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func release(_ reservation: UUID) {
        guard reservations.remove(reservation) != nil else { return }
        resumeNextWaiter()
    }

    func snapshot() -> (active: Int, waiting: Int) {
        (reservations.count, waiters.count)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        waiterOrder.removeAll { $0.id == waiterID }
        continuation.resume(returning: nil)
    }

    private func resumeNextWaiter() {
        while let index = waiterOrder.indices.max(by: { lhs, rhs in
            let left = waiterOrder[lhs]
            let right = waiterOrder[rhs]
            if left.priority != right.priority {
                return left.priority < right.priority
            }
            return left.sequence > right.sequence
        }) {
            let waiter = waiterOrder.remove(at: index)
            guard let continuation = waiters.removeValue(forKey: waiter.id) else { continue }
            let reservation = UUID()
            reservations.insert(reservation)
            continuation.resume(returning: reservation)
            return
        }
    }
}

nonisolated enum RemoteImageFetch {
    static let maximumImageBytes = 2 * 1024 * 1024
    /// Byte cap for non-image responses (e.g. the DuckDuckGo image-search
    /// JSON/HTML fetched via `data(for:)`). Mirrors `maximumImageBytes` so a
    /// hostile/oversized search response cannot be buffered unbounded into
    /// memory. Larger than `maximumImageBytes` because a search payload can
    /// legitimately exceed a single thumbnail's size.
    static let maximumResponseBytes = 8 * 1024 * 1024
    static let remoteImageAcceptHeader = [
        "image/avif",
        "image/webp",
        "image/apng",
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/heic",
        "image/heif",
        "*/*;q=0.8",
    ].joined(separator: ",")

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // The pinned transport receives whole network chunks and rejects the
        // response as soon as headers plus body exceed the configured cap.
        return try await download(request, maximumResponseBytes: maximumResponseBytes)
    }

    static func imageData(for url: URL) async throws -> Data {
        // Self-enforcing chokepoint: re-validate at the egress instead of
        // trusting every caller to have pre-sanitized. The redirect guard only
        // re-checks hops after the first; the first hop must pass the same
        // allowlist.
        guard let validated = ContentSanitizer.imageURL(url.absoluteString) else {
            throw PinnedHTTPSFetcher.FetchError.invalidRequest
        }
        let request = request(
            for: validated,
            accept: remoteImageAcceptHeader
        )
        let (data, _) = try await download(request, maximumResponseBytes: maximumImageBytes)
        return data
    }

    private static func download(
        _ request: URLRequest,
        maximumResponseBytes cap: Int
    ) async throws -> (Data, URLResponse) {
        // Resolve exactly once and connect to that validated numeric address.
        // Keeping the original host only for HTTP Host and TLS SNI closes the
        // DNS-rebinding gap between a preflight lookup and URLSession's lookup.
        try await PinnedHTTPSFetcher.fetch(request, maximumResponseBytes: cap)
    }

    static func request(for url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

}

nonisolated enum RemoteImageDecoder {
    static func isAllowedRemoteImageType(_ typeIdentifier: CFString?) -> Bool {
        guard let typeIdentifier,
              let type = UTType(typeIdentifier as String)
        else { return false }
        return type.conforms(to: .image) && !type.conforms(to: UTType.svg)
    }

    static func downsampledImage(from data: Data, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        let targetPixelSize = max(maxPixelSize, 1)
        let imageScale = max(scale, 1)
        return await Task.detached(priority: .utility) { () -> UIImage? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }
            guard Self.isAllowedRemoteImageType(CGImageSourceGetType(source)) else {
                return nil
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
            ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }
            return UIImage(cgImage: cgImage, scale: imageScale, orientation: .up)
        }.value
    }
}

nonisolated enum DecodedImageCost {
    static func decodedBitmapByteCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            let cost = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
            return cost.overflow ? Int.max : max(1, cost.partialValue)
        }
        let pixelWidth = max(1, Int(ceil(image.size.width * image.scale)))
        let pixelHeight = max(1, Int(ceil(image.size.height * image.scale)))
        let pixels = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !pixels.overflow else { return Int.max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return bytes.overflow ? Int.max : max(1, bytes.partialValue)
    }
}

actor RemoteAvatarDiskCache {
    static let shared = RemoteAvatarDiskCache()
    static let groupShared = RemoteAvatarDiskCache(
        directoryName: "GroupAvatars",
        maximumBytes: 75 * 1024 * 1024,
        maximumEntryBytes: 10 * 1024 * 1024,
        maximumAge: 30 * 24 * 60 * 60
    )
    static let groupThumbnailShared = RemoteAvatarDiskCache(
        directoryName: "GroupAvatarThumbnails",
        maximumBytes: 50 * 1024 * 1024,
        maximumEntryBytes: 2 * 1024 * 1024,
        maximumAge: 30 * 24 * 60 * 60
    )

    private let directoryURL: URL
    private let maximumBytes: Int
    private let maximumEntryBytes: Int
    private let maximumAge: TimeInterval

    init(
        directoryURL: URL? = nil,
        directoryName: String = "ProfileAvatars",
        maximumBytes: Int = 50 * 1024 * 1024,
        maximumEntryBytes: Int = RemoteImageFetch.maximumImageBytes,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        let cacheRoot = directoryURL
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directoryURL = cacheRoot.appendingPathComponent(directoryName, isDirectory: true)
        self.maximumBytes = maximumBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumAge = maximumAge
    }

    func data(for url: URL, now: Date = Date()) -> Data? {
        data(forKey: url.absoluteString, now: now)
    }

    func data(forKey key: String, now: Date = Date()) -> Data? {
        guard prepareDirectory() else { return nil }
        let fileURL = cachedFileURL(forKey: key)
        do {
            let values = try fileURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= maximumEntryBytes
            else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            if let modifiedAt = values.contentModificationDate,
               now.timeIntervalSince(modifiedAt) > maximumAge {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= maximumEntryBytes else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            // The modification date doubles as a bounded least-recently-used
            // signal. Touch only after a complete, size-checked read.
            try? FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: fileURL.path
            )
            return data
        } catch {
            return nil
        }
    }

    func store(_ data: Data, for url: URL, now: Date = Date()) {
        store(data, forKey: url.absoluteString, now: now)
    }

    func store(_ data: Data, forKey key: String, now: Date = Date()) {
        guard !data.isEmpty,
              data.count <= maximumEntryBytes,
              prepareDirectory()
        else { return }

        let fileURL = cachedFileURL(forKey: key)
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [
                    .protectionKey: FileProtectionType.complete,
                    .modificationDate: now,
                ],
                ofItemAtPath: fileURL.path
            )
            pruneIfNeeded()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectoryURL = directoryURL
            try? mutableDirectoryURL.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    private func cachedFileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    private func pruneIfNeeded() {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, modifiedAt: Date, size: Int)] = []
        var totalBytes = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            totalBytes += size
            entries.append((
                url: file,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                size: size
            ))
        }

        guard totalBytes > maximumBytes else { return }
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try? FileManager.default.removeItem(at: entry.url)
            totalBytes -= entry.size
            if totalBytes <= maximumBytes { break }
        }
    }

    #if DEBUG
    func removeAllForTesting() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func cachedFileExistsForTesting(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: cachedFileURL(forKey: url.absoluteString).path)
    }

    func cachedFileExistsForTesting(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedFileURL(forKey: key).path)
    }
    #endif
}

@MainActor
enum RemoteAvatarImageLoader {
    private final class CachedImage: NSObject {
        let image: UIImage

        init(image: UIImage) {
            self.image = image
        }
    }

    private final class CachedFailure: NSObject {
        let error: Error
        let expiresAt: Date

        init(error: Error, expiresAt: Date) {
            self.error = error
            self.expiresAt = expiresAt
        }

        func isExpired(now: Date = Date()) -> Bool {
            now >= expiresAt
        }
    }

    /// Short negative-cache window: long enough to dampen layout/scroll retry
    /// storms, short enough that a transiently broken avatar can recover soon.
    private static let failureCacheTTL: TimeInterval = 60
    /// Bound peer-controlled bad URL churn independently from decoded-image cost.
    private static let failureCacheCountLimit = 500

    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private static let failureCache: NSCache<NSString, CachedFailure> = {
        let cache = NSCache<NSString, CachedFailure>()
        cache.countLimit = failureCacheCountLimit
        return cache
    }()

    private static var inFlightTasks: [String: Task<Data, Error>] = [:]
    private static var inFlightImageTasks: [String: Task<UIImage, Error>] = [:]
    private static let cacheLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "avatar-cache"
    )

    static func image(
        for url: URL,
        maxPixelSize: Int,
        scale: CGFloat,
        fetch: @escaping @Sendable (URL) async throws -> Data = RemoteImageFetch.imageData
    ) async throws -> UIImage {
        let targetPixelSize = max(maxPixelSize, 1)
        let key = cacheKey(for: url, maxPixelSize: targetPixelSize)
        let failureKey = failureCacheKey(for: url)
        let failureKeyString = failureKey as String
        if let cached = cache.object(forKey: key)?.image {
            return cached
        }

        if let cachedFailure = cachedFailureError(for: failureKey) {
            throw cachedFailure
        }

        let imageTaskKey = key as String
        if let task = inFlightImageTasks[imageTaskKey] {
            return try await task.value
        }

        let task = Task { @MainActor in
            let data = try await cachedImageData(for: url, keyString: failureKeyString, fetch: fetch)
            guard let image = await RemoteImageDecoder.downsampledImage(
                from: data,
                maxPixelSize: targetPixelSize,
                scale: scale
            ) else { throw URLError(.cannotDecodeContentData) }
            return image
        }
        inFlightImageTasks[imageTaskKey] = task
        defer { inFlightImageTasks[imageTaskKey] = nil }
        do {
            let image = try await task.value
            guard !task.isCancelled else { throw CancellationError() }

            failureCache.removeObject(forKey: failureKey)
            cache.setObject(
                CachedImage(image: image),
                forKey: key,
                cost: DecodedImageCost.decodedBitmapByteCost(for: image)
            )
            return image
        } catch {
            cacheFailure(error, for: failureKey)
            throw error
        }
    }

    private static func cachedImageData(
        for url: URL,
        keyString: String,
        fetch: @escaping @Sendable (URL) async throws -> Data
    ) async throws -> Data {
        if let cached = await RemoteAvatarDiskCache.shared.data(for: url) {
            cacheLog.debug("disk_hit bytes=\(cached.count, privacy: .public)")
            return cached
        }

        let startedAt = ContinuousClock.now
        let data = try await imageData(for: url, keyString: keyString, fetch: fetch)
        try Task.checkCancellation()
        await RemoteAvatarDiskCache.shared.store(data, for: url)
        cacheLog.debug(
            "network_fetch bytes=\(data.count, privacy: .public) duration_ms=\(elapsedMilliseconds(since: startedAt), format: .fixed(precision: 0), privacy: .public)"
        )
        return data
    }

    private static func imageData(
        for url: URL,
        keyString: String,
        fetch: @escaping @Sendable (URL) async throws -> Data
    ) async throws -> Data {
        if let inFlightTask = inFlightTasks[keyString] {
            // A just-completed task may still be present until its owner resumes
            // and clears the slot; reusing that result is safe and still avoids
            // a redundant fetch for simultaneous rows.
            return try await inFlightTask.value
        }

        let task = Task {
            try await fetch(url)
        }
        inFlightTasks[keyString] = task
        defer { inFlightTasks[keyString] = nil }
        return try await task.value
    }

    private static func cachedFailureError(for key: NSString, now: Date = Date()) -> Error? {
        guard let cachedFailure = failureCache.object(forKey: key) else { return nil }
        if cachedFailure.isExpired(now: now) {
            failureCache.removeObject(forKey: key)
            return nil
        }
        return cachedFailure.error
    }

    private static func cacheFailure(_ error: Error, for key: NSString, now: Date = Date()) {
        guard shouldCacheFailure(error) else { return }
        failureCache.setObject(
            CachedFailure(error: error, expiresAt: now.addingTimeInterval(failureCacheTTL)),
            forKey: key
        )
    }

    private static func shouldCacheFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if (error as? URLError)?.code == .cancelled { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return false }
        return true
    }

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString):\(maxPixelSize)" as NSString
    }

    private static func failureCacheKey(for url: URL) -> NSString {
        url.absoluteString as NSString
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }

    static func clearCachesAndDrain() async {
        let dataTasks = Array(inFlightTasks.values)
        let imageTasks = Array(inFlightImageTasks.values)
        clearCaches()
        for task in dataTasks { _ = await task.result }
        for task in imageTasks { _ = await task.result }
        clearCaches()
    }

    static func clearCaches() {
        cache.removeAllObjects()
        failureCache.removeAllObjects()
        inFlightTasks.values.forEach { $0.cancel() }
        inFlightTasks.removeAll()
        inFlightImageTasks.values.forEach { $0.cancel() }
        inFlightImageTasks.removeAll()
    }

    #if DEBUG
    static func resetCachesForTesting() { clearCaches() }

    static func cacheFailureForTesting(_ error: Error, for url: URL, now: Date = Date()) {
        cacheFailure(error, for: failureCacheKey(for: url), now: now)
    }

    static func cachedFailureForTesting(for url: URL, now: Date = Date()) -> Error? {
        cachedFailureError(for: failureCacheKey(for: url), now: now)
    }

    static func shouldCacheFailureForTesting(_ error: Error) -> Bool {
        shouldCacheFailure(error)
    }

    static func imageDataForTesting(
        for url: URL,
        keyString: String,
        fetch: @escaping @Sendable (URL) async throws -> Data
    ) async throws -> Data {
        try await imageData(for: url, keyString: keyString, fetch: fetch)
    }

    static func cachedImageForTesting(for url: URL, maxPixelSize: Int) -> UIImage? {
        cachedImage(for: url, maxPixelSize: maxPixelSize)
    }
    #endif

    static func cachedImage(for url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: cacheKey(for: url, maxPixelSize: max(maxPixelSize, 1)))?.image
    }
}
