import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

/// The badge is the shared trailing marker for rows. These lock the two things
/// callers rely on: a prominent badge fills with the monochrome accent (never
/// the asset accent, which is the system blue in this app), and a neutral one
/// stays muted.
struct WNBadgeTests {
    @Test func prominentBadgeFillsWithTheMonochromeAccent() {
        #expect(
            WNBadge.Metrics.background(for: .prominent, colorScheme: .light) == .black
        )
        #expect(
            WNBadge.Metrics.background(for: .prominent, colorScheme: .dark) == .white
        )
    }

    @Test func prominentBadgeNeverFillsWithTheAssetAccent() {
        for colorScheme in [ColorScheme.light, .dark] {
            #expect(
                WNBadge.Metrics.background(
                    for: .prominent,
                    colorScheme: colorScheme
                ) != .accentColor
            )
        }
    }

    @Test func badgeAccentTracksTheButtonAccent() {
        for colorScheme in [ColorScheme.light, .dark] {
            #expect(
                WNBadge.Metrics.accent(for: colorScheme)
                    == WNButton.Metrics.accent(for: colorScheme)
            )
        }
    }

    @Test func neutralBadgeStaysMutedInBothSchemes() {
        let light = WNBadge.Metrics.background(for: .neutral, colorScheme: .light)
        let dark = WNBadge.Metrics.background(for: .neutral, colorScheme: .dark)

        #expect(light == dark)
        #expect(light != WNBadge.Metrics.accent(for: .light))
        #expect(dark != WNBadge.Metrics.accent(for: .dark))
    }

    @Test func onlyCountsGetMonospacedDigits() {
        #expect(WNBadge.Metrics.usesMonospacedDigits(.prominent))
        #expect(!WNBadge.Metrics.usesMonospacedDigits(.neutral))
    }

    @Test func countsCarryMoreWeightThanStatusWords() {
        #expect(WNBadge.Metrics.fontWeight(for: .prominent) == .bold)
        #expect(WNBadge.Metrics.fontWeight(for: .neutral) == .semibold)
    }

    @Test func glyphBadgesDropTheTextPaddingSoTheyStaySquare() {
        #expect(WNBadge.Metrics.horizontalPadding(for: .symbol("plus")) == 0)
        #expect(WNBadge.Metrics.horizontalPadding(for: .text("1")) > 0)
    }

    @Test func glyphOnAProminentBadgeStaysLegibleInBothSchemes() {
        for (scheme, style) in [(ColorScheme.light, UIUserInterfaceStyle.light),
                                (.dark, .dark)] {
            let ratio = ContrastProbe.ratio(
                foreground: Color(uiColor: .systemBackground),
                background: WNBadge.Metrics.background(for: .prominent, colorScheme: scheme),
                style: style
            )
            #expect(ratio >= 4.5)
        }
    }
}

/// The badge is pinned to one height so a glyph badge and a count badge read as
/// the same marker in a list. These render the real view and measure it rather
/// than restating the constants.
@MainActor
struct WNBadgeGeometryTests {
    @Test func aGlyphBadgeRendersAsACircle() {
        let size = renderedSize(WNBadge(symbol: "plus"))

        #expect(size.width == size.height)
        #expect(size.height == WNBadge.Metrics.minimumHeight)
    }

    @Test func aSingleDigitCountRendersAtTheSameFootprintAsAGlyph() {
        #expect(renderedSize(WNBadge(text: "1")) == renderedSize(WNBadge(symbol: "plus")))
    }

    @Test func aLongerCountGrowsWiderWithoutChangingTheRowHeight() {
        let single = renderedSize(WNBadge(text: "1"))
        let capped = renderedSize(WNBadge(text: "99+"))

        #expect(capped.width > single.width)
        #expect(capped.height == single.height)
    }

    private func renderedSize(_ view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size ?? .zero
    }
}
