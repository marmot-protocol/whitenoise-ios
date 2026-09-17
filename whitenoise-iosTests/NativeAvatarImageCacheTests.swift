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
        let state = AppState(client: nil, notifications: .shared, accountDefaults: defaults, erasureDefaults: defaults)
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
}
