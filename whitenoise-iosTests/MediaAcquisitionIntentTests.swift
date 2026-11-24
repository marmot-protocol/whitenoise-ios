import CryptoKit
import Foundation
import MarmotKit
import Synchronization
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct MediaAcquisitionIntentTests {
    private func attachment(_ mediaType: String = "image/jpeg", localData: Data? = nil) -> MessageMediaAttachment {
        MessageMediaAttachment(id: "source-slot", reference: nil, fileName: "attachment",
            mediaType: mediaType, dim: nil, localData: localData)
    }

    @Test func neighbouringGalleryPagesNeverInvokeTheDownloader() async throws {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            return Data([1])
        }
        for _ in 0..<5 {
            #expect(try await loader.selectedPageData(for: attachment(), isSelected: false) == nil)
        }
        #expect(requests.isEmpty)
        #expect(try await loader.selectedPageData(for: attachment(), isSelected: true) == Data([1]))
        #expect(requests == [.explicit])
    }

    @Test func documentPrefetchRequiresVisibilityAndPermissionAndNeverEscalatesFailure() async {
        var requests = [AttachmentDemand]()
        var sizeRequests = 0
        let loader = ConversationMediaLoader({ item in
            requests.append(item.demand)
            throw AttachmentReadError.unavailable
        }, admitAutomaticAttachment: { _ in
            sizeRequests += 1
            return nil
        })
        let pdf = attachment("application/pdf")
        let contact = attachment("text/vcard")
        for document in [pdf, contact] {
            await loader.prefetchDocument(document, isVisible: false, allowed: true)
            await loader.prefetchDocument(document, isVisible: true, allowed: false)
        }
        await loader.prefetchDocument(attachment(), isVisible: true, allowed: true)
        #expect(requests.isEmpty)
        #expect(sizeRequests == 0)
        for _ in 0..<2 {
            await loader.prefetchDocument(pdf, isVisible: true, allowed: true)
            await loader.prefetchDocument(contact, isVisible: true, allowed: true)
        }
        #expect(sizeRequests == 2)
        #expect(requests == [.automatic, .automatic])
    }

    @Test func aReceivedContactWithAnOutgoingByteOverlayChecksItsOwnSlot() async throws {
        let bytes = Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Avery Stone\r\nN:Stone;Avery;;;\r\nEND:VCARD\r\n".utf8)
        let target = AttachmentLocalTargetFfi(messageIdHex: "received", sourceMessageIdHex: "original", attachmentIndex: 2)
        let ref = encryptedMediaReference(fileName: "contact.vcf", mediaType: "text/vcard", sourceEpoch: 1)
        let contact = MessageMediaAttachment(id: "received-contact", reference: ref, fileName: "contact.vcf",
            mediaType: "text/vcard", dim: nil, localData: bytes, localTarget: target)
        var checked: [AttachmentLocalTargetFfi] = []
        var retained = false
        var reads: [MessageMediaAttachment] = []
        let loader = ConversationMediaLoader({ request in
            reads.append(request)
            throw AttachmentReadError.unavailable
        }, canShareDocument: { _, source in
            guard let source else { return false }
            checked.append(source)
            return retained
        })
        let missing = await loader.prefetchDocument(contact, isVisible: true, allowed: true)
        #expect(missing == nil && reads.isEmpty)
        retained = true
        let cached = await loader.prefetchDocument(contact, isVisible: true, allowed: false)
        #expect(cached?.contactName == "Avery Stone" && checked == [target, target] && reads.isEmpty)

        let presentation = DocumentSharePresentation()
        await #expect(throws: AttachmentReadError.unavailable) {
            try await presentation.openDocument(contact, using: loader, demand: .explicit,
                isCurrent: { true }, handoffItem: { contact }, didReadSize: { _ in })
        }
        #expect(reads.count == 1 && reads.first?.localTarget == target && reads.first?.localData == nil)
    }

    @Test func documentRowsReadOnlyTheBytesNeededForTheirLabels() async throws {
        let card = Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Avery Stone\r\nN:Stone;Avery;;;\r\nEND:VCARD\r\n".utf8)
        var bodyReadAttempts = 0
        let downloader = ConversationMediaDownloader()
        let loader = ConversationMediaLoader({ item in
            bodyReadAttempts += 1
            return try await downloader.data(for: item, groupIdHex: "group", appState: nil)
        }, admitAutomaticAttachment: { item in
            await downloader.admitAutomaticAttachment(for: item, groupIdHex: "group", appState: nil)
        })
        for type in ["application/pdf", "text/plain", "application/zip"] {
            let document = attachment(type, localData: Data(repeating: 1, count: 1024))
            let metadata = await loader.prefetchDocument(document, isVisible: true, allowed: true)
            #expect(metadata?.size == 1024)
        }
        #expect(bodyReadAttempts == 0)
        let contact = attachment("text/vcard", localData: card)
        let metadata = await loader.prefetchDocument(contact, isVisible: true, allowed: false)
        #expect(metadata?.size == card.count)
        #expect(metadata?.contactName?.contains("Avery") == true)
        #expect(bodyReadAttempts == 0)
    }

    @Test func selectedPageRetryCarriesTheRetryDemand() async throws {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            return Data([1])
        }
        _ = try await loader.selectedPageData(for: attachment(), isSelected: true,
            demand: .userTap(afterFailure: true))
        _ = try await loader.data(for: attachment())
        #expect(requests == [.retry, .explicit])
    }

    @Test func onlyATapOnAFailedAttachmentIsADeliberateRetry() {
        #expect(AttachmentDemand.userTap(afterFailure: false) == .explicit)
        #expect(AttachmentDemand.userTap(afterFailure: true) == .retry)
        #expect(!AttachmentDemand.automatic.isUserInitiated)
        #expect(AttachmentDemand.explicit.isUserInitiated)
        #expect(AttachmentDemand.retry.isUserInitiated)
    }

    @Test func sharedMediaTileAppearanceStaysAutomaticUntilATap() async {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            throw AttachmentReadError.unavailable
        }
        var didFail = false
        func load(_ demand: AttachmentDemand) async {
            if (try? await loader.data(for: attachment(), demand: demand)) == nil {
                didFail = demand.failureOffersRetry
            }
        }
        for _ in 0..<3 {
            guard let demand = GroupSharedMediaThumbnailDemand.onAppear(autoDownloadAllowed: true) else { continue }
            await load(demand)
        }
        // Reappearing may repeat automatic demand; MDK keeps the durable history, and
        // only a tap on a tile showing Retry asks it to download again.
        #expect(requests == [.automatic, .automatic, .automatic])
        await load(GroupSharedMediaThumbnailDemand.onTap(didFail: didFail))
        await load(GroupSharedMediaThumbnailDemand.onTap(didFail: didFail))
        #expect(requests.suffix(2) == [.explicit, .retry])
    }

    @Test func policyBlockedSharedMediaTileWaitsForAnExplicitTap() async {
        var requests = [AttachmentDemand]()
        let loader = ConversationMediaLoader { item in
            requests.append(item.demand)
            return Data([1])
        }
        if let demand = GroupSharedMediaThumbnailDemand.onAppear(autoDownloadAllowed: false) {
            _ = try? await loader.data(for: attachment(), demand: demand)
        }
        #expect(requests.isEmpty)
        _ = try? await loader.data(for: attachment(), demand: GroupSharedMediaThumbnailDemand.onTap(didFail: false))
        #expect(requests == [.explicit])
    }

    @Test func aTapDuringAnAutomaticLoadSupersedesIt() {
        var loads = GroupSharedMediaThumbnailLoadGate()
        let automatic = loads.begin()
        let tap = loads.begin()
        #expect(loads.isLoading)
        #expect(!loads.owns(automatic))
        // The superseded automatic load finishing cannot clear the tap's spinner or record its outcome.
        loads.finish(automatic)
        #expect(loads.isLoading)
        #expect(loads.owns(tap))
        loads.finish(tap)
        #expect(!loads.isLoading)
    }

    @Test func aPolicyRevisionDuringALoadStartsAFreshOne() {
        var loads = GroupSharedMediaThumbnailLoadGate()
        let cancelled = loads.begin()
        let replacement = loads.begin()
        loads.finish(cancelled)
        #expect(loads.owns(replacement))
        #expect(loads.isLoading)
    }

    @Test func automaticFailureLeavesTheFirstTapExplicit() {
        // Appearance load fails (e.g. a failed or retry-exhausted source).
        var showsRetry = AttachmentDemand.automatic.failureOffersRetry
        #expect(!showsRetry)
        let firstTap = AttachmentDemand.userTap(afterFailure: showsRetry)
        #expect(firstTap == .explicit)
        // MDK does not re-arm the source, so the tap fails and surfaces Retry.
        showsRetry = firstTap.failureOffersRetry
        #expect(showsRetry)
        #expect(AttachmentDemand.userTap(afterFailure: showsRetry) == .retry)
        #expect(AttachmentDemand.retry.failureOffersRetry)
    }

    private let target = AttachmentLocalTargetFfi(messageIdHex: String(repeating: "a", count: 64),
        sourceMessageIdHex: String(repeating: "b", count: 64), attachmentIndex: 1)

    @Test func tapJoinsTheCurrentSourceWithoutDownloadingAgain() async throws {
        let requester = RecordingAttachmentDemandRequester(reference: "job")
        #expect(try await AttachmentDemand.explicit.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: requester))
        #expect(requester.calls == [.init(kind: .explicit, accountRef: "account-a", groupID: "group-a", target: target)])
    }

    @Test func tapOnAnObsoleteSlotHasNothingToAwait() async throws {
        let requester = RecordingAttachmentDemandRequester(reference: nil)
        #expect(try await !AttachmentDemand.explicit.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: requester))
        #expect(requester.calls.map(\.kind) == [.explicit])
    }

    @Test func deliberateRetryDownloadsAgain() async throws {
        let requester = RecordingAttachmentDemandRequester(reference: "job")
        #expect(try await AttachmentDemand.retry.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: requester))
        #expect(requester.calls == [.init(kind: .downloadAgain, accountRef: "account-a", groupID: "group-a", target: target)])
    }

    @Test func automaticDemandAwaitsOnlyLiveTransfers() async throws {
        let live = RecordingAttachmentDemandRequester(reference: "job", automaticState: .downloading)
        #expect(try await AttachmentDemand.automatic.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: live))
        let failed = RecordingAttachmentDemandRequester(reference: "job", automaticState: .failed)
        #expect(try await !AttachmentDemand.automatic.record(accountRef: "account-a", groupID: "group-a",
            target: target, with: failed))
        #expect((live.calls + failed.calls).map(\.kind) == [.automatic, .automatic])
    }

    // A local miss whose demand MDK does not queue must surface `.unavailable`
    // rather than wait on a transfer that will never start.
    @Test(.marmotRuntimeConcurrencyLimit)
    func explicitAcquisitionOfAnUnknownSlotThrowsUnavailable() async throws {
        try await withTestClient { client in
            let watchdog = MarmotFixtureWatchdog.start("Attachment acquisition guard did not finish", breaking: client)
            defer { watchdog.cancel() }
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Attachment acquisition", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0)).requireCreated()
            let target = AttachmentLocalTargetFfi(messageIdHex: String(repeating: "a", count: 64),
                sourceMessageIdHex: String(repeating: "b", count: 64), attachmentIndex: 2)
            await #expect(throws: AttachmentReadError.unavailable) {
                _ = try await client.acquireAttachmentData(accountRef: account.label,
                    groupID: group.groupIdHex, target: target, demand: .explicit)
            }
        }
    }

    @Test func retainedReadsRespectOffsetsAndRevocation() async throws {
        let offsets = Mutex<[UInt64]>([])
        let data = try await RetainedAttachmentReader.read(byteCount: 3) { offset, limit in
            #expect(limit <= 1_048_576)
            offsets.withLock { $0.append(offset) }
            return AttachmentLocalBytesFfi(available: true, bytes: offset == 0 ? Data([1, 2]) : offset == 2 ? Data([3]) : Data())
        }
        #expect(data == Data([1, 2, 3]))
        #expect(offsets.withLock { $0 } == [0, 2, 3])
        await #expect(throws: AttachmentReadError.self) {
            try await RetainedAttachmentReader.read(byteCount: 2) { offset, _ in
                AttachmentLocalBytesFfi(available: offset == 0, bytes: offset == 0 ? Data([1]) : Data())
            }
        }
        let empty = try await RetainedAttachmentReader.read(byteCount: 0) { _, _ in
            AttachmentLocalBytesFfi(available: true, bytes: Data())
        }
        #expect(empty.isEmpty)
        await #expect(throws: AttachmentReadError.self) {
            try await RetainedAttachmentReader.read(byteCount: 2) { _, _ in
                AttachmentLocalBytesFfi(available: true, bytes: Data())
            }
        }
    }

    @Test func retainedReadsAboveThresholdStreamIntoUnlinkedMappedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetainedMappedReads-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Footprint is process-wide while other suites run concurrently, so use
        // a 128 MiB payload (64 MiB margin) just like MediaFileUploadTests.
        let size = 128 * 1024 * 1024
        let chunkPattern = Data(repeating: 0x05, count: 1024 * 1024)
        let offsets = Mutex<[UInt64]>([])
        let sawPathnameDuringStream = Mutex(false)
        let before = try #require(MediaFileUploadTests.physicalFootprint())
        let read = try await RetainedAttachmentReader.read(
            byteCount: UInt64(size),
            mappedDirectory: directory
        ) { offset, limit in
            offsets.withLock { $0.append(offset) }
            // The backing file must already be unlinked before any plaintext flows.
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
               !entries.isEmpty {
                sawPathnameDuringStream.withLock { $0 = true }
            }
            let remaining = size - Int(offset)
            let count = min(remaining, Int(limit))
            return AttachmentLocalBytesFfi(
                available: true,
                bytes: count > 0 ? chunkPattern.prefix(count) : Data()
            )
        }
        #expect(!sawPathnameDuringStream.withLock { $0 })
        #expect(read.count == size)
        let sum = read.withUnsafeBytes { $0.reduce(into: 0) { $0 &+= Int($1) } }
        let after = try #require(MediaFileUploadTests.physicalFootprint())
        #expect(sum == size * 5)
        #expect(Int64(after) - Int64(before) < Int64(size / 2))
        #expect(offsets.withLock { $0.first } == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        // Revocation, premature EOF, and oversize chunks all map to `.stale` and leave no file behind.
        await #expect(throws: AttachmentReadError.stale) {
            _ = try await RetainedAttachmentReader.read(byteCount: 128, mappedThreshold: 32, mappedDirectory: directory) { offset, _ in
                AttachmentLocalBytesFfi(available: offset == 0, bytes: offset == 0 ? Data(count: 64) : Data())
            }
        }
        await #expect(throws: AttachmentReadError.stale) {
            _ = try await RetainedAttachmentReader.read(byteCount: 128, mappedThreshold: 32, mappedDirectory: directory) { offset, _ in
                AttachmentLocalBytesFfi(available: true, bytes: offset == 0 ? Data(count: 64) : Data())
            }
        }
        await #expect(throws: AttachmentReadError.stale) {
            _ = try await RetainedAttachmentReader.read(byteCount: 64, mappedThreshold: 32, mappedDirectory: directory) { _, _ in
                AttachmentLocalBytesFfi(available: true, bytes: Data(count: 80))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func streamingPlaybackCachePublishesVerifiedFileAndRejectsCorruptionOrStaleEpoch() async throws {
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamPlaybackCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        let payload = Data((0..<(2 * 1024 * 1024 + 33)).map { UInt8($0 & 0xff) })
        let digest = await MediaPlaintextHash.digest(payload)
        let reference = MediaAttachmentReferenceFfi(
            locators: [],
            ciphertextSha256: String(repeating: "c", count: 64),
            plaintextSha256: digest,
            nonceHex: String(repeating: "d", count: 24),
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            version: .v2,
            sourceEpoch: 1,
            sourceEpochIdentity: nil,
            dim: "1920x1080",
            thumbhash: nil
        )
        let epoch = MessageMediaCache.currentProducerEpoch()
        let url = try await MessageMediaCache.streamAndStore(
            for: reference,
            byteCount: UInt64(payload.count),
            cachesDirectory: cachesDirectory,
            producerGeneration: epoch
        ) { offset, limit in
            let start = Int(offset)
            let end = min(payload.count, start + Int(limit))
            return AttachmentLocalBytesFfi(available: true, bytes: start < end ? payload[start..<end] : Data())
        }
        #expect(try Data(contentsOf: url) == payload)
        #expect(await MessageMediaCache.validCachedFileURL(for: reference, cachesDirectory: cachesDirectory) == url)

        // Staging files must never be left behind, even when verification or epoch checks fail.
        let encryptedDir = url.deletingLastPathComponent()
        let badReference = MediaAttachmentReferenceFfi(
            locators: [],
            ciphertextSha256: String(repeating: "e", count: 64),
            plaintextSha256: String(repeating: "0", count: 64),
            nonceHex: String(repeating: "f", count: 24),
            fileName: "bad.mp4",
            mediaType: "video/mp4",
            version: .v2,
            sourceEpoch: 1,
            sourceEpochIdentity: nil,
            dim: nil,
            thumbhash: nil
        )
        await #expect(throws: ConversationMediaDownloader.MediaDataError.plaintextHashMismatch) {
            _ = try await MessageMediaCache.streamAndStore(
                for: badReference,
                byteCount: UInt64(payload.count),
                cachesDirectory: cachesDirectory,
                producerGeneration: epoch
            ) { offset, limit in
                let start = Int(offset)
                let end = min(payload.count, start + Int(limit))
                return AttachmentLocalBytesFfi(available: true, bytes: start < end ? payload[start..<end] : Data())
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await MessageMediaCache.streamAndStore(
                for: reference,
                byteCount: UInt64(payload.count),
                cachesDirectory: cachesDirectory,
                producerGeneration: epoch - 1
            ) { offset, limit in
                let start = Int(offset)
                let end = min(payload.count, start + Int(limit))
                return AttachmentLocalBytesFfi(available: true, bytes: start < end ? payload[start..<end] : Data())
            }
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: encryptedDir.path)
        #expect(entries == [url.lastPathComponent])
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func playbackRejectsRevokedSlotEvenWhenHashKeyedCacheIsPrimed() async throws {
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-revoked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        let payload = Data("cached video bytes".utf8)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let reference = MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/video.mp4")],
            ciphertextSha256: String(repeating: "a", count: 64),
            plaintextSha256: sha,
            nonceHex: String(repeating: "b", count: 24),
            fileName: "video.mp4",
            mediaType: "video/mp4",
            version: .v2,
            sourceEpoch: 1,
            sourceEpochIdentity: nil,
            dim: nil,
            thumbhash: nil
        )
        // Prime the host plaintext cache so a cache-before-MDK shortcut would hit it.
        MessageMediaCache.store(payload, for: reference, cachesDirectory: cachesDirectory)
        let primedURL = await MessageMediaCache.validCachedFileURL(for: reference, cachesDirectory: cachesDirectory)
        #expect(primedURL != nil)

        try await withTestClient { client in
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: client.relayUrls,
                bootstrapRelays: client.relayUrls
            ).account
            let missingTarget = AttachmentLocalTargetFfi(
                messageIdHex: String(repeating: "11", count: 32),
                sourceMessageIdHex: String(repeating: "22", count: 32),
                attachmentIndex: 0
            )
            // Requesting playback for an unavailable/revoked slot must fail
            // through MDK authorization rather than returning primed plaintext.
            await #expect(throws: Error.self) {
                _ = try await client.acquireAttachmentPlaybackFile(
                    accountRef: account.label,
                    groupID: String(repeating: "ab", count: 32),
                    target: missingTarget,
                    demand: .automatic,
                    reference: reference,
                    producerGeneration: MessageMediaCache.currentProducerEpoch(),
                    cachesDirectory: cachesDirectory
                )
            }
        }
    }

    @Test func streamAndStoreSweepsAbandonedStagingFilesWhilePreservingActiveWriter() async throws {
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-sweep-\(UUID().uuidString)", isDirectory: true)
        let encryptedDir = cachesDirectory.appendingPathComponent(
            "EncryptedMedia",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: encryptedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        // Plant an abandoned staging file left over from a simulated prior crash.
        let abandoned = encryptedDir.appendingPathComponent(".staging-abandoned-crash")
        try Data("stale partial bytes".utf8).write(to: abandoned)
        #expect(FileManager.default.fileExists(atPath: abandoned.path))

        let payload = Data("fresh streamed video".utf8)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let reference = MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/fresh.mp4")],
            ciphertextSha256: String(repeating: "c", count: 64),
            plaintextSha256: sha,
            nonceHex: String(repeating: "d", count: 24),
            fileName: "fresh.mp4",
            mediaType: "video/mp4",
            version: .v2,
            sourceEpoch: 1,
            sourceEpochIdentity: nil,
            dim: nil,
            thumbhash: nil
        )

        let chunkEntered = TestLatch()
        let chunkRelease = TestLatch()
        let streamTask = Task {
            try await MessageMediaCache.streamAndStore(
                for: reference,
                byteCount: UInt64(payload.count),
                cachesDirectory: cachesDirectory
            ) { offset, limit in
                if offset == 0 {
                    chunkEntered.signal()
                    try await chunkRelease.wait()
                }
                let start = Int(offset)
                let end = min(payload.count, start + Int(limit))
                return AttachmentLocalBytesFfi(
                    available: true,
                    bytes: start < end ? payload[start..<end] : Data()
                )
            }
        }

        try await chunkEntered.wait()
        // The abandoned staging file must already have been swept on startup,
        // and a concurrent manual sweep must NOT delete the active writer's file.
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        MessageMediaCache.sweepAbandonedStagingFiles(in: encryptedDir)
        let activeEntries = try FileManager.default.contentsOfDirectory(atPath: encryptedDir.path)
        #expect(activeEntries.count == 1)
        #expect(activeEntries[0].hasPrefix(MessageMediaCache.stagingPrefix))

        chunkRelease.signal()
        let publishedURL = try await streamTask.value
        #expect(try Data(contentsOf: publishedURL) == payload)
        let finalEntries = try FileManager.default.contentsOfDirectory(atPath: encryptedDir.path)
        #expect(finalEntries == [publishedURL.lastPathComponent])
    }

    @Test func sharedMediaThumbnailVideoLoadsApplyVideoPreviewByteLimit() async throws {
        var recorded: [(mediaType: String, demand: AttachmentDemand, limit: Int?)] = []
        let loader = ConversationMediaLoader { item in
            recorded.append((item.mediaType, item.demand, item.previewByteLimit))
            return Data([1, 2, 3])
        }
        let video = attachment("video/mp4")
        let image = attachment("image/jpeg")

        _ = try await GroupSharedMediaThumbnailLoader.loadData(for: video, demand: .automatic, using: loader)
        _ = try await GroupSharedMediaThumbnailLoader.loadData(for: video, demand: .explicit, using: loader)
        _ = try await GroupSharedMediaThumbnailLoader.loadData(for: image, demand: .explicit, using: loader)

        #expect(recorded.count == 3)
        #expect(recorded[0].demand == .automatic && recorded[0].limit != nil)
        #expect(recorded[1].demand == .explicit && recorded[1].limit != nil)
        #expect(recorded[2].demand == .explicit && recorded[2].limit == nil)
    }
}

private nonisolated final class RecordingAttachmentDemandRequester: AttachmentDemandRequesting {
    struct Call: Equatable {
        enum Kind { case automatic, explicit, downloadAgain }
        let kind: Kind
        let accountRef: String
        let groupID: String
        let target: AttachmentLocalTargetFfi
    }

    private let reference: String?
    private let automaticState: AttachmentTransferStateFfi
    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    init(reference: String?, automaticState: AttachmentTransferStateFfi = .queued) {
        self.reference = reference
        self.automaticState = automaticState
    }

    private func record(_ kind: Call.Kind, _ accountRef: String, _ groupID: String, _ target: AttachmentLocalTargetFfi) {
        recorded.withLock { $0.append(Call(kind: kind, accountRef: accountRef, groupID: groupID, target: target)) }
    }

    func requestAutomaticAttachment(accountRef: String, groupIdHex: String,
                                    target: AttachmentLocalTargetFfi) async throws -> AutomaticAttachmentRequestFfi {
        record(.automatic, accountRef, groupIdHex, target)
        return AutomaticAttachmentRequestFfi(status: AttachmentTransferStatusFfi(reference: reference,
            state: automaticState, attempt: 0, received: 0, total: nil, retryAt: nil), newlyQueued: true)
    }

    func requestExplicitAttachment(accountRef: String, groupIdHex: String,
                                   target: AttachmentLocalTargetFfi) async throws -> String? {
        record(.explicit, accountRef, groupIdHex, target)
        return reference
    }

    func downloadAttachmentAgain(accountRef: String, groupIdHex: String,
                                 target: AttachmentLocalTargetFfi) async throws -> String? {
        record(.downloadAgain, accountRef, groupIdHex, target)
        return reference
    }
}
