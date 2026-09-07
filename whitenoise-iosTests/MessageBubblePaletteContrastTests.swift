import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

/// Resolves a SwiftUI `Color` for one appearance and measures WCAG contrast.
/// Translucent foregrounds are composited over their background first, which is
/// the whole point here: the deleted-message placeholder is a partially
/// transparent tint of the bubble's own foreground.
private enum ContrastProbe {
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

@MainActor
struct MessageBubblePaletteContrastTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [true, false])
    func secondaryBubbleTextMeetsContrastOnItsOwnBubble(
        style: UIUserInterfaceStyle,
        isFromMe: Bool
    ) {
        let ratio = ContrastProbe.ratio(
            foreground: MessageBubblePalette.secondaryForeground(isFromMe: isFromMe),
            background: MessageBubblePalette.background(isFromMe: isFromMe),
            style: style
        )
        #expect(
            ratio >= 4.5,
            "isFromMe=\(isFromMe) style=\(style.rawValue) contrast=\(ratio)"
        )
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [true, false])
    func secondaryBubbleTextStaysDeemphasized(
        style: UIUserInterfaceStyle,
        isFromMe: Bool
    ) {
        let background = MessageBubblePalette.background(isFromMe: isFromMe)
        let secondary = ContrastProbe.ratio(
            foreground: MessageBubblePalette.secondaryForeground(isFromMe: isFromMe),
            background: background,
            style: style
        )
        let primary = ContrastProbe.ratio(
            foreground: MessageBubblePalette.foreground(isFromMe: isFromMe),
            background: background,
            style: style
        )
        #expect(secondary < primary)
    }

    /// Guards the probe itself: a palette color that stopped resolving
    /// dynamically would silently report the same contrast for both
    /// appearances and make every assertion above meaningless.
    @Test func bubbleBackgroundsResolvePerAppearance() {
        let light = ContrastProbe.channels(MessageBubblePalette.sentBackground, style: .light)
        let dark = ContrastProbe.channels(MessageBubblePalette.sentBackground, style: .dark)
        #expect(ContrastProbe.relativeLuminance(light) != ContrastProbe.relativeLuminance(dark))
    }
}
