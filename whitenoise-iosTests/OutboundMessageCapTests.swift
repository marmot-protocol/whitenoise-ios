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

    @Test func overageAppearsExactlyWhenRejectedAndCutsToTheLimit() {
        let limit = ContentSanitizer.maxMessageLength
        for count in [limit - 1, limit, limit + 1, limit + 1_000] {
            let text = String(repeating: "x", count: count)
            let overage = OutgoingSendSizePolicy.textOverage(text)
            let rejected = ConversationSendPreparation.textRejection(forOutgoing: text) != nil
            #expect((overage != nil) == rejected)
            if let overage {
                #expect(ConversationSendPreparation.textRejection(forOutgoing: String(text.dropLast(overage))) == nil)
                #expect(ConversationSendPreparation.textRejection(forOutgoing: String(text.dropLast(overage - 1))) != nil)
            }
        }
        #expect(OutgoingSendSizePolicy.textOverage(nil) == nil)
    }

    @Test func overageShrinksAsTextIsDeletedAndCountsCharactersNotScalars() throws {
        let limit = ContentSanitizer.maxMessageLength
        let longer = try #require(OutgoingSendSizePolicy.textOverage(String(repeating: "x", count: limit + 10)))
        let shorter = try #require(OutgoingSendSizePolicy.textOverage(String(repeating: "x", count: limit + 3)))
        #expect(shorter < longer)
        // A multi-scalar emoji is one character, as the send check counts it.
        let family = "👨‍👩‍👧‍👦"
        #expect(OutgoingSendSizePolicy.textOverage(String(repeating: family, count: limit)) == nil)
        #expect(OutgoingSendSizePolicy.textOverage(String(repeating: family, count: limit + 1)) == 1)
    }
}
