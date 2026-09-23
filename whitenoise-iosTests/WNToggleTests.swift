import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct WNToggleTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func onTintIsNeutralRatherThanTheSystemGreen(scheme: ColorScheme) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light

        #expect(channelSpread(WNTogglePalette.onTint(for: scheme), style: style) < 0.05)
        #expect(channelSpread(Color(uiColor: .systemGreen), style: style) > 0.05)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func onTintIsOpaque(scheme: ColorScheme) {
        let channels = ContrastProbe.channels(
            WNTogglePalette.onTint(for: scheme),
            style: scheme == .dark ? .dark : .light
        )

        #expect(channels.alpha == 1)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func thumbStaysVisibleAgainstTheOnTint(scheme: ColorScheme) {
        let ratio = ContrastProbe.ratio(
            foreground: WNTogglePalette.thumb,
            background: WNTogglePalette.onTint(for: scheme),
            style: scheme == .dark ? .dark : .light
        )

        #expect(ratio >= 3)
    }

    private func channelSpread(_ color: Color, style: UIUserInterfaceStyle) -> Double {
        let channels = ContrastProbe.channels(color, style: style)
        let components = [channels.red, channels.green, channels.blue]
        guard let lowest = components.min(), let highest = components.max() else { return 0 }
        return highest - lowest
    }
}
