import SwiftUI
import UIKit
import MarmotKit
import ImageIO
import AVFoundation
import AVKit
import UniformTypeIdentifiers

private struct TimelineRowVisibleEnvironmentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var timelineRowIsVisible: Bool {
        get { self[TimelineRowVisibleEnvironmentKey.self] }
        set { self[TimelineRowVisibleEnvironmentKey.self] = newValue }
    }
}

struct TimelineMediaTaskID: Equatable {
    let contentID: String
    let isVisible: Bool
}

/// Reference box for the media-load callback. Passing the bare async closure
/// through every media view layer builds a deep reabstraction-thunk chain
/// that corrupts the indirect argument in debug builds — one shared box keeps
/// each hop a plain reference copy and the call a direct method dispatch.
@MainActor
final class ConversationMediaLoader {
    private let load: (MessageMediaAttachment) async throws -> Data

    init(_ load: @escaping (MessageMediaAttachment) async throws -> Data) {
        self.load = load
    }

    func data(for media: MessageMediaAttachment) async throws -> Data {
        try await load(media)
    }
}

enum MessageBubbleReplyLayout {
    static let richContentWidth: CGFloat = 256
    static let richBubbleWidth = richContentWidth + (cardOuterInset * 2)
    static let bodyHorizontalInset = ChatBubbleMetrics.horizontalInset
    static let bodyTopInset = ChatBubbleMetrics.verticalInset
    static let bodyTopInsetAfterReply: CGFloat = 0
    static let bodyBottomInset = ChatBubbleMetrics.verticalInset
    static let cardOuterInset: CGFloat = 6
    static let cardHorizontalInset: CGFloat = 10
    static let cardVerticalInset: CGFloat = 6
    static let cardCornerRadius = ChatBubbleMetrics.cornerRadius - cardOuterInset
    static let sentCardOpacity = 0.16
    static let receivedCardOpacity = 0.09
}

nonisolated enum MessageGiphyGridPresentation {
    /// A GIF joins the visual grid only when every attachment is visual.
    /// Documents and audio keep their own rows beneath a full-width GIF card.
    static func gridsWithGiphy(isVisualMedia: [Bool]) -> Bool {
        !isVisualMedia.isEmpty && isVisualMedia.allSatisfy { $0 }
    }
}

nonisolated enum MessageRichMediaBubblePresentation {
    static func contentWidth(
        maxWidth: CGFloat,
        singleVisualWidth: CGFloat?,
        hasCaption: Bool,
        hasReply: Bool
    ) -> CGFloat {
        let boundedMaxWidth = max(1, maxWidth)
        guard !hasCaption,
              !hasReply,
              let singleVisualWidth,
              singleVisualWidth.isFinite,
              singleVisualWidth > 0
        else { return boundedMaxWidth }
        return min(boundedMaxWidth, singleVisualWidth)
    }
}

nonisolated enum MessageBodyCollapsePresentation {
    static let maxCollapsedCharacters = 900
    static let maxCollapsedLines = 12
    static let collapsedBodyMaxHeight: CGFloat = 260

    static func shouldCollapse(_ text: String) -> Bool {
        text.count > maxCollapsedCharacters || lineCount(text) > maxCollapsedLines
    }

    static func isCollapsed(_ text: String, isExpanded: Bool) -> Bool {
        shouldCollapse(text) && !isExpanded
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// One chat bubble. Aligned right for our own messages, left for everyone
/// else. Renders an optional quoted reply header, the message body, a
/// external time/delivery metadata, and any reaction chips.
struct MessageBubble: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    let record: AppMessageRecordFfi
    let status: MessageStatus
    var debugStyle: MessageDebugStyle? = nil
    var isDeleted: Bool = false
    var isEdited: Bool = false
    var clusterPresentation: MessageClusterPresentation = .none
    var replyPreview: ConversationReplyPreview? = nil
    var mediaItems: [MessageMediaAttachment] = []
    var markdownBlocks: [MarkdownDisplayBlock]? = nil
    var reactions: [ConversationViewModel.ReactionTally] = []
    var onShowReactionDetails: (String?) -> Void = { _ in }
    var onReplyPreviewTap: () -> Void = {}
    var onLoadMedia = ConversationMediaLoader { _ in Data() }
    var mediaForwardingContext: MediaForwardingContext?
    /// Set when the message has viewable edit history; makes the inline "Edited"
    /// label tap to open the history sheet, the same sheet the actions menu opens.
    var onViewEditHistory: (() -> Void)? = nil
    /// Set for a failed outgoing message; a tap on the bubble opens the
    /// retry/discard sheet.
    var onFailedTap: (() -> Void)? = nil

    @State private var mediaGallery: MessageMediaGallery?
    @State private var isBodyExpanded = false
    @State private var pendingExternalLink: PendingMessageExternalLink?

    private var isFromMe: Bool { record.direction == "sent" }

    private var bubbleMaxWidth: CGFloat? {
        sizeClass == .regular ? ChatBubbleMetrics.regularMaximumWidth : nil
    }

    /// Minimum gap on the opposite side. Tiny on iPhone so long bubbles run
    /// (near) full width; larger on iPad where width is also capped above.
    private var oppositeInset: CGFloat {
        sizeClass == .regular ? ChatBubbleMetrics.regularOppositeInset : ChatBubbleMetrics.compactOppositeInset
    }

    /// Body text projected from the decoded unsigned Nostr app event's kind,
    /// tags, and content.
    private var bodyText: String {
        if let remoteGiphyMedia {
            return Self.giphyCaptionText(
                remoteGiphyMedia,
                mentionDisplayName: { appState.mentionDisplayName(for: $0) }
            )
        }
        return Self.bodyText(
            for: record,
            hasMediaItems: !mediaItems.isEmpty,
            mentionDisplayName: { appState.mentionDisplayName(for: $0) }
        )
    }

    /// A GIF bubble renders only the caption its sender typed. The envelope's
    /// URL and credit line must never surface as message text.
    static func giphyCaptionText(
        _ media: RemoteGiphyMedia,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String {
        guard let caption = media.caption else { return "" }
        return CanonicalMentionDisplayProjection.project(caption) { npub in
            mentionDisplayName?(MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
        }.text
    }

    static func bodyText(
        for record: AppMessageRecordFfi,
        hasMediaItems: Bool,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String {
        if hasMediaItems, record.plaintext.isEmpty {
            // The attachments render separately; do not replace an empty
            // caption with MessagePreview's filename fallback inside the bubble.
            return ""
        }
        return MessagePreview.body(record, mentionDisplayName: mentionDisplayName)
    }

    private var sanitizedBodyText: String {
        ContentSanitizer.messageBody(bodyText)
    }

    private var hasVisibleBodyText: Bool {
        if debugStyle != nil, debugStyle?.isUserVisibleBubble == false {
            return true
        }
        return !sanitizedBodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sharedLocation: SharedLocation? {
        SharedLocationText.location(from: record.plaintext)
    }

    private var remoteGiphyMedia: RemoteGiphyMedia? {
        guard debugStyle == nil else { return nil }
        return RemoteGiphyMedia.parse(wireText: record.plaintext)
    }

    private var showsStandardBody: Bool {
        debugStyle?.isUserVisibleBubble ?? true
    }

    private var showsMediaUploadProgress: Bool {
        MessageMediaUploadPresentation.showsIndicator(status: status, items: mediaItems)
    }

    private var standaloneEmoji: String? {
        guard debugStyle == nil,
              !isDeleted,
              replyPreview == nil,
              mediaItems.isEmpty
        else { return nil }

        return SingleEmojiMessagePresentation.emoji(in: sanitizedBodyText)
    }

    private var hasExpirationTimer: Bool {
        MessageExpirationPresentation.showsIndicator(
            retentionSeconds: record.retentionSeconds,
            expiresAt: record.retentionExpiresAt
        )
    }

    /// White-on-gradient text is only appropriate for our own user-visible bubbles.
    private var usesSentBubbleForeground: Bool {
        isFromMe && showsStandardBody
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isFromMe { Spacer(minLength: oppositeInset) }

            if !isFromMe, clusterPresentation.reservesIdentityLane {
                GroupMessageIdentityLane(
                    accountIdHex: record.sender,
                    showsAvatar: clusterPresentation.showsAvatar
                )
            }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                if !isFromMe, clusterPresentation.showsSenderName {
                    Text(appState.displayName(forAccountIdHex: record.sender))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                MessageBubbleChromeLayout(isFromMe: isFromMe) {
                    messageSurface
                    bubbleMetadataRow
                }

                // Media rows have no bubble tap for the failed dialog, and the
                // footer's red glyph alone is easy to miss — this caption is
                // the one affordance every failed row shares.
                if status == .failed, let onFailedTap {
                    Button(action: onFailedTap) {
                        Text("Not delivered. Tap for options.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(isFromMe ? .trailing : .leading, 12)
                }
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: isFromMe ? .trailing : .leading)
            .layoutPriority(1)

            if !isFromMe { Spacer(minLength: oppositeInset) }
        }
        .padding(.horizontal, 12)
        .padding(.top, mediaItems.isEmpty ? 0 : 4)
        .fullScreenCover(item: $mediaGallery) { gallery in
            MessageMediaFullscreenGalleryView(
                gallery: gallery,
                onLoadMedia: onLoadMedia,
                forwardingContext: mediaForwardingContext
            ) {
                mediaGallery = nil
            }
        }
        .alert(L10n.string("Open link?"), isPresented: externalLinkConfirmationPresented) {
            Button(L10n.string("Open")) {
                guard let link = pendingExternalLink else { return }
                pendingExternalLink = nil
                openURL(link.url)
            }
            Button("Cancel", role: .cancel) {
                pendingExternalLink = nil
            }
        } message: {
            Text(pendingExternalLink?.displayText ?? "")
        }
    }

    @ViewBuilder
    private var messageSurface: some View {
        if isDeleted {
            deletedBubble
        } else if let remoteGiphyMedia, showsStandardBody {
            remoteGiphyMessageContent(remoteGiphyMedia)
        } else if !mediaItems.isEmpty, showsStandardBody {
            mediaMessageContent
        } else if let standaloneEmoji {
            if status == .failed {
                standaloneEmojiContent(standaloneEmoji)
                    .contentShape(.rect)
                    .onTapGesture { onFailedTap?() }
            } else {
                standaloneEmojiContent(standaloneEmoji)
                    .opacity(status == .sending ? 0.7 : 1)
            }
        } else {
            // The tap gesture exists only on failed rows — a recognizer on
            // every bubble steals touches from timeline scrolling.
            if status == .failed {
                textBubble
                    .contentShape(.rect)
                    .onTapGesture { onFailedTap?() }
            } else {
                textBubble
                    .opacity(status == .sending ? 0.7 : 1)
            }
        }
    }

    private func standaloneEmojiContent(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: SingleEmojiMessagePresentation.fontSize))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
    }

    private var giphySharesMediaGrid: Bool {
        MessageGiphyGridPresentation.gridsWithGiphy(
            isVisualMedia: mediaItems.map { $0.isImage || $0.isVideo }
        )
    }

    @ViewBuilder
    private func remoteGiphyVisual(_ media: RemoteGiphyMedia) -> some View {
        if giphySharesMediaGrid {
            MessageMediaGrid(
                cells: [.giphy(media)] + mediaItems.map(MessageVisualCell.media),
                isFromMe: isFromMe,
                maxWidth: mediaGridWidth,
                onLoadMedia: onLoadMedia,
                onOpenImage: { item, data in
                    mediaGallery = MessageMediaGallery(
                        items: mediaItems,
                        initialItem: item,
                        initialImageData: data,
                        messageIdByItemID: mediaMessageIds,
                        giphyMedia: media
                    )
                },
                onOpenVideo: { item in
                    mediaGallery = MessageMediaGallery(
                        items: mediaItems,
                        initialItem: item,
                        messageIdByItemID: mediaMessageIds,
                        giphyMedia: media
                    )
                },
                onOpenGiphy: { openGiphyGallery($0) }
            )

            // A grid cell has no room for a credit line, so the whole grid
            // carries the attribution GIPHY requires.
            Text(media.creditLabel)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe))
        } else {
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: isFromMe,
                onOpenFullscreen: { openGiphyGallery(media) }
            )
            .clipShape(.rect(cornerRadius: 12, style: .continuous))

            if !mediaItems.isEmpty {
                mediaAttachments
            }
        }
    }

    private func openGiphyGallery(_ media: RemoteGiphyMedia) {
        mediaGallery = MessageMediaGallery(
            giphyMedia: media,
            items: giphySharesMediaGrid ? mediaItems : [],
            messageIdByItemID: mediaMessageIds
        )
    }

    private func remoteGiphyMessageContent(_ media: RemoteGiphyMedia) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyPreview {
                replyCard(replyPreview)
            }

            remoteGiphyVisual(media)

            if hasVisibleBodyText {
                // Markdown blocks are parsed from the whole record content,
                // which here is the envelope, not the caption alone.
                messageBodyText(hasReply: false, richContent: true, plainText: true)
            }
        }
        .frame(width: MessageBubbleReplyLayout.richContentWidth, alignment: .leading)
        .padding(6)
        .background { bubbleBackground }
        .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
        .opacity(status == .sending ? 0.7 : 1)
    }

    private var deletedBubble: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
            Text(
                isFromMe
                    ? L10n.string("You deleted this message.")
                    : L10n.string("This message was deleted.")
            )
        }
        .font(.subheadline)
        .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe))
        .padding(.horizontal, ChatBubbleMetrics.horizontalInset)
        .padding(.vertical, ChatBubbleMetrics.verticalInset)
        .background { bubbleBackground }
        .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
    }

    private func replyHeader(_ preview: ConversationReplyPreview) -> some View {
        replyCard(preview)
            .padding(.horizontal, MessageBubbleReplyLayout.cardOuterInset)
            .padding(.vertical, MessageBubbleReplyLayout.cardOuterInset)
    }

    private func replyCard(_ preview: ConversationReplyPreview) -> some View {
        Button(action: onReplyPreviewTap) {
            quoted(preview)
                .padding(.horizontal, MessageBubbleReplyLayout.cardHorizontalInset)
                .padding(.vertical, MessageBubbleReplyLayout.cardVerticalInset)
                .frame(
                    width: MessageBubbleReplyLayout.richContentWidth,
                    alignment: .leading
                )
                .background(
                    replyCardBackground,
                    in: .rect(
                        cornerRadius: MessageBubbleReplyLayout.cardCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.formatted("Reply to %@", preview.name))
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
                if let sharedLocation {
                    sharedLocationBody(sharedLocation)
                } else {
                    messageBodyText(hasReply: replyPreview != nil)
                }
                if let debugStyle, debugStyle.isUserVisibleBubble {
                    debugTagsFooter(debugStyle)
                }
            } else if let debugStyle {
                debugPayload(debugStyle)
            }
        }
        .font(.body)
        .background { bubbleBackground }
        .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
        .overlay {
            if let debugStyle {
                RoundedRectangle(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(debugStyle.category.accentColor.opacity(0.75), lineWidth: 2)
            }
        }
        // No .textSelection here: it installs its own long-press recognizer
        // that swallows the bubble's long-press. Copy is in the actions sheet.
    }

    private func sharedLocationBody(_ location: SharedLocation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                _ = handleMessageLink(location.url)
            } label: {
                SharedLocationMapPreview(location: location)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Location"))

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Label(L10n.string("Location"), systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : MessageBubblePalette.receivedForeground)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
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
            .foregroundStyle(usesSentBubbleForeground ? MessageBubblePalette.sentForeground.opacity(0.78) : Color.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
            .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
    }

    private func debugPayload(_ style: MessageDebugStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(style.detailText)
                .font(.caption.monospaced())
                .foregroundStyle(usesSentBubbleForeground ? MessageBubblePalette.sentForeground.opacity(0.95) : Color.primary)
                .textSelection(.enabled)
            Text(style.tagsSummary)
                .font(.caption2.monospaced())
                .foregroundStyle(usesSentBubbleForeground ? MessageBubblePalette.sentForeground.opacity(0.82) : Color.secondary)
                .textSelection(.enabled)
            if !record.messageIdHex.isEmpty {
                Text("id: \(record.messageIdHex)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(usesSentBubbleForeground ? MessageBubblePalette.sentForeground.opacity(0.72) : Color.secondary.opacity(0.8))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
        .padding(.top, MessageBubbleReplyLayout.bodyTopInsetAfterReply)
        .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
    }

    @ViewBuilder
    private var mediaMessageContent: some View {
        if mediaItems.contains(where: { $0.kind == .audio }) {
            legacyMediaMessageContent
        } else {
            richMediaMessageContent
        }
    }

    private var richMediaMessageContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyPreview {
                replyCard(replyPreview)
            }

            mediaAttachments

            if hasVisibleBodyText {
                messageBodyText(hasReply: false, richContent: true)
            }
        }
        .frame(width: richMediaContentWidth, alignment: .leading)
        .padding(6)
        .background { bubbleBackground }
        .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
        .opacity(status == .sending ? 0.7 : 1)
    }

    private var legacyMediaMessageContent: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 6) {
            mediaAttachments

            if let replyPreview {
                VStack(alignment: .leading, spacing: 0) {
                    replyHeader(replyPreview)
                    if hasVisibleBodyText {
                        messageBodyText(hasReply: true)
                    }
                }
                .font(.body)
                .background { bubbleBackground }
                .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
            } else if hasVisibleBodyText {
                textBubble
            }
        }
        .opacity(status == .sending ? 0.7 : 1)
    }

    private var mediaAttachments: some View {
        MessageMediaAttachmentContent(
            items: mediaItems,
            isFromMe: isFromMe,
            maxWidth: mediaGridWidth,
            onLoadMedia: onLoadMedia,
            onOpenImage: { item, data in
                mediaGallery = MessageMediaGallery(
                    items: mediaItems,
                    initialItem: item,
                    initialImageData: data,
                    messageIdByItemID: mediaMessageIds
                )
            },
            onOpenVideo: { item in
                mediaGallery = MessageMediaGallery(
                    items: mediaItems,
                    initialItem: item,
                    messageIdByItemID: mediaMessageIds
                )
            }
        )
        .overlay {
            if showsMediaUploadProgress {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.55), in: Circle())
                    .accessibilityLabel(L10n.string("Sending…"))
                    .allowsHitTesting(false)
            }
        }
    }

    private var mediaMessageIds: [String: String] {
        guard !record.messageIdHex.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: mediaItems.map { ($0.id, record.messageIdHex) })
    }

    private var mediaGridWidth: CGFloat {
        if mediaItems.contains(where: { $0.kind == .audio }) {
            return sizeClass == .regular ? 340 : 276
        }
        return 256
    }

    private var richMediaContentWidth: CGFloat {
        let singleVisualWidth: CGFloat?
        if mediaItems.count == 1, let item = mediaItems.first {
            switch item.kind {
            case .image:
                singleVisualWidth = MessageImageBubblePresentation.displaySize(
                    maxWidth: mediaGridWidth,
                    dim: item.dim
                ).width
            case .video:
                singleVisualWidth = MessageVideoBubblePresentation.displaySize(
                    maxWidth: mediaGridWidth,
                    dim: item.dim
                ).width
            case .audio, .document, .unsupported:
                singleVisualWidth = nil
            }
        } else {
            singleVisualWidth = nil
        }

        return MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: MessageBubbleReplyLayout.richContentWidth,
            singleVisualWidth: singleVisualWidth,
            hasCaption: hasVisibleBodyText,
            hasReply: replyPreview != nil
        )
    }

    private func quoted(_ preview: ConversationReplyPreview) -> some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MessageBubblePalette.foreground(isFromMe: isFromMe))
                Text(preview.text)
                    .font(.caption)
                    .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let media = preview.media {
                MessageReplyMediaThumbnail(
                    item: media,
                    isFromMe: isFromMe,
                    onLoadMedia: onLoadMedia
                )
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(
                    (isFromMe ? MessageBubblePalette.sentForeground : MessageBubblePalette.receivedForeground)
                        .opacity(isFromMe ? 0.65 : 0.46)
                )
                .frame(width: 3)
                .frame(maxHeight: .infinity)
        }
        // Without this the width-only Capsule is greedy vertically and stretches
        // the whole bubble; fixedSize pins the quote to its content height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func messageBodyText(
        hasReply: Bool,
        richContent: Bool = false,
        plainText: Bool = false
    ) -> some View {
        let isCollapsed = MessageBodyCollapsePresentation.isCollapsed(
            sanitizedBodyText,
            isExpanded: isBodyExpanded
        )
        return VStack(alignment: .leading, spacing: 5) {
            messageBodyContent(plainText: plainText)
                .frame(
                    maxHeight: isCollapsed ? MessageBodyCollapsePresentation.collapsedBodyMaxHeight : nil,
                    alignment: .topLeading
                )
                .clipped()
                .mask {
                    if isCollapsed {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.88),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        Rectangle()
                    }
                }

            if isCollapsed {
                Button {
                    isBodyExpanded = true
                } label: {
                    Text(L10n.string("Read more"))
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground.opacity(0.9) : Color.accentColor)
            }
        }
        .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : MessageBubblePalette.receivedForeground)
        .padding(
            .horizontal,
            richContent ? 6 : MessageBubbleReplyLayout.bodyHorizontalInset
        )
        .padding(
            .top,
            richContent
                ? 0
                : (hasReply ? MessageBubbleReplyLayout.bodyTopInsetAfterReply : MessageBubbleReplyLayout.bodyTopInset)
        )
        .padding(
            .bottom,
            richContent ? 2 : MessageBubbleReplyLayout.bodyBottomInset
        )
        .frame(
            width: richContent
                ? MessageBubbleReplyLayout.richContentWidth
                : (hasReply ? MessageBubbleReplyLayout.richBubbleWidth : nil),
            alignment: .leading
        )
    }

    @ViewBuilder
    private func messageBodyContent(plainText: Bool) -> some View {
        if let blocks = markdownBlocks, !plainText {
            MarkdownMessageView(
                blocks: blocks,
                quoteBar: isFromMe ? MessageBubblePalette.sentForeground.opacity(0.8) : Color.accentColor
            )
            .tint(isFromMe ? MessageBubblePalette.sentForeground : Color.accentColor)
            .environment(\.openURL, OpenURLAction(handler: handleMessageLink))
        } else {
            // Records without parsed tokens (non-chat kinds, optimistic
            // stream bubbles, pre-markdown history) keep the plain path.
            Text(sanitizedBodyText)
        }
    }

    private func handleMessageLink(_ url: URL) -> OpenURLAction.Result {
        switch MessageLinkPolicy.action(for: url) {
        case .openProfile(let npub):
            appState.presentProfile(npub: npub)
            return .handled
        case .openChat(let groupIdHex):
            appState.presentChat(groupIdHex: groupIdHex)
            return .handled
        case .confirmExternal(let external):
            pendingExternalLink = PendingMessageExternalLink(url: external)
            return .handled
        case .blocked:
            return .discarded
        }
    }

    private var externalLinkConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingExternalLink != nil },
            set: { isPresented in
                if !isPresented {
                    pendingExternalLink = nil
                }
            }
        )
    }

    private var replyCardBackground: Color {
        let opacity = isFromMe
            ? MessageBubbleReplyLayout.sentCardOpacity
            : MessageBubbleReplyLayout.receivedCardOpacity
        return (isFromMe ? MessageBubblePalette.sentForeground : MessageBubblePalette.receivedForeground)
            .opacity(opacity)
    }

    @ViewBuilder
    private var bubbleMetadataRow: some View {
        if reactions.isEmpty || isDeleted {
            metadataWithoutReactions
        } else {
            reactionMetadata
        }
    }

    private var metadataWithoutReactions: some View {
        let timestampOnLeading = MessageMetadataRowArrangement.timestampOnLeadingEdge(
            isFromMe: isFromMe
        )

        return HStack(spacing: 8) {
            if timestampOnLeading {
                messageMetadataFooter
                Spacer(minLength: 8)
            } else {
                Spacer(minLength: 8)
                messageMetadataFooter
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ChatBubbleMetrics.horizontalInset)
    }

    private var reactionMetadata: some View {
        let allPills = ReactionPillPresentation.sorted(reactions)
        let pills = Array(allPills.prefix(ReactionPillPresentation.maximumRenderedPills))
        let preHiddenCount = allPills.count - pills.count
        let totalCount = allPills.reduce(0) { $0 + $1.count }
        let mine = allPills.contains(where: \.mine)

        return ReactionMetadataRowLayout(reactionsOnLeadingEdge: isFromMe) {
            Button {
                onShowReactionDetails(nil)
            } label: {
                ReactionPillLayout(preHiddenReactionCount: preHiddenCount) {
                    ForEach(Array(pills.enumerated()), id: \.element.emoji) { index, tally in
                        reactionPill(tally)
                            .layoutValue(
                                key: ReactionMetadataSubviewRoleKey.self,
                                value: .reaction(index)
                            )
                    }
                    ForEach(0...pills.count, id: \.self) { hiddenRenderedCount in
                        let hiddenCount = preHiddenCount + hiddenRenderedCount
                        if hiddenCount > 0 {
                            reactionOverflowPill(
                                hiddenCount: hiddenCount,
                                mine: allPills.suffix(hiddenCount).contains(where: \.mine)
                            )
                            .layoutValue(
                                key: ReactionMetadataSubviewRoleKey.self,
                                value: .overflow(hiddenCount)
                            )
                        }
                    }
                }
                .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("Reactions"))
            .accessibilityValue(L10n.plural("%lld reactions", Int64(totalCount)))
            .accessibilityAddTraits(mine ? .isSelected : [])

            messageMetadataFooter
        }
        .padding(.horizontal, ChatBubbleMetrics.horizontalInset)
    }

    private func reactionPill(_ tally: ConversationViewModel.ReactionTally) -> some View {
        HStack(spacing: 3) {
            Text(ContentSanitizer.reactionEmoji(tally.emoji))
                .font(.system(size: 14, weight: .bold))
            if tally.count > 1 {
                Text(L10n.formatted("%lld", Int64(tally.count)))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            tally.mine ? Color(.systemGray4) : Color(.secondarySystemBackground),
            in: Capsule()
        )
        .overlay {
            Capsule().strokeBorder(Color(.separator), lineWidth: 1)
        }
        .fixedSize()
    }

    private func reactionOverflowPill(hiddenCount: Int, mine: Bool) -> some View {
        Text("+\(hiddenCount)")
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                mine ? Color(.systemGray4) : Color(.secondarySystemBackground),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(Color(.separator), lineWidth: 1)
            }
            .fixedSize()
    }

    private var messageMetadataFooter: some View {
        MessageMetadataFooter(
            time: timeLabel,
            isEdited: isEdited && !isDeleted,
            status: status,
            isFromMe: isFromMe,
            showsDeliveryStatus: MessageTombstonePresentation.showsDeliveryStatus(isDeleted: isDeleted),
            showsExpirationTimer: hasExpirationTimer,
            onViewEditHistory: onViewEditHistory
        )
    }

    private var timeLabel: String {
        Self.timeLabel(recordedAt: record.recordedAt)
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
            MessageBubblePalette.sentBackground
        } else {
            MessageBubblePalette.receivedBackground
        }
    }

    /// Incoming bubbles use the prototype's opaque system-gray surface in both
    /// appearances. Keeping this semantic avoids a per-row appearance branch.
    static func receivedBubbleColor(dark: Bool) -> UIColor {
        .systemGray5
    }

    static func timeLabel(recordedAt: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(recordedAt))
        return RelativeTime.shortTime(date, locale: locale)
    }
}

private struct GroupMessageIdentityLane: View {
    @Environment(AppState.self) private var appState
    let accountIdHex: String
    let showsAvatar: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if showsAvatar {
                AvatarBubble(
                    seed: accountIdHex,
                    title: appState.displayName(forAccountIdHex: accountIdHex),
                    pictureURL: appState.avatarURL(forAccountIdHex: accountIdHex)
                )
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

nonisolated private enum ReactionMetadataSubviewRole: Hashable {
    case unassigned
    case reaction(Int)
    case overflow(Int)
}

nonisolated private struct ReactionMetadataSubviewRoleKey: LayoutValueKey {
    static let defaultValue = ReactionMetadataSubviewRole.unassigned
}

private struct ReactionPillLayout: Layout {
    struct Cache {
        var sizes: [CGSize]
        var reactionIndices: [Int]
        var overflowByHiddenCount: [Int: Int]
        var resolvedWidth: CGFloat? = nil
        var resolvedFit: ResolvedFit? = nil
    }

    let preHiddenReactionCount: Int

    func makeCache(subviews: Subviews) -> Cache {
        let roles = roles(in: subviews)
        return Cache(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            reactionIndices: roles.reactionIndices,
            overflowByHiddenCount: roles.overflowByHiddenCount
        )
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let roles = roles(in: subviews)
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.reactionIndices = roles.reactionIndices
        cache.overflowByHiddenCount = roles.overflowByHiddenCount
        cache.resolvedWidth = nil
        cache.resolvedFit = nil
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let naturalWidth = fitting(
            availableWidth: .greatestFiniteMagnitude,
            cache: cache
        ).requiredWidth
        let width: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            width = max(0, proposedWidth)
        } else {
            width = naturalWidth
        }
        let fit = fitting(availableWidth: width, cache: cache)
        cache.resolvedWidth = width
        cache.resolvedFit = fit
        return CGSize(width: width, height: fit.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let fit: ResolvedFit
        if cache.resolvedWidth == bounds.width, let cached = cache.resolvedFit {
            fit = cached
        } else {
            fit = fitting(availableWidth: bounds.width, cache: cache)
            cache.resolvedWidth = bounds.width
            cache.resolvedFit = fit
        }
        for index in subviews.indices where !fit.visibleIndices.contains(index) {
            subviews[index].place(
                at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY),
                anchor: .topLeading,
                proposal: .zero
            )
        }

        let reactionIndices = fit.reactionIndices
        var x = bounds.minX
        for index in reactionIndices {
            let size = cache.sizes[index]
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY - size.height / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + ReactionMetadataFitting.pillSpacing
        }
    }

    private func fitting(
        availableWidth: CGFloat,
        cache: Cache
    ) -> ResolvedFit {
        let reactionWidths = cache.reactionIndices.map { cache.sizes[$0].width }
        let overflowWidths = cache.overflowByHiddenCount.mapValues { cache.sizes[$0].width }
        let fit = ReactionMetadataFitting.fit(
            reactionWidths: reactionWidths,
            overflowWidthForHiddenCount: overflowWidths,
            footerWidth: 0,
            availableWidth: availableWidth,
            footerSpacing: 0,
            preHiddenReactionCount: preHiddenReactionCount
        )
        var reactionIndices = Array(cache.reactionIndices.prefix(fit.visibleReactionCount))
        if fit.usesOverflowPill,
           let overflowIndex = cache.overflowByHiddenCount[fit.hiddenReactionCount] {
            reactionIndices.append(overflowIndex)
        }
        let visibleIndices = Set(reactionIndices)
        let height = visibleIndices.map { cache.sizes[$0].height }.max() ?? 0
        let requiredWidth = ReactionMetadataFitting.requiredWidth(
            visibleReactionWidths: reactionIndices.map { cache.sizes[$0].width },
            overflowWidth: nil,
            footerWidth: 0,
            footerSpacing: 0
        )
        return ResolvedFit(
            reactionIndices: reactionIndices,
            visibleIndices: visibleIndices,
            height: height,
            requiredWidth: requiredWidth
        )
    }

    private func roles(in subviews: Subviews) -> (
        reactionIndices: [Int],
        overflowByHiddenCount: [Int: Int]
    ) {
        var reactions: [(position: Int, index: Int)] = []
        var overflowByHiddenCount: [Int: Int] = [:]
        for index in subviews.indices {
            switch subviews[index][ReactionMetadataSubviewRoleKey.self] {
            case .reaction(let position):
                reactions.append((position, index))
            case .overflow(let hiddenCount):
                overflowByHiddenCount[hiddenCount] = index
            case .unassigned:
                break
            }
        }
        reactions.sort { $0.position < $1.position }
        return (reactions.map(\.index), overflowByHiddenCount)
    }

    fileprivate struct ResolvedFit {
        let reactionIndices: [Int]
        let visibleIndices: Set<Int>
        let height: CGFloat
        let requiredWidth: CGFloat
    }
}

private struct ReactionMetadataRowLayout: Layout {
    struct Cache {
        var footerSize: CGSize?
        var reactionSize: CGSize?
        var resolvedWidth: CGFloat?
    }

    let reactionsOnLeadingEdge: Bool

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let footerSize = subviews[1].sizeThatFits(.unspecified)
        let idealReactionSize = subviews[0].sizeThatFits(.unspecified)
        let idealWidth = idealReactionSize.width
            + ReactionMetadataFitting.metadataSpacing
            + footerSize.width
        let width = proposal.width.map { max(0, $0) } ?? idealWidth
        let reactionWidth = max(
            0,
            width - footerSize.width - ReactionMetadataFitting.metadataSpacing
        )
        let reactionSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: reactionWidth, height: nil)
        )
        cache.footerSize = footerSize
        cache.reactionSize = reactionSize
        cache.resolvedWidth = width
        return CGSize(width: width, height: max(footerSize.height, reactionSize.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard subviews.count == 2 else { return }
        let footerSize = cache.footerSize ?? subviews[1].sizeThatFits(.unspecified)
        let reactionWidth = max(
            0,
            bounds.width - footerSize.width - ReactionMetadataFitting.metadataSpacing
        )
        let reactionSize: CGSize
        if cache.resolvedWidth == bounds.width, let cached = cache.reactionSize {
            reactionSize = cached
        } else {
            reactionSize = subviews[0].sizeThatFits(
                ProposedViewSize(width: reactionWidth, height: nil)
            )
        }
        let reactionX = reactionsOnLeadingEdge ? bounds.minX : bounds.maxX - reactionWidth
        let footerX = reactionsOnLeadingEdge ? bounds.maxX - footerSize.width : bounds.minX
        subviews[0].place(
            at: CGPoint(x: reactionX, y: bounds.midY - reactionSize.height / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: reactionWidth, height: reactionSize.height)
        )
        subviews[1].place(
            at: CGPoint(x: footerX, y: bounds.midY - footerSize.height / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(footerSize)
        )
    }
}

private struct PendingMessageExternalLink: Equatable {
    let url: URL

    var displayText: String {
        MessageExternalLinkConfirmation.displayText(for: url)
    }
}

nonisolated enum MessageExternalLinkConfirmation {
    private static let maxDisplayedHostCharacters = 96
    private static let maxDisplayedURLCharacters = 180

    static func displayText(for url: URL) -> String {
        let displayedURL = elided(ContentSanitizer.textRun(url.absoluteString), maxCharacters: maxDisplayedURLCharacters)
        if let host = hostDisplay(for: url) {
            return L10n.formatted("This link opens %@:\n%@", host, displayedURL)
        }
        return L10n.formatted("This link opens:\n%@", displayedURL)
    }

    private static func hostDisplay(for url: URL) -> String? {
        guard let rawHost = url.host(percentEncoded: false), !rawHost.isEmpty else {
            return nil
        }

        let sanitizedHost = ContentSanitizer.textRun(rawHost)

        // Hosts wider than the display cap are peer-controlled (autolinks in
        // received markdown) and are elided away anyway, so never feed an
        // over-long string to the punycode decoder. `decodePunycodeLabel`
        // grows its output with O(n) `Array.insert(_:at:)` calls, so decoding
        // a multi-thousand-character `xn--` label is O(L²) work on the
        // MainActor at tap time. Bounding the input before decode keeps that
        // cost proportional to what we can actually show.
        guard sanitizedHost.count <= maxDisplayedHostCharacters else {
            return elided(sanitizedHost, maxCharacters: maxDisplayedHostCharacters)
        }

        let decoded = decodedInternationalizedHost(sanitizedHost)
        let primary = elided(decoded.host, maxCharacters: maxDisplayedHostCharacters)
        guard decoded.isInternationalized else { return primary }

        let raw = elided(sanitizedHost, maxCharacters: maxDisplayedHostCharacters)
        if raw.caseInsensitiveCompare(decoded.host) == .orderedSame {
            return L10n.formatted("%@ (IDN/punycode)", primary)
        }
        return L10n.formatted("%@ (IDN/punycode: %@)", primary, raw)
    }

    private static func decodedInternationalizedHost(_ host: String) -> (host: String, isInternationalized: Bool) {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        var decodedLabels: [String] = []
        var isInternationalized = host.unicodeScalars.contains { $0.value > 0x7f }

        for label in labels {
            let labelString = String(label)
            if labelString.lowercased().hasPrefix("xn--") {
                isInternationalized = true
                if let decoded = decodePunycodeLabel(String(labelString.dropFirst(4))) {
                    decodedLabels.append(decoded)
                } else {
                    decodedLabels.append(labelString)
                }
            } else {
                decodedLabels.append(labelString)
            }
        }

        // `decodePunycodeLabel` can emit bidi/control/invisible-format scalars
        // (e.g. U+202E RLO from `xn--paypal-dm0c`), which would visually reorder
        // the host shown in the confirmation alert. The host string was
        // sanitized *before* decode, so re-strip the decoder output with the
        // stricter relay/URL display policy before it is rendered. If nothing
        // renderable survives, fall back to the raw (already-sanitized) host.
        let joined = decodedLabels.joined(separator: ".")
        let safe = ContentSanitizer.relayDisplayLine(joined, maxLength: joined.count) ?? host
        return (safe, isInternationalized)
    }

    private static func elided(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters, maxCharacters > 8 else { return text }
        let prefixCount = maxCharacters / 2
        let suffixCount = maxCharacters - prefixCount - 1
        return "\(text.prefix(prefixCount))…\(text.suffix(suffixCount))"
    }

    private static func decodePunycodeLabel(_ input: String) -> String? {
        let scalars = Array(input.unicodeScalars)
        var output: [UInt32] = []
        var index = 0

        if let delimiterIndex = scalars.lastIndex(where: { $0 == "-" }) {
            for scalar in scalars[..<delimiterIndex] {
                guard scalar.value < 0x80 else { return nil }
                output.append(scalar.value)
            }
            index = delimiterIndex + 1
        }

        var n = 128
        var i = 0
        var bias = 72

        while index < scalars.count {
            let oldi = i
            var w = 1
            var k = 36

            while true {
                guard index < scalars.count,
                      let digit = punycodeDigitValue(scalars[index])
                else { return nil }
                index += 1
                guard digit <= (Int.max - i) / w else { return nil }
                i += digit * w

                let t: Int
                if k <= bias {
                    t = 1
                } else if k >= bias + 26 {
                    t = 26
                } else {
                    t = k - bias
                }

                if digit < t { break }
                guard w <= Int.max / (36 - t) else { return nil }
                w *= 36 - t
                k += 36
            }

            let outputCount = output.count + 1
            // Defense in depth against quadratic decode cost: each
            // `output.insert(_:at:)` below shifts O(output.count) elements, so
            // an over-long `xn--` label would be O(L²). Callers already cap the
            // host length, but the decoder must not trust that, so bail to the
            // raw label once the decoded output exceeds what we can display.
            guard outputCount <= maxDisplayedHostCharacters else { return nil }
            bias = adaptPunycodeBias(delta: i - oldi, numPoints: outputCount, firstTime: oldi == 0)
            let (newN, overflowed) = n.addingReportingOverflow(i / outputCount)
            guard !overflowed else { return nil }
            n = newN
            let insertionIndex = i % outputCount
            guard let scalar = UnicodeScalar(n) else { return nil }
            output.insert(scalar.value, at: insertionIndex)
            i = insertionIndex + 1
        }

        var view = String.UnicodeScalarView()
        for value in output {
            guard let scalar = UnicodeScalar(value) else { return nil }
            view.append(scalar)
        }
        return String(view)
    }

    private static func punycodeDigitValue(_ scalar: UnicodeScalar) -> Int? {
        switch scalar.value {
        case 48...57: Int(scalar.value - 22) // 0...9 => 26...35
        case 65...90: Int(scalar.value - 65)
        case 97...122: Int(scalar.value - 97)
        default: nil
        }
    }

    private static func adaptPunycodeBias(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / 700 : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((36 - 1) * 26) / 2 {
            delta /= 36 - 1
            k += 36
        }
        return k + (((36 - 1 + 1) * delta) / (delta + 38))
    }
}

/// A cell in the visual grid. A staged GIF is a remote URL rather than an
/// encrypted attachment, so the grid holds both shapes.
private enum MessageVisualCell {
    case giphy(RemoteGiphyMedia)
    case media(MessageMediaAttachment)
}

private struct MessageMediaGrid: View {
    let cells: [MessageVisualCell]
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void
    var onOpenGiphy: ((RemoteGiphyMedia) -> Void)?

    private let cornerRadius: CGFloat = 12

    private var visibleCells: [MessageVisualCell] {
        Array(cells.prefix(MessageMediaGridPresentation.visibleCount(totalCount: cells.count)))
    }

    private var layout: MessageMediaGridLayout {
        MessageMediaGridPresentation.layout(totalCount: cells.count, maxWidth: maxWidth)
    }

    var body: some View {
        let resolvedLayout = layout
        let resolvedCells = visibleCells
        ZStack(alignment: .topLeading) {
            ForEach(Array(resolvedLayout.frames.enumerated()), id: \.offset) { index, frame in
                if index < resolvedCells.count {
                    tile(
                        cell: resolvedCells[index],
                        size: frame.size,
                        hiddenCount: index == resolvedCells.count - 1
                            ? resolvedLayout.overflowCount
                            : 0
                    )
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: resolvedLayout.size.width, height: resolvedLayout.size.height, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private func tile(
        cell: MessageVisualCell,
        size: CGSize,
        hiddenCount: Int
    ) -> some View {
        switch cell {
        case .giphy(let media):
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: isFromMe,
                layout: .gridCell(size),
                onOpenFullscreen: onOpenGiphy.map { open in { open(media) } }
            )
        case .media(let item):
            MessageMediaTile(
                item: item,
                isFromMe: isFromMe,
                size: size,
                hiddenCount: hiddenCount,
                onLoadMedia: onLoadMedia,
                onOpenImage: onOpenImage,
                onOpenVideo: onOpenVideo
            )
        }
    }
}

private struct MessageMediaTileCornerClip: ViewModifier {
    let corners: MessageMediaTileCornerRadii
    let radius: CGFloat

    @Environment(\.layoutDirection) private var layoutDirection

    @ViewBuilder
    func body(content: Content) -> some View {
        if corners.hasRoundedCorners {
            content.clipShape(MessageMediaRoundedTileShape(
                corners: corners,
                radius: radius,
                layoutDirection: layoutDirection
            ))
        } else {
            content
        }
    }
}

private extension View {
    func messageMediaTileCornerClip(_ corners: MessageMediaTileCornerRadii, radius: CGFloat) -> some View {
        modifier(MessageMediaTileCornerClip(corners: corners, radius: radius))
    }
}

private struct MessageMediaRoundedTileShape: Shape {
    let corners: MessageMediaTileCornerRadii
    let radius: CGFloat
    let layoutDirection: LayoutDirection

    func path(in rect: CGRect) -> Path {
        let roundedCorners = corners.uiRectCorners(layoutDirection: layoutDirection)
        guard !roundedCorners.isEmpty else { return Path(rect) }

        let boundedRadius = min(max(0, radius), rect.width / 2, rect.height / 2)
        return Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: roundedCorners,
            cornerRadii: CGSize(width: boundedRadius, height: boundedRadius)
        ).cgPath)
    }
}

private struct MessageMediaAttachmentContent: View {
    let items: [MessageMediaAttachment]
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    private var usesVisualGrid: Bool {
        !items.isEmpty && items.allSatisfy { $0.isImage || $0.isVideo }
    }

    private var singleVideo: MessageMediaAttachment? {
        items.count == 1 && items[0].isVideo ? items[0] : nil
    }

    private var singleImage: MessageMediaAttachment? {
        items.count == 1 && items[0].isImage ? items[0] : nil
    }

    var body: some View {
        if let singleImage {
            MessageSingleImageBubble(
                item: singleImage,
                isFromMe: isFromMe,
                maxWidth: maxWidth,
                onLoadMedia: onLoadMedia,
                onOpenImage: onOpenImage,
                onOpenVideo: onOpenVideo
            )
        } else if let singleVideo {
            MessageSingleVideoBubble(
                item: singleVideo,
                isFromMe: isFromMe,
                maxWidth: maxWidth,
                onLoadMedia: onLoadMedia
            )
        } else if usesVisualGrid {
            MessageMediaGrid(
                cells: items.map(MessageVisualCell.media),
                isFromMe: isFromMe,
                maxWidth: maxWidth,
                onLoadMedia: onLoadMedia,
                onOpenImage: onOpenImage,
                onOpenVideo: onOpenVideo
            )
        } else {
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 6) {
                ForEach(items) { item in
                    switch item.kind {
                    case .image:
                        MessageMediaTile(
                            item: item,
                            isFromMe: isFromMe,
                            size: MessageImageBubblePresentation.displaySize(maxWidth: maxWidth, dim: item.dim),
                            hiddenCount: 0,
                            onLoadMedia: onLoadMedia,
                            onOpenImage: onOpenImage,
                            onOpenVideo: onOpenVideo
                        )
                        .clipShape(.rect(cornerRadius: 12))
                    case .video:
                        MessageSingleVideoBubble(
                            item: item,
                            isFromMe: isFromMe,
                            maxWidth: maxWidth,
                            onLoadMedia: onLoadMedia
                        )
                    case .audio:
                        MessageAudioAttachmentView(
                            item: item,
                            isFromMe: isFromMe,
                            width: maxWidth,
                            onLoadMedia: onLoadMedia
                        )
                    case .document, .unsupported:
                        MessageDocumentAttachmentView(
                            item: item,
                            isFromMe: isFromMe,
                            width: maxWidth,
                            onLoadMedia: onLoadMedia
                        )
                    }
                }
            }
            .frame(width: maxWidth, alignment: isFromMe ? .trailing : .leading)
        }
    }
}

private struct MessageSingleImageBubble: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    private let cornerRadius: CGFloat = 12

    private var size: CGSize {
        MessageImageBubblePresentation.displaySize(maxWidth: maxWidth, dim: item.dim)
    }

    var body: some View {
        MessageMediaTile(
            item: item,
            isFromMe: isFromMe,
            size: size,
            hiddenCount: 0,
            onLoadMedia: onLoadMedia,
            onOpenImage: onOpenImage,
            onOpenVideo: onOpenVideo
        )
        .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

private struct MessageSingleVideoBubble: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader

    private let cornerRadius: CGFloat = 12

    private var size: CGSize {
        MessageVideoBubblePresentation.displaySize(maxWidth: maxWidth, dim: item.dim)
    }

    var body: some View {
        MessageVideoAttachmentView(
            item: item,
            isFromMe: isFromMe,
            width: size.width,
            height: size.height,
            onLoadMedia: onLoadMedia,
            onOpenFullscreen: nil
        )
        .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

nonisolated struct MessageMediaTileCornerRadii: Equatable, Sendable {
    let topLeading: Bool
    let topTrailing: Bool
    let bottomLeading: Bool
    let bottomTrailing: Bool

    static let none = MessageMediaTileCornerRadii(
        topLeading: false,
        topTrailing: false,
        bottomLeading: false,
        bottomTrailing: false
    )

    var hasRoundedCorners: Bool {
        topLeading || topTrailing || bottomLeading || bottomTrailing
    }

    func uiRectCorners(layoutDirection: LayoutDirection) -> UIRectCorner {
        var roundedCorners: UIRectCorner = []
        let isRightToLeft = layoutDirection == .rightToLeft

        if topLeading { roundedCorners.insert(isRightToLeft ? .topRight : .topLeft) }
        if topTrailing { roundedCorners.insert(isRightToLeft ? .topLeft : .topRight) }
        if bottomLeading { roundedCorners.insert(isRightToLeft ? .bottomRight : .bottomLeft) }
        if bottomTrailing { roundedCorners.insert(isRightToLeft ? .bottomLeft : .bottomRight) }

        return roundedCorners
    }
}

nonisolated struct MessageMediaGridLayout: Equatable {
    let size: CGSize
    let frames: [CGRect]
    let overflowCount: Int
}

enum MessageMediaGridPresentation {
    static let maxVisibleItems = 5
    private static let referenceWidth: CGFloat = 256

    static func visibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), maxVisibleItems)
    }

    static func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - maxVisibleItems)
    }

    static func layout(totalCount: Int, maxWidth: CGFloat) -> MessageMediaGridLayout {
        let count = max(0, totalCount)
        let width = max(1, maxWidth)
        let scale = width / referenceWidth
        let referenceFrames: [CGRect]
        let referenceHeight: CGFloat

        switch count {
        case 0:
            referenceHeight = 0
            referenceFrames = []
        case 1:
            referenceHeight = referenceWidth
            referenceFrames = [CGRect(x: 0, y: 0, width: 256, height: 256)]
        case 2:
            referenceHeight = 127
            referenceFrames = [
                CGRect(x: 0, y: 0, width: 127, height: 127),
                CGRect(x: 129, y: 0, width: 127, height: 127),
            ]
        case 3:
            referenceHeight = 170
            referenceFrames = [
                CGRect(x: 0, y: 0, width: 170, height: 170),
                CGRect(x: 172, y: 0, width: 84, height: 84),
                CGRect(x: 172, y: 86, width: 84, height: 84),
            ]
        case 4:
            referenceHeight = 256
            referenceFrames = [
                CGRect(x: 0, y: 0, width: 127, height: 127),
                CGRect(x: 129, y: 0, width: 127, height: 127),
                CGRect(x: 0, y: 129, width: 127, height: 127),
                CGRect(x: 129, y: 129, width: 127, height: 127),
            ]
        default:
            referenceHeight = 213
            referenceFrames = [
                CGRect(x: 0, y: 0, width: 127, height: 127),
                CGRect(x: 129, y: 0, width: 127, height: 127),
                CGRect(x: 0, y: 129, width: 84, height: 84),
                CGRect(x: 86, y: 129, width: 84, height: 84),
                CGRect(x: 172, y: 129, width: 84, height: 84),
            ]
        }

        return MessageMediaGridLayout(
            size: CGSize(width: count == 0 ? 0 : width, height: referenceHeight * scale),
            frames: referenceFrames.map { frame in
                CGRect(
                    x: frame.minX * scale,
                    y: frame.minY * scale,
                    width: frame.width * scale,
                    height: frame.height * scale
                )
            },
            overflowCount: hiddenCount(totalCount: count)
        )
    }

    static func columnCount(totalCount: Int) -> Int {
        totalCount <= 1 ? 1 : 2
    }

    static func rowCount(totalCount: Int) -> Int {
        let visible = visibleCount(totalCount: totalCount)
        let columns = columnCount(totalCount: totalCount)
        guard visible > 0 else { return 0 }
        return Int(ceil(Double(visible) / Double(columns)))
    }

    static func roundedCorners(totalCount: Int, tileIndex: Int) -> MessageMediaTileCornerRadii {
        let visibleCount = visibleCount(totalCount: totalCount)
        guard tileIndex >= 0, tileIndex < visibleCount else { return .none }

        let columns = columnCount(totalCount: totalCount)
        let rows = rowCount(totalCount: totalCount)
        let row = tileIndex / columns
        let column = tileIndex % columns

        let lastRowItemCount = visibleCount - ((rows - 1) * columns)
        let isOnlyItemInLastRow = row == rows - 1 && lastRowItemCount == 1
        return MessageMediaTileCornerRadii(
            topLeading: row == 0 && column == 0,
            topTrailing: row == 0 && column == columns - 1,
            bottomLeading: row == rows - 1 && column == 0,
            bottomTrailing: row == rows - 1 && (column == columns - 1 || isOnlyItemInLastRow)
        )
    }
}

nonisolated private enum MessageVisualMediaBubblePresentation {
    private static let maximumHeightRatio: CGFloat = 1.35

    static func aspectRatio(dim: String?, fallback: CGFloat) -> CGFloat {
        guard let dim else { return fallback }
        let parts = dim
            .lowercased()
            .split(separator: "x", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0
        else {
            return fallback
        }
        let aspectRatio = CGFloat(width / height)
        guard aspectRatio.isFinite else { return fallback }
        return min(4, max(0.25, aspectRatio))
    }

    static func displaySize(maxWidth: CGFloat, dim: String?, fallback: CGFloat) -> CGSize {
        let boundedMaxWidth = max(1, maxWidth)
        let aspectRatio = aspectRatio(dim: dim, fallback: fallback)
        if aspectRatio >= 1 {
            return roundedSize(width: boundedMaxWidth, height: boundedMaxWidth / aspectRatio)
        }

        let maxHeight = boundedMaxWidth * maximumHeightRatio
        let height = min(boundedMaxWidth / aspectRatio, maxHeight)
        return roundedSize(width: min(boundedMaxWidth, height * aspectRatio), height: height)
    }

    private static func roundedSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(
            width: max(1, width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, height.rounded(.toNearestOrAwayFromZero))
        )
    }
}

nonisolated enum MessageImageBubblePresentation {
    static func aspectRatio(dim: String?) -> CGFloat {
        MessageVisualMediaBubblePresentation.aspectRatio(dim: dim, fallback: 1)
    }

    static func displaySize(maxWidth: CGFloat, dim: String?) -> CGSize {
        MessageVisualMediaBubblePresentation.displaySize(maxWidth: maxWidth, dim: dim, fallback: 1)
    }
}

nonisolated enum MessageVideoBubblePresentation {
    private static let fallbackAspectRatio: CGFloat = 16.0 / 9.0
    static let fullscreenButtonSize: CGFloat = 36
    static let fullscreenButtonIconSize: CGFloat = 15
    static let fullscreenButtonInset: CGFloat = 8

    static func aspectRatio(dim: String?) -> CGFloat {
        MessageVisualMediaBubblePresentation.aspectRatio(dim: dim, fallback: fallbackAspectRatio)
    }

    static func displaySize(maxWidth: CGFloat, dim: String?) -> CGSize {
        MessageVisualMediaBubblePresentation.displaySize(
            maxWidth: maxWidth,
            dim: dim,
            fallback: fallbackAspectRatio
        )
    }
}

nonisolated enum MessageVideoThumbnailPresentation {
    static func cacheKey(for item: MessageMediaAttachment) -> String {
        if let hash = item.reference?.plaintextSha256.lowercased(),
           hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        {
            return "sha256:\(hash)"
        }
        return "item:\(item.id)"
    }
}

nonisolated enum MessageMediaThumbnailPresentation {
    static func cacheKey(for item: MessageMediaAttachment) -> String {
        if let hash = item.reference?.plaintextSha256.lowercased(),
           hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        {
            return "sha256:\(hash)"
        }
        return "item:\(item.id)"
    }
}

nonisolated enum MessageAudioBubblePresentation {
    static func playbackIconName(isPlaying: Bool, didFail: Bool) -> String {
        if isPlaying { return "pause.fill" }
        if didFail { return "arrow.clockwise" }
        return "play.fill"
    }

    static func cacheKey(for item: MessageMediaAttachment) -> String {
        if let hash = item.reference?.plaintextSha256.lowercased(),
           hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        {
            return "sha256:\(hash)"
        }
        return "item:\(item.id)"
    }

    static func durationLabel(_ duration: Double?) -> String? {
        AudioDurationLabel.optionalLabel(for: duration)
    }
}

private struct MessageFullscreenVideo: Identifiable {
    let id: String
    let item: MessageMediaAttachment
    let url: URL
}

private struct MessageMediaTile: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let size: CGSize
    let hiddenCount: Int
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible
    @State private var image: UIImage?
    @State private var loadedImageID: String?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var awaitingManualDownload = false

    private var thumbnailCacheKey: String {
        MessageMediaThumbnailPresentation.cacheKey(for: item)
    }

    var body: some View {
        ZStack {
            if item.isImage, loadedImageID == item.id, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else if item.isImage {
                imagePlaceholder
            } else if item.isVideo {
                MessageVideoAttachmentView(
                    item: item,
                    isFromMe: isFromMe,
                    width: size.width,
                    height: size.height,
                    onLoadMedia: onLoadMedia,
                    onOpenFullscreen: {
                        onOpenVideo(item)
                    }
                )
            } else {
                filePlaceholder
            }

            if hiddenCount > 0 {
                Color.black.opacity(0.48)
                Text(L10n.formatted("+%lld", Int64(hiddenCount)))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }

            if awaitingManualDownload {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .accessibilityLabel(L10n.string("Tap to download"))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .task(id: TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible)) {
            guard isTimelineRowVisible else { return }
            // The auto-download policy gates only the automatic fetch: a
            // cached thumbnail always renders, and a tap always downloads.
            let maxPixelSize = max(1, Int(ceil(max(size.width, size.height) * displayScale)))
            if item.isImage,
               MessageMediaThumbnailDecoder.cachedThumbnail(for: thumbnailCacheKey, maxPixelSize: maxPixelSize) == nil,
               !MediaAutoDownloadStore.shared.shouldAutoDownload(.image) {
                awaitingManualDownload = true
                return
            }
            awaitingManualDownload = false
            _ = await loadImageIfNeeded(scale: displayScale)
        }
        .onTapGesture {
            if awaitingManualDownload {
                awaitingManualDownload = false
                Task { _ = await loadImageIfNeeded(scale: displayScale, force: true) }
                return
            }
            guard item.isImage else { return }
            if didFail {
                Task { await loadImageIfNeeded(scale: displayScale, force: true) }
            } else {
                Task {
                    if let data = await loadImageIfNeeded(scale: displayScale) {
                        onOpenImage(item, data)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private var imagePlaceholder: some View {
        ZStack {
            MessageMediaPlaceholderBackground(
                thumbhash: item.reference?.thumbhash,
                fallbackSystemName: isLoading || didFail ? nil : "photo",
                width: size.width,
                height: size.height
            )
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

    private func loadImageIfNeeded(scale: CGFloat, force: Bool = false) async -> Data? {
        guard item.isImage else { return nil }
        let maxPixelSize = max(1, Int(ceil(max(size.width, size.height) * scale)))
        if !force {
            if let cachedThumbnail = MessageMediaThumbnailDecoder.cachedThumbnail(
                for: thumbnailCacheKey,
                maxPixelSize: maxPixelSize
            ) {
                image = cachedThumbnail.image
                loadedImageID = item.id
                didFail = false
                return cachedThumbnail.sourceData
            }
        }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            guard !Task.isCancelled else { return nil }
            guard let decoded = await MessageMediaThumbnailDecoder.image(
                data: data,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) else {
                image = nil
                loadedImageID = item.id
                didFail = true
                return nil
            }
            image = decoded
            loadedImageID = item.id
            MessageMediaThumbnailDecoder.store(
                decoded,
                sourceData: data,
                for: thumbnailCacheKey,
                maxPixelSize: maxPixelSize
            )
            return data
        } catch {
            image = nil
            loadedImageID = item.id
            didFail = true
            return nil
        }
    }
}

private struct MessageMediaPlaceholderBackground: View {
    let thumbhash: String?
    let fallbackSystemName: String?
    let width: CGFloat
    let height: CGFloat

    @State private var image: UIImage?
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if let fallbackSystemName {
                Image(systemName: fallbackSystemName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .task(id: TimelineMediaTaskID(
            contentID: thumbhash ?? "",
            isVisible: isTimelineRowVisible
        )) {
            image = nil
            guard isTimelineRowVisible, let thumbhash else { return }
            let decoded = await ThumbHashImageCache.shared.image(for: thumbhash)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

/// Compact, non-interactive media identity for a quoted message. It reuses the
/// same bounded thumbnail caches and conversation media loader as the full row,
/// so a reply never introduces a second decrypt/download path.
private struct MessageReplyMediaThumbnail: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let onLoadMedia: ConversationMediaLoader

    @Environment(\.displayScale) private var displayScale
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible
    @State private var image: UIImage?
    @State private var loadedItemID: String?

    private let side: CGFloat = 38

    var body: some View {
        ZStack {
            if loadedItemID == item.id, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if item.isImage || item.isVideo {
                MessageMediaPlaceholderBackground(
                    thumbhash: item.reference?.thumbhash,
                    fallbackSystemName: item.isVideo ? "play.rectangle" : "photo",
                    width: side,
                    height: side
                )
            } else {
                Color.primary.opacity(isFromMe ? 0.10 : 0.08)
                Image(systemName: item.isAudio ? "waveform" : "doc.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : Color.secondary)
            }

            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .task(id: TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible)) {
            guard isTimelineRowVisible else { return }
            await loadThumbnailIfAllowed()
        }
        .accessibilityHidden(true)
    }

    private func loadThumbnailIfAllowed() async {
        loadedItemID = nil
        image = nil

        if let thumbnail = item.thumbnail {
            image = thumbnail
            loadedItemID = item.id
            return
        }

        let maxPixelSize = max(1, Int(ceil(side * displayScale)))
        if item.isImage {
            let cacheKey = MessageMediaThumbnailPresentation.cacheKey(for: item)
            if let cached = MessageMediaThumbnailDecoder.cachedThumbnail(
                for: cacheKey,
                maxPixelSize: maxPixelSize
            ) {
                image = cached.image
                loadedItemID = item.id
                return
            }
            guard MediaAutoDownloadStore.shared.shouldAutoDownload(.image) else { return }
            guard let data = await mediaData() else { return }
            guard let thumbnail = await MessageMediaThumbnailDecoder.image(
                data: data,
                maxPixelSize: maxPixelSize,
                scale: displayScale
            ), !Task.isCancelled else { return }
            MessageMediaThumbnailDecoder.store(
                thumbnail,
                sourceData: data,
                for: cacheKey,
                maxPixelSize: maxPixelSize
            )
            image = thumbnail
            loadedItemID = item.id
            return
        }

        guard item.isVideo else { return }
        let cacheKey = MessageVideoThumbnailPresentation.cacheKey(for: item)
        if let cached = MessageVideoThumbnailDecoder.cachedThumbnail(
            for: cacheKey,
            maxPixelSize: maxPixelSize
        ) {
            image = cached
            loadedItemID = item.id
            return
        }
        guard MediaAutoDownloadStore.shared.shouldAutoDownload(.video) else { return }
        guard let data = await mediaData() else { return }
        let producerEpoch = MessageMediaCache.currentProducerEpoch()
        guard let url = await MediaPlaybackFileStore.fileURL(
            for: item,
            data: data,
            producerEpoch: producerEpoch
        ), !Task.isCancelled else { return }
        guard let thumbnail = await MessageVideoThumbnailDecoder.thumbnail(
            url: url,
            maxPixelSize: maxPixelSize,
            scale: displayScale
        ), !Task.isCancelled else { return }
        MessageVideoThumbnailDecoder.store(
            thumbnail,
            for: cacheKey,
            maxPixelSize: maxPixelSize
        )
        image = thumbnail
        loadedItemID = item.id
    }

    private func mediaData() async -> Data? {
        if let localData = item.localData { return localData }
        return try? await onLoadMedia.data(for: item)
    }
}

/// Drives an `AVAudioSession` `.playback` lease from an externally-controlled
/// `AVPlayer`'s `timeControlStatus`. `VideoPlayer` exposes system transport
/// controls, so the user can pause/resume (and the item can reach its end)
/// without routing through our view code. Observing `timeControlStatus` keeps
/// the lease held only while the player is actually playing and releases it the
/// moment playback pauses or finishes, mirroring how the audio attachment view
/// releases its lease on pause / end-of-playback.
@MainActor
private final class ObservableVideoPlaybackAudioSession {
    private weak var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var lease: VoiceAudioSession.Lease?

    /// Begins observing `player`'s play/pause transitions and syncs the lease to
    /// the current status immediately. Safe to call repeatedly; re-attaching to a
    /// new player tears down any prior observation and releases the held lease.
    func attach(to player: AVPlayer) {
        guard self.player !== player else {
            sync(to: player.timeControlStatus)
            return
        }
        stop()
        self.player = player
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            // Apple does not guarantee KVO callbacks arrive on the main thread,
            // so hop to the MainActor explicitly rather than asserting isolation.
            // Re-read the player's `timeControlStatus` inside the hop from the
            // MainActor-isolated stored reference (avoids capturing the
            // non-Sendable AVPlayer) so the lease converges toward the player's
            // latest state even if hops coalesce or reorder.
            guard let self else { return }
            Task { @MainActor in
                guard let player = self.player else { return }
                self.sync(to: player.timeControlStatus)
            }
        }
    }

    /// Stops observing and releases the audio session lease. Called from the
    /// owning view's teardown points (`onDisappear`, item change, fullscreen
    /// handoff) before the view storage releases this object.
    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
        release()
    }

    private func sync(to status: AVPlayer.TimeControlStatus) {
        switch VideoPlaybackLeaseAction.resolve(status: status, hasLease: lease != nil) {
        case .acquire:
            lease = try? VoiceAudioSession.configureForVideoPlayback()
        case .release:
            release()
        case .none:
            break
        }
    }

    private func release() {
        VoiceAudioSession.deactivate(lease)
        lease = nil
    }
}

/// Pure decision for how a video playback audio-session lease should respond to
/// an `AVPlayer.timeControlStatus` change. Extracted so the release-on-pause /
/// release-on-end behavior is unit-testable without a live `AVPlayer`.
nonisolated enum VideoPlaybackLeaseAction: Equatable {
    case acquire
    case release
    case none

    static func resolve(status: AVPlayer.TimeControlStatus, hasLease: Bool) -> VideoPlaybackLeaseAction {
        switch status {
        case .playing:
            // Only acquire when we don't already hold a lease, so repeated
            // `.playing` notifications don't stack redundant leases.
            return hasLease ? .none : .acquire
        case .paused:
            // Covers user pause via the system transport control and reaching
            // end-of-item, both of which leave the player in `.paused`. Release
            // only when a lease is actually held.
            return hasLease ? .release : .none
        case .waitingToPlayAtSpecifiedRate:
            // Buffering/stalling while still intending to play; keep the lease.
            return .none
        @unknown default:
            return .none
        }
    }
}

/// Pure decision for whether a received-audio bubble's in-flight load+play task
/// should proceed to start playback after an `await`, or abort. Extracted so the
/// "don't start playback (or acquire the audio-session lease) once the view has
/// disappeared and the task was cancelled" behavior is unit-testable without a
/// live SwiftUI view or `AVAudioPlayer`.
nonisolated enum AudioPlaybackLoadOutcome: Equatable {
    case proceed
    case abort

    static func resolve(isCancelled: Bool) -> AudioPlaybackLoadOutcome {
        isCancelled ? .abort : .proceed
    }
}

private struct MessageVideoAttachmentView: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let width: CGFloat
    let height: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenFullscreen: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var playbackURL: URL?
    @State private var audioSession = ObservableVideoPlaybackAudioSession()
    @State private var previewThumbnail: UIImage?
    @State private var fullscreenVideo: MessageFullscreenVideo?
    @State private var isLoading = false
    @State private var isLoadingFullscreen = false
    @State private var didFail = false

    @Environment(\.displayScale) private var displayScale
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible

    private var overlayDiameter: CGFloat {
        VideoPreviewOverlayPresentation.diameter(for: CGSize(width: width, height: height))
    }

    private func maxThumbnailPixelSize(scale: CGFloat) -> Int {
        max(1, Int(ceil(max(width, height) * scale)))
    }

    private var thumbnailCacheKey: String {
        MessageVideoThumbnailPresentation.cacheKey(for: item)
    }

    private var displayThumbnail: UIImage? {
        item.thumbnail
            ?? previewThumbnail
            ?? MessageVideoThumbnailDecoder.cachedThumbnail(
                for: thumbnailCacheKey,
                maxPixelSize: maxThumbnailPixelSize(scale: displayScale)
            )
    }

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: width, height: height)
                    .background(Color.black)
            } else if let thumbnail = displayThumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                videoPlaceholder
            }

            if player == nil {
                if isLoading {
                    ProgressView()
                        .controlSize(
                            overlayDiameter >= VideoPreviewOverlayPresentation.regularDiameter ? .regular : .small
                        )
                        .tint(.white)
                        .frame(width: overlayDiameter, height: overlayDiameter)
                        .background(Color.black.opacity(0.5), in: Circle())
                } else {
                    VideoPreviewPlayOverlay(
                        systemName: didFail ? "arrow.clockwise" : "play.fill",
                        diameter: overlayDiameter
                    )
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        if let onOpenFullscreen {
                            player?.pause()
                            audioSession.stop()
                            onOpenFullscreen()
                        } else {
                            Task { await openFullscreen(scale: displayScale) }
                        }
                    } label: {
                        Group {
                            if isLoadingFullscreen && onOpenFullscreen == nil {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(
                                        size: MessageVideoBubblePresentation.fullscreenButtonIconSize,
                                        weight: .bold
                                    ))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(
                            width: MessageVideoBubblePresentation.fullscreenButtonSize,
                            height: MessageVideoBubblePresentation.fullscreenButtonSize
                        )
                        .background(Color.black.opacity(0.48), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onOpenFullscreen == nil && isLoadingFullscreen)
                    .accessibilityLabel(
                        onOpenFullscreen == nil
                            ? L10n.string("Open video fullscreen")
                            : L10n.string("Open media gallery")
                    )
                }
                Spacer()
            }
            .padding(MessageVideoBubblePresentation.fullscreenButtonInset)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await loadAndPlay(scale: displayScale) }
        }
        .task(id: TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible)) {
            guard isTimelineRowVisible else { return }
            // Auto-download per the Videos matrix row: fetch, cache, and
            // render the poster so the bubble shows the download happened;
            // playback stays tap-driven.
            guard player == nil, previewThumbnail == nil, !isLoading,
                  MediaAutoDownloadStore.shared.shouldAutoDownload(.video),
                  MediaPrefetchRegistry.claim(item.id)
            else { return }
            do {
                let url = try await playbackFileURL()
                await loadPreviewThumbnail(from: url, scale: displayScale)
            } catch {
                MediaPrefetchRegistry.release(item.id)
            }
        }
        .onChange(of: isTimelineRowVisible) { _, isVisible in
            guard !isVisible else { return }
            player?.pause()
            audioSession.stop()
            player = nil
        }
        .onChange(of: item.id) { _, _ in
            player?.pause()
            audioSession.stop()
            player = nil
            playbackURL = nil
            previewThumbnail = nil
            fullscreenVideo = nil
            isLoading = false
            isLoadingFullscreen = false
            didFail = false
        }
        .onDisappear {
            player?.pause()
            audioSession.stop()
        }
        .fullScreenCover(item: $fullscreenVideo) { video in
            MessageFullscreenVideoPlayerView(video: video) {
                fullscreenVideo = nil
            }
        }
        .accessibilityLabel("Video attachment")
    }

    private var videoPlaceholder: some View {
        MessageMediaPlaceholderBackground(
            thumbhash: item.reference?.thumbhash,
            fallbackSystemName: "play.rectangle",
            width: width,
            height: height
        )
    }

    private func loadAndPlay(scale: CGFloat) async {
        if let player {
            player.play()
            audioSession.attach(to: player)
            return
        }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let url = try await playbackFileURL()
            await loadPreviewThumbnail(from: url, scale: scale)
            let next = AVPlayer(url: url)
            player = next
            next.play()
            audioSession.attach(to: next)
        } catch {
            didFail = true
        }
    }

    private func openFullscreen(scale: CGFloat) async {
        player?.pause()
        audioSession.stop()
        if let playbackURL {
            fullscreenVideo = MessageFullscreenVideo(id: item.id, item: item, url: playbackURL)
            return
        }

        isLoadingFullscreen = true
        didFail = false
        defer { isLoadingFullscreen = false }
        do {
            let url = try await playbackFileURL()
            await loadPreviewThumbnail(from: url, scale: scale)
            fullscreenVideo = MessageFullscreenVideo(id: item.id, item: item, url: url)
        } catch {
            didFail = true
        }
    }

    private func playbackFileURL() async throws -> URL {
        if let playbackURL {
            return playbackURL
        }
        let producerEpoch = MessageMediaCache.currentProducerEpoch()
        let data = try await onLoadMedia.data(for: item)
        guard let url = await MediaPlaybackFileStore.fileURL(for: item, data: data, producerEpoch: producerEpoch) else {
            throw MessageVideoAttachmentError.playbackFileUnavailable
        }
        playbackURL = url
        return url
    }

    private func loadPreviewThumbnail(from url: URL, scale: CGFloat) async {
        guard item.thumbnail == nil, previewThumbnail == nil else { return }
        if let cached = MessageVideoThumbnailDecoder.cachedThumbnail(
            for: thumbnailCacheKey,
            maxPixelSize: maxThumbnailPixelSize(scale: scale)
        ) {
            previewThumbnail = cached
            return
        }
        guard let thumbnail = await MessageVideoThumbnailDecoder.thumbnail(
            url: url,
            maxPixelSize: maxThumbnailPixelSize(scale: scale),
            scale: scale
        ) else {
            return
        }
        previewThumbnail = thumbnail
        MessageVideoThumbnailDecoder.store(
            thumbnail,
            for: thumbnailCacheKey,
            maxPixelSize: maxThumbnailPixelSize(scale: scale)
        )
    }
}

private enum MessageVideoAttachmentError: Error {
    case playbackFileUnavailable
}

private struct MessageFullscreenVideoPlayerView: View {
    let video: MessageFullscreenVideo
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var audioSession = ObservableVideoPlaybackAudioSession()
    @State private var dismissDragOffset: CGFloat = 0

    @ScaledMetric(relativeTo: .body)
    private var closeButtonSize: CGFloat = 44

    init(video: MessageFullscreenVideo, onDismiss: @escaping () -> Void) {
        self.video = video
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: video.url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .offset(y: dismissDragOffset)
        .opacity(1 - min(dismissDragOffset / 420, 0.35))
        .simultaneousGesture(swipeDownToDismissGesture)
        .onAppear {
            player.play()
            audioSession.attach(to: player)
        }
        .onDisappear {
            player.pause()
            audioSession.stop()
        }
    }

    private var swipeDownToDismissGesture: some Gesture {
        DragGesture(minimumDistance: MediaFullscreenDismiss.minimumDistance, coordinateSpace: .local)
            .onChanged { value in
                guard MediaFullscreenDismiss.isDownwardVertical(value.translation) else { return }
                dismissDragOffset = value.translation.height
            }
            .onEnded { value in
                guard dismissDragOffset > 0
                    || MediaFullscreenDismiss.isDownwardVertical(value.translation)
                else { return }

                if dismissDragOffset >= MediaFullscreenDismiss.dismissThreshold
                    || value.predictedEndTranslation.height >= MediaFullscreenDismiss.predictedDismissThreshold
                {
                    onDismiss()
                } else {
                    withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }
}

nonisolated enum MessageAudioPlayerPreparer {
    static func preparedPlayer(from data: Data) async throws -> AVAudioPlayer {
        try await detachedPreparedValue(priority: .userInitiated) { () throws -> AVAudioPlayer in
            let next = try AVAudioPlayer(data: data)
            next.enableRate = true
            next.prepareToPlay()
            return next
        }
    }

    static func duration(from data: Data) async -> Double? {
        await detachedValue(priority: .utility) {
            try? AVAudioPlayer(data: data).duration
        }
    }

    static func detachedPreparedValue<Value>(
        priority: TaskPriority,
        _ operation: @escaping @Sendable () throws -> sending Value
    ) async throws -> sending Value {
        try await Task.detached(priority: priority) {
            try operation()
        }.value
    }

    static func detachedValue<Value: Sendable>(
        priority: TaskPriority,
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await Task.detached(priority: priority) {
            operation()
        }.value
    }
}

/// Session-scoped memory of successful media prefetches, so a bubble that
/// scrolls in and out doesn't re-read the decrypted cache on every
/// appearance. Failed prefetches are released so a later appearance retries.
@MainActor
private enum MediaPrefetchRegistry {
    private static var claimed: Set<String> = []

    static func claim(_ key: String) -> Bool {
        claimed.insert(key).inserted
    }

    static func release(_ key: String) {
        claimed.remove(key)
    }
}

private struct MessageAudioAttachmentView: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let width: CGFloat
    let onLoadMedia: ConversationMediaLoader

    @State private var player: AVAudioPlayer?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var isPlaying = false
    @State private var progress: CGFloat = 0
    @State private var durationSeconds: Double?
    @State private var waveformSamples: [CGFloat]
    @State private var speedIndex = 0
    @State private var progressTask: Task<Void, Never>?
    @State private var playbackLoadTask: Task<Void, Never>?
    @State private var audioSessionLease: VoiceAudioSession.Lease?
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible

    @ScaledMetric(relativeTo: .subheadline)
    private var playIconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .caption)
    private var speedBadgeWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .caption)
    private var speedBadgeHeight: CGFloat = 28
    private let speeds: [Float] = [1, 1.5, 2]
    private var metadataCacheKey: String {
        MessageAudioBubblePresentation.cacheKey(for: item)
    }

    init(
        item: MessageMediaAttachment,
        isFromMe: Bool,
        width: CGFloat,
        onLoadMedia: ConversationMediaLoader
    ) {
        self.item = item
        self.isFromMe = isFromMe
        self.width = width
        self.onLoadMedia = onLoadMedia
        _durationSeconds = State(initialValue: item.durationSeconds)
        _waveformSamples = State(initialValue: item.waveformSamples.isEmpty ? MediaWaveformAnalyzer.fallback() : item.waveformSamples)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: togglePlayback) {
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: MessageAudioBubblePresentation.playbackIconName(
                                isPlaying: isPlaying,
                                didFail: didFail
                            ))
                            .font(.system(size: playIconSize, weight: .semibold))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : Color.primary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause audio message" : "Play audio message")

                VStack(alignment: .leading, spacing: 5) {
                    AudioWaveformView(
                        samples: waveformSamples,
                        progress: progress,
                        barColor: isFromMe ? MessageBubblePalette.sentForeground.opacity(0.58) : Color.secondary.opacity(0.45),
                        playedColor: isFromMe ? MessageBubblePalette.sentForeground : Color.accentColor
                    )
                    .frame(height: 28)
                    if let durationLabel = MessageAudioBubblePresentation.durationLabel(durationSeconds ?? item.durationSeconds) {
                        Text(durationLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground.opacity(0.75) : Color.secondary)
                    }
                }

                Button(action: cycleSpeed) {
                    Text(speedLabel)
                        .font(.caption.weight(.bold))
                        .frame(width: speedBadgeWidth, height: speedBadgeHeight)
                        .background(isFromMe ? MessageBubblePalette.sentForeground.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : Color.primary)
                .accessibilityLabel("Playback speed")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

        }
        .frame(width: width)
        .frame(minHeight: 68)
        .background(isFromMe ? MessageBubblePalette.sentBackground : MessageBubblePalette.receivedBackground, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(isFromMe ? 0.12 : 0.08), lineWidth: 1)
        }
        .onDisappear {
            stopPlayback()
        }
        .task(id: TimelineMediaTaskID(
            contentID: metadataCacheKey,
            isVisible: isTimelineRowVisible
        )) {
            guard isTimelineRowVisible else { return }
            await loadMetadataIfNeeded()
            await prefetchIfNeeded()
        }
        .onChange(of: isTimelineRowVisible) { _, isVisible in
            if !isVisible { stopPlayback() }
        }
    }

    /// Downloads the payload ahead of the first play tap when policy allows —
    /// voice messages always, other audio per the auto-download matrix.
    private func prefetchIfNeeded() async {
        guard player == nil, !isLoading else { return }
        let isVoice = AudioAutoDownloadPolicy.isVoiceMessage(durationSeconds: item.durationSeconds)
        guard AudioAutoDownloadPolicy.shouldPrefetch(
            isVoiceMessage: isVoice,
            matrixAllows: MediaAutoDownloadStore.shared.shouldAutoDownload(.audio)
        ) else { return }
        guard MediaPrefetchRegistry.claim(metadataCacheKey) else { return }
        guard let data = try? await onLoadMedia.data(for: item) else {
            MediaPrefetchRegistry.release(metadataCacheKey)
            return
        }
        guard AudioPlaybackLoadOutcome.resolve(isCancelled: Task.isCancelled) == .proceed else { return }
        applyMetadata(await audioMetadata(from: data))
    }

    private var speedLabel: String {
        switch speeds[speedIndex] {
        case 1: "1x"
        case 1.5: "1.5x"
        default: "2x"
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
            return
        }
        if player == nil || didFail {
            // Store the load+play task so it can be cancelled when the view
            // disappears mid-load; cancel any prior in-flight load first so we
            // never stack redundant loads. Mirrors the `progressTask` pattern.
            playbackLoadTask?.cancel()
            playbackLoadTask = Task { await loadAndPlay() }
        } else {
            playLoadedAudio()
        }
    }

    private func cycleSpeed() {
        speedIndex = (speedIndex + 1) % speeds.count
        player?.rate = speeds[speedIndex]
        if isPlaying {
            player?.play()
            player?.rate = speeds[speedIndex]
        }
    }

    private func loadAndPlay() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            // The view may have disappeared (and `stopPlayback` cancelled this
            // task) while the decrypt/download was in flight. Bail before
            // touching player state or acquiring the audio-session lease so a
            // gone view never starts invisible, uncontrollable playback.
            guard AudioPlaybackLoadOutcome.resolve(isCancelled: Task.isCancelled) == .proceed else { return }
            let metadata = await audioMetadata(from: data)
            let next = try await MessageAudioPlayerPreparer.preparedPlayer(from: data)
            guard AudioPlaybackLoadOutcome.resolve(isCancelled: Task.isCancelled) == .proceed else { return }
            player = next
            let playableMetadata = MessageAudioMetadata(
                durationSeconds: metadata.durationSeconds ?? next.duration,
                samples: metadata.samples
            )
            MessageAudioMetadataCache.store(playableMetadata, for: metadataCacheKey)
            applyMetadata(playableMetadata)
            playLoadedAudio()
        } catch {
            // A cancelled load is an expected disappearance, not a failure;
            // don't flip the bubble into the retry/failed state for it.
            if Task.isCancelled { return }
            didFail = true
            isPlaying = false
        }
    }

    private func loadMetadataIfNeeded() async {
        if let cached = MessageAudioMetadataCache.metadata(for: metadataCacheKey) {
            applyMetadata(cached)
            return
        }

        if let embedded = embeddedMetadata {
            MessageAudioMetadataCache.store(embedded, for: metadataCacheKey)
            applyMetadata(embedded)
        }
    }

    private var embeddedMetadata: MessageAudioMetadata? {
        guard item.durationSeconds != nil, !item.waveformSamples.isEmpty else {
            return nil
        }
        return MessageAudioMetadata(
            durationSeconds: item.durationSeconds,
            samples: MediaWaveformAnalyzer.normalized(item.waveformSamples)
        )
    }

    private func audioMetadata(from data: Data) async -> MessageAudioMetadata {
        if let cached = MessageAudioMetadataCache.metadata(for: metadataCacheKey) {
            return cached
        }

        let analyzed = await Task.detached(priority: .utility) {
            MediaWaveformAnalyzer.metadata(from: data, mediaType: item.mediaType)
        }.value
        let duration: Double?
        if let analyzedDuration = analyzed.durationSeconds {
            duration = analyzedDuration
        } else {
            duration = await MessageAudioPlayerPreparer.duration(from: data)
        }
        let metadata = MessageAudioMetadata(
            durationSeconds: duration,
            samples: MediaWaveformAnalyzer.normalized(analyzed.samples)
        )
        MessageAudioMetadataCache.store(metadata, for: metadataCacheKey)
        return metadata
    }

    private func applyMetadata(_ metadata: MessageAudioMetadata) {
        durationSeconds = metadata.durationSeconds
        waveformSamples = MediaWaveformAnalyzer.normalized(metadata.samples)
    }

    private func playLoadedAudio() {
        guard let player else { return }
        do {
            releaseAudioSession()
            audioSessionLease = try VoiceAudioSession.configureForPlayback()
        } catch {
            failPlaybackStart()
            return
        }
        if player.currentTime >= player.duration {
            player.currentTime = 0
        }
        player.enableRate = true
        player.rate = speeds[speedIndex]
        guard player.play() else {
            failPlaybackStart()
            return
        }
        player.rate = speeds[speedIndex]
        didFail = false
        isPlaying = true
        startProgressLoop()
    }

    private func pausePlayback() {
        progressTask?.cancel()
        progressTask = nil
        player?.pause()
        isPlaying = false
        releaseAudioSession()
    }

    private func failPlaybackStart() {
        progressTask?.cancel()
        progressTask = nil
        releaseAudioSession()
        didFail = true
        isPlaying = false
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                guard let player else { return }
                let duration = max(0.01, player.duration)
                progress = min(1, max(0, CGFloat(player.currentTime / duration)))
                if !player.isPlaying {
                    finishPlayback()
                    if progress >= 0.995 {
                        progress = 0
                        player.currentTime = 0
                    }
                    return
                }
            }
        }
    }

    private func finishPlayback() {
        progressTask?.cancel()
        progressTask = nil
        isPlaying = false
        releaseAudioSession()
    }

    private func stopPlayback() {
        progressTask?.cancel()
        progressTask = nil
        // Cancel any in-flight load+play task. Without this, a load resolving
        // after the view disappeared would start playback (and acquire the
        // `.playback` lease) on a view that is no longer on screen.
        playbackLoadTask?.cancel()
        playbackLoadTask = nil
        let shouldDeactivate = isPlaying || player?.isPlaying == true || audioSessionLease != nil
        player?.stop()
        isPlaying = false
        if shouldDeactivate {
            releaseAudioSession()
        }
    }

    private func releaseAudioSession() {
        VoiceAudioSession.deactivate(audioSessionLease)
        audioSessionLease = nil
    }

}

private struct MessageAudioMetadata: Sendable {
    let durationSeconds: Double?
    let samples: [CGFloat]
}

private enum MessageAudioMetadataCache {
    private final class CachedMetadata: NSObject {
        let durationSeconds: Double?
        let samples: [CGFloat]

        init(_ metadata: MessageAudioMetadata) {
            durationSeconds = metadata.durationSeconds
            samples = metadata.samples
        }

        var metadata: MessageAudioMetadata {
            MessageAudioMetadata(durationSeconds: durationSeconds, samples: samples)
        }
    }

    private static let cache: NSCache<NSString, CachedMetadata> = {
        let cache = NSCache<NSString, CachedMetadata>()
        cache.countLimit = 200
        return cache
    }()

    static func metadata(for key: String) -> MessageAudioMetadata? {
        cache.object(forKey: key as NSString)?.metadata
    }

    static func store(_ metadata: MessageAudioMetadata, for key: String) {
        cache.setObject(CachedMetadata(metadata), forKey: key as NSString)
    }
}

private struct MessageDocumentAttachmentView: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let width: CGFloat
    let onLoadMedia: ConversationMediaLoader

    @State private var isLoading = false
    @State private var didFail = false
    @State private var shareItem: MessageDocumentShareItem?

    var body: some View {
        Button {
            Task { await openDocument() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.kind.systemImageName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : Color.accentColor)
                    .frame(width: 24, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Text(fileDetail)
                        .font(.caption2)
                        .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground.opacity(0.74) : Color.secondary)
                }
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isFromMe ? MessageBubblePalette.sentForeground : .accentColor)
                } else if didFail {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 24)
                        .padding(.trailing, 4)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 24)
                        .padding(.trailing, 4)
                }
            }
            .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : Color.primary)
            .padding(6)
            .frame(width: width)
            .background(documentSurface, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open attachment")
        .sheet(item: $shareItem) { shareItem in
            MessageDocumentShareSheet(url: shareItem.url)
        }
    }

    private var fileDetail: String {
        let ext = MediaAttachmentPolicy.fileExtension(for: item.mediaType, fileName: item.fileName)
        return ext.isEmpty
            ? MediaAttachmentPolicy.canonicalMediaType(item.mediaType)
            : ext.uppercased()
    }

    private var documentSurface: Color {
        if isFromMe {
            return MessageBubblePalette.sentForeground.opacity(0.16)
        }
        return MessageBubblePalette.receivedForeground.opacity(0.09)
    }

    private func openDocument() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let producerEpoch = MessageMediaCache.currentProducerEpoch()
            let data = try await onLoadMedia.data(for: item)
            guard let url = await MediaPlaybackFileStore.fileURL(for: item, data: data, producerEpoch: producerEpoch) else {
                didFail = true
                return
            }
            shareItem = MessageDocumentShareItem(url: url)
        } catch {
            didFail = true
        }
    }
}

private struct MessageDocumentShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MessageDocumentShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum MessageVideoThumbnailDecoder {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    static func cachedThumbnail(for itemID: String, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize))
    }

    static func store(_ image: UIImage, for itemID: String, maxPixelSize: Int) {
        let pixelCost = max(1, Int(image.size.width * image.scale * image.size.height * image.scale * 4))
        cache.setObject(
            image,
            forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize),
            cost: pixelCost
        )
    }

    static func thumbnail(url: URL, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let boundedSize = max(1, maxPixelSize)
        let imageScale = max(1, scale)
        return await withCheckedContinuation { continuation in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: boundedSize, height: boundedSize)
            generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
                guard let image, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: image, scale: imageScale, orientation: .up))
            }
        }
    }

    private static func cacheKey(for itemID: String, maxPixelSize: Int) -> NSString {
        "\(itemID):\(max(1, maxPixelSize))" as NSString
    }
}

enum MessageMediaThumbnailDecoder {
    private final class CachedThumbnail: NSObject {
        let image: UIImage
        let sourceData: Data

        init(image: UIImage, sourceData: Data) {
            self.image = image
            self.sourceData = sourceData
        }
    }

    private static let cache: NSCache<NSString, CachedThumbnail> = {
        let cache = NSCache<NSString, CachedThumbnail>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    static func cachedThumbnail(for itemID: String, maxPixelSize: Int) -> (image: UIImage, sourceData: Data)? {
        guard let cached = cache.object(forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize)) else {
            return nil
        }
        return (cached.image, cached.sourceData)
    }

    static func store(_ image: UIImage, sourceData: Data, for itemID: String, maxPixelSize: Int) {
        cache.setObject(
            CachedThumbnail(image: image, sourceData: sourceData),
            forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize),
            cost: thumbnailCacheCost(for: image, sourceData: sourceData)
        )
    }

    static func thumbnailCacheCost(for image: UIImage, sourceData: Data) -> Int {
        let bitmapCost = DecodedImageCost.decodedBitmapByteCost(for: image)
        guard Int.max - bitmapCost >= sourceData.count else { return Int.max }
        return max(1, bitmapCost + sourceData.count)
    }

    static func image(data: Data, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        let targetPixelSize = max(1, maxPixelSize)
        let imageScale = max(1, scale)
        return await Task.detached(priority: .utility) { () -> UIImage? in
            decodeThumbnailImage(
                data: data,
                targetPixelSize: targetPixelSize,
                imageScale: imageScale,
                createSource: { data, options in
                    CGImageSourceCreateWithData(data as CFData, options)
                },
                createThumbnail: { source, options in
                    CGImageSourceCreateThumbnailAtIndex(source, 0, options)
                }
            )
        }.value
    }

    nonisolated static func decodeThumbnailImage(
        data: Data,
        targetPixelSize: Int,
        imageScale: CGFloat,
        createSource: (Data, CFDictionary) -> CGImageSource?,
        sourceType: (CGImageSource) -> CFString? = { CGImageSourceGetType($0) },
        createThumbnail: (CGImageSource, CFDictionary) -> CGImage?
    ) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = createSource(data, sourceOptions as CFDictionary) else {
            return nil
        }
        // Peer-controlled MLS media attachments are admitted here purely on a
        // `image/*` MIME prefix, which includes `image/svg+xml`. Gate the actual
        // decoded container type through the shared remote-image allowlist so SVG
        // (and any non-image container ImageIO would otherwise parse) is rejected
        // before thumbnailing, mirroring the HTTP avatar/group-image path.
        guard RemoteImageDecoder.isAllowedRemoteImageType(sourceType(source)) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, targetPixelSize),
        ]
        guard let cgImage = createThumbnail(source, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: max(1, imageScale), orientation: .up)
    }

    private static func cacheKey(for itemID: String, maxPixelSize: Int) -> NSString {
        "\(itemID):\(maxPixelSize)" as NSString
    }
}

/// A page in the fullscreen gallery. A GIF is a remote URL with no encrypted
/// payload, so it pages alongside media without being one.
enum MessageMediaGalleryPage: Identifiable {
    case giphy(RemoteGiphyMedia)
    case media(MessageMediaAttachment)

    var id: String {
        switch self {
        case .giphy: MessageMediaGallery.giphyPageID
        case .media(let item): item.id
        }
    }
}

struct MessageMediaGallery: Identifiable {
    /// Media ids join owner, digest, epoch and index with ":", so a
    /// colon-free sentinel cannot collide with one.
    static let giphyPageID = "remote-giphy-page"

    let id = UUID()
    let items: [MessageMediaAttachment]
    let giphyMedia: RemoteGiphyMedia?
    let initialItemID: String
    let initialMediaData: Data?
    let messageIdByItemID: [String: String]

    /// The GIF leads the pages the way it leads the grid cells.
    var pages: [MessageMediaGalleryPage] {
        (giphyMedia.map { [MessageMediaGalleryPage.giphy($0)] } ?? [])
            + items.map(MessageMediaGalleryPage.media)
    }

    init?(item: MessageMediaAttachment, imageData: Data) {
        self.init(items: [item], initialItem: item, initialMediaData: imageData)
    }

    init(
        giphyMedia: RemoteGiphyMedia,
        items: [MessageMediaAttachment] = [],
        messageIdByItemID: [String: String] = [:]
    ) {
        self.items = items.filter { $0.isImage || $0.isVideo }
        self.giphyMedia = giphyMedia
        self.initialItemID = Self.giphyPageID
        self.initialMediaData = nil
        self.messageIdByItemID = messageIdByItemID
    }

    init?(
        items: [MessageMediaAttachment],
        initialItem: MessageMediaAttachment,
        initialImageData: Data,
        messageIdByItemID: [String: String] = [:],
        giphyMedia: RemoteGiphyMedia? = nil
    ) {
        self.init(
            items: items,
            initialItem: initialItem,
            initialMediaData: initialImageData,
            messageIdByItemID: messageIdByItemID,
            giphyMedia: giphyMedia
        )
    }

    init?(
        items: [MessageMediaAttachment],
        initialItem: MessageMediaAttachment,
        initialMediaData: Data? = nil,
        messageIdByItemID: [String: String] = [:],
        giphyMedia: RemoteGiphyMedia? = nil
    ) {
        guard initialItem.isImage || initialItem.isVideo else { return nil }
        let visualItems = items.filter { $0.isImage || $0.isVideo }
        if visualItems.contains(where: { $0.id == initialItem.id }) {
            self.items = visualItems
        } else {
            self.items = [initialItem] + visualItems
        }
        self.giphyMedia = giphyMedia
        self.initialItemID = initialItem.id
        self.initialMediaData = initialMediaData
        self.messageIdByItemID = messageIdByItemID
    }

    func initialData(for item: MessageMediaAttachment) -> Data? {
        if item.id == initialItemID {
            return initialMediaData
        }
        return item.localData
    }
}

@MainActor
struct MediaForwardingContext {
    let viewModel: ConversationViewModel
    let destinationProvider: () async throws -> [MessageForwardDestination]
}

private struct FullscreenMediaPrepared: Identifiable {
    let id: String
    let item: MessageMediaAttachment
    let data: Data
    let url: URL
    let contentType: UTType
}

private struct FullscreenMediaShare: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DecryptedMediaExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum FullscreenMediaPreparationError: Error {
    case protectedFileUnavailable
}

enum MessageMediaFullscreenPresentation {
    /// Pixel budget for a fullscreen decode derived from the longest native
    /// screen edge. The fullscreen view only ever renders the image
    /// `scaledToFit` within the screen, so a screen-sized decode is visually
    /// lossless for presentation while capping the worst-case bitmap
    /// allocation. Pure helper kept separate from `UIScreen` so it stays
    /// testable and free of MainActor isolation.
    static func fullscreenMaxPixelSize(forLongestScreenEdge longestEdge: CGFloat) -> Int {
        guard longestEdge.isFinite, longestEdge >= 1 else { return 1 }
        return max(1, Int(longestEdge.rounded(.up)))
    }

    /// Decodes attacker-controlled image bytes off the MainActor, bounded to a
    /// screen-sized pixel budget. Mirrors the thumbnail/grid hardening
    /// (`MessageMediaThumbnailDecoder`) so the fullscreen path never performs a
    /// full-resolution decode on the MainActor, and a crafted high-megapixel
    /// image cannot allocate an unbounded bitmap on the UI actor.
    static func decodedImage(from data: Data?, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        guard let data else { return nil }
        return await MessageMediaThumbnailDecoder.image(
            data: data,
            maxPixelSize: maxPixelSize,
            scale: scale
        )
    }
}

private enum MediaFullscreenDismiss {
    static let minimumDistance: CGFloat = 16
    static let dismissThreshold: CGFloat = 120
    static let predictedDismissThreshold: CGFloat = 240
    static let verticalDominance: CGFloat = 1.2

    static func isDownwardVertical(_ translation: CGSize) -> Bool {
        translation.height > 0
            && translation.height > abs(translation.width) * verticalDominance
    }
}

nonisolated enum MessageMediaFullscreenGalleryPresentation {
    static func pageCountLabel(
        selectedIndex: Int?,
        totalCount: Int,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        guard let selectedIndex,
              selectedIndex >= 0,
              totalCount > 0
        else { return "" }
        let current = LocalizedNumberLabel.decimal(UInt64(selectedIndex + 1), locale: locale)
        let total = LocalizedNumberLabel.decimal(UInt64(totalCount), locale: locale)
        return L10n.formatted("%@ of %@", arguments: [current, total], locale: locale)
    }

    static func canGoToMessage(messageId: String?, hasHandler: Bool) -> Bool {
        guard hasHandler, let messageId else { return false }
        return !messageId.isEmpty
    }

    static func canForward(hasPreparedMedia: Bool, hasForwardingContext: Bool) -> Bool {
        hasPreparedMedia && hasForwardingContext
    }
}

struct MessageMediaFullscreenGalleryView: View {
    @Environment(AppState.self) private var appState
    let gallery: MessageMediaGallery
    let onLoadMedia: ConversationMediaLoader
    var forwardingContext: MediaForwardingContext?
    var onGoToMessage: ((String) -> Void)?
    let onDismiss: () -> Void

    @State private var selectedItemID: String
    @State private var dismissDragOffset: CGFloat = 0
    @State private var preparedMedia: FullscreenMediaPrepared?
    @State private var mediaShare: FullscreenMediaShare?
    @State private var exportDocument: DecryptedMediaExportDocument?
    @State private var saveProductTicket: ProductAnalyticsRecorder.Ticket?
    @State private var isExporting = false
    @State private var actionError: String?
    @State private var forwardMedia: FullscreenMediaPrepared?

    @ScaledMetric(relativeTo: .body)
    private var closeButtonSize: CGFloat = 42

    init(
        gallery: MessageMediaGallery,
        onLoadMedia: ConversationMediaLoader,
        forwardingContext: MediaForwardingContext? = nil,
        onGoToMessage: ((String) -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.gallery = gallery
        self.onLoadMedia = onLoadMedia
        self.forwardingContext = forwardingContext
        self.onGoToMessage = onGoToMessage
        self.onDismiss = onDismiss
        _selectedItemID = State(initialValue: gallery.initialItemID)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedItemID) {
                ForEach(gallery.pages) { page in
                    switch page {
                    case .giphy(let media):
                        // Opening fullscreen is the explicit action that the
                        // tap-to-load gate asks for, so this page may load.
                        RemoteGiphyMediaView(
                            media: media,
                            mayLoadAutomatically: true,
                            layout: .fullscreen
                        )
                        .tag(page.id)
                    case .media(let item):
                        MessageMediaFullscreenPage(
                            item: item,
                            isSelected: item.id == selectedItemID,
                            initialImageData: gallery.initialData(for: item),
                            onLoadMedia: onLoadMedia
                        )
                        .tag(page.id)
                    }
                }
            }
            .tabViewStyle(
                .page(indexDisplayMode: .never)
            )
            .ignoresSafeArea()

            if gallery.pages.count > 1 {
                Text(pageCountLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 76)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(.top, 14)
            .padding(.trailing, 14)

            actionMenu

            bottomActions
        }
        .offset(y: dismissDragOffset)
        .opacity(1 - min(dismissDragOffset / 420, 0.35))
        .simultaneousGesture(swipeDownToDismissGesture)
        .task(id: selectedItemID) { await prepareSelectedMedia() }
        .sheet(item: $mediaShare) { share in
            ActivityShareSheet(items: [share.url])
        }
        .sheet(item: $forwardMedia) { prepared in
            if let forwardingContext {
                ForwardMessageSheet(
                    media: prepared.item,
                    data: prepared.data,
                    viewModel: forwardingContext.viewModel,
                    destinationProvider: forwardingContext.destinationProvider
                )
                .appAppearance()
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: preparedMedia?.contentType ?? .data,
            defaultFilename: preparedMedia?.item.fileName ?? "Media"
        ) { result in
            let outcome: ProductOutcome
            switch result {
            case .success: outcome = .success
            case .failure(let error): outcome = (error as NSError).code == NSUserCancelledError ? .cancelled : .failure
            }
            appState.productAnalytics.record(.attachment(.save, outcome), ticket: saveProductTicket)
            saveProductTicket = nil
            if case .failure = result {
                actionError = L10n.string("Couldn't save media.")
            }
        }
        .alert(
            "Media unavailable",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var selectedItem: MessageMediaAttachment? {
        gallery.items.first { $0.id == selectedItemID }
    }

    private var actionMenu: some View {
        Menu {
            Button("Save", systemImage: "square.and.arrow.down") {
                guard let preparedMedia else { return }
                saveProductTicket = appState.productAnalytics.ticket()
                exportDocument = DecryptedMediaExportDocument(data: preparedMedia.data)
                isExporting = true
            }
            .disabled(preparedMedia == nil)

            if let messageId = gallery.messageIdByItemID[selectedItemID],
               MessageMediaFullscreenGalleryPresentation.canGoToMessage(
                    messageId: messageId,
                    hasHandler: onGoToMessage != nil
               )
            {
                Button("Go to Message", systemImage: "bubble.left") {
                    onDismiss()
                    onGoToMessage?(messageId)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: closeButtonSize, height: closeButtonSize)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .padding(.top, 14)
        .padding(.trailing, closeButtonSize + 24)
    }

    private var bottomActions: some View {
        HStack {
            Button {
                if let url = preparedMedia?.url {
                    mediaShare = FullscreenMediaShare(url: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }
            .disabled(preparedMedia == nil)

            Spacer()

            Button {
                forwardMedia = preparedMedia
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
                    .frame(minHeight: 44)
            }
            .disabled(!MessageMediaFullscreenGalleryPresentation.canForward(
                hasPreparedMedia: preparedMedia != nil,
                hasForwardingContext: forwardingContext != nil
            ))
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func prepareSelectedMedia() async {
        guard let selectedItem else {
            preparedMedia = nil
            return
        }
        preparedMedia = nil
        do {
            let data = try await onLoadMedia.data(for: selectedItem)
            guard !Task.isCancelled, selectedItem.id == selectedItemID else { return }
            let producerEpoch = MessageMediaCache.currentProducerEpoch()
            guard let url = await MediaPlaybackFileStore.fileURL(
                for: selectedItem,
                data: data,
                producerEpoch: producerEpoch
            ) else {
                throw FullscreenMediaPreparationError.protectedFileUnavailable
            }
            guard !Task.isCancelled, selectedItem.id == selectedItemID else { return }
            preparedMedia = FullscreenMediaPrepared(
                id: selectedItem.id,
                item: selectedItem,
                data: data,
                url: url,
                contentType: UTType(mimeType: selectedItem.mediaType) ?? .data
            )
        } catch is CancellationError {
            return
        } catch {
            actionError = L10n.string("Couldn't prepare media.")
        }
    }

    private var swipeDownToDismissGesture: some Gesture {
        DragGesture(minimumDistance: MediaFullscreenDismiss.minimumDistance, coordinateSpace: .local)
            .onChanged { value in
                guard MediaFullscreenDismiss.isDownwardVertical(value.translation) else { return }
                dismissDragOffset = value.translation.height
            }
            .onEnded { value in
                guard dismissDragOffset > 0
                    || MediaFullscreenDismiss.isDownwardVertical(value.translation)
                else { return }

                if dismissDragOffset >= MediaFullscreenDismiss.dismissThreshold
                    || value.predictedEndTranslation.height >= MediaFullscreenDismiss.predictedDismissThreshold
                {
                    onDismiss()
                } else {
                    withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }

    private var pageCountLabel: String {
        MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: gallery.pages.firstIndex(where: { $0.id == selectedItemID }),
            totalCount: gallery.pages.count
        )
    }
}

private struct MessageMediaFullscreenPage: View {
    let item: MessageMediaAttachment
    let isSelected: Bool
    let initialImageData: Data?
    let onLoadMedia: ConversationMediaLoader

    var body: some View {
        if item.isVideo {
            MessageMediaFullscreenVideoPage(
                item: item,
                isSelected: isSelected,
                onLoadMedia: onLoadMedia
            )
        } else {
            MessageMediaFullscreenImagePage(
                item: item,
                initialImageData: initialImageData,
                onLoadMedia: onLoadMedia
            )
        }
    }
}

private struct MessageMediaFullscreenVideoPage: View {
    @Environment(AppState.self) private var appState
    let item: MessageMediaAttachment
    let isSelected: Bool
    let onLoadMedia: ConversationMediaLoader

    @State private var player: AVPlayer?
    @State private var playbackURL: URL?
    @State private var audioSession = ObservableVideoPlaybackAudioSession()
    @State private var isLoading = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isLoading {
                ProgressView()
                    .tint(.white)
                    .controlSize(.regular)
            } else if didFail {
                Button {
                    Task { await loadAndPlay(force: true) }
                } label: {
                    Label(L10n.string("Retry"), systemImage: "arrow.clockwise")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if player == nil {
                Button {
                    Task { await loadAndPlay() }
                } label: {
                    VideoPreviewPlayOverlay(
                        diameter: VideoPreviewOverlayPresentation.maximumDiameter
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Play video"))
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            startPlaybackIfSelected()
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                startPlaybackIfSelected()
            } else {
                releasePlayback()
            }
        }
        .onDisappear {
            releasePlayback()
        }
        .accessibilityLabel(L10n.string("Video attachment"))
    }

    private func startPlaybackIfSelected() {
        guard isSelected else { return }
        Task { await loadAndPlay() }
    }

    private func loadAndPlay(force: Bool = false) async {
        guard isSelected else { return }
        guard force || !isLoading else { return }
        if force {
            // Retry should refetch the decrypted playback file, while ordinary
            // re-selection reuses the memoized URL after releasing the player.
            releasePlayback()
            playbackURL = nil
        } else if let player {
            player.play()
            audioSession.attach(to: player)
            return
        }

        let productTicket = appState.productAnalytics.ticket()
        var productOutcome: ProductOutcome = .cancelled
        defer { appState.productAnalytics.record(.attachment(.open, productOutcome), ticket: productTicket) }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let url = try await playbackFileURL()
            guard !Task.isCancelled, isSelected else { return }
            let next = AVPlayer(url: url)
            productOutcome = .success
            player = next
            next.play()
            audioSession.attach(to: next)
        } catch {
            guard !Task.isCancelled, isSelected else { return }
            productOutcome = .failure
            didFail = true
        }
    }

    private func playbackFileURL() async throws -> URL {
        if let playbackURL {
            return playbackURL
        }
        let producerEpoch = MessageMediaCache.currentProducerEpoch()
        let data = try await onLoadMedia.data(for: item)
        guard let url = await MediaPlaybackFileStore.fileURL(for: item, data: data, producerEpoch: producerEpoch) else {
            throw MessageVideoAttachmentError.playbackFileUnavailable
        }
        playbackURL = url
        return url
    }

    private func releasePlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        audioSession.stop()
        player = nil
    }
}

private struct MessageMediaFullscreenImagePage: View {
    @Environment(AppState.self) private var appState
    let item: MessageMediaAttachment
    let onLoadMedia: ConversationMediaLoader

    @State private var imageData: Data?
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    @Environment(\.displayScale) private var displayScale

    init(
        item: MessageMediaAttachment,
        initialImageData: Data?,
        onLoadMedia: ConversationMediaLoader
    ) {
        self.item = item
        self.onLoadMedia = onLoadMedia
        // Do NOT decode here. Decoding attacker-controlled bytes is deferred to
        // `loadImageIfNeeded`, which runs the decode off the MainActor and
        // bounded to a screen-sized pixel budget. Stash the raw initial bytes
        // (if any) so the first load can reuse them without re-fetching.
        _imageData = State(initialValue: initialImageData)
    }

    private func fullscreenMaxPixelSize(viewSize: CGSize, scale: CGFloat) -> Int {
        let longestPoint = max(viewSize.width, viewSize.height)
        let longestEdge = max(1, longestPoint * scale)
        return MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: longestEdge)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if didFail {
                    Button {
                        Task { await loadImageIfNeeded(viewSize: proxy.size, scale: displayScale, force: true) }
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
                await loadImageIfNeeded(viewSize: proxy.size, scale: displayScale)
            }
        }
    }

    private func loadImageIfNeeded(viewSize: CGSize, scale: CGFloat, force: Bool = false) async {
        guard image == nil || force else { return }
        let productTicket = appState.productAnalytics.ticket()
        var productOutcome: ProductOutcome = .cancelled
        defer { appState.productAnalytics.record(.attachment(.open, productOutcome), ticket: productTicket) }
        let maxPixelSize = fullscreenMaxPixelSize(viewSize: viewSize, scale: scale)

        // First, try decoding any bytes we already hold (initial data passed in
        // from the gallery / a previous load) off the MainActor before paying
        // for another fetch.
        if !force, let existing = imageData {
            if let decoded = await MessageMediaFullscreenPresentation.decodedImage(
                from: existing,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) {
                guard !Task.isCancelled else { return }
                productOutcome = .success
                image = decoded
                didFail = false
                return
            }
        }

        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            guard !Task.isCancelled else { return }
            guard let decoded = await MessageMediaFullscreenPresentation.decodedImage(
                from: data,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) else {
                guard !Task.isCancelled else { return }
                imageData = nil
                image = nil
                productOutcome = .failure
                didFail = true
                return
            }
            guard !Task.isCancelled else { return }
            productOutcome = .success
            imageData = data
            image = decoded
        } catch {
            guard !Task.isCancelled else { return }
            imageData = nil
            image = nil
            productOutcome = .failure
            didFail = true
        }
    }
}
