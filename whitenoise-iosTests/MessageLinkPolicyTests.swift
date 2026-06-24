import Testing
import Foundation
@testable import whitenoise_ios

/// Tap-time routing for links inside message bubbles: in-app destinations
/// stay in-app, the external allowlist asks for confirmation, and everything
/// else is inert.
struct MessageLinkPolicyTests {

    /// Checksum-valid npub from the NIP-19 test vectors.
    private let validNpub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
    private let groupIdHex = String(repeating: "ab", count: 32)

    private func action(_ raw: String) -> MessageLinkAction? {
        URL(string: raw).map(MessageLinkPolicy.action(for:))
    }

    @Test func whitenoiseDeepLinksRouteInApp() {
        #expect(action("whitenoise://profile/\(validNpub)") == .openProfile(npub: validNpub))
        #expect(action("whitenoise://chat/\(groupIdHex)") == .openChat(groupIdHex: groupIdHex))
    }

    @Test func whitenoiseChatRejectsNonGroupIdPayloads() {
        #expect(action("whitenoise://chat/abc") == .blocked)
        #expect(action("whitenoise://unknown/route") == .blocked)
    }

    @Test func nostrProfileUrisRouteToProfile() {
        #expect(action("nostr:\(validNpub)") == .openProfile(npub: validNpub))
    }

    @Test func nostrNpubRejectsBadChecksumLikeQrScans() {
        let shapeOnly = "npub1" + String(repeating: "q", count: 58)
        #expect(action("nostr:\(shapeOnly)") == .blocked)
    }

    @Test func nostrUrisOfOtherKindsStayBlocked() {
        #expect(action("nostr:note1" + String(repeating: "q", count: 58)) == .blocked)
        #expect(action("nostr:nevent1" + String(repeating: "q", count: 58)) == .blocked)
    }

    @Test func externalSchemesAskForConfirmation() {
        for raw in ["https://example.com/a?b=c", "http://example.com", "mailto:a@b.com", "tel:+15551234567", "whitenoise://x"] {
            let url = URL(string: raw)!
            #expect(MessageLinkPolicy.action(for: url) == .confirmExternal(url), "url: \(raw)")
        }
    }

    @Test func externalConfirmationBoundsLongPeerURLs() {
        withAppLanguage(.english) {
            let run = String(repeating: "a", count: 260)
            let url = URL(string: "https://example.com/\(run)?token=\(run)")!
            let text = MessageExternalLinkConfirmation.displayText(for: url)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

            #expect(lines.count == 2)
            #expect(lines[0] == "This link opens example.com:")
            #expect(lines[1].count == 180)
            #expect(lines[1].contains("…"))
            #expect(!text.contains(run))
        }
    }

    @Test func externalConfirmationFlagsPunycodeHosts() {
        withAppLanguage(.english) {
            let url = URL(string: "https://xn--bcher-kva.example/path")!
            let text = MessageExternalLinkConfirmation.displayText(for: url)

            #expect(text.contains("b\u{00FC}cher.example (IDN/punycode: xn--bcher-kva.example)"))
            #expect(text.contains("https://xn--bcher-kva.example/path"))
        }
    }

    /// Regression for #254: a crafted `xn--` label can drive the punycode
    /// decoder's `i` accumulator to exactly `Int.max`, which previously made
    /// the unguarded `n += i / outputCount` add trap. The decoder must bail to
    /// the raw host instead of crashing the link-confirmation text builder.
    @Test func externalConfirmationSurvivesPunycodeOverflowLabel() {
        withAppLanguage(.english) {
            let url = URL(string: "https://xn--hz767205604493046e.example/path")!
            let text = MessageExternalLinkConfirmation.displayText(for: url)

            // No trap: the malformed label is shown raw, not decoded.
            #expect(text.contains("xn--hz767205604493046e.example"))
            #expect(text.contains("https://xn--hz767205604493046e.example/path"))
        }
    }

    /// Regression for #296: a peer-controlled autolink host can carry a
    /// multi-thousand-character `xn--` label, and the punycode decoder grows
    /// its output with O(n) `Array.insert(_:at:)` calls (O(L²) overall) on the
    /// MainActor at tap time. The confirmation builder must cap the host before
    /// decode and bound the decoder's own output, so an over-long host is shown
    /// elided/raw without paying the quadratic cost or stalling the main thread.
    @Test func externalConfirmationBoundsOverlongPunycodeHost() {
        withAppLanguage(.english) {
            // ~7900-char single `xn--` label, within `maxMessageLength` (8000)
            // so it survives outbound capping but is far beyond what is shown.
            let hugeLabel = "xn--" + String(repeating: "a", count: 7900)
            let url = URL(string: "https://\(hugeLabel).example/path")!

            // Must return quickly; if the O(L²) decode ran on the full label
            // this would stall. Wall-clock isn't asserted here (it's a unit
            // test), but the input cap guarantees the decoder never sees it.
            let text = MessageExternalLinkConfirmation.displayText(for: url)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

            #expect(lines.count == 2)
            // Host line is elided to the display cap (no decode, no IDN suffix).
            let hostLine = String(lines[0])
            #expect(hostLine.hasPrefix("This link opens "))
            #expect(hostLine.hasSuffix(":"))
            #expect(hostLine.contains("…"))
            #expect(!hostLine.contains("IDN/punycode"))
            // The full label never appears verbatim in the host display.
            #expect(!hostLine.contains(hugeLabel))
        }
    }

    @Test func externalConfirmationHandlesHostlessExternalURLs() {
        withAppLanguage(.english) {
            let url = URL(string: "mailto:a@b.com")!

            #expect(MessageExternalLinkConfirmation.displayText(for: url) == "This link opens:\nmailto:a@b.com")
        }
    }

    @Test func dangerousAndUnknownSchemesAreBlocked() {
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "ftp://h/x", "ssh://h"] {
            #expect(action(raw) == .blocked, "url: \(raw)")
        }
    }
}
