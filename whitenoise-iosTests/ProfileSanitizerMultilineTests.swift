import Testing
@testable import whitenoise_ios

/// #60 — multi-line profile fields (e.g. "about") must clamp runs of blank
/// lines so a peer can't flood the UI with vertical whitespace.
struct ProfileSanitizerMultilineTests {

    @Test func clampsRunsOfBlankLines() {
        let flooded = "Line one" + String(repeating: "\n", count: 8) + "Line two"
        #expect(ProfileSanitizer.multilineText(flooded) == "Line one\n\nLine two")
    }

    @Test func clampsCRLFAndLoneCRBlankLineRuns() {
        // CRLF / CR sequences must be normalized so they can't bypass the \n{3,} clamp.
        let crlf = "Line one" + String(repeating: "\r\n", count: 5) + "Line two"
        #expect(ProfileSanitizer.multilineText(crlf) == "Line one\n\nLine two")
        let cr = "Line one" + String(repeating: "\r", count: 5) + "Line two"
        #expect(ProfileSanitizer.multilineText(cr) == "Line one\n\nLine two")
    }

    @Test func keepsASingleBlankLineAndStripsBidi() {
        let raw = "Para one\n\nPara\u{202E}two"
        #expect(ProfileSanitizer.multilineText(raw) == "Para one\n\nParatwo")
    }

    @Test func emptyOrWhitespaceOnlyReturnsNil() {
        #expect(ProfileSanitizer.multilineText("\n\n\n\n") == nil)
        #expect(ProfileSanitizer.multilineText("   ") == nil)
        #expect(ProfileSanitizer.multilineText(nil) == nil)
    }
}
