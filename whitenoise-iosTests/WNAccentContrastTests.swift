import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct WNAccentContrastTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func assetMatchesExistingMonochromeControls(style: UIUserInterfaceStyle) throws {
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
