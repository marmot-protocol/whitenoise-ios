import Foundation
import MarmotKit

/// Interprets a Marmot inner app event's `kind` + `tags` into the small set of
/// semantic shapes the UI cares about.
///
/// Inner MLS messages are unsigned Nostr events: the FFI record carries the
/// Nostr `kind` (9 chat, 7 reaction, 5 delete, 1200 stream-start) and the raw
/// `tags`. Host apps branch on those instead of a fixed payload enum — this
/// type is that branch, kept in one place so the timeline, chat-list preview,
/// and bubble all classify a record identically.
///
/// The kind/tag names mirror `crates/traits/src/app_event.rs`.
enum MessageSemantics {

    // Nostr kinds used as Marmot inner app events.
    static let kindDelete: UInt64 = 5
    static let kindReaction: UInt64 = 7
    static let kindChat: UInt64 = 9
    static let kindAgentStreamStart: UInt64 = 1200

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
        /// A kind-9 media attachment described by an `imeta` tag.
        case media(MediaReferenceFfi)
        /// A kind-9 agent-stream final: carries a `stream` tag. The body
        /// (plaintext) is the full transcript; it replaces the live preview
        /// keyed by `streamId`.
        case streamFinal(streamId: String)
        /// A kind-7 reaction. Emoji lives in `content` (plaintext); empty
        /// content means an un-react (delete of the reaction event).
        case reaction(targetMessageId: String)
        /// A kind-5 delete tombstoning the `e`-tag target.
        case delete(targetMessageId: String)
        /// A kind-1200 agent-stream start (opens the live QUIC preview).
        case agentStreamStart(StreamStart)
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
        case kindAgentStreamStart:
            guard let start = streamStart(from: tags) else { return .unknown }
            return .agentStreamStart(start)
        case kindChat:
            // Order matters: a stream-final is a kind-9 with a `stream` tag; a
            // reply has both `e` and `q`; media has an `imeta` tag.
            if let streamId = streamFinalId(from: tags) {
                return .streamFinal(streamId: streamId)
            }
            if hasTag(imetaTag, in: tags) {
                guard let media = media(from: tags) else { return .unknown }
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
              normalizedHex32(firstValue(of: streamStartTag, in: tags)) != nil,
              normalizedHex32(firstValue(of: streamHashTag, in: tags)) != nil,
              validUnsignedDecimal(firstValue(of: streamChunksTag, in: tags))
        else { return nil }
        return streamId
    }

    /// Parse an `imeta` tag's space-prefixed fields (`url <blob>`, `m <type>`, `x <hash>`, ...).
    private static func media(from tags: [MessageTagFfi]) -> MediaReferenceFfi? {
        guard let tag = tags.first(where: { $0.values.first == imetaTag }) else { return nil }
        var url = ""
        var mediaType = ""
        var hash = ""
        var nonce = ""
        var version = ""
        var size: UInt64 = 0
        var name = ""
        for field in tag.values.dropFirst() {
            if let value = field.dropPrefix("url ") { url = value }
            else if let value = field.dropPrefix("m ") { mediaType = value }
            else if let value = field.dropPrefix("filename ") { name = value }
            else if let value = field.dropPrefix("x ") { hash = value }
            else if let value = field.dropPrefix("n ") { nonce = value }
            else if let value = field.dropPrefix("v ") { version = value }
            else if let value = field.dropPrefix("size ") { size = UInt64(value) ?? 0 }
        }
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hash.isHexByteString(byteCount: 32),
              nonce.isHexByteString(byteCount: 12),
              version == "mip04-v2",
              size > 0
        else { return nil }
        return MediaReferenceFfi(
            url: url,
            fileHashHex: hash,
            nonceHex: nonce,
            fileName: name,
            mediaType: mediaType,
            version: version
        )
    }

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
        normalizedHex32(raw)
    }

    private static func normalizedHex32(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 64,
              value.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil
        else { return nil }
        return value.lowercased()
    }

    private static func validUnsignedDecimal(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil
        else { return false }
        return UInt64(value) != nil
    }
}

private extension String {
    /// Returns the remainder after `prefix`, or nil if the string doesn't start with it.
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }

    func isHexByteString(byteCount: Int) -> Bool {
        count == byteCount * 2
            && range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil
    }
}
