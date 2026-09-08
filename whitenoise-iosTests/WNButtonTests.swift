import SwiftUI
import Testing
@testable import whitenoise_ios

struct WNButtonTests {
    @Test func accentIsMonochromeAgainstTheColorScheme() {
        #expect(WNButton.Metrics.accent(for: .light) == .black)
        #expect(WNButton.Metrics.accent(for: .dark) == .white)
    }

    @Test func primaryContentInvertsTheFilledAccent() {
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .primary,
                colorScheme: .light,
                isEnabled: true
            ) == .white
        )
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .primary,
                colorScheme: .dark,
                isEnabled: true
            ) == .black
        )
    }

    @Test func secondaryContentMatchesTheAccent() {
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .secondary,
                colorScheme: .light,
                isEnabled: true
            ) == WNButton.Metrics.accent(for: .light)
        )
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .secondary,
                colorScheme: .dark,
                isEnabled: true
            ) == WNButton.Metrics.accent(for: .dark)
        )
    }

    @Test func disabledContentDimsForBothEmphasesAndSchemes() {
        for emphasis in [WNButton.Emphasis.primary, .secondary] {
            for colorScheme in [ColorScheme.light, .dark] {
                #expect(
                    WNButton.Metrics.contentColor(
                        emphasis: emphasis,
                        colorScheme: colorScheme,
                        isEnabled: false
                    ) == .secondary
                )
            }
        }
    }

    @Test func fallbackLabelMinHeightClearsTheAppleMinimumTapTarget() {
        #expect(WNButton.Metrics.fallbackLabelMinHeight >= 44)
    }

    @Test func onlyTheLargeSizeClaimsTheFullWidth() {
        #expect(WNButton.Metrics.stretches(.large))
        #expect(!WNButton.Metrics.stretches(.compact))
    }

    @Test func onlyTheCompactSecondaryButtonLeansOnItsContainerForASurface() {
        #expect(
            !WNButton.Metrics.drawsOwnSurface(emphasis: .secondary, size: .compact)
        )
        #expect(
            WNButton.Metrics.drawsOwnSurface(emphasis: .secondary, size: .large)
        )
        #expect(
            WNButton.Metrics.drawsOwnSurface(emphasis: .primary, size: .compact)
        )
        #expect(
            WNButton.Metrics.drawsOwnSurface(emphasis: .primary, size: .large)
        )
    }

    @Test func onlyASecondaryIconButtonCanInheritItsContainersSurface() {
        #expect(
            WNIconButton.inheritsContainerSurface(
                emphasis: .secondary,
                chrome: .container
            )
        )
        #expect(
            !WNIconButton.inheritsContainerSurface(
                emphasis: .secondary,
                chrome: .own
            )
        )
        #expect(
            !WNIconButton.inheritsContainerSurface(
                emphasis: .primary,
                chrome: .container
            )
        )
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

    @Test func compactDropsBelowTheCallToActionControlSize() {
        #expect(WNButton.Metrics.controlSize(for: .large) == .extraLarge)
        #expect(WNButton.Metrics.controlSize(for: .compact) < .extraLarge)
    }
}
