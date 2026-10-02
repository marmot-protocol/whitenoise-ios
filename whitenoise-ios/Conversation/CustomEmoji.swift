import Foundation
import MarmotKit

// NIP-30 custom emoji. A kind-9 chat or kind-7 reaction names an image with
// `["emoji", shortcode, url]`; in Marmot that image is an ordinary encrypted
// attachment on the same event, matched by its `imeta` locator. The tag URL is
// only a matching key: it is never fetched. Everything here is pure so the
// sending follow-up can reuse the parser, matcher and catalog.

/// A NIP-30 shortcode, without its surrounding colons: ASCII letters, digits,
/// hyphens and underscores, bounded so peer text cannot make it unbounded.
nonisolated struct CustomEmojiShortcode: Hashable, Comparable, Sendable {
    static let maxLength = 64

    let name: String

    init?(_ raw: String) {
        guard (1...Self.maxLength).contains(raw.utf8.count),
              raw.utf8.allSatisfy(Self.isShortcodeByte)
        else { return nil }
        name = raw
    }

    /// Reaction content that is exactly `:shortcode:`.
    init?(reactionContent content: String) {
        guard content.utf8.count >= 3, content.utf8.count <= Self.maxLength + 2,
              content.hasPrefix(":"), content.hasSuffix(":")
        else { return nil }
        self.init(String(content.dropFirst().dropLast()))
    }

    /// The literal `:shortcode:` form shown when no image is available.
    var token: String { ":\(name):" }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.name < rhs.name }

    static func isShortcodeByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: true
        default: false
        }
    }

    static func isShortcodeCharacter(_ character: Character) -> Bool {
        guard character.utf8.count == 1, let byte = character.utf8.first else { return false }
        return isShortcodeByte(byte)
    }

    /// VoiceOver text for a reaction: the shortcode name for custom emoji,
    /// otherwise the sanitized reaction text.
    static func spokenReaction(_ content: String) -> String {
        Self(reactionContent: content)?.name ?? ContentSanitizer.reactionEmoji(content)
    }
}

/// One well-formed NIP-30 `emoji` tag.
nonisolated struct CustomEmojiTag: Hashable, Sendable {
    let shortcode: CustomEmojiShortcode
    let url: String

    /// `["emoji", shortcode, url]` with an optional fourth emoji-set address.
    /// Anything else, including an empty or oversized URL, is malformed.
    init?(_ tag: MessageTagFfi) {
        let values = tag.values
        guard values.count >= 3, values.count <= 4, values[0] == "emoji",
              let shortcode = CustomEmojiShortcode(values[1])
        else { return nil }
        let url = values[2]
        guard !url.isEmpty, url.utf8.count <= ContentSanitizer.maxImageURLLength,
              url.trimmingCharacters(in: .whitespacesAndNewlines) == url
        else { return nil }
        self.shortcode = shortcode
        self.url = url
    }

    /// Well-formed tags in tag order. The first well-formed tag for a shortcode
    /// is authoritative; later duplicates are ignored, even when the first one
    /// names no attachment, so one event can never name two images.
    static func parse(_ tags: [MessageTagFfi]) -> [CustomEmojiTag] {
        var seen = Set<CustomEmojiShortcode>()
        var result: [CustomEmojiTag] = []
        for tag in tags {
            guard let parsed = CustomEmojiTag(tag), seen.insert(parsed.shortcode).inserted else { continue }
            result.append(parsed)
        }
        return result
    }
}

/// `:shortcode:` tokenizing for plain strings and attributed display runs.
nonisolated enum CustomEmojiText {
    enum Token: Equatable {
        case text(String)
        case emoji(CustomEmojiShortcode)
    }

    enum AttributedSegment: Equatable {
        case text(AttributedString)
        /// `original` keeps the run's own styling for the literal fallback.
        case emoji(CustomEmojiShortcode, original: AttributedString)
    }

    /// Character-offset ranges of `:shortcode:` tokens naming one of
    /// `resolvable`. Scans left to right; an unresolvable candidate does not
    /// consume its closing colon, so `:a:b:` still finds `:b:`.
    static func matches(
        in characters: [Character],
        resolvable: Set<CustomEmojiShortcode>
    ) -> [(range: Range<Int>, shortcode: CustomEmojiShortcode)] {
        guard !resolvable.isEmpty else { return [] }
        let names = Dictionary(uniqueKeysWithValues: resolvable.map { ($0.name, $0) })
        var result: [(range: Range<Int>, shortcode: CustomEmojiShortcode)] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == ":" else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, end - index - 1 <= CustomEmojiShortcode.maxLength,
                  CustomEmojiShortcode.isShortcodeCharacter(characters[end]) {
                end += 1
            }
            if end < characters.count, characters[end] == ":", end > index + 1,
               let shortcode = names[String(characters[(index + 1)..<end])] {
                result.append((index..<(end + 1), shortcode))
                index = end + 1
            } else {
                index += 1
            }
        }
        return result
    }

    /// Distinct resolvable shortcodes that occur in `text`.
    static func shortcodes(in text: String, among candidates: Set<CustomEmojiShortcode>) -> Set<CustomEmojiShortcode> {
        guard !candidates.isEmpty, text.contains(":") else { return [] }
        return Set(matches(in: Array(text), resolvable: candidates).map(\.shortcode))
    }

    static func tokens(in text: String, resolvable: Set<CustomEmojiShortcode>) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var cursor = 0
        for match in matches(in: characters, resolvable: resolvable) {
            if match.range.lowerBound > cursor {
                tokens.append(.text(String(characters[cursor..<match.range.lowerBound])))
            }
            tokens.append(.emoji(match.shortcode))
            cursor = match.range.upperBound
        }
        if cursor < characters.count {
            tokens.append(.text(String(characters[cursor...])))
        }
        return tokens
    }

    /// Splits a display run around resolvable shortcodes, preserving the
    /// attributes (links, emphasis, code) of every surrounding slice.
    static func segments(of attributed: AttributedString, resolvable: Set<CustomEmojiShortcode>) -> [AttributedSegment] {
        guard !resolvable.isEmpty else { return [.text(attributed)] }
        let characters = Array(attributed.characters)
        let found = matches(in: characters, resolvable: resolvable)
        guard !found.isEmpty else { return [.text(attributed)] }
        func index(_ offset: Int) -> AttributedString.Index {
            attributed.characters.index(attributed.startIndex, offsetBy: offset)
        }
        var segments: [AttributedSegment] = []
        var cursor = 0
        for match in found {
            if match.range.lowerBound > cursor {
                segments.append(.text(AttributedString(attributed[index(cursor)..<index(match.range.lowerBound)])))
            }
            let original = AttributedString(attributed[index(match.range.lowerBound)..<index(match.range.upperBound)])
            segments.append(.emoji(match.shortcode, original: original))
            cursor = match.range.upperBound
        }
        if cursor < characters.count {
            segments.append(.text(AttributedString(attributed[index(cursor)...])))
        }
        return segments
    }
}

/// Inline custom emoji for one message row.
nonisolated struct CustomEmojiRowResolution: Equatable {
    /// Shortcode → the row's own accepted image attachment to draw inline.
    let inline: [CustomEmojiShortcode: MessageMediaAttachment]
    /// The row's attachments minus those drawn inline, for the media grid.
    let gridItems: [MessageMediaAttachment]

    static let empty = Self(inline: [:], gridItems: [])

    var shortcodes: Set<CustomEmojiShortcode> { Set(inline.keys) }
    var isEmpty: Bool { inline.isEmpty }
}

nonisolated enum CustomEmojiResolver {
    /// Matches each `:shortcode:` in `text` to the row's attachment whose
    /// `imeta` locator equals the shortcode's first `emoji` tag URL. Unmatched
    /// shortcodes, malformed tags and URLs without an attachment are left as
    /// literal text. An attachment drawn inline leaves the media grid so it is
    /// not rendered twice; an emoji-tagged attachment whose shortcode never
    /// appears in the text stays in the grid.
    static func resolve(
        text: String,
        tags: [MessageTagFfi],
        attachments: [MessageMediaAttachment]
    ) -> CustomEmojiRowResolution {
        guard !attachments.isEmpty, text.contains(":") else {
            return CustomEmojiRowResolution(inline: [:], gridItems: attachments)
        }
        let emojiTags = CustomEmojiTag.parse(tags)
        guard !emojiTags.isEmpty else {
            return CustomEmojiRowResolution(inline: [:], gridItems: attachments)
        }
        let used = CustomEmojiText.shortcodes(in: text, among: Set(emojiTags.map(\.shortcode)))
        var inline: [CustomEmojiShortcode: MessageMediaAttachment] = [:]
        for tag in emojiTags where used.contains(tag.shortcode) {
            if let attachment = attachment(forURL: tag.url, in: attachments) {
                inline[tag.shortcode] = attachment
            }
        }
        guard !inline.isEmpty else {
            return CustomEmojiRowResolution(inline: [:], gridItems: attachments)
        }
        let inlineIDs = Set(inline.values.map(\.id))
        return CustomEmojiRowResolution(inline: inline, gridItems: attachments.filter { !inlineIDs.contains($0.id) })
    }

    /// The first accepted, decodable image attachment carrying `url` as a
    /// locator. Rejected slots and unsafe locator sets never match.
    static func attachment(forURL url: String, in attachments: [MessageMediaAttachment]) -> MessageMediaAttachment? {
        attachments.first { item in
            guard item.rejectionKind == nil, item.isImage, let reference = item.reference else { return false }
            return reference.locators.contains { $0.value == url }
                && EncryptedMediaLocatorValidation.isStaticallySafe(reference.locators)
        }
    }
}

nonisolated enum CustomEmojiReactionResolver {
    /// The image `listMedia` returns for a `:shortcode:` reaction under its
    /// `reactionMessageIdHex`: an accepted image of that kind-7, lowest slot
    /// first. A record whose caption is a different reaction is ignored.
    static func record(
        forReaction emoji: String,
        reactionMessageIdHex: String,
        in records: [MediaRecordFfi]
    ) -> MediaRecordFfi? {
        guard CustomEmojiShortcode(reactionContent: emoji) != nil, !reactionMessageIdHex.isEmpty else { return nil }
        let id = reactionMessageIdHex.lowercased()
        return records
            .filter { record in
                record.messageIdHex.lowercased() == id
                    && (record.caption == nil || record.caption == emoji)
                    && MediaAttachmentPolicy.isDecodableImageMediaType(record.reference.mediaType)
                    && EncryptedMediaLocatorValidation.isStaticallySafe(record.reference.locators)
            }
            .min { $0.attachmentIndex < $1.attachmentIndex }
    }

    /// MDK 0.12.0 serves retained bytes only for kind-9 source slots, so a
    /// reaction image is readable when a chat attachment in this conversation
    /// carries the same plaintext. The caller verifies the bytes against
    /// `reference.plaintextSha256` before use.
    static func loadableAttachment(
        matching reference: MediaAttachmentReferenceFfi,
        candidates: [MessageMediaAttachment]
    ) -> MessageMediaAttachment? {
        let sha = reference.plaintextSha256.lowercased()
        guard !sha.isEmpty else { return nil }
        return candidates.first { item in
            item.rejectionKind == nil && item.isImage && item.localTarget != nil
                && item.reference?.plaintextSha256.lowercased() == sha
        }
    }
}

/// One custom emoji the conversation already holds, with the encrypted
/// reference a sender can reuse (`sendTaggedMedia` / `reactWithMedia`).
nonisolated struct CustomEmojiCatalogEntry: Hashable {
    enum Source: Hashable {
        case message(messageIdHex: String, attachmentIndex: UInt32?)
        case reaction(reactionMessageIdHex: String, attachmentIndex: UInt32)
    }

    let shortcode: CustomEmojiShortcode
    let reference: MediaAttachmentReferenceFfi
    let source: Source
}

nonisolated enum CustomEmojiCatalog {
    /// Message-inline emoji first, then reaction images, deduplicated by
    /// shortcode and plaintext digest (first seen wins), sorted by shortcode.
    static func merge(messages: [CustomEmojiCatalogEntry], reactions: [CustomEmojiCatalogEntry]) -> [CustomEmojiCatalogEntry] {
        var seen = Set<String>()
        var result: [CustomEmojiCatalogEntry] = []
        for entry in messages + reactions {
            let key = "\(entry.shortcode.name)|\(entry.reference.plaintextSha256.lowercased())"
            guard seen.insert(key).inserted else { continue }
            result.append(entry)
        }
        return result.enumerated()
            .sorted { $0.element.shortcode == $1.element.shortcode ? $0.offset < $1.offset : $0.element.shortcode < $1.element.shortcode }
            .map(\.element)
    }

    static func messageEntries(messageIdHex: String, resolution: CustomEmojiRowResolution) -> [CustomEmojiCatalogEntry] {
        resolution.inline.compactMap { shortcode, item in
            guard let reference = item.reference else { return nil }
            return CustomEmojiCatalogEntry(shortcode: shortcode, reference: reference,
                source: .message(messageIdHex: messageIdHex,
                    attachmentIndex: item.localTarget?.attachmentIndex ?? item.sourceHint?.slot))
        }
    }
}

/// Account, runtime and chat a custom emoji image belongs to. Results computed
/// under one scope are never shown under another.
nonisolated struct CustomEmojiScope: Hashable, Sendable {
    let accountRef: String
    let runtimeGeneration: Int
    let groupIdHex: String
}

/// Identity of one decoded emoji image.
nonisolated struct CustomEmojiImageKey: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// An inline attachment, keyed by its row-scoped display id.
        case attachment(itemID: String)
        /// A reaction image, keyed by the earliest kind-7 carrying the emoji.
        case reaction(reactionMessageIdHex: String, emoji: String)
    }

    let scope: CustomEmojiScope
    let source: Source
    let pixelSize: Int

    /// A late result is accepted only while its scope is still current.
    static func accepts(_ key: Self, currentScope: CustomEmojiScope?) -> Bool {
        key.scope == currentScope
    }
}
