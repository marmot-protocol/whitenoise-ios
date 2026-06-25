import Testing
@testable import whitenoise_ios

/// #54 — outbound message send must clamp text to the protocol's max length so
/// an oversized paste can't bypass the composer's cap.
struct OutboundMessageCapTests {

    @Test func clampsOversizedTextToMaxMessageLength() {
        let huge = String(repeating: "x", count: ProfileSanitizer.maxMessageLength + 250)
        #expect(ConversationViewModel.cappedOutgoingText(huge).count == ProfileSanitizer.maxMessageLength)
    }

    @Test func leavesTextWithinLimitUnchanged() {
        #expect(ConversationViewModel.cappedOutgoingText("hello") == "hello")
        let exact = String(repeating: "y", count: ProfileSanitizer.maxMessageLength)
        #expect(ConversationViewModel.cappedOutgoingText(exact) == exact)
    }
}
