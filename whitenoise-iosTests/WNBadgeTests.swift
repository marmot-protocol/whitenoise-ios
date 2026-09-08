import SwiftUI
import Testing
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
}
