import CoreGraphics
import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct MessageActionsOverlayLayoutTests {
    @Test func menuFollowsEitherBubbleEdgeAndStopsAtTheScreenMargins() {
        let container: CGFloat = 400
        let menu: CGFloat = 120
        let margin = MessageActionsPresentation.horizontalMargin
        func center(_ edge: CGFloat, alignsRight: Bool) -> CGFloat {
            MessageActionsPresentation.menuCenterX(bubbleEdge: edge, alignsRight: alignsRight, surfaceWidth: menu, containerWidth: container)
        }
        let edge = container / 2
        #expect(center(edge, alignsRight: false) - menu / 2 == edge)
        #expect(center(edge, alignsRight: true) + menu / 2 == edge)
        #expect(center(0, alignsRight: false) - menu / 2 == margin)
        #expect(center(container, alignsRight: true) + menu / 2 == container - margin)
    }

    @Test func messageActionsOverlayKeepsReactionsAboveAndActionsBelowMessage() {
        let source = CGRect(x: 0, y: 220, width: 390, height: 96)
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 320,
            showsReactions: true
        )

        let reactionBottom = layout.groupTop + MessageActionsPresentation.reactionHeight
        let previewTop = layout.previewCenterY - layout.previewHeight / 2
        let previewBottom = layout.previewCenterY + layout.previewHeight / 2
        let actionsTop = layout.groupTop + layout.groupHeight - 320

        #expect(abs(previewTop - reactionBottom - MessageActionsPresentation.surfaceGap) < 0.001)
        #expect(abs(actionsTop - previewBottom - MessageActionsPresentation.surfaceGap) < 0.001)
    }

    @Test func longTextPreviewKeepsTheQuoteAndFooterAndLimitsOnlyItsBody() throws {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: -500, width: 320, height: 1240),
            containerHeight: 844, actionMenuHeight: 320, showsReactions: true, bodyHeight: 1150
        )
        let body = try #require(layout.excerptBodyHeight)
        #expect(body == MessageActionsPresentation.maximumExcerptBodyHeight)
        #expect(layout.previewHeight == body + 90)
    }

    @Test func textPreviewLeavesSpaceForActionsWhenTheMenuIsTall() throws {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: 900),
            containerHeight: 600, actionMenuHeight: 340, showsReactions: true, bodyHeight: 860
        )
        let body = try #require(layout.excerptBodyHeight)
        #expect(body > 0 && body < MessageActionsPresentation.maximumExcerptBodyHeight)
        #expect(layout.previewHeight == body + 40)
        #expect(layout.groupHeight <= 600 - 2 * MessageActionsPresentation.verticalMargin)
    }

    @Test func tallMediaCanStillLeaveASingleTruncatedCaption() throws {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: 1230),
            containerHeight: 728, actionMenuHeight: 340, showsReactions: true, bodyHeight: 1000
        )
        let caption = try #require(layout.excerptBodyHeight)
        #expect(caption >= 44 && caption < 64)
        #expect(layout.previewHeight == 230 + caption)
    }

    @Test func aCaptionThatFitsAtTheNormalPreviewScaleStaysComplete() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: 260),
            containerHeight: 704, actionMenuHeight: 340, showsReactions: true, bodyHeight: 100
        )
        #expect(layout.excerptBodyHeight == nil)
        #expect(!layout.previewIsTruncated)
        #expect(layout.previewHeight == 260)
    }

    @Test func aFractionalPointOfOverflowKeepsTheWholeCaption() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: 350.2),
            containerHeight: 794, actionMenuHeight: 340, showsReactions: true, bodyHeight: 100
        )
        #expect(layout.excerptBodyHeight == nil)
        #expect(!layout.previewIsTruncated)
        #expect(layout.previewHeight == 350.2)
    }

    @Test func aMarkdownExcerptKeepsTheWholeInlineEmojiAtItsTail() throws {
        let emoji = try #require(CustomEmojiShortcode("party_parrot"))
        let excerpt = MarkdownDisplayBlock.excerpt([.paragraph(AttributedString("A :party_parrot: today"))],
                                                  characterBudget: 7, emoji: [emoji])
        #expect(excerpt == [.paragraph(AttributedString("A :party_parrot:…"))])
    }

    @Test func aShortTallListCanPreviewJustTheFirstItem() {
        let items = ["A", "B", "C", "D"].map {
            MarkdownDisplayListItem(marker: .bullet, blocks: [.paragraph(AttributedString($0))])
        }
        let list: [MarkdownDisplayBlock] = [.list(items: items, tight: false)]
        let candidates = MarkdownDisplayBlock.menuExcerptBudgets(for: list).map {
            MarkdownDisplayBlock.excerpt(list, characterBudget: $0)
        }
        #expect(candidates.contains([.list(items: [.init(marker: .bullet, blocks: [.paragraph(AttributedString("A…"))])], tight: false)]))
    }

    @Test func aMarkdownExcerptPreservesTheQuotationAndCodeBlockAtItsTail() {
        let source: [MarkdownDisplayBlock] = [
            .paragraph(AttributedString("Intro")),
            .blockQuote([.codeBlock(AttributedString("let sample = 123"))]),
            .paragraph(AttributedString("After"))
        ]
        #expect(MarkdownDisplayBlock.excerpt(source, characterBudget: 15) == [
            .paragraph(AttributedString("Intro")),
            .blockQuote([.codeBlock(AttributedString("let sample…"))])
        ])
    }

    @Test func messageActionsOverlayShiftsTheWholeCompositionOnShortScreens() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 650, width: 390, height: 300),
            containerHeight: 760,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.groupTop >= MessageActionsPresentation.verticalMargin)
        #expect(layout.groupTop + layout.groupHeight <= 760 - MessageActionsPresentation.verticalMargin)
    }

    @Test func messageActionsOverlayClipsMessagesTallerThanTheViewportInsteadOfShrinkingThem() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: -900, width: 320, height: 2400),
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.previewIsTruncated)
        #expect(layout.previewHeight < 2400)
        #expect(layout.groupTop >= MessageActionsPresentation.verticalMargin)
        #expect(layout.groupTop + layout.groupHeight <= 844 - MessageActionsPresentation.verticalMargin)
    }

    @Test(arguments: [CGFloat(2400), CGFloat(5000), CGFloat(20000)])
    func messageActionsOverlayKeepsTallPreviewsBoundedAndDeterministic(sourceHeight: CGFloat) {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: sourceHeight),
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )
        let reference = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 0, width: 320, height: 2400),
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.previewHeight == reference.previewHeight)
        #expect(layout.groupHeight == reference.groupHeight)
    }

    @Test func shortBubbleKeepsItsTranscriptHeightAndCenter() {
        let source = CGRect(x: 0, y: 220, width: 390, height: 96)
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 320,
            showsReactions: true
        )

        #expect(abs(layout.previewCenterY - source.midY) < 0.001)
        #expect(!layout.previewIsTruncated)
        #expect(layout.previewHeight == source.height)
    }

    @Test func mediaThatExceedsTheAvailableHeightIsCroppedAtOriginalSize() {
        let containerHeight: CGFloat = 760
        let source = CGRect(x: 0, y: 650, width: 390, height: 300)
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: containerHeight,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.excerptBodyHeight == nil)
        #expect(layout.previewIsTruncated)
        #expect(layout.previewHeight < source.height)
        #expect(layout.groupTop == MessageActionsPresentation.verticalMargin)
        #expect(layout.groupTop + layout.groupHeight == containerHeight - MessageActionsPresentation.verticalMargin)
    }

    @Test func messageActionsOverlayKeyboardSizedContainerStillRendersAReadablePreview() {
        let source = CGRect(x: 0, y: 40, width: 320, height: 1200)
        let keyboardOpen = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 508,
            actionMenuHeight: 300,
            showsReactions: true
        )
        let keyboardClosed = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(keyboardOpen.previewHeight >= MessageActionsPresentation.minimumPreviewHeight)
        #expect(keyboardClosed.previewHeight > keyboardOpen.previewHeight)
    }

    @Test func messageActionsOverlayDoesNotReserveAReactionSurfaceWhenInteractionIsDisabled() {
        let source = CGRect(x: 0, y: 180, width: 390, height: 80)
        let withReactions = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 220,
            showsReactions: true
        )
        let withoutReactions = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 220,
            showsReactions: false
        )

        #expect(withoutReactions.groupHeight
            == withReactions.groupHeight
                - MessageActionsPresentation.reactionHeight
                - MessageActionsPresentation.surfaceGap)
    }
}
