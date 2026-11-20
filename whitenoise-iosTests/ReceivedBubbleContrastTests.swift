import Testing
import UIKit
@testable import whitenoise_ios

struct MessageBubbleMetadataLayoutTests {
    @Test func shortQuotesHugTheirContentsAndLongExchangesRespectAvailableWidth() {
        #expect(MessageBubbleReplyLayout.textWidth(proposed: 300, ideal: 80) == 80)
        #expect(MessageBubbleReplyLayout.textWidth(proposed: 240, ideal: 400) == 240)
        #expect(MessageBubbleReplyLayout.textWidth(proposed: nil, ideal: 400) == 332)
        #expect(MessageBubbleReplyLayout.textWidth(proposed: 500, ideal: nil) == 332)
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
