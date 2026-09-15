import SwiftUI
import Testing
@testable import whitenoise_ios

struct WNQRCodeCardMetricsTests {
    private static let legacyFixedCardWidth: CGFloat = 225 + 2 * 16
    private static let formContainerWidth: CGFloat = 369

    @Test func cardWidthScalesWithItsContainer() {
        let narrow = WNQRCodeCard.Metrics.width(forContainerWidth: 320)
        let wide = WNQRCodeCard.Metrics.width(forContainerWidth: 440)

        #expect(narrow < wide)
        #expect(narrow == 320 * WNQRCodeCard.Metrics.widthFraction)
        #expect(wide == 440 * WNQRCodeCard.Metrics.widthFraction)
    }

    @Test func cardNeverOutgrowsItsContainer() {
        for containerWidth in [CGFloat(320), 369, 402, 440, 700] {
            #expect(WNQRCodeCard.Metrics.width(forContainerWidth: containerWidth) < containerWidth)
        }
    }

    @Test func cardIsLargerThanTheFixedSizeItReplaced() {
        let width = WNQRCodeCard.Metrics.width(forContainerWidth: Self.formContainerWidth)

        #expect(width > Self.legacyFixedCardWidth)
    }

    @Test func quietZonePaddingLeavesRoomForTheSymbol() {
        let width = WNQRCodeCard.Metrics.width(forContainerWidth: Self.formContainerWidth)
        let symbolWidth = width - 2 * WNQRCodeCard.Metrics.quietZonePadding

        #expect(symbolWidth > width * 0.9)
    }
}

struct WNNeutralAccentTests {
    @Test func accentIsMonochromeInLightAppearance() {
        #expect(WNNeutralAccent.color(for: .light) == .black)
    }

    @Test func accentIsMonochromeInDarkAppearance() {
        #expect(WNNeutralAccent.color(for: .dark) == .white)
    }

    @Test func accentNeverFallsBackToTheSystemTint() {
        #expect(WNNeutralAccent.color(for: .light) != .accentColor)
        #expect(WNNeutralAccent.color(for: .dark) != .accentColor)
    }
}

struct CopyableValueChipFeedbackTests {
    @Test func offersACopyGlyphBeforeCopying() {
        #expect(CopyableValueChip.Feedback.symbolName(isCopied: false) == "doc.on.doc")
    }

    @Test func confirmsWithACheckmarkAfterCopying() {
        #expect(CopyableValueChip.Feedback.symbolName(isCopied: true) == "checkmark")
    }

    @Test func accessibilityLabelNamesTheValueBeforeCopying() {
        let label = CopyableValueChip.Feedback.accessibilityLabel(isCopied: false, valueName: "npub")

        #expect(label.contains("npub"))
        #expect(label != L10n.string("Copied"))
    }

    @Test func accessibilityLabelConfirmsTheCopyAfterwards() {
        let label = CopyableValueChip.Feedback.accessibilityLabel(isCopied: true, valueName: "npub")

        #expect(label == L10n.string("Copied"))
    }

    @Test func copyFeedbackResetsAfterABoundedDelay() {
        #expect(CopyableValueChip.Feedback.resetDelay > .zero)
        #expect(CopyableValueChip.Feedback.resetDelay <= .seconds(5))
    }
}
