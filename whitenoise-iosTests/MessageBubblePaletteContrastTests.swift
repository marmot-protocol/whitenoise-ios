import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

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
