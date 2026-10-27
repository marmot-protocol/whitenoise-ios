import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct DeepLinkTests {
    /// Checksum-valid npub from the NIP-19 test vectors.
    private let validNpub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
    private let groupIdHex = String(repeating: "ab", count: 32)
    private let valid64 = String(repeating: "a", count: 64)

    @Test func generatedURLKeepsDelimiterCharactersInsidePathComponent() {
        let profileURL = DeepLink.profile(npub: "npub?query#fragment/child").url
        let chatURL = DeepLink.chat(groupIdHex: "ABC?query#fragment/child").url
        let expectedScheme = DeepLink.canonicalScheme

        #expect(expectedScheme == "marmot")
        #expect(profileURL.absoluteString == "\(expectedScheme)://profile/npub%3Fquery%23fragment%2Fchild")
        #expect(profileURL.query == nil)
        #expect(profileURL.fragment == nil)

        #expect(chatURL.absoluteString == "\(expectedScheme)://chat/ABC%3Fquery%23fragment%2Fchild")
        #expect(chatURL.query == nil)
        #expect(chatURL.fragment == nil)
    }

    @Test func legacyWhiteNoiseProfileLinksStillParse() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        for scheme in ["whitenoise", "whitenoise-staging"] {
            #expect(DeepLink.parse(string: "\(scheme)://profile/\(npub)") == .profile(npub: npub))
        }
    }

    @Test func darkmatterProfileLinksDoNotParse() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        #expect(DeepLink.parse(string: "darkmatter://profile/\(npub)") == nil)
    }

    // MARK: - Generated links
    //
    // Generated QR/share links must carry the canonical cross-client scheme in
    // every build flavor, while inbound parsing stays scheme-liberal.

    @Test func generatedLinksUseCanonicalScheme() {
        #expect(DeepLink.profile(npub: validNpub).url.scheme == "marmot")
        #expect(DeepLink.chat(groupIdHex: groupIdHex).url.scheme == "marmot")
    }

    @Test func generatedLinksRoundTripThroughParse() {
        #expect(DeepLink.parse(DeepLink.profile(npub: validNpub).url) == .profile(npub: validNpub))
        #expect(DeepLink.parse(DeepLink.chat(groupIdHex: groupIdHex).url) == .chat(groupIdHex: groupIdHex))
    }

    @Test func flavorSchemeLinksStillParse() {
        for scheme in ["marmot", "marmot-staging", "whitenoise", "whitenoise-staging"] {
            #expect(DeepLink.parse(string: "\(scheme)://profile/\(validNpub)") == .profile(npub: validNpub), "scheme: \(scheme)")
        }
    }

    // MARK: - Chat group ids
    //
    // #68 — chat deep links must carry a 64-char (32-byte) hex group id; any
    // other length must be rejected before it reaches Marmot.

    @Test func acceptsAndLowercases64CharHexGroupId() {
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(valid64)") == .chat(groupIdHex: valid64))
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(valid64.uppercased())") == .chat(groupIdHex: valid64))
    }

    @Test func acceptsLegacyWhiteNoiseChatLinks() {
        for scheme in ["whitenoise", "whitenoise-staging"] {
            #expect(DeepLink.parse(string: "\(scheme)://chat/\(valid64)") == .chat(groupIdHex: valid64))
        }
    }

    @Test func rejectsNon64CharOrNonHexGroupId() {
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/abc") == nil)
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(String(repeating: "a", count: 63))") == nil)
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(String(repeating: "a", count: 65))") == nil)
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(String(repeating: "z", count: 64))") == nil)
    }
}
