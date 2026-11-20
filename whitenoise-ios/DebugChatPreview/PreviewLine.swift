#if DEBUG
import Foundation
import MarmotKit

/// Authored examples carry the same typed sidecars as a retained conversation row.
nonisolated struct PreviewLine {
    enum Detail {
        case markdown([MarkdownBlockFfi]), mention, reply(Int), edited, reported, pending, failed, deleted, expires
        case missingReply, namedMentions([(String, String)])
        case reactionParticipants([(String, [String])])
        case reactions([String]), media([String]), rejectedMedia, sticker, poll(closed: Bool, type: PollTypeFfi = .singleChoice), malformedPoll
        case groupEvent(String, subject: String? = ChatPreviewThread.third), activity(replyingTo: Int)
    }

    let author: String
    let date: Date?
    let text: String
    let details: [Detail]

    init(_ text: String, _ details: Detail..., by author: String = ChatPreviewThread.peer, at date: Date? = nil) {
        self.author = author
        self.date = date
        self.text = text
        self.details = details
    }

    func apply(to message: inout ConversationMessageFfi, history: [ConversationMessageFfi], identities: [(String, String)]) {
        var row = message.timeline
        // A pasted CDN envelope keeps its wire text on the record, just like a real row.
        // The offline transcript shows the same label as its inbox and quoted previews.
        let displayText = RemoteGiphyMedia.envelopePreviewText(for: text) ?? text
        row.contentTokens = .init(blocks: [.paragraph(inlines: [.text(content: displayText)])],
                                  truncated: false, blankLinesBefore: Data([0]))
        for detail in details {
            switch detail {
            case let .markdown(blocks):
                row.contentTokens = .init(blocks: blocks, truncated: false, blankLinesBefore: Data(repeating: 0, count: blocks.count))
            case .mention:
                let entity = MarkdownNostrEntityFfi(hrp: .npub, bech32: Self.ownerNpub)
                row.plaintext = "nostr:\(entity.bech32) " + text
                row.contentTokens.blocks = [.paragraph(inlines: [.nostrMention(entity: entity), .text(content: " " + text)])]
                message.references.mentions = [ChatPreviewThread.owner]
            case let .namedMentions(people):
                var rest = text[...]
                var inlines: [MarkdownInlineFfi] = []
                var wire = ""
                for (name, key) in people {
                    guard let range = rest.range(of: "@" + name), let npub = NostrProfileReference.npub(fromAccountIdHex: key) else {
                        preconditionFailure("Invalid named mention in preview row")
                    }
                    let prefix = String(rest[..<range.lowerBound])
                    inlines += [.text(content: prefix), .nostrMention(entity: .init(hrp: .npub, bech32: npub))]
                    wire += prefix + "nostr:" + npub
                    rest = rest[range.upperBound...]
                }
                inlines.append(.text(content: String(rest)))
                row.plaintext = wire + rest
                row.contentTokens.blocks = [.paragraph(inlines: inlines)]
                message.references.mentions = people.map { $0.1 }
            case .missingReply:
                let missing = String(repeating: "fe", count: 32)
                row.replyToMessageIdHex = missing
                row.tags = ["e", "q"].map { .init(values: [$0, missing]) }
            case let .reply(index):
                let parent = history[index].timeline
                row.replyToMessageIdHex = parent.messageIdHex
                row.tags = ["e", "q"].map { .init(values: [$0, parent.messageIdHex]) }
                row.replyPreview = .init(messageIdHex: parent.messageIdHex, sender: parent.sender,
                    plaintext: parent.plaintext, contentTokens: parent.contentTokens, kind: parent.kind, sticker: parent.sticker,
                    mediaJson: parent.mediaJson, media: parent.media, agentTextStreamJson: nil,
                    deleted: parent.deleted, deletionSource: parent.deletionSource, invalidationStatus: nil)
                message.references.replyAuthor = parent.sender
            case .edited:
                row.edit = .init(editCount: 1, latestEditMessageIdHex: String(repeating: "ed", count: 32), editedAt: row.timelineAt + 10)
            case .reported: row.hasReports = true
            case .pending: row.sourceMessageIdHex = nil
            case .failed:
                row.sourceMessageIdHex = nil
                row.invalidationStatus = "local_publish_failed"
            case .deleted:
                row.deleted = true
                row.deletionSource = .author
                row.plaintext = ""
                row.contentTokens = .emptyDocument
            case .expires:
                row.retentionSeconds = 86_400
                row.retentionExpiresAt = row.timelineAt + 86_400
            case let .reactions(symbols):
                let participants = symbols.enumerated().map { index, emoji in
                    (emoji, index == 0 ? [ChatPreviewThread.owner, ChatPreviewThread.peer] : [ChatPreviewThread.peer])
                }
                Self.applyReactions(participants, to: &message, row: &row)
            case let .reactionParticipants(participants):
                Self.applyReactions(participants, to: &message, row: &row)
            case let .media(files):
                row.media = files.enumerated().map { index, name in
                    let ref = ChatPreviewMedia.reference(for: name)
                    return .accepted(attachmentIndex: UInt32(index), reference: ref)
                }
            case .rejectedMedia:
                row.media = [.rejected(attachmentIndex: 0, rejection: .init(kind: .unsupportedFormat, detail: ""))]
            case .sticker:
                row.sticker = ChatPreviewStickers.reference(from: author)
            case let .poll(closed, type):
                row.kind = MessageSemantics.kindPoll
                row.poll = .init(question: text, options: [
                    .init(id: "a", label: "Saturday morning", votes: closed || type == .multipleChoice ? 2 : 1), .init(id: "b", label: "Sunday afternoon", votes: 1)
                ], pollType: type, participants: closed ? 3 : 2, localSelection: closed ? ["a"] : [],
                    creator: author, endsAt: closed ? row.timelineAt : nil, open: !closed)
            case .malformedPoll: row.kind = MessageSemantics.kindPoll
            case let .groupEvent(systemType, subject):
                row.kind = MessageSemantics.kindGroupSystem
                row.groupSystem = .init(provenance: .authenticatedGroupState, actorDisplayName: identities.first { $0.0 == author }?.1, subjectDisplayName: identities.first { $0.0 == subject }?.1,
                    systemType: systemType, text: text, actorAccountIdHex: author, subjectAccountIdHex: subject,
                    name: nil, oldName: nil, oldRetentionSeconds: nil, newRetentionSeconds: systemType == "disappearing_timer_changed" ? 86_400 : nil)
            case let .activity(requestIndex):
                row.kind = MessageSemantics.kindAgentActivity
                let payload: [String: Any] = ["v": 1, "status": "thinking", "text": text]
                row.plaintext = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                row.tags = [.init(values: ["status", "thinking"]), .init(values: ["e", history[requestIndex].timeline.messageIdHex])]
            }
        }
        message.timeline = row
    }

    private static func applyReactions(_ participants: [(String, [String])], to message: inout ConversationMessageFfi,
                                       row: inout TimelineMessageRecordFfi) {
        let items = participants.map { emoji, senders in
            ConversationReactionFfi(emoji: emoji, count: UInt64(senders.count), reactors: senders,
                                    viewerReacted: senders.contains(ChatPreviewThread.owner), reactionMessageIdHex: nil)
        }
        message.references.reactions = .init(totalCount: items.reduce(0) { $0 + $1.count },
            totalKinds: UInt64(items.count), items: items, omittedKinds: 0)
        row.reactions.byEmoji = items.map { .init(emoji: $0.emoji, count: UInt32($0.count), senders: $0.reactors) }
    }

    // Canonical Bech32 encoding of the synthetic 0x11… account.
    static let ownerNpub = "npub1zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygse4sl3h"
}
#endif
