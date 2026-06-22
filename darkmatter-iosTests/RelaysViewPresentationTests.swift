import Testing
import Foundation
@testable import darkmatter_ios

/// #365 — `RelaysView`'s "Published Relay Lists" section and "Missing" footer
/// render relay URLs straight from `AccountRelayListsFfi` (parsed from
/// relay-hosted NIP-65 / kind:10050 inbox events). Those are relay-influenced
/// display strings, so they must be routed through the relay/URL display
/// boundary sanitizer to strip bidi / zero-width / invisible-format characters
/// that could visually spoof a host (Trojan-Source-style), matching the
/// defense `KeyPackagesView.sanitizedRelays` and `GroupRelaysPresentation.rows`
/// already apply (#298 / #306).
@MainActor
struct RelaysViewPresentationTests {

    // MARK: - Published list rows

    @Test func stripsBidiAndZeroWidthFromPublishedRows() {
        let rows = RelaySettings.publishedRelayRows([
            "wss://relay\u{202E}evil.example",
            "wss://a\u{200B}b.example"
        ])

        #expect(rows.count == 2)
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x202E } })
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x200B } })
        #expect(rows.contains("wss://relayevil.example"))
        #expect(rows.contains("wss://ab.example"))
    }

    @Test func stripsAllBidiAndFormattingControlScalarsFromPublishedRows() {
        // LRM, RLM, LRE..RLO, isolates, ALM, ZWSP, BOM must all be removed.
        let spoofed = "wss://x"
            + "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{200B}\u{FEFF}"
            + ".example"
        #expect(RelaySettings.publishedRelayRows([spoofed]) == ["wss://x.example"])
    }

    @Test func stripsResidualInvisibleFormatCharactersFromPublishedRows() {
        // #306 — ZWNJ, ZWJ, WORD JOINER that the shared sanitizer preserves for
        // general text must still be stripped from relay host strings.
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        let rows = RelaySettings.publishedRelayRows([spoofed])
        #expect(rows == ["wss://relayevil.example"])
        #expect(!rows.contains { $0.unicodeScalars.contains { [0x200C, 0x200D, 0x2060].contains($0.value) } })
    }

    @Test func emptyPublishedListRendersNotPublishedMessage() {
        #expect(RelaySettings.publishedRelayRows([]) == [RelaySettings.notPublishedMessage])
    }

    @Test func publishedRowsThatSanitizeAwayFallBackToNotPublishedMessage() {
        // A non-empty input whose every entry collapses to nothing renderable
        // must still show the empty state, never a blank disclosure row.
        let rows = RelaySettings.publishedRelayRows(["\u{200B}", "\u{FEFF}\u{202E}"])
        #expect(rows == [RelaySettings.notPublishedMessage])
    }

    @Test func cleanPublishedRowsPassThroughUnchanged() {
        let clean = ["wss://relay.one.example", "wss://relay.two.example"]
        #expect(RelaySettings.publishedRelayRows(clean) == clean)
    }

    @Test func collapsesWhitespaceAndTrimsPublishedRows() {
        let rows = RelaySettings.publishedRelayRows(["  wss://relay\t\n  spaced.example  "])
        #expect(rows == ["wss://relay spaced.example"])
    }

    // MARK: - Missing footer labels

    @Test func stripsBidiAndZeroWidthFromMissingLabels() {
        let labels = RelaySettings.missingRelayLabels([
            "wss://relay\u{202E}evil.example",
            "wss://a\u{200B}b.example"
        ])

        #expect(labels == ["wss://relayevil.example", "wss://ab.example"])
        #expect(!labels.contains { $0.unicodeScalars.contains { [0x202E, 0x200B].contains($0.value) } })
    }

    @Test func dropsMissingLabelsThatSanitizeAway() {
        // Entries that collapse to nothing renderable are dropped from the
        // joined footer rather than contributing an empty fragment.
        let labels = RelaySettings.missingRelayLabels(["\u{200B}", "wss://ok.example", "\u{FEFF}\u{202E}"])
        #expect(labels == ["wss://ok.example"])
    }

    @Test func cleanMissingLabelsPassThroughUnchanged() {
        let clean = ["NIP-65", "Inbox"]
        #expect(RelaySettings.missingRelayLabels(clean) == clean)
    }

    @Test func emptyMissingListYieldsNoLabels() {
        #expect(RelaySettings.missingRelayLabels([]).isEmpty)
    }
}
