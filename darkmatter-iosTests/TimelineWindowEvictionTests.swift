import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

struct TimelineWindowEvictionTests {
    @MainActor
    @Test func boundedWindowPageKeepsPreviouslyLoadedHistory() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let older = timelineRecord(messageIdHex: hexId(1), timelineAt: 1)
        let newest = timelineRecord(messageIdHex: hexId(2), timelineAt: 2)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [older, newest], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [newest], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )

        let ids = timelineMessageIds(in: viewModel)
        #expect(ids.contains(older.messageIdHex))
        #expect(ids.contains(newest.messageIdHex))
    }

    @MainActor
    @Test func projectionRemoveEvictsOnlyAuthoritativelyRemovedRecord() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let removed = timelineRecord(messageIdHex: hexId(1), timelineAt: 1)
        let retained = timelineRecord(messageIdHex: hexId(2), timelineAt: 2)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [removed, retained], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyTimelineSubscriptionUpdate(.projection(update: RuntimeProjectionUpdateFfi(
            accountIdHex: "",
            accountLabel: "",
            update: TimelineProjectionUpdateFfi(
                groupIdHex: testGroupId,
                messages: [],
                changes: [.remove(messageIdHex: removed.messageIdHex, reason: .pruned)],
                chatListRow: nil,
                chatListTrigger: .lastMessageDeleted
            )
        )))

        let ids = timelineMessageIds(in: viewModel)
        #expect(!ids.contains(removed.messageIdHex))
        #expect(ids.contains(retained.messageIdHex))
    }
}

private let testGroupId = String(repeating: "b", count: 64)

private func timelineRecord(messageIdHex: String, timelineAt: UInt64) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: nil,
        direction: "received",
        groupIdHex: testGroupId,
        sender: String(repeating: "a", count: 64),
        plaintext: "message \(timelineAt)",
        contentTokens: MarkdownDocumentFfi.emptyDocument,
        kind: MessageSemantics.kindChat,
        tags: [],
        timelineAt: timelineAt,
        receivedAt: timelineAt,
        replyToMessageIdHex: nil,
        replyPreview: nil,
        mediaJson: nil,
        agentTextStreamJson: nil,
        groupSystem: nil,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

@MainActor
private func timelineMessageIds(in viewModel: ConversationViewModel) -> [String] {
    viewModel.timeline.compactMap { item in
        if case .message(let record, _) = item.kind {
            return record.messageIdHex
        }
        return nil
    }
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

private func hexId(_ n: Int) -> String {
    String(format: "%064x", n)
}
