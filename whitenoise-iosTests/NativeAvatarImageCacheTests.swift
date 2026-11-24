import Testing
import UIKit
import SwiftUI
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct NativeAvatarImageCacheTests {
    @Test func firstFrameUsesWarmPixelsWithoutWaitingForTheConversationOrRuntime() throws {
        let suite = "NativeAvatarImageCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState.test(client: nil, notifications: .shared, accountDefaults: defaults, erasureDefaults: defaults)
        state.activeAccountRef = "avatar-first-frame"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        NativeAvatarImageCache.shared.insert(image, account: "avatar-first-frame", generation: state.runtimeGeneration,
            reference: "warm", revision: 1)
        defer { NativeAvatarImageCache.shared.removeAll() }
        let asset = AvatarAssetFfi(target: "visible", reference: "warm", availability: .ready,
            acquisition: nil, contentRevision: 1, byteCount: 100)
        func render(_ asset: AvatarAssetFfi?) throws -> Data {
            let renderer = ImageRenderer(content: NativeAvatarBubble(seed: "peer", title: "Ren", asset: asset)
                .frame(width: 40, height: 40).environment(state))
            return try #require(renderer.uiImage?.pngData())
        }
        let expected = ImageRenderer(content: AvatarBubble(seed: "peer", title: "Ren", pictureImage: image)
            .frame(width: 40, height: 40))
        #expect(try render(asset) == #require(expected.uiImage?.pngData()))
        #expect(try render(nil) != render(asset))
        var replaced = asset
        replaced.contentRevision = 2
        #expect(try render(replaced) == render(nil))
        var invalidated = asset
        invalidated.availability = .invalidated
        #expect(try render(invalidated) == render(nil))
    }

    @Test func decodedPixelsTransferOnlyWithinTheSameAccountRuntimeAndContent() {
        let cache = NativeAvatarImageCache()
        let image = UIImage()
        cache.insert(image, account: "alice", generation: 1, reference: "avatar", revision: 2)
        #expect(cache.image(account: "alice", generation: 1, reference: "avatar", revision: 2) === image)
        #expect(cache.image(account: "bob", generation: 1, reference: "avatar", revision: 2) == nil)
        #expect(cache.image(account: "alice", generation: 2, reference: "avatar", revision: 2) == nil)
        #expect(cache.image(account: "alice", generation: 1, reference: "replacement", revision: 2) == nil)
        #expect(cache.image(account: "alice", generation: 1, reference: "avatar", revision: 3) == nil)
    }

    @Test func viewerSizedPixelsAreCachedApartFromThumbnails() {
        let cache = NativeAvatarImageCache()
        let thumbnail = UIImage()
        let viewer = UIImage()
        cache.insert(thumbnail, account: "alice", generation: 1, reference: "avatar", revision: 2)
        #expect(cache.image(account: "alice", generation: 1, reference: "avatar", revision: 2,
                            maxPixelSize: 1_200) == nil)
        cache.insert(viewer, account: "alice", generation: 1, reference: "avatar", revision: 2, maxPixelSize: 1_200)
        #expect(cache.image(account: "alice", generation: 1, reference: "avatar", revision: 2) === thumbnail)
        #expect(cache.image(account: "alice", generation: 1, reference: "avatar", revision: 2,
                            maxPixelSize: 1_200) === viewer)
    }

    @Test func visiblePixelsStayWarmWhileLeastRecentlyUsedPixelsAreEvicted() {
        let cache = NativeAvatarImageCache(capacity: 2)
        let image = UIImage()
        for reference in ["visible", "old"] {
            cache.insert(image, account: "alice", generation: 1, reference: reference, revision: 1)
        }
        #expect(cache.image(account: "alice", generation: 1, reference: "visible", revision: 1) === image)
        cache.insert(image, account: "alice", generation: 1, reference: "new", revision: 1)
        #expect(cache.image(account: "alice", generation: 1, reference: "old", revision: 1) == nil)
        #expect(cache.image(account: "alice", generation: 1, reference: "visible", revision: 1) === image)
        cache.removeAll()
        #expect(cache.image(account: "alice", generation: 1, reference: "visible", revision: 1) == nil)
    }

    @Test func erasureInvalidatesDecodedPixelsAndInFlightRequestGeneration() {
        let cache = NativeAvatarImageCache.shared
        cache.insert(UIImage(), account: "erasure-test", generation: 1, reference: "avatar", revision: 1)
        let generation = AvatarCacheErasure.generation
        AvatarCacheErasure.begin()
        defer { AvatarCacheErasure.end() }
        #expect(AvatarCacheErasure.generation > generation)
        #expect(cache.image(account: "erasure-test", generation: 1, reference: "avatar", revision: 1) == nil)
    }

    @Test func readyAvatarWithExactRamCacheHitSkipsRequestAvatarAssets() async throws {
        let cache = NativeAvatarImageCache()
        let cachedImage = UIImage()
        cache.insert(cachedImage, account: "alice", generation: 3, reference: "ref-1", revision: 7,
                     maxPixelSize: NativeAvatarImageCache.thumbnailPixelSize)

        let readyAsset = AvatarAssetFfi(
            target: "target-1",
            reference: "ref-1",
            availability: .ready,
            acquisition: nil,
            contentRevision: 7,
            byteCount: 120
        )

        var requestCalls = 0
        var readCalls = 0
        let hit = try await NativeAvatarBubble.resolveImage(
            asset: readyAsset,
            account: "alice",
            generation: 3,
            maxPixelSize: NativeAvatarImageCache.thumbnailPixelSize,
            cache: cache,
            requestAssets: { _, _ in
                requestCalls += 1
                return [readyAsset]
            },
            readAssets: { _, _, _ in
                readCalls += 1
                return []
            },
            decodeImage: { _, _ in UIImage() }
        )

        #expect(hit?.image === cachedImage)
        #expect(hit?.reference == "ref-1")
        #expect(hit?.revision == 7)
        #expect(requestCalls == 0)
        #expect(readCalls == 0)

        // Requesting viewer size when only thumbnail is cached must still hit MDK.
        let decodedViewer = UIImage()
        let viewerHit = try await NativeAvatarBubble.resolveImage(
            asset: readyAsset,
            account: "alice",
            generation: 3,
            maxPixelSize: 1_200,
            cache: cache,
            requestAssets: { _, _ in
                requestCalls += 1
                return [readyAsset]
            },
            readAssets: { _, _, _ in
                readCalls += 1
                return [AvatarBytesFfi(
                    reference: "ref-1",
                    availability: .ready,
                    contentRevision: 7,
                    byteCount: 3,
                    deferred: false,
                    bytes: Data([1, 2, 3]),
                    mediaType: "image/png",
                    width: 1_200,
                    height: 1_200
                )]
            },
            decodeImage: { _, _ in decodedViewer }
        )
        #expect(viewerHit?.image === decodedViewer)
        #expect(requestCalls == 1)
        #expect(readCalls == 1)

        // Stale availability still calls requestAvatarAssets to trigger refresh,
        // but reuses the warm pixels if MDK returns the same revision.
        var staleAsset = readyAsset
        staleAsset.availability = .stale
        let staleHit = try await NativeAvatarBubble.resolveImage(
            asset: staleAsset,
            account: "alice",
            generation: 3,
            maxPixelSize: NativeAvatarImageCache.thumbnailPixelSize,
            cache: cache,
            requestAssets: { _, _ in
                requestCalls += 1
                return [staleAsset]
            },
            readAssets: { _, _, _ in
                readCalls += 1
                return []
            },
            decodeImage: { _, _ in UIImage() }
        )
        #expect(staleHit?.image === cachedImage)
        #expect(requestCalls == 2)
        #expect(readCalls == 1)

        // Missing and invalidated avatars always register demand via requestAvatarAssets.
        for availability in [AvatarAvailabilityFfi.missing, .invalidated] {
            let unavailable = AvatarAssetFfi(
                target: "target-1",
                reference: nil,
                availability: availability,
                acquisition: nil,
                contentRevision: 0,
                byteCount: 0
            )
            let before = requestCalls
            let result = try await NativeAvatarBubble.resolveImage(
                asset: unavailable,
                account: "alice",
                generation: 3,
                maxPixelSize: NativeAvatarImageCache.thumbnailPixelSize,
                cache: cache,
                requestAssets: { _, _ in
                    requestCalls += 1
                    return [unavailable]
                },
                readAssets: { _, _, _ in
                    readCalls += 1
                    return []
                },
                decodeImage: { _, _ in UIImage() }
            )
            #expect(result == nil)
            #expect(requestCalls == before + 1)
        }
    }
}
