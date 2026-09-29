import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct HistoryNoticeAndPendingEditTests {
    private static let group = String(repeating: "c", count: 64)

    private static func record(
        id: String,
        kind: UInt64 = MessageSemantics.kindChat,
        direction: String = "sent",
        delivered: Bool,
        token: String?,
        poll: PollProjectionFfi? = nil
    ) -> TimelineMessageRecordFfi {
        var record = TimelineMessageRecordFfi(
            messageIdHex: id, sourceMessageIdHex: delivered ? id : nil, direction: direction,
            groupIdHex: group, sender: String(repeating: "a", count: 64), plaintext: "Lunch?",
            contentTokens: .emptyDocument, kind: kind, tags: [],
            timelineAt: 1, receivedAt: 1, replyToMessageIdHex: nil, replyPreview: nil,
            mediaJson: nil, media: [], agentTextStreamJson: nil, groupSystem: nil, poll: poll,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil,
            deleted: false, deletedByMessageIdHex: nil, invalidationStatus: nil
        )
        record.clientToken = token
        return record
    }

    // MARK: History notices

    @Test func everyNoticeCauseHasItsOwnWording() {
        let causes: [HistoryNoticeCauseFfi] = [
            .deliveryLoss, .notificationLoss, .epochGap, .incrementalHistory,
            .explicitRepair, .knownEvent, .maintenanceBoundary
        ]
        let messages = causes.map(HistoryNoticePresentation.message(for:))
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(HistoryNoticePresentation.message(for: .deliveryLoss)
            == HistoryNoticePresentation.message(for: .notificationLoss))
        #expect(Set(messages).count == causes.count - 1)
    }

    @Test func groupNoticeUsesItsOwnOccurrenceCauseOrFallsBackToAnEpochGap() {
        let notices = [
            HistoryNoticeFfi(noticeId: "a", cause: .deliveryLoss, groupIdHex: nil, parkedAtMs: nil),
            HistoryNoticeFfi(noticeId: "b", cause: .incrementalHistory, groupIdHex: Self.group, parkedAtMs: 1)
        ]
        #expect(HistoryNoticePresentation.groupMessage(noticeIDs: ["b"], notices: notices)
            == HistoryNoticePresentation.message(for: .incrementalHistory))
        #expect(HistoryNoticePresentation.groupMessage(noticeIDs: ["unknown"], notices: notices)
            == HistoryNoticePresentation.message(for: .epochGap))
    }

    // MARK: Pending edits

    @Test func onlyUnsettledTextAndRepliesUseThePendingEditQueue() {
        let text = AppMessageRecordFfi(messageIdHex: "01", direction: "sent", groupIdHex: Self.group, sender: "",
                                       plaintext: "hi", kind: MessageSemantics.kindChat, tags: [],
                                       recordedAt: 1, receivedAt: 1)
        let poll = AppMessageRecordFfi(messageIdHex: "02", direction: "sent", groupIdHex: Self.group, sender: "",
                                       plaintext: "Q", kind: MessageSemantics.kindPoll, tags: [],
                                       recordedAt: 1, receivedAt: 1)
        #expect(ConversationViewModel.pendingEditOriginalToken(for: text, unsettledClientToken: "tok") == "tok")
        #expect(ConversationViewModel.pendingEditOriginalToken(for: text, unsettledClientToken: nil) == nil)
        #expect(ConversationViewModel.pendingEditOriginalToken(for: text, unsettledClientToken: "") == nil)
        #expect(ConversationViewModel.pendingEditOriginalToken(for: poll, unsettledClientToken: "tok") == nil)
    }

    @Test func storeTracksTheClientTokenOnlyUntilDelivery() {
        let store = TimelineStore(appState: nil, groupIdHex: Self.group)
        let id = String(repeating: "1", count: 64)
        store.applyTimelineRecord(Self.record(id: id, delivered: false, token: "tok"))
        #expect(store.unsettledClientToken(forMessageId: id) == "tok")

        store.applyTimelineRecord(Self.record(id: id, delivered: true, token: "tok"))
        #expect(store.unsettledClientToken(forMessageId: id) == nil)

        let received = String(repeating: "2", count: 64)
        store.applyTimelineRecord(Self.record(id: received, direction: "received", delivered: false, token: "tok"))
        #expect(store.unsettledClientToken(forMessageId: received) == nil)
    }

    // MARK: Polls

    @Test func malformedPollRowsStayVisibleForTheUnsupportedState() {
        let store = TimelineStore(appState: nil, groupIdHex: Self.group)
        let id = String(repeating: "3", count: 64)
        store.applyTimelineRecord(Self.record(id: id, kind: MessageSemantics.kindPoll, direction: "received",
                                              delivered: true, token: nil),
                                  updateTimeline: true)
        #expect(store.poll(for: id) == nil)
        #expect(store.timeline.contains { item in
            if case .message(let record, _) = item.kind { return record.messageIdHex == id }
            return false
        })
    }
}
