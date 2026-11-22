import Testing
import UIKit
@testable import whitenoise_ios

struct MessageBubbleMetadataLayoutTests {
    @Test func shortQuotesHugTheirContentsAndLongExchangesRespectAvailableWidth() {
        #expect(MessageBubbleReplyLayout.textWidth(proposed: 300, ideal: 80) == 80)
        #expect(MessageBubbleReplyLayout.textWidth(proposed: 240, ideal: 400) == 240)
        let cap = ChatBubbleMetrics.textMaximumWidth
        #expect(MessageBubbleReplyLayout.textWidth(proposed: nil, ideal: cap + 80) == cap)
        #expect(MessageBubbleReplyLayout.textWidth(proposed: cap + 80, ideal: nil) == cap)
    }

    @Test func timestampsAlwaysUseTheOuterConversationEdge() {
        #expect(!MessageMetadataRowArrangement.timestampOnLeadingEdge(isFromMe: true))
        #expect(MessageMetadataRowArrangement.timestampOnLeadingEdge(isFromMe: false))
    }

    @Test func chromeWidthTracksItsWidestChildAndHonorsTheProposal() {
        #expect(MessageBubbleChromeSizing.width(
            proposedWidth: 320,
            bubbleWidth: 140,
            metadataWidth: 180
        ) == 180)
        #expect(MessageBubbleChromeSizing.width(
            proposedWidth: 150,
            bubbleWidth: 280,
            metadataWidth: 180
        ) == 150)
        #expect(MessageBubbleChromeSizing.width(
            proposedWidth: nil,
            bubbleWidth: 140,
            metadataWidth: 180
        ) == 180)
    }

    @Test func chromeHeightAddsBubbleMetadataAndSpacing() {
        #expect(MessageBubbleChromeSizing.height(bubbleHeight: 44, metadataHeight: 0, spacing: 3) == 44)
        #expect(MessageBubbleChromeSizing.height(
            bubbleHeight: 44,
            metadataHeight: 14,
            spacing: 3
        ) == 61)
    }
}

struct MessageBodyCollapsePresentationTests {
    @Test func shortMessagesStayExpanded() {
        #expect(!MessageBodyCollapsePresentation.shouldCollapse("Short message"))
    }

    @Test func veryLongMessagesCollapseByCharacterCount() {
        let body = String(repeating: "x", count: MessageBodyCollapsePresentation.maxCollapsedCharacters + 1)
        #expect(MessageBodyCollapsePresentation.shouldCollapse(body))
    }

    @Test func manyLineMessagesCollapseByLineCount() {
        let body = Array(repeating: "line", count: MessageBodyCollapsePresentation.maxCollapsedLines + 1)
            .joined(separator: "\n")
        #expect(MessageBodyCollapsePresentation.shouldCollapse(body))
    }

    @Test func expandingALongMessageRemovesTheInlineCollapse() {
        let body = String(repeating: "x", count: MessageBodyCollapsePresentation.maxCollapsedCharacters + 1)
        #expect(MessageBodyCollapsePresentation.isCollapsed(body, isExpanded: false))
        #expect(!MessageBodyCollapsePresentation.isCollapsed(body, isExpanded: true))
    }
}

struct TranscriptMessagePreviewTests {
    @Test func characterLimitCountsWholeEmojiAndNewlinesOnlyLimitAnExcerpt() {
        let emoji = "👩🏽‍💻"
        let boundary = String(repeating: emoji, count: 512)
        #expect(TranscriptMessagePreview.snippet(boundary) == nil)
        #expect(TranscriptMessagePreview.snippet(boundary + "x") == boundary)

        let lines = Array(repeating: "a", count: 17).joined(separator: "\n")
        #expect(TranscriptMessagePreview.snippet(lines) == nil)
        #expect(TranscriptMessagePreview.snippet(lines + boundary) == String(lines.dropLast(2)))
    }

    @Test func longReaderAccountsForNewlinesAndTheExistingInlineRenderLimit() {
        let text = String(repeating: "🌲", count: 2044)
        #expect(!TranscriptMessagePreview.requiresReader(text + "\n"))
        #expect(TranscriptMessagePreview.requiresReader(text + "\nx"))
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
