import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageMediaCachePurgeTests {

    @Test func targetedRemovalRejectsAProducerThatStartedBeforeDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targeted-purge-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = purgeTestReference()
        let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: root))
        let staleEpoch = MessageMediaCache.currentProducerEpoch()

        MessageMediaCache.removeCachedData(
            forCiphertextHashes: [reference.ciphertextSha256.lowercased()],
            in: [reference],
            cachesDirectory: root
        )
        MessageMediaCache.store(
            Data([0x1]),
            for: reference,
            cachesDirectory: root,
            producerGeneration: staleEpoch
        )

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func staleProducerCannotStorePlaintextAfterAPurge() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-race-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = purgeTestReference()
        let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: root))

        // Deterministic ordering of the reviewed race: the producer captures
        // its epoch, the wipe completes, and only then does the store run —
        // it must be rejected before touching the filesystem.
        let staleEpoch = MessageMediaCache.currentProducerEpoch()
        #expect(MessageMediaCache.purgeAllDecryptedMedia(cachesDirectory: root))
        MessageMediaCache.store(
            Data([0x1]),
            for: reference,
            cachesDirectory: root,
            producerGeneration: staleEpoch
        )
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A producer whose epoch postdates the purge stores normally.
        let storedFresh = writeWithFreshEpoch { freshEpoch in
            MessageMediaCache.store(
                Data([0x1]),
                for: reference,
                cachesDirectory: root,
                producerGeneration: freshEpoch
            )
            return FileManager.default.fileExists(atPath: url.path)
        }
        #expect(storedFresh)

        // The purge removes what exists and reports it.
        #expect(MessageMediaCache.purgeAllDecryptedMedia(cachesDirectory: root))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func playbackWritesRejectStaleProducersToo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-race-playback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No reference: this exercises the raw playback branch.
        let item = MessageMediaAttachment(
            id: "playback-item",
            reference: nil,
            fileName: "voice.m4a",
            mediaType: "audio/mp4",
            dim: nil,
            localData: nil
        )

        let staleEpoch = MessageMediaCache.currentProducerEpoch()
        #expect(MessageMediaCache.purgeAllDecryptedMedia(cachesDirectory: root))
        let rejected = MediaPlaybackFileStore.fileURL(
            for: item,
            data: Data([0x2]),
            cachesDirectory: root,
            mediaPolicy: .media,
            playbackPolicy: .playback,
            producerEpoch: staleEpoch
        )
        #expect(rejected == nil)

        let storedFresh = writeWithFreshEpoch { freshEpoch in
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x2]),
                cachesDirectory: root,
                mediaPolicy: .media,
                playbackPolicy: .playback,
                producerEpoch: freshEpoch
            ) != nil
        }
        #expect(storedFresh)
    }
}

/// Runs a write with a freshly read producer epoch and reports whether it was
/// accepted. The epoch is process-global and only grows, and other suites
/// bump it (purges, deletions, sign-out wipes), so one can land between the
/// read and the write's check. A rejection is retried only when the epoch
/// provably moved; a rejection while it held still is a real failure. The
/// cap is far above the bumps a whole suite run makes, so it only stops a
/// broken write from looping.
private func writeWithFreshEpoch(_ write: (Int) -> Bool) -> Bool {
    for _ in 0..<1_000 {
        let epoch = MessageMediaCache.currentProducerEpoch()
        if write(epoch) { return true }
        if MessageMediaCache.currentProducerEpoch() == epoch { return false }
    }
    return false
}

private func purgeTestReference() -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/media")],
        ciphertextSha256: String(repeating: "a", count: 64),
        plaintextSha256: String(repeating: "b", count: 64),
        nonceHex: String(repeating: "2", count: 24),
        fileName: "photo.jpg",
        mediaType: "image/jpeg",
        version: .v1,
        sourceEpoch: 1,
        dim: nil,
        thumbhash: nil
    )
}
