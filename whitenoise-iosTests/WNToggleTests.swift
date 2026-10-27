import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct WNToggleTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func thumbStaysVisibleAgainstTheOnTint(scheme: ColorScheme) {
        let ratio = ContrastProbe.ratio(
            foreground: WNTogglePalette.thumb,
            background: WNTogglePalette.onTint(for: scheme),
            style: scheme == .dark ? .dark : .light
        )

        #expect(ratio >= 3)
    }
}
