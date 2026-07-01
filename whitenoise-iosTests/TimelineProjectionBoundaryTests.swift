import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct TimelineProjectionBoundaryTests {
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

    @Test func mediaDownloaderProbesDecryptedCacheOnlyOnceBeforeDownload() async throws {
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
        let downloaded = DownloadMediaSpy(data: Data([0x09, 0x0a, 0x0b]))
        let downloader = ConversationMediaDownloader(
            cache: cached,
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

    private func timelineRecord(
        messageIdHex: String,
        plaintext: String,
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
            contentTokens: MarkdownDocumentFfi.emptyDocument,
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

    private func mediaReference(sourceEpoch: UInt64) -> MediaAttachmentReferenceFfi {
        MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/a.png")],
            ciphertextSha256: hex32("44"),
            plaintextSha256: hex32("33"),
            nonceHex: String(repeating: "22", count: 12),
            fileName: "a.png",
            mediaType: "image/png",
            version: MessageSemantics.encryptedMediaVersion,
            sourceEpoch: sourceEpoch,
            dim: nil,
            thumbhash: nil
        )
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
                mediaFormat: MessageSemantics.encryptedMediaVersion,
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

    func cachedData(for reference: MediaAttachmentReferenceFfi) async -> Data? {
        cachedDataCalls += 1
        return cachedDataToReturn
    }

    func store(_ data: Data, for reference: MediaAttachmentReferenceFfi) async {
        storedPayloads.append(data)
        storedReferenceHashes.append(reference.plaintextSha256)
        storedSourceEpochs.append(reference.sourceEpoch)
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
