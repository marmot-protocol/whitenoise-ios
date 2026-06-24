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
        // The image fetch buffers through the chunked `BoundedDataCollector`
        // delegate (one callback per network read), not a per-byte async loop.
        #expect(source.contains("URLSessionDataDelegate"))
        #expect(source.contains("task.delegate = collector"))
        // The image path drives the shared chunked download with its own cap.
        #expect(source.contains("download(request, maximumResponseBytes: maximumImageBytes)"))
        #expect(source.contains("BoundedDataCollector(maximumResponseBytes: cap)"))
        // The oversized-response rejection still uses the byte cap (now on the
        // collector's running total) and the same `URLError`.
        #expect(source.contains("response.expectedContentLength > Int64(maximumResponseBytes)"))
        #expect(source.contains("URLError(.dataLengthExceedsMaximum)"))
        #expect(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        #expect(source.contains("kCGImageSourceThumbnailMaxPixelSize"))
        #expect(!source.contains("UIImage(data: data)"))
    }

    @Test func remoteImageFetchDataCapsResponseBytes() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        // `data(for:)` (used by the DuckDuckGo image-search fetch) must enforce
        // the same early-abort byte cap as `imageData(for:)` via the chunked
        // `BoundedDataCollector`, not buffer an unbounded response and not walk
        // the body one `UInt8` at a time.
        #expect(source.contains("static let maximumResponseBytes ="))
        #expect(source.contains("response.expectedContentLength > Int64(maximumResponseBytes)"))
        // Running-total cap lives in the collector's pure decision helper.
        #expect(source.contains("data.count + chunk.count <= maximumResponseBytes"))
        #expect(source.contains("download(request, maximumResponseBytes: maximumResponseBytes)"))
        #expect(!source.contains("try await session.data(for: request)"))
        #expect(!source.contains("session.bytes(for: request)"))
    }

    @Test func remoteImageFetchDataRejectsNon2xxStatus() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        // Both fetch paths route through `BoundedDataCollector`, whose
        // `didReceive response` callback validates a 2xx HTTP status and
        // cancels (recording `.badServerResponse`) before any body chunk is
        // buffered. Without this, a 4xx/5xx error page (or a refused-redirect
        // response) would be handed to the DuckDuckGo image-search result
        // parser as if it were a valid search payload.
        let statusGuard = "(200..<300).contains(http.statusCode)"
        #expect(source.contains(statusGuard))

        // The status guard must precede both the oversized-length rejection and
        // the body-buffering decision so a non-2xx body is refused before any
        // bytes are admitted. All three live in the collector's response/data
        // callbacks; assert the textual ordering of the decision points.
        let collectorMarker = "didReceive response: URLResponse"
        if let bodyStart = source.range(of: collectorMarker) {
            let body = String(source[bodyStart.upperBound...])
            let guardIndex = body.range(of: statusGuard)?.lowerBound
            let capIndex = body.range(of: "response.expectedContentLength > Int64(maximumResponseBytes)")?.lowerBound
            #expect(guardIndex != nil)
            #expect(capIndex != nil)
            if let guardIndex, let capIndex {
                #expect(guardIndex < capIndex)
            }
            // Non-2xx records the badServerResponse error and cancels.
            #expect(body.contains("URLError(.badServerResponse)"))
            #expect(body.contains("completionHandler(.cancel)"))
        } else {
            Issue.record("BoundedDataCollector didReceive-response callback not found")
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
        #expect(source.contains("cost: DecodedImageCost.decodedBitmapByteCost(for: image)"))
        #expect(!source.contains("cost: data.count"))
    }

    @Test func avatarLoaderCachesFailuresAndCoalescesInFlightLoads() throws {
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        // Regression for #404: failed avatar loads must not re-fetch on every
        // relayout, and simultaneous rows for the same URL should share a
        // single network task before size-specific decode.
        #expect(source.contains("private static let failureCacheTTL: TimeInterval"))
        #expect(source.contains("NSCache<NSString, CachedFailure>"))
        #expect(source.contains("failureCacheKey(for: url)"))
        #expect(source.contains("failureCache.object(forKey: failureKey)"))
        #expect(source.contains("failureCache.setObject("))
        #expect(source.contains("Date().addingTimeInterval(failureCacheTTL)"))
        #expect(source.contains("private static var inFlightTasks: [String: Task<Data, Error>] = [:]"))
        #expect(source.contains("if let inFlightTask = inFlightTasks[keyString]"))
        #expect(source.contains("inFlightTasks[keyString] = task"))
        #expect(source.contains("inFlightTasks[keyString] = nil"))
    }

    @Test func avatarLoaderCacheCostExceedsCompressedBytesForHighlyCompressibleImage() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        let image = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let compressedData = try #require(image.pngData())

        let cost = DecodedImageCost.decodedBitmapByteCost(for: image)

        #expect(cost == 64 * 64 * 4)
        #expect(cost > compressedData.count)
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

    @Test func remoteImageFetchUsesChunkedDelegateNotPerByteLoop() throws {
        // Regression for #407: both `data(for:)` and `imageData(for:)` must
        // download through a `URLSessionDataDelegate` that receives whole `Data`
        // chunks (one callback per network read) and enforce the byte cap on the
        // running total. A per-byte `URLSession.AsyncBytes` loop walks a 2 MB
        // avatar in ~2,000,000 async iterations — a remote-amplification CPU
        // lever — which the chunked delegate eliminates.
        let source = try sourceString("darkmatter-ios/Core/RemoteImageLoader.swift")

        // No per-byte async loop or scalar append remains on any fetch path.
        #expect(!source.contains("for try await byte in bytes"))
        #expect(!source.contains("data.append(byte)"))
        #expect(!source.contains("chunk.append(byte)"))
        #expect(!source.contains("session.bytes(for: request)"))

        // The chunked delegate exists and receives whole `Data` chunks via the
        // `didReceive data:` callback, routing them through the pure cap helper.
        #expect(source.contains("URLSessionDataDelegate"))
        #expect(source.contains("didReceive data: Data"))
        #expect(source.contains("func appendWithinLimit(_ chunk: Data) -> Bool"))
        #expect(source.contains("task.delegate = collector"))
    }

    @Test func boundedDataCollectorRejectsChunkThatExceedsCap() {
        // Behavioral coverage of the pure byte-cap decision point (#407): the
        // collector appends whole chunks only when they fit, never partially,
        // and accepts a chunk that lands exactly on the cap boundary.
        let collector = BoundedDataCollector(maximumResponseBytes: 10)

        #expect(collector.appendWithinLimit(Data(repeating: 0xAB, count: 6)))
        #expect(collector.data.count == 6)

        // 6 + 6 = 12 > 10: rejected without partially appending.
        #expect(!collector.appendWithinLimit(Data(repeating: 0xCD, count: 6)))
        #expect(collector.data.count == 6)

        // 6 + 4 = 10: exactly the cap, allowed.
        #expect(collector.appendWithinLimit(Data(repeating: 0xEF, count: 4)))
        #expect(collector.data.count == 10)
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
