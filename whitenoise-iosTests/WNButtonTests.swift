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
        #expect(WNButton.Metrics.controlSize(for: .compact) == .regular)
    }

    @Test func standardSitsBetweenTheCallToActionAndTheToolbarSize() {
        #expect(WNButton.Metrics.controlSize(for: .standard) == .large)
    }

    @Test func standardClaimsTheFullWidthWithoutTheCallToActionHeight() {
        #expect(WNButton.Metrics.stretches(.standard))
        #expect(WNButton.Metrics.controlSize(for: .standard) != WNButton.Metrics.controlSize(for: .large))
    }

    @Test func destructiveTintsRedRegardlessOfColorScheme() {
        #expect(WNButton.Metrics.tint(for: .destructive, colorScheme: .light) == .red)
        #expect(WNButton.Metrics.tint(for: .destructive, colorScheme: .dark) == .red)
    }

    @Test func nonDestructiveEmphasesKeepTheMonochromeAccent() {
        for emphasis in [WNButton.Emphasis.primary, .secondary] {
            for colorScheme in [ColorScheme.light, .dark] {
                #expect(
                    WNButton.Metrics.tint(for: emphasis, colorScheme: colorScheme)
                        == WNButton.Metrics.accent(for: colorScheme)
                )
            }
        }
    }

    /// The red fill is the same red in both schemes, so unlike the monochrome
    /// emphases the label cannot flip with the scheme or it loses contrast.
    @Test func destructiveLabelStaysLightOnTheRedFillInBothSchemes() {
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .destructive,
                colorScheme: .light,
                isEnabled: true
            ) == .white
        )
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .destructive,
                colorScheme: .dark,
                isEnabled: true
            ) == .white
        )
    }

    @Test func disabledDestructiveDimsLikeEveryOtherEmphasis() {
        for colorScheme in [ColorScheme.light, .dark] {
            #expect(
                WNButton.Metrics.contentColor(
                    emphasis: .destructive,
                    colorScheme: colorScheme,
                    isEnabled: false
                ) == .secondary
            )
        }
    }

    /// A destructive button is never a bare toolbar item, so it always paints
    /// its own red surface instead of borrowing a container's.
    @Test func destructiveAlwaysPaintsItsOwnSurface() {
        for size in [WNButton.Size.large, .standard, .compact] {
            #expect(WNButton.Metrics.drawsOwnSurface(emphasis: .destructive, size: size))
        }
    }
}
