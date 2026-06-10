import SwiftUI
import UIKit
import MarmotKit

enum MessageBubbleReplyLayout {
    static let bodyHorizontalInset: CGFloat = 14
    static let bodyTopInset: CGFloat = 9
    static let bodyTopInsetAfterReply: CGFloat = 11
    static let bodyBottomInset: CGFloat = 9
    static let headerHorizontalInset = bodyHorizontalInset
    static let headerVerticalInset: CGFloat = 8
    static let sentHeaderOverlayOpacity = 0.16
}

/// One chat bubble. Aligned right for our own messages, left for everyone
/// else. Renders an optional quoted reply header, the message body, a
/// time/delivery caption, and any reaction chips.
struct MessageBubble: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass
    let record: AppMessageRecordFfi
    let status: MessageStatus
    var debugStyle: MessageDebugStyle? = nil
    var isDeleted: Bool = false
    var replyPreview: (name: String, text: String)? = nil
    var mediaItems: [MessageMediaAttachment] = []
    var reactions: [ConversationViewModel.ReactionTally] = []
    var onTapReaction: (String) -> Void = { _ in }
    var onLoadMedia: (MessageMediaAttachment) async throws -> Data = { _ in Data() }

    @State private var mediaGallery: MessageMediaGallery?

    private var isFromMe: Bool { record.direction == "sent" }

    private var bubbleMaxWidth: CGFloat? {
        sizeClass == .regular ? 560 : nil
    }

    /// Minimum gap on the opposite side. Tiny on iPhone so long bubbles run
    /// (near) full width; larger on iPad where width is also capped above.
    private var oppositeInset: CGFloat {
        sizeClass == .regular ? 64 : 0
    }

    /// Body text projected from the decoded unsigned Nostr app event's kind,
    /// tags, and content.
    private var bodyText: String {
        if !mediaItems.isEmpty {
            return record.plaintext
        }
        return MessagePreview.body(record)
    }

    private var sanitizedBodyText: String {
        ProfileSanitizer.messageBody(bodyText)
    }

    private var hasVisibleBodyText: Bool {
        if debugStyle != nil, debugStyle?.isUserVisibleBubble == false {
            return true
        }
        return !sanitizedBodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsStandardBody: Bool {
        debugStyle?.isUserVisibleBubble ?? true
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isFromMe { Spacer(minLength: oppositeInset) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                if !isFromMe {
                    Text(appState.displayName(forAccountIdHex: record.sender))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                if isDeleted {
                    deletedBubble
                } else if !mediaItems.isEmpty, showsStandardBody {
                    mediaMessageContent
                } else {
                    textBubble
                        .opacity(status == .sending ? 0.7 : 1)

                    if !reactions.isEmpty, showsStandardBody {
                        reactionChips
                    }
                }

                metaLine
                    .padding(isFromMe ? .trailing : .leading, 12)
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: isFromMe ? .trailing : .leading)

            if !isFromMe { Spacer(minLength: oppositeInset) }
        }
        .padding(.horizontal, 12)
        .fullScreenCover(item: $mediaGallery) { gallery in
            MessageMediaFullscreenGalleryView(
                gallery: gallery,
                onLoadMedia: onLoadMedia
            ) {
                mediaGallery = nil
            }
        }
    }

    private var deletedBubble: some View {
        HStack(spacing: 5) {
            Image(systemName: "trash")
            Text("This message was deleted")
        }
        .font(.callout)
        .italic()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    private func replyHeader(_ preview: (name: String, text: String)) -> some View {
        quoted(preview)
            .padding(.horizontal, MessageBubbleReplyLayout.headerHorizontalInset)
            .padding(.vertical, MessageBubbleReplyLayout.headerVerticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(replyHeaderBackground)
    }

    private var textBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let debugStyle {
                debugHeader(debugStyle)
            }
            if let replyPreview, showsStandardBody {
                replyHeader(replyPreview)
            }
            if showsStandardBody {
                messageBodyText(hasReply: replyPreview != nil)
                if let debugStyle, debugStyle.isUserVisibleBubble {
                    debugTagsFooter(debugStyle)
                }
            } else if let debugStyle {
                debugPayload(debugStyle)
            }
        }
        .font(.body)
        .background(bubbleBackground)
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            if let debugStyle {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(debugStyle.category.accentColor.opacity(0.75), lineWidth: 2)
            }
        }
        // No .textSelection here: it installs its own long-press recognizer
        // that swallows the bubble's long-press. Copy is in the actions sheet.
    }

    private func debugHeader(_ style: MessageDebugStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(style.category.label)
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 0)
                Text(style.kindLabel)
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(style.category.accentColor)
        }
        .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
        .padding(.top, MessageBubbleReplyLayout.bodyTopInset)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.category.accentColor.opacity(0.12))
    }

    private func debugTagsFooter(_ style: MessageDebugStyle) -> some View {
        Text(style.tagsSummary)
            .font(.caption2.monospaced())
            .foregroundStyle(isFromMe ? Color.white.opacity(0.78) : Color.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
            .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
    }

    private func debugPayload(_ style: MessageDebugStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(style.detailText)
                .font(.caption.monospaced())
                .foregroundStyle(isFromMe ? Color.white.opacity(0.95) : Color.primary)
                .textSelection(.enabled)
            Text(style.tagsSummary)
                .font(.caption2.monospaced())
                .foregroundStyle(isFromMe ? Color.white.opacity(0.82) : Color.secondary)
                .textSelection(.enabled)
            if !record.messageIdHex.isEmpty {
                Text("id: \(record.messageIdHex)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(isFromMe ? Color.white.opacity(0.72) : Color.secondary.opacity(0.8))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
        .padding(.top, MessageBubbleReplyLayout.bodyTopInsetAfterReply)
        .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
    }

    @ViewBuilder
    private var mediaMessageContent: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 6) {
            MessageMediaGrid(
                items: mediaItems,
                isFromMe: isFromMe,
                maxWidth: mediaGridWidth,
                onLoadMedia: onLoadMedia,
                onOpenImage: { item, data in
                    mediaGallery = MessageMediaGallery(
                        items: mediaItems,
                        initialItem: item,
                        initialImageData: data
                    )
                }
            )

            if let replyPreview {
                VStack(alignment: .leading, spacing: 0) {
                    replyHeader(replyPreview)
                    if hasVisibleBodyText {
                        messageBodyText(hasReply: true)
                    }
                }
                .font(.body)
                .background(bubbleBackground)
                .clipShape(.rect(cornerRadius: 18))
            } else if hasVisibleBodyText {
                textBubble
            }
        }
        .opacity(status == .sending ? 0.7 : 1)

        if !reactions.isEmpty {
            reactionChips
        }
    }

    private var mediaGridWidth: CGFloat {
        sizeClass == .regular ? 340 : 276
    }

    private func quoted(_ preview: (name: String, text: String)) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(isFromMe ? Color.white.opacity(0.8) : Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFromMe ? Color.white.opacity(0.95) : Color.primary)
                Text(preview.text)
                    .font(.caption)
                    .foregroundStyle(isFromMe ? Color.white.opacity(0.82) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // Without this the width-only Capsule is greedy vertically and stretches
        // the whole bubble; fixedSize pins the quote to its content height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func messageBodyText(hasReply: Bool) -> some View {
        Text(sanitizedBodyText)
            .foregroundStyle(isFromMe ? Color.white : Color.primary)
            .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
            .padding(.top, hasReply ? MessageBubbleReplyLayout.bodyTopInsetAfterReply : MessageBubbleReplyLayout.bodyTopInset)
            .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
    }

    @ViewBuilder
    private var replyHeaderBackground: some View {
        if isFromMe {
            Color.white.opacity(MessageBubbleReplyLayout.sentHeaderOverlayOpacity)
        } else {
            Color(UIColor { traits in
                Self.receivedReplyHeaderColor(dark: traits.userInterfaceStyle == .dark)
            })
        }
    }

    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { tally in
                Button {
                    onTapReaction(tally.emoji)
                } label: {
                    HStack(spacing: 2) {
                        Text(ProfileSanitizer.reactionEmoji(tally.emoji))
                        if tally.count > 1 {
                            Text("\(tally.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(tally.mine ? Color.accentColor.opacity(0.22) : Color(.tertiarySystemFill))
                    )
                    .overlay(
                        Capsule().stroke(tally.mine ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .padding(isFromMe ? .trailing : .leading, 8)
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(timeLabel)
            // Show the status caption for our own messages, and the live
            // "streaming" indicator regardless of side.
            if let statusLabel, isFromMe || status == .streaming {
                Text("·")
                Text(statusLabel)
            }
        }
        .font(.caption2)
        .foregroundStyle(status == .failed ? Color.red : Color.secondary)
    }

    private var timeLabel: String {
        let date = Date(timeIntervalSince1970: TimeInterval(record.recordedAt))
        return RelativeTime.shortTime(date)
    }

    private var statusLabel: String? {
        switch status {
        case .sending: return L10n.string("Sending…")
        case .sent: return L10n.string("Sent")
        case .failed: return L10n.string("Not delivered")
        case .streaming: return L10n.string("Streaming…")
        case .received: return nil
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if let debugStyle, !debugStyle.isUserVisibleBubble {
            Color(UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.systemGray5
                    : UIColor.secondarySystemBackground
            })
        } else if isFromMe {
            LinearGradient(
                colors: [.blue, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(UIColor { traits in
                Self.receivedBubbleColor(dark: traits.userInterfaceStyle == .dark)
            })
        }
    }

    /// Fill for an incoming (other-user) message bubble. In dark mode the old
    /// `tertiarySystemBackground` sat too close to the elevated conversation
    /// background, so received bubbles barely stood out (#4). Use a lighter
    /// system gray that clearly separates the bubble while keeping the white
    /// message text well above the WCAG AA contrast ratio. Light mode is
    /// unchanged.
    static func receivedBubbleColor(dark: Bool) -> UIColor {
        dark ? .systemGray5 : .secondarySystemBackground
    }

    static func receivedReplyHeaderColor(dark: Bool) -> UIColor {
        dark ? .systemGray4 : .systemGray5
    }
}

private struct MessageMediaGrid: View {
    let items: [MessageMediaAttachment]
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: (MessageMediaAttachment) async throws -> Data
    let onOpenImage: (MessageMediaAttachment, Data) -> Void

    private let spacing: CGFloat = 3
    private let cornerRadius: CGFloat = 14

    private var visibleItems: [MessageMediaAttachment] {
        Array(items.prefix(MessageMediaGridPresentation.visibleCount(totalCount: items.count)))
    }

    private var hiddenCount: Int {
        MessageMediaGridPresentation.hiddenCount(totalCount: items.count)
    }

    private var columnCount: Int {
        MessageMediaGridPresentation.columnCount(totalCount: items.count)
    }

    private var rowCount: Int {
        MessageMediaGridPresentation.rowCount(totalCount: items.count)
    }

    private var tileSize: CGFloat {
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        return (maxWidth - totalSpacing) / CGFloat(columnCount)
    }

    private var gridHeight: CGFloat {
        CGFloat(rowCount) * tileSize + CGFloat(rowCount - 1) * spacing
    }

    private var rowStarts: [Int] {
        rowCount == 1 ? [0] : [0, columnCount]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                HStack(spacing: spacing) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tile(at: rowStart + column)
                    }
                }
                .frame(width: maxWidth, alignment: .leading)
            }
        }
        .frame(width: maxWidth, height: gridHeight, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(isFromMe ? 0.16 : 0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        if index < visibleItems.count {
            MessageMediaTile(
                item: visibleItems[index],
                isFromMe: isFromMe,
                sideLength: tileSize,
                hiddenCount: index == MessageMediaGridPresentation.maxVisibleItems - 1 ? hiddenCount : 0,
                onLoadMedia: onLoadMedia,
                onOpenImage: onOpenImage
            )
        } else {
            Color.clear
                .frame(width: tileSize, height: tileSize)
        }
    }
}

enum MessageMediaGridPresentation {
    static let maxVisibleItems = 4

    static func visibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), maxVisibleItems)
    }

    static func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - maxVisibleItems)
    }

    static func columnCount(totalCount: Int) -> Int {
        totalCount <= 1 ? 1 : 2
    }

    static func rowCount(totalCount: Int) -> Int {
        if totalCount <= 2 { return 1 }
        return 2
    }
}

private struct MessageMediaTile: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let sideLength: CGFloat
    let hiddenCount: Int
    let onLoadMedia: (MessageMediaAttachment) async throws -> Data
    let onOpenImage: (MessageMediaAttachment, Data) -> Void

    @State private var imageData: Data?
    @State private var isLoading = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            if item.isImage, let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: sideLength, height: sideLength)
                    .clipped()
            } else if item.isImage {
                imagePlaceholder
            } else {
                filePlaceholder
            }

            if hiddenCount > 0 {
                Color.black.opacity(0.48)
                Text("+\(hiddenCount)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .clipped()
        .contentShape(Rectangle())
        .task(id: item.id) {
            await loadImageIfNeeded()
        }
        .onTapGesture {
            if didFail {
                Task { await loadImageIfNeeded(force: true) }
            } else if let imageData {
                onOpenImage(item, imageData)
            } else {
                Task {
                    if let data = await loadImageIfNeeded(force: true) {
                        onOpenImage(item, data)
                    }
                }
            }
        }
        .frame(width: sideLength, height: sideLength)
    }

    @ViewBuilder
    private var imagePlaceholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if didFail {
                VStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.title3)
            Text(item.fileName)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.tertiarySystemFill))
    }

    private func loadImageIfNeeded(force: Bool = false) async -> Data? {
        guard item.isImage else { return nil }
        if let imageData, !force { return imageData }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia(item)
            imageData = data
            return data
        } catch {
            didFail = true
            return nil
        }
    }
}

private struct MessageMediaGallery: Identifiable {
    let id = UUID()
    let items: [MessageMediaAttachment]
    let initialItemID: String
    let initialImageData: Data

    init(item: MessageMediaAttachment, imageData: Data) {
        self.init(items: [item], initialItem: item, initialImageData: imageData)
    }

    init(items: [MessageMediaAttachment], initialItem: MessageMediaAttachment, initialImageData: Data) {
        let imageItems = items.filter(\.isImage)
        if imageItems.contains(where: { $0.id == initialItem.id }) {
            self.items = imageItems
        } else {
            self.items = [initialItem] + imageItems
        }
        self.initialItemID = initialItem.id
        self.initialImageData = initialImageData
    }

    func initialData(for item: MessageMediaAttachment) -> Data? {
        if item.id == initialItemID {
            return initialImageData
        }
        return item.localData
    }
}

private struct MessageMediaFullscreenGalleryView: View {
    let gallery: MessageMediaGallery
    let onLoadMedia: (MessageMediaAttachment) async throws -> Data
    let onDismiss: () -> Void

    @State private var selectedItemID: String

    init(
        gallery: MessageMediaGallery,
        onLoadMedia: @escaping (MessageMediaAttachment) async throws -> Data,
        onDismiss: @escaping () -> Void
    ) {
        self.gallery = gallery
        self.onLoadMedia = onLoadMedia
        self.onDismiss = onDismiss
        _selectedItemID = State(initialValue: gallery.initialItemID)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedItemID) {
                ForEach(gallery.items) { item in
                    MessageMediaFullscreenPage(
                        item: item,
                        initialImageData: gallery.initialData(for: item),
                        onLoadMedia: onLoadMedia
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(
                .page(indexDisplayMode: .never)
            )
            .ignoresSafeArea()

            if gallery.items.count > 1 {
                Text(pageCountLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 34)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
    }

    private var pageCountLabel: String {
        guard let index = gallery.items.firstIndex(where: { $0.id == selectedItemID }) else {
            return ""
        }
        return "\(index + 1) of \(gallery.items.count)"
    }
}

private struct MessageMediaFullscreenPage: View {
    let item: MessageMediaAttachment
    let onLoadMedia: (MessageMediaAttachment) async throws -> Data

    @State private var imageData: Data?
    @State private var isLoading = false
    @State private var didFail = false

    init(
        item: MessageMediaAttachment,
        initialImageData: Data?,
        onLoadMedia: @escaping (MessageMediaAttachment) async throws -> Data
    ) {
        self.item = item
        self.onLoadMedia = onLoadMedia
        _imageData = State(initialValue: initialImageData)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView()
                    .tint(.white)
            } else if didFail {
                Button {
                    Task { await loadImageIfNeeded(force: true) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            await loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded(force: Bool = false) async {
        guard imageData == nil || force else { return }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            imageData = try await onLoadMedia(item)
        } catch {
            didFail = true
        }
    }
}
