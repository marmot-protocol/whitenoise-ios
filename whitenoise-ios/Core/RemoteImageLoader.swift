import Foundation
import ImageIO
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// Re-validates every HTTP redirect target through the same SSRF allowlist that
/// gates the initial URL (`ProfileSanitizer.imageURL`: HTTPS + public host).
///
/// `URLSession` follows `3xx` redirects automatically, so without this delegate
/// a peer-controlled allowlisted HTTPS endpoint could `302` the fetch to
/// `http://127.0.0.1:<port>/…`, `https://[::1]/…`, or any internal/link-local
/// host — defeating the allowlist and downgrading HTTPS→HTTP. Refusing a
/// disallowed redirect (completing with `nil`) terminates the redirect chain
/// and surfaces the response of the refused hop rather than dereferencing it.
nonisolated final class RemoteImageRedirectGuard: NSObject, URLSessionTaskDelegate {
    /// A redirect target is allowed only if it independently passes the image
    /// URL allowlist (HTTPS scheme + non-private/non-loopback/non-link-local
    /// host, including legacy IPv4 and IPv4-mapped IPv6 spellings).
    static func isRedirectAllowed(to url: URL?) -> Bool {
        guard let url else { return false }
        return ProfileSanitizer.imageURL(url.absoluteString) != nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // `nil` refuses the redirect; the original task completes with the
        // redirect response instead of following it to an unvalidated host.
        completionHandler(Self.isRedirectAllowed(to: request.url) ? request : nil)
    }
}

/// Per-fetch download delegate that buffers a response in whole `Data` chunks
/// (one delegate callback per network read), enforcing a hard byte cap on the
/// running total. This replaces consuming `URLSession.bytes(for:)` one `UInt8`
/// at a time, which drove millions of async-sequence iterations per response
/// (#407): a 2 MB avatar is now a few dozen chunk appends, not ~2,000,000.
///
/// Each instance owns the state for a single task, so the continuation /
/// recorded-error storage is touched only from that task's delegate callbacks:
/// instances are not shared across tasks and `URLSession` serializes a task's
/// delegate callbacks. The per-instance state still lives behind a `Mutex` so
/// the class is a checked `Sendable` (the delegate reference crosses isolation
/// domains) without resorting to `@unchecked Sendable`.
nonisolated final class BoundedDataCollector: NSObject, URLSessionDataDelegate, Sendable {
    let maximumResponseBytes: Int

    private struct State {
        var data = Data()
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var recordedError: Error?
        var didResume = false
    }
    private let state = Mutex(State())

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    var data: Data {
        state.withLock { $0.data }
    }

    /// Pure, byte-cap decision point (#407). Appends the whole `chunk` in a
    /// single `Data.append(_:)` only if it fits within `maximumResponseBytes`;
    /// returns `false` WITHOUT appending when it would exceed the cap. Never
    /// iterates byte-by-byte.
    func appendWithinLimit(_ chunk: Data) -> Bool {
        state.withLock { state in
            guard state.data.count + chunk.count <= maximumResponseBytes else { return false }
            state.data.append(chunk)
            return true
        }
    }

    /// Stores the continuation that `didCompleteWithError` resumes. Set before
    /// `task.resume()`.
    func setContinuation(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            state.withLock { $0.recordedError = URLError(.badServerResponse) }
            completionHandler(.cancel)
            return
        }

        if response.expectedContentLength > Int64(maximumResponseBytes) {
            state.withLock { $0.recordedError = URLError(.dataLengthExceedsMaximum) }
            completionHandler(.cancel)
            return
        }

        if response.expectedContentLength > 0 {
            let reserve = Int(min(response.expectedContentLength, Int64(maximumResponseBytes)))
            state.withLock { $0.data.reserveCapacity(reserve) }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard appendWithinLimit(data) else {
            state.withLock { $0.recordedError = URLError(.dataLengthExceedsMaximum) }
            dataTask.cancel()
            return
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Resolve the resume decision under the lock, but resume the continuation
        // outside it so no caller code runs while the mutex is held.
        let pending: (continuation: CheckedContinuation<(Data, URLResponse), Error>, recordedError: Error?, data: Data)? =
            state.withLock { state in
                guard !state.didResume else { return nil }
                state.didResume = true
                guard let continuation = state.continuation else { return nil }
                state.continuation = nil
                return (continuation, state.recordedError, state.data)
            }
        guard let pending else { return }

        if let recordedError = pending.recordedError {
            pending.continuation.resume(throwing: recordedError)
            return
        }
        if let error {
            pending.continuation.resume(throwing: error)
            return
        }
        guard let response = task.response else {
            pending.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        pending.continuation.resume(returning: (pending.data, response))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Preserve the SSRF redirect allowlist even though a per-task delegate
        // is set: a per-task delegate overrides the session delegate, so the
        // redirect guard must be re-applied here.
        completionHandler(RemoteImageRedirectGuard.isRedirectAllowed(to: request.url) ? request : nil)
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

    private static let redirectGuard = RemoteImageRedirectGuard()

    private static let session = URLSession(
        configuration: ephemeralConfiguration(),
        delegate: redirectGuard,
        delegateQueue: nil
    )

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // A `BoundedDataCollector` per-task delegate receives whole `Data`
        // chunks (one callback per network read) and enforces the byte cap on
        // the running total, cancelling the task the moment it would exceed
        // `maximumResponseBytes`. The non-2xx guard, the oversized
        // `expectedContentLength` rejection, and the SSRF redirect guard all
        // live in the collector's delegate callbacks (#407).
        return try await download(request, maximumResponseBytes: maximumResponseBytes)
    }

    static func imageData(for url: URL) async throws -> Data {
        let request = request(
            for: url,
            accept: remoteImageAcceptHeader
        )
        let (data, _) = try await download(request, maximumResponseBytes: maximumImageBytes)
        return data
    }

    private static func download(
        _ request: URLRequest,
        maximumResponseBytes cap: Int
    ) async throws -> (Data, URLResponse) {
        let collector = BoundedDataCollector(maximumResponseBytes: cap)
        let task = session.dataTask(with: request)
        task.delegate = collector
        return try await withCheckedThrowingContinuation { continuation in
            collector.setContinuation(continuation)
            task.resume()
        }
    }

    static func request(for url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
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

    static func image(for url: URL, maxPixelSize: Int, scale: CGFloat) async throws -> UIImage {
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

        do {
            let data = try await imageData(for: url, keyString: failureKeyString)
            guard let image = await RemoteImageDecoder.downsampledImage(
                from: data,
                maxPixelSize: targetPixelSize,
                scale: scale
            ) else { throw URLError(.cannotDecodeContentData) }

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

    private static func imageData(for url: URL, keyString: String) async throws -> Data {
        try await imageData(for: url, keyString: keyString) { url in
            try await RemoteImageFetch.imageData(for: url)
        }
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

    #if DEBUG
    static func resetCachesForTesting() {
        cache.removeAllObjects()
        failureCache.removeAllObjects()
        inFlightTasks.removeAll()
    }

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
    #endif
}
