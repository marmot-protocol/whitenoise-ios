import Foundation
import MarmotKit
import OSLog
import UIKit

enum GroupAvatarLoadPriority: Int {
    case chatList = 10
    case foreground = 100
}

struct GroupAvatarImageRequest: Hashable {
    let accountRef: String
    let groupIdHex: String
    let imageHashHex: String
    let maxPixelSize: Int
}

nonisolated enum GroupAvatarCacheKey {
    static func rawData(accountRef: String, imageHashHex: String) -> String {
        "\(accountRef):\(imageHashHex)"
    }

    static func legacyRawData(accountRef: String, groupIdHex: String, imageHashHex: String) -> String {
        "\(accountRef):\(groupIdHex):\(imageHashHex)"
    }

    static func thumbnail(accountRef: String, imageHashHex: String, maxPixelSize: Int) -> String {
        "\(accountRef):\(imageHashHex):\(max(maxPixelSize, 1))"
    }

    static func seed(accountRef: String, groupIdHex: String) -> String {
        "\(accountRef):\(groupIdHex)"
    }

    static func shouldUseSeed(replacingImageHashHex: String?, requestedImageHashHex: String) -> Bool {
        replacingImageHashHex != requestedImageHashHex
    }
}

@MainActor
enum GroupAvatarImageLoader {
    private final class CachedImage: NSObject {
        let image: UIImage

        init(_ image: UIImage) {
            self.image = image
        }
    }

    private struct Seed {
        let data: Data
        let replacingImageHashHex: String?
        let insertedAt: ContinuousClock.Instant
    }

    private enum LoadSource: String {
        case decodedMemory = "decoded_memory"
        case thumbnailDisk = "thumbnail_disk"
        case seeded = "seeded"
        case rawMemory = "raw_memory"
        case rawDisk = "raw_disk"
        case network
    }

    private struct DataLoad {
        let data: Data
        let source: LoadSource
        let queueWaitMilliseconds: Double
        let fetchMilliseconds: Double
    }

    private struct ImageLoad {
        let image: UIImage
        let source: LoadSource
        let byteCount: Int
        let queueWaitMilliseconds: Double
        let fetchMilliseconds: Double
        let decodeMilliseconds: Double
    }

    private static let loadLimiter = CancellableLoadLimiter(maximumConcurrentLoads: 4)
    private static let seedLifetime: Duration = .seconds(10 * 60)
    private static let maximumSeedCount = 12
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "group-avatar-cache"
    )

    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private static let dataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static var diskWrites: [UUID: Task<Void, Never>] = [:]
    private static var seeds: [String: Seed] = [:]
    private static var inFlight: [String: Task<DataLoad, Error>] = [:]
    private static var inFlightImages: [String: Task<ImageLoad, Error>] = [:]
    private static var cacheDrainTask: Task<Void, Never>?
    private static var cacheGeneration: UInt64 = 0
    #if DEBUG
    static var beforeDecodeForTesting: (@Sendable () async -> Void)?
    #endif

    static func seed(
        data: Data,
        accountRef: String,
        groupIdHex: String,
        replacingImageHashHex: String?
    ) {
        guard !data.isEmpty, cacheDrainTask == nil, !AvatarCacheErasure.isInProgress else { return }
        pruneSeeds()
        if seeds.count >= maximumSeedCount,
           let oldest = seeds.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key {
            seeds[oldest] = nil
        }
        seeds[GroupAvatarCacheKey.seed(accountRef: accountRef, groupIdHex: groupIdHex)] = Seed(
            data: data,
            replacingImageHashHex: replacingImageHashHex,
            insertedAt: .now
        )
    }

    static func cachedImage(for request: GroupAvatarImageRequest) -> UIImage? {
        cache.object(forKey: imageCacheKey(for: request))?.image
    }

    static func image(
        request: GroupAvatarImageRequest,
        scale: CGFloat,
        priority: GroupAvatarLoadPriority,
        client: MarmotClient
    ) async throws -> UIImage {
        try checkCacheWorkAllowed()
        let generation = cacheGeneration
        let startedAt = ContinuousClock.now
        let cacheKey = imageCacheKey(for: request)
        if let cached = cache.object(forKey: cacheKey)?.image {
            record(
                ImageLoad(
                    image: cached,
                    source: .decodedMemory,
                    byteCount: 0,
                    queueWaitMilliseconds: 0,
                    fetchMilliseconds: 0,
                    decodeMilliseconds: 0
                ),
                totalStartedAt: startedAt
            )
            return cached
        }

        let imageTaskKey = cacheKey as String
        if let task = inFlightImages[imageTaskKey] {
            return try await task.value.image
        }

        let task = Task { @MainActor in
            try await loadImage(
                request: request,
                scale: scale,
                priority: priority,
                client: client
            )
        }
        inFlightImages[imageTaskKey] = task
        defer { if generation == cacheGeneration { inFlightImages[imageTaskKey] = nil } }

        do {
            let load = try await task.value
            try checkCacheWorkAllowed()
            guard !task.isCancelled else { throw CancellationError() }
            cache.setObject(
                CachedImage(load.image),
                forKey: cacheKey,
                cost: DecodedImageCost.decodedBitmapByteCost(for: load.image)
            )
            record(load, totalStartedAt: startedAt)
            return load.image
        } catch {
            if !(error is CancellationError) {
                log.error(
                    "load_failed total_ms=\(elapsedMilliseconds(since: startedAt), format: .fixed(precision: 0), privacy: .public)"
                )
            }
            throw error
        }
    }

    private static func loadImage(
        request: GroupAvatarImageRequest,
        scale: CGFloat,
        priority: GroupAvatarLoadPriority,
        client: MarmotClient
    ) async throws -> ImageLoad {
        if let seed = takeSeed(for: request) {
            let load = try await decode(
                data: seed.data,
                source: .seeded,
                request: request,
                scale: scale
            )
            try checkCacheWorkAllowed()
            cacheRawData(seed.data, for: request)
            persistRawData(seed.data, for: request)
            persistThumbnail(load.image, for: request)
            return load
        }

        let thumbnailKey = GroupAvatarCacheKey.thumbnail(
            accountRef: request.accountRef,
            imageHashHex: request.imageHashHex,
            maxPixelSize: request.maxPixelSize
        )
        if let thumbnailData = await RemoteAvatarDiskCache.groupThumbnailShared.data(forKey: thumbnailKey) {
            return try await decode(
                data: thumbnailData,
                source: .thumbnailDisk,
                request: request,
                scale: scale
            )
        }

        let dataLoad = try await imageData(
            request: request,
            priority: priority,
            client: client
        )
        let load = try await decode(
            data: dataLoad.data,
            source: dataLoad.source,
            request: request,
            scale: scale,
            queueWaitMilliseconds: dataLoad.queueWaitMilliseconds,
            fetchMilliseconds: dataLoad.fetchMilliseconds
        )
        try checkCacheWorkAllowed()
        persistThumbnail(load.image, for: request)
        return load
    }

    private static func decode(
        data: Data,
        source: LoadSource,
        request: GroupAvatarImageRequest,
        scale: CGFloat,
        queueWaitMilliseconds: Double = 0,
        fetchMilliseconds: Double = 0
    ) async throws -> ImageLoad {
        #if DEBUG
        await beforeDecodeForTesting?()
        #endif
        try checkCacheWorkAllowed()
        let decodeStartedAt = ContinuousClock.now
        guard let image = await RemoteImageDecoder.downsampledImage(
            from: data,
            maxPixelSize: request.maxPixelSize,
            scale: scale
        ) else {
            throw URLError(.cannotDecodeContentData)
        }
        return ImageLoad(
            image: image,
            source: source,
            byteCount: data.count,
            queueWaitMilliseconds: queueWaitMilliseconds,
            fetchMilliseconds: fetchMilliseconds,
            decodeMilliseconds: elapsedMilliseconds(since: decodeStartedAt)
        )
    }

    private static func imageData(
        request: GroupAvatarImageRequest,
        priority: GroupAvatarLoadPriority,
        client: MarmotClient
    ) async throws -> DataLoad {
        try checkCacheWorkAllowed()
        let generation = cacheGeneration
        let dataKey = GroupAvatarCacheKey.rawData(
            accountRef: request.accountRef,
            imageHashHex: request.imageHashHex
        )
        if let cached = dataCache.object(forKey: dataKey as NSString) {
            return DataLoad(
                data: cached as Data,
                source: .rawMemory,
                queueWaitMilliseconds: 0,
                fetchMilliseconds: 0
            )
        }
        if let cached = await RemoteAvatarDiskCache.groupShared.data(forKey: dataKey) {
            try checkCacheWorkAllowed()
            dataCache.setObject(cached as NSData, forKey: dataKey as NSString, cost: cached.count)
            return DataLoad(
                data: cached,
                source: .rawDisk,
                queueWaitMilliseconds: 0,
                fetchMilliseconds: 0
            )
        }
        let legacyDataKey = GroupAvatarCacheKey.legacyRawData(
            accountRef: request.accountRef,
            groupIdHex: request.groupIdHex,
            imageHashHex: request.imageHashHex
        )
        if let cached = await RemoteAvatarDiskCache.groupShared.data(forKey: legacyDataKey) {
            try checkCacheWorkAllowed()
            dataCache.setObject(cached as NSData, forKey: dataKey as NSString, cost: cached.count)
            await RemoteAvatarDiskCache.groupShared.store(cached, forKey: dataKey)
            return DataLoad(
                data: cached,
                source: .rawDisk,
                queueWaitMilliseconds: 0,
                fetchMilliseconds: 0
            )
        }
        if let task = inFlight[dataKey] {
            return try await task.value
        }

        let task = Task {
            let queueStartedAt = ContinuousClock.now
            guard let reservation = await loadLimiter.acquire(priority: priority.rawValue) else {
                throw CancellationError()
            }
            let queueWaitMilliseconds = elapsedMilliseconds(since: queueStartedAt)
            do {
                try Task.checkCancellation()
                let fetchStartedAt = ContinuousClock.now
                let data = try await client.downloadGroupBlossomImage(
                    accountRef: request.accountRef,
                    groupIdHex: request.groupIdHex
                )
                let fetchMilliseconds = elapsedMilliseconds(since: fetchStartedAt)
                await loadLimiter.release(reservation)
                return DataLoad(
                    data: data,
                    source: .network,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    fetchMilliseconds: fetchMilliseconds
                )
            } catch {
                await loadLimiter.release(reservation)
                throw error
            }
        }
        inFlight[dataKey] = task
        defer { if generation == cacheGeneration { inFlight[dataKey] = nil } }
        let load = try await task.value
        try checkCacheWorkAllowed()
        guard !task.isCancelled else { throw CancellationError() }
        dataCache.setObject(load.data as NSData, forKey: dataKey as NSString, cost: load.data.count)
        await RemoteAvatarDiskCache.groupShared.store(load.data, forKey: dataKey)
        return load
    }

    private static func takeSeed(for request: GroupAvatarImageRequest) -> Seed? {
        pruneSeeds()
        let key = GroupAvatarCacheKey.seed(
            accountRef: request.accountRef,
            groupIdHex: request.groupIdHex
        )
        guard let seed = seeds[key],
              GroupAvatarCacheKey.shouldUseSeed(
                replacingImageHashHex: seed.replacingImageHashHex,
                requestedImageHashHex: request.imageHashHex
              )
        else { return nil }
        seeds[key] = nil
        return seed
    }

    private static func pruneSeeds(now: ContinuousClock.Instant = .now) {
        seeds = seeds.filter { entry in
            entry.value.insertedAt.duration(to: now) < seedLifetime
        }
    }

    private static func cacheRawData(_ data: Data, for request: GroupAvatarImageRequest) {
        guard !Task.isCancelled, cacheDrainTask == nil, !AvatarCacheErasure.isInProgress else { return }
        let key = GroupAvatarCacheKey.rawData(
            accountRef: request.accountRef,
            imageHashHex: request.imageHashHex
        )
        dataCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    private static func persistRawData(_ data: Data, for request: GroupAvatarImageRequest) {
        guard !Task.isCancelled, cacheDrainTask == nil, !AvatarCacheErasure.isInProgress else { return }
        let key = GroupAvatarCacheKey.rawData(
            accountRef: request.accountRef,
            imageHashHex: request.imageHashHex
        )
        let id = UUID()
        diskWrites[id] = Task {
            defer { diskWrites[id] = nil }
            guard !Task.isCancelled, cacheDrainTask == nil, !AvatarCacheErasure.isInProgress else { return }
            await RemoteAvatarDiskCache.groupShared.store(data, forKey: key)
        }
    }

    private static func persistThumbnail(_ image: UIImage, for request: GroupAvatarImageRequest) {
        guard !Task.isCancelled, cacheDrainTask == nil, !AvatarCacheErasure.isInProgress else { return }
        let key = GroupAvatarCacheKey.thumbnail(
            accountRef: request.accountRef,
            imageHashHex: request.imageHashHex,
            maxPixelSize: request.maxPixelSize
        )
        let id = UUID()
        diskWrites[id] = Task {
            defer { diskWrites[id] = nil }
            let data = await Task.detached(priority: .utility) {
                image.pngData()
            }.value
            guard let data, !Task.isCancelled, cacheDrainTask == nil, !AvatarCacheErasure.isInProgress else { return }
            await RemoteAvatarDiskCache.groupThumbnailShared.store(data, forKey: key)
        }
    }

    private static func imageCacheKey(for request: GroupAvatarImageRequest) -> NSString {
        GroupAvatarCacheKey.thumbnail(
            accountRef: request.accountRef,
            imageHashHex: request.imageHashHex,
            maxPixelSize: request.maxPixelSize
        ) as NSString
    }

    private static func record(_ load: ImageLoad, totalStartedAt: ContinuousClock.Instant) {
        log.debug(
            "load source=\(load.source.rawValue, privacy: .public) bytes=\(load.byteCount, privacy: .public) queue_ms=\(load.queueWaitMilliseconds, format: .fixed(precision: 0), privacy: .public) fetch_ms=\(load.fetchMilliseconds, format: .fixed(precision: 0), privacy: .public) decode_ms=\(load.decodeMilliseconds, format: .fixed(precision: 0), privacy: .public) total_ms=\(elapsedMilliseconds(since: totalStartedAt), format: .fixed(precision: 0), privacy: .public)"
        )
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }

    static func clearCachesAndDrain() async {
        if let cacheDrainTask { await cacheDrainTask.value; return }
        let dataTasks = Array(inFlight.values)
        let imageTasks = Array(inFlightImages.values)
        let writes = Array(diskWrites.values)
        clearCaches()
        let drain = Task { @MainActor in
            for task in dataTasks { _ = await task.result }
            for task in imageTasks { _ = await task.result }
            for task in writes { await task.value }
            clearCaches()
            cacheDrainTask = nil
        }
        cacheDrainTask = drain
        await drain.value
    }

    private static func checkCacheWorkAllowed() throws {
        try Task.checkCancellation()
        guard cacheDrainTask == nil, !AvatarCacheErasure.isInProgress else { throw CancellationError() }
    }

    static func clearCaches() {
        cacheGeneration &+= 1
        diskWrites.values.forEach { $0.cancel() }
        diskWrites.removeAll()
        cache.removeAllObjects()
        dataCache.removeAllObjects()
        seeds.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        inFlightImages.values.forEach { $0.cancel() }
        inFlightImages.removeAll()
    }

    #if DEBUG
    static var isDrainingForTesting: Bool { cacheDrainTask != nil }
    static func resetForTesting() { clearCaches() }

    static func hasSeedForTesting(accountRef: String, groupIdHex: String) -> Bool {
        pruneSeeds()
        return seeds[GroupAvatarCacheKey.seed(accountRef: accountRef, groupIdHex: groupIdHex)] != nil
    }
    #endif
}
