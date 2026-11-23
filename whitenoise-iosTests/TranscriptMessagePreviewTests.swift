import Foundation
import MarmotKit
import SwiftUI
import UIKit
import Testing
@testable import whitenoise_ios

struct TranscriptMessagePreviewTests {
    @Test func collapseStopsAtTheFirstLineOrWholeCharacterLimit() {
        let boundary = String(repeating: "👩🏽‍💻", count: 900)
        #expect(MessageBodyCollapsePresentation.snippet(boundary) == nil)
        #expect(MessageBodyCollapsePresentation.snippet(boundary + "x") == boundary)
        for newline in ["\n", "\r", "\r\n"] {
            let twelve = Array(repeating: "a", count: 12).joined(separator: newline)
            #expect(MessageBodyCollapsePresentation.snippet(twelve) == nil)
            #expect(MessageBodyCollapsePresentation.snippet(twelve + newline) == twelve)
            #expect(MessageBodyCollapsePresentation.snippet(twelve + newline + boundary) == twelve)
            #expect(MessageBodyCollapsePresentation.snippet(boundary + newline + twelve) == boundary)
        }
    }

    @Test func visibleDividersTakeTheirOwnLineInTheFormattedExcerpt() throws {
        let start = MarkdownDisplayBlock.paragraph(AttributedString("Start"))
        let end = MarkdownDisplayBlock.paragraph(AttributedString("End"))
        let twelveLines = [start] + Array(repeating: MarkdownDisplayBlock.thematicBreak, count: 10) + [end]
        func snippet(_ blocks: [MarkdownDisplayBlock]) -> String? {
            MessageBodyCollapsePresentation.snippet(blocks.flatMap { $0.textFields(for: .excerpt) }.joined(separator: "\n"))
        }
        #expect(snippet(twelveLines) == nil)
        let tall = [start] + Array(repeating: MarkdownDisplayBlock.thematicBreak, count: 100) + [end]
        let prefix = try #require(snippet(tall))
        #expect(MarkdownDisplayBlock.excerpt(tall, characterBudget: prefix.count, countingBlockSeparators: true)
            == [start] + Array(repeating: .thematicBreak, count: 11))
        let fence = MarkdownDisplayBlock.codeBlock(AttributedString("---\n---"), language: "md")
        #expect(snippet([fence]) == nil)
        #expect(MarkdownDisplayBlock.thematicBreak.textFields.isEmpty)
    }

    @Test func indentedCodeExcerptKeepsTheCharactersAfterItsIndentation() throws {
        let indentation = String(repeating: " ", count: 850)
        let source = indentation + String(repeating: "x", count: 100)
        let prefix = try #require(MessageBodyCollapsePresentation.snippet(source))
        let blocks = MarkdownDisplayBlock.excerpt([.codeBlock(AttributedString(source), language: nil)],
                                                 characterBudget: prefix.count, countingBlockSeparators: true)
        guard case .codeBlock(let code, _) = blocks.first else {
            Issue.record("Missing formatted code excerpt")
            return
        }
        #expect(String(code.characters) == indentation + String(repeating: "x", count: 50) + "…")
    }

    @Test func longReaderAccountsForNewlinesAndTheExistingInlineRenderLimit() {
        let text = String(repeating: "🌲", count: 2044)
        for newline in ["\n", "\r", "\r\n"] {
            #expect(!TranscriptMessagePreview.requiresReader(text + newline))
            #expect(TranscriptMessagePreview.requiresReader(text + newline + "x"))
        }
        #expect(TranscriptMessagePreview.requiresReader(String(repeating: "a", count: 8001)))
    }

    @Test func inlineSourceLimitCountsCharactersEvenWhenSearchExpandsTheMatchingRow() {
        let inline = String(repeating: "é", count: ContentSanitizer.maxMessageLength)
        #expect(!TranscriptMessagePreview.exceedsInlineLimit(inline))
        #expect(TranscriptMessagePreview.exceedsInlineLimit(inline + "x"))
    }

    @Test func formattedPreviewCountsBlockBoundariesAndKeepsItsLastEmphasis() {
        var emphatic = AttributedString("abcdef")
        emphatic.inlinePresentationIntent = .stronglyEmphasized
        let blocks: [MarkdownDisplayBlock] = [.paragraph(AttributedString("123")), .heading(emphatic)]
        let excerpt = MarkdownDisplayBlock.excerpt(blocks, characterBudget: 6, countingBlockSeparators: true)
        guard case .heading(let heading) = excerpt.last else {
            Issue.record("Missing heading at the end of the preview")
            return
        }
        #expect(String(heading.characters) == "ab…")
        #expect(heading.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    @MainActor
    @Test func sourceReaderPreservesParagraphsAndLongLinesAroundTheFormerChunkBoundary() async throws {
        let emoji = "👩🏽‍💻"
        let paragraph = String(repeating: "a word ", count: 330) + emoji
        let unbroken = String(repeating: "x", count: 10_000)
        let source = paragraph + "\r\n\r\n" + unbroken + "\n\n" + paragraph + "\n"
        let state = AppState.test()
        func bubble(_ text: String, attachmentRevision: Int = 0) -> some View {
            let record = AppMessageRecordFfi(messageIdHex: "msg", direction: "received", groupIdHex: "group", sender: "peer",
                plaintext: text, contentTokens: .emptyDocument, kind: MessageSemantics.kindChat, tags: [], recordedAt: 1, receivedAt: 1)
            return MessageBubble(record: record, status: .received, incompleteMarkdown: true, displaysReader: true)
                .refreshingAttachments(on: attachmentRevision).environment(state)
        }
        let original = source + "é"
        let host = UIHostingController(rootView: bubble(original))
        try await withHostedWindow(host) { window in
            func reader(in view: UIView) -> UITextView? {
                if let text = view as? UITextView { return text }
                return view.subviews.lazy.compactMap { reader(in: $0) }.first
            }
            func shows(_ expected: String) -> Bool {
                window.layoutIfNeeded()
                return reader(in: window)?.text.utf8.elementsEqual(expected.utf8) == true
            }
            try await eventually { shows(original) }
            let view = try #require(reader(in: window))
            #expect(view.contentSize.height > view.bounds.height)

            view.setContentOffset(CGPoint(x: 0, y: 140), animated: false)
            host.rootView = bubble(original, attachmentRevision: 1)
            try await settleLayout(window) { reader(in: window)?.contentOffset.y }
            #expect(reader(in: window) === view)
            #expect(view.contentOffset.y == 140)

            let edited = source + "e\u{301}"
            host.rootView = bubble(edited)
            try await eventually { shows(edited) }
        }
    }

    @Test func sourceReaderProjectsWholeMentionsAndPreservesAdjacentText() async throws {
        let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: String(repeating: "ab", count: 32)))
        let prefix = String(repeating: "x", count: 2040) + " "
        let suffix = "\n\n👩🏽‍💻 embedded@" + npub
        let source = prefix + "@" + npub + suffix
        let known = try await TranscriptMessagePreview.sourceText(source) { $0 == npub ? "Ada" : nil }
        #expect(known == prefix + "@Ada" + suffix)
        let unknown = try await TranscriptMessagePreview.sourceText(source) { _ in nil }
        #expect(unknown == source)
    }
}
