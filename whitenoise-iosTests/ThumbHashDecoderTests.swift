import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ThumbHashDecoderTests {

    @Test func rejectsMalformedAndOversizedHashes() {
        #expect(ThumbHash.decodedImage(from: "") == nil)
        #expect(ThumbHash.decodedImage(from: "!!!!") == nil)
        #expect(ThumbHash.decodedImage(from: Data([0, 1, 2, 3]).base64EncodedString()) == nil)
        #expect(ThumbHash.decodedImage(from: Data(repeating: 0, count: 65).base64EncodedString()) == nil)
        #expect(ThumbHash.decodedImage(from: String(repeating: "A", count: 65)) == nil)
    }

    @Test func decodesNeutralPortraitPixelsWithinNaturalBounds() throws {
        let bytes: [UInt8] = [0x20, 0x08, 0x02, 0x05, 0x00] + Array(repeating: 0, count: 16)
        let decoded = try #require(ThumbHash.decodedImage(from: Data(bytes).base64EncodedString()))

        #expect(decoded.width == 23)
        #expect(decoded.height == 32)
        #expect(decoded.rgba.count == decoded.width * decoded.height * 4)
        let center = ((decoded.height / 2) * decoded.width + decoded.width / 2) * 4
        #expect(abs(Int(decoded.rgba[center]) - 127) <= 8)
        #expect(abs(Int(decoded.rgba[center + 1]) - 127) <= 8)
        #expect(abs(Int(decoded.rgba[center + 2]) - 127) <= 8)
        #expect(decoded.rgba[center + 3] == 255)
    }

    @Test func decodesLandscapeAndUnpaddedBase64() throws {
        let bytes: [UInt8] = [0x20, 0x08, 0x02, 0x04, 0x80] + Array(repeating: 0, count: 15)
        let unpadded = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let decoded = try #require(ThumbHash.decodedImage(from: unpadded))

        #expect(decoded.width == 32)
        #expect(decoded.height == 18)
        #expect(decoded.rgba.count == decoded.width * decoded.height * 4)
    }

    @MainActor
    @Test func imageCacheCoalescesConcurrentDecodes() async {
        let probe = ThumbHashDecoderProbe(shouldSuspend: true)
        let cache = ThumbHashImageCache { encoded in
            await probe.decode(encoded)
        }

        let first = Task { @MainActor in await cache.image(for: "same") }
        await probe.waitUntilStarted()
        let second = Task { @MainActor in await cache.image(for: "same") }
        for _ in 0..<10 { await Task.yield() }

        #expect(await probe.callCount() == 1)
        await probe.release()
        let firstImage = await first.value
        let secondImage = await second.value
        #expect(firstImage == nil)
        #expect(secondImage == nil)
    }

    @MainActor
    @Test func imageCacheClearsCompletedDecode() async {
        let probe = ThumbHashDecoderProbe(shouldSuspend: false)
        let cache = ThumbHashImageCache { encoded in
            await probe.decode(encoded)
        }

        let firstImage = await cache.image(for: "same")
        let secondImage = await cache.image(for: "same")
        #expect(firstImage == nil)
        #expect(secondImage == nil)
        #expect(await probe.callCount() == 2)
    }
}

private actor ThumbHashDecoderProbe {
    private let shouldSuspend: Bool
    private var decodeCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(shouldSuspend: Bool) {
        self.shouldSuspend = shouldSuspend
    }

    func decode(_: String) async -> ThumbHash.DecodedImage? {
        decodeCount += 1
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll()

        if shouldSuspend, !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return nil
    }

    func waitUntilStarted() async {
        guard decodeCount == 0 else { return }
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
        decodeCount
    }
}
