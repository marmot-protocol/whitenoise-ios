import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct UnsupportedEventPresentationTests {
    private let kind: UInt64 = 4242

    /// Something landed even though this app can't draw it: the row stays in
    /// the timeline instead of vanishing.
    @Test func anUnsupportedEventKeepsItsTimelineRow() {
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineRecord(messageIdHex: hex("01"), timelineAt: 1),
                    timelineRecord(messageIdHex: hex("02"), plaintext: "{}", kind: kind, timelineAt: 2),
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        let kinds = store.timeline.compactMap { item -> UInt64? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.kind
        }
        #expect(kinds == [MessageSemantics.kindChat, kind])
    }

    /// A NIP-22 comment from another client shows as a reply to the parent MDK
    /// projects, quoting it, not as a card.
    @Test func aCommentShowsAsAReplyRow() throws {
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        let parent = hex("01")
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineRecord(messageIdHex: parent, plaintext: "the parent", timelineAt: 1),
                    // The raw `e` differs from MDK's projection, which the timeline follows.
                    timelineRecord(
                        messageIdHex: hex("02"), plaintext: "agreed", kind: MessageSemantics.kindComment,
                        tags: [tag("e", hex("03")), tag("k", "9")], timelineAt: 2, replyToMessageIdHex: parent
                    ),
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        let comment = try #require(record(kind: MessageSemantics.kindComment, in: store))
        #expect(store.replyTargetMessageId(for: comment) == parent)
        #expect(store.replyPreview(for: comment)?.text == "the parent")
    }

    /// A quoted kind 1111 that isn't a comment stays an unsupported event in
    /// the quote, as its own row does, rather than showing its payload.
    @Test func aQuotedKind1111WithoutANumericKStaysUnsupported() throws {
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        let target = hex("01")
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineRecord(
                        messageIdHex: target, plaintext: "{\"raw\":true}", kind: MessageSemantics.kindComment,
                        tags: [tag("k", "custom")], timelineAt: 1
                    ),
                    timelineRecord(
                        messageIdHex: hex("02"), plaintext: "what is this?", timelineAt: 2,
                        replyToMessageIdHex: target,
                        replyPreview: TimelineReplyPreviewFfi(
                            messageIdHex: target, sender: hex("11"), plaintext: "{\"raw\":true}",
                            kind: MessageSemantics.kindComment, mediaJson: nil, media: [],
                            deleted: false
                        )
                    ),
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        let reply = try #require(record(kind: MessageSemantics.kindChat, in: store))
        #expect(store.replyPreview(for: reply)?.text == MessagePreview.unsupportedEventLabel)
    }

    /// A quote of a kind 1111 whose row isn't loaded follows MDK's `thread`:
    /// a thread message shows its text, anything else is an unsupported event.
    @Test(arguments: [true, false])
    func anUnloadedQuotedKind1111FollowsMDKsThread(inThread: Bool) throws {
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        let target = hex("01")
        let quote = TimelineReplyPreviewFfi(
            messageIdHex: target, sender: hex("11"), plaintext: "on it",
            kind: MessageSemantics.kindComment, mediaJson: nil, media: [],
            replyToMessageIdHex: inThread ? hex("03") : nil,
            thread: inThread ? TimelineThreadRefFfi(rootMessageIdHex: hex("03"), parentMessageIdHex: hex("03")) : nil,
            deleted: false
        )
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineRecord(
                        messageIdHex: hex("02"), plaintext: "thanks", timelineAt: 2,
                        replyToMessageIdHex: target, replyPreview: quote
                    ),
                ],
                hasMoreBefore: false,
                hasMoreAfter: true
            ),
            placement: .window
        )

        let reply = try #require(record(kind: MessageSemantics.kindChat, in: store))
        #expect(store.replyPreview(for: reply)?.text == (inThread ? "on it" : MessagePreview.unsupportedEventLabel))
    }

    /// MDK clears a deleted row's tags, so a deleted comment can't be told
    /// from another kind 1111: its quote reads as deleted, as any quote does.
    @Test func aQuotedDeletedCommentReadsAsDeleted() throws {
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        let target = hex("01")
        let quote = TimelineReplyPreviewFfi(
            messageIdHex: target, sender: hex("11"), plaintext: "",
            kind: MessageSemantics.kindComment, mediaJson: nil, media: [],
            deleted: true
        )
        store.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineRecord(
                        messageIdHex: target, plaintext: "", kind: MessageSemantics.kindComment,
                        timelineAt: 1, deleted: true
                    ),
                    timelineRecord(
                        messageIdHex: hex("02"), plaintext: "it's gone", timelineAt: 2,
                        replyToMessageIdHex: target, replyPreview: quote
                    ),
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        let reply = try #require(record(kind: MessageSemantics.kindChat, in: store))
        #expect(store.replyPreview(for: reply)?.text == MessagePreview.body(quote))
        #expect(store.replyPreview(for: reply)?.text != MessagePreview.unsupportedEventLabel)
    }

    private func record(kind: UInt64, in store: TimelineStore) -> AppMessageRecordFfi? {
        store.timeline.compactMap { item -> AppMessageRecordFfi? in
            guard case .message(let record, _) = item.kind, record.kind == kind else { return nil }
            return record
        }.first
    }

    @Test func theCardUsesTheEventsOwnDescription() {
        let presentation = UnsupportedEventPresentation(kind: kind, tags: [
            tag("subject", "Signal box log"),
            tag("alt", "The evening crew logged a delay."),
        ])

        #expect(presentation.title == "Signal box log")
        #expect(presentation.summary == "The evening crew logged a delay.")
    }

    @Test func aTitleTagStandsInForAMissingSubject() {
        let presentation = UnsupportedEventPresentation(kind: kind, tags: [tag("title", "Release notes")])

        #expect(presentation.title == "Release notes")
        #expect(presentation.summary == nil)
    }

    /// Tags are peer-controlled: the card shows one bounded line, without
    /// control or bidi characters.
    @Test func peerTextIsSanitizedAndBounded() throws {
        let presentation = UnsupportedEventPresentation(kind: kind, tags: [
            tag("subject", "Line\u{202E}one\nline two"),
            tag("alt", String(repeating: "a", count: 10_000)),
        ])

        let title = try #require(presentation.title)
        #expect(!title.contains("\n"))
        #expect(!title.unicodeScalars.contains("\u{202E}"))
        #expect((presentation.summary?.count ?? 0) <= UnsupportedEventPresentation.maxSummaryLength)
    }

    @Test func anEventWithoutDescriptiveTagsShowsOnlyItsKind() {
        let presentation = UnsupportedEventPresentation(kind: kind, tags: [tag("e", hex("01"))])

        #expect(presentation.title == nil)
        #expect(presentation.summary == nil)
    }

    /// The event data is valid JSON that reproduces the event exactly, including
    /// content that needs escaping.
    @Test func theEventJSONRoundTripsTheEvent() throws {
        let content = "line one\n\"quoted\" / \\ tab\t✓"
        let tags = [tag("subject", "Signal box log"), MessageTagFfi(values: ["imeta", "url https://x.invalid/a.mp4", "m video/mp4"])]
        let record = AppMessageRecordFfi(
            messageIdHex: hex("dd"),
            direction: "received",
            groupIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: content,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            recordedAt: 1_763_000_000,
            receivedAt: 1_763_000_001
        )

        let json = UnsupportedEventPresentation.eventJSON(for: record)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        #expect(object["id"] as? String == record.messageIdHex)
        #expect(object["pubkey"] as? String == record.sender)
        #expect((object["created_at"] as? NSNumber)?.uint64Value == record.recordedAt)
        #expect((object["kind"] as? NSNumber)?.uint64Value == kind)
        #expect(object["tags"] as? [[String]] == tags.map(\.values))
        #expect(object["content"] as? String == content)
        #expect(object["sig"] == nil)
    }

    @Test func copyingAnUnsupportedEventCopiesItsJSON() {
        let record = unsignedEventRecord(plaintext: "payload", kind: kind, tags: [])

        #expect(MessagePreview.copyBody(record) == UnsupportedEventPresentation.eventJSON(for: record))
    }

    private func tag(_ name: String, _ value: String) -> MessageTagFfi {
        MessageTagFfi(values: [name, value])
    }
}
