import Foundation
import MarmotKit

// NIP-30 custom emoji reactions (#1137). A kind-7 whose content is
// `:shortcode:` carries its image as an ordinary encrypted attachment; MDK's
// `reactionAttachment` names that slot, and the image loads through the same
// host-managed attachment path as inline message emoji.

/// The image slot of one custom emoji reaction event.
nonisolated struct CustomEmojiReactionArtwork: Equatable {
    let reactionMessageIdHex: String
    let shortcode: CustomEmojiShortcode
    let attachment: MessageMediaAttachment

    var reference: MediaAttachmentReferenceFfi? { attachment.reference }
}

nonisolated enum CustomEmojiReactionResolution {
    /// The most reactions whose artwork one conversation resolves, so a long
    /// chat cannot queue unbounded lookups.
    static let lookupLimit = 64

    /// MDK's slot for a `:shortcode:` reaction as a loadable attachment. Only
    /// an accepted image of that same reaction event, with statically safe
    /// locators and a local target to acquire it by, qualifies.
    static func artwork(
        emoji: String,
        reactionMessageIdHex: String,
        entry: AttachmentEntryFfi?
    ) -> CustomEmojiReactionArtwork? {
        guard let shortcode = CustomEmojiShortcode(reactionContent: emoji),
              let entry, entry.messageIdHex == reactionMessageIdHex,
              case .accepted = entry.attachment
        else { return nil }
        let item = MessageMediaAttachment.displayItems(
            fromOutcomes: [entry.attachment],
            ownerId: "reaction:\(entry.messageIdHex)",
            messageId: entry.messageIdHex,
            sourceMessageId: entry.sourceMessageIdHex
        ).first
        guard let item, item.isImage, item.rejectionKind == nil, item.localTarget != nil,
              let reference = item.reference,
              EncryptedMediaLocatorValidation.isStaticallySafe(reference.locators)
        else { return nil }
        return CustomEmojiReactionArtwork(reactionMessageIdHex: reactionMessageIdHex, shortcode: shortcode,
                                          attachment: item)
    }

    /// Catalog entries for resolved reaction artwork, ordered by reaction id
    /// so the merged catalog is deterministic.
    static func catalogEntries(_ artwork: [String: CustomEmojiReactionArtwork]) -> [CustomEmojiCatalogEntry] {
        artwork.values
            .sorted { $0.reactionMessageIdHex < $1.reactionMessageIdHex }
            .compactMap { item in
                guard let reference = item.reference else { return nil }
                return CustomEmojiCatalogEntry(
                    shortcode: item.shortcode,
                    reference: reference,
                    source: .reaction(reactionMessageIdHex: item.reactionMessageIdHex,
                                      attachmentIndex: item.attachment.localTarget?.attachmentIndex ?? 0)
                )
            }
    }

    /// Distinct `:shortcode:` reactions to resolve, first seen first, skipping
    /// ones already resolved or known to have no artwork, up to the limit.
    static func pendingLookups(
        tallies: [(emoji: String, reactionMessageIdHex: String?)],
        resolved: Set<String>,
        misses: Set<String>,
        limit: Int = lookupLimit
    ) -> [(emoji: String, reactionMessageIdHex: String)] {
        var seen = Set<String>()
        var result: [(emoji: String, reactionMessageIdHex: String)] = []
        for tally in tallies {
            guard result.count + resolved.count < limit else { break }
            guard let id = tally.reactionMessageIdHex, !id.isEmpty,
                  CustomEmojiShortcode(reactionContent: tally.emoji) != nil,
                  !resolved.contains(id), !misses.contains(id), seen.insert(id).inserted
            else { continue }
            result.append((tally.emoji, id))
        }
        return result
    }
}
