import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct WNIdentityPaletteTests {
    @Test func identityUsesTheWholeKeyAndHasAStableBucket() {
        let first = String(repeating: "0", count: 63) + "1"
        let second = String(repeating: "0", count: 63) + "2"
        #expect(WNIdentityPalette.paletteIndex(for: first) != WNIdentityPalette.paletteIndex(for: second))
        #expect(WNIdentityPalette.paletteIndex(for: first) == 8)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func everyNameColorMeetsContrast(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(accessibilityContrast: contrast),
        ])
        var checkedBuckets = Set<Int>()
        for value in 0..<256 {
            let key = String(format: "%064x", value)
            let bucket = WNIdentityPalette.paletteIndex(for: key)
            guard checkedBuckets.insert(bucket).inserted else { continue }
            let foreground = UIColor(WNIdentityPalette.color(for: key)).resolvedColor(with: traits)
            let background = UIColor.systemBackground.resolvedColor(with: traits)
            #expect(ContrastProbe.ratio(
                foreground: Color(uiColor: foreground),
                background: Color(uiColor: background),
                style: style
            ) >= 4.5)
        }
        #expect(checkedBuckets.count == WNIdentityPalette.paletteCount)
    }

    @Test func arbitrarySeedsStayInThePalette() {
        for seed in ["", "peer", "👩🏽‍💻", String(repeating: "f", count: 64)] {
            #expect((0..<WNIdentityPalette.paletteCount).contains(WNIdentityPalette.paletteIndex(for: seed)))
        }
    }

    @Test func fallbackAvatarUsesOneInitial() {
        #expect(WNAvatarMonogram.initial(for: "  Ada Lovelace ") == "A")
        #expect(WNAvatarMonogram.initial(for: "李 明") == "李")
        #expect(WNAvatarMonogram.initial(for: "  ") == "?")
    }
}
