import Foundation
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

    @Test func sourceReaderRetainsEveryCharacterAcrossChunkBoundaries() {
        let text = String(repeating: "🥾 a trail without a break ", count: 220) + String(repeating: "x", count: 5000)
        var tail = text[...]
        var recovered = ""
        while !tail.isEmpty {
            let chunk = TranscriptMessagePreview.sourceChunk(tail)
            #expect((1...2048).contains(chunk.count))
            recovered += chunk
            tail = tail[chunk.endIndex...]
        }
        #expect(recovered == text)
    }
}
