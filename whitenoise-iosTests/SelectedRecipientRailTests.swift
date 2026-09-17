import SwiftUI
import Testing
import UIKit

@testable import whitenoise_ios

@MainActor
struct SelectedRecipientRailTests {
    private typealias Metrics = SelectedRecipientRail.Metrics
    private typealias Palette = SelectedRecipientRail.Palette

    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        ContrastProbe.relativeLuminance(ContrastProbe.channels(color, style: style))
    }

    /// The badge used to sit a few points clear of the avatar, in the corner of
    /// a frame a circle never reaches. It belongs on the edge.
    @Test func removeBadgeSitsOnTheAvatarEdge() {
        let radius = Metrics.avatarSize / 2
        let centre = Metrics.badgeCentre
        let distance = ((centre.x - radius) * (centre.x - radius)
            + (centre.y - radius) * (centre.y - radius)).squareRoot()

        #expect(abs(distance - radius) < 0.5, "badge centre is \(distance) from a \(radius) radius")
    }

    /// Anchored at the top trailing corner, so the badge must land in the upper
    /// right quadrant — an inset large enough to cross the centre would park it
    /// over the face.
    @Test func removeBadgeStaysInTheUpperTrailingQuadrant() {
        let radius = Metrics.avatarSize / 2

        #expect(Metrics.badgeCentre.x > radius)
        #expect(Metrics.badgeCentre.y < radius)
    }

    /// The prototype hardcodes white-on-black, which leaves a black disc on a
    /// dark chip. Ours inverts, the same way the search field's clear control
    /// does.
    @Test func removeBadgeInvertsBetweenAppearances() {
        let lightFill = luminance(Palette.removeFill(for: .light), .light)
        let darkFill = luminance(Palette.removeFill(for: .dark), .dark)
        let lightGlyph = luminance(Palette.removeGlyph(for: .light), .light)
        let darkGlyph = luminance(Palette.removeGlyph(for: .dark), .dark)

        #expect(lightFill < lightGlyph, "light mode wants a dark disc under a light glyph")
        #expect(darkFill > darkGlyph, "dark mode wants a light disc under a dark glyph")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func removeGlyphIsLegibleOnItsOwnDisc(_ scheme: ColorScheme) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let ratio = ContrastProbe.ratio(
            foreground: Palette.removeGlyph(for: scheme),
            background: Palette.removeFill(for: scheme),
            style: style
        )

        #expect(ratio >= 4.5, "remove glyph contrast \(ratio) in \(scheme)")
    }

    /// The badge is the same filled circle as every other WN control, so a
    /// change to the button vocabulary cannot silently skip this one.
    @Test(arguments: [ColorScheme.light, .dark])
    func removeBadgeUsesTheSharedButtonVocabulary(_ scheme: ColorScheme) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light

        #expect(
            luminance(Palette.removeFill(for: scheme), style)
                == luminance(WNButton.Metrics.accent(for: scheme), style)
        )
        #expect(
            luminance(Palette.removeGlyph(for: scheme), style)
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
