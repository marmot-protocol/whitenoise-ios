import SwiftUI
import MarmotKit

nonisolated struct GroupSharedMediaItem: Identifiable, Equatable {
    let id: String
    let attachment: MessageMediaAttachment
    let timestamp: UInt64
    /// Owning message, when the record carries one — powers jump-to-message.
    let messageIdHex: String?

    var isVisual: Bool {
        attachment.isImage || attachment.isVideo
    }
}

nonisolated enum GroupSharedMediaPresentation {
    static func items(entries: [AttachmentEntryFfi]) -> [GroupSharedMediaItem] {
        entries.flatMap { entry in
            MessageMediaAttachment.displayItems(fromOutcomes: [entry.attachment],
                ownerId: "shared-media:\(entry.messageIdHex)", messageId: entry.messageIdHex,
                sourceMessageId: entry.sourceMessageIdHex).map { attachment in
                let index: UInt32
                switch entry.attachment {
                case .accepted(let slot, _), .rejected(let slot, _): index = slot
                }
                return GroupSharedMediaItem(id: "\(entry.messageIdHex):\(index)", attachment: attachment,
                    timestamp: entry.timelineAt, messageIdHex: entry.messageIdHex)
            }
        }
    }

    static func items(from records: [MediaRecordFfi]) -> [GroupSharedMediaItem] {
        var duplicateCountByOwnerID: [String: Int] = [:]
        return records.map { record in
            // Records without a message id fall back to content identity;
            // identical plaintext re-sent as separate records must still get
            // distinct ForEach ids, so the fallback folds in the ciphertext
            // hash and record timestamps too.
            let stableRecordID = record.messageIdHex.isEmpty
                ? "\(record.reference.plaintextSha256.lowercased()):\(record.reference.ciphertextSha256.lowercased()):\(record.recordedAt):\(record.receivedAt)"
                : record.messageIdHex
            let baseOwnerID = "shared-media:\(stableRecordID):\(record.attachmentIndex)"
            let duplicateIndex = duplicateCountByOwnerID[baseOwnerID, default: 0]
            duplicateCountByOwnerID[baseOwnerID] = duplicateIndex + 1
            // MediaRecordFfi exposes no timeline-row identity when messageIdHex
            // is empty. Preserve a deterministic occurrence ordinal so even
            // byte-for-byte duplicate projection rows remain distinct in SwiftUI.
            let ownerID = duplicateIndex == 0
                ? baseOwnerID
                : "\(baseOwnerID):duplicate-\(duplicateIndex)"
            let attachment = MessageMediaAttachment.displayItems(
                from: [record.reference],
                ownerId: ownerID
            )[0]
            return GroupSharedMediaItem(
                id: ownerID,
                attachment: attachment,
                timestamp: max(record.recordedAt, record.receivedAt),
                messageIdHex: record.messageIdHex.isEmpty ? nil : record.messageIdHex
            )
        }
        .sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id > rhs.id
        }
    }

    static func visualItems(from items: [GroupSharedMediaItem]) -> [GroupSharedMediaItem] {
        items.filter(\.isVisual)
    }

    @MainActor
    static func subtitle(for item: GroupSharedMediaItem) -> String {
        let mediaType = ContentSanitizer.compactSingleLine(item.attachment.mediaType, maxLength: 100)
            ?? L10n.string("Attachment")
        guard item.timestamp > 0 else { return mediaType }
        let date = Date(timeIntervalSince1970: TimeInterval(item.timestamp))
        return L10n.formatted(
            "%@ · %@",
            arguments: [mediaType, RelativeTime.short(date)],
            locale: AppLanguage.currentLocale
        )
    }
}

/// Details-page preview: a horizontal strip of the most recent photos and
/// videos plus the entry point into the full library (voice, files, links).
struct GroupSharedMediaSection: View {
    let items: [GroupSharedMediaItem]
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void
    let onLoadMedia: ConversationMediaLoader
    let onOpenGallery: (MessageMediaGallery) -> Void
    let onSeeAll: () -> Void

    static let previewCount = 12
    private static let thumbnailSize: CGFloat = 92

    var body: some View {
        Section {
            if isLoading && items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let error, items.isEmpty {
                ContentUnavailableView {
                    Label("Shared media unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: onRetry)
                }
            } else {
                let visualItems = GroupSharedMediaPresentation.visualItems(from: items)

                if !visualItems.isEmpty {
                    previewStrip(visualItems: visualItems)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .listRowBackground(Color.clear)
                }

                Button(action: onSeeAll) {
                    HStack {
                        Label("View Shared Media", systemImage: "photo.on.rectangle.angled")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Shared Media")
        }
        .id(AttachmentPresentationState.shared.revision)
    }

    private func previewStrip(visualItems: [GroupSharedMediaItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(visualItems.prefix(Self.previewCount)) { item in
                    GroupSharedMediaThumbnail(
                        item: item.attachment,
                        onLoadMedia: onLoadMedia
                    ) { initialData in
                        let attachments = visualItems.map(\.attachment)
                        guard let gallery = MessageMediaGallery(
                            items: attachments,
                            initialItem: item.attachment,
                            initialMediaData: initialData,
                            messageIdByItemID: Dictionary(
                                uniqueKeysWithValues: visualItems.compactMap { media in
                                    media.messageIdHex.map { (media.attachment.id, $0) }
                                }
                            )
                        ) else { return }
                        onOpenGallery(gallery)
                    }
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .clipShape(.rect(cornerRadius: 10))
                }
            }
        }
    }
}

struct GroupSharedMediaThumbnail: View {
    let item: MessageMediaAttachment
    let onLoadMedia: ConversationMediaLoader
    let onOpen: (Data?) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var sourceData: Data?
    @State private var isLoading = false
    @State private var didFail = false

    private let pointSize: CGFloat = 120

    var body: some View {
        Button {
            Task {
                if thumbnail == nil {
                    await load(force: didFail)
                }
                guard thumbnail != nil else { return }
                onOpen(item.isImage ? sourceData : nil)
            }
        } label: {
            GeometryReader { geometry in
                ZStack {
                    Color(.tertiarySystemFill)
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                            .clipped()
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: didFail ? "arrow.clockwise" : item.kind.systemImageName)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    if item.isVideo, thumbnail != nil {
                        Image(systemName: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.fileName)
        .task(id: item.id) {
            await load()
        }
    }

    @MainActor
    private func load(force: Bool = false) async {
        guard !isLoading else { return }
        let maxPixelSize = max(1, Int(ceil(pointSize * displayScale)))
        let cacheKey = MessageMediaThumbnailPresentation.cacheKey(for: item)

        if !force, item.isImage,
           let cached = MessageMediaThumbnailDecoder.cachedThumbnail(
            for: cacheKey,
            maxPixelSize: maxPixelSize
           )
        {
            thumbnail = cached.image
            sourceData = cached.sourceData
            didFail = false
            return
        }
        if !force, item.isVideo,
           let cached = MessageVideoThumbnailDecoder.cachedThumbnail(
            for: cacheKey,
            maxPixelSize: maxPixelSize
           )
        {
            thumbnail = cached
            didFail = false
            return
        }

        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let producerEpoch = MessageMediaCache.currentProducerEpoch()
            let data = try await onLoadMedia.data(for: item)
            guard !Task.isCancelled else { return }
            if item.isImage {
                guard let decoded = await MessageMediaThumbnailDecoder.image(
                    data: data,
                    maxPixelSize: maxPixelSize,
                    scale: displayScale
                ) else {
                    didFail = true
                    return
                }
                MessageMediaThumbnailDecoder.store(
                    decoded,
                    sourceData: data,
                    for: cacheKey,
                    maxPixelSize: maxPixelSize
                )
                sourceData = data
                thumbnail = decoded
            } else if item.isVideo,
                      let url = await MediaPlaybackFileStore.fileURL(for: item, data: data, producerEpoch: producerEpoch),
                      let decoded = await MessageVideoThumbnailDecoder.thumbnail(
                        url: url,
                        maxPixelSize: maxPixelSize,
                        scale: displayScale
                      )
            {
                MessageVideoThumbnailDecoder.store(
                    decoded,
                    for: cacheKey,
                    maxPixelSize: maxPixelSize
                )
                thumbnail = decoded
            } else {
                didFail = true
            }
        } catch is CancellationError {
            return
        } catch {
            didFail = true
        }
    }
}
