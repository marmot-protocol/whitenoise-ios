import Testing
@testable import whitenoise_ios

/// #306 — relay / URL-like single-line display must remove the residual
/// invisible Unicode *format* characters that the shared `singleLine` sanitizer
/// intentionally preserves for general text (so ZWJ emoji survive for
/// `reactionEmoji`, #70). For a host/URL string ZWNJ/ZWJ/WORD JOINER are pure
/// spoofing vectors and must be stripped.
struct ProfileSanitizerRelayDisplayTests {

    @Test func stripsZeroWidthNonJoinerJoinerAndWordJoiner() {
        // U+200C ZWNJ, U+200D ZWJ, U+2060 WORD JOINER embedded in a host label.
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        let display = ProfileSanitizer.relayDisplayLine(spoofed, maxLength: 120)
        #expect(display == "wss://relayevil.example")
    }

    @Test func stripsTheFullInvisibleFormatFamily() {
        // Everything stripUnsafe already removes (bidi marks/overrides/isolates,
        // ALM, ZWSP, BOM) PLUS the previously-preserved ZWNJ/ZWJ/WORD JOINER.
        let spoofed = "wss://x"
            + "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{200B}\u{FEFF}"
            + "\u{200C}\u{200D}\u{2060}"
            + ".example"
        #expect(ProfileSanitizer.relayDisplayLine(spoofed, maxLength: 120) == "wss://x.example")
    }

    @Test func collapsesWhitespaceLikeSingleLine() {
        let display = ProfileSanitizer.relayDisplayLine("  wss://relay\t\n  spaced.example  ", maxLength: 120)
        #expect(display == "wss://relay spaced.example")
    }

    @Test func cleanRelayPassesThroughUnchanged() {
        #expect(ProfileSanitizer.relayDisplayLine("wss://relay.example", maxLength: 120) == "wss://relay.example")
    }

    @Test func emptyOrFormatOnlyReturnsNil() {
        #expect(ProfileSanitizer.relayDisplayLine(nil, maxLength: 120) == nil)
        #expect(ProfileSanitizer.relayDisplayLine("   ", maxLength: 120) == nil)
        // A string of only invisible-format characters has nothing renderable.
        #expect(ProfileSanitizer.relayDisplayLine("\u{200C}\u{200D}\u{2060}\u{FEFF}", maxLength: 120) == nil)
    }

    @Test func capsLength() {
        let long = "wss://" + String(repeating: "a", count: 200) + ".example"
        let display = ProfileSanitizer.relayDisplayLine(long, maxLength: 120)
        #expect((display?.count ?? 0) <= 120)
    }

    /// The stricter relay policy must NOT change the shared sanitizer: reaction
    /// emoji still preserve legitimate ZWJ / variation-selector sequences (#70).
    @Test func reactionEmojiStillPreservesZWJSequences() {
        #expect(ProfileSanitizer.reactionEmoji("👨‍👩‍👧") == "👨‍👩‍👧") // ZWJ family
        #expect(ProfileSanitizer.reactionEmoji("❤️") == "❤️")           // U+FE0F variation selector
    }

    /// And the shared `singleLine` is unchanged — it still preserves ZWNJ/ZWJ/
    /// WORD JOINER so non-relay surfaces (names, message bodies) are untouched.
    @Test func singleLineStillPreservesFormatCharacters() {
        let withZWJ = "a\u{200D}b"
        #expect(ProfileSanitizer.singleLine(withZWJ, maxLength: 80) == withZWJ)
    }
}
