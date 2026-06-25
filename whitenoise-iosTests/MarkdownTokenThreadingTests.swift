import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// Rust pre-parses markdown into `contentTokens` on every chat record; the
/// view model's record conversions must not drop them on the floor (they did,
/// via the `.emptyDocument` compatibility initializers).
@MainActor
struct MarkdownTokenThreadingTests {

    private let tokens = MarkdownDocumentFfi(blocks: [
        .paragraph(inlines: [.strong(children: [.text(content: "hi")])])
    ])

    @Test func timelineConversionKeepsContentTokens() {
        let record = TimelineMessageRecordFfi(
            messageIdHex: "01",
            sourceMessageIdHex: nil,
            direction: "received",
            groupIdHex: "aa",
            sender: "11",
            plaintext: "**hi**",
            contentTokens: tokens,
            kind: MessageSemantics.kindChat,
            tags: [],
            timelineAt: 1,
            receivedAt: 1,
            replyToMessageIdHex: nil,
            replyPreview: nil,
            mediaJson: nil,
            media: [],
            agentTextStreamJson: nil,
            groupSystem: nil,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
            deleted: false,
            deletedByMessageIdHex: nil,
            invalidationStatus: nil
        )

        let converted = ConversationViewModel.appMessageRecord(from: record)
        #expect(converted.contentTokens == tokens)
    }

    /// Regression: confirmSent rebuilt the timeline record through the
    /// token-less compatibility init, so a sent bubble rendered markdown
    /// optimistically and snapped back to plain text on send confirmation.
    @Test func confirmSentKeepsContentTokensOnTheTimelineRecord() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: "aa",
            sender: "11",
            plaintext: "**hi**",
            contentTokens: tokens,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-1", record: pending)
        viewModel.confirmSent(tempId: "pending-1", record: pending, messageId: "01")

        let confirmed = viewModel.timeline.compactMap { item -> AppMessageRecordFfi? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record
        }
        #expect(confirmed.count == 1)
        #expect(confirmed.first?.contentTokens == tokens)
    }

    @Test func timelinePagePrecomputesMarkdownBlocksForMessageRows() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let record = TimelineMessageRecordFfi(
            messageIdHex: "01",
            sourceMessageIdHex: nil,
            direction: "received",
            groupIdHex: "aa",
            sender: "11",
            plaintext: "**hi**",
            contentTokens: tokens,
            kind: MessageSemantics.kindChat,
            tags: [],
            timelineAt: 1,
            receivedAt: 1,
            replyToMessageIdHex: nil,
            replyPreview: nil,
            mediaJson: nil,
            media: [],
            agentTextStreamJson: nil,
            groupSystem: nil,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
            deleted: false,
            deletedByMessageIdHex: nil,
            invalidationStatus: nil
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let item = try #require(viewModel.timeline.first)
        let blocks = try #require(viewModel.markdownDisplayBlocks(for: item))
        guard case .paragraph(let attributed) = try #require(blocks.first) else {
            Issue.record("Expected a precomputed paragraph block")
            return
        }
        #expect(String(attributed.characters) == "hi")
    }

    private func testGroup() -> AppGroupRecordFfi {
        AppGroupRecordFfi(
            groupIdHex: "aa",
            endpoint: "",
            name: "g",
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

    @Test func liveReceiveConversionKeepsContentTokens() {
        let received = RuntimeMessageReceivedFfi(
            accountIdHex: "22",
            accountLabel: "label",
            message: ReceivedMessageFfi(
                messageIdHex: "02",
                groupIdHex: "aa",
                sender: "11",
                senderDisplayName: nil,
                plaintext: "**hi**",
                contentTokens: tokens,
                kind: MessageSemantics.kindChat,
                tags: [],
                recordedAt: 5
            )
        )

        let converted = ConversationViewModel.receivedToRecord(received, now: 9)
        #expect(converted.contentTokens == tokens)
        #expect(converted.recordedAt == 5)
    }
}
