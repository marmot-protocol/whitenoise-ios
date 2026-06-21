import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import darkmatter_ios

@MainActor
struct RemoteImageLoaderTests {
    @Test func avatarBubbleDoesNotUseAsyncImageForPeerControlledURLs() throws {
        let source = try sourceString("darkmatter-ios/Chats/ChatRow.swift")

        #expect(!source.contains("AsyncImage("))
        #expect(source.contains("AvatarRemoteImage(url: pictureURL)"))
        #expect(source.contains("RemoteAvatarImageLoader.image("))
    }

    @Test func remoteImageFetchUsesEphemeralNoCookieNoCacheSession() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        #expect(source.contains("URLSessionConfiguration.ephemeral"))
        #expect(source.contains("httpCookieAcceptPolicy = .never"))
        #expect(source.contains("httpShouldSetCookies = false"))
        #expect(source.contains("requestCachePolicy = .reloadIgnoringLocalCacheData"))
        #expect(source.contains("urlCache = nil"))
        #expect(source.contains("request.cachePolicy = .reloadIgnoringLocalCacheData"))
        #expect(!source.contains("URLSession.shared"))
    }

    @Test func remoteImageFetchCapsBytesAndDecoderDownsamples() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        #expect(source.contains("static let maximumImageBytes = 2 * 1024 * 1024"))
        #expect(source.contains("session.bytes(for: request)"))
        #expect(source.contains("response.expectedContentLength > Int64(maximumImageBytes)"))
        #expect(source.contains("throw URLError(.dataLengthExceedsMaximum)"))
        #expect(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        #expect(source.contains("kCGImageSourceThumbnailMaxPixelSize"))
        #expect(!source.contains("UIImage(data: data)"))
    }

    @Test func remoteImageFetchDataCapsResponseBytes() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        // `data(for:)` (used by the DuckDuckGo image-search fetch) must stream
        // with the same early-abort byte cap as `imageData(for:)`, not buffer
        // an unbounded response via `session.data(for:)`.
        #expect(source.contains("static let maximumResponseBytes ="))
        #expect(source.contains("response.expectedContentLength > Int64(maximumResponseBytes)"))
        #expect(source.contains("data.count < maximumResponseBytes"))
        #expect(!source.contains("try await session.data(for: request)"))
    }

    @Test func remoteImageFetchDataRejectsNon2xxStatus() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        // `data(for:)` must validate a 2xx HTTP status before buffering/returning
        // the body, mirroring `imageData(for:)`. Without this, a 4xx/5xx error
        // page (or a refused-redirect response) is handed to the DuckDuckGo
        // image-search result parser as if it were a valid search payload.
        // The guard must appear twice in this file: once in `data(for:)` and
        // once in `imageData(for:)`.
        let statusGuard = "(200..<300).contains(http.statusCode)"
        let occurrences = source.components(separatedBy: statusGuard).count - 1
        #expect(occurrences >= 2)

        // The byte-cap check must come after the status guard so an error body
        // is rejected before any bytes are streamed/buffered.
        let dataFunc = "static func data(for request: URLRequest) async throws -> (Data, URLResponse) {"
        if let bodyStart = source.range(of: dataFunc) {
            let body = String(source[bodyStart.upperBound...])
            let guardIndex = body.range(of: statusGuard)?.lowerBound
            let capIndex = body.range(of: "response.expectedContentLength > Int64(maximumResponseBytes)")?.lowerBound
            #expect(guardIndex != nil)
            #expect(capIndex != nil)
            if let guardIndex, let capIndex {
                #expect(guardIndex < capIndex)
            }
        } else {
            Issue.record("data(for:) signature not found")
        }
    }

    @Test func remoteImageFetchDoesNotAdvertiseSVGContent() throws {
        let request = RemoteImageFetch.request(
            for: try #require(URL(string: "https://example.com/avatar.png")),
            accept: RemoteImageFetch.remoteImageAcceptHeader
        )
        let accept = try #require(request.value(forHTTPHeaderField: "Accept"))

        #expect(!accept.contains("image/svg+xml"))
        #expect(accept.contains("image/png"))
        #expect(accept.contains("image/jpeg"))
        #expect(accept.contains("image/webp"))
    }

    @Test func remoteImageDecoderRejectsSVGTypes() {
        #expect(RemoteImageDecoder.isAllowedRemoteImageType(UTType.png.identifier as CFString))
        #expect(RemoteImageDecoder.isAllowedRemoteImageType(UTType.jpeg.identifier as CFString))
        #expect(!RemoteImageDecoder.isAllowedRemoteImageType(UTType.svg.identifier as CFString))
        #expect(!RemoteImageDecoder.isAllowedRemoteImageType(nil))
    }

    @Test func avatarLoaderCachesDecodedImagesByURLAndPixelSize() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        #expect(source.contains("NSCache<NSString, CachedImage>"))
        #expect(source.contains("cacheKey(for: url, maxPixelSize: targetPixelSize)"))
        #expect(source.contains(#""\(url.absoluteString):\(maxPixelSize)" as NSString"#))
        #expect(source.contains("cache.setObject(CachedImage(image: image), forKey: key, cost: data.count)"))
    }

    @Test func decoderDownsamplesLargeImages() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80))
        let sourceImage = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        }
        let data = try #require(sourceImage.pngData())

        let decoded = await RemoteImageDecoder.downsampledImage(from: data, maxPixelSize: 20, scale: 1)

        let image = try #require(decoded)
        #expect(max(image.size.width, image.size.height) <= 20)
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
