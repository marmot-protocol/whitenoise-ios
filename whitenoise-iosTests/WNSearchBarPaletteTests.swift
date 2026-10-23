import SwiftUI
import Testing
import UIKit

@testable import whitenoise_ios

@MainActor
struct WNSearchBarPaletteTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func magnifierStaysLegibleOnTheFieldSurface(_ style: UIUserInterfaceStyle) {
        let ratio = ContrastProbe.ratio(
            foreground: WNSearchBar.Palette.fieldGlyph,
            background: Color(uiColor: .systemBackground),
            style: style
        )

        #expect(ratio >= 4.5, "magnifier contrast \(ratio) in \(style)")
    }

    /// The prototype hardcodes a dark circle, which vanishes on a dark field.
    /// The circle has to stand out from the field and its glyph from the circle.
    @Test(arguments: [ColorScheme.light, .dark])
    func clearControlStandsOutFromTheFieldAndKeepsItsGlyphLegible(_ scheme: ColorScheme) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let fillOnField = ContrastProbe.ratio(
            foreground: WNSearchBar.Palette.clearFill(for: scheme),
            background: Color(uiColor: .systemBackground),
            style: style
        )
        let glyphOnFill = ContrastProbe.ratio(
            foreground: WNSearchBar.Palette.clearGlyph(for: scheme),
            background: WNSearchBar.Palette.clearFill(for: scheme),
            style: style
        )

        #expect(fillOnField >= 3, "clear circle contrast \(fillOnField) in \(scheme)")
        #expect(glyphOnFill >= 4.5, "clear glyph contrast \(glyphOnFill) in \(scheme)")
    }
}
