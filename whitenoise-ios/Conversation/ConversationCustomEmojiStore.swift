import UIKit
import MarmotKit

/// Loads and caches decoded inline NIP-30 custom emoji for one conversation.
///
/// Bytes come only through the conversation's attachment path as automatic
/// loads: retained local bytes first, then `requestAutomaticAttachment`, which
/// MDK admits only under the account's host-managed image permission. Never
/// legacy `downloadMedia`, never an explicit job. A failed load (including a
/// policy block) is retried only after the attachment policy revision changes.
/// Decoded images are keyed by account, runtime generation and chat plus the
/// row-scoped attachment id, and a result is dropped if that scope changed
/// while it was loading. Views own cancellation through their `.task(id:)`.
@MainActor
final class ConversationCustomEmojiStore {
    typealias LoadData = @MainActor (MessageMediaAttachment) async throws -> Data
    typealias Decode = @MainActor (Data, Int, CGFloat) async -> UIImage?
    /// The image slot of a `:shortcode:` reaction event, or nil when MDK
    /// reports it has none. Throws when that can't be read right now.
    typealias ResolveReaction = @MainActor (_ emoji: String, _ reactionMessageIdHex: String) async throws -> CustomEmojiReactionArtwork?

    /// What a `:shortcode:` reaction label may draw.
    enum ReactionImage {
        /// The reaction event's own image.
        case image(key: CustomEmojiImageKey, image: UIImage)
        /// The reaction carries no image, so a built-in may stand in.
        case noArtwork
    }

    static let imageLimit = 128

    private let scopeProvider: @MainActor () -> CustomEmojiScope?
    private let loadData: LoadData
    private let decode: Decode
    private let resolveReaction: ResolveReaction

    private var scope: CustomEmojiScope?
    private var images: [CustomEmojiImageKey: UIImage] = [:]
    private var imageOrder: [CustomEmojiImageKey] = []
    /// Policy revision at which a load failed; retried after the policy changes.
    private var failures: [CustomEmojiImageKey: String] = [:]

    init(
        scopeProvider: @escaping @MainActor () -> CustomEmojiScope?,
        loadData: @escaping LoadData,
        decode: @escaping Decode = { data, pixelSize, scale in
            await MessageMediaThumbnailDecoder.image(data: data, maxPixelSize: pixelSize, scale: scale)
        },
        resolveReaction: @escaping ResolveReaction = { _, _ in nil }
    ) {
        self.scopeProvider = scopeProvider
        self.loadData = loadData
        self.decode = decode
        self.resolveReaction = resolveReaction
    }

    /// The scope images are currently shown under. Reading it from a view body
    /// observes the account, runtime generation and chat it derives from.
    var currentScope: CustomEmojiScope? { scopeProvider() }

    /// The image for an inline emoji attachment of a message row, with the key
    /// it was decoded under.
    func inlineImage(for item: MessageMediaAttachment, pixelSize: Int, scale: CGFloat,
                     policyRevision: String) async -> (key: CustomEmojiImageKey, image: UIImage)? {
        guard item.isImage, item.rejectionKind == nil, let reference = item.reference,
              let scope = syncedScope() else { return nil }
        let key = CustomEmojiImageKey(scope: scope, itemID: item.id, pixelSize: pixelSize)
        if let cached = images[key] { return (key, cached) }
        guard failures[key] != policyRevision else { return nil }
        var requested = item
        requested.demand = .automatic
        do {
            let data = try await loadData(requested)
            try Task.checkCancellation()
            guard await MediaPlaintextHash.matches(data, expectedSha256: reference.plaintextSha256),
                  let image = await decode(data, pixelSize, scale) else {
                guard CustomEmojiImageKey.accepts(key, currentScope: scopeProvider()) else { return nil }
                failures[key] = policyRevision
                return nil
            }
            guard !Task.isCancelled, CustomEmojiImageKey.accepts(key, currentScope: scopeProvider()) else { return nil }
            let sized = Self.sizedToPoints(image, pixelSize: pixelSize, scale: scale)
            store(sized, for: key)
            return (key, sized)
        } catch is CancellationError {
            return nil
        } catch {
            if CustomEmojiImageKey.accepts(key, currentScope: scopeProvider()) {
                failures[key] = policyRevision
            }
            return nil
        }
    }

    /// The image for a `:shortcode:` reaction, read from that reaction
    /// event's own attachment exactly as an inline emoji is. NIP-30
    /// definitions belong to one event, so artwork is never borrowed from
    /// another reaction. Nil (not yet known, or failed) keeps the literal
    /// shortcode text.
    func reactionImage(emoji: String, reactionMessageIdHex: String?, pixelSize: Int, scale: CGFloat,
                       policyRevision: String) async -> ReactionImage? {
        guard CustomEmojiShortcode(reactionContent: emoji) != nil, let scope = syncedScope() else { return nil }
        guard let reactionID = reactionMessageIdHex, !reactionID.isEmpty else { return .noArtwork }
        let artwork: CustomEmojiReactionArtwork?
        do {
            artwork = try await resolveReaction(emoji, reactionID)
        } catch {
            return nil
        }
        guard !Task.isCancelled, scopeProvider() == scope else { return nil }
        guard let artwork else { return .noArtwork }
        guard let loaded = await inlineImage(for: artwork.attachment, pixelSize: pixelSize, scale: scale,
                                             policyRevision: policyRevision) else { return nil }
        return .image(key: loaded.key, image: loaded.image)
    }

    /// Sets the image scale so its longest side spans the requested point
    /// size even when the source has fewer pixels than the target (ImageIO
    /// thumbnails never upscale).
    nonisolated static func sizedToPoints(_ image: UIImage, pixelSize: Int, scale: CGFloat) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let longest = CGFloat(max(cgImage.width, cgImage.height))
        let points = CGFloat(max(1, pixelSize)) / max(1, scale)
        guard longest > 0, points > 0 else { return image }
        return UIImage(cgImage: cgImage, scale: longest / points, orientation: .up)
    }

    // MARK: Private

    /// Drops every cached image and failure when the scope changes.
    private func syncedScope() -> CustomEmojiScope? {
        let current = scopeProvider()
        if current != scope {
            images.removeAll()
            imageOrder.removeAll()
            failures.removeAll()
            scope = current
        }
        return current
    }

    private func store(_ image: UIImage, for key: CustomEmojiImageKey) {
        if images.updateValue(image, forKey: key) == nil {
            imageOrder.append(key)
        }
        failures[key] = nil
        while imageOrder.count > Self.imageLimit {
            images[imageOrder.removeFirst()] = nil
        }
    }
}
