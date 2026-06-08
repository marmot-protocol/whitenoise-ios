import Testing
import UIKit
@testable import darkmatter_ios

/// #4 — other-user bubbles must use a higher-contrast fill in dark mode (a
/// lighter system gray) so they stand off the conversation background.
@MainActor
struct ReceivedBubbleContrastTests {

    @Test func darkModeUsesLighterGrayThanBackground() {
        #expect(MessageBubble.receivedBubbleColor(dark: true) == UIColor.systemGray5)
    }

    @Test func lightModeIsUnchanged() {
        #expect(MessageBubble.receivedBubbleColor(dark: false) == UIColor.secondarySystemBackground)
    }
}
