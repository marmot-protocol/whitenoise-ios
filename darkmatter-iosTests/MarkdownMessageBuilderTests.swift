import Testing
import SwiftUI
@testable import darkmatter_ios
@testable import MarmotKit

/// The markdown AST arrives pre-parsed from Rust but its text runs are
/// untrusted relay content. These tests pin the builder's three contracts:
/// faithful styling, render-side link gating, and budget/sanitization safety.
@MainActor
struct MarkdownMessageBuilderTests {

    private func doc(_ blocks: [MarkdownBlockFfi]) -> MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: blocks)
    }

    private func para(_ inlines: [MarkdownInlineFfi]) -> MarkdownBlockFfi {
        .paragraph(inlines: inlines)
    }

    private func firstParagraph(
        _ document: MarkdownDocumentFfi,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> AttributedString {
        let blocks = try #require(
            MarkdownMessageBuilder.displayBlocks(for: document),
            sourceLocation: sourceLocation
        )
        guard case .paragraph(let attributed) = try #require(blocks.first, sourceLocation: sourceLocation) else {
            throw TestFailure("expected paragraph, got \(blocks[0])")
        }
        return attributed
    }

    private func firstParagraphText(
        _ blocks: [MarkdownDisplayBlock]?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let blocks = try #require(blocks, sourceLocation: sourceLocation)
        guard case .paragraph(let attributed) = try #require(blocks.first, sourceLocation: sourceLocation) else {
            throw TestFailure("expected paragraph, got \(blocks[0])")
        }
        return String(attributed.characters)
    }

    private func record(
        plaintext: String,
        tokens: MarkdownDocumentFfi
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: "message",
            direction: "received",
            groupIdHex: "group",
            sender: "sender",
            plaintext: plaintext,
            contentTokens: tokens,
            kind: 9,
            tags: [],
            recordedAt: 1,
            receivedAt: 1
        )
    }

    private struct TestFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Inline styling

    @Test func emphasisAndStrongComposeFonts() throws {
        let attributed = try firstParagraph(doc([para([
            .text(content: "a"),
            .strong(children: [
                .text(content: "b"),
                .emph(children: [.text(content: "c")]),
            ]),
        ])]))

        #expect(String(attributed.characters) == "abc")
        let runs = Array(attributed.runs)
        #expect(runs.count == 3)
        #expect(runs[0].font == Font.body)
        #expect(runs[1].font == Font.body.bold())
        #expect(runs[2].font == Font.body.bold().italic())
    }

    @Test func strikethroughSetsLineStyle() throws {
        let attributed = try firstParagraph(doc([para([
            .strikethrough(children: [.text(content: "gone")])
        ])]))

        let run = try #require(attributed.runs.first)
        #expect(run.strikethroughStyle == .single)
    }

    @Test func inlineCodeIsMonospacedWithBackgroundAndNoLink() throws {
        let attributed = try firstParagraph(doc([para([
            .code(content: "let x")
        ])]))

        let run = try #require(attributed.runs.first)
        #expect(run.font == Font.body.monospaced())
        #expect(run.backgroundColor != nil)
        #expect(run.link == nil)
    }

    // MARK: - Links

    @Test func httpsLinkGetsLinkAttributeAndUnderline() throws {
        let attributed = try firstParagraph(doc([para([
            .link(dest: "https://example.com/x", title: nil, children: [.text(content: "label")])
        ])]))

        let run = try #require(attributed.runs.first)
        #expect(String(attributed.characters) == "label")
        #expect(run.link == URL(string: "https://example.com/x"))
        #expect(run.underlineStyle == .single)
    }

    @Test func dangerousLinkSchemesRenderAsPlainText() throws {
        for dest in ["javascript:alert(1)", "data:text/html,<b>x</b>", "file:///etc/passwd", "ftp://host/x"] {
            let attributed = try firstParagraph(doc([para([
                .link(dest: dest, title: nil, children: [.text(content: "label")])
            ])]))

            #expect(String(attributed.characters) == "label", "dest: \(dest)")
            for run in attributed.runs {
                #expect(run.link == nil, "dest: \(dest)")
            }
        }
    }

    @Test func autolinksLinkifyAndEmailSynthesizesMailto() throws {
        let uri = try firstParagraph(doc([para([
            .autolink(url: "https://example.com", kind: .uri)
        ])]))
        #expect(try #require(uri.runs.first).link == URL(string: "https://example.com"))

        let email = try firstParagraph(doc([para([
            .autolink(url: "a@b.com", kind: .email)
        ])]))
        #expect(String(email.characters) == "a@b.com")
        #expect(try #require(email.runs.first).link == URL(string: "mailto:a@b.com"))
    }

    @Test func nostrProfileEntitiesLinkAndOthersStayInert() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let mention = try firstParagraph(doc([para([
            .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
        ])]))
        let mentionRun = try #require(mention.runs.first)
        #expect(String(mention.characters) == "@npub1qqq…qqqq")
        #expect(mentionRun.link == URL(string: "nostr:\(bech32)"))
        #expect(mentionRun.font == Font.body.monospaced())

        let note = try firstParagraph(doc([para([
            .nostrUri(entity: MarkdownNostrEntityFfi(hrp: .note, bech32: "note1" + String(repeating: "q", count: 58)))
        ])]))
        let noteRun = try #require(note.runs.first)
        #expect(noteRun.link == nil)
        #expect(noteRun.font == Font.body.monospaced())
    }

    @Test func mentionResolvesToDisplayNameWhenProfileKnown() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let document = doc([para([
            .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
        ])])
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(
            for: document,
            mentionDisplayName: { entity in
                entity.bech32 == bech32 ? "Jeff" : nil
            }
        ))
        guard case .paragraph(let attributed) = try #require(blocks.first) else {
            throw TestFailure("expected paragraph")
        }

        let run = try #require(attributed.runs.first)
        #expect(String(attributed.characters) == "@Jeff")
        #expect(run.link == URL(string: "nostr:\(bech32)"))
        #expect(run.font == Font.body.bold())
    }

    @Test func mentionFallsBackToBech32WhenResolverDeclines() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let document = doc([para([
            .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
        ])])
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(
            for: document,
            mentionDisplayName: { _ in nil }
        ))
        guard case .paragraph(let attributed) = try #require(blocks.first) else {
            throw TestFailure("expected paragraph")
        }

        #expect(String(attributed.characters) == "@npub1qqq…qqqq")
        #expect(try #require(attributed.runs.first).font == Font.body.monospaced())
    }

    @Test func displayCacheReusesBlocksUntilMessageOrProfileGenerationChanges() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let tokens = doc([para([
            .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
        ])])
        let cache = MessageMarkdownDisplayCache()
        var resolverCalls = 0
        var displayName = "Jeff"

        let first = cache.displayBlocks(
            for: record(plaintext: "hello", tokens: tokens),
            profileRefreshGeneration: 1
        ) { _ in
            resolverCalls += 1
            return displayName
        }

        #expect(try firstParagraphText(first) == "@Jeff")
        #expect(resolverCalls == 1)

        displayName = "Other"
        let cached = cache.displayBlocks(
            for: record(plaintext: "hello", tokens: tokens),
            profileRefreshGeneration: 1
        ) { _ in
            resolverCalls += 1
            return displayName
        }

        #expect(try firstParagraphText(cached) == "@Jeff")
        #expect(resolverCalls == 1)

        let refreshed = cache.displayBlocks(
            for: record(plaintext: "hello", tokens: tokens),
            profileRefreshGeneration: 2
        ) { _ in
            resolverCalls += 1
            return displayName
        }

        #expect(try firstParagraphText(refreshed) == "@Other")
        #expect(resolverCalls == 2)

        displayName = "Updated"
        let changedRecord = cache.displayBlocks(
            for: record(plaintext: "hello edited", tokens: tokens),
            profileRefreshGeneration: 2
        ) { _ in
            resolverCalls += 1
            return displayName
        }

        #expect(try firstParagraphText(changedRecord) == "@Updated")
        #expect(resolverCalls == 3)
    }

    @Test func pubkeyHexDecodesValidProfileReferencesOnly() {
        // NIP-19 test vector.
        let valid = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        #expect(
            NostrProfileReference.pubkeyHex(fromBech32: valid)
                == "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
        )
        #expect(NostrProfileReference.pubkeyHex(fromBech32: "npub1" + String(repeating: "q", count: 58)) == nil)
        #expect(NostrProfileReference.pubkeyHex(fromBech32: "note1" + String(repeating: "q", count: 58)) == nil)
    }

    // MARK: - Images (never fetched)

    @Test func imageRendersAltAsLinkWithoutFetching() throws {
        let attributed = try firstParagraph(doc([para([
            .image(dest: "https://example.com/pic.png", title: nil, alt: [.text(content: "a cat")])
        ])]))

        let run = try #require(attributed.runs.first)
        #expect(String(attributed.characters) == "a cat")
        #expect(run.link == URL(string: "https://example.com/pic.png"))
    }

    @Test func imageWithoutAltUsesPlaceholderLabel() throws {
        let attributed = try firstParagraph(doc([para([
            .image(dest: "https://example.com/pic.png", title: nil, alt: [])
        ])]))

        #expect(String(attributed.characters) == L10n.string("Image"))
    }

    @Test func imageWithBlockedSchemeRendersPlainAlt() throws {
        let attributed = try firstParagraph(doc([para([
            .image(dest: "file:///etc/passwd", title: nil, alt: [.text(content: "alt")])
        ])]))

        #expect(String(attributed.characters) == "alt")
        #expect(try #require(attributed.runs.first).link == nil)
    }

    @Test func imageInsideLinkKeepsOuterDestination() throws {
        let attributed = try firstParagraph(doc([para([
            .link(dest: "https://outer.com", title: nil, children: [
                .image(dest: "https://inner.com/i.png", title: nil, alt: [.text(content: "a")])
            ])
        ])]))

        #expect(try #require(attributed.runs.first).link == URL(string: "https://outer.com"))
    }

    // MARK: - Breaks and sanitization

    @Test func breaksMapToWhitespaceAndClamp() throws {
        var inlines: [MarkdownInlineFfi] = [.text(content: "a"), .softBreak, .text(content: "b")]
        let soft = try firstParagraph(doc([para(inlines)]))
        #expect(String(soft.characters) == "a b")

        inlines = [.text(content: "a")]
        inlines.append(contentsOf: Array(repeating: MarkdownInlineFfi.hardBreak, count: 10))
        inlines.append(.text(content: "b"))
        let hard = try firstParagraph(doc([para(inlines)]))
        #expect(String(hard.characters) == "a\n\nb")
    }

    @Test func bidiAndControlCharactersAreStrippedFromRunsAndCodeBlocks() throws {
        let attributed = try firstParagraph(doc([para([
            .text(content: "user\u{202E}txt.exe\u{200B}")
        ])]))
        #expect(String(attributed.characters) == "usertxt.exe")

        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            .codeBlock(kind: .fenced, info: "", content: "safe()\u{202E}\u{0007}\n")
        ])))
        guard case .codeBlock(let code) = try #require(blocks.first) else {
            throw TestFailure("expected code block")
        }
        #expect(String(code.characters) == "safe()")
    }

    // MARK: - Budgets

    @Test func characterBudgetCapsTotalOutput() throws {
        let big = String(repeating: "a", count: 4000)
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            para([.text(content: big)]),
            para([.text(content: big)]),
            para([.text(content: big)]),
        ])))

        let totalCharacters = blocks.reduce(into: 0) { count, block in
            if case .paragraph(let attributed) = block {
                count += attributed.characters.count
            }
        }
        #expect(totalCharacters <= MarkdownMessageBuilder.maxCharacters + 1)
        guard case .paragraph(let last) = try #require(blocks.last) else {
            throw TestFailure("expected trailing truncation paragraph")
        }
        #expect(String(last.characters) == "…")
    }

    @Test func nodeBudgetTerminatesPathologicalInlineFloods() throws {
        let flood = Array(repeating: MarkdownInlineFfi.text(content: "a"), count: 5000)
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([para(flood)])))

        guard case .paragraph(let first) = try #require(blocks.first) else {
            throw TestFailure("expected paragraph")
        }
        #expect(first.characters.count < 5000)
        guard case .paragraph(let last) = try #require(blocks.last) else {
            throw TestFailure("expected trailing truncation paragraph")
        }
        #expect(String(last.characters) == "…")
    }

    @Test func deepQuoteNestingStopsAtRenderDepthCap() throws {
        var block: MarkdownBlockFfi = para([.text(content: "core")])
        for _ in 0..<30 {
            block = .blockQuote(blocks: [para([.text(content: "q")]), block])
        }
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([block])))

        func quoteDepth(_ blocks: [MarkdownDisplayBlock]) -> Int {
            blocks.reduce(into: 0) { deepest, block in
                if case .blockQuote(let nested) = block {
                    deepest = max(deepest, 1 + quoteDepth(nested))
                }
            }
        }
        #expect(quoteDepth(blocks) <= MarkdownMessageBuilder.maxRenderDepth)
        guard case .paragraph(let last) = try #require(blocks.last) else {
            throw TestFailure("expected trailing truncation paragraph")
        }
        #expect(String(last.characters) == "…")
    }

    // MARK: - Block shapes

    @Test func headingFontsMapAndClamp() throws {
        let levels: [(UInt8, Font)] = [
            (0, .title3.bold()),
            (1, .title3.bold()),
            (2, .headline),
            (3, .subheadline.bold()),
            (9, .subheadline.bold()),
        ]
        for (level, expected) in levels {
            let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
                .heading(level: level, inlines: [.text(content: "h")])
            ])))
            guard case .heading(let attributed) = try #require(blocks.first) else {
                throw TestFailure("expected heading")
            }
            #expect(try #require(attributed.runs.first).font == expected, "level \(level)")
        }
    }

    @Test func orderedListsHonorStartAndDelimiterAndTaskItems() throws {
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            .list(
                kind: .ordered(start: 3, delimiter: ")"),
                tight: true,
                items: [
                    MarkdownListItemFfi(blocks: [para([.text(content: "one")])], checked: nil),
                    MarkdownListItemFfi(blocks: [para([.text(content: "two")])], checked: nil),
                    MarkdownListItemFfi(blocks: [para([.text(content: "done")])], checked: true),
                ]
            )
        ])))

        guard case .list(let items, let tight) = try #require(blocks.first) else {
            throw TestFailure("expected list")
        }
        #expect(tight)
        #expect(items.count == 3)
        #expect(items[0].marker == .ordered(label: "3)"))
        #expect(items[1].marker == .ordered(label: "4)"))
        #expect(items[2].marker == .task(done: true))
    }

    @Test func tablesDegradeToHeaderAndRowParagraphs() throws {
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            .table(
                alignments: [.none, .none],
                header: [
                    MarkdownTableCellFfi(inlines: [.text(content: "h1")]),
                    MarkdownTableCellFfi(inlines: [.text(content: "h2")]),
                ],
                rows: [[
                    MarkdownTableCellFfi(inlines: [.text(content: "a")]),
                    MarkdownTableCellFfi(inlines: [.text(content: "b")]),
                ]]
            )
        ])))

        #expect(blocks.count == 2)
        guard case .paragraph(let header) = blocks[0], case .paragraph(let row) = blocks[1] else {
            throw TestFailure("expected two paragraphs")
        }
        #expect(String(header.characters) == "h1  h2")
        #expect(try #require(header.runs.first).font == Font.body.bold())
        #expect(String(row.characters) == "a  b")
    }

    @Test func mathRendersVerbatimWithCodeStyling() throws {
        let inline = try firstParagraph(doc([para([.math(content: "E = mc^2")])]))
        let run = try #require(inline.runs.first)
        #expect(String(inline.characters) == "E = mc^2")
        #expect(run.font == Font.body.monospaced())

        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            .mathBlock(content: "\\int_0^1 x dx")
        ])))
        guard case .codeBlock(let math) = try #require(blocks.first) else {
            throw TestFailure("expected math to degrade to code block")
        }
        #expect(String(math.characters) == "\\int_0^1 x dx")
    }

    // MARK: - Fallback contract

    @Test func emptyAndUnrenderableDocumentsReturnNil() {
        #expect(MarkdownMessageBuilder.displayBlocks(for: MarkdownDocumentFfi.emptyDocument) == nil)
        #expect(MarkdownMessageBuilder.displayBlocks(for: doc([para([.text(content: "\u{202E}\u{200B}")])])) == nil)
        #expect(MarkdownMessageBuilder.displayBlocks(for: doc([para([.text(content: "   ")])])) == nil)
    }

    @Test func mixedDocumentGoldenShape() throws {
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            .heading(level: 2, inlines: [.text(content: "Title")]),
            para([
                .text(content: "Hello "),
                .strong(children: [.text(content: "world")]),
                .text(content: ", see "),
                .link(dest: "https://example.com", title: nil, children: [.text(content: "this")]),
            ]),
            .codeBlock(kind: .fenced, info: "swift", content: "print(1)\n"),
            .thematicBreak,
            .list(kind: .bullet(marker: "-"), tight: true, items: [
                MarkdownListItemFfi(blocks: [para([.text(content: "item")])], checked: nil)
            ]),
        ])))

        #expect(blocks.count == 5)
        guard case .heading(let heading) = blocks[0],
              case .paragraph(let body) = blocks[1],
              case .codeBlock(let code) = blocks[2],
              case .thematicBreak = blocks[3],
              case .list(let items, _) = blocks[4]
        else {
            throw TestFailure("unexpected block shapes: \(blocks)")
        }
        #expect(String(heading.characters) == "Title")
        #expect(String(body.characters) == "Hello world, see this")
        #expect(String(code.characters) == "print(1)")
        #expect(items.count == 1)
    }
}
