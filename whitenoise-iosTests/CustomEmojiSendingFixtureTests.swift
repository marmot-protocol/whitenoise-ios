import CryptoKit
import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

/// Captures the existing sender boundary and projects its output into the real
/// conversation view model, fed from fixture snapshots. MDK storage and relay
/// delivery are not part of this unit test.
@MainActor
struct CustomEmojiSendingFixtureTests {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func taggedMessageReachesSendBoundaryAndRenders() async throws {
        let accountRef = "emoji-send-account"
        let accountIdHex = String(repeating: "1f", count: 32)
        let epoch: UInt64 = 1
        let groupRecord = group(name: "Emoji send")
        var snapshot = conversationWindowSnapshot(groupIdHex: groupRecord.groupIdHex, title: "Emoji send", epoch: epoch)
        let state = AppState.test()
        state.activeAccountRef = accountRef
        let model = ConversationViewModel(appState: state, group: groupRecord)

        // A peer's kind-9 with :party: gives this chat one sendable emoji.
        let payload = Data("party-emoji-png".utf8)
        let peerURL = "https://peer.example.com/party"
        var received = CustomEmojiFixtures.reference(url: peerURL, sha: Self.sha256Hex(payload))
        received.sourceEpoch = epoch
        let peer = String(repeating: "5e", count: 32)
        let peerMessageID = String(repeating: "9a", count: 32)
        var peerRow = timelineRecord(messageIdHex: peerMessageID, sourceMessageIdHex: .absent,
            groupIdHex: groupRecord.groupIdHex, sender: peer, plaintext: "look :party: :celebrate: :party-time:",
            tags: [MessageTagFfi(values: ["emoji", "party", peerURL]),
                   MessageTagFfi(values: ["emoji", "celebrate", peerURL]),
                   MessageTagFfi(values: ["emoji", "party-time", peerURL])],
            timelineAt: 1)
        peerRow.media = [.accepted(attachmentIndex: 0, reference: received)]
        let peerMessage = conversationMessage(peerRow)
        snapshot.revision.sequence += 1
        snapshot.messages = [peerMessage]
        model.installConversationWindow(snapshot)

        let party = try #require(CustomEmojiShortcode("party"))
        let celebrate = try #require(CustomEmojiShortcode("celebrate"))
        // :celebrate: is an alias of the same image. The hyphenated
        // shortcode renders but is not NIP-30, so it is never offered.
        #expect(Set(model.customEmojiSendables.map(\.shortcode)) == [party, celebrate])
        let emoji = model.customEmojiUsed(in: "yay :party: :celebrate: :party-time:")
        #expect(emoji.map(\.shortcode) == [party, celebrate])

        var submissions: [(scope: CustomEmojiScope, caption: String, attachments: [MediaAttachmentReferenceFfi], tags: [[String]])] = []
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
                let ciphertext = Self.sha256Hex(Data("cipher".utf8) + request.plaintext)
                uploadedURL = "https://blossom.example.com/\(ciphertext)"
                return MediaAttachmentReferenceFfi(
                    locators: [MediaLocatorFfi(kind: "blossom-v1", value: uploadedURL)],
                    ciphertextSha256: ciphertext, plaintextSha256: Self.sha256Hex(request.plaintext),
                    nonceHex: String(repeating: "3", count: 24), fileName: request.fileName,
                    mediaType: request.mediaType, version: version, sourceEpoch: epoch,
                    dim: request.dim, thumbhash: request.thumbhash)
            },
            sendMessage: { scope, caption, attachments, tags in
                submissions.append((scope, caption, attachments, tags))
            }
        )

        try await sender.sendMessage(text: "yay :party: :celebrate: :party-time:", replyTargetId: nil, emoji: emoji)
        #expect(uploadCount == 1)

        let first = try #require(submissions.first)
        #expect(submissions.count == 1)
        #expect(first.scope == model.customEmojiSendScope)
        #expect(first.caption == "yay :party: :celebrate: :party-time:")
        #expect(first.tags.contains(["emoji", "party", uploadedURL]))
        #expect(first.tags.contains(["emoji", "celebrate", uploadedURL]))
        #expect(!first.tags.contains { $0.first == "emoji" && $0.dropFirst().first == "party-time" })
        #expect(first.attachments.count == 1)
        #expect(first.attachments.first?.locators.first?.value == uploadedURL)

        // Install a synthetic sent row from the captured payload. This checks
        // presentation, not MDK storage or relay acceptance.
        var sent = peerRow
        sent.messageIdHex = String(repeating: "ab", count: 32)
        sent.sender = accountIdHex
        sent.direction = "sent"
        sent.plaintext = first.caption
        sent.tags = first.tags.map { MessageTagFfi(values: $0) }
        sent.media = first.attachments.enumerated().map { .accepted(attachmentIndex: UInt32($0.offset), reference: $0.element) }
        let attachments = MessageMediaAttachment.displayItems(fromOutcomes: sent.media, ownerId: "msg:\(sent.messageIdHex)",
            messageId: sent.messageIdHex, sourceMessageId: sent.sourceMessageIdHex)
        let resolution = CustomEmojiResolver.resolve(text: sent.plaintext, tags: sent.tags, attachments: attachments)
        #expect(resolution.shortcodes == [party, celebrate])
        #expect(resolution.inline[party]?.reference?.locators.first?.value == uploadedURL)
        #expect(resolution.gridItems.isEmpty)

        // A second message reuses the uploaded reference: no second upload.
        try await sender.sendMessage(text: "again :party:", replyTargetId: nil, emoji: [emoji[0]])
        #expect(uploadCount == 1)
        #expect(submissions.count == 2)
        let second = try #require(submissions.last)
        #expect(second.caption == "again :party:")
        #expect(second.attachments == first.attachments)
        #expect(second.tags == [["emoji", "party", uploadedURL]])

        snapshot.revision.sequence += 1
        snapshot.messages = [peerMessage, conversationMessage(sent)]
        model.installConversationWindow(snapshot)
        let item = try #require(model.timeline.first { item in
            if case .message(let record, _) = item.kind { return record.messageIdHex == sent.messageIdHex }
            return false
        })
        #expect(model.customEmoji(for: item).shortcodes == [party, celebrate])
        #expect(model.mediaItems(for: item).isEmpty)
    }
}
