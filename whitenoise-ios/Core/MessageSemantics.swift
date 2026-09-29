import Foundation
import MarmotKit

/// Interprets a Marmot inner app event's `kind` + `tags` into the small set of
/// semantic shapes the UI cares about.
///
/// Inner MLS messages are unsigned Nostr events: the FFI record carries the
/// Nostr `kind` (9 chat, 7 reaction, 5 delete, 1009 edit, 1068 poll, 1200 stream-start) and the raw
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
    static let kindPoll: UInt64 = 1068
    static let kindAgentStreamStart: UInt64 = 1200
    static let kindAgentActivity: UInt64 = 1201
    static let kindAgentOperation: UInt64 = 1202
    static let kindGroupSystem: UInt64 = 1210

    // Tag names. `e`/`q` are standard Nostr reference tags; the `stream-*` /
    // `imeta` sets are owned by their respective features.
    static let eventRefTag = "e"
    static let quoteRefTag = "q"
    static let imetaTag = "imeta"
    static let streamTag = "stream"
    static let streamTypeTag = "stream-type"
    static let streamFinalKindTag = "final-kind"
    static let streamHashTag = "stream-hash"
    static let streamStartTag = "stream-start"
    static let streamChunksTag = "stream-chunks"
    static let streamRouteTag = "route"
    static let streamBrokerTag = "broker"
    static let streamTypeText = "text"
    static let streamFinalKindChat = "9"
    static let streamRouteQuic = "quic"

    /// The semantic classification of a message record.
    enum Kind: Equatable {
        /// A plain kind-9 chat bubble.
        case chat
        /// A kind-9 reply: `e` + `q` tags point at the parent. Body is plaintext.
        case reply(targetMessageId: String)
        /// A kind-9 media message described by one or more ordered `imeta` tags.
        case media([MediaAttachmentReferenceFfi])
        /// A kind-9 agent-stream final: carries a `stream` tag. The body
        /// (plaintext) is the full transcript; it replaces the live preview
        /// keyed by `streamId`.
        case streamFinal(streamId: String)
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
        /// A kind-1200 agent-stream start (opens the live QUIC preview).
        case agentStreamStart(StreamStart)
        /// Durable agent activity/status chrome; not a chat bubble.
        case agentActivity
        /// Durable agent operation chrome; not a chat bubble.
        case agentOperation
        /// Durable group-system chrome; not a chat bubble.
        case groupSystem
        /// Anything we don't render as a bubble or index.
        case unknown
    }

    /// A kind-1200 agent-stream start projected from its tags.
    struct StreamStart: Equatable {
        var streamId: String
        var route: String
        var brokers: [String]
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
        case kindAgentStreamStart:
            guard let start = streamStart(from: tags) else { return .unknown }
            return .agentStreamStart(start)
        case kindAgentActivity:
            return .agentActivity
        case kindAgentOperation:
            return .agentOperation
        case kindGroupSystem:
            return .groupSystem
        case kindPoll:
            return .poll
        case kindChat:
            // Order matters: a stream-final is a kind-9 with a `stream` tag; a
            // reply has both `e` and `q`; media has an `imeta` tag.
            if let streamId = streamFinalId(from: tags) {
                return .streamFinal(streamId: streamId)
            }
            if hasTag(imetaTag, in: tags) {
                guard let media = mediaAttachments(from: tags) else { return .chat }
                return .media(media)
            }
            if hasTag(quoteRefTag, in: tags), let target = firstValue(of: eventRefTag, in: tags) {
                return .reply(targetMessageId: target)
            }
            return .chat
        default:
            return .unknown
        }
    }

    static func classify(_ record: AppMessageRecordFfi) -> Kind {
        classify(kind: record.kind, tags: record.tags)
    }

    static func classify(_ message: ReceivedMessageFfi) -> Kind {
        classify(kind: message.kind, tags: message.tags)
    }

    /// Kinds a person sends as their own conversation message: chat and polls.
    static func isUserMessageKind(_ kind: UInt64) -> Bool {
        kind == kindChat || kind == kindPoll
    }

    static func isTypedAgentEventKind(_ kind: UInt64) -> Bool {
        kind == kindAgentActivity
            || kind == kindAgentOperation
            || kind == kindGroupSystem
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

    /// The `stream` id if this kind-9 is a complete stream-final. The current
    /// text-stream profile requires `stream`, `stream-start`, `stream-hash`,
    /// and `stream-chunks`; partial stream-ish tags are just normal chat text.
    private static func streamFinalId(from tags: [MessageTagFfi]) -> String? {
        guard let streamId = normalizedStreamId(firstValue(of: streamTag, in: tags)),
              Hex.normalized32Bytes(firstValue(of: streamStartTag, in: tags)) != nil,
              Hex.normalized32Bytes(firstValue(of: streamHashTag, in: tags)) != nil,
              validUnsignedDecimal(firstValue(of: streamChunksTag, in: tags))
        else { return nil }
        return streamId
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

    private static func streamStart(from tags: [MessageTagFfi]) -> StreamStart? {
        guard let streamId = normalizedStreamId(firstValue(of: streamTag, in: tags)),
              firstValue(of: streamTypeTag, in: tags) == streamTypeText,
              firstValue(of: streamFinalKindTag, in: tags) == streamFinalKindChat
        else { return nil }
        guard let route = firstValue(of: streamRouteTag, in: tags)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return nil }
        guard route == streamRouteQuic else { return nil }
        let brokers = allValues(of: streamBrokerTag, in: tags)
        return StreamStart(streamId: streamId, route: route, brokers: brokers)
    }

    static func normalizedStreamId(_ raw: String?) -> String? {
        Hex.normalized32Bytes(raw)
    }

    private static func validUnsignedDecimal(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.allSatisfy(isAsciiDigit)
        else { return false }
        return UInt64(value) != nil
    }

    private static func isAsciiDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }
}
