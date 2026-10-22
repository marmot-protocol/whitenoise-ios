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
}
