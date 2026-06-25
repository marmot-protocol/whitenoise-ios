import Testing
import Foundation
@testable import whitenoise_ios

/// #298 — group relay strings come from `AppGroupRecordFfi.relays`, which is
/// MLS-propagated group metadata controlled by a (possibly malicious) group
/// admin. The Relays disclosure in `GroupDetailsView` must strip bidi /
/// zero-width characters so a relay URL can't visually spoof a trusted host
/// (Trojan-Source-style), matching the defense `KeyPackagesView` already
/// applies to relay strings.
struct GroupRelaysPresentationTests {

    @Test func stripsBidiAndZeroWidthFromRelayRows() {
        let rows = GroupRelaysPresentation.rows(for: [
            "wss://relay\u{202E}evil.example",
            "wss://a\u{200B}b.example"
        ])

        #expect(rows.count == 2)
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x202E } })
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x200B } })
        #expect(rows.contains("wss://relayevil.example"))
        #expect(rows.contains("wss://ab.example"))
    }

    @Test func stripsAllBidiAndFormattingControlScalars() {
        // LRM, RLM, LRE..RLO, isolates, ALM, ZWSP, BOM must all be removed.
        let spoofed = "wss://x"
            + "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{200B}\u{FEFF}"
            + ".example"
        let rows = GroupRelaysPresentation.rows(for: [spoofed])

        #expect(rows == ["wss://x.example"])
    }

    /// #306 — relay rows must also strip the invisible format characters the
    /// shared sanitizer preserves for general text: ZWNJ, ZWJ, WORD JOINER.
    @Test func stripsResidualInvisibleFormatCharacters() {
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        let rows = GroupRelaysPresentation.rows(for: [spoofed])
        #expect(rows == ["wss://relayevil.example"])
        #expect(!rows.contains { $0.unicodeScalars.contains { [0x200C, 0x200D, 0x2060].contains($0.value) } })
    }

    @Test func emptyRelaysRendersEmptyMessage() {
        #expect(GroupRelaysPresentation.rows(for: []) == [GroupRelaysPresentation.emptyMessage])
    }

    @Test func relaysThatSanitizeAwayFallBackToEmptyMessage() {
        // A non-empty input whose every entry collapses to nothing renderable
        // must still show the empty state, never a blank disclosure.
        let rows = GroupRelaysPresentation.rows(for: ["\u{200B}", "\u{FEFF}\u{202E}"])
        #expect(rows == [GroupRelaysPresentation.emptyMessage])
    }

    @Test func cleanRelaysPassThroughUnchanged() {
        let clean = ["wss://relay.one.example", "wss://relay.two.example"]
        #expect(GroupRelaysPresentation.rows(for: clean) == clean)
    }

    @Test func collapsesWhitespaceAndTrims() {
        // singleLine collapses internal whitespace runs and trims; verify the
        // group rows inherit that normalization.
        let rows = GroupRelaysPresentation.rows(for: ["  wss://relay\t\n  spaced.example  "])
        #expect(rows == ["wss://relay spaced.example"])
    }
}
