import Foundation
import MarmotKit

/// Interprets a Marmot inner app event's `kind` + `tags` into the small set of
/// semantic shapes the UI cares about.
///
/// Inner MLS messages are unsigned Nostr events: the FFI record carries the
/// Nostr `kind` (9 chat, 7 reaction, 5 delete, 1009 edit, 1068 poll) and the raw
/// `tags`. Host apps branch on those instead of a fixed payload enum — this
/// type is that branch, kept in one place so the timeline, chat-list preview,
/// and bubble all classify a record identically.
///
/// The kind/tag names mirror `crates/traits/src/app_event.rs`.
nonisolated enum MessageSemantics {

    // Nostr kinds used as Marmot inner app events.
    static let kindDelete: UInt64 = 5
    static let kindReaction: UInt64 = 7
    static let kindChat: UInt64 = 9
    static let kindEdit: UInt64 = 1009
    /// A NIP-22 comment, as other clients send thread replies.
    static let kindComment: UInt64 = 1111
    static let kindPoll: UInt64 = 1068
    static let kindAgentActivity: UInt64 = 1201
    static let kindAgentOperation: UInt64 = 1202
    static let kindGroupSystem: UInt64 = 1210

    // Tag names. `e`/`q` are standard Nostr reference tags; `imeta` describes
    // encrypted media.
    static let eventRefTag = "e"
    static let quoteRefTag = "q"
    static let imetaTag = "imeta"

    /// The semantic classification of a message record.
    enum Kind: Equatable {
        /// A plain kind-9 chat bubble.
        case chat
        /// A kind-9 reply: `e` + `q` tags point at the parent. Body is plaintext.
        case reply(targetMessageId: String)
        /// A kind-9 media message described by one or more ordered `imeta` tags.
        case media([MediaAttachmentReferenceFfi])
        /// A kind-7 reaction. Emoji lives in `content` (plaintext); empty
        /// content means an un-react (delete of the reaction event).
        case reaction(targetMessageId: String)
        /// A kind-5 delete tombstoning the `e`-tag target.
        case delete(targetMessageId: String)
        /// A kind-1009 replacement body for the `e`-tag target.
        case edit(targetMessageId: String)
        /// A kind-1068 poll. MDK validates it and projects the tally onto the
        /// timeline row; the question is the plaintext.
        case poll
        /// A durable progress update from an agent.
        case agentActivity
        /// Durable agent operation chrome; not a chat bubble.
        case agentOperation
        /// Durable group-system chrome; not a chat bubble.
        case groupSystem
        /// An event of a kind this app doesn't know, such as another client's
        /// app-defined kind. Shown as a card so the reader knows something arrived.
        case unsupportedEvent
        /// A known kind whose tags are malformed; never rendered as a bubble.
        case unknown
    }

    /// Classify a record by branching on its `kind` and reading `tags`.
    static func classify(kind: UInt64, tags: [MessageTagFfi]) -> Kind {
        switch kind {
        case kindReaction:
            guard let target = firstValue(of: eventRefTag, in: tags) else { return .unknown }
            return .reaction(targetMessageId: target)
        case kindDelete:
            guard let target = firstValue(of: eventRefTag, in: tags) else { return .unknown }
            return .delete(targetMessageId: target)
        case kindEdit:
            guard let target = firstValue(of: eventRefTag, in: tags) else { return .unknown }
            return .edit(targetMessageId: target)
        case kindAgentActivity:
            return .agentActivity
        case kindAgentOperation:
            return .agentOperation
        case kindGroupSystem:
            return .groupSystem
        case kindPoll:
            return .poll
        case kindChat:
            // Order matters: media has an `imeta` tag; a reply has both `e`
            // and `q`.
            if hasTag(imetaTag, in: tags) {
                guard let media = mediaAttachments(from: tags) else { return .chat }
                return .media(media)
            }
            if hasTag(quoteRefTag, in: tags), let target = firstValue(of: eventRefTag, in: tags) {
                return .reply(targetMessageId: target)
            }
            return .chat
        case kindComment:
            // This app has no thread view: a thread message shows inline as a
            // reply to its parent, as MDK projects it. A comment without a
            // parent reads like chat; a kind 1111 that isn't a comment is
            // another app's kind.
            guard isNIP22Comment(tags) else { return .unsupportedEvent }
            if hasTag(imetaTag, in: tags), let media = mediaAttachments(from: tags) {
                return .media(media)
            }
            if let parent = threadParent(in: tags) {
                return .reply(targetMessageId: parent)
            }
            return .chat
        default:
            return .unsupportedEvent
        }
    }

    /// MDK's test for a NIP-22 comment: a lowercase `e` tag, or a `k` tag
    /// naming a numeric kind (White Noise Linux sent thread messages without
    /// `k` until 2026-11-17).
    private static func isNIP22Comment(_ tags: [MessageTagFfi]) -> Bool {
        hasTag(eventRefTag, in: tags) || allValues(of: "k", in: tags).contains { value in
            !value.isEmpty && value.utf8.allSatisfy(isAsciiDigit) && UInt64(value) != nil
        }
    }

    /// The parent a thread message answers: the value of its first lowercase
    /// `e`, which MDK takes as authoritative even when it has no value.
    private static func threadParent(in tags: [MessageTagFfi]) -> String? {
        guard let first = tags.first(where: { $0.values.first == eventRefTag }),
              first.values.count > 1, !first.values[1].isEmpty else { return nil }
        return first.values[1]
    }

    static func classify(_ record: AppMessageRecordFfi) -> Kind {
        classify(kind: record.kind, tags: record.tags)
    }

    static func classify(_ message: ReceivedMessageFfi) -> Kind {
        classify(kind: message.kind, tags: message.tags)
    }

    /// A kind this app has no rendering for at all, such as another client's app-defined kind.
    /// Previews carry no tags: the chat list shows only chat activity, so a
    /// kind 1111 there is a thread message, and a quote decides from MDK's
    /// `thread` (`TimelineStore.replyPreview`).
    static func isUnsupportedEventKind(_ kind: UInt64) -> Bool {
        kind != kindComment && classify(kind: kind, tags: []) == .unsupportedEvent
    }

    /// What MDK counts as chat activity a person sends: chat, polls and
    /// thread messages (a kind 1111 with a parent). Only these move the
    /// unread count and can carry the read marker.
    static func isChatActivity(kind: UInt64, tags: [MessageTagFfi]) -> Bool {
        kind == kindChat || kind == kindPoll || (kind == kindComment && threadParent(in: tags) != nil)
    }

    static func isChatActivity(_ record: AppMessageRecordFfi) -> Bool {
        isChatActivity(kind: record.kind, tags: record.tags)
    }

    static func isTypedAgentEventKind(_ kind: UInt64) -> Bool {
        kind == kindAgentActivity
            || kind == kindAgentOperation
            || kind == kindGroupSystem
    }

    /// True for an agent's in-progress commentary remark (`["phase", "commentary"]`)
    /// carried on a kind-9 or kind-1111 message. Rendered quieter and never alerts.
    static func isAgentCommentary(tags: [MessageTagFfi]) -> Bool {
        firstValue(of: "phase", in: tags) == "commentary"
    }

    static func agentSettlesEventIds(in tags: [MessageTagFfi]) -> [String] {
        allValues(of: "settles", in: tags).filter { !$0.isEmpty }
    }

    static func agentSubagentTaskId(in tags: [MessageTagFfi]) -> String? {
        guard let value = firstValue(of: "subagent", in: tags), !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Tag helpers

    /// First value following a named tag (`tag.values[0] == name` → `tag.values[1]`).
    static func firstValue(of name: String, in tags: [MessageTagFfi]) -> String? {
        for tag in tags where tag.values.first == name {
            if tag.values.count > 1 { return tag.values[1] }
        }
        return nil
    }

    static func hasTag(_ name: String, in tags: [MessageTagFfi]) -> Bool {
        tags.contains { $0.values.first == name }
    }

    static func allValues(of name: String, in tags: [MessageTagFfi]) -> [String] {
        tags.compactMap { tag in
            guard tag.values.first == name, tag.values.count > 1 else { return nil }
            return tag.values[1]
        }
    }

    static func supportsEncryptedMediaVersion(_ version: EncryptedMediaVersionFfi?) -> Bool {
        version == .v1 || version == .v2
    }

    /// Parse all supported encrypted-media `imeta` tags, preserving tag order.
    ///
    /// `sourceEpoch` is not encoded in the public `imeta` fields; Marmot carries
    /// it as record metadata and now projects resolved timeline-row media with
    /// the real epoch. Conversation display/download paths should mirror that row
    /// projection. This parser is retained only for local optimistic or legacy
    /// compatibility records that have no captured row projection yet.
    static func mediaAttachments(
        from tags: [MessageTagFfi],
        sourceEpoch: UInt64 = 0
    ) -> [MediaAttachmentReferenceFfi]? {
        let imetaTags = tags.lazy
            .filter { $0.values.first == imetaTag }
            .prefix(maxImetaTags)
        var foundImeta = false

        var attachments: [MediaAttachmentReferenceFfi] = []
        for tag in imetaTags {
            foundImeta = true
            if let attachment = try? parseMediaImetaTag(
                tag: tag,
                sourceEpoch: sourceEpoch
            ), let safeAttachment = displaySafeMediaAttachment(attachment) {
                attachments.append(safeAttachment)
            }
        }
        guard foundImeta, !attachments.isEmpty else { return nil }
        return attachments
    }

    static func imetaTag(for reference: MediaAttachmentReferenceFfi) -> MessageTagFfi {
        var values = [imetaTag, "v \(reference.version.wireValue)"]
        values.append(contentsOf: reference.locators.map { "locator \($0.kind) \($0.value)" })
        values.append("ciphertext_sha256 \(reference.ciphertextSha256)")
        values.append("plaintext_sha256 \(reference.plaintextSha256)")
        values.append("nonce \(reference.nonceHex)")
        values.append("m \(reference.mediaType)")
        values.append("filename \(reference.fileName)")
        if let dim = reference.dim, !dim.isEmpty {
            values.append("dim \(dim)")
        }
        if let thumbhash = reference.thumbhash, !thumbhash.isEmpty {
            values.append("thumbhash \(thumbhash)")
        }
        return MessageTagFfi(values: values)
    }

    /// Keep UI-only bounds separate from MDK's protocol parser. The attachment
    /// fields that feed media cryptography remain byte-for-byte unchanged.
    private static func displaySafeMediaAttachment(
        _ reference: MediaAttachmentReferenceFfi
    ) -> MediaAttachmentReferenceFfi? {
        guard reference.fileName.utf8.count <= maxImetaFileNameBytes,
              reference.mediaType.utf8.count <= maxImetaMediaTypeBytes
        else { return nil }

        let dim = reference.dim?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbhash = reference.thumbhash?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaAttachmentReferenceFfi(
            locators: reference.locators,
            ciphertextSha256: reference.ciphertextSha256,
            plaintextSha256: reference.plaintextSha256,
            nonceHex: reference.nonceHex,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            version: reference.version,
            sourceEpoch: reference.sourceEpoch,
            dim: dim.flatMap { isValidMediaDim($0) ? $0 : nil },
            thumbhash: thumbhash.flatMap { isValidMediaThumbhash($0) ? $0 : nil }
        )
    }

    private static func isValidMediaDim(_ raw: String) -> Bool {
        let parts = raw.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { component in
            let bytes = component.utf8
            guard (1...6).contains(bytes.count),
                  let first = bytes.first,
                  (0x31...0x39).contains(first)
            else { return false }
            return bytes.dropFirst().allSatisfy(isAsciiDigit)
        }
    }

    private static func isValidMediaThumbhash(_ raw: String) -> Bool {
        let bytes = raw.utf8
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                 0x2B, 0x2D, 0x2F, 0x3D, 0x5F:
                return true
            default:
                return false
            }
        }
    }

    static let maxImetaFileNameBytes = 255
    static let maxImetaMediaTypeBytes = 127
    static let maxImetaTags = MediaDraftProcessor.maxAttachmentCount + 2

    private static func isAsciiDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }
}
