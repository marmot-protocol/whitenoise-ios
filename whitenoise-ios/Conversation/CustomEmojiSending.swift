import Foundation
import MarmotKit

// Sending NIP-30 custom emoji (#1128). The only emoji a person can send are
// the ones this conversation already holds (`CustomEmojiCatalog`). Each image
// is re-encrypted for the current epoch with `uploadMedia(send: false)` and
// named by `["emoji", shortcode, reference.locators[0].value]`. Everything here
// is pure so limits, tags and validation are testable without a runtime.

/// MDK 0.12.0 `validate_message_tags` limits, enforced before anything is
/// uploaded or sent.
nonisolated enum CustomEmojiSendPolicy {
    static let maxTags = 64
    static let maxTagValueBytes = 16 * 1024
    /// MDK caps reaction content at 64 characters; keeping `:shortcode:`
    /// within it lets the same emoji become a reaction once MDK pins
    /// attachment-bearing reactions to their epoch (#1137).
    static let maxShortcodeLength = 62

    /// NIP-30: ASCII letters, digits and underscores only. Received shortcodes
    /// with other characters still render, but are never re-sent.
    static func isSendable(_ shortcode: CustomEmojiShortcode) -> Bool {
        let bytes = shortcode.name.utf8
        return (1...maxShortcodeLength).contains(bytes.count) && bytes.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: true
            default: false
            }
        }
    }
}

/// Why a custom emoji message could not be sent. Every case keeps the
/// composer draft for an explicit retry.
nonisolated enum CustomEmojiSendError: Error, Equatable {
    case unsendableShortcode(String)
    case missingLocator
    case tooManyTags(count: Int)
    case tagValuesTooLarge(bytes: Int)
    case forbiddenImetaTag
    case malformedTag
    case emptyEventTarget
    case mixedWithAttachments
    case imageUnavailable
    case uploadFailed
    case staleEpoch
    case sendFailed

    var message: String {
        switch self {
        case .tooManyTags, .tagValuesTooLarge:
            L10n.string("This message has too many custom emoji. Remove some and try again.")
        case .mixedWithAttachments:
            L10n.string("Send custom emoji in a separate message from photos and files.")
        case .imageUnavailable:
            L10n.string("A custom emoji image isn't available on this device yet. Try again once it has loaded.")
        case .uploadFailed:
            L10n.string("Couldn't upload the custom emoji. Check your connection and try again.")
        case .staleEpoch:
            L10n.string("The chat changed while sending. Try again.")
        case .emptyEventTarget:
            L10n.string("The message you're replying to is unavailable.")
        case .unsendableShortcode, .missingLocator, .forbiddenImetaTag, .malformedTag:
            L10n.string("This custom emoji can't be sent.")
        case .sendFailed:
            L10n.string("Couldn't send. Check your connection and try again.")
        }
    }
}

/// One custom emoji the person can send from this conversation: a NIP-30
/// shortcode, the image reference it was received with, and a chat
/// attachment whose retained bytes hold the same plaintext.
nonisolated struct CustomEmojiSendable: Identifiable, Equatable {
    let shortcode: CustomEmojiShortcode
    let reference: MediaAttachmentReferenceFfi
    let source: MessageMediaAttachment

    var id: String { shortcode.name }
    var token: String { shortcode.token }
}

/// Composer state for a custom emoji message. The draft stays in the
/// composer until MDK accepts the message.
nonisolated enum CustomEmojiComposerSendState: Equatable {
    case idle
    case sending
    case failed(String)
}

/// What a custom emoji composer send submitted, captured at the Send tap.
/// `draft` is the saved-draft form of the composer at that moment.
nonisolated struct CustomEmojiSubmittedDraft: Equatable {
    let accountRef: String
    let groupIdHex: String
    let text: String
    let replyTargetId: String?
    let draft: ConversationDraftSnapshot
}

/// Custom emoji reactions are deferred until MDK pins attachment-bearing
/// reactions to their epoch (#1137, marmot-protocol/mdk#2151). Until then a
/// `:shortcode:` chip only removes the person's own reaction: tapping it
/// never adds a media reaction, nor a plain-text copy that would read as
/// literal `:shortcode:` text.
nonisolated enum CustomEmojiReactionPolicy {
    static func allowsAdding(_ emoji: String) -> Bool {
        CustomEmojiShortcode(reactionContent: emoji) == nil
    }
}

nonisolated enum CustomEmojiSendCatalog {
    /// One image per sendable shortcode, in catalog order (first wins).
    /// Entries without a readable chat slot are left out: their bytes cannot
    /// be re-encrypted, and a tag URL is never fetched.
    static func sendables(
        catalog: [CustomEmojiCatalogEntry],
        source: (MediaAttachmentReferenceFfi) -> MessageMediaAttachment?
    ) -> [CustomEmojiSendable] {
        var seen = Set<CustomEmojiShortcode>()
        var result: [CustomEmojiSendable] = []
        for entry in catalog where CustomEmojiSendPolicy.isSendable(entry.shortcode) && !seen.contains(entry.shortcode) {
            guard let attachment = source(entry.reference) else { continue }
            seen.insert(entry.shortcode)
            result.append(CustomEmojiSendable(shortcode: entry.shortcode, reference: entry.reference, source: attachment))
        }
        return result
    }

    /// Catalog shortcodes used in `text`, in first-appearance order.
    static func used(in text: String, sendables: [CustomEmojiSendable]) -> [CustomEmojiSendable] {
        let byShortcode = Dictionary(sendables.map { ($0.shortcode, $0) }, uniquingKeysWith: { first, _ in first })
        guard !byShortcode.isEmpty, text.contains(":") else { return [] }
        var seen = Set<CustomEmojiShortcode>()
        return CustomEmojiText.matches(in: Array(text), resolvable: Set(byShortcode.keys)).compactMap { match in
            guard seen.insert(match.shortcode).inserted else { return nil }
            return byShortcode[match.shortcode]
        }
    }
}

nonisolated enum CustomEmojiTags {
    /// Mirrors MDK `validate_message_tags`: at most 64 rows and 16 KiB of
    /// UTF-8 values, no empty rows or names, no `imeta`, and `e` / `q` rows
    /// need a non-blank target.
    static func validate(_ tags: [[String]]) throws(CustomEmojiSendError) {
        guard tags.count <= CustomEmojiSendPolicy.maxTags else {
            throw .tooManyTags(count: tags.count)
        }
        let bytes = tags.joined().reduce(0) { $0 + $1.utf8.count }
        guard bytes <= CustomEmojiSendPolicy.maxTagValueBytes else {
            throw .tagValuesTooLarge(bytes: bytes)
        }
        for tag in tags {
            guard let name = tag.first, !name.isEmpty else { throw .malformedTag }
            guard name != "imeta" else { throw .forbiddenImetaTag }
            if name == "e" || name == "q" {
                guard tag.count >= 2, !tag[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw .emptyEventTarget
                }
            }
        }
    }

    /// `["emoji", shortcode, reference.locators[0].value]`.
    static func emojiTag(_ shortcode: CustomEmojiShortcode, reference: MediaAttachmentReferenceFfi) throws(CustomEmojiSendError) -> [String] {
        guard CustomEmojiSendPolicy.isSendable(shortcode) else { throw .unsendableShortcode(shortcode.name) }
        guard let url = reference.locators.first?.value, !url.isEmpty,
              url.trimmingCharacters(in: .whitespacesAndNewlines) == url else { throw .missingLocator }
        return ["emoji", shortcode.name, url]
    }

    /// Tags for a kind-9 chat: one `emoji` row per image in text order, then
    /// the `e` + `q` reply rows MDK's own replies carry.
    static func messageTags(
        emoji: [(shortcode: CustomEmojiShortcode, reference: MediaAttachmentReferenceFfi)],
        replyTargetId: String?
    ) throws(CustomEmojiSendError) -> [[String]] {
        var tags: [[String]] = []
        for item in emoji {
            tags.append(try emojiTag(item.shortcode, reference: item.reference))
        }
        if let replyTargetId {
            tags.append([MessageSemantics.eventRefTag, replyTargetId])
            tags.append([MessageSemantics.quoteRefTag, replyTargetId])
        }
        try validate(tags)
        return tags
    }

    /// Cheap pre-upload count check so an over-limit message fails before any
    /// network work. The byte limit is checked again with the uploaded URLs.
    static func precheck(emojiCount: Int, isReply: Bool) throws(CustomEmojiSendError) {
        let count = emojiCount + (isReply ? 2 : 0)
        guard count <= CustomEmojiSendPolicy.maxTags else { throw .tooManyTags(count: count) }
    }
}

nonisolated enum CustomEmojiComposerText {
    /// Appends `token` to the draft, separated from preceding text by a space,
    /// so the inserted `:shortcode:` stays a whole token.
    static func inserting(_ token: String, into draft: String) -> String {
        guard let last = draft.last else { return token }
        return last.isWhitespace ? draft + token : draft + " " + token
    }
}

/// Uploaded references for this conversation's custom emoji, keyed by scope
/// and plaintext digest. A reference is reused for every later send and every
/// retry while its epoch is current, so a retry never uploads the same image
/// twice; concurrent sends share one in-flight upload. Results that complete
/// after the account, runtime or chat changed are dropped.
@MainActor
final class CustomEmojiUploadCache {
    typealias LoadBytes = @MainActor (MessageMediaAttachment) async throws -> Data
    typealias Upload = @MainActor (CustomEmojiScope, MediaUploadAttachmentRequestFfi) async throws -> MediaAttachmentReferenceFfi

    struct Uploaded {
        let reference: MediaAttachmentReferenceFfi
        let plaintext: Data
    }

    private struct Key: Hashable {
        let scope: CustomEmojiScope
        let plaintextSha256: String
    }

    static let limit = 64

    private let scopeProvider: @MainActor () -> CustomEmojiScope?
    private let loadBytes: LoadBytes
    private let upload: Upload
    private var scope: CustomEmojiScope?
    private var uploaded: [Key: Uploaded] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: (id: UUID, task: Task<Uploaded, Error>)] = [:]
    /// Upload calls made, for tests asserting a retry never re-uploads.
    private(set) var uploadCount = 0

    init(scopeProvider: @escaping @MainActor () -> CustomEmojiScope?, loadBytes: @escaping LoadBytes, upload: @escaping Upload) {
        self.scopeProvider = scopeProvider
        self.loadBytes = loadBytes
        self.upload = upload
    }

    /// A reference for `sendable` encrypted under the group's current epoch.
    /// `currentEpoch` nil (not yet known) reuses whatever was uploaded.
    func reference(for sendable: CustomEmojiSendable, scope: CustomEmojiScope, currentEpoch: UInt64?) async throws -> Uploaded {
        guard currentScope() == scope else { throw CancellationError() }
        let key = Key(scope: scope, plaintextSha256: sendable.reference.plaintextSha256.lowercased())
        if let cached = uploaded[key] {
            if currentEpoch == nil || cached.reference.sourceEpoch == currentEpoch { return cached }
            forget(key)
        }
        if let pending = inFlight[key] {
            let result = try await pending.task.value
            guard scopeProvider() == scope else { throw CancellationError() }
            return result
        }
        let id = UUID()
        let task = Task { @MainActor [weak self, loadBytes, upload] () throws -> Uploaded in
            var source = sendable.source
            source.demand = .automatic
            let data: Data
            do {
                data = try await loadBytes(source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CustomEmojiSendError.imageUnavailable
            }
            guard await MediaPlaintextHash.matches(data, expectedSha256: key.plaintextSha256) else {
                throw CustomEmojiSendError.imageUnavailable
            }
            let original = sendable.reference
            let request = MediaUploadAttachmentRequestFfi(fileName: original.fileName, mediaType: original.mediaType,
                                                          plaintext: data, dim: original.dim, thumbhash: original.thumbhash)
            let reference: MediaAttachmentReferenceFfi
            do {
                self?.uploadCount += 1
                reference = try await upload(scope, request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CustomEmojiSendError.uploadFailed
            }
            guard reference.plaintextSha256.lowercased() == key.plaintextSha256,
                  reference.locators.first.map({ !$0.value.isEmpty }) == true else {
                throw CustomEmojiSendError.uploadFailed
            }
            return Uploaded(reference: reference, plaintext: data)
        }
        inFlight[key] = (id, task)
        defer {
            if inFlight[key]?.id == id { inFlight[key] = nil }
        }
        let result = try await task.value
        guard scopeProvider() == scope else { throw CancellationError() }
        store(result, for: key)
        return result
    }

    /// Drops an uploaded reference MDK refused as stale, so the next attempt
    /// re-encrypts for the new epoch.
    func invalidate(_ reference: MediaAttachmentReferenceFfi) {
        for (key, value) in uploaded where value.reference == reference {
            forget(key)
        }
    }

    private func currentScope() -> CustomEmojiScope? {
        let current = scopeProvider()
        if current != scope {
            uploaded.removeAll()
            order.removeAll()
            for pending in inFlight.values { pending.task.cancel() }
            inFlight.removeAll()
            scope = current
        }
        return current
    }

    private func store(_ value: Uploaded, for key: Key) {
        if uploaded.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > Self.limit {
            uploaded[order.removeFirst()] = nil
        }
    }

    private func forget(_ key: Key) {
        uploaded[key] = nil
        order.removeAll { $0 == key }
    }
}
