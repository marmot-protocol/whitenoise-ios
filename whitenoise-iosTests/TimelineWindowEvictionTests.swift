import Foundation
import Testing
@testable import whitenoise_ios
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

    @MainActor
    @Test func confirmedSentMessageSurvivesWindowPageUntilMirrored() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let retained = timelineRecord(messageIdHex: hexId(1), timelineAt: 1)
        let tempId = "pending-1"
        let confirmedId = hexId(2)
        let pending = pendingSentRecord(timelineAt: 2)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: confirmedId)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        var ids = timelineMessageIds(in: viewModel)
        #expect(ids.contains(retained.messageIdHex))
        #expect(ids.contains(confirmedId))

        let mirrored = timelineRecord(
            messageIdHex: confirmedId,
            timelineAt: 2,
            direction: "sent"
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained, mirrored], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        ids = timelineMessageIds(in: viewModel)
        #expect(ids.contains(retained.messageIdHex))
        #expect(!ids.contains(confirmedId))
    }

    @MainActor
    @Test func confirmedSentMessageSurvivesEdgeFlagChangeUntilMirrored() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let retained = timelineRecord(messageIdHex: hexId(1), timelineAt: 1)
        let tempId = "pending-edge"
        let confirmedId = hexId(3)
        let pending = pendingSentRecord(timelineAt: 2)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained], hasMoreBefore: true, hasMoreAfter: true),
            placement: .window
        )
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: confirmedId)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained], hasMoreBefore: false, hasMoreAfter: true),
            placement: .window
        )

        var ids = timelineMessageIds(in: viewModel)
        #expect(ids.contains(retained.messageIdHex))
        #expect(ids.contains(confirmedId))

        let mirrored = timelineRecord(
            messageIdHex: confirmedId,
            timelineAt: 2,
            direction: "sent"
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained, mirrored], hasMoreBefore: false, hasMoreAfter: true),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [retained], hasMoreBefore: true, hasMoreAfter: true),
            placement: .window
        )

        ids = timelineMessageIds(in: viewModel)
        #expect(ids.contains(retained.messageIdHex))
        #expect(!ids.contains(confirmedId))
    }
}

private let testGroupId = String(repeating: "b", count: 64)

private func timelineRecord(
    messageIdHex: String,
    timelineAt: UInt64,
    direction: String = "received"
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: nil,
        direction: direction,
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
        media: [],
        agentTextStreamJson: nil,
        groupSystem: nil,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

private func pendingSentRecord(timelineAt: UInt64) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: "",
        direction: "sent",
        groupIdHex: testGroupId,
        sender: String(repeating: "a", count: 64),
        plaintext: "just sent",
        kind: MessageSemantics.kindChat,
        tags: [],
        recordedAt: timelineAt,
        receivedAt: timelineAt
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
