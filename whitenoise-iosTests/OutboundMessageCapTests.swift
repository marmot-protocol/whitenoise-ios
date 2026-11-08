import Testing
@testable import whitenoise_ios

/// #54, #1276 — outbound text over the protocol's max length is rejected
/// before it leaves the composer, never shortened and sent.
struct OutboundMessageCapTests {

    @Test func rejectsTextOverMaxMessageLength() {
        let oversized = String(repeating: "x", count: ContentSanitizer.maxMessageLength + 1)
        #expect(ConversationSendPreparation.textRejection(forOutgoing: oversized) == .text)
    }

    @Test func admitsTextAtMaxMessageLengthAndSendsWithoutText() {
        let exact = String(repeating: "y", count: ContentSanitizer.maxMessageLength)
        #expect(ConversationSendPreparation.textRejection(forOutgoing: exact) == nil)
        // An attachment-only or voice send has no composer text to reject.
        #expect(ConversationSendPreparation.textRejection(forOutgoing: nil) == nil)
    }
}
