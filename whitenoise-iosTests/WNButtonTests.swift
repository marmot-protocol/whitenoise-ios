import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

struct WNButtonTests {
    @Test func accentIsMonochromeAgainstTheColorScheme() {
        #expect(WNButton.Metrics.accent(for: .light) == .black)
        #expect(WNButton.Metrics.accent(for: .dark) == .white)
    }

    @Test func disabledPrimaryContentLooksDifferentFromEnabled() {
        for colorScheme in [ColorScheme.light, .dark] {
            #expect(
                WNButton.Metrics.contentColor(emphasis: .primary, colorScheme: colorScheme, isEnabled: false)
                    != WNButton.Metrics.contentColor(emphasis: .primary, colorScheme: colorScheme, isEnabled: true)
            )
        }
    }

    @Test func fallbackLabelMinHeightClearsTheAppleMinimumTapTarget() {
        #expect(WNButton.Metrics.fallbackLabelMinHeight >= 44)
    }

    /// A new call site must keep its own circle until it opts out, so a toolbar
    /// item that hides the shared background cannot silently lose all chrome.
    @Test @MainActor func anIconButtonDrawsItsOwnSurfaceUnlessToldOtherwise() {
        let button = WNIconButton(
            title: "Close search",
            systemImage: "xmark",
            action: {}
        )

        #expect(button.emphasis == .secondary)
        #expect(button.chrome == .own)
        #expect(
            !WNIconButton.inheritsContainerSurface(
                emphasis: button.emphasis,
                chrome: button.chrome
            )
        )
    }

    @MainActor
    @Test func destructiveLabelsMeetTextContrastAcrossAppearanceAndContrastSettings() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let scheme: ColorScheme = style == .dark ? .dark : .light
                #expect(ContrastProbe.ratio(
                    foreground: WNButton.Metrics.contentColor(emphasis: .destructive, colorScheme: scheme, isEnabled: true),
                    background: WNButton.Metrics.tint(for: .destructive, colorScheme: scheme),
                    style: style,
                    contrast: contrast
                ) >= 4.5)
            }
        }
    }

    /// A destructive button is never a bare toolbar item, so it always paints
    /// its own red surface instead of borrowing a container's.
    @Test func destructiveAlwaysPaintsItsOwnSurface() {
        for size in [WNButton.Size.large, .standard, .compact] {
            #expect(WNButton.Metrics.drawsOwnSurface(emphasis: .destructive, size: size))
        }
    }

    /// Moved from WNSearchBarPaletteTests: the search bar's clear control
    /// forwards to these two colors, so the glyph-on-fill guard lives here.
    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func primaryContentStaysLegibleOnTheAccentFill(_ scheme: ColorScheme) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let ratio = ContrastProbe.ratio(
            foreground: WNButton.Metrics.contentColor(
                emphasis: .primary,
                colorScheme: scheme,
                isEnabled: true
            ),
            background: WNButton.Metrics.accent(for: scheme),
            style: style
        )

        #expect(ratio >= 4.5, "primary glyph contrast \(ratio) in \(scheme)")
    }

    /// The asset-catalog AccentColor is the only place the catalog is tied to
    /// the code accent.
    @MainActor
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func accentColorAssetMatchesExistingMonochromeControls(style: UIUserInterfaceStyle) throws {
        let asset = try #require(UIColor(named: "AccentColor"))
        let channels = ContrastProbe.channels(Color(uiColor: asset), style: style)
        let expected: Double = style == .dark ? 1 : 0
        #expect(channels.red == expected)
        #expect(channels.green == expected)
        #expect(channels.blue == expected)
        #expect(channels.alpha == 1)
        #expect(ContrastProbe.ratio(
            foreground: WNNeutralAccent.foreground,
            background: Color(uiColor: asset),
            style: style
        ) >= 4.5)
    }

    @MainActor
    @Test func windowTintTracksThemeChanges() throws {
        let window = UIWindow()
        let asset = try #require(UIColor(named: "AccentColor"))
        for theme in [AppearanceTheme.light, .dark, .system] {
            AppAppearanceRuntime.apply(theme: theme, to: [window])
            #expect(window.overrideUserInterfaceStyle == theme.userInterfaceStyle)
            let traits = UITraitCollection(userInterfaceStyle: theme.userInterfaceStyle)
            #expect(window.tintColor.resolvedColor(with: traits) == asset.resolvedColor(with: traits))
        }
    }
}
