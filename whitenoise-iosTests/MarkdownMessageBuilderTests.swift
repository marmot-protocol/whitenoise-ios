import Testing
import SwiftUI
@testable import whitenoise_ios
@testable import MarmotKit

/// The markdown AST arrives pre-parsed from Rust but its text runs are
/// untrusted relay content. These tests pin the builder's three contracts:
/// faithful styling, render-side link gating, and budget/sanitization safety.
@MainActor
struct MarkdownMessageBuilderTests {

    private func doc(_ blocks: [MarkdownBlockFfi]) -> MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: blocks, truncated: false)
    }

    @Test func detailsDisplaySummaryAndBodyWithoutDroppingCollapsedContent() throws {
        let document = doc([.details(
            summary: [.text(content: "Summary")], open: false,
            body: [.paragraph(inlines: [.text(content: "Body")])], blankLinesBefore: Data()
        )])
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: document))
        #expect(blocks.count == 2)
        #expect(try firstParagraphText(blocks) == "Summary")
        guard case .blockQuote(let body) = blocks[1] else {
            throw TestFailure("expected an indented details body")
        }
        #expect(try firstParagraphText(body) == "Body")
    }

    @Test func aNodeLimitedProjectionKeepsTheSourceReaderAvailable() {
        let source = String(repeating: "*x* ", count: 750) + "TAIL"
        let word: [MarkdownInlineFfi] = [.emph(children: [.text(content: "x")]), .text(content: " ")]
        let inlines = Array(repeating: word, count: 750).flatMap { $0 } + [.text(content: "TAIL")]
        let document = doc([para(inlines)])
        let row = record(plaintext: source, tokens: document)
        let projection = MessageMarkdownDisplayProjection.build(for: row, mentionDisplayName: nil)
        #expect(!TranscriptMessagePreview.requiresReader(source))
        #expect(projection.isTruncated)
        #expect(MessageBubble(record: row, status: .received, incompleteMarkdown: projection.isTruncated,
                              isBodyExpanded: true).offersSourceReader)
    }

    @Test func plainReaderPreservesTheTailOfOneOversizedGrapheme() {
        let source = "a" + String(repeating: "\u{301}", count: ContentSanitizer.maxMessageScalars) + "TAIL"
        let row = record(plaintext: source, tokens: doc([]))
        #expect(!ContentSanitizer.messageBody(source).hasSuffix("TAIL"))
        #expect(MessageBubble(record: row, status: .received).readerShowsSource)
    }

    @Test func longSourceWithCompleteFormattedLinksKeepsThemTappableInTheReader() throws {
        let destination = "https://example.org/" + String(repeating: "x", count: 100)
        let source = String(repeating: "[Map](\(destination)) ", count: 80)
        let links: [MarkdownInlineFfi] = Array(repeating: .link(dest: destination, title: nil, children: [.text(content: "Map")],
                                                               classification: .web), count: 80)
        let row = record(plaintext: source, tokens: doc([para(links)]))
        let projection = MessageMarkdownDisplayProjection.build(for: row, mentionDisplayName: nil)
        let blocks = try #require(projection.blocks)
        #expect(!projection.isTruncated)
        #expect(TranscriptMessagePreview.requiresReader(source))
        #expect(!MessageBubble(record: row, status: .received, markdownBlocks: blocks).readerShowsSource)
    }

    @Test func anEmojiAtTheStartOfATruncatedDocumentKeepsTheTextBubble() {
        let document = MarkdownDocumentFfi(blocks: [para([.text(content: "🐿️")])], truncated: true)
        let row = record(plaintext: "🐿️ followed by omitted text", tokens: document)
        let projection = MessageMarkdownDisplayProjection.build(for: row, mentionDisplayName: nil)
        #expect(projection.isTruncated)
        #expect(MessageBubble(record: row, status: .received, incompleteMarkdown: projection.isTruncated).standaloneEmoji == nil)
    }

    @Test func longMarkdownLinkFlatteningToSingleEmojiStillRendersAsStandaloneEmoji() {
        let destination = "https://example.org/" + String(repeating: "x", count: 160)
        let source = "[👍](\(destination))"
        let document = doc([
            para([
                .link(
                    dest: destination,
                    title: nil,
                    children: [.text(content: "👍")],
                    classification: .web
                ),
            ]),
        ])
        let row = record(plaintext: source, tokens: document)
        #expect(source.utf8.count > MessageBubble.maxStandaloneEmojiPlaintextBytes)
        #expect(MessageBubble.mayContainStandaloneEmoji(plaintext: source, hasMarkdownTokens: true))
        #expect(MessageBubble(record: row, status: .received).standaloneEmoji == "👍")
    }

    @Test func bodyPresentationShortCircuitsPlaintextAndSanitizesAtMostOnce() {
        #expect(!MessageBubble.mayContainStandaloneEmoji(plaintext: "Hello world"))
        #expect(!MessageBubble.mayContainStandaloneEmoji(plaintext: ""))
        #expect(!MessageBubble.mayContainStandaloneEmoji(plaintext: "🔥" + String(repeating: "a", count: 129)))
        #expect(MessageBubble.mayContainStandaloneEmoji(plaintext: "🔥"))
        #expect(MessageBubble.mayContainStandaloneEmoji(plaintext: "1️⃣"))

        #expect(!MessageBubble.mayContainStandaloneCustomEmoji(plaintext: ":wave:", hasResolvableCustomEmoji: false))
        #expect(!MessageBubble.mayContainStandaloneCustomEmoji(plaintext: "hello", hasResolvableCustomEmoji: true))
        #expect(!MessageBubble.mayContainStandaloneCustomEmoji(
            plaintext: ":" + String(repeating: "a", count: 128) + ":",
            hasResolvableCustomEmoji: true
        ))
        #expect(MessageBubble.mayContainStandaloneCustomEmoji(plaintext: ":wave:", hasResolvableCustomEmoji: true))

        func resolve(
            plaintext: String,
            isDeleted: Bool = false,
            hasReplyPreview: Bool = false,
            hasMediaItems: Bool = false,
            showsReactionStrip: Bool = true,
            offersSourceReader: Bool = false,
            resolvableCustomEmoji: Set<CustomEmojiShortcode> = [],
            searchQuery: String? = nil
        ) -> (presentation: MessageBubble.BodyPresentation, sanitizeCalls: Int) {
            var calls = 0
            let presentation = MessageBubble.BodyPresentation.resolve(
                plaintext: plaintext,
                isDeleted: isDeleted,
                showsStandardBody: true,
                hasDebugStyle: false,
                hasAgentActivity: false,
                hasReplyPreview: hasReplyPreview,
                hasMediaItems: hasMediaItems,
                hasSticker: false,
                isPoll: false,
                hasRemoteGiphyMedia: false,
                hasSharedLocation: false,
                hasLinkPreviewURL: false,
                showsReactionStrip: showsReactionStrip,
                offersSourceReader: offersSourceReader,
                resolvableCustomEmoji: resolvableCustomEmoji,
                searchQuery: searchQuery,
                sanitizedBody: {
                    calls += 1
                    return ContentSanitizer.messageBody(plaintext)
                }
            )
            return (presentation, calls)
        }

        // Plain ASCII message skips sanitization completely.
        let ascii = resolve(plaintext: "Hello world")
        #expect(ascii.sanitizeCalls == 0)
        #expect(ascii.presentation.standaloneEmoji == nil)
        #expect(ascii.presentation.widensTextForReactions)

        // >128B emoji-prefixed message skips sanitization completely.
        let longEmoji = resolve(plaintext: "🔥 " + String(repeating: "x", count: 140))
        #expect(longEmoji.sanitizeCalls == 0)
        #expect(longEmoji.presentation.standaloneEmoji == nil)

        // Truncated source-reader and reply rows skip sanitization completely.
        #expect(resolve(plaintext: "🔥", offersSourceReader: true).sanitizeCalls == 0)
        #expect(resolve(plaintext: "🔥", hasReplyPreview: true).sanitizeCalls == 0)
        #expect(resolve(plaintext: "", hasMediaItems: true).sanitizeCalls == 0)

        // Single emoji sanitizes once and reuses the result.
        let singleEmoji = resolve(plaintext: "🔥")
        #expect(singleEmoji.sanitizeCalls == 1)
        #expect(singleEmoji.presentation.standaloneEmoji == "🔥")
        #expect(!singleEmoji.presentation.widensTextForReactions)
        #expect(singleEmoji.presentation.precomputedSanitizedBody == "🔥")

        // Multi-emoji sanitizes at most once and caches sanitized body for fallback rendering.
        let multiEmoji = resolve(plaintext: "🔥🔥")
        #expect(multiEmoji.sanitizeCalls == 1)
        #expect(multiEmoji.presentation.standaloneEmoji == nil)
        #expect(multiEmoji.presentation.widensTextForReactions)
        #expect(multiEmoji.presentation.precomputedSanitizedBody == "🔥🔥")

        // Single custom emoji sanitizes once even when both emoji and custom-emoji checks apply.
        let wave = CustomEmojiShortcode("wave")!
        let customEmoji = resolve(plaintext: ":wave:", resolvableCustomEmoji: [wave])
        #expect(customEmoji.sanitizeCalls == 1)
        #expect(customEmoji.presentation.standaloneCustomEmoji == wave)
        #expect(!customEmoji.presentation.widensTextForReactions)

        // Whitespace-padded single emoji beyond 128 raw bytes still resolves as standalone emoji.
        let paddedEmoji = resolve(plaintext: String(repeating: " ", count: 140) + "👍" + String(repeating: "\n", count: 10))
        #expect(paddedEmoji.sanitizeCalls == 1)
        #expect(paddedEmoji.presentation.standaloneEmoji == "👍")

        // ASCII numeric HTML entity with Markdown tokens passes the emoji pre-check.
        #expect(MessageBubble.mayContainStandaloneEmoji(plaintext: "&#128077;", hasMarkdownTokens: true))
        #expect(!MessageBubble.mayContainStandaloneEmoji(plaintext: "&#128077;", hasMarkdownTokens: false))

        // Captioned media sanitizes once for hasVisibleBodyText and passes precomputed text down.
        let captionedMedia = resolve(plaintext: "Caption text", hasMediaItems: true)
        #expect(captionedMedia.sanitizeCalls == 1)
        #expect(captionedMedia.presentation.hasVisibleBodyText)
        #expect(captionedMedia.presentation.precomputedSanitizedBody == "Caption text")
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
            .link(dest: "https://example.com/x", title: nil, children: [.text(content: "label")], classification: .web)
        ])]))

        let run = try #require(attributed.runs.first)
        #expect(String(attributed.characters) == "label")
        #expect(run.link == URL(string: "https://example.com/x"))
        #expect(run.underlineStyle == .single)
    }

    @Test func dangerousLinkSchemesRenderAsPlainText() throws {
        for dest in ["javascript:alert(1)", "data:text/html,<b>x</b>", "file:///etc/passwd", "ftp://host/x"] {
            let attributed = try firstParagraph(doc([para([
                .link(dest: dest, title: nil, children: [.text(content: "label")], classification: .dangerous)
            ])]))

            #expect(String(attributed.characters) == "label", "dest: \(dest)")
            for run in attributed.runs {
                #expect(run.link == nil, "dest: \(dest)")
            }
        }
    }

    @Test func autolinksLinkifyAndEmailSynthesizesMailto() throws {
        let uri = try firstParagraph(doc([para([
            .autolink(url: "https://example.com", kind: .uri, classification: .web)
        ])]))
        #expect(try #require(uri.runs.first).link == URL(string: "https://example.com"))

        let email = try firstParagraph(doc([para([
            .autolink(url: "a@b.com", kind: .email, classification: .contact)
        ])]))
        #expect(String(email.characters) == "a@b.com")
        #expect(try #require(email.runs.first).link == URL(string: "mailto:a@b.com"))

        let www = try firstParagraph(doc([para([
            .autolink(url: "www.example.com/path", kind: .www, classification: .web)
        ])]))
        #expect(String(www.characters) == "www.example.com/path")
        #expect(try #require(www.runs.first).link == URL(string: "https://www.example.com/path"))
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
        #expect(run.font == Font.body.weight(.semibold))
        #expect(run.underlineStyle == nil)
        #expect(run[MarkdownMentionAttribute.self] == true)
    }

    @Test func inlineNostrUriResolvesToDisplayNameWithoutMentionStyling() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let document = doc([para([
            .nostrUri(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
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
        #expect(String(attributed.characters) == "Jeff")
        #expect(run.link == URL(string: "nostr:\(bech32)"))
        #expect(run.font == Font.body)
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

    @Test func displayProjectionBuildsBlocksAndTracksMentionedProfiles() throws {
        let bech32 = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let tokens = doc([para([
            .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
        ])])
        var resolverCalls = 0

        let projection = MessageMarkdownDisplayProjection.build(
            for: record(plaintext: "hello", tokens: tokens),
            mentionDisplayName: { _ in
                resolverCalls += 1
                return "Jeff"
            }
        )

        #expect(try firstParagraphText(projection.blocks) == "@Jeff")
        #expect(resolverCalls == 1)
        #expect(projection.mentionedAccountIds == Set([
            "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
        ]))
    }

    @Test func displayProjectionDoesNotTrackInvalidMentions() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let tokens = doc([para([
            .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
        ])])
        var resolverCalls = 0

        let projection = MessageMarkdownDisplayProjection.build(
            for: record(plaintext: "hello", tokens: tokens),
            mentionDisplayName: { _ in
                resolverCalls += 1
                return "Jeff"
            }
        )

        #expect(try firstParagraphText(projection.blocks) == "@Jeff")
        #expect(resolverCalls == 1)
        #expect(projection.mentionedAccountIds.isEmpty)
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
            .image(dest: "https://example.com/pic.png", title: nil, alt: [.text(content: "a cat")], classification: .web)
        ])]))

        let run = try #require(attributed.runs.first)
        #expect(String(attributed.characters) == "a cat")
        #expect(run.link == URL(string: "https://example.com/pic.png"))
    }

    @Test func imageWithoutAltUsesPlaceholderLabel() throws {
        let attributed = try firstParagraph(doc([para([
            .image(dest: "https://example.com/pic.png", title: nil, alt: [], classification: .web)
        ])]))

        #expect(String(attributed.characters) == L10n.string("Image"))
    }

    @Test func imageWithSanitizedEmptyAltUsesPlaceholderLabel() throws {
        let attributed = try firstParagraph(doc([para([
            .image(dest: "https://example.com/pic.png", title: nil, alt: [
                .emph(children: [.text(content: "\u{202E}\u{200B}")])
            ], classification: .web)
        ])]))

        #expect(String(attributed.characters) == L10n.string("Image"))
    }

    @Test func imageWithBlockedSchemeRendersPlainAlt() throws {
        let attributed = try firstParagraph(doc([para([
            .image(dest: "file:///etc/passwd", title: nil, alt: [.text(content: "alt")], classification: .dangerous)
        ])]))

        #expect(String(attributed.characters) == "alt")
        #expect(try #require(attributed.runs.first).link == nil)
    }

    @Test func imageInsideLinkKeepsOuterDestination() throws {
        let attributed = try firstParagraph(doc([para([
            .link(dest: "https://outer.com", title: nil, children: [
                .image(dest: "https://inner.com/i.png", title: nil, alt: [.text(content: "a")], classification: .web)
            ], classification: .web)
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
        guard case .codeBlock(let code, _) = try #require(blocks.first) else {
            throw TestFailure("expected code block")
        }
        #expect(String(code.characters) == "safe()")
    }

    // MARK: - Budgets

    @Test func scalarBoundMarksAnIncompleteProjectionEvenWhenTheVisibleGraphemesFit() {
        let first = String(repeating: "x", count: MarkdownMessageBuilder.maxCharacters - 6)
        func projection(accents: Int) -> Bool {
            let last = "a" + String(repeating: "\u{301}", count: accents) + "Z"
            return MarkdownMessageBuilder.build(for: doc([para([.text(content: first), .text(content: last)])])).isTruncated
        }
        #expect(!projection(accents: 4))
        #expect(projection(accents: 49))
    }

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

    @Test func tableEmptyCellsConsumeNodeBudgetBeforeLateContent() throws {
        let emptyCells = Array(
            repeating: MarkdownTableCellFfi(inlines: []),
            count: MarkdownMessageBuilder.maxNodes
        )
        let visibleLateCell = MarkdownTableCellFfi(inlines: [.text(content: "late")])

        let headerBlocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            para([.text(content: "intro")]),
            .table(
                alignments: Array(repeating: .none, count: emptyCells.count + 1),
                header: emptyCells + [visibleLateCell],
                rows: []
            )
        ])))
        let headerParagraphs = headerBlocks.compactMap { block -> String? in
            guard case .paragraph(let attributed) = block else { return nil }
            return String(attributed.characters)
        }
        #expect(headerParagraphs.first == "intro")
        #expect(!headerParagraphs.contains("late"))
        #expect(headerParagraphs.last == "…")

        let bodyBlocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            .table(
                alignments: Array(repeating: .none, count: emptyCells.count + 1),
                header: [MarkdownTableCellFfi(inlines: [.text(content: "header")])],
                rows: [emptyCells + [visibleLateCell]]
            )
        ])))
        let bodyParagraphs = bodyBlocks.compactMap { block -> String? in
            guard case .paragraph(let attributed) = block else { return nil }
            return String(attributed.characters)
        }
        #expect(bodyParagraphs.first == "header")
        #expect(!bodyParagraphs.contains("late"))
        #expect(bodyParagraphs.last == "…")
    }

    @Test func deepQuoteNestingStopsAtRenderDepthCap() throws {
        var block: MarkdownBlockFfi = para([.text(content: "core")])
        for _ in 0..<30 {
            block = .blockQuote(
                blocks: [para([.text(content: "q")]), block],
                blankLinesBefore: Data([0, 0])
            )
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
            .listBlock(
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
        guard case .codeBlock(let math, _) = try #require(blocks.first) else {
            throw TestFailure("expected math to degrade to code block")
        }
        #expect(String(math.characters) == "\\int_0^1 x dx")
    }

    @Test func collapsedDetailsKeepsSummaryAndBodyVisible() throws {
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: doc([
            .details(
                summary: [.text(content: "Spoiler")],
                open: false,
                body: [para([.text(content: "hidden body")])],
                blankLinesBefore: Data([0])
            )
        ])))

        #expect(blocks.count == 2)
        guard case .paragraph(let summary) = blocks[0] else {
            throw TestFailure("expected the summary to render as a paragraph")
        }
        #expect(String(summary.characters) == "Spoiler")
        #expect(try #require(summary.runs.first).font == Font.body.bold())

        guard case .blockQuote(let body) = blocks[1] else {
            throw TestFailure("expected the details body to render as an indented group")
        }
        guard case .paragraph(let bodyText) = try #require(body.first) else {
            throw TestFailure("expected a body paragraph")
        }
        #expect(String(bodyText.characters) == "hidden body")
    }

    @Test func deepDetailsNestingStopsAtRenderDepthCap() throws {
        var block: MarkdownBlockFfi = para([.text(content: "core")])
        for _ in 0..<30 {
            block = .details(
                summary: [.text(content: "s")],
                open: true,
                body: [block],
                blankLinesBefore: Data([0])
            )
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
                .link(dest: "https://example.com", title: nil, children: [.text(content: "this")], classification: .web),
            ]),
            .codeBlock(kind: .fenced, info: "swift", content: "print(1)\n"),
            .thematicBreak,
            .listBlock(kind: .bullet(marker: "-"), tight: true, items: [
                MarkdownListItemFfi(blocks: [para([.text(content: "item")])], checked: nil)
            ]),
        ])))

        #expect(blocks.count == 5)
        guard case .heading(let heading) = blocks[0],
              case .paragraph(let body) = blocks[1],
              case .codeBlock(let code, let language) = blocks[2],
              case .thematicBreak = blocks[3],
              case .list(let items, _) = blocks[4]
        else {
            throw TestFailure("unexpected block shapes: \(blocks)")
        }
        #expect(language == "swift")
        #expect(String(heading.characters) == "Title")
        #expect(String(body.characters) == "Hello world, see this")
        #expect(String(code.characters) == "print(1)")
        #expect(items.count == 1)
    }
}
