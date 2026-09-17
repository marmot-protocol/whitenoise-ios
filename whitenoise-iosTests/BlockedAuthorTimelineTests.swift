import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct BlockedAuthorTimelineTests {
    /// Blocking someone has to silence them in every shared group, not only in
    /// the direct chat whose composer is already withheld.
    @Test func blockedAuthorsRowsLeaveTheTimelineAndComeBackOnUnblock() {
        let blocked = hex("bb")
        let peer = hex("cc")
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    record(id: hex("01"), sender: blocked, at: 1),
                    record(id: hex("02"), sender: peer, at: 2),
                    record(id: hex("03"), sender: blocked, at: 3),
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        #expect(renderedMessageIds(in: store) == [hex("01"), hex("02"), hex("03")])

        store.setBlockedAuthorIds([blocked])
        #expect(renderedMessageIds(in: store) == [hex("02")])

        // Filtering is display-only, so the history returns without a refetch.
        store.setBlockedAuthorIds([])
        #expect(renderedMessageIds(in: store) == [hex("01"), hex("02"), hex("03")])
    }

    /// MDK stores the key as it received it, so a differently-cased sender must
    /// not slip past the filter.
    @Test func theAuthorFilterMatchesRegardlessOfHexCase() {
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [record(id: hex("01"), sender: String(repeating: "BB", count: 32), at: 1)],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        store.setBlockedAuthorIds([hex("bb")])
        #expect(renderedMessageIds(in: store).isEmpty)
    }

    /// A quote would otherwise carry a blocked author's plaintext back onto the
    /// screen through somebody else's reply.
    @Test func aReplyCannotQuoteABlockedAuthorsMessage() throws {
        let blocked = hex("bb")
        let peer = hex("cc")
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    record(id: hex("01"), sender: blocked, at: 1),
                    record(id: hex("02"), sender: peer, at: 2, replyTo: hex("01"), previewSender: blocked),
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        let reply = try #require(store.record(for: hex("02")))
        #expect(store.replyPreview(for: reply) != nil)

        store.setBlockedAuthorIds([blocked])
        #expect(renderedMessageIds(in: store) == [hex("02")])
        #expect(store.replyPreview(for: reply) == nil)
        #expect(store.record(for: hex("01")) == nil)
    }

    private func record(
        id: String,
        sender: String,
        at: UInt64,
        replyTo: String? = nil,
        previewSender: String? = nil
    ) -> TimelineMessageRecordFfi {
        TimelineMessageRecordFfi(
            messageIdHex: id,
            sourceMessageIdHex: id,
            direction: "received",
            groupIdHex: hex("aa"),
            sender: sender,
            plaintext: "message \(at)",
            contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: replyTo.map { [MessageTagFfi(values: [MessageSemantics.eventRefTag, $0])] } ?? [],
            timelineAt: at,
            receivedAt: at,
            replyToMessageIdHex: replyTo,
            replyPreview: replyTo.map {
                TimelineReplyPreviewFfi(
                    messageIdHex: $0,
                    sender: previewSender ?? sender,
                    plaintext: "quoted text",
                    kind: MessageSemantics.kindChat,
                    mediaJson: nil,
                    media: [],
                    agentTextStreamJson: nil,
                    deleted: false
                )
            },
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

    private func renderedMessageIds(in store: TimelineStore) -> [String] {
        store.timeline.compactMap { item in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
    }

    private func hex(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }
}
