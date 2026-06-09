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

@MainActor
struct MessageBubbleReplyChromeTests {

    @Test func replyHeaderUsesBalancedPaddingAndExtraBodyGap() {
        #expect(MessageBubbleReplyLayout.headerVerticalInset > 0)
        #expect(MessageBubbleReplyLayout.headerHorizontalInset == MessageBubbleReplyLayout.bodyHorizontalInset)
        #expect(MessageBubbleReplyLayout.bodyTopInsetAfterReply > MessageBubbleReplyLayout.bodyTopInset)
        #expect(MessageBubbleReplyLayout.bodyBottomInset == MessageBubbleReplyLayout.bodyTopInset)
    }

    @Test func receivedReplyHeaderContrastsWithBubbleFill() {
        #expect(MessageBubble.receivedReplyHeaderColor(dark: true) == UIColor.systemGray4)
        #expect(MessageBubble.receivedReplyHeaderColor(dark: false) == UIColor.systemGray5)
        #expect(MessageBubble.receivedReplyHeaderColor(dark: true) != MessageBubble.receivedBubbleColor(dark: true))
        #expect(MessageBubble.receivedReplyHeaderColor(dark: false) != MessageBubble.receivedBubbleColor(dark: false))
    }

    @Test func sentReplyHeaderUsesSubtleOverlay() {
        #expect(MessageBubbleReplyLayout.sentHeaderOverlayOpacity > 0)
        #expect(MessageBubbleReplyLayout.sentHeaderOverlayOpacity < 0.25)
    }
}
