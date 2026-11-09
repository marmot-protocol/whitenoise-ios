import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

struct CustomEmojiReactionResolutionTests {
    typealias F = CustomEmojiFixtures
    let reactionID = String(repeating: "ef", count: 32)

    func entry(id: String? = nil, outcome: MediaAttachmentOutcomeFfi? = nil) -> AttachmentEntryFfi {
        AttachmentEntryFfi(
            messageIdHex: id ?? reactionID, sourceMessageIdHex: String(repeating: "12", count: 32),
            sender: String(repeating: "34", count: 32), timelineAt: 10, receivedAt: 10, sourceEpoch: 3,
            category: .image, role: .inlineEmoji,
            attachment: outcome ?? .accepted(attachmentIndex: 0,
                reference: F.reference(url: "https://blossom.example.com/party")))
    }

    @Test func acceptedImageOfTheSameReactionResolves() throws {
        let artwork = try #require(CustomEmojiReactionResolution.artwork(
            emoji: ":party:", reactionMessageIdHex: reactionID, entry: entry()))
        #expect(artwork.shortcode == CustomEmojiShortcode("party"))
        #expect(artwork.reactionMessageIdHex == reactionID)
        #expect(artwork.attachment.localTarget != nil)
        #expect(artwork.reference?.locators.first?.value == "https://blossom.example.com/party")
    }

    @Test func artworkIsRefusedUnlessEverythingMatches() {
        func resolve(_ emoji: String, _ entry: AttachmentEntryFfi?) -> CustomEmojiReactionArtwork? {
            CustomEmojiReactionResolution.artwork(emoji: emoji, reactionMessageIdHex: reactionID, entry: entry)
        }
        #expect(resolve("👍", entry()) == nil)
        #expect(resolve(":party:", nil) == nil)
        #expect(resolve(":party:", entry(id: String(repeating: "00", count: 32))) == nil)
        #expect(resolve(":party:", entry(outcome: .accepted(attachmentIndex: 0,
            reference: F.reference(url: "https://blossom.example.com/clip", mediaType: "video/mp4")))) == nil)
        #expect(resolve(":party:", entry(outcome: .accepted(attachmentIndex: 0,
            reference: F.reference(url: "http://127.0.0.1/party")))) == nil)
    }

    @Test func pendingLookupsAreDistinctBoundedAndSkipKnownOutcomes() {
        let tallies: [(emoji: String, reactionMessageIdHex: String?)] = [
            ("👍", "a"), (":party:", "b"), (":party:", "b"), (":cat:", nil), (":cat:", ""),
            (":dog:", "c"), (":fox:", "d"), (":owl:", "e"), (":bee:", "f"),
        ]
        let pending = CustomEmojiReactionResolution.pendingLookups(
            tallies: tallies, resolved: ["c"], misses: ["d"], limit: 3)
        #expect(pending.map(\.reactionMessageIdHex) == ["b", "e"])
        #expect(pending.map(\.emoji) == [":party:", ":owl:"])
    }

    @Test func catalogEntriesAreOrderedByReactionAndNameTheirSlot() throws {
        let first = try #require(CustomEmojiReactionResolution.artwork(
            emoji: ":party:", reactionMessageIdHex: reactionID, entry: entry()))
        let otherID = String(repeating: "01", count: 32)
        let second = try #require(CustomEmojiReactionResolution.artwork(
            emoji: ":cat:", reactionMessageIdHex: otherID, entry: entry(id: otherID)))
        let entries = CustomEmojiReactionResolution.catalogEntries([reactionID: first, otherID: second])
        #expect(entries.map(\.shortcode) == [CustomEmojiShortcode("cat"), CustomEmojiShortcode("party")])
        #expect(entries.first?.source == .reaction(reactionMessageIdHex: otherID, attachmentIndex: 0))
    }
}
