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
        let freshFailure = freshWriteFailure { freshEpoch in
            MessageMediaCache.store(
                Data([0x1]),
                for: reference,
                cachesDirectory: root,
                producerGeneration: freshEpoch
            )
            return FileManager.default.fileExists(atPath: url.path)
        }
        #expect(freshFailure == nil)

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

        let freshFailure = freshWriteFailure { freshEpoch in
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x2]),
                cachesDirectory: root,
                mediaPolicy: .media,
                playbackPolicy: .playback,
                producerEpoch: freshEpoch
            ) != nil
        }
        #expect(freshFailure == nil)
    }
}

/// Runs a write with a freshly read producer epoch; nil means it was accepted.
/// The epoch is process-global and only grows, and other tests, this suite's
/// parallel siblings included, bump it with purges, targeted cache removals
/// and sign-out wipes. A bump can land between the read and the write's check,
/// so a failed write is retried only when the epoch moved meanwhile; a failure
/// while it held still cannot be an epoch race and is real. The attempt cap is
/// a defensive bound against a write path that keeps bumping the epoch itself.
private func freshWriteFailure(_ write: (Int) -> Bool) -> String? {
    for _ in 0..<1_000 {
        let epoch = MessageMediaCache.currentProducerEpoch()
        if write(epoch) { return nil }
        if MessageMediaCache.currentProducerEpoch() == epoch {
            return "write failed while the epoch held at \(epoch), so not an epoch race"
        }
    }
    return "write failed on every attempt while the epoch kept moving"
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
