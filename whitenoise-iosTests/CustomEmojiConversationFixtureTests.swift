import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

/// Binding fixture for MDK 0.12.0 custom emoji: a peer's tagged kind-9 row and
/// a `:shortcode:` reaction installed through the real conversation-window path
/// of a live test runtime.
@MainActor
@Suite(.serialized)
struct CustomEmojiConversationFixtureTests {
    @Test func taggedRowAndShortcodeReactionProjectThroughTheConversationWindow() async throws {
        let client = try MarmotClient.testClient()
        try await client.startRuntime()
        let watchdog = MarmotFixtureWatchdog.start("Custom emoji fixture exceeded its deadline", breaking: client)
        defer { watchdog.cancel() }
        do {
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Emoji", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
            var snapshot = try #require(window.snapshot())
            await window.cancel()
            let groupSubscription = try await client.subscribeGroupState(accountRef: account.label, groupIdHex: group.groupIdHex)
            let groupRecord = try #require(await client.groupStateSubscriptionSnapshot(groupSubscription))
            let state = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            state.activeAccountRef = account.label
            let model = ConversationViewModel(appState: state, group: groupRecord)

            let peer = String(repeating: "5e", count: 32)
            let messageID = String(repeating: "9a", count: 32)
            let sourceID = String(repeating: "9b", count: 32)
            let reactionID = String(repeating: "7c", count: 32)
            let partyURL = "https://blossom.example.com/party"
            let party = CustomEmojiFixtures.reference(url: partyURL)
            let photo = CustomEmojiFixtures.reference(url: "https://blossom.example.com/photo",
                                                      sha: String(repeating: "c", count: 64))
            var row = TimelineMessageRecordFfi(messageIdHex: messageID, sourceMessageIdHex: sourceID, direction: "received",
                groupIdHex: group.groupIdHex, sender: peer, plaintext: "hi :party: :nope:",
                contentTokens: .emptyDocument, kind: MessageSemantics.kindChat,
                tags: [MessageTagFfi(values: ["emoji", "party", partyURL]),
                       MessageTagFfi(values: ["emoji", "nope", "https://elsewhere.example/nope.png"])],
                timelineAt: 10, receivedAt: 10, replyToMessageIdHex: nil, replyPreview: nil, mediaJson: nil,
                media: [], agentTextStreamJson: nil, groupSystem: nil,
                reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil, deleted: false,
                deletedByMessageIdHex: nil, invalidationStatus: nil)
            row.media = [.accepted(attachmentIndex: 0, reference: party), .accepted(attachmentIndex: 1, reference: photo)]
            let reactions = ConversationReactionsFfi(totalCount: 2, totalKinds: 2, items: [
                ConversationReactionFfi(emoji: ":cat:", count: 1, reactors: [peer], viewerReacted: false,
                                        reactionMessageIdHex: reactionID),
                ConversationReactionFfi(emoji: "👍", count: 1, reactors: [peer], viewerReacted: false,
                                        reactionMessageIdHex: String(repeating: "7d", count: 32)),
            ], omittedKinds: 0)
            func install(_ record: TimelineMessageRecordFfi) {
                snapshot.revision.sequence += 1
                snapshot.messages = [ConversationMessageFfi(timeline: record, references: ConversationMessageReferencesFfi(
                    messageIdHex: record.messageIdHex, sender: record.sender, replyAuthor: nil, mentions: [],
                    mentionsTruncated: false, replyMentions: [], replyMentionsTruncated: false, system: nil,
                    reactions: reactions))]
                model.installConversationWindow(snapshot)
            }

            install(row)
            let item = try #require(model.timeline.first { $0.id == "msg:\(messageID)" })
            let resolution = model.customEmoji(for: item)
            let partyCode = try #require(CustomEmojiShortcode("party"))
            #expect(resolution.shortcodes == [partyCode])
            #expect(resolution.inline[partyCode]?.localTarget == AttachmentLocalTargetFfi(
                messageIdHex: messageID, sourceMessageIdHex: sourceID, attachmentIndex: 0))
            // The emoji renders inline only; the photo keeps its grid tile.
            #expect(model.mediaItems(for: item).map(\.reference?.plaintextSha256) == [photo.plaintextSha256])
            #expect(model.customEmojiCatalog.map(\.shortcode.name) == ["party"])

            let tallies = model.reactions(for: messageID)
            #expect(tallies.first { $0.emoji == ":cat:" }?.reactionMessageIdHex == reactionID)
            #expect(model.reactionDetails(for: messageID).reactionMessageIdHex(for: ":cat:") == reactionID)

            // Reaction images stay text (MDK 0.12.0 exposes no kind-7 slot), but the
            // reaction id is carried for a later MDK release.
            #expect(model.customEmojiScope?.groupIdHex == group.groupIdHex)

            // Reprojection without the shortcode returns the attachment to the grid.
            row.plaintext = "hi"
            install(row)
            let updated = try #require(model.timeline.first { $0.id == "msg:\(messageID)" })
            #expect(model.customEmoji(for: updated).isEmpty)
            #expect(model.mediaItems(for: updated).count == 2)
            #expect(model.customEmojiCatalog.isEmpty)

            // A shortcode only in a rendered link's destination is not displayed,
            // so its attachment stays in the grid instead of vanishing.
            row.plaintext = "[here](https://example.com/:party:)"
            row.contentTokens = MarkdownDocumentFfi(blocks: [.paragraph(inlines: [
                .link(dest: "https://example.com/:party:", title: nil, children: [.text(content: "here")],
                      classification: .web),
            ])], truncated: false)
            install(row)
            let linked = try #require(model.timeline.first { $0.id == "msg:\(messageID)" })
            #expect(model.markdownDisplayBlocks(for: linked) != nil)
            #expect(model.customEmoji(for: linked).isEmpty)
            #expect(model.mediaItems(for: linked).count == 2)

            // Switching away from the conversation's account drops the scope:
            // nothing loads or renders for another account.
            state.activeAccountRef = "another-account"
            #expect(model.customEmojiScope == nil)
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
}
