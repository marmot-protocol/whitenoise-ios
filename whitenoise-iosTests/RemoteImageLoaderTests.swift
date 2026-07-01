import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct RemoteImageLoaderTests {
    @Test func remoteImageFetchDataRejectsNon2xxStatus() async throws {
        let url = try #require(URL(string: "https://example.com/search"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let rejected = try await responseDisposition(
            statusCode: 500,
            url: url,
            session: session,
            maximumResponseBytes: 1_000
        )
        #expect(rejected == .cancel)

        let allowed = try await responseDisposition(
            statusCode: 200,
            url: url,
            session: session,
            maximumResponseBytes: 1_000
        )
        #expect(allowed == .allow)

        let oversized = try await responseDisposition(
            statusCode: 200,
            url: url,
            session: session,
            maximumResponseBytes: 1_000,
            expectedContentLength: 5_000
        )
        #expect(oversized == .cancel)
    }

    private func responseDisposition(
        statusCode: Int,
        url: URL,
        session: URLSession,
        maximumResponseBytes: Int,
        expectedContentLength: Int? = nil
    ) async throws -> URLSession.ResponseDisposition {
        let collector = BoundedDataCollector(maximumResponseBytes: maximumResponseBytes)
        let dataTask = session.dataTask(with: url)
        let headers: [String: String]?
        if let expectedContentLength {
            headers = ["Content-Length": String(expectedContentLength)]
        } else {
            headers = nil
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
        return await withCheckedContinuation { continuation in
            collector.urlSession(session, dataTask: dataTask, didReceive: response) { disposition in
                continuation.resume(returning: disposition)
            }
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

    @Test func avatarLoaderCachesFailuresWithTTLAndPreservesError() throws {
        let url = try #require(URL(string: "https://example.com/broken-avatar.png"))
        let now = Date()
        RemoteAvatarImageLoader.resetCachesForTesting()
        defer { RemoteAvatarImageLoader.resetCachesForTesting() }

        RemoteAvatarImageLoader.cacheFailureForTesting(URLError(.badServerResponse), for: url, now: now)

        let cached = try #require(
            RemoteAvatarImageLoader.cachedFailureForTesting(
                for: url,
                now: now.addingTimeInterval(30)
            ) as? URLError
        )
        #expect(cached.code == .badServerResponse)
        #expect(
            RemoteAvatarImageLoader.cachedFailureForTesting(
                for: url,
                now: now.addingTimeInterval(61)
            ) == nil
        )
        #expect(!RemoteAvatarImageLoader.shouldCacheFailureForTesting(CancellationError()))
        #expect(!RemoteAvatarImageLoader.shouldCacheFailureForTesting(URLError(.cancelled)))
        #expect(!RemoteAvatarImageLoader.shouldCacheFailureForTesting(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
    }

    @Test func avatarLoaderCoalescesInFlightDataLoadsByURLKey() async throws {
        let url = try #require(URL(string: "https://example.com/avatar.png"))
        let data = Data([0xCA, 0xFE])
        let probe = RemoteImageFetchProbe(data: data)
        RemoteAvatarImageLoader.resetCachesForTesting()
        defer { RemoteAvatarImageLoader.resetCachesForTesting() }

        let first = Task { @MainActor in
            try await RemoteAvatarImageLoader.imageDataForTesting(
                for: url,
                keyString: url.absoluteString
            ) { _ in
                await probe.fetch()
            }
        }
        await probe.waitUntilStarted()

        let second = Task { @MainActor in
            try await RemoteAvatarImageLoader.imageDataForTesting(
                for: url,
                keyString: url.absoluteString
            ) { _ in
                await probe.fetch()
            }
        }

        // Let `second` run up to its in-flight coalescing await on the MainActor
        // before releasing the fetch. Otherwise `first` can complete and clear
        // the in-flight slot before `second` checks it, making `second` start a
        // second fetch and racing the single-fetch expectation.
        for _ in 0..<10 { await Task.yield() }

        await probe.release()
        let firstData = try await first.value
        let secondData = try await second.value

        #expect(firstData == data)
        #expect(secondData == data)
        #expect(await probe.callCount() == 1)
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
}

private actor RemoteImageFetchProbe {
    private let data: Data
    private var fetchCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(data: Data) {
        self.data = data
    }

    func fetch() async -> Data {
        fetchCount += 1
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return data
    }

    func waitUntilStarted() async {
        guard fetchCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }

    func callCount() -> Int {
        fetchCount
    }
}
