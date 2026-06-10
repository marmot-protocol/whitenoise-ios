import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// Chat-list rows and reply quotes must show markdown messages as clean plain
/// text — syntax dropped, content kept — without changing anything for
/// records that carry no parsed tokens.
struct MarkdownPlainTextTests {

    private func doc(_ blocks: [MarkdownBlockFfi]) -> MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: blocks)
    }

    @Test func stylingSyntaxIsDroppedAndTextKept() {
        let flattened = MarkdownPlainText.flatten(doc([
            .paragraph(inlines: [
                .strong(children: [.text(content: "a")]),
                .softBreak,
                .emph(children: [.text(content: "b")]),
                .strikethrough(children: [.text(content: "c")]),
            ])
        ]))
        #expect(flattened == "a b c")
    }

    @Test func linksReduceToLabelsAndImagesToAlt() {
        let flattened = MarkdownPlainText.flatten(doc([
            .paragraph(inlines: [
                .link(dest: "https://example.com", title: nil, children: [.text(content: "label")]),
                .image(dest: "https://example.com/i.png", title: nil, alt: [.text(content: "alt")]),
                .autolink(url: "https://auto.example", kind: .uri),
            ])
        ]))
        #expect(flattened == "label alt https://auto.example")
    }

    @Test func blocksJoinWithSingleSpacesAndCodeIsVerbatim() {
        let flattened = MarkdownPlainText.flatten(doc([
            .heading(level: 1, inlines: [.text(content: "Title")]),
            .paragraph(inlines: [.text(content: "body")]),
            .codeBlock(kind: .fenced, info: "swift", content: "let x = 1\nlet y = 2\n"),
            .thematicBreak,
            .list(kind: .bullet(marker: "-"), tight: true, items: [
                MarkdownListItemFfi(blocks: [.paragraph(inlines: [.text(content: "item")])], checked: false)
            ]),
        ]))
        #expect(flattened == "Title body let x = 1 let y = 2 item")
    }

    @Test func nostrEntitiesTruncate() {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let flattened = MarkdownPlainText.flatten(doc([
            .paragraph(inlines: [.nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))])
        ]))
        #expect(flattened == "@npub1qqq…qqqq")
    }

    @Test func mentionsResolveToDisplayNamesInPreviews() {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let flattened = MarkdownPlainText.flatten(
            doc([
                .paragraph(inlines: [
                    .text(content: "ping"),
                    .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32)),
                ])
            ]),
            mentionDisplayName: { _ in "Jeff" }
        )
        #expect(flattened == "ping @Jeff")
    }

    @Test func emptyDocumentsFlattenToNil() {
        #expect(MarkdownPlainText.flatten(MarkdownDocumentFfi.emptyDocument) == nil)
        #expect(MarkdownPlainText.flatten(doc([.paragraph(inlines: [.softBreak])])) == nil)
    }

    @Test func flattenedOutputComposesWithSingleLineSanitizer() throws {
        // Exactly the ChatRow pipeline: flatten → ProfileSanitizer.singleLine.
        let flattened = MarkdownPlainText.flatten(doc([
            .paragraph(inlines: [
                .strong(children: [.text(content: "bidi\u{202E}safe")]),
                .hardBreak,
                .text(content: String(repeating: "x", count: 300)),
            ])
        ]))
        let result = try #require(ProfileSanitizer.singleLine(flattened, maxLength: 140))
        #expect(result.hasPrefix("bidisafe x"))
        #expect(result.count == 140)
        #expect(!result.contains("\u{202E}"))
    }

    // MARK: - MessagePreview integration

    @Test func previewBodyFlattensWhenTokensPresent() {
        let preview = ChatListMessagePreviewFfi(
            messageIdHex: "01",
            sender: "11",
            senderDisplayName: nil,
            plaintext: "**bold** _text_",
            contentTokens: doc([
                .paragraph(inlines: [
                    .strong(children: [.text(content: "bold")]),
                    .softBreak,
                    .emph(children: [.text(content: "text")]),
                ])
            ]),
            kind: MessageSemantics.kindChat,
            timelineAt: 1,
            deleted: false
        )
        #expect(MessagePreview.body(preview) == "bold text")
    }

    @Test func previewBodyIsUnchangedWhenTokensEmpty() {
        let raw = "**bold** _text_"
        let preview = ChatListMessagePreviewFfi(
            messageIdHex: "01",
            sender: "11",
            senderDisplayName: nil,
            plaintext: raw,
            kind: MessageSemantics.kindChat,
            timelineAt: 1,
            deleted: false
        )
        #expect(MessagePreview.body(preview) == raw)
    }

    @Test func replyPreviewBodyFlattensWhenTokensPresent() {
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: "01",
            sender: "11",
            plaintext: "`code` reply",
            contentTokens: doc([
                .paragraph(inlines: [
                    .code(content: "code"),
                    .text(content: " reply"),
                ])
            ]),
            kind: MessageSemantics.kindChat,
            mediaJson: nil,
            agentTextStreamJson: nil,
            deleted: false
        )
        #expect(MessagePreview.body(preview) == "code reply")
    }
}
