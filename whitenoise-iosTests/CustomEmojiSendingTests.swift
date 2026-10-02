import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

struct CustomEmojiSendingTests {
    typealias F = CustomEmojiFixtures
    let partyURL = "https://blossom.example.com/party"

    func code(_ name: String) -> CustomEmojiShortcode { CustomEmojiShortcode(name)! }

    func sendable(_ name: String, sha: String = String(repeating: "b", count: 64), url: String? = nil) -> CustomEmojiSendable {
        let reference = F.reference(url: url ?? "https://blossom.example.com/\(name)", sha: sha)
        let source = F.attachments([.accepted(attachmentIndex: 0, reference: reference)])[0]
        return CustomEmojiSendable(shortcode: code(name), reference: reference, source: source)
    }

    // MARK: Shortcodes

    @Test func onlyNip30ShortcodesThatFitAReactionAreSendable() {
        #expect(CustomEmojiSendPolicy.isSendable(code("party_Parrot2")))
        // Received hyphenated shortcodes still render but are never re-sent.
        #expect(!CustomEmojiSendPolicy.isSendable(code("party-parrot")))
        #expect(CustomEmojiSendPolicy.isSendable(code(String(repeating: "a", count: 62))))
        // `:shortcode:` stays within MDK's 64-character reaction content.
        #expect(!CustomEmojiSendPolicy.isSendable(code(String(repeating: "a", count: 63))))
    }

    // MARK: Tags

    @Test func emojiTagNamesTheFirstLocator() throws {
        let reference = F.reference(url: partyURL, extraLocators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://mirror.example/x")])
        #expect(try CustomEmojiTags.emojiTag(code("party"), reference: reference) == ["emoji", "party", partyURL])
    }

    @Test func emojiTagRejectsUnsendableShortcodesAndMissingLocators() {
        #expect(throws: CustomEmojiSendError.unsendableShortcode("a-b")) {
            try CustomEmojiTags.emojiTag(code("a-b"), reference: F.reference(url: partyURL))
        }
        var noLocator = F.reference(url: partyURL)
        noLocator.locators = []
        #expect(throws: CustomEmojiSendError.missingLocator) {
            try CustomEmojiTags.emojiTag(code("party"), reference: noLocator)
        }
        #expect(throws: CustomEmojiSendError.missingLocator) {
            try CustomEmojiTags.emojiTag(code("party"), reference: F.reference(url: " \(partyURL)"))
        }
    }

    @Test func messageTagsListEmojiInTextOrderThenReplyRows() throws {
        let target = String(repeating: "ab", count: 32)
        let tags = try CustomEmojiTags.messageTags(
            emoji: [(code("party"), F.reference(url: partyURL)), (code("cat"), F.reference(url: "https://b.example/cat"))],
            replyTargetId: target
        )
        #expect(tags == [
            ["emoji", "party", partyURL],
            ["emoji", "cat", "https://b.example/cat"],
            ["e", target],
            ["q", target],
        ])
        #expect(!tags.contains { $0.first == "imeta" })
    }

    @Test func tagLimitsMirrorMdk() throws {
        let row = ["emoji", "a", "u"]
        try CustomEmojiTags.validate(Array(repeating: row, count: 64))
        #expect(throws: CustomEmojiSendError.tooManyTags(count: 65)) {
            try CustomEmojiTags.validate(Array(repeating: row, count: 65))
        }
        // 16 KiB of UTF-8 tag values in total, counting every element.
        let atLimit = [["emoji", "a", String(repeating: "x", count: 16 * 1024 - 6)]]
        try CustomEmojiTags.validate(atLimit)
        let overLimit = [["emoji", "a", String(repeating: "x", count: 16 * 1024 - 5)]]
        #expect(throws: CustomEmojiSendError.tagValuesTooLarge(bytes: 16 * 1024 + 1)) {
            try CustomEmojiTags.validate(overLimit)
        }
        let multibyte = [["emoji", "a", String(repeating: "é", count: 8 * 1024)]]
        #expect(throws: CustomEmojiSendError.tagValuesTooLarge(bytes: 16 * 1024 + 6)) {
            try CustomEmojiTags.validate(multibyte)
        }
    }

    @Test func tagValidationRejectsRowsMdkRejects() {
        #expect(throws: CustomEmojiSendError.forbiddenImetaTag) { try CustomEmojiTags.validate([["imeta", "v 2"]]) }
        #expect(throws: CustomEmojiSendError.malformedTag) { try CustomEmojiTags.validate([[]]) }
        #expect(throws: CustomEmojiSendError.malformedTag) { try CustomEmojiTags.validate([["", "x"]]) }
        #expect(throws: CustomEmojiSendError.emptyEventTarget) { try CustomEmojiTags.validate([["e"]]) }
        #expect(throws: CustomEmojiSendError.emptyEventTarget) { try CustomEmojiTags.validate([["q", " "]]) }
        #expect(throws: CustomEmojiSendError.emptyEventTarget) {
            try CustomEmojiTags.messageTags(emoji: [(code("party"), F.reference(url: partyURL))], replyTargetId: "")
        }
    }

    @Test func precheckFailsBeforeUploadWhenEmojiAndReplyRowsExceedTheLimit() throws {
        try CustomEmojiTags.precheck(emojiCount: 64, isReply: false)
        try CustomEmojiTags.precheck(emojiCount: 62, isReply: true)
        #expect(throws: CustomEmojiSendError.tooManyTags(count: 65)) {
            try CustomEmojiTags.precheck(emojiCount: 63, isReply: true)
        }
    }

    @Test func limitErrorsExplainTheFix() {
        #expect(!CustomEmojiSendError.tooManyTags(count: 65).message.isEmpty)
        #expect(CustomEmojiSendError.tooManyTags(count: 65).message == CustomEmojiSendError.tagValuesTooLarge(bytes: 1).message)
        #expect(CustomEmojiSendError.mixedWithAttachments.message != CustomEmojiSendError.sendFailed.message)
    }

    // MARK: Catalog

    @Test func usedEmojiFollowTextOrderAndIgnoreOtherShortcodes() {
        let party = sendable("party")
        let cat = sendable("cat", sha: String(repeating: "c", count: 64))
        let used = CustomEmojiSendCatalog.used(in: ":cat: hi :party: :dog: :cat: x:party", sendables: [party, cat])
        #expect(used.map(\.id) == ["cat", "party"])
        #expect(CustomEmojiSendCatalog.used(in: "plain text", sendables: [party]).isEmpty)
        #expect(CustomEmojiSendCatalog.used(in: ":party:", sendables: []).isEmpty)
    }

    @Test func sendablesKeepOneReadableNip30ImagePerShortcode() {
        let party = F.reference(url: partyURL, sha: String(repeating: "1", count: 64))
        let otherParty = F.reference(url: "https://b.example/party2", sha: String(repeating: "2", count: 64))
        let hyphen = F.reference(url: "https://b.example/h", sha: String(repeating: "3", count: 64))
        let unreadable = F.reference(url: "https://b.example/u", sha: String(repeating: "4", count: 64))
        let entries = [
            CustomEmojiCatalogEntry(shortcode: code("a-b"), reference: hyphen, source: .message(messageIdHex: "m1", attachmentIndex: 0)),
            CustomEmojiCatalogEntry(shortcode: code("ghost"), reference: unreadable, source: .message(messageIdHex: "m1", attachmentIndex: 1)),
            CustomEmojiCatalogEntry(shortcode: code("party"), reference: party, source: .message(messageIdHex: "m2", attachmentIndex: 0)),
            CustomEmojiCatalogEntry(shortcode: code("party"), reference: otherParty, source: .message(messageIdHex: "m3", attachmentIndex: 0)),
        ]
        let readable = Set([party, otherParty, hyphen].map(\.plaintextSha256))
        let sendables = CustomEmojiSendCatalog.sendables(catalog: entries) { reference in
            readable.contains(reference.plaintextSha256)
                ? F.attachments([.accepted(attachmentIndex: 0, reference: reference)])[0] : nil
        }
        #expect(sendables.map(\.id) == ["party"])
        #expect(sendables.first?.reference == party)
    }

    // MARK: Reactions

    @Test func customShortcodeChipsNeverAddAReaction() {
        // Deferred until MDK epoch-pins media reactions (#1137): no media
        // reaction, and no plain-text `:party:` copy either.
        #expect(!CustomEmojiReactionPolicy.allowsAdding(":party:"))
        #expect(CustomEmojiReactionPolicy.allowsAdding("👍"))
        #expect(CustomEmojiReactionPolicy.allowsAdding("party"))
    }

    // MARK: Composer and picker

    @Test func insertionKeepsTheShortcodeAWholeToken() {
        #expect(CustomEmojiComposerText.inserting(":party:", into: "") == ":party:")
        #expect(CustomEmojiComposerText.inserting(":party:", into: "hi") == "hi :party:")
        #expect(CustomEmojiComposerText.inserting(":party:", into: "hi ") == "hi :party:")
        #expect(CustomEmojiComposerText.inserting(":cat:", into: ":party:") == ":party: :cat:")
        #expect(CustomEmojiComposerText.inserting("🎉", into: "hi\n") == "hi\n🎉")
    }


    @Test func pickerSearchMatchesShortcodes() {
        let all = [sendable("party_parrot"), sendable("cat")]
        #expect(CustomEmojiPickerSearch.results(in: all, query: "parrot").map(\.id) == ["party_parrot"])
        #expect(CustomEmojiPickerSearch.results(in: all, query: ":CAT:").map(\.id) == ["cat"])
        #expect(CustomEmojiPickerSearch.results(in: all, query: "dog").isEmpty)
        #expect(CustomEmojiPickerSearch.results(in: all, query: "  ").map(\.id) == ["party_parrot", "cat"])
    }

    @Test func composerOffersCustomEmojiOnlyWhenTheChatHoldsSome() {
        #expect(!ComposerAttachmentOption.available(cameraAvailable: true, gifsAvailable: true).contains(.customEmoji))
        let options = ComposerAttachmentOption.available(cameraAvailable: true, gifsAvailable: true,
                                                         pollsAvailable: true, customEmojiAvailable: true)
        #expect(options == [.camera, .photosAndVideos, .files, .gifs, .customEmoji, .location, .contact, .poll])
    }
}
