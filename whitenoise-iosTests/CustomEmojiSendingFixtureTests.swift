import CryptoKit
import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

/// Binding fixture for sending MDK 0.12.0 custom emoji: a peer's emoji puts
/// `:party:` in the chat's catalog, then a tagged kind-9 goes through the
/// real `sendTaggedMedia` of a live test runtime and is read back through the
/// conversation window and the rendering resolver. The peer row is synthetic, so its retained bytes and
/// the Blossom upload are simulated (the runtime is offline); the uploaded
/// reference is shaped like a real one for the group's epoch.
@MainActor
@Suite(.serialized)
struct CustomEmojiSendingFixtureTests {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func taggedMessageRoundTripsThroughTheRuntime() async throws {
        let client = try MarmotClient.testClient()
        try await client.startRuntime()
        let watchdog = MarmotFixtureWatchdog.start("Custom emoji send fixture exceeded its deadline", breaking: client)
        defer { watchdog.cancel() }
        do {
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Emoji send", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            func readSnapshot() async throws -> ConversationWindowSnapshotFfi {
                let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
                let snapshot = try #require(window.snapshot())
                await window.cancel()
                return snapshot
            }
            var snapshot = try await readSnapshot()
            let epoch = try await client.marmot.groupMlsState(accountRef: account.label, groupIdHex: group.groupIdHex).epoch
            let groupSubscription = try await client.subscribeGroupState(accountRef: account.label, groupIdHex: group.groupIdHex)
            let groupRecord = try #require(await client.groupStateSubscriptionSnapshot(groupSubscription))
            let state = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            state.activeAccountRef = account.label
            let model = ConversationViewModel(appState: state, group: groupRecord)

            // A peer's kind-9 with :party: gives this chat one sendable emoji.
            let payload = Data("party-emoji-png".utf8)
            let peerURL = "https://peer.example.com/party"
            var received = CustomEmojiFixtures.reference(url: peerURL, sha: Self.hex(payload))
            received.sourceEpoch = epoch
            let peer = String(repeating: "5e", count: 32)
            let peerMessageID = String(repeating: "9a", count: 32)
            var peerRow = TimelineMessageRecordFfi(messageIdHex: peerMessageID, sourceMessageIdHex: nil, direction: "received",
                groupIdHex: group.groupIdHex, sender: peer, plaintext: "look :party: :party-time:",
                contentTokens: .emptyDocument, kind: MessageSemantics.kindChat,
                tags: [MessageTagFfi(values: ["emoji", "party", peerURL]),
                       MessageTagFfi(values: ["emoji", "party-time", peerURL])],
                timelineAt: 1, receivedAt: 1, replyToMessageIdHex: nil, replyPreview: nil, mediaJson: nil,
                media: [], agentTextStreamJson: nil, groupSystem: nil,
                reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil, deleted: false,
                deletedByMessageIdHex: nil, invalidationStatus: nil)
            peerRow.media = [.accepted(attachmentIndex: 0, reference: received)]
            let peerMessage = ConversationMessageFfi(timeline: peerRow, references: ConversationMessageReferencesFfi(
                messageIdHex: peerMessageID, sender: peer, replyAuthor: nil, mentions: [], mentionsTruncated: false,
                replyMentions: [], replyMentionsTruncated: false, system: nil,
                reactions: ConversationReactionsFfi(totalCount: 0, totalKinds: 0, items: [], omittedKinds: 0)))
            snapshot.revision.sequence += 1
            snapshot.messages = [peerMessage] + snapshot.messages
            model.installConversationWindow(snapshot)

            let party = try #require(CustomEmojiShortcode("party"))
            // The hyphenated shortcode renders but is not NIP-30, so it is never offered.
            #expect(model.customEmojiSendables.map(\.shortcode) == [party])
            let emoji = model.customEmojiUsed(in: "yay :party: :party-time:")
            #expect(emoji.map(\.shortcode) == [party])

            var uploadCount = 0
            var uploadedURL = ""
            let version = groupRecord.encryptedMedia.version ?? .v2
            let sender = ConversationCustomEmojiSender(
                scopeProvider: { model.customEmojiSendScope },
                currentEpoch: { epoch },
                loadBytes: { item in
                    #expect(item.reference == received)
                    #expect(item.demand == .automatic)
                    return payload
                },
                upload: { _, request in
                    uploadCount += 1
                    let ciphertext = Self.hex(Data("cipher".utf8) + request.plaintext)
                    uploadedURL = "https://blossom.example.com/\(ciphertext)"
                    return MediaAttachmentReferenceFfi(
                        locators: [MediaLocatorFfi(kind: "blossom-v1", value: uploadedURL)],
                        ciphertextSha256: ciphertext, plaintextSha256: Self.hex(request.plaintext),
                        nonceHex: String(repeating: "3", count: 24), fileName: request.fileName,
                        mediaType: request.mediaType, version: version, sourceEpoch: epoch,
                        dim: request.dim, thumbhash: request.thumbhash)
                },
                sendMessage: { scope, caption, attachments, tags in
                    _ = try await client.sendTaggedMedia(accountRef: scope.accountRef, groupIdHex: scope.groupIdHex,
                                                         attachments: attachments, caption: caption, tags: tags)
                }
            )

            try await sender.sendMessage(text: "yay :party: :party-time:", replyTargetId: nil, emoji: emoji)
            #expect(uploadCount == 1)

            // MDK stored a kind-9 carrying the caption, the emoji tag naming our
            // upload, and that upload as an attachment; the resolver draws it
            // inline and leaves nothing for the media grid.
            var readBack = try await readSnapshot()
            let sent = try #require(readBack.messages.first {
                $0.timeline.direction == "sent" && $0.timeline.kind == MessageSemantics.kindChat
            }).timeline
            #expect(sent.plaintext == "yay :party: :party-time:")
            #expect(sent.tags.contains(MessageTagFfi(values: ["emoji", "party", uploadedURL])))
            #expect(!sent.tags.contains { $0.values.first == "emoji" && $0.values.dropFirst().first == "party-time" })
            let attachments = MessageMediaAttachment.displayItems(fromOutcomes: sent.media, ownerId: "msg:\(sent.messageIdHex)",
                messageId: sent.messageIdHex, sourceMessageId: sent.sourceMessageIdHex)
            let resolution = CustomEmojiResolver.resolve(text: sent.plaintext, tags: sent.tags, attachments: attachments)
            #expect(resolution.shortcodes == [party])
            #expect(resolution.inline[party]?.reference?.locators.first?.value == uploadedURL)
            #expect(resolution.gridItems.isEmpty)

            // A second message reuses the uploaded reference: no second upload.
            try await sender.sendMessage(text: "again :party:", replyTargetId: nil, emoji: emoji)
            #expect(uploadCount == 1)
            readBack = try await readSnapshot()
            #expect(readBack.messages.filter {
                $0.timeline.tags.contains(MessageTagFfi(values: ["emoji", "party", uploadedURL]))
            }.count == 2)

            // The view model renders it through the #1136 path.
            readBack.revision.sequence = snapshot.revision.sequence + 1
            readBack.messages = [peerMessage] + readBack.messages
            model.installConversationWindow(readBack)
            let item = try #require(model.timeline.first { item in
                if case .message(let record, _) = item.kind { return record.messageIdHex == sent.messageIdHex }
                return false
            })
            #expect(model.customEmoji(for: item).shortcodes == [party])
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
}
