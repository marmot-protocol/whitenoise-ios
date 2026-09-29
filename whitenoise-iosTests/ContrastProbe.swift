import SwiftUI
import UIKit
@testable import whitenoise_ios

/// Resolves a SwiftUI `Color` for one appearance so a palette's light and
/// dark values can be asserted separately.
///
/// Translucent foregrounds are composited over their background before the
/// ratio is taken, which is the point of the tool: several of these palettes
/// express de-emphasis as an alpha on their own foreground rather than as
/// `Color.secondary`.
enum ContrastProbe {
    struct Channels {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    static func channels(_ color: Color, style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast = .normal) -> Channels {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style), UITraitCollection(accessibilityContrast: contrast),
        ])
        let resolved = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Channels(red: red, green: green, blue: blue, alpha: alpha)
    }

    static func relativeLuminance(_ channels: Channels) -> Double {
        Double(WCAGContrast.relativeLuminance(
            UIColor(red: channels.red, green: channels.green, blue: channels.blue, alpha: 1)
        ))
    }

    static func ratio(
        foreground: Color,
        background: Color,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast = .normal
    ) -> Double {
        let base = channels(background, style: style, contrast: contrast)
        let tint = channels(foreground, style: style, contrast: contrast)
        let composited = Channels(
            red: tint.red * tint.alpha + base.red * (1 - tint.alpha),
            green: tint.green * tint.alpha + base.green * (1 - tint.alpha),
            blue: tint.blue * tint.alpha + base.blue * (1 - tint.alpha),
            alpha: 1
        )
        return Double(WCAGContrast.ratio(
            CGFloat(relativeLuminance(composited)),
            CGFloat(relativeLuminance(base))
        ))
    }
}
