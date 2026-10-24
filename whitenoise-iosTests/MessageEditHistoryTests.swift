import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// The edit-history viewer is driven by a pure projection: version ordering,
/// current-version labeling, and the actions-menu gate. These assert on that
/// projection's behavior, not on any SwiftUI wiring.
struct EditHistoryPresentationTests {

    @Test func rowsAreNewestFirstWithOriginalLastAndSequentialVersionNumbers() {
        let original = record(id: hex("10"), text: "v0", at: 100)
        let edits = [
            record(id: hex("22"), text: "v2", at: 300),
            record(id: hex("21"), text: "v1", at: 200),
        ]

        let rows = EditHistoryPresentation.rows(original: original, edits: edits)

        #expect(rows.map(\.body) == ["v2", "v1", "v0"])
        #expect(rows.map(\.versionNumber) == [2, 1, 0])
        #expect(rows.map(\.isOriginal) == [false, false, true])
        #expect(rows.map(\.id) == [hex("22"), hex("21"), hex("10")])
    }

    @Test func latestEditIsTheOnlyCurrentRowAndTiesBreakOnMessageId() {
        let original = record(id: hex("10"), text: "v0", at: 100)
        // Same recordedAt: the higher message id is the later ("current") edit.
        let edits = [
            record(id: hex("aa"), text: "lo", at: 200),
            record(id: hex("bb"), text: "hi", at: 200),
        ]

        let rows = EditHistoryPresentation.rows(original: original, edits: edits)

        #expect(rows.map(\.isCurrent) == [true, false, false])
        #expect(rows.first?.body == "hi")
        #expect(rows.filter(\.isCurrent).count == 1)
    }

    @Test func withNoEditsTheOriginalIsBothCurrentAndOriginal() {
        let original = record(id: hex("10"), text: "only", at: 100)

        let rows = EditHistoryPresentation.rows(original: original, edits: [])

        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.isOriginal)
        #expect(row.isCurrent)
        #expect(row.versionNumber == 0)
        #expect(row.body == "only")
    }

    @Test func bodyPrefersFlattenedTokensAndSanitizesPlaintext() {
        // Tokens present: markdown syntax is dropped, text kept.
        let tokenized = AppMessageRecordFfi(
            messageIdHex: hex("30"),
            direction: "sent",
            groupIdHex: hex("cc"),
            sender: hex("dd"),
            plaintext: "**bold** _it_",
            contentTokens: MarkdownDocumentFfi(
                blocks: [.paragraph(inlines: [
                    .strong(children: [.text(content: "bold")]),
                    .text(content: " "),
                    .emph(children: [.text(content: "it")]),
                ])],
                truncated: false
            ),
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 100,
            receivedAt: 100
        )
        // No tokens: raw plaintext, but sanitized to a single line.
        let plain = record(id: hex("31"), text: "line one\nline two", at: 200)

        let rows = EditHistoryPresentation.rows(original: tokenized, edits: [plain])

        #expect(rows.map(\.body) == ["line one line two", "bold it"])
    }

    @Test func tokenlessEditHistoryRendersCanonicalMentionAsDisplayName() throws {
        let npub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let original = record(id: hex("30"), text: "original", at: 100)
        let edit = record(id: hex("31"), text: "updated @\(npub)", at: 200)

        let rows = EditHistoryPresentation.rows(
            original: original,
            edits: [edit],
            mentionDisplayName: { entity in entity.bech32 == npub ? "Alex" : nil }
        )

        #expect(rows.first?.body == "updated @Alex")
    }

    @Test func gatingRequiresAtLeastOneEditAndUndeletedMessage() {
        #expect(!EditHistoryPresentation.shouldOffer(editCount: 0, isDeleted: false))
        #expect(EditHistoryPresentation.shouldOffer(editCount: 1, isDeleted: false))
        #expect(EditHistoryPresentation.shouldOffer(editCount: 3, isDeleted: false))
        #expect(!EditHistoryPresentation.shouldOffer(editCount: 2, isDeleted: true))
    }

    private func record(
        id: String,
        text: String,
        at: UInt64
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: id,
            direction: "sent",
            groupIdHex: hex("cc"),
            sender: hex("dd"),
            plaintext: text,
            contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: at,
            receivedAt: at
        )
    }
}

/// The projection cache surfaces the durable edit chain the viewer sources
/// versions from; verify authorship filtering and chronological ordering hold.
@MainActor
struct ConversationEditRecordsSourcingTests {
    @Test func editRecordsAreAuthorFilteredUsableAndChronological() {
        let cache = ConversationEditProjectionCache()
        let target = record(id: hex("10"), sender: hex("aa"), text: "original", at: 1)
        let first = record(id: hex("21"), sender: target.sender, text: "first", at: 2)
        let second = record(id: hex("22"), sender: target.sender, text: "second", at: 3)
        let wrongAuthor = record(id: hex("30"), sender: hex("bb"), text: "spoof", at: 4)
        let invalidated = record(id: hex("40"), sender: target.sender, text: "gone", at: 5)

        // Insert out of order to prove the cache re-sorts.
        _ = cache.setRecord(second, invalidated: false, deleted: false)
        _ = cache.setRecord(first, invalidated: false, deleted: false)
        _ = cache.setRecord(wrongAuthor, invalidated: false, deleted: false)
        _ = cache.setRecord(invalidated, invalidated: true, deleted: false)

        let edits = cache.editRecords(for: target)
        #expect(edits.map(\.plaintext) == ["first", "second"])

        let rows = EditHistoryPresentation.rows(original: target, edits: edits)
        #expect(rows.map(\.body) == ["second", "first", "original"])
        #expect(rows.first?.isCurrent == true)
    }

    private func record(
        id: String,
        sender: String,
        text: String,
        at: UInt64
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: id,
            direction: "sent",
            groupIdHex: hex("cc"),
            sender: sender,
            plaintext: text,
            contentTokens: .emptyDocument,
            kind: text == "original" ? MessageSemantics.kindChat : MessageSemantics.kindEdit,
            tags: text == "original"
                ? []
                : [MessageTagFfi(values: [MessageSemantics.eventRefTag, hex("10")])],
            recordedAt: at,
            receivedAt: at
        )
    }
}
