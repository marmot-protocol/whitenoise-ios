import UIKit
import MarmotKit

/// Loads and caches decoded NIP-30 custom emoji images for one conversation.
///
/// Bytes come only through the conversation's attachment path as automatic
/// loads: retained local bytes first, then `requestAutomaticAttachment`, which
/// MDK admits only under the account's host-managed image permission. Never
/// legacy `downloadMedia`, never an explicit job. A failed load (including a
/// policy block) is retried only after the attachment policy revision changes. Decoded images are keyed by
/// account, runtime generation and chat plus the row-scoped attachment id or
/// reaction id, and every result is dropped if that scope changed while it was
/// loading. Views own cancellation through their `.task(id:)`.
@MainActor
final class ConversationCustomEmojiStore {
    typealias ListMedia = @MainActor (CustomEmojiScope) async throws -> [MediaRecordFfi]
    typealias LoadData = @MainActor (MessageMediaAttachment) async throws -> Data
    typealias Decode = @MainActor (Data, Int, CGFloat) async -> UIImage?

    static let imageLimit = 128

    private let scopeProvider: @MainActor () -> CustomEmojiScope?
    private let listMedia: ListMedia
    private let loadData: LoadData
    private let loadableAttachment: @MainActor (MediaAttachmentReferenceFfi) -> MessageMediaAttachment?
    private let decode: Decode

    private var scope: CustomEmojiScope?
    private var images: [CustomEmojiImageKey: UIImage] = [:]
    private var imageOrder: [CustomEmojiImageKey] = []
    /// Policy revision at which a load failed; retried after the policy changes.
    private var failures: [CustomEmojiImageKey: String] = [:]
    /// `:shortcode:`-captioned media records by lowercased message id.
    private var reactionMedia: [String: [MediaRecordFfi]] = [:]
    private var queriedReactionIDs: Set<String> = []
    private var pendingReactionIDs: Set<String> = []
    private var listTask: Task<Void, Never>?
    private var resolvedReactions: [String: CustomEmojiCatalogEntry] = [:]
#if DEBUG
    private(set) var listMediaCallCountForTesting = 0
#endif

    init(
        scopeProvider: @escaping @MainActor () -> CustomEmojiScope?,
        listMedia: @escaping ListMedia,
        loadData: @escaping LoadData,
        loadableAttachment: @escaping @MainActor (MediaAttachmentReferenceFfi) -> MessageMediaAttachment?,
        decode: @escaping Decode = { data, pixelSize, scale in
            await MessageMediaThumbnailDecoder.image(data: data, maxPixelSize: pixelSize, scale: scale)
        }
    ) {
        self.scopeProvider = scopeProvider
        self.listMedia = listMedia
        self.loadData = loadData
        self.loadableAttachment = loadableAttachment
        self.decode = decode
    }

    // MARK: Reads

    /// The image for an inline emoji attachment of a message row.
    func inlineImage(for item: MessageMediaAttachment, pixelSize: Int, scale: CGFloat,
                     policyRevision: String) async -> UIImage? {
        guard item.isImage, item.rejectionKind == nil, let reference = item.reference,
              let scope = currentScope() else { return nil }
        let key = CustomEmojiImageKey(scope: scope, source: .attachment(itemID: item.id), pixelSize: pixelSize)
        if let cached = images[key] { return cached }
        guard failures[key] != policyRevision else { return nil }
        return await load(key: key, item: item, expectedSha256: reference.plaintextSha256,
                          scale: scale, policyRevision: policyRevision)
    }

    /// The image for a `:shortcode:` reaction, found through
    /// `reactionMessageIdHex` and `listMedia`. Nil means show the text.
    func reactionImage(emoji: String, reactionMessageIdHex: String?, pixelSize: Int, scale: CGFloat,
                       policyRevision: String) async -> UIImage? {
        guard let shortcode = CustomEmojiShortcode(reactionContent: emoji),
              let reactionID = reactionMessageIdHex, !reactionID.isEmpty,
              let scope = currentScope() else { return nil }
        let key = CustomEmojiImageKey(scope: scope,
            source: .reaction(reactionMessageIdHex: reactionID.lowercased(), emoji: emoji), pixelSize: pixelSize)
        if let cached = images[key] { return cached }
        guard failures[key] != policyRevision,
              let record = await reactionRecord(emoji: emoji, reactionID: reactionID, scope: scope),
              CustomEmojiImageKey.accepts(key, currentScope: scopeProvider()), !Task.isCancelled
        else { return nil }
        resolvedReactions["\(reactionID.lowercased())|\(emoji)"] = CustomEmojiCatalogEntry(
            shortcode: shortcode, reference: record.reference,
            source: .reaction(reactionMessageIdHex: record.messageIdHex, attachmentIndex: record.attachmentIndex))
        guard let candidate = loadableAttachment(record.reference) else { return nil }
        return await load(key: key, item: candidate, expectedSha256: record.reference.plaintextSha256,
                          scale: scale, policyRevision: policyRevision)
    }

    /// Reaction images resolved under the current scope, for the catalog.
    var reactionCatalogEntries: [CustomEmojiCatalogEntry] {
        guard currentScope() != nil else { return [] }
        return resolvedReactions.keys.sorted().compactMap { resolvedReactions[$0] }
    }

    // MARK: Lifecycle

    /// Stops reaction lookups, e.g. while the runtime suspends. Cached images
    /// stay valid for their scope.
    func cancelAll() {
        listTask?.cancel()
        listTask = nil
        pendingReactionIDs.removeAll()
    }

    // MARK: Private

    private func currentScope() -> CustomEmojiScope? {
        let current = scopeProvider()
        if current != scope {
            reset()
            scope = current
        }
        return current
    }

    private func reset() {
        cancelAll()
        images.removeAll()
        imageOrder.removeAll()
        failures.removeAll()
        reactionMedia.removeAll()
        queriedReactionIDs.removeAll()
        resolvedReactions.removeAll()
    }

    private func reactionRecord(emoji: String, reactionID: String, scope: CustomEmojiScope) async -> MediaRecordFfi? {
        let id = reactionID.lowercased()
        if reactionMedia[id] == nil, !queriedReactionIDs.contains(id) {
            pendingReactionIDs.insert(id)
            await refreshReactionMedia(scope: scope, until: id)
        }
        guard scopeProvider() == scope else { return nil }
        return CustomEmojiReactionResolver.record(forReaction: emoji, reactionMessageIdHex: id,
                                                  in: reactionMedia[id] ?? [])
    }

    /// One coalesced `listMedia` pass covers every reaction id requested
    /// before it started; an id requested mid-flight waits for the next pass.
    private func refreshReactionMedia(scope: CustomEmojiScope, until id: String) async {
        while reactionMedia[id] == nil, !queriedReactionIDs.contains(id), pendingReactionIDs.contains(id),
              scopeProvider() == scope, !Task.isCancelled {
            if let listTask {
                await listTask.value
                continue
            }
            let batch = pendingReactionIDs
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.listTask = nil }
#if DEBUG
                self.listMediaCallCountForTesting += 1
#endif
                guard let records = try? await self.listMedia(scope),
                      !Task.isCancelled, self.scopeProvider() == scope else {
                    // A failed pass is not evidence; the next appearance retries.
                    self.pendingReactionIDs.subtract(batch)
                    return
                }
                self.reactionMedia = Dictionary(grouping: records.filter {
                    $0.caption.flatMap { CustomEmojiShortcode(reactionContent: $0) } != nil
                }, by: { $0.messageIdHex.lowercased() })
                self.queriedReactionIDs.formUnion(batch)
                self.pendingReactionIDs.subtract(batch)
            }
            listTask = task
            await task.value
        }
    }

    private func load(key: CustomEmojiImageKey, item: MessageMediaAttachment, expectedSha256: String,
                      scale: CGFloat, policyRevision: String) async -> UIImage? {
        var requested = item
        requested.downloadExplicitly = false
        do {
            let data = try await loadData(requested)
            try Task.checkCancellation()
            guard await MediaPlaintextHash.matches(data, expectedSha256: expectedSha256),
                  let image = await decode(data, key.pixelSize, scale) else {
                guard CustomEmojiImageKey.accepts(key, currentScope: scopeProvider()) else { return nil }
                failures[key] = policyRevision
                return nil
            }
            guard !Task.isCancelled, CustomEmojiImageKey.accepts(key, currentScope: scopeProvider()) else { return nil }
            let sized = Self.sizedToPoints(image, pixelSize: key.pixelSize, scale: scale)
            store(sized, for: key)
            return sized
        } catch is CancellationError {
            return nil
        } catch {
            if CustomEmojiImageKey.accepts(key, currentScope: scopeProvider()) {
                failures[key] = policyRevision
            }
            return nil
        }
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
