import SwiftUI
import UIKit

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

    static func channels(_ color: Color, style: UIUserInterfaceStyle) -> Channels {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Channels(red: red, green: green, blue: blue, alpha: alpha)
    }

    static func relativeLuminance(_ channels: Channels) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(channels.red)
            + 0.7152 * linear(channels.green)
            + 0.0722 * linear(channels.blue)
    }

    static func ratio(
        foreground: Color,
        background: Color,
        style: UIUserInterfaceStyle
    ) -> Double {
        let base = channels(background, style: style)
        let tint = channels(foreground, style: style)
        let composited = Channels(
            red: tint.red * tint.alpha + base.red * (1 - tint.alpha),
            green: tint.green * tint.alpha + base.green * (1 - tint.alpha),
            blue: tint.blue * tint.alpha + base.blue * (1 - tint.alpha),
            alpha: 1
        )
        let lighter = max(relativeLuminance(composited), relativeLuminance(base))
        let darker = min(relativeLuminance(composited), relativeLuminance(base))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
