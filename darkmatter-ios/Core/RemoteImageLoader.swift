import Foundation
import ImageIO
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
        let (bytes, response) = try await session.bytes(for: request)

        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(min(response.expectedContentLength, Int64(maximumResponseBytes))))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return (data, response)
    }

    static func imageData(for url: URL) async throws -> Data {
        let request = request(
            for: url,
            accept: remoteImageAcceptHeader
        )
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw URLError(.badServerResponse) }

        if response.expectedContentLength > Int64(maximumImageBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(min(response.expectedContentLength, Int64(maximumImageBytes))))
        }
        for try await byte in bytes {
            guard data.count < maximumImageBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
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
    private struct SendableImage: @unchecked Sendable {
        let image: UIImage
    }

    static func isAllowedRemoteImageType(_ typeIdentifier: CFString?) -> Bool {
        guard let typeIdentifier,
              let type = UTType(typeIdentifier as String)
        else { return false }
        return type.conforms(to: .image) && !type.conforms(to: UTType.svg)
    }

    static func downsampledImage(from data: Data, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        let targetPixelSize = max(maxPixelSize, 1)
        let imageScale = max(scale, 1)
        let decoded = await Task.detached(priority: .utility) { () -> SendableImage? in
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
            return SendableImage(image: UIImage(cgImage: cgImage, scale: imageScale, orientation: .up))
        }.value
        return decoded?.image
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

    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    static func image(for url: URL, maxPixelSize: Int, scale: CGFloat) async throws -> UIImage {
        let targetPixelSize = max(maxPixelSize, 1)
        let key = cacheKey(for: url, maxPixelSize: targetPixelSize)
        if let cached = cache.object(forKey: key)?.image {
            return cached
        }

        let data = try await RemoteImageFetch.imageData(for: url)
        guard let image = await RemoteImageDecoder.downsampledImage(
            from: data,
            maxPixelSize: targetPixelSize,
            scale: scale
        ) else { throw URLError(.cannotDecodeContentData) }

        cache.setObject(CachedImage(image: image), forKey: key, cost: data.count)
        return image
    }

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString):\(maxPixelSize)" as NSString
    }
}
