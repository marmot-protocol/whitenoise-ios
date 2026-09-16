import Foundation
import CryptoKit
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct TimelineProjectionBoundaryTests {
    @Test func rejectedSiblingsKeepTheirSlotAndCannotBecomeDownloadable() {
        let reference = mediaReference(sourceEpoch: 42)
        let outcomes: [MediaAttachmentOutcomeFfi] = [
            .rejected(attachmentIndex: 0, rejection: MediaAttachmentRejectionFfi(kind: .unsupportedFormat, detail: "peer supplied detail")),
            .accepted(attachmentIndex: 1, reference: reference),
            .rejected(attachmentIndex: 2, rejection: MediaAttachmentRejectionFfi(kind: .malformedField, detail: "untrusted")),
        ]
        let items = MessageMediaAttachment.displayItems(fromOutcomes: outcomes, ownerId: "message-a")
        #expect(items.count == 3)
        #expect(items[0].reference == nil)
        #expect(items[0].rejectionMessage == L10n.string("Unsupported attachment"))
        #expect(items[1].reference == reference)
        #expect(items[1].id.hasSuffix(":1"))
        #expect(items[2].rejectionMessage == L10n.string("Attachment couldn’t be read"))
        let another = MessageMediaAttachment.displayItems(fromOutcomes: outcomes, ownerId: "message-b")
        #expect(Set(items.map(\.id)).isDisjoint(with: another.map(\.id)))
    }

    @Test func mediaCacheTreatsPresentEmptyRowProjectionAsAuthoritative() {
        let cache = ConversationMediaProjectionCache()
        let reference = mediaReference(sourceEpoch: 42)
        let record = appRecord(
            messageIdHex: hexId(1),
            plaintext: "caption",
            tags: [MessageSemantics.imetaTag(for: reference)]
        )

        // No mirrored row projection yet: local/optimistic compatibility records
        // may still render from tags.
        #expect(cache.build(for: record, ownerId: "msg:\(record.messageIdHex)").count == 1)

        // Once Marmot's row projection has been mirrored, even an empty projection
        // is truth. Do not re-derive media from tags and reintroduce source-epoch
        // or drop-bad disagreement in Swift.
        cache.setReferences([], forMessageId: record.messageIdHex)
        #expect(cache.build(for: record, ownerId: "msg:\(record.messageIdHex)").isEmpty)
    }

    @Test func timelineDoesNotRenderTagMediaWhenRowProjectionIsEmpty() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let reference = mediaReference(sourceEpoch: 7)
        let record = timelineRecord(
            messageIdHex: hexId(2),
            plaintext: "caption",
            tags: [MessageSemantics.imetaTag(for: reference)],
            media: []
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let item = try #require(viewModel.timeline.first)
        #expect(viewModel.mediaItems(for: item).isEmpty)
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == 0)
    }

    @Test func mirroredNilReplyTargetDoesNotFallBackToTags() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let target = timelineRecord(messageIdHex: hexId(3), plaintext: "target body")
        let reply = timelineRecord(
            messageIdHex: hexId(4),
            plaintext: "reply body",
            tags: [
                MessageTagFfi(values: [MessageSemantics.eventRefTag, target.messageIdHex]),
                MessageTagFfi(values: [MessageSemantics.quoteRefTag, target.messageIdHex]),
            ],
            replyToMessageIdHex: nil,
            replyPreview: nil
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [target, reply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let replyRecord = try #require(viewModel.record(for: reply.messageIdHex))
        if let preview = viewModel.replyPreview(for: replyRecord) {
            Issue.record("Expected mirrored nil reply target to suppress tag fallback, got \(preview)")
        }
    }

    @Test func projectedReplyTargetCanUseLoadedTargetAsPreviewFallback() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let target = timelineRecord(messageIdHex: hexId(5), plaintext: "target body")
        let reply = timelineRecord(
            messageIdHex: hexId(6),
            plaintext: "reply body",
            replyToMessageIdHex: target.messageIdHex,
            replyPreview: nil
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [target, reply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let replyRecord = try #require(viewModel.record(for: reply.messageIdHex))
        let preview = try #require(viewModel.replyPreview(for: replyRecord))
        #expect(preview.text == "target body")
    }

    @Test func projectedReplyPreviewCarriesResolvedMediaWithoutAnotherLookup() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let targetID = hexId(11)
        let reference = mediaReference(sourceEpoch: 23)
        let reply = timelineRecord(
            messageIdHex: hexId(12),
            plaintext: "reply body",
            replyToMessageIdHex: targetID,
            replyPreview: TimelineReplyPreviewFfi(
                messageIdHex: targetID,
                sender: hexId(10),
                plaintext: "",
                kind: MessageSemantics.kindChat,
                mediaJson: nil,
                media: [reference],
                agentTextStreamJson: nil,
                deleted: false
            )
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [reply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let replyRecord = try #require(viewModel.record(for: reply.messageIdHex))
        let preview = try #require(viewModel.replyPreview(for: replyRecord))
        #expect(preview.media?.reference == reference)
        #expect(preview.media?.id.contains(targetID) == true)
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == 0)
    }

    @Test func markdownProjectionCacheSkipsUnchangedWindowRows() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let tokens = doc([.paragraph(inlines: [.text(content: "hello **world**")])])
        let record = timelineRecord(
            messageIdHex: hexId(7),
            plaintext: "hello **world**",
            contentTokens: tokens
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.markdownProjectionBuildCountForTesting == 1)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.markdownProjectionBuildCountForTesting == 1)

        let updated = timelineRecord(
            messageIdHex: record.messageIdHex,
            plaintext: "hello again",
            contentTokens: doc([.paragraph(inlines: [.text(content: "hello again")])])
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [updated], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.markdownProjectionBuildCountForTesting == 2)
    }

    @Test func mediaProjectionCacheSkipsUnchangedWindowRows() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let reference = mediaReference(sourceEpoch: 7)
        let record = timelineRecord(
            messageIdHex: hexId(8),
            plaintext: "caption",
            tags: [MessageSemantics.imetaTag(for: reference)],
            media: [reference]
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == 1)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == 1)

        let updatedReference = mediaReference(sourceEpoch: 8)
        let updated = timelineRecord(
            messageIdHex: record.messageIdHex,
            plaintext: record.plaintext,
            tags: [MessageSemantics.imetaTag(for: updatedReference)],
            media: [updatedReference]
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [updated], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == 2)
    }

    @Test func authoritativeWindowSkipsDiscardedReactionTargetCollection() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let record = timelineRecord(messageIdHex: hexId(9), plaintext: "hello")
        let page = TimelinePageFfi(messages: [record], hasMoreBefore: true, hasMoreAfter: false)

        viewModel.applyTimelinePage(page, placement: .window)
        #expect(viewModel.reactionTargetCollectionCountForTesting == 0)

        viewModel.applyTimelinePage(page, placement: .window)
        #expect(viewModel.reactionTargetCollectionCountForTesting == 1)
    }

    @Test func mediaDownloaderProbesDecryptedCacheOnlyOnceBeforeDownload() async throws {
        let downloadedData = Data([0x09, 0x0a, 0x0b])
        let reference = mediaReference(sourceEpoch: 7, plaintext: downloadedData)
        let media = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cached = CountingConversationMediaCache()
        let downloaded = DownloadMediaSpy(data: downloadedData)
        let downloader = ConversationMediaDownloader(
            cache: cached,
            locatorResolver: { _ in ["93.184.216.34"] },
            downloadMedia: { client, accountRef, groupIdHex, reference in
                try await downloaded.download(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
            }
        )
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-a"

        let data = try await downloader.data(for: media, groupIdHex: testGroupId, appState: appState)

        #expect(data == downloaded.data)
        #expect(cached.cachedDataCalls == 1)
        #expect(cached.storedPayloads == [downloaded.data])
        #expect(cached.storedReferenceHashes == [reference.plaintextSha256])
        #expect(cached.storedSourceEpochs == [reference.sourceEpoch])
        #expect(downloaded.accountRefs == ["account-a"])
        #expect(downloaded.groupIds == [testGroupId])
        #expect(downloaded.referenceHashes == [reference.plaintextSha256])
        #expect(downloaded.sourceEpochs == [reference.sourceEpoch])
    }

    @Test func mediaDownloaderRejectsPlaintextHashMismatchBeforeCaching() async throws {
        let reference = mediaReference(sourceEpoch: 7, plaintext: Data([0x01]))
        let media = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cached = CountingConversationMediaCache()
        let downloaded = DownloadMediaSpy(data: Data([0xff]))
        let downloader = ConversationMediaDownloader(
            cache: cached,
            locatorResolver: { _ in ["93.184.216.34"] },
            downloadMedia: { client, accountRef, groupIdHex, reference in
                try await downloaded.download(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
            }
        )
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-a"

        await #expect(throws: ConversationMediaDownloader.MediaDataError.plaintextHashMismatch) {
            _ = try await downloader.data(for: media, groupIdHex: testGroupId, appState: appState)
        }
        #expect(cached.storedPayloads.isEmpty)
    }

    @Test func mediaDownloaderRejectsUnsafeStaticLocatorBeforeCacheOrNativeDownload() async throws {
        let reference = mediaReference(
            sourceEpoch: 7,
            locatorValue: "http://media.example/a.png"
        )
        let media = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cached = CountingConversationMediaCache()
        let downloaded = DownloadMediaSpy(data: Data([0x01]))
        let downloader = ConversationMediaDownloader(
            cache: cached,
            locatorResolver: { _ in ["93.184.216.34"] },
            downloadMedia: { client, accountRef, groupIdHex, reference in
                try await downloaded.download(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
            }
        )
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-a"

        await #expect(throws: ConversationMediaDownloader.MediaDataError.unsafeLocator) {
            _ = try await downloader.data(for: media, groupIdHex: testGroupId, appState: appState)
        }
        #expect(cached.cachedDataCalls == 0)
        #expect(downloaded.referenceHashes.isEmpty)
    }

    @Test func mediaDownloaderRejectsPrivateDnsBeforeNativeDownload() async throws {
        let reference = mediaReference(sourceEpoch: 7)
        let media = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cached = CountingConversationMediaCache()
        let downloaded = DownloadMediaSpy(data: Data([0x01]))
        let downloader = ConversationMediaDownloader(
            cache: cached,
            locatorResolver: { _ in ["10.0.0.5"] },
            downloadMedia: { client, accountRef, groupIdHex, reference in
                try await downloaded.download(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
            }
        )
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-a"

        await #expect(throws: ConversationMediaDownloader.MediaDataError.unsafeLocator) {
            _ = try await downloader.data(for: media, groupIdHex: testGroupId, appState: appState)
        }
        #expect(cached.cachedDataCalls == 1)
        #expect(downloaded.referenceHashes.isEmpty)
    }

    @Test func mediaUploadIntegrityDropsMismatchedReferences() async {
        let acceptedData = Data([0x01, 0x02])
        let rejectedData = Data([0x03, 0x04])
        let acceptedReference = mediaReference(sourceEpoch: 7, plaintext: acceptedData)
        let rejectedReference = mediaReference(sourceEpoch: 8, plaintext: Data([0xff]))

        let verified = await MediaUploadIntegrity.verifiedAttachments(
            plaintexts: [acceptedData, rejectedData],
            references: [acceptedReference, rejectedReference]
        )

        #expect(verified.map(\.data) == [acceptedData])
        #expect(verified.map(\.reference.plaintextSha256) == [acceptedReference.plaintextSha256])
    }

    @Test func mediaDownloaderIgnoresHashMismatchedCacheHit() async throws {
        let downloadedData = Data([0x0c, 0x0d, 0x0e])
        let reference = mediaReference(sourceEpoch: 7, plaintext: downloadedData)
        let media = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cached = CountingConversationMediaCache()
        cached.cachedDataToReturn = Data([0xff])
        let downloaded = DownloadMediaSpy(data: downloadedData)
        let downloader = ConversationMediaDownloader(
            cache: cached,
            locatorResolver: { _ in ["93.184.216.34"] },
            downloadMedia: { client, accountRef, groupIdHex, reference in
                try await downloaded.download(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
            }
        )
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-a"

        let data = try await downloader.data(for: media, groupIdHex: testGroupId, appState: appState)

        #expect(data == downloadedData)
        #expect(cached.cachedDataCalls == 1)
        #expect(cached.storedPayloads == [downloadedData])
        #expect(downloaded.referenceHashes == [reference.plaintextSha256])
    }

    @Test func mediaDownloaderCoalescesConcurrentCacheVerification() async throws {
        let cachedData = Data(repeating: 0x5a, count: 512 * 1024)
        let reference = mediaReference(sourceEpoch: 7, plaintext: cachedData)
        let media = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cached = CountingConversationMediaCache()
        cached.cachedDataToReturn = cachedData
        cached.blocksCachedDataRead = true
        let downloader = ConversationMediaDownloader(cache: cached)

        let first = Task {
            try await downloader.data(for: media, groupIdHex: testGroupId, appState: nil)
        }
        await cached.waitForCachedDataRead()
        let secondRequestStarted = AsyncTestSignal()
        let second = Task<Data, Error> {
            secondRequestStarted.signal()
            return try await downloader.data(for: media, groupIdHex: testGroupId, appState: nil)
        }
        await secondRequestStarted.wait()
        cached.releaseCachedDataRead()

        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult == cachedData)
        #expect(secondResult == cachedData)
        #expect(cached.cachedDataCalls == 1)
        #expect(cached.storedPayloads.isEmpty)
    }

    private func timelineRecord(
        messageIdHex: String,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi = MarkdownDocumentFfi.emptyDocument,
        tags: [MessageTagFfi] = [],
        media: [MediaAttachmentReferenceFfi] = [],
        replyToMessageIdHex: String? = nil,
        replyPreview: TimelineReplyPreviewFfi? = nil
    ) -> TimelineMessageRecordFfi {
        TimelineMessageRecordFfi(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: nil,
            direction: "received",
            groupIdHex: testGroupId,
            sender: hexId(10),
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: MessageSemantics.kindChat,
            tags: tags,
            timelineAt: UInt64(Int(messageIdHex.suffix(2), radix: 16) ?? 1),
            receivedAt: UInt64(Int(messageIdHex.suffix(2), radix: 16) ?? 1),
            replyToMessageIdHex: replyToMessageIdHex,
            replyPreview: replyPreview,
            mediaJson: nil,
            media: media,
            agentTextStreamJson: nil,
            groupSystem: nil,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
            deleted: false,
            deletedByMessageIdHex: nil,
            invalidationStatus: nil
        )
    }

    private func doc(_ blocks: [MarkdownBlockFfi]) -> MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: blocks, truncated: false)
    }

    private func appRecord(
        messageIdHex: String,
        plaintext: String,
        tags: [MessageTagFfi]
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: messageIdHex,
            direction: "sent",
            groupIdHex: testGroupId,
            sender: hexId(10),
            plaintext: plaintext,
            contentTokens: MarkdownDocumentFfi.emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: tags,
            recordedAt: 1,
            receivedAt: 1
        )
    }

    private func mediaReference(
        sourceEpoch: UInt64,
        plaintext: Data? = nil,
        locatorValue: String = "https://media.example/4444444444444444444444444444444444444444444444444444444444444444.bin"
    ) -> MediaAttachmentReferenceFfi {
        MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: locatorValue)],
            ciphertextSha256: hex32("44"),
            plaintextSha256: plaintext.map(sha256Hex(of:)) ?? hex32("33"),
            nonceHex: String(repeating: "22", count: 12),
            fileName: "a.png",
            mediaType: "image/png",
            version: .v1,
            sourceEpoch: sourceEpoch,
            dim: nil,
            thumbhash: nil
        )
    }

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func testGroup() -> AppGroupRecordFfi {
        AppGroupRecordFfi(
            groupIdHex: testGroupId,
            endpoint: "",
            name: "Test Group",
            description: "",
            admins: [],
            relays: [],
            nostrGroupIdHex: "",
            avatarUrl: nil,
            avatarDim: nil,
            avatarThumbhash: nil,
            encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                componentId: 0x8008,
                component: "marmot.group.encrypted-media.v1",
                required: true,
                mediaFormat: EncryptedMediaVersionFfi.v1.wireValue,
                allowedLocatorKinds: ["blossom-v1"],
                defaultBlobEndpoints: [
                    AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
                ]
            ),
            archived: false,
            pendingConfirmation: false,
            welcomerAccountIdHex: nil,
            viaWelcomeMessageIdHex: nil
        )
    }
}

@MainActor
private final class CountingConversationMediaCache: ConversationMediaCacheAccessing {
    private(set) var cachedDataCalls = 0
    private(set) var storedPayloads: [Data] = []
    private(set) var storedReferenceHashes: [String] = []
    private(set) var storedSourceEpochs: [UInt64] = []
    var cachedDataToReturn: Data?
    var blocksCachedDataRead = false
    private let cachedDataReadStarted = AsyncTestSignal()
    private let cachedDataReadReleased = AsyncTestSignal()

    func cachedData(for reference: MediaAttachmentReferenceFfi) async -> Data? {
        cachedDataCalls += 1
        if blocksCachedDataRead {
            cachedDataReadStarted.signal()
            await cachedDataReadReleased.wait()
        }
        return cachedDataToReturn
    }

    func waitForCachedDataRead() async {
        await cachedDataReadStarted.wait()
    }

    func releaseCachedDataRead() {
        cachedDataReadReleased.signal()
    }

    func store(_ data: Data, for reference: MediaAttachmentReferenceFfi, producerGeneration: Int?) async {
        storedPayloads.append(data)
        storedReferenceHashes.append(reference.plaintextSha256)
        storedSourceEpochs.append(reference.sourceEpoch)
    }
}

@MainActor
private final class AsyncTestSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

@MainActor
private final class DownloadMediaSpy {
    let data: Data
    private(set) var accountRefs: [String] = []
    private(set) var groupIds: [String] = []
    private(set) var referenceHashes: [String] = []
    private(set) var sourceEpochs: [UInt64] = []

    init(data: Data) {
        self.data = data
    }

    func download(
        client: MarmotClient,
        accountRef: String,
        groupIdHex: String,
        reference: MediaAttachmentReferenceFfi
    ) async throws -> MediaDownloadResultFfi {
        _ = client
        accountRefs.append(accountRef)
        groupIds.append(groupIdHex)
        referenceHashes.append(reference.plaintextSha256)
        sourceEpochs.append(reference.sourceEpoch)
        return MediaDownloadResultFfi(
            plaintext: data,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            sizeBytes: UInt64(data.count)
        )
    }
}

private let testGroupId = String(repeating: "b", count: 64)

private func hexId(_ n: Int) -> String {
    String(format: "%064x", n)
}

private func hex32(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}
