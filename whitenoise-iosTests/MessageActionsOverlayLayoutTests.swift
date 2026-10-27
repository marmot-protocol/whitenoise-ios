import CoreGraphics
import Testing
@testable import whitenoise_ios

@MainActor
struct MessageActionsOverlayLayoutTests {
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

        #expect(previewTop - reactionBottom == MessageActionsPresentation.surfaceGap)
        #expect(actionsTop - previewBottom == MessageActionsPresentation.surfaceGap)
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
        #expect(layout.previewScale < 1)
    }

    @Test func messageActionsOverlayClipsMessagesTallerThanTheViewportInsteadOfShrinkingThem() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: -900, width: 320, height: 2400),
            containerHeight: 844,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.previewScale >= MessageActionsPresentation.minimumPreviewScale)
        #expect(layout.previewIsTruncated)
        #expect(layout.previewContentHeight < 2400)
        #expect(abs(layout.previewContentHeight * layout.previewScale - layout.previewHeight) < 0.001)
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

        #expect(layout.previewScale == MessageActionsPresentation.minimumPreviewScale)
        #expect(layout.previewHeight == reference.previewHeight)
        #expect(layout.previewContentHeight == reference.previewContentHeight)
        #expect(layout.groupHeight == reference.groupHeight)
    }

    @Test func messageActionsOverlayLeavesMessagesThatAlreadyFitUntouched() {
        let source = CGRect(x: 0, y: 220, width: 390, height: 96)
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: source,
            containerHeight: 844,
            actionMenuHeight: 320,
            showsReactions: true
        )

        #expect(layout.previewScale == 1)
        #expect(!layout.previewIsTruncated)
        #expect(layout.previewContentHeight == source.height)
        #expect(layout.previewHeight == source.height)
    }

    @Test func messageActionsOverlayStillScalesModeratelyTallMessagesWithoutClipping() {
        let layout = MessageActionsOverlayLayout.resolve(
            sourceFrame: CGRect(x: 0, y: 650, width: 390, height: 300),
            containerHeight: 760,
            actionMenuHeight: 420,
            showsReactions: true
        )

        #expect(layout.previewScale < 1)
        #expect(layout.previewScale > MessageActionsPresentation.minimumPreviewScale)
        #expect(!layout.previewIsTruncated)
        #expect(layout.previewContentHeight == 300)
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

        #expect(keyboardOpen.previewScale == MessageActionsPresentation.minimumPreviewScale)
        #expect(keyboardClosed.previewHeight > keyboardOpen.previewHeight)
        #expect(keyboardClosed.previewContentHeight > keyboardOpen.previewContentHeight)
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
