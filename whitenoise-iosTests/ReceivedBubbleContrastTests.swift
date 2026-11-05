import Testing
import UIKit
@testable import whitenoise_ios

struct MessageBubbleMetadataLayoutTests {
    @Test func onlyReplyHeadersPreferACompactMeasurementWidth() throws {
        let available = MessageBubbleReplyLayout.richBubbleWidth * 2
        let header = try #require(MessageBubbleReplyLayout.measurementWidth(proposedWidth: available, isReplyHeader: true))
        let body = try #require(MessageBubbleReplyLayout.measurementWidth(proposedWidth: available, isReplyHeader: false))

        #expect(header < body)
        #expect(body == available)
    }

    @Test func aReplyHeaderDoesNotOutgrowANarrowProposal() {
        let available = MessageBubbleReplyLayout.richBubbleWidth / 2
        #expect(MessageBubbleReplyLayout.measurementWidth(proposedWidth: available, isReplyHeader: true) == available)
    }

    @Test func unspecifiedBodyWidthStaysFlexibleWhileTheHeaderStaysFinite() throws {
        #expect(MessageBubbleReplyLayout.measurementWidth(proposedWidth: nil, isReplyHeader: false) == nil)
        let header = try #require(MessageBubbleReplyLayout.measurementWidth(proposedWidth: nil, isReplyHeader: true))
        #expect(header.isFinite && header > 0)
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
