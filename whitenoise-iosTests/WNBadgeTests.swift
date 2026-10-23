import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

/// The badge is the shared trailing marker for rows; whatever the accent
/// becomes, a glyph on a prominent badge has to stay readable.
struct WNBadgeTests {
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
@Suite(.tags(.uiHosting))
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
