import Testing
@testable import whitenoise_ios

/// #70 — reaction "emoji" come from peers and must be sanitized before display,
/// without breaking legitimate multi-scalar emoji.
struct ReactionEmojiSanitizerTests {

    @Test func passesPlainEmojiThrough() {
        #expect(ProfileSanitizer.reactionEmoji("👍") == "👍")
    }

    @Test func stripsBidiAndZeroWidthCharacters() {
        #expect(ProfileSanitizer.reactionEmoji("\u{202E}👍\u{200B}") == "👍")
        #expect(ProfileSanitizer.reactionEmoji("  👎\n") == "👎")
    }

    @Test func preservesZWJAndVariationSelectorSequences() {
        #expect(ProfileSanitizer.reactionEmoji("👨‍👩‍👧") == "👨‍👩‍👧") // ZWJ family
        #expect(ProfileSanitizer.reactionEmoji("❤️") == "❤️")           // U+FE0F variation selector
    }

    @Test func capsAbusivelyLongReactions() {
        let long = String(repeating: "🎉", count: 50)
        let sanitized = ProfileSanitizer.reactionEmoji(long)

        #expect(sanitized == String(repeating: "🎉", count: ProfileSanitizer.maxReactionLength))
        #expect(!sanitized.isEmpty)
    }
}
