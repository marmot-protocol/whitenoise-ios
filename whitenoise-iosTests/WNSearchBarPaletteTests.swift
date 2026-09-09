import SwiftUI
import Testing
import UIKit

@testable import whitenoise_ios

@MainActor
struct WNSearchBarPaletteTests {
    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        ContrastProbe.relativeLuminance(ContrastProbe.channels(color, style: style))
    }

    /// The ask: the magnifier reads darker than it used to in light mode. Its
    /// dark-mode counterpart has to move the other way, or the glyph would sink
    /// into the field instead of labelling it.
    @Test func magnifierIsDarkerThanSecondaryInLightAndLighterInDark() {
        let glyph = WNSearchBar.Palette.fieldGlyph

        #expect(luminance(glyph, .light) < luminance(.secondary, .light))
        #expect(luminance(glyph, .dark) > luminance(.secondary, .dark))
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func magnifierStaysLegibleOnTheFieldSurface(_ style: UIUserInterfaceStyle) {
        let ratio = ContrastProbe.ratio(
            foreground: WNSearchBar.Palette.fieldGlyph,
            background: Color(uiColor: .systemBackground),
            style: style
        )

        #expect(ratio >= 4.5, "magnifier contrast \(ratio) in \(style)")
    }

    /// The prototype hardcodes this pair as `.white, .black`, which leaves a
    /// black circle on a dark field. Ours inverts with the appearance.
    @Test func clearControlInvertsBetweenAppearances() {
        let lightFill = luminance(WNSearchBar.Palette.clearFill(for: .light), .light)
        let darkFill = luminance(WNSearchBar.Palette.clearFill(for: .dark), .dark)
        let lightGlyph = luminance(WNSearchBar.Palette.clearGlyph(for: .light), .light)
        let darkGlyph = luminance(WNSearchBar.Palette.clearGlyph(for: .dark), .dark)

        #expect(lightFill < lightGlyph, "light mode wants a dark fill under a light glyph")
        #expect(darkFill > darkGlyph, "dark mode wants a light fill under a dark glyph")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func clearGlyphIsLegibleOnItsOwnFill(_ scheme: ColorScheme) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let ratio = ContrastProbe.ratio(
            foreground: WNSearchBar.Palette.clearGlyph(for: scheme),
            background: WNSearchBar.Palette.clearFill(for: scheme),
            style: style
        )

        #expect(ratio >= 4.5, "clear glyph contrast \(ratio) in \(scheme)")
    }

    /// The filled circle carries the same weight as every other WN control, so
    /// a change to the button vocabulary cannot silently skip this one.
    @Test(arguments: [ColorScheme.light, .dark])
    func clearControlUsesTheSharedButtonVocabulary(_ scheme: ColorScheme) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light

        #expect(
            luminance(WNSearchBar.Palette.clearFill(for: scheme), style)
                == luminance(WNButton.Metrics.accent(for: scheme), style)
        )
        #expect(
            luminance(WNSearchBar.Palette.clearGlyph(for: scheme), style)
                == luminance(
                    WNButton.Metrics.contentColor(
                        emphasis: .primary,
                        colorScheme: scheme,
                        isEnabled: true
                    ),
                    style
                )
        )
    }
}
