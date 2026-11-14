import Foundation
import UIKit
import Testing
import MarmotKit
@testable import whitenoise_ios

struct CustomEmojiBuiltinsTests {
    typealias F = CustomEmojiFixtures
    let marmot = CustomEmojiShortcode("marmot")!
    let party = CustomEmojiShortcode("party")!
    let partyURL = "https://blossom.example.com/party"

    @Test func everyBuiltinShipsADecodableSendableImage() throws {
        #expect(!CustomEmojiBuiltins.all.isEmpty)
        for builtin in CustomEmojiBuiltins.all {
            #expect(CustomEmojiSendPolicy.isSendable(builtin.shortcode))
            let image = try #require(UIImage(data: builtin.data))
            #expect(image.size.width > 0)
            #expect(builtin.dim != nil)
            #expect(CustomEmojiBuiltins.builtin(builtin.shortcode) == builtin)
        }
        #expect(CustomEmojiBuiltins.shortcodes.count == CustomEmojiBuiltins.all.count)
    }

    @Test func untaggedBuiltinShortcodesRenderFromTheBundle() {
        let resolution = CustomEmojiResolver.claim([:], attachments: [], displayedRuns: ["time to :party: :marmot:"],
                                                   builtins: [marmot])
        #expect(resolution.builtin == [marmot])
        #expect(resolution.inline.isEmpty)
        #expect(!resolution.isEmpty)
        #expect(resolution.shortcodes == [marmot])

        let absent = CustomEmojiResolver.claim([:], attachments: [], displayedRuns: ["marmot"], builtins: [marmot])
        #expect(absent.isEmpty)
    }

    @Test func aRowsOwnDefinitionWinsOverTheBuiltin() {
        let reference = F.reference(url: partyURL)
        let attachments = F.attachments([.accepted(attachmentIndex: 0, reference: reference)])
        let resolution = CustomEmojiResolver.resolve(
            text: ":marmot: and :party:",
            tags: [F.tag("emoji", "marmot", partyURL)],
            attachments: attachments,
            builtins: [marmot, party]
        )
        #expect(Set(resolution.inline.keys) == [marmot])
        #expect(resolution.builtin == [party])
        #expect(resolution.gridItems.isEmpty)
    }

    @Test func builtinImagesShowWithoutAChatScope() {
        let resolution = CustomEmojiResolver.claim([:], attachments: [], displayedRuns: [":marmot:"], builtins: [marmot])
        let images: [CustomEmojiShortcode: String] = CustomEmojiInlinePresentation.images(
            for: resolution, loaded: [:], scope: nil, pixelSize: 40) { $0 == marmot ? "bundled" : nil }
        #expect(images == [marmot: "bundled"])
    }

    @Test func builtinsComeFirstAndOwnTheirShortcode() {
        let chatMarmot = F.reference(url: "https://theirs.example/marmot", sha: String(repeating: "c", count: 64))
        let chatParty = F.reference(url: partyURL)
        let catalog = [
            CustomEmojiCatalogEntry(shortcode: marmot, reference: chatMarmot, source: .message(messageIdHex: "m1", attachmentIndex: 0)),
            CustomEmojiCatalogEntry(shortcode: party, reference: chatParty, source: .message(messageIdHex: "m1", attachmentIndex: 1)),
        ]
        let sendables = CustomEmojiSendCatalog.sendables(catalog: catalog, builtins: [F.builtin("marmot"), F.builtin("wn")]) {
            F.attachments([.accepted(attachmentIndex: 0, reference: $0)])[0]
        }
        #expect(sendables.map(\.id) == ["marmot", "wn", "party"])
        #expect(sendables[0].chatReference == nil)
        #expect(CustomEmojiSendCatalog.used(in: "hi :marmot:", sendables: sendables).map(\.id) == ["marmot"])
    }

    @Test func pickerSearchFindsBuiltinsByProductName() {
        let all = [CustomEmojiSendable(builtin: F.builtin("wn", spokenName: "White Noise")),
                   CustomEmojiSendable(builtin: F.builtin("marmot", spokenName: "Marmot"))]
        #expect(CustomEmojiPickerSearch.results(in: all, query: "noise").map(\.id) == ["wn"])
        #expect(CustomEmojiPickerSearch.results(in: all, query: ":wn:").map(\.id) == ["wn"])
    }

    /// A catalog key that doesn't match falls back to the English key, so a
    /// typo shows up as an untranslated or duplicated name.
    @Test func everyBuiltinHasADistinctTranslatedSpokenName() {
        let languages = AppLanguage.allCases.filter { $0 != .system }
        let english = withAppLanguage(.english) { CustomEmojiBuiltins.all.map(\.spokenName) }
        for language in languages {
            let names = withAppLanguage(language) { CustomEmojiBuiltins.all.map(\.spokenName) }
            #expect(Set(names).count == names.count, "\(language)")
            #expect(names.allSatisfy { !$0.isEmpty }, "\(language)")
            guard language != .english else { continue }
            for (index, builtin) in CustomEmojiBuiltins.all.enumerated() {
                guard case .localized = builtin.name else { continue }
                #expect(names[index] != english[index], "\(language) \(builtin.shortcode.name)")
            }
        }
    }

    @Test func voiceOverReadsTheProductNameOfABuiltin() throws {
        let builtin = try #require(CustomEmojiBuiltins.all.first)
        #expect(CustomEmojiShortcode.spokenReaction(builtin.shortcode.token) == builtin.spokenName)
        #expect(CustomEmojiShortcode.spokenReaction(":party_parrot:") == "party_parrot")
    }
}
