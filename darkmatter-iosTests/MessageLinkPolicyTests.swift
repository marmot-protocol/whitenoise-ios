import Testing
import Foundation
@testable import darkmatter_ios

/// Tap-time routing for links inside message bubbles: in-app destinations
/// stay in-app, the external allowlist opens via the system, and everything
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

    @Test func nostrNpubRoutesByShapeLikeQrScans() {
        // DeepLink accepts npub-shaped references without checksum validation
        // (same as the QR scanner); Marmot validates the reference downstream.
        let shapeOnly = "npub1" + String(repeating: "q", count: 58)
        #expect(action("nostr:\(shapeOnly)") == .openProfile(npub: shapeOnly))
    }

    @Test func nostrUrisOfOtherKindsStayBlocked() {
        #expect(action("nostr:note1" + String(repeating: "q", count: 58)) == .blocked)
        #expect(action("nostr:nevent1" + String(repeating: "q", count: 58)) == .blocked)
    }

    @Test func externalSchemesOpenExternally() {
        for raw in ["https://example.com/a?b=c", "http://example.com", "mailto:a@b.com", "tel:+15551234567", "whitenoise://x"] {
            let url = URL(string: raw)!
            #expect(MessageLinkPolicy.action(for: url) == .openExternal(url), "url: \(raw)")
        }
    }

    @Test func dangerousAndUnknownSchemesAreBlocked() {
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "ftp://h/x", "ssh://h"] {
            #expect(action(raw) == .blocked, "url: \(raw)")
        }
    }
}
