import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageRetentionSweepTests {

    @Test func sweepsOnlyInReadyPhaseWithLocalForegroundRuntime() {
        #expect(MessageRetentionSweepPolicy.canSweep(
            phase: .ready,
            canUseRuntimeForLocalForegroundWork: true
        ))
        #expect(!MessageRetentionSweepPolicy.canSweep(
            phase: .ready,
            canUseRuntimeForLocalForegroundWork: false
        ))
        #expect(!MessageRetentionSweepPolicy.canSweep(
            phase: .bootstrapping,
            canUseRuntimeForLocalForegroundWork: true
        ))
        #expect(!MessageRetentionSweepPolicy.canSweep(
            phase: .onboarding,
            canUseRuntimeForLocalForegroundWork: true
        ))
        #expect(!MessageRetentionSweepPolicy.canSweep(
            phase: .failed("boom"),
            canUseRuntimeForLocalForegroundWork: true
        ))
    }

    @Test func signedOutAccountsAreExcludedFromSweeps() {
        let accounts = [
            sweepTestAccount(label: "account-1", signedOut: false),
            sweepTestAccount(label: "account-2", signedOut: true),
            sweepTestAccount(label: "account-3", signedOut: false),
        ]
        #expect(MessageRetentionSweepPolicy.sweepAccountRefs(from: accounts) == ["account-1", "account-3"])
    }

    @Test func onlyRetentionEnabledGroupsAreSwept() {
        let retentionOn = sweepTestGroup(groupIdHex: String(repeating: "aa", count: 32), retentionSeconds: 30)
        let retentionOff = sweepTestGroup(groupIdHex: String(repeating: "bb", count: 32), retentionSeconds: 0)
        let longRetention = sweepTestGroup(groupIdHex: String(repeating: "cc", count: 32), retentionSeconds: 2_592_000)
        #expect(MessageRetentionSweepPolicy.sweepGroupIds(from: [retentionOn, retentionOff, longRetention]) == [
            retentionOn.groupIdHex,
            longRetention.groupIdHex,
        ])
        #expect(MessageRetentionSweepPolicy.sweepGroupIds(from: [retentionOff]).isEmpty)
    }

    @Test func duplicateGroupSnapshotsSweepOnce() {
        let group = sweepTestGroup(groupIdHex: String(repeating: "aa", count: 32), retentionSeconds: 30)
        #expect(MessageRetentionSweepPolicy.sweepGroupIds(from: [group, group]) == [group.groupIdHex])
    }

    @Test func sweepIntervalIsPositive() {
        #expect(MessageRetentionSweepPolicy.sweepIntervalNanoseconds > 0)
    }

    /// Cache eviction clears both decrypted stores for each plaintext hash
    /// resolved from Marmot's privacy-safe ciphertext-hash sweep report.
    @Test func cacheEvictionRemovesOnlyReportedPlaintextHashes() throws {
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-sweep-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        let prunedReference = sweepTestReference(
            ciphertextSha256: String(repeating: "AB", count: 32),
            plaintextSha256: String(repeating: "a", count: 64)
        )
        let keptReference = sweepTestReference(
            ciphertextSha256: String(repeating: "cd", count: 32),
            plaintextSha256: String(repeating: "b", count: 64)
        )

        for reference in [prunedReference, keptReference] {
            let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("plaintext".utf8).write(to: url)
        }
        let playbackDirectory = cachesDirectory
            .appendingPathComponent("EncryptedMediaPlayback", isDirectory: true)
        try FileManager.default.createDirectory(
            at: playbackDirectory,
            withIntermediateDirectories: true
        )
        let prunedPlaybackURL = playbackDirectory.appendingPathComponent("\(prunedReference.plaintextSha256).mp4")
        let keptPlaybackURL = playbackDirectory.appendingPathComponent("\(keptReference.plaintextSha256).mp4")
        try Data("pruned playback".utf8).write(to: prunedPlaybackURL)
        try Data("kept playback".utf8).write(to: keptPlaybackURL)

        let removed = MessageMediaCache.removeCachedData(
            forPlaintextHashes: [prunedReference.plaintextSha256.uppercased()],
            cachesDirectory: cachesDirectory
        )

        let prunedURL = try #require(MessageMediaCache.cacheURL(for: prunedReference, cachesDirectory: cachesDirectory))
        let keptURL = try #require(MessageMediaCache.cacheURL(for: keptReference, cachesDirectory: cachesDirectory))
        #expect(!FileManager.default.fileExists(atPath: prunedURL.path))
        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(!FileManager.default.fileExists(atPath: prunedPlaybackURL.path))
        #expect(FileManager.default.fileExists(atPath: keptPlaybackURL.path))
        #expect(removed)
    }

    @Test func cacheEvictionReportsDirectoryReadFailures() throws {
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-sweep-failure-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        try FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(
            to: cachesDirectory.appendingPathComponent("EncryptedMedia")
        )

        let removed = MessageMediaCache.removeCachedData(
            forPlaintextHashes: [String(repeating: "a", count: 64)],
            cachesDirectory: cachesDirectory
        )

        #expect(!removed)
    }
}

private func sweepTestAccount(label: String, signedOut: Bool) -> AccountSummaryFfi {
    AccountSummaryFfi(
        label: label,
        accountIdHex: String(repeating: "ee", count: 32),
        localSigning: true,
        externalSigning: false,
        signedOut: signedOut,
        running: !signedOut,
        unlinked: false
    )
}

private func sweepTestGroup(groupIdHex: String, retentionSeconds: UInt64) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: groupIdHex,
        endpoint: "",
        name: "Sweep Test Group",
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: String(repeating: "cd", count: 32),
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        imageHashHex: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: EncryptedMediaVersionFfi.v1.wireValue,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: []
        ),
        disappearingMessageSecs: retentionSeconds,
        archived: false,
        pendingConfirmation: false,
        selfMembership: .member,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func sweepTestReference(
    ciphertextSha256: String,
    plaintextSha256: String
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/media")],
        ciphertextSha256: ciphertextSha256,
        plaintextSha256: plaintextSha256,
        nonceHex: String(repeating: "2", count: 24),
        fileName: "photo.jpg",
        mediaType: "image/jpeg",
        version: .v1,
        sourceEpoch: 1,
        dim: nil,
        thumbhash: nil
    )
}
