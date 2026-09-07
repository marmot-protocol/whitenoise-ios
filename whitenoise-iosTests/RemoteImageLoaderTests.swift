import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct RemoteImageLoaderTests {
    @Test func imageDataRejectsUnsanitizedURLsAtTheEgress() async throws {
        // Self-enforcing chokepoint: a caller that skips ContentSanitizer must
        // not reach the network on the first hop.
        let privateHost = try #require(URL(string: "https://127.0.0.1/a.png"))
        await #expect(throws: PinnedHTTPSFetcher.FetchError.invalidRequest) {
            try await RemoteImageFetch.imageData(for: privateHost)
        }
        let plainHTTP = try #require(URL(string: "http://example.com/a.png"))
        await #expect(throws: PinnedHTTPSFetcher.FetchError.invalidRequest) {
            try await RemoteImageFetch.imageData(for: plainHTTP)
        }
        let oddPort = try #require(URL(string: "https://example.com:8443/a.png"))
        await #expect(throws: PinnedHTTPSFetcher.FetchError.invalidRequest) {
            try await RemoteImageFetch.imageData(for: oddPort)
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

    @Test func avatarLoaderCoalescesDecodeWorkAndPublishesMemoryHit() async throws {
        let url = try #require(URL(string: "https://example.com/\(UUID().uuidString).png"))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let source = renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let data = try #require(source.pngData())
        let probe = RemoteImageFetchProbe(data: data)
        RemoteAvatarImageLoader.resetCachesForTesting()
        defer { RemoteAvatarImageLoader.resetCachesForTesting() }

        let first = Task { @MainActor in
            try await RemoteAvatarImageLoader.image(
                for: url,
                maxPixelSize: 56,
                scale: 1,
                fetch: { _ in await probe.fetch() }
            )
        }
        await probe.waitUntilStarted()
        let second = Task { @MainActor in
            try await RemoteAvatarImageLoader.image(
                for: url,
                maxPixelSize: 56,
                scale: 1,
                fetch: { _ in await probe.fetch() }
            )
        }
        for _ in 0..<10 { await Task.yield() }

        await probe.release()
        _ = try await first.value
        _ = try await second.value

        #expect(await probe.callCount() == 1)
        #expect(RemoteAvatarImageLoader.cachedImageForTesting(for: url, maxPixelSize: 56) != nil)
    }

    @Test func erasureDrainsFetchesWithoutRepopulatingAvatarCaches() async throws {
        let url = try #require(URL(string: "https://example.com/\(UUID().uuidString).png"))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let data = try #require(renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        let probe = RemoteImageFetchProbe(data: data)
        let request = Task {
            try await RemoteAvatarImageLoader.image(for: url, maxPixelSize: 8, scale: 1,
                                                    fetch: { _ in await probe.fetch() })
        }
        await probe.waitUntilStarted()
        var drained = false
        let cleanup = Task {
            await RemoteAvatarImageLoader.clearCachesAndDrain()
            drained = true
        }
        for _ in 0..<1_000 where !RemoteAvatarImageLoader.isDrainingForTesting { await Task.yield() }
        #expect(RemoteAvatarImageLoader.isDrainingForTesting)
        #expect(!drained)
        let arrivingURL = try #require(URL(string: "https://example.com/\(UUID()).png"))
        await #expect(throws: CancellationError.self) {
            try await RemoteAvatarImageLoader.image(for: arrivingURL, maxPixelSize: 8, scale: 1, fetch: { _ in data })
        }
        var secondDrainFinished = false
        let secondCleanup = Task {
            await RemoteAvatarImageLoader.clearCachesAndDrain()
            secondDrainFinished = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!secondDrainFinished)
        await probe.release()
        await cleanup.value
        await secondCleanup.value
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(RemoteAvatarImageLoader.cachedImageForTesting(for: url, maxPixelSize: 8) == nil)
        #expect(!(await RemoteAvatarDiskCache.shared.cachedFileExistsForTesting(for: url)))
        #expect(!(await RemoteAvatarDiskCache.shared.cachedFileExistsForTesting(for: arrivingURL)))
        _ = try await RemoteAvatarImageLoader.image(for: arrivingURL, maxPixelSize: 8, scale: 1, fetch: { _ in data })
    }

    @Test func groupAvatarDrainBlocksNewLoadsAndSeedsUntilDecodeSettles() async throws {
        let client = try MarmotClient.testClient()
        let request = GroupAvatarImageRequest(accountRef: "drain-\(UUID())", groupIdHex: "group",
                                              imageHashHex: "image", maxPixelSize: 8)
        let data = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        let probe = RemoteImageFetchProbe(data: data)
        GroupAvatarImageLoader.beforeDecodeForTesting = { _ = await probe.fetch() }
        defer { GroupAvatarImageLoader.beforeDecodeForTesting = nil }
        GroupAvatarImageLoader.seed(data: data, accountRef: request.accountRef,
                                   groupIdHex: request.groupIdHex, replacingImageHashHex: nil)
        let load = Task {
            try await GroupAvatarImageLoader.image(request: request, scale: 1, priority: .foreground, client: client)
        }
        await probe.waitUntilStarted()
        let cleanup = Task { await GroupAvatarImageLoader.clearCachesAndDrain() }
        for _ in 0..<1_000 where !GroupAvatarImageLoader.isDrainingForTesting { await Task.yield() }
        #expect(GroupAvatarImageLoader.isDrainingForTesting)
        GroupAvatarImageLoader.seed(data: data, accountRef: request.accountRef,
                                   groupIdHex: request.groupIdHex, replacingImageHashHex: nil)
        #expect(!GroupAvatarImageLoader.hasSeedForTesting(accountRef: request.accountRef, groupIdHex: request.groupIdHex))
        await #expect(throws: CancellationError.self) {
            try await GroupAvatarImageLoader.image(request: request, scale: 1, priority: .foreground, client: client)
        }
        await probe.release()
        await cleanup.value
        await #expect(throws: CancellationError.self) { _ = try await load.value }
        #expect(GroupAvatarImageLoader.cachedImage(for: request) == nil)
        let dataKey = GroupAvatarCacheKey.rawData(accountRef: request.accountRef, imageHashHex: request.imageHashHex)
        #expect(!(await RemoteAvatarDiskCache.groupShared.cachedFileExistsForTesting(forKey: dataKey)))
        GroupAvatarImageLoader.beforeDecodeForTesting = nil
        GroupAvatarImageLoader.seed(data: data, accountRef: request.accountRef,
                                   groupIdHex: request.groupIdHex, replacingImageHashHex: nil)
        _ = try await GroupAvatarImageLoader.image(request: request, scale: 1, priority: .foreground, client: client)
        await GroupAvatarImageLoader.clearCachesAndDrain()
    }

    @Test func erasureKeepsBothLoadersBlockedAfterTheirIndividualDrains() async throws {
        AvatarCacheErasure.begin()
        defer { AvatarCacheErasure.end() }
        await RemoteAvatarImageLoader.clearCachesAndDrain()
        await GroupAvatarImageLoader.clearCachesAndDrain()
        let url = try #require(URL(string: "https://example.com/\(UUID()).png"))
        await #expect(throws: CancellationError.self) {
            try await RemoteAvatarImageLoader.image(for: url, maxPixelSize: 8, scale: 1, fetch: { _ in Data() })
        }
        let client = try MarmotClient.testClient()
        let request = GroupAvatarImageRequest(accountRef: "erasure", groupIdHex: "group", imageHashHex: "hash", maxPixelSize: 8)
        await #expect(throws: CancellationError.self) {
            try await GroupAvatarImageLoader.image(request: request, scale: 1, priority: .foreground, client: client)
        }
    }

    @Test func avatarDiskCacheSurvivesMemoryCacheResetAndExpiresOldEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAvatarDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteAvatarDiskCache(
            directoryURL: root,
            maximumBytes: 1_024,
            maximumEntryBytes: 128,
            maximumAge: 60
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.com/persisted-avatar.png"))
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let writtenAt = Date(timeIntervalSince1970: 1_000)

        await cache.store(data, for: url, now: writtenAt)

        #expect(await cache.cachedFileExistsForTesting(for: url))
        #expect(await cache.data(for: url, now: writtenAt.addingTimeInterval(59)) == data)
        #expect(await cache.data(for: url, now: writtenAt.addingTimeInterval(120)) == nil)
        #expect(!(await cache.cachedFileExistsForTesting(for: url)))
    }

    @Test func avatarDiskCacheRejectsOversizedEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAvatarDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteAvatarDiskCache(
            directoryURL: root,
            maximumBytes: 1_024,
            maximumEntryBytes: 4,
            maximumAge: 60
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.com/oversized-avatar.png"))

        await cache.store(Data(repeating: 0x01, count: 5), for: url)

        #expect(await cache.data(for: url) == nil)
        #expect(!(await cache.cachedFileExistsForTesting(for: url)))
    }

    @Test func avatarDiskCacheSupportsContentAddressedGroupKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroupAvatarDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteAvatarDiskCache(
            directoryURL: root,
            directoryName: "GroupAvatars",
            maximumBytes: 1_024,
            maximumEntryBytes: 128,
            maximumAge: 60
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "account:group:image-hash"
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        await cache.store(data, forKey: key)

        #expect(await cache.cachedFileExistsForTesting(forKey: key))
        #expect(await cache.data(forKey: key) == data)
    }

    @Test func groupAvatarDiskCacheRetainsRecentlyUsedEntriesBeyondOneWeek() async {
        let key = "group-cache-retention-\(UUID().uuidString)"
        let data = Data([1, 2, 3, 4])
        let writtenAt = Date(timeIntervalSince1970: 10_000)

        await RemoteAvatarDiskCache.groupShared.store(data, forKey: key, now: writtenAt)

        #expect(await RemoteAvatarDiskCache.groupShared.data(
            forKey: key,
            now: writtenAt.addingTimeInterval(8 * 24 * 60 * 60)
        ) == data)
        #expect(await RemoteAvatarDiskCache.groupShared.data(
            forKey: key,
            now: writtenAt.addingTimeInterval(39 * 24 * 60 * 60)
        ) == nil)
    }

    @Test func groupAvatarPersistentThumbnailBypassesTheFullImageDownload() async throws {
        let accountRef = "thumbnail-account-\(UUID().uuidString)"
        let imageHashHex = UUID().uuidString
        let request = GroupAvatarImageRequest(
            accountRef: accountRef,
            groupIdHex: "group",
            imageHashHex: imageHashHex,
            maxPixelSize: 56
        )
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 56, height: 56))
        let thumbnailData = try #require(renderer.image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 56, height: 56))
        }.pngData())
        let key = GroupAvatarCacheKey.thumbnail(
            accountRef: accountRef,
            imageHashHex: imageHashHex,
            maxPixelSize: request.maxPixelSize
        )
        GroupAvatarImageLoader.resetForTesting()
        defer { GroupAvatarImageLoader.resetForTesting() }

        await RemoteAvatarDiskCache.groupThumbnailShared.store(thumbnailData, forKey: key)
        let image = try await GroupAvatarImageLoader.image(
            request: request,
            scale: 1,
            priority: .chatList,
            client: try MarmotClient.testClient()
        )

        #expect(image.cgImage?.width == 56)
        #expect(image.cgImage?.height == 56)
    }

    @Test func groupAvatarLoaderPromotesTheLegacyGroupScopedDiskEntry() async throws {
        let accountRef = "legacy-account-\(UUID().uuidString)"
        let groupIdHex = "legacy-group"
        let imageHashHex = UUID().uuidString
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let imageData = try #require(renderer.image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }.jpegData(compressionQuality: 0.8))
        let legacyKey = GroupAvatarCacheKey.legacyRawData(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            imageHashHex: imageHashHex
        )
        let contentKey = GroupAvatarCacheKey.rawData(
            accountRef: accountRef,
            imageHashHex: imageHashHex
        )
        GroupAvatarImageLoader.resetForTesting()
        defer { GroupAvatarImageLoader.resetForTesting() }
        await RemoteAvatarDiskCache.groupShared.store(imageData, forKey: legacyKey)

        _ = try await GroupAvatarImageLoader.image(
            request: GroupAvatarImageRequest(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                imageHashHex: imageHashHex,
                maxPixelSize: 56
            ),
            scale: 1,
            priority: .chatList,
            client: try MarmotClient.testClient()
        )

        #expect(await RemoteAvatarDiskCache.groupShared.data(forKey: contentKey) == imageData)
    }

    @Test func groupAvatarSeedWaitsForTheReplacementHashAndAvoidsNetwork() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let imageData = try #require(renderer.image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }.jpegData(compressionQuality: 0.8))
        let accountRef = "seed-account-\(UUID().uuidString)"
        let groupIdHex = "seed-group"
        GroupAvatarImageLoader.resetForTesting()
        defer { GroupAvatarImageLoader.resetForTesting() }
        GroupAvatarImageLoader.seed(
            data: imageData,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            replacingImageHashHex: "old-hash"
        )

        #expect(!GroupAvatarCacheKey.shouldUseSeed(
            replacingImageHashHex: "old-hash",
            requestedImageHashHex: "old-hash"
        ))
        #expect(GroupAvatarImageLoader.hasSeedForTesting(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        ))

        let loaded = try await GroupAvatarImageLoader.image(
            request: GroupAvatarImageRequest(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                imageHashHex: "new-hash",
                maxPixelSize: 56
            ),
            scale: 1,
            priority: .foreground,
            client: try MarmotClient.testClient()
        )

        #expect(loaded.cgImage?.width == 56)
        #expect(!GroupAvatarImageLoader.hasSeedForTesting(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        ))
    }

    @Test func groupAvatarRawCacheKeyIsContentAddressedAndAccountScoped() {
        let first = GroupAvatarCacheKey.rawData(accountRef: "account", imageHashHex: "hash")
        let second = GroupAvatarCacheKey.rawData(accountRef: "account", imageHashHex: "hash")
        let otherAccount = GroupAvatarCacheKey.rawData(accountRef: "other", imageHashHex: "hash")

        #expect(first == second)
        #expect(first != otherAccount)
    }

    @Test func prioritizedLimiterAdmitsForegroundWorkBeforeQueuedListWork() async throws {
        let limiter = CancellableLoadLimiter(maximumConcurrentLoads: 1)
        let first = try #require(await limiter.acquire())
        let order = LoadOrderProbe()
        let listTask = Task {
            guard let reservation = await limiter.acquire(priority: GroupAvatarLoadPriority.chatList.rawValue) else {
                return
            }
            await order.append("list")
            await limiter.release(reservation)
        }
        while await limiter.snapshot().waiting < 1 { await Task.yield() }
        let foregroundTask = Task {
            guard let reservation = await limiter.acquire(priority: GroupAvatarLoadPriority.foreground.rawValue) else {
                return
            }
            await order.append("foreground")
            await limiter.release(reservation)
        }
        while await limiter.snapshot().waiting < 2 { await Task.yield() }

        await limiter.release(first)
        await listTask.value
        await foregroundTask.value

        #expect(await order.values() == ["foreground", "list"])
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

}

private actor LoadOrderProbe {
    private var entries: [String] = []

    func append(_ value: String) {
        entries.append(value)
    }

    func values() -> [String] {
        entries
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
