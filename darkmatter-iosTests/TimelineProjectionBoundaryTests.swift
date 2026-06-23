import Foundation
import Testing
@testable import darkmatter_ios
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

    @Test func conversationTimelineDoesNotCallListMediaOrRecoverSourceEpoch() throws {
        let sources = try [
            "darkmatter-ios/Conversation/ConversationViewModel.swift",
            "darkmatter-ios/Conversation/TimelineStore.swift",
            "darkmatter-ios/Conversation/ConversationMediaProjectionCache.swift",
            "darkmatter-ios/Conversation/ConversationMediaDownloader.swift",
        ].map(sourceString).joined(separator: "\n")

        #expect(!sources.matches(#"\blistMedia\s*\("#))
        #expect(!sources.contains("mediaRecordsByMessageId"))
        #expect(!sources.contains("mediaRecordReferencesByKey"))
        #expect(!sources.contains("refreshMediaRecords"))
        #expect(!sources.contains("scheduleMediaRecordsRefresh"))
        #expect(!sources.matches(#"\bsourceEpoch\s*==\s*0\b"#))
        #expect(!sources.contains("mediaRecordReference(matching:"))
    }

    @Test func displayTimelineDoesNotParseMarkdownAtRenderTime() throws {
        let displaySources = try [
            "darkmatter-ios/Conversation/ConversationView.swift",
            "darkmatter-ios/Conversation/MessageBubble.swift",
            "darkmatter-ios/Conversation/TimelineStore.swift",
            "darkmatter-ios/Conversation/ConversationMarkdownProjectionCache.swift",
            "darkmatter-ios/Conversation/MarkdownMessageModel.swift",
        ].map(sourceString).joined(separator: "\n")

        #expect(!displaySources.matches(#"\bparseMarkdown\s*\("#))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
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

private let testGroupId = String(repeating: "b", count: 64)

private func hexId(_ n: Int) -> String {
    String(format: "%064x", n)
}

private func hex32(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
