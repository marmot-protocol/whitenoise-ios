import Testing
import Foundation
@testable import darkmatter_ios

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

    @Test func darkmatterDeepLinksRouteInApp() {
        #expect(action("darkmatter://profile/\(validNpub)") == .openProfile(npub: validNpub))
        #expect(action("darkmatter://chat/\(groupIdHex)") == .openChat(groupIdHex: groupIdHex))
    }

    @Test func darkmatterChatRejectsNonGroupIdPayloads() {
        #expect(action("darkmatter://chat/abc") == .blocked)
        #expect(action("darkmatter://unknown/route") == .blocked)
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
