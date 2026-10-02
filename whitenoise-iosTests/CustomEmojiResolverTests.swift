import Foundation
import SwiftUI
import Testing
import UIKit
import MarmotKit
@testable import whitenoise_ios

enum CustomEmojiFixtures {
    static let messageID = String(repeating: "ab", count: 32)
    static let sourceID = String(repeating: "cd", count: 32)

    static func reference(url: String, sha: String = String(repeating: "b", count: 64),
                          mediaType: String = "image/png", extraLocators: [MediaLocatorFfi] = []) -> MediaAttachmentReferenceFfi {
        MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: url)] + extraLocators,
            ciphertextSha256: String(repeating: "a", count: 64),
            plaintextSha256: sha,
            nonceHex: String(repeating: "2", count: 24),
            fileName: "emoji.png",
            mediaType: mediaType,
            version: .v2,
            sourceEpoch: 3,
            dim: "64x64",
            thumbhash: nil
        )
    }

    static func attachments(_ outcomes: [MediaAttachmentOutcomeFfi], messageID: String = messageID,
                            sourceID: String? = sourceID) -> [MessageMediaAttachment] {
        MessageMediaAttachment.displayItems(fromOutcomes: outcomes, ownerId: "msg:\(messageID)",
            messageId: messageID, sourceMessageId: sourceID)
    }

    static func tag(_ values: String...) -> MessageTagFfi { MessageTagFfi(values: values) }
}

struct CustomEmojiResolverTests {
    typealias F = CustomEmojiFixtures
    let partyURL = "https://blossom.example.com/party"
    let catURL = "https://blossom.example.com/cat"

    // MARK: Shortcodes and tags

    @Test func shortcodeAcceptsOnlyNip30Characters() {
        #expect(CustomEmojiShortcode("party_parrot-2")?.name == "party_parrot-2")
        #expect(CustomEmojiShortcode("") == nil)
        #expect(CustomEmojiShortcode("has space") == nil)
        #expect(CustomEmojiShortcode("emoji:colon") == nil)
        #expect(CustomEmojiShortcode("café") == nil)
        #expect(CustomEmojiShortcode(String(repeating: "a", count: 65)) == nil)
        #expect(CustomEmojiShortcode(reactionContent: ":cat:")?.name == "cat")
        #expect(CustomEmojiShortcode(reactionContent: "cat") == nil)
        #expect(CustomEmojiShortcode(reactionContent: "::") == nil)
        #expect(CustomEmojiShortcode(reactionContent: "👍") == nil)
        #expect(CustomEmojiShortcode(reactionContent: " :cat:") == nil)
    }

    @Test func malformedTagsAreIgnored() {
        let tags = [
            F.tag("emoji", "party"),
            F.tag("emoji", "", partyURL),
            F.tag("emoji", "bad code", partyURL),
            F.tag("emoji", "blank", ""),
            F.tag("emoji", "spaced", " \(partyURL)"),
            F.tag("emoji", "long", "https://x.example/" + String(repeating: "a", count: 3000)),
            F.tag("emoji", "five", partyURL, "30030:pk:set", "extra"),
            F.tag("Emoji", "upper", partyURL),
            F.tag("e", String(repeating: "aa", count: 32)),
            F.tag("emoji", "set", partyURL, "30030:pk:set"),
        ]
        #expect(CustomEmojiTag.parse(tags).map(\.shortcode.name) == ["set"])
    }

    @Test func firstWellFormedTagWinsForDuplicateShortcodes() {
        let parsed = CustomEmojiTag.parse([
            F.tag("emoji", "party"),
            F.tag("emoji", "party", partyURL),
            F.tag("emoji", "party", catURL),
        ])
        #expect(parsed.count == 1)
        #expect(parsed.first?.url == partyURL)
    }

    // MARK: Tokenizing

    @Test func tokenizerFindsOnlyResolvableShortcodes() {
        let party = CustomEmojiShortcode("party")!
        let cat = CustomEmojiShortcode("cat")!
        #expect(CustomEmojiText.tokens(in: "hi :party: and :dog:", resolvable: [party]) == [
            .text("hi "), .emoji(party), .text(" and :dog:"),
        ])
        // An unresolvable candidate does not consume the colon of the next one.
        #expect(CustomEmojiText.tokens(in: "x:dog:cat:", resolvable: [cat]) == [.text("x:dog"), .emoji(cat)])
        #expect(CustomEmojiText.tokens(in: ":party::cat:", resolvable: [party, cat]) == [.emoji(party), .emoji(cat)])
        #expect(CustomEmojiText.tokens(in: "no emoji here", resolvable: [party]) == [.text("no emoji here")])
        #expect(CustomEmojiText.tokens(in: ":party:", resolvable: []) == [.text(":party:")])
        #expect(CustomEmojiText.shortcodes(in: "🎉:party:🎉 :party:", among: [party, cat]) == [party])
    }

    @Test func attributedSegmentsKeepSurroundingStyling() {
        let party = CustomEmojiShortcode("party")!
        var bold = AttributedString("Bold :party:")
        bold.inlinePresentationIntent = .stronglyEmphasized
        let segments = CustomEmojiText.segments(of: AttributedString("A ") + bold + AttributedString(" z"),
                                                resolvable: [party])
        #expect(segments.count == 3)
        guard case .text(let leading) = segments[0], case .emoji(let code, let original) = segments[1],
              case .text(let trailing) = segments[2] else {
            Issue.record("Unexpected segments \(segments)")
            return
        }
        #expect(String(leading.characters) == "A Bold ")
        #expect(code == party)
        #expect(String(original.characters) == ":party:")
        #expect(original.inlinePresentationIntent == .stronglyEmphasized)
        #expect(String(trailing.characters) == " z")
    }

    // MARK: Message matching

    @Test func matchedShortcodeRendersInlineAndLeavesTheGrid() {
        let photo = F.reference(url: "https://blossom.example.com/photo", sha: String(repeating: "c", count: 64))
        let items = F.attachments([
            .accepted(attachmentIndex: 0, reference: F.reference(url: partyURL)),
            .accepted(attachmentIndex: 1, reference: photo),
        ])
        let resolution = CustomEmojiResolver.resolve(text: "hi :party:",
            tags: [F.tag("emoji", "party", partyURL)], attachments: items)
        let party = CustomEmojiShortcode("party")!
        #expect(resolution.inline[party]?.id == items[0].id)
        #expect(resolution.inline[party]?.localTarget == AttachmentLocalTargetFfi(
            messageIdHex: F.messageID, sourceMessageIdHex: F.sourceID, attachmentIndex: 0))
        #expect(resolution.gridItems.map(\.id) == [items[1].id])
    }

    @Test func unmatchedShortcodesAndUnnamedAttachmentsStayLiteral() {
        let items = F.attachments([.accepted(attachmentIndex: 0, reference: F.reference(url: partyURL))])
        // No tag for the shortcode in the text.
        let untagged = CustomEmojiResolver.resolve(text: ":wave:", tags: [F.tag("emoji", "party", partyURL)], attachments: items)
        #expect(untagged.isEmpty)
        #expect(untagged.gridItems == items)
        // The tag names a URL that matches no attachment: never fetched, stays text.
        let orphan = CustomEmojiResolver.resolve(text: ":party:",
            tags: [F.tag("emoji", "party", "https://elsewhere.example/party.png")], attachments: items)
        #expect(orphan.isEmpty)
        #expect(orphan.gridItems == items)
        // A tag without any attachment on the row.
        #expect(CustomEmojiResolver.resolve(text: ":party:", tags: [F.tag("emoji", "party", partyURL)], attachments: []).isEmpty)
        // Malformed tag.
        #expect(CustomEmojiResolver.resolve(text: ":party:", tags: [F.tag("emoji", "party")], attachments: items).isEmpty)
        // Tagged attachment whose shortcode never appears stays in the grid.
        let unused = CustomEmojiResolver.resolve(text: "just a photo", tags: [F.tag("emoji", "party", partyURL)], attachments: items)
        #expect(unused.isEmpty)
        #expect(unused.gridItems == items)
    }

    @Test func duplicateShortcodeUsesFirstTagEvenWithoutAttachment() {
        let items = F.attachments([.accepted(attachmentIndex: 0, reference: F.reference(url: partyURL))])
        let resolution = CustomEmojiResolver.resolve(text: ":party:", tags: [
            F.tag("emoji", "party", "https://elsewhere.example/a.png"),
            F.tag("emoji", "party", partyURL),
        ], attachments: items)
        #expect(resolution.isEmpty)
        #expect(resolution.gridItems == items)
    }

    @Test func rejectedNonImageAndUnsafeAttachmentsNeverMatch() {
        let rejected = F.attachments([.rejected(attachmentIndex: 0,
            rejection: MediaAttachmentRejectionFfi(kind: .unsupportedFormat, detail: "bad"))])
        #expect(CustomEmojiResolver.resolve(text: ":party:", tags: [F.tag("emoji", "party", partyURL)],
                                            attachments: rejected).isEmpty)
        let video = F.attachments([.accepted(attachmentIndex: 0, reference: F.reference(url: partyURL, mediaType: "video/mp4"))])
        #expect(CustomEmojiResolver.resolve(text: ":party:", tags: [F.tag("emoji", "party", partyURL)],
                                            attachments: video).isEmpty)
        let svg = F.attachments([.accepted(attachmentIndex: 0, reference: F.reference(url: partyURL, mediaType: "image/svg+xml"))])
        #expect(CustomEmojiResolver.resolve(text: ":party:", tags: [F.tag("emoji", "party", partyURL)],
                                            attachments: svg).isEmpty)
        let unsafe = F.attachments([.accepted(attachmentIndex: 0, reference: F.reference(url: partyURL,
            extraLocators: [MediaLocatorFfi(kind: "blossom-v1", value: "http://127.0.0.1/party")]))])
        #expect(CustomEmojiResolver.resolve(text: ":party:", tags: [F.tag("emoji", "party", partyURL)],
                                            attachments: unsafe).isEmpty)
    }

    @Test func twoShortcodesNamingOneAttachmentRemoveItOnce() {
        let items = F.attachments([.accepted(attachmentIndex: 0, reference: F.reference(url: partyURL))])
        let resolution = CustomEmojiResolver.resolve(text: ":party: :fiesta:", tags: [
            F.tag("emoji", "party", partyURL), F.tag("emoji", "fiesta", partyURL),
        ], attachments: items)
        #expect(resolution.shortcodes == [CustomEmojiShortcode("party")!, CustomEmojiShortcode("fiesta")!])
        #expect(resolution.gridItems.isEmpty)
    }

    // MARK: Reactions

    @Test @MainActor func shortcodeOnlyInALinkDestinationKeepsItsAttachmentInTheGrid() throws {
        let items = F.attachments([.accepted(attachmentIndex: 0, reference: F.reference(url: partyURL))])
        let tags = [F.tag("emoji", "party", partyURL)]
        let candidates = CustomEmojiResolver.candidates(tags: tags, attachments: items)
        #expect(candidates.keys.map(\.name) == ["party"])
        // `[here](https://example.com/:party:)` renders only "here".
        let document = MarkdownDocumentFfi(blocks: [.paragraph(inlines: [
            .link(dest: "https://example.com/:party:", title: nil, children: [.text(content: "here")],
                  classification: .web),
        ])], truncated: false)
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(for: document))
        let runs = CustomEmojiDisplayText.runs(in: blocks)
        #expect(runs == ["here"])
        let resolution = CustomEmojiResolver.claim(candidates, attachments: items, displayedRuns: runs)
        #expect(resolution.isEmpty)
        #expect(resolution.gridItems == items)

        // The same shortcode in the link's visible text is claimed.
        let visible = MarkdownDocumentFfi(blocks: [.paragraph(inlines: [
            .link(dest: "https://example.com", title: nil, children: [.text(content: "go :party:")],
                  classification: .web),
        ])], truncated: false)
        let visibleRuns = CustomEmojiDisplayText.runs(in: try #require(MarkdownMessageBuilder.displayBlocks(for: visible)))
        let claimed = CustomEmojiResolver.claim(candidates, attachments: items, displayedRuns: visibleRuns)
        #expect(claimed.shortcodes.map(\.name) == ["party"])
        #expect(claimed.gridItems.isEmpty)
    }

    @Test @MainActor func displayRunsWalkNestedBlocksButNotHiddenContent() {
        let blocks: [MarkdownDisplayBlock] = [
            .heading(AttributedString("Title")),
            .blockQuote([.paragraph(AttributedString("quoted :a:"))]),
            .list(items: [MarkdownDisplayListItem(marker: .bullet, blocks: [.codeBlock(AttributedString("code :b:"))])],
                  tight: true),
            .thematicBreak,
        ]
        #expect(CustomEmojiDisplayText.runs(in: blocks) == ["Title", "quoted :a:", "code :b:"])
    }

    @Test func legacySummaryNamesTheEarliestActiveReaction() {
        let target = String(repeating: "aa", count: 32)
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: ":cat:", count: 2, senders: ["a", "b"])],
            userReactions: [
                TimelineUserReactionFfi(reactionMessageIdHex: "later", targetMessageIdHex: target, sender: "a", emoji: ":cat:", reactedAt: 20),
                TimelineUserReactionFfi(reactionMessageIdHex: "earliest", targetMessageIdHex: target, sender: "b", emoji: ":cat:", reactedAt: 10),
                TimelineUserReactionFfi(reactionMessageIdHex: "other", targetMessageIdHex: target, sender: "b", emoji: "👍", reactedAt: 1),
            ])
        let details = ConversationViewModel.reactionDetails(for: target, summary: summary, optimisticRemovals: [],
            optimisticRecords: [:], deletedMessageIds: [], me: "a")
        #expect(details.reactionMessageIdHex(for: ":cat:") == "earliest")
        #expect(details.tallies.first?.reactionMessageIdHex == "earliest")
    }

    // MARK: Catalog, scope, presentation

    @Test func catalogDeduplicatesAndSortsByShortcode() {
        let party = CustomEmojiShortcode("party")!
        let cat = CustomEmojiShortcode("cat")!
        let partyRef = F.reference(url: partyURL)
        let catRef = F.reference(url: catURL, sha: String(repeating: "e", count: 64))
        let messages = [
            CustomEmojiCatalogEntry(shortcode: party, reference: partyRef, source: .message(messageIdHex: "m1", attachmentIndex: 0)),
            CustomEmojiCatalogEntry(shortcode: party, reference: partyRef, source: .message(messageIdHex: "m2", attachmentIndex: 0)),
        ]
        let reactions = [
            CustomEmojiCatalogEntry(shortcode: cat, reference: catRef, source: .reaction(reactionMessageIdHex: "r1", attachmentIndex: 0)),
            CustomEmojiCatalogEntry(shortcode: party, reference: partyRef, source: .reaction(reactionMessageIdHex: "r2", attachmentIndex: 0)),
        ]
        let merged = CustomEmojiCatalog.merge(messages: messages, reactions: reactions)
        #expect(merged.map(\.shortcode.name) == ["cat", "party"])
        #expect(merged.last?.source == .message(messageIdHex: "m1", attachmentIndex: 0))

        let items = F.attachments([.accepted(attachmentIndex: 0, reference: partyRef)])
        let resolution = CustomEmojiResolver.resolve(text: ":party:", tags: [F.tag("emoji", "party", partyURL)], attachments: items)
        #expect(CustomEmojiCatalog.messageEntries(messageIdHex: F.messageID, resolution: resolution) == [
            CustomEmojiCatalogEntry(shortcode: party, reference: partyRef, source: .message(messageIdHex: F.messageID, attachmentIndex: 0)),
        ])
    }

    @Test func lateResultsFromAnotherScopeAreRejected() {
        let scope = CustomEmojiScope(accountRef: "alice", runtimeGeneration: 1, groupIdHex: "g1")
        let key = CustomEmojiImageKey(scope: scope, itemID: "msg:a:sha:3:0", pixelSize: 60)
        #expect(CustomEmojiImageKey.accepts(key, currentScope: scope))
        #expect(!CustomEmojiImageKey.accepts(key, currentScope: nil))
        #expect(!CustomEmojiImageKey.accepts(key, currentScope: CustomEmojiScope(accountRef: "bob", runtimeGeneration: 1, groupIdHex: "g1")))
        #expect(!CustomEmojiImageKey.accepts(key, currentScope: CustomEmojiScope(accountRef: "alice", runtimeGeneration: 2, groupIdHex: "g1")))
        #expect(!CustomEmojiImageKey.accepts(key, currentScope: CustomEmojiScope(accountRef: "alice", runtimeGeneration: 1, groupIdHex: "g2")))
    }

    @Test func spokenReactionUsesTheShortcodeName() {
        #expect(CustomEmojiShortcode.spokenReaction(":party_parrot:") == "party_parrot")
        #expect(CustomEmojiShortcode.spokenReaction("👍") == "👍")
    }

    @Test @MainActor func smallSourcesAreScaledToTheRequestedPointSize() {
        let tiny = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 8),
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in }
        let sized = ConversationCustomEmojiStore.sizedToPoints(tiny, pixelSize: 60, scale: 3)
        #expect(abs(sized.size.width - 20) < 0.01)
        #expect(abs(sized.size.height - 10) < 0.01)
        #expect(CustomEmojiInlineMetrics.pixelSize(pointSize: 20, scale: 3) == 60)
    }
}
