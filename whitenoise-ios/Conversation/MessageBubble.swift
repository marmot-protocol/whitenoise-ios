import Combine
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

    @Entry var mediaOpenIntent: MediaOpenIntent? = nil

    /// The conversation's file-backed upload progress; nil outside a conversation.
    @Entry var mediaUploadProgress: MediaUploadProgressStore? = nil
}

/// Shared by tiles in one conversation so an older read cannot present over a later tap.
@MainActor
final class MediaOpenIntent {
    private(set) var current: UUID?

    private var cancelPendingOpen: (() -> Void)?

    @discardableResult
    func begin(cancelPendingOpen: (() -> Void)? = nil) -> UUID {
        invalidate()
        self.cancelPendingOpen = cancelPendingOpen
        let id = UUID()
        current = id
        return id
    }

    func finish(_ id: UUID) {
        if current == id { cancelPendingOpen = nil }
    }

    func invalidate() {
        current = nil
        cancelPendingOpen?()
        cancelPendingOpen = nil
    }
}

struct TimelineMediaTaskID: Equatable {
    let contentID: String
    let isVisible: Bool
    var policyRevision: String = ""
    var source: AttachmentHandoffSource = .none
}

/// Reference box for the media-load callback. Passing the bare async closure
/// through every media view layer builds a deep reabstraction-thunk chain
/// that corrupts the indirect argument in debug builds — one shared box keeps
/// each hop a plain reference copy and the call a direct method dispatch.
@MainActor
final class ConversationMediaLoader {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    typealias OpenHandoff = (MessageMediaAttachment, MediaFileTransferControlFfi) async throws -> AttachmentHandoffLease?

    private let load: (MessageMediaAttachment) async throws -> Data
    private let openHandoff: OpenHandoff?
    let canShareDocument: @MainActor (MessageMediaAttachment, AttachmentLocalTargetFfi?) async throws -> Bool
    private let admitAutomatic: (MessageMediaAttachment) async -> Int?


    init(_ load: @escaping (MessageMediaAttachment) async throws -> Data, openHandoff: OpenHandoff? = nil,
         canShareDocument: @escaping @MainActor (MessageMediaAttachment, AttachmentLocalTargetFfi?) async throws -> Bool = { _, _ in true },
         admitAutomaticAttachment: @escaping (MessageMediaAttachment) async -> Int? = { $0.localData?.count }) {
        self.load = load
        self.openHandoff = openHandoff
        self.canShareDocument = canShareDocument
        self.admitAutomatic = admitAutomaticAttachment
    }

    @discardableResult
    func admitAutomaticAttachment(_ item: MessageMediaAttachment) async -> Int? {
        await admitAutomatic(item)
    }

    func data(for media: MessageMediaAttachment, demand: AttachmentDemand = .explicit) async throws -> Data {
        var requested = media
        requested.demand = demand
        return try await load(requested)
    }

    func videoPreviewData(for media: MessageMediaAttachment, demand: AttachmentDemand = .automatic) async throws -> Data {
        var preview = media
        // Larger movies can supply their poster from the file opened for playback.
        preview.previewByteLimit = 32 * 1024 * 1024
        return try await data(for: preview, demand: demand)
    }

    /// A file for video or audio playback. Prefers MDK's handoff lease when a
    /// retained slot is available so playback never buffers up to 512 MiB in RAM.
    func playbackFile(
        for media: MessageMediaAttachment,
        demand: AttachmentDemand = .explicit,
        initialData: Data? = nil,
        control: MediaFileTransferControlFfi
    ) async throws -> AttachmentShareFile {
        var requested = media
        requested.demand = demand
        if let initialData, demand != .retry, AttachmentHandoffSource(media) == .none {
            let producerEpoch = MessageMediaCache.currentProducerEpoch()
            guard let url = await MediaPlaybackFileStore.fileURL(for: media, data: initialData, producerEpoch: producerEpoch) else {
                throw AttachmentReadError.unavailable
            }
            return AttachmentShareFile(hostURL: url)
        }
        if let openHandoff, let lease = try await openHandoff(requested, control) {
            if Self.hasPlayableExtension(for: media, at: lease.url) {
                return AttachmentShareFile(lease: lease)
            }
            if let alias = Self.makePlaybackSymlink(to: lease.url, for: media) {
                return AttachmentShareFile(lease: lease, url: alias, cleanupURL: alias)
            }
            lease.release()
        }
        let producerEpoch = MessageMediaCache.currentProducerEpoch()
        let data: Data
        if let initialData, demand != .retry {
            data = initialData
        } else {
            data = try await load(requested)
        }
        guard let url = await MediaPlaybackFileStore.fileURL(for: media, data: data, producerEpoch: producerEpoch) else {
            throw AttachmentReadError.unavailable
        }
        return AttachmentShareFile(hostURL: url)
    }

    nonisolated private static func hasPlayableExtension(for media: MessageMediaAttachment, at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let resolvedType = MediaAttachmentPolicy.mediaType(forFileExtension: ext) else {
            return false
        }
        return MediaAttachmentKind.classify(mediaType: resolvedType, fileName: url.lastPathComponent) == media.kind
    }

    nonisolated private static func makePlaybackSymlink(to targetURL: URL, for media: MessageMediaAttachment) -> URL? {
        let ext = MediaAttachmentPolicy.fileExtension(for: media.mediaType, fileName: media.fileName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteNoiseMediaPlaybackLinks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            MediaUploadSourceFiles.removeStale(in: directory, olderThan: PickedMediaFile.staleAge, now: Date())
            let alias = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: targetURL)
            return alias
        } catch {
            return nil
        }
    }

    /// A file for the share sheet. MDK's handoff lease when it has a source slot for
    /// the item; otherwise the host's own export of bytes it already holds.
    func shareFile(for media: MessageMediaAttachment, demand: AttachmentDemand = .explicit,
                   control: MediaFileTransferControlFfi) async throws -> AttachmentShareFile {
        var requested = media
        requested.demand = demand
        if let openHandoff, let lease = try await openHandoff(requested, control) {
            return AttachmentShareFile(lease: lease)
        }
        let producerEpoch = MessageMediaCache.currentProducerEpoch()
        let data = try await load(requested)
        guard let url = await MediaPlaybackFileStore.fileURL(for: media, data: data, producerEpoch: producerEpoch) else {
            throw AttachmentReadError.unavailable
        }
        return AttachmentShareFile(hostURL: url)
    }

    func selectedPageData(for media: MessageMediaAttachment, isSelected: Bool,
                          demand: AttachmentDemand = .explicit) async throws -> Data? {
        guard isSelected else { return nil }
        return try await data(for: media, demand: demand)
    }

    /// A sourced attachment may carry matching bytes from another message. The
    /// timeline can identify a confirmed own send whose only copy is still local.
    func documentSource(for item: MessageMediaAttachment) async throws -> MessageMediaAttachment {
        guard item.localData != nil, AttachmentHandoffSource(item) != .none,
              try await !canShareDocument(item, nil) else { return item }
        return item.forTranscriptPage
    }

    @discardableResult
    func prefetchDocument(_ media: MessageMediaAttachment, isVisible: Bool, allowed: Bool, hasContactName: Bool = false) async -> (size: Int, contactName: String?)? {
        guard isVisible, media.kind == .document || media.kind == .unsupported else { return nil }
        guard !hasContactName, DocumentPreviewFormat(for: media) == .contact else {
            guard allowed else { return nil }
            return await admitAutomaticAttachment(media).map { ($0, nil) }
        }
        let limit = DocumentPreviewFormat.contact.byteLimit
        do {
            let bytes: Data
            if let local = media.localData {
                // An identical outgoing send can supply these bytes. Only reveal a contact
                // name from that overlay while this message's own slot still retains it.
                if try await documentSource(for: media).localData == nil {
                    guard let target = media.localTarget, try await canShareDocument(media, target) else { return nil }
                }
                guard local.count <= limit else { return (local.count, nil) }
                bytes = local
            } else {
                guard allowed else { return nil }
                var requested = media
                requested.previewByteLimit = limit
                bytes = try await data(for: requested, demand: .automatic)
            }
            try Task.checkCancellation()
            let name = await Task.detached(priority: .utility) { SharedContactPreview(data: bytes)?.name }.value
            try Task.checkCancellation()
            return (bytes.count, name)
        } catch AttachmentReadError.previewLimitExceeded(let size) {
            return size.map { ($0, nil) }
        } catch { return nil }
    }
}

nonisolated enum MessageBubbleReplyLayout {
    static let richContentWidth: CGFloat = 256
    static let bodyHorizontalInset = ChatBubbleMetrics.horizontalInset
    static let bodyTopInset = ChatBubbleMetrics.verticalInset
    static let bodyTopInsetAfterReply: CGFloat = 0
    static let bodyBottomInset = ChatBubbleMetrics.verticalInset
    static let cardOuterInset: CGFloat = 6
    static let cardVerticalInset: CGFloat = 6
    static let cardCornerRadius = ChatBubbleMetrics.cornerRadius - cardOuterInset
    static let sentCardOpacity = 0.16
    static let receivedCardOpacity = 0.09

    static func textWidth(proposed: CGFloat?, ideal: CGFloat?) -> CGFloat {
        min(ChatBubbleMetrics.textMaximumWidth, proposed ?? .infinity, ideal ?? .infinity)
    }
}

/// A quote's flexible card fills the final bubble. Measure its natural width first
/// so that a short quote and a short reply can share a narrow bubble.
private struct MessageTextBubbleLayout: Layout {
    let fitsQuote: Bool
    var widensForReactions = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = fitsQuote ? content.sizeThatFits(.unspecified).width : nil
        let width = MessageBubbleReplyLayout.textWidth(proposed: proposal.width, ideal: ideal)
        let size = content.sizeThatFits(.init(width: width, height: nil))
        // The chrome measures the bubble with no height first, then supplies its final width for the reaction strip at placement.
        if widensForReactions, proposal.height != nil, let width = proposal.width {
            return CGSize(width: width, height: size.height)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
    }
}

nonisolated enum TranscriptMessagePreview {
    /// Prepare one continuous document off the UI actor. Resolve each distinct
    /// mention against the existing profile cache without starting a profile load.
    @concurrent
    static func sourceText(_ raw: String, displayName: @MainActor @Sendable (String) -> String?) async throws -> String {
        let text = ContentSanitizer.textRun(raw)
        var start = text.startIndex
        var search = start
        var rendered = ""
        var replacements: [String: String] = [:]
        while let at = text[search...].firstIndex(of: "@") {
            try Task.checkCancellation()
            search = text.index(after: at)
            guard let match = CanonicalMentionDisplayProjection.canonicalMention(in: text, at: at) else { continue }
            let replacement: String
            if let cached = replacements[match.npub] {
                replacement = cached
            } else {
                replacement = await ContentSanitizer.displayName(displayName(match.npub)).map { "@\($0)" } ?? String(text[at..<match.endIndex])
                replacements[match.npub] = replacement
            }
            rendered += text[start..<at]
            rendered += replacement
            start = match.endIndex
            search = start
        }
        try Task.checkCancellation()
        guard start != text.startIndex else { return text }
        rendered += text[start...]
        return rendered
    }

    /// A search result can show every indexed character and still have more authored source.
    static func exceedsInlineLimit(_ text: String) -> Bool {
        text.utf8.count > ContentSanitizer.maxMessageLength
            && text.prefix(ContentSanitizer.maxMessageLength).endIndex != text.endIndex
    }

    static func requiresReader(_ text: String) -> Bool {
        // Signal weights each newline as 16 UTF-8 bytes. Stop at the first
        // exceeded budget, including our existing inline rendering limit.
        var estimate = 0
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 13 || byte == 10 {
                if byte == 13 || !previousWasCR { estimate += 16 }
            } else {
                estimate += 1
            }
            previousWasCR = byte == 13
            if estimate > 8192 { return true }
        }
        return exceedsInlineLimit(text)
    }
}

private struct LongMessageSourceText: View {
    @Environment(AppState.self) private var appState
    let text: String
    @State private var document: String?

    var body: some View {
        Group {
            if let document {
                SourceTextView(document: document)
            } else {
                ProgressView()
            }
        }
        .task(id: text.contains("@") ? appState.profileRefreshGeneration : nil) {
            guard let prepared = try? await TranscriptMessagePreview.sourceText(text, displayName: { npub in
                guard let id = NostrProfileReference.pubkeyHex(fromBech32: npub) else { return nil }
                return appState.cachedKnownDisplayName(forAccountIdHex: id)
            }), !Task.isCancelled else { return }
            document = prepared
        }
    }
}

/// TextKit lays out the visible viewport of a single document, including long
/// lines that wrap across many screens.
private struct SourceTextView: UIViewRepresentable {
    let document: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if !view.text.utf8.elementsEqual(document.utf8) { view.text = document }
    }
}

nonisolated enum MessageBodyCollapsePresentation {
    static let maxCollapsedCharacters = 900
    static let maxCollapsedLines = 12
    static let collapsedBodyMaxHeight: CGFloat = 260
    /// Read more's laid-out height and how far its hit area reaches past it,
    /// so the target stays at least 44 points tall at every text size. The
    /// outset fits the 5-point gap above the label and the compact bubble's
    /// bottom padding, so it never covers the body or gets clipped.
    static let readMoreMinHeight: CGFloat = 34
    static let readMoreHitOutset: CGFloat = 5

    /// A CR/LF pair is one Swift Character and starts a single new line.
    static func snippet(_ body: @autoclosure () -> String, isExpanded: Bool = false) -> String? {
        guard !isExpanded else { return nil }
        let text = body()
        var remainingLines = maxCollapsedLines
        for (offset, entry) in text.indices.enumerated() {
            if offset == maxCollapsedCharacters { return String(text[..<entry]) }
            if text[entry].isNewline {
                remainingLines -= 1
                if remainingLines == 0 { return String(text[..<entry]) }
            }
        }
        return nil
    }

    static func shouldCollapse(_ text: String) -> Bool {
        snippet(text) != nil
    }
}

/// One chat bubble. Aligned right for our own messages, left for everyone
/// else. Renders an optional quoted reply header, the message body, a
/// external time/delivery metadata, and any reaction chips.
/// A timeline pass rebuilds every row's `MessageBubble` value with fresh
/// closures, which SwiftUI cannot compare, so every bubble body used to re-run
/// on each pass. Equality covers what the bubble draws; handlers are compared
/// only by presence, because they act on the same record and view model. What
/// an identity lookup returns is read in `body`, so a changed name or avatar
/// redraws the bubble through Observation, not through this comparison.
extension MessageBubble: Equatable {
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.record == rhs.record
            && lhs.status == rhs.status
            && (lhs.showMessageActions == nil) == (rhs.showMessageActions == nil)
            && lhs.debugStyle == rhs.debugStyle
            && lhs.isDeleted == rhs.isDeleted
            && lhs.deletionSource == rhs.deletionSource
            && lhs.isEdited == rhs.isEdited
            && lhs.hasReports == rhs.hasReports
            && lhs.usesReviewLayout == rhs.usesReviewLayout
            && lhs.agentActivity == rhs.agentActivity
            && lhs.voiceTranscript == rhs.voiceTranscript
            && lhs.readingSpeech === rhs.readingSpeech
            && lhs.displaysReader == rhs.displaysReader
            && (!lhs.displaysReader || lhs.record.plaintext.utf8.elementsEqual(rhs.record.plaintext.utf8))
            && lhs.incompleteMarkdown == rhs.incompleteMarkdown
            && lhs.clusterPresentation == rhs.clusterPresentation
            && lhs.showsSenderIdentity == rhs.showsSenderIdentity
            && lhs.replyPreview == rhs.replyPreview
            && Self.sameMedia(lhs.mediaItems, rhs.mediaItems)
            && lhs.customEmoji == rhs.customEmoji
            && lhs.markdownBlocks == rhs.markdownBlocks
            && lhs.poll == rhs.poll
            && lhs.reactions == rhs.reactions
            && lhs.omittedReactionKinds == rhs.omittedReactionKinds
            && lhs.projectedReactionTotal == rhs.projectedReactionTotal
            && lhs.isBodyExpanded == rhs.isBodyExpanded
            && (lhs.onPollVote == nil) == (rhs.onPollVote == nil)
            && (lhs.onViewPollVotes == nil) == (rhs.onViewPollVotes == nil)
            && (lhs.identityName == nil) == (rhs.identityName == nil)
            && (lhs.identityAvatar == nil) == (rhs.identityAvatar == nil)
            && (lhs.identityAvatarAsset == nil) == (rhs.identityAvatarAsset == nil)
            && lhs.mediaOpenScope == rhs.mediaOpenScope
            && (lhs.onOpenTranscriptMedia == nil) == (rhs.onOpenTranscriptMedia == nil)
            && (lhs.mediaForwardingContext == nil) == (rhs.mediaForwardingContext == nil)
            && (lhs.onGoToMessage == nil) == (rhs.onGoToMessage == nil)
            && (lhs.onViewEditHistory == nil) == (rhs.onViewEditHistory == nil)
            && (lhs.onTapReaction == nil) == (rhs.onTapReaction == nil)
            && (lhs.onFailedTap == nil) == (rhs.onFailedTap == nil)
            && (lhs.onSenderAvatarTap == nil) == (rhs.onSenderAvatarTap == nil)
    }

    /// `MessageMediaAttachment`'s own equality leaves out the fields that decide
    /// how an attachment loads, and a row must redraw when those change.
    private static func sameMedia(_ lhs: [MessageMediaAttachment], _ rhs: [MessageMediaAttachment]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left == right
                && left.localTarget == right.localTarget
                && left.sourceHint == right.sourceHint
                && left.demand == right.demand
                && left.thumbnail === right.thumbnail
        }
    }
}

struct MessageBubble: View {
    struct MediaOpenScope: Equatable {
        let model: ObjectIdentifier
        let client: ObjectIdentifier?
        let account: String?
        let generation: Int
        let attachmentRevision: Int

        init(_ viewModel: ConversationViewModel, appState: AppState) {
            model = ObjectIdentifier(viewModel)
            client = appState.client.map(ObjectIdentifier.init)
            account = appState.activeAccountRef
            generation = appState.runtimeGeneration
            attachmentRevision = AttachmentPresentationState.shared.revision
        }

        func matchesConversation(_ other: Self) -> Bool {
            model == other.model && account != nil && account == other.account && attachmentRevision == other.attachmentRevision
        }

        func isCurrent(_ viewModel: ConversationViewModel?, appState: AppState) -> Bool {
            viewModel.map { Self($0, appState: appState) == self } == true
        }
    }

    @Environment(\.messageActionBodySize) private var actionBodySize
    @Environment(\.messageActionHoldsEnabled) private var messageActionHoldsEnabled
    @Environment(\.actionRowMeasurementKey) private var actionRowMeasurementKey
    @Environment(AppState.self) private var appState
    @Environment(\.appDensity) private var density
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    let record: AppMessageRecordFfi
    let status: MessageStatus
    var showMessageActions: ((MessageActionSurface) -> Void)?
    var debugStyle: MessageDebugStyle? = nil
    var isDeleted: Bool = false
    var deletionSource: DeletionSourceFfi = .unknown
    var isEdited: Bool = false
    var hasReports: Bool = false
    var usesReviewLayout: Bool = false
    var agentActivity: AgentEventPresentation.Display?
    var clusterPresentation: MessageClusterPresentation = .none
    var showsSenderIdentity = true
    var replyPreview: ConversationReplyPreview? = nil
    var mediaItems: [MessageMediaAttachment] = []
    var voiceTranscript: VoiceTranscriptDisplay?
    var readingSpeech: ConversationSpeech?
    /// NIP-30 custom emoji drawn inline in the body; their attachments are
    /// already excluded from `mediaItems`.
    var customEmoji: CustomEmojiRowResolution = .empty
    var markdownBlocks: [MarkdownDisplayBlock]? = nil
    var incompleteMarkdown = false
    var poll: PollProjectionFfi? = nil
    var onPollVote: ((String) -> Void)? = nil
    var onViewPollVotes: (() -> Void)? = nil
    var reactions: [ConversationViewModel.ReactionTally] = []
    var omittedReactionKinds: UInt64 = 0
    var projectedReactionTotal: UInt64? = nil
    var identityName: ((String) -> String)? = nil
    var identityAvatar: ((String) -> URL?)? = nil
    var identityAvatarAsset: ((String) -> AvatarAssetFfi?)? = nil
    var onTapReaction: ((ConversationViewModel.ReactionTally) -> Void)?
    var onShowReactionDetails: (String?) -> Void = { _ in }
    var onReplyPreviewTap: () -> Void = {}
    var onLoadMedia = ConversationMediaLoader { _ in Data() }
    var mediaOpenScope: MediaOpenScope?
    var onOpenTranscriptMedia: ((MessageMediaAttachment, Data?) -> Void)?
    var mediaForwardingContext: MediaForwardingContext?
    /// Set when the timeline can scroll to a message; drives "Go to Message"
    /// in the fullscreen media viewer's More menu.
    var onGoToMessage: ((String) -> Void)? = nil
    /// Set when the message has viewable edit history; makes the inline "Edited"
    /// label tap to open the history sheet, the same sheet the actions menu opens.
    var onViewEditHistory: (() -> Void)? = nil
    /// Tapping the failure notice or a failed text bubble opens the
    /// retry/discard sheet.
    var onFailedTap: (() -> Void)? = nil
    var onSenderAvatarTap: (() -> Void)? = nil
    var displaysReader = false
    /// Owned by the list, not the bubble: a lazy list rebuilds rows that
    /// scroll away, and a "Read more" the reader chose must survive that.
    var isBodyExpanded = false
    var onExpandBody: () -> Void = {}

    @Environment(\.timelineSearchQuery) private var searchQuery
    @State private var readerProfile: String?
    @State private var mediaGallery: MessageMediaGallery?
    @State private var pendingExternalLink: PendingMessageExternalLink?
    @State private var showsUnsupportedEventData = false
    @State private var linkPreviewSettings = LinkPreviewSettingsStore.shared

    private var isFromMe: Bool {
        !usesReviewLayout && !displaysReader && MessageOwnership.isMine(
            direction: record.direction, sender: record.sender,
            myAccountId: appState.activeAccount?.accountIdHex
        )
    }

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
        Self.bodyText(
            for: record,
            hasMediaItems: !mediaItems.isEmpty,
            mentionDisplayName: { appState.mentionDisplayName(for: $0) }
        )
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
        guard debugStyle == nil, mediaItems.isEmpty else { return nil }
        return RemoteGiphyMedia.parse(wireText: record.plaintext)
    }

    private var linkPreviewURL: URL? {
        guard debugStyle == nil, linkPreviewSettings.showsPreviews else { return nil }
        return LinkPreviewMetadata.previewURL(in: markdownBlocks)
    }

    private var showsStandardBody: Bool {
        debugStyle?.isUserVisibleBubble ?? true
    }

    private var showsMediaUploadProgress: Bool {
        MessageMediaUploadPresentation.showsIndicator(status: status, items: mediaItems)
    }

    var standaloneEmoji: String? {
        guard agentActivity == nil, debugStyle == nil,
              !isDeleted,
              replyPreview == nil,
              mediaItems.isEmpty
        else { return nil }

        guard let emoji = SingleEmojiMessagePresentation.emoji(in: sanitizedBodyText), !offersSourceReader else { return nil }
        return emoji
    }

    private var standaloneCustomEmoji: CustomEmojiShortcode? {
        guard agentActivity == nil, debugStyle == nil,
              !isDeleted,
              replyPreview == nil,
              mediaItems.isEmpty,
              !customEmoji.isEmpty
        else { return nil }

        guard let shortcode = SingleCustomEmojiMessagePresentation.shortcode(in: sanitizedBodyText, resolvable: customEmoji.shortcodes),
              !offersSourceReader else { return nil }
        if let searchQuery, sanitizedBodyText.localizedStandardContains(searchQuery) { return nil }
        return shortcode
    }

    /// White-on-gradient text is only appropriate for our own user-visible bubbles.
    private var usesSentBubbleForeground: Bool {
        isFromMe && showsStandardBody
    }

    var body: some View {
        Group {
            if displaysReader {
                readerBody
                    .navigationDestination(item: $readerProfile) { npub in
                        ProfileContentView(npub: npub)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarRole(.editor)
                    }
            } else {
                transcriptRow
            }
        }
        .sheet(item: $pendingExternalLink) { link in
            MessageLinkActionSheet(
                url: link.url,
                onOpen: {
                    pendingExternalLink = nil
                    openURL(link.url)
                },
                onCopy: {
                    pendingExternalLink = nil
                    if let target = MessageLinkTarget(url: link.url) {
                        MessageLinkCopyAction.copy(target, presenting: appState)
                    }
                },
                onCancel: { pendingExternalLink = nil }
            )
            .appAppearance()
        }
    }

    /// Refresh media state in a timeline row without replacing an open reader and its scroll position.
    func refreshingAttachments(on revision: Int) -> some View {
        equatable().id(displaysReader ? nil : revision)
    }

    var readerShowsSource: Bool {
        if incompleteMarkdown { return true }
        guard markdownBlocks == nil else { return false }
        if TranscriptMessagePreview.exceedsInlineLimit(record.plaintext) { return true }
        guard record.plaintext.utf8.count > ContentSanitizer.maxMessageScalars else { return false }
        let scalars = record.plaintext.unicodeScalars
        return scalars.prefix(ContentSanitizer.maxMessageScalars).endIndex != scalars.endIndex
    }

    @ViewBuilder private var readerBody: some View {
        if readerShowsSource {
            // TextKit owns scrolling for the source reader.
            LongMessageSourceText(text: record.plaintext)
                .id(Data(record.plaintext.utf8))
        } else {
            ScrollView {
                messageBodyContent(snippet: nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var transcriptRow: some View {
        HStack(alignment: .messageSurfaceBottom, spacing: 0) {
            if isFromMe { Spacer(minLength: oppositeInset) }

            if showsSenderIdentity, !isFromMe, clusterPresentation.reservesIdentityLane {
                GroupMessageIdentityLane(
                    accountIdHex: record.sender,
                    showsAvatar: clusterPresentation.showsAvatar,
                    projectedName: identityName?(record.sender),
                    projectedAvatar: identityAvatar?(record.sender),
                    usesProjection: identityAvatar != nil,
                    nativeAsset: identityAvatarAsset?(record.sender),
                    usesNativeAsset: identityAvatarAsset != nil,
                    onTap: onSenderAvatarTap
                )
                .environment(\.avatarMonogramFont, .subheadline.weight(.semibold))
                .padding(.trailing, 7)
                .zIndex(1)
            }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                if showsSenderIdentity, !isFromMe, clusterPresentation.showsSenderName {
                    if let onSenderAvatarTap {
                        Button(action: onSenderAvatarTap) { senderLabel }.buttonStyle(.plain)
                    } else {
                        senderLabel
                    }
                }

                MessageBubbleChromeLayout(isFromMe: isFromMe, spacing: 0, widensTextForReactions: widensTextForReactions) {
                    messageSurface
                        .alignmentGuide(.messageSurfaceBottom) { $0[.bottom] }
                        .modifier(MessageActionHold(isEnabled: showMessageActions != nil) {
                            showMessageActions?(.bubble)
                        })
                        .background(alignment: .leading) { BubbleReplyIndicator() }
                        .background(alignment: .bottomTrailing) {
                            if !showsMetadataFooter {
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .accessibilityRepresentation {
                                        messageMetadataFooter.accessibilityElement(children: .combine)
                                    }
                                    .allowsHitTesting(false)
                            }
                        }
                        .background {
                            if let key = actionRowMeasurementKey {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: RowFramesKey.self, value: [
                                        RowFramePreference(part: .bubble, key: key, frame: proxy.frame(in: .global))
                                    ])
                                }
                            }
                        }
                    bubbleMetadataRow
                }
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: isFromMe ? .trailing : .leading)
            .modifier(ReplySwipeContentOffset())
            .layoutPriority(1)

            if !isFromMe { Spacer(minLength: oppositeInset) }
        }
        .padding(.horizontal, ChatBubbleMetrics.timelineMargin)
        .fullScreenCover(item: $mediaGallery) { gallery in
            MessageMediaFullscreenGalleryView(
                gallery: gallery,
                onLoadMedia: onLoadMedia,
                forwardingContext: mediaForwardingContext,
                onGoToMessage: onGoToMessage
            ) {
                mediaGallery = nil
            }
        }
        .sheet(isPresented: $showsUnsupportedEventData) {
            UnsupportedEventSheet(record: record, senderName: identityName?(record.sender))
                .appAppearance()
        }
    }

    private var senderLabel: some View {
        TimelineSearchText(identityName?(record.sender) ?? appState.displayName(forAccountIdHex: record.sender))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WNIdentityPalette.color(for: record.sender))
            .padding(.leading, 12)
    }

    @ViewBuilder
    private var messageSurface: some View {
        if isDeleted {
            deletedBubble
        } else if let sticker = record.sticker, showsStandardBody {
            stickerMessageContent(StickerKey(sticker))
        } else if record.kind == MessageSemantics.kindPoll, showsStandardBody {
            let rich = poll != nil || replyPreview != nil
            VStack(alignment: .leading, spacing: MessageBubbleReplyLayout.cardOuterInset) {
                if let replyPreview {
                    replyCard(replyPreview)
                }
                if let poll {
                    PollMessageContent(poll: poll, isFromMe: isFromMe, onVote: onPollVote,
                                       onViewVotes: onViewPollVotes)
                } else {
                    // MDK projects no tally for a malformed poll; never show its raw question.
                    Label {
                        TimelineSearchText(L10n.string("This poll can’t be displayed."))
                    } icon: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .font(.subheadline)
                    .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe))
                    .padding(.horizontal, rich ? MessageBubbleReplyLayout.cardOuterInset : density.metrics.bubbleHorizontalInset)
                    .padding(.vertical, rich ? 2 : density.metrics.bubbleVerticalInset)
                }
            }
            .frame(width: rich ? MessageBubbleReplyLayout.richContentWidth : nil, alignment: .leading)
            .padding(rich ? MessageBubbleReplyLayout.cardOuterInset : 0)
            .background { bubbleBackground }
            .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
            .opacity(status == .sending ? 0.7 : 1)
        } else if case .unsupportedEvent = MessageSemantics.classify(record), showsStandardBody {
            VStack(alignment: .leading, spacing: 0) {
                if let replyPreview {
                    replyHeader(replyPreview)
                }
                UnsupportedEventCard(
                    presentation: UnsupportedEventPresentation(record: record),
                    isFromMe: isFromMe
                ) {
                    showsUnsupportedEventData = true
                }
            }
            .background { bubbleBackground }
            .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
            .opacity(status == .sending ? 0.7 : 1)
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
        } else if let standaloneCustomEmoji {
            if status == .failed {
                standaloneCustomEmojiContent(standaloneCustomEmoji)
                    .contentShape(.rect)
                    .onTapGesture { onFailedTap?() }
            } else {
                standaloneCustomEmojiContent(standaloneCustomEmoji)
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

    @ViewBuilder
    private func stickerMessageContent(_ sticker: StickerKey) -> some View {
        let standsAlone = StickerBubbleLayout.standsAlone(plaintext: record.plaintext, hasReply: replyPreview != nil,
                                                          hasMedia: !mediaItems.isEmpty)
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
            if !standsAlone {
                if mediaItems.isEmpty {
                    textBubble
                } else {
                    mediaMessageContent
                }
            }
            StickerMessageContent(sticker: sticker, isFromMe: isFromMe)
        }
        .opacity(status == .sending ? 0.7 : 1)
    }

    private func standaloneEmojiContent(_ emoji: String) -> some View {
        TimelineSearchText(emoji)
            .font(.system(size: SingleEmojiMessagePresentation.fontSize))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
    }

    /// The ordinary bubble, with its own inline emoji or the literal
    /// shortcode, shows until the large image loads, and stays if it never
    /// does (auto-download off, a failed read).
    private func standaloneCustomEmojiContent(_ shortcode: CustomEmojiShortcode) -> some View {
        StandaloneCustomEmoji(
            shortcode: shortcode,
            side: SingleCustomEmojiMessagePresentation.side,
            isPixelArt: customEmoji.usesBuiltinArtwork(for: shortcode)
        ) {
            textBubble
        }
        .modifier(CustomEmojiInlineLoader(resolution: customEmoji, fixedPointSize: SingleCustomEmojiMessagePresentation.side))
    }

    private func remoteGiphyMessageContent(_ media: RemoteGiphyMedia) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let replyPreview {
                replyCard(replyPreview)
                    .padding(6)
            }
            RemoteGiphyMediaView(media: media, mayLoadAutomatically: isFromMe)
        }
        .frame(width: MessageBubbleReplyLayout.richContentWidth, alignment: .leading)
        .background { bubbleBackground }
        .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
        .opacity(status == .sending ? 0.7 : 1)
    }

    private var deletedBubble: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
            Text(
                deletionSource == .admin
                    ? L10n.string("This message was deleted by an admin.")
                    : deletionSource == .author && isFromMe
                        ? L10n.string("You deleted this message.")
                        : L10n.string("This message was deleted.")
            )
        }
        .font(.subheadline)
        .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe).opacity(0.8))
        .padding(.horizontal, density.metrics.bubbleHorizontalInset)
        .padding(.vertical, density.metrics.bubbleVerticalInset)
        .background { bubbleBackground }
        .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
    }

    private func replyHeader(_ preview: ConversationReplyPreview) -> some View {
        replyCard(preview)
            .padding(.horizontal, MessageBubbleReplyLayout.cardOuterInset)
            .padding(.vertical, MessageBubbleReplyLayout.cardOuterInset)
    }

    private func replyCard(_ preview: ConversationReplyPreview) -> some View {
        quoted(preview)
            .padding(.leading, MessageBubbleReplyLayout.cardCornerRadius)
            .padding(.trailing, MessageBubbleReplyLayout.cardOuterInset)
            .padding(.vertical, MessageBubbleReplyLayout.cardVerticalInset)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                replyCardBackground,
                in: .rect(
                    cornerRadius: MessageBubbleReplyLayout.cardCornerRadius,
                    style: .continuous
                )
            )
            .contentShape(
                .rect(
                    cornerRadius: MessageBubbleReplyLayout.cardCornerRadius,
                    style: .continuous
                )
            )
            .onTapGesture(perform: onReplyPreviewTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L10n.formatted("Reply to %@", preview.name))
            .accessibilityAction { onReplyPreviewTap() }
    }

    private var textBubble: some View {
        let location = showsStandardBody ? sharedLocation : nil
        let previewURL = showsStandardBody && location == nil ? linkPreviewURL : nil
        let fitsQuote = replyPreview != nil && showsStandardBody && location == nil && previewURL == nil
        return MessageTextBubbleLayout(fitsQuote: fitsQuote, widensForReactions: widensTextForReactions) {
            VStack(alignment: .leading, spacing: 0) {
                if let debugStyle {
                    debugHeader(debugStyle)
                }
                if let replyPreview, showsStandardBody {
                    replyHeader(replyPreview)
                }
                if let agentActivity {
                    AgentActivityContent(display: agentActivity)
                        .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: usesSentBubbleForeground))
                        .padding(.horizontal, density.metrics.bubbleHorizontalInset)
                        .padding(.vertical, density.metrics.bubbleVerticalInset)
                    if let debugStyle { debugTagsFooter(debugStyle) }
                } else if showsStandardBody {
                    if let location {
                        sharedLocationBody(location)
                    } else {
                        if let previewURL {
                            LinkPreviewCard(url: previewURL, isFromMe: isFromMe) {
                                _ = handleMessageLink(previewURL)
                            }
                            .id(previewURL)
                        }
                        messageBodyText(hasReply: replyPreview != nil)
                    }
                    if let debugStyle, debugStyle.isUserVisibleBubble {
                        debugTagsFooter(debugStyle)
                    }
                } else if let debugStyle {
                    debugPayload(debugStyle)
                }
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
                Label {
                    TimelineSearchText(L10n.string("Location"))
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : MessageBubblePalette.receivedForeground)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .background(replyCardBackground)
        .clipShape(.rect(cornerRadius: MessageBubbleReplyLayout.cardCornerRadius, style: .continuous))
        .padding([.horizontal, .bottom], MessageBubbleReplyLayout.cardOuterInset)
        .padding(.top, replyPreview == nil ? MessageBubbleReplyLayout.cardOuterInset : 0)
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

    private var isStandaloneUnsupportedAttachment: Bool {
        mediaItems.count == 1 && mediaItems.first?.rejectionKind == .unsupportedFormat
            && replyPreview == nil && !hasVisibleBodyText
    }

    private var mediaMessageContent: some View {
        let compact = isStandaloneUnsupportedAttachment
        let contentWidth = compact ? nil : MessageVisualMediaBubblePresentation.contentWidth(for: mediaItems, maxWidth: mediaGridWidth)
        return VStack(alignment: .leading, spacing: 6) {
            if let replyPreview {
                replyCard(replyPreview)
            }

            mediaAttachments

            if hasVisibleBodyText {
                messageBodyText(hasReply: false, richWidth: contentWidth)
            }
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, compact ? density.metrics.bubbleHorizontalInset : 6)
        .padding(.vertical, compact ? density.metrics.bubbleVerticalInset : 6)
        .background { bubbleBackground }
        .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
        .opacity(status == .sending ? 0.7 : 1)
    }

    private var mediaAttachments: some View {
        VStack(alignment: .leading, spacing: 6) {
            attachmentContent
            switch voiceTranscript {
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.caption)
                }
            case .text(let words):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribed").font(.caption2).foregroundStyle(.secondary)
                    Text(words).font(.body)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 3)
            case .checkFailed:
                let hint: LocalizedStringKey = messageActionHoldsEnabled && showMessageActions != nil
                    ? "Couldn’t verify the recording. Touch and hold this message to try again." : "Couldn’t verify the recording."
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)
            case nil: EmptyView()
            }
        }
    }

    private var attachmentContent: some View {
        MessageMediaAttachmentContent(
            messageID: record.messageIdHex, items: mediaItems,
            isFromMe: isFromMe,
            isStandaloneUnsupportedAttachment: isStandaloneUnsupportedAttachment,
            status: status,
            maxWidth: mediaGridWidth,
            onLoadMedia: onLoadMedia,
            onOpenImage: { openMedia($0, data: $1) },
            onOpenVideo: { openMedia($0) }
        )
        .overlay {
            if showsMediaUploadProgress {
                MessageMediaUploadIndicator(itemIds: mediaItems.map(\.id))
            }
        }
    }

    private func openMedia(_ item: MessageMediaAttachment, data: Data? = nil) {
        if let onOpenTranscriptMedia {
            onOpenTranscriptMedia(item, data)
        } else {
            mediaGallery = MessageMediaGallery(items: mediaItems, initialItem: item,
                initialMediaData: data, messageIdByItemID: mediaMessageIds)
        }
    }

    private var mediaMessageIds: [String: String] {
        guard !record.messageIdHex.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: mediaItems.map { ($0.id, record.messageIdHex) })
    }

    private var mediaGridWidth: CGFloat {
        MessageBubbleReplyLayout.richContentWidth
    }

    private func quoted(_ preview: ConversationReplyPreview) -> some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MessageBubblePalette.foreground(isFromMe: isFromMe))
                Group {
                    if preview.isPoll {
                        Label(preview.text, systemImage: "chart.bar.xaxis")
                    } else {
                        Text(preview.text)
                    }
                }
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
                .id(media.localTarget)
                .id(media.sourceHint)
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

    /// The complete source stays reachable for a durable row even when search expands the projected text.
    var offersSourceReader: Bool {
        !usesReviewLayout
            && (incompleteMarkdown || TranscriptMessagePreview.requiresReader(record.plaintext))
    }

    private func messageBodyText(hasReply: Bool, richWidth: CGFloat? = nil) -> some View {
        let snippet = MessageBodyCollapsePresentation.snippet(
            markdownBlocks?.flatMap { $0.textFields(for: .excerpt) }.joined(separator: "\n") ?? sanitizedBodyText,
            isExpanded: isBodyExpanded || searchQuery != nil
        )
        let fadesReviewExcerpt = usesReviewLayout && snippet != nil
        return VStack(alignment: .leading, spacing: 5) {
            messageBodyContent(snippet: snippet)
                // The body mask also needs room for mention corners outside the text bounds.
                .padding(.horizontal, TimelineTextRenderer.mentionHorizontalOutset)
                .frame(
                    maxHeight: fadesReviewExcerpt ? MessageBodyCollapsePresentation.collapsedBodyMaxHeight : nil,
                    alignment: .topLeading
                )
                .clipped()
                .mask {
                    if fadesReviewExcerpt {
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
                .padding(.horizontal, -TimelineTextRenderer.mentionHorizontalOutset)

            if snippet != nil || offersSourceReader {
                Button {
                    onExpandBody()
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.string("Read more"))
                        // The reader opens in a sheet, so only an inline expansion points down.
                        if !offersSourceReader {
                            Image(systemName: "chevron.down")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: MessageBodyCollapsePresentation.readMoreMinHeight)
                    // Reach a 44-point target without pushing the text further from the body.
                    .contentShape(Rectangle().inset(by: -MessageBodyCollapsePresentation.readMoreHitOutset))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground.opacity(0.9) : Color.accentColor)
            }
            if let readingSpeech {
                MessageReadingProgress(speech: readingSpeech)
                    .padding(.top, 6)
            }
        }
        .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : MessageBubblePalette.receivedForeground)
        .padding(
            .horizontal,
            richWidth != nil ? 6 : density.metrics.bubbleHorizontalInset
        )
        .padding(
            .top,
            richWidth != nil
                ? 0
                : (hasReply ? MessageBubbleReplyLayout.bodyTopInsetAfterReply : density.metrics.bubbleVerticalInset)
        )
        .padding(
            .bottom,
            richWidth != nil ? 2 : density.metrics.bubbleVerticalInset
        )
        .frame(
            width: richWidth,
            alignment: .leading
        )
        // Measure a reply body on the same width as its quote so a lifted excerpt keeps both edges.
        .frame(maxWidth: hasReply ? .infinity : nil, alignment: .leading)
        .frame(width: actionBodySize?.width, height: actionBodySize?.height, alignment: .topLeading)
        .background {
            if let key = actionRowMeasurementKey {
                GeometryReader { proxy in
                    Color.clear.preference(key: RowFramesKey.self, value: [
                        RowFramePreference(part: .body, key: key, frame: CGRect(origin: .zero, size: proxy.size))
                    ])
                }
            }
        }
    }

    @ViewBuilder
    private func messageBodyContent(snippet: String?) -> some View {
        if customEmoji.isEmpty {
            messageBodyTextContent(snippet: snippet)
        } else {
            messageBodyTextContent(snippet: snippet)
                .modifier(CustomEmojiInlineLoader(resolution: customEmoji))
        }
    }

    @ViewBuilder
    private func messageBodyTextContent(snippet: String?) -> some View {
        if let blocks = markdownBlocks {
            let quoteColor = isFromMe ? MessageBubblePalette.sentForeground.opacity(0.8) : Color.accentColor
            let visible = snippet.map {
                MarkdownDisplayBlock.excerpt(blocks, characterBudget: $0.count, emoji: customEmoji.shortcodes,
                                             countingBlockSeparators: true)
            } ?? blocks
            Group {
                if actionBodySize != nil, visible.count == 1, let inline = visible[0].inlineText, customEmoji.isEmpty {
                    liftedInlineText(inline)
                } else if actionBodySize != nil {
                    ViewThatFits(in: .vertical) {
                        // The measured body exceeds this frame. Start with a bounded
                        // excerpt and keep whole code or quote lines where possible.
                        ForEach(MarkdownDisplayBlock.menuExcerptBudgets(for: visible), id: \.self) { budget in
                            MarkdownMessageView(blocks: MarkdownDisplayBlock.excerpt(visible, characterBudget: budget, emoji: customEmoji.shortcodes),
                                                quoteBar: quoteColor)
                        }
                        Text(verbatim: "…")
                    }
                } else {
                    MarkdownMessageView(blocks: visible, quoteBar: quoteColor)
                }
            }
            .tint(MessageBubblePalette.foreground(isFromMe: isFromMe))
            .environment(\.messageTextIsOutgoing, isFromMe)
            .environment(\.openURL, OpenURLAction(handler: handleMessageLink))
            .environment(\.copyMessageLink, MessageLinkCopyAction { [appState] target in
                MessageLinkCopyAction.copy(target, presenting: appState)
            })
        } else {
            // Records without parsed tokens (non-chat kinds, optimistic
            // sends, pre-markdown history) keep the plain path.
            let text = AttributedString(snippet.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "…" } ?? sanitizedBodyText)
            if actionBodySize != nil {
                liftedInlineText(text)
            } else {
                MarkdownLinkText(text.highlightingTimelineMatches(searchQuery))
            }
        }
    }

    /// The fixed-height lifted bubble also contains padding and can contain Read more.
    /// Give the native text its actual remaining space so it truncates on a whole line.
    private func liftedInlineText(_ text: AttributedString) -> some View {
        GeometryReader { proxy in
            let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
            MarkdownLinkText(text.highlightingTimelineMatches(searchQuery))
                .lineLimit(max(1, Int(ceil(proxy.size.height / lineHeight))))
                .truncationMode(.tail)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func handleMessageLink(_ url: URL) -> OpenURLAction.Result {
        switch MessageLinkPolicy.action(for: url) {
        case .openProfile(let npub):
            if displaysReader { readerProfile = npub } else { appState.presentProfile(npub: npub) }
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

    private var replyCardBackground: Color {
        let opacity = isFromMe
            ? MessageBubbleReplyLayout.sentCardOpacity
            : MessageBubbleReplyLayout.receivedCardOpacity
        return (isFromMe ? MessageBubblePalette.sentForeground : MessageBubblePalette.receivedForeground)
            .opacity(opacity)
    }

    private var showsReactionStrip: Bool {
        !isDeleted && (!reactions.isEmpty || omittedReactionKinds > 0)
    }

    private var widensTextForReactions: Bool {
        showsReactionStrip && sharedLocation == nil && linkPreviewURL == nil
            && record.sticker == nil && record.kind != MessageSemantics.kindPoll && remoteGiphyMedia == nil
            && mediaItems.isEmpty && standaloneEmoji == nil && standaloneCustomEmoji == nil && debugStyle == nil
    }

    private var showsMetadataFooter: Bool {
        clusterPresentation.showsFooter(status: status, isDeleted: isDeleted, isEdited: isEdited,
                                        reported: hasReports)
    }

    @ViewBuilder
    private var bubbleMetadataRow: some View {
        if let notice = MessageFailureNotice(status: status, isDeleted: isDeleted, isEdited: isEdited,
                                            hasReports: hasReports, action: onFailedTap) {
            VStack(alignment: .trailing, spacing: 0) {
                if showsReactionStrip { reactionMetadata(showsTimestamp: false) }
                failedNotice(notice)
            }
        } else if !showsReactionStrip {
            if showsMetadataFooter {
                metadataWithoutReactions.padding(.top, density.metrics.bubbleMetadataSpacing)
            }
        } else {
            reactionMetadata(showsTimestamp: showsMetadataFooter)
        }
    }

    private func failedNotice(_ notice: MessageFailureNotice) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(action: notice.action) {
                MessageMetadataFooter(caption: .failureNotice, isEdited: false, status: .failed, isFromMe: true)
                    .multilineTextAlignment(.trailing)
            }
            .buttonStyle(.plain)
            .modifier(MessageActionHold(surface: .failureNotice, isEnabled: showMessageActions != nil) {
                showMessageActions?(.failureNotice)
            })
            if notice.showsTimestamp {
                MessageMetadataFooter(caption: .timestamp(timeLabel), isEdited: isEdited, status: status, isFromMe: isFromMe,
                    showsDeliveryStatus: false, hasReports: hasReports,
                    onViewEditHistory: onViewEditHistory)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, density.metrics.bubbleHorizontalInset)
        .padding(.top, density.metrics.bubbleMetadataSpacing)
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
        .padding(.horizontal, density.metrics.bubbleHorizontalInset)
    }

    private func reactionMetadata(showsTimestamp: Bool) -> some View {
        let allPills = reactions
        let pills = Array(allPills.prefix(ReactionPillPresentation.maximumRenderedPills))
        let preHiddenCount = allPills.count - pills.count + Int(clamping: min(omittedReactionKinds, UInt64(Int.max - allPills.count)))
        let totalCount = projectedReactionTotal.map { Int(clamping: $0) } ?? allPills.reduce(0) { $0 + $1.count }
        let mine = allPills.contains(where: \.mine)

        return ReactionMetadataRowLayout(reactionsOnLeadingEdge: isFromMe) {
            ReactionPillLayout(preHiddenReactionCount: preHiddenCount, alignsLeading: isFromMe) {
                ForEach(Array(pills.enumerated()), id: \.element.emoji) { index, tally in
                    reactionChip(emoji: tally.emoji, mine: tally.mine, onTap: {
                        if let onTapReaction { onTapReaction(tally) } else { onShowReactionDetails(tally.emoji) }
                    }) {
                        reactionLabel(tally)
                    }
                    .layoutValue(key: ReactionMetadataSubviewRoleKey.self, value: .reaction(index))
                }
                ForEach(0..<max(1, pills.count), id: \.self) { hiddenRenderedCount in
                    let hiddenCount = preHiddenCount + hiddenRenderedCount
                    if hiddenCount > 0 {
                        let includesMine = allPills.suffix(hiddenRenderedCount + allPills.count - pills.count).contains(where: \.mine)
                        reactionChip(emoji: nil, mine: includesMine, onTap: { onShowReactionDetails(nil) }) {
                            if pills.isEmpty {
                                Text(L10n.string("Reactions"))
                            } else {
                                Text("+\(hiddenCount)")
                                    .font(.system(size: ReactionPillPresentation.symbolSize, weight: .bold).monospacedDigit())
                            }
                        }
                        .layoutValue(key: ReactionMetadataSubviewRoleKey.self, value: .overflow(hiddenCount))
                    }
                }
            }
            .clipped()
            .contentShape(.rect)
            .accessibilityRepresentation {
                Button(L10n.string("Reactions")) { onShowReactionDetails(nil) }
                    .accessibilityValue(L10n.plural("%lld reactions", Int64(totalCount)))
                    .accessibilityAddTraits(mine ? .isSelected : [])
                    .accessibilityActions {
                        if let onTapReaction {
                            ForEach(pills, id: \.emoji) { tally in
                                let name = CustomEmojiShortcode.spokenReaction(tally.emoji)
                                let removes = tally.mine && ReactionPillPresentation.canRemoveIndividually(
                                    tally.emoji, from: allPills, omittedKinds: omittedReactionKinds
                                )
                                Button(removes ? L10n.formatted("Remove reaction %@", name) : name) { onTapReaction(tally) }
                            }
                        }
                    }
            }

            if showsTimestamp {
                messageMetadataFooter
            }
        }
        .padding(.horizontal, density.metrics.bubbleHorizontalInset)
        // Only the visible capsule overlaps the lower edge of the message.
        .padding(.top, -7)
    }

    private func reactionChip<Label: View>(emoji: String?, mine: Bool, onTap: @escaping () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
        label()
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 7)
            .frame(minWidth: ReactionPillPresentation.minimumWidth)
            .frame(height: ReactionPillPresentation.height)
            .background(mine ? Color(.systemGray4) : Color(.secondarySystemBackground), in: Capsule())
            .overlay { Capsule().strokeBorder(Color(.opaqueSeparator), lineWidth: 1) }
            .fixedSize()
            .frame(height: 44, alignment: .top)
            // The strip proposes zero width to omitted chips, including their hit targets.
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            .contentShape(.rect)
            .gesture(
                LongPressGesture()
                    .onEnded { _ in onShowReactionDetails(emoji) }
                    .exclusively(before: TapGesture().onEnded(onTap))
            )
    }

    private func reactionLabel(_ tally: ConversationViewModel.ReactionTally) -> some View {
        HStack(spacing: 2) {
            CustomEmojiReactionLabel(emoji: tally.emoji, reactionMessageIdHex: tally.reactionMessageIdHex,
                                     pointSize: ReactionPillPresentation.symbolSize, maximumPointSize: ReactionPillPresentation.height - 2)
                .font(.system(size: ReactionPillPresentation.symbolSize, weight: .bold))
            if tally.count > 1 {
                Text(L10n.formatted("%lld", Int64(tally.count)))
            }
        }
    }

    private var messageMetadataFooter: some View {
        MessageMetadataFooter(
            caption: .timestamp(timeLabel),
            isEdited: isEdited && !isDeleted,
            status: status,
            isFromMe: isFromMe,
            showsDeliveryStatus: MessageTombstonePresentation.showsDeliveryStatus(isDeleted: isDeleted),
            hasReports: hasReports,
            onViewEditHistory: onViewEditHistory
        )
    }

    private var timeLabel: String {
        _ = appState.markdownTimestampClock.formatGeneration
        return Self.timeLabel(recordedAt: record.recordedAt)
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

    static func timeLabel(
        recordedAt: UInt64,
        locale: Locale = .autoupdatingCurrent,
        formatters: RelativeTimeFormatters? = nil
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(recordedAt))
        return RelativeTime.shortTime(date, locale: locale, formatters: formatters)
    }
}

/// Spinner over a sending media bubble; a ring once a single file-backed
/// upload reports byte progress. Only this view observes the progress store.
private struct MessageMediaUploadIndicator: View {
    @Environment(\.mediaUploadProgress) private var progressStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let itemIds: [String]

    var body: some View {
        let fraction = progressStore?.fraction(forItemIds: itemIds)
        ZStack {
            if let fraction {
                Circle()
                    .stroke(.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            }
        }
        .padding(fraction == nil ? 0 : 12)
        .frame(width: 48, height: 48)
        .background(.black.opacity(0.55), in: Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Sending…"))
        .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
        .allowsHitTesting(false)
    }
}

private struct GroupMessageIdentityLane: View {
    @Environment(AppState.self) private var appState
    let accountIdHex: String
    let showsAvatar: Bool
    var projectedName: String? = nil
    var projectedAvatar: URL? = nil
    var usesProjection = false
    var nativeAsset: AvatarAssetFfi?
    var usesNativeAsset = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if showsAvatar, let onTap {
                Button(action: onTap) {
                    avatar
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint(L10n.string("View Profile"))
            } else if showsAvatar {
                avatar
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var title: String {
        if usesNativeAsset {
            return projectedName ?? L10n.string("Unknown user")
        }
        return projectedName ?? appState.displayName(forAccountIdHex: accountIdHex)
    }

    private var avatar: GroupMessageAvatar {
        GroupMessageAvatar(
            accountIdHex: accountIdHex,
            title: title,
            pictureURL: usesNativeAsset ? nil
                : usesProjection ? projectedAvatar : appState.avatarURL(forAccountIdHex: accountIdHex),
            nativeAsset: nativeAsset,
            usesNativeAsset: usesNativeAsset
        )
    }
}

private struct GroupMessageAvatar: View {
    let accountIdHex: String
    let title: String
    let pictureURL: URL?
    let nativeAsset: AvatarAssetFfi?
    let usesNativeAsset: Bool

    var body: some View {
        if usesNativeAsset {
            NativeAvatarBubble(seed: accountIdHex, title: title, asset: nativeAsset)
        } else {
            AvatarBubble(seed: accountIdHex, title: title, pictureURL: pictureURL)
        }
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
    let alignsLeading: Bool

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
        return CGSize(width: fit.requiredWidth, height: fit.height)
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
            subviews[index].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }

        let reactionIndices = fit.reactionIndices
        var x = alignsLeading ? bounds.minX : max(bounds.minX, bounds.maxX - fit.requiredWidth)
        for index in reactionIndices {
            let size = cache.sizes[index]
            // Center each capsule in a touch target that reaches halfway into each gap.
            let slotWidth = size.width + ReactionMetadataFitting.pillSpacing
            subviews[index].place(
                at: CGPoint(x: x - ReactionMetadataFitting.pillSpacing / 2, y: bounds.midY - size.height / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: slotWidth, height: size.height)
            )
            x += slotWidth
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
    struct Measurement {
        let width: CGFloat
        let reactions: CGSize
        let footer: CGSize
        let stacksFooter: Bool

        var height: CGFloat {
            stacksFooter ? reactions.height + footer.height : max(reactions.height, footer.height)
        }
    }

    let reactionsOnLeadingEdge: Bool

    func makeCache(subviews: Subviews) -> Measurement? { nil }

    func updateCache(_ cache: inout Measurement?, subviews: Subviews) {
        cache = nil
    }

    private func measure(width proposedWidth: CGFloat?, subviews: Subviews) -> Measurement {
        let strip = subviews[0]
        let footer = subviews.dropFirst().first?.sizeThatFits(.unspecified) ?? .zero
        let reserved = footer.width > 0 ? footer.width + ReactionMetadataFitting.metadataSpacing : 0
        let idealWidth = (strip.sizeThatFits(.unspecified).width + reserved).rounded(.up)
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        let available = max(0, width - reserved)
        var reactions = strip.sizeThatFits(.init(width: available, height: nil))
        let stacksFooter = footer.width > 0 && reactions.width > available
        if stacksFooter {
            reactions = strip.sizeThatFits(.init(width: width, height: nil))
        }
        return Measurement(width: max(width, reactions.width, footer.width), reactions: reactions,
                           footer: footer, stacksFooter: stacksFooter)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurement?) -> CGSize {
        let measurement = measure(width: proposal.width, subviews: subviews)
        cache = measurement
        return CGSize(width: measurement.width, height: measurement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurement?) {
        let row: Measurement
        if let cache, cache.width == bounds.width {
            row = cache
        } else {
            row = measure(width: bounds.width, subviews: subviews)
        }
        let reactionX = reactionsOnLeadingEdge ? bounds.minX : bounds.maxX - row.reactions.width
        let reactionY = row.stacksFooter ? bounds.minY : bounds.midY - row.reactions.height / 2
        subviews[0].place(at: CGPoint(x: reactionX, y: reactionY), anchor: .topLeading,
                          proposal: ProposedViewSize(row.reactions))
        if let footer = subviews.dropFirst().first {
            let footerX = reactionsOnLeadingEdge ? bounds.maxX - row.footer.width : bounds.minX
            let footerY = row.stacksFooter ? bounds.minY + row.reactions.height
                : min(bounds.midY - row.footer.height / 2 + 7, bounds.maxY - row.footer.height)
            footer.place(at: CGPoint(x: footerX, y: footerY), anchor: .topLeading,
                         proposal: ProposedViewSize(row.footer))
        }
    }
}

private struct PendingMessageExternalLink: Identifiable, Equatable {
    let url: URL

    var id: String { url.absoluteString }
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

private struct MessageMediaGrid: View {
    let items: [MessageMediaAttachment]
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    private let cornerRadius: CGFloat = 12

    private var visibleItems: [MessageMediaAttachment] {
        Array(items.prefix(MessageMediaGridPresentation.visibleCount(totalCount: items.count)))
    }

    private var layout: MessageMediaGridLayout {
        MessageMediaGridPresentation.layout(totalCount: items.count, maxWidth: maxWidth)
    }

    var body: some View {
        let resolvedLayout = layout
        let resolvedItems = visibleItems
        ZStack(alignment: .topLeading) {
            ForEach(Array(resolvedLayout.frames.enumerated()), id: \.offset) { index, frame in
                if index < resolvedItems.count {
                    MessageMediaTile(
                        item: resolvedItems[index],
                        isFromMe: isFromMe,
                        size: frame.size,
                        hiddenCount: index == resolvedItems.count - 1
                            ? resolvedLayout.overflowCount
                            : 0,
                        showsVideoDuration: !resolvedLayout.threeAcrossTiles.contains(index),
                        onLoadMedia: onLoadMedia,
                        onOpenImage: onOpenImage,
                        onOpenVideo: onOpenVideo
                    )
                    .id(resolvedItems[index].id)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: resolvedLayout.size.width, height: resolvedLayout.size.height, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: cornerRadius))
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
    let messageID: String
    let items: [MessageMediaAttachment]
    let isFromMe: Bool
    let isStandaloneUnsupportedAttachment: Bool
    let status: MessageStatus
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    var body: some View {
        let album = items.filter(\.isTranscriptGalleryMedia)
        VStack(alignment: .leading, spacing: 6) {
            if album.count == 1, let first = album.first {
                tile(first, size: MessageVisualMediaBubblePresentation.displaySize(maxWidth: maxWidth, dim: first.dim))
            } else if !album.isEmpty {
                MessageMediaGrid(items: album, isFromMe: isFromMe, maxWidth: maxWidth, onLoadMedia: onLoadMedia,
                    onOpenImage: onOpenImage, onOpenVideo: onOpenVideo)
            }
            ForEach(MessageMediaAttachment.inlineRows(items, outgoing: isFromMe)) { row in
                let item = row.item
                if item.rejectionKind == .unsupportedFormat {
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .overlay { Image(systemName: "line.diagonal").rotationEffect(.degrees(90)) }
                            .accessibilityHidden(true)
                        Text(L10n.string("Unsupported attachment."))
                    }
                    .font(.subheadline)
                    .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe))
                    .frame(maxWidth: isStandaloneUnsupportedAttachment ? nil : .infinity,
                           minHeight: isStandaloneUnsupportedAttachment ? nil : 44, alignment: .leading)
                    .padding(isStandaloneUnsupportedAttachment ? 0 : 8)
                } else if let rejection = item.rejectionMessage {
                    Label(rejection, systemImage: "exclamationmark.document")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(8)
                } else if item.isGIF {
                    tile(item, size: CGSize(width: maxWidth, height: 188))
                } else if item.kind == .audio {
                    MessageAudioAttachmentView(item: item, isFromMe: isFromMe,
                        isUploading: MessageMediaUploadPresentation.isUploading(item, status: status),
                        width: maxWidth, onLoadMedia: onLoadMedia)
                } else {
                    MessageDocumentAttachmentView(messageID: messageID, item: item, isFromMe: isFromMe, onLoadMedia: onLoadMedia)
                }
            }
        }
    }

    private func tile(_ item: MessageMediaAttachment, size: CGSize) -> some View {
        MessageMediaTile(item: item, isFromMe: isFromMe, size: size, hiddenCount: 0,
            onLoadMedia: onLoadMedia, onOpenImage: onOpenImage, onOpenVideo: onOpenVideo)
            .id(item.id)
            .clipShape(.rect(cornerRadius: 12))
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
    let threeAcrossTiles: Range<Int>
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
        var threeAcrossTiles = 0..<0

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
            threeAcrossTiles = 2..<5
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
            threeAcrossTiles: threeAcrossTiles,
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

nonisolated enum MessageVisualMediaBubblePresentation {
    static func contentWidth(for items: [MessageMediaAttachment], maxWidth: CGFloat) -> CGFloat {
        // File and unavailable rows fit the enclosing bubble. Visual tiles and
        // audio players each have a size of their own.
        let media = items.filter { $0.rejectionKind == nil && ($0.isImage || $0.isVideo || $0.isAudio) }
        guard media.count == 1, let visual = media.first,
              visual.isTranscriptGalleryMedia, visual.isImage || items.count == 1 else { return maxWidth }
        return displaySize(maxWidth: maxWidth, dim: visual.dim).width
    }

    static func displaySize(maxWidth: CGFloat, dim: String?) -> CGSize {
        let extent = max(1, maxWidth)
        let square = CGSize(width: extent, height: extent)
        guard let parts = dim?.lowercased().split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false),
              parts.count == 2,
              let width = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let height = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              width.isFinite, height.isFinite, width > 0, height > 0 else { return square }

        let ratio = min(1 / 0.35, max(0.35, width / height))
        let minimumWidth = min(192, extent)
        var tileWidth = max(minimumWidth, min(extent, extent * ratio))
        var tileHeight = min(extent, extent / ratio)
        let shortSide = min(tileWidth, tileHeight)
        if shortSide > minimumWidth, shortSide > min(width, height) {
            let scale = minimumWidth / shortSide
            tileWidth *= scale
            tileHeight *= scale
        }
        return CGSize(width: max(1, tileWidth.rounded()), height: max(1, tileHeight.rounded()))
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

private struct MessageMediaTile: View {
    @Environment(\.mediaOpenIntent) private var openIntent
    @Environment(AppState.self) private var appState
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let size: CGSize
    let hiddenCount: Int
    var showsVideoDuration = true
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible
    @State private var image: UIImage?
    @State private var gifData: Data?
    @State private var gifReplay = 0
    @State private var loadedImageID: String?
    @State private var imageRequest = UUID()
    @State private var explicitReadInFlight = false
    @State private var isLoading = false
    @State private var didFail = false
    @State private var awaitingManualDownload = false

    private var thumbnailCacheKey: String {
        MessageMediaThumbnailPresentation.cacheKey(for: item)
    }

    var body: some View {
        ZStack {
            if item.isImage, loadedImageID == item.id, let image {
                AttachmentGIFPlayback(contentID: item.id, data: gifData, activity: isTimelineRowVisible ? .active : .inactive) { playback in
                    if let playback {
                        AttachmentGIFImage(data: playback.data, playbackID: playback.id, contentMode: .scaleAspectFill,
                            onCompletion: playback.finish)
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .id(gifReplay)
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    if isLoading || didFail {
                        Group {
                            if isLoading { ProgressView().tint(.white) }
                            else { Label("Retry", systemImage: "arrow.clockwise").font(.caption.weight(.semibold)) }
                        }
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .allowsHitTesting(false)
                    }
                }
            } else if item.isImage {
                imagePlaceholder
            } else if item.isVideo {
                MessageVideoAttachmentView(
                    item: item,
                    isFromMe: isFromMe,
                    width: size.width,
                    height: size.height,
                    showsBadges: hiddenCount == 0,
                    showsDuration: showsVideoDuration,
                    onLoadMedia: onLoadMedia
                )
                .id(item.id)
            } else {
                filePlaceholder
            }

            if hiddenCount > 0 {
                Color.black.opacity(0.5).allowsHitTesting(false)
                Text(L10n.formatted("+%lld", Int64(hiddenCount)))
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            } else if item.isGIF, loadedImageID == item.id, image != nil {
                Text("GIF")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }

            if awaitingManualDownload, !(item.isGIF && loadedImageID == item.id && image != nil) {
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
        .task(id: TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible,
            policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision)) {
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
        .onChange(of: isTimelineRowVisible) { _, visible in
            if !visible { gifData = nil }
        }
        .onTapGesture {
            let request = openIntent?.begin()
            if item.isGIF, loadedImageID == item.id, gifData != nil {
                gifReplay &+= 1
                return
            }
            if item.isVideo {
                onOpenVideo(item)
                return
            }
            if awaitingManualDownload {
                awaitingManualDownload = false
                Task { _ = await loadImageIfNeeded(scale: displayScale, demand: .explicit) }
                return
            }
            guard item.isImage else { return }
            let demand = AttachmentDemand.userTap(afterFailure: didFail)
            Task {
                if let data = await loadImageIfNeeded(scale: displayScale, demand: demand),
                   !item.isGIF, openIntent?.current == request {
                    onOpenImage(item, data)
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
            TimelineSearchText(item.fileName, keepsMatchVisible: true)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.tertiarySystemFill))
    }

    private func loadImageIfNeeded(scale: CGFloat, demand: AttachmentDemand = .automatic) async -> Data? {
        guard item.isImage, demand != .automatic || (!explicitReadInFlight && !didFail) else { return nil }
        let request = UUID()
        imageRequest = request
        explicitReadInFlight = demand != .automatic
        defer {
            if imageRequest == request {
                isLoading = false
                explicitReadInFlight = false
            }
        }
        let maxPixelSize = max(1, Int(ceil(max(size.width, size.height) * scale)))
        let cached = demand == .retry ? nil : MessageMediaThumbnailDecoder.cachedThumbnail(for: thumbnailCacheKey, maxPixelSize: maxPixelSize)
        // Identical photos share decoded thumbnails. An explicit open still needs
        // the tapped slot's own bytes and acquisition state.
        if let cached, demand == .automatic || item.reference == nil {
            image = cached.image
            gifData = item.isGIF ? cached.sourceData : nil
            loadedImageID = item.id
            didFail = false
            return cached.sourceData
        }
        isLoading = true
        didFail = false
        // host_media_prepare: bytes through decode, before the UI assignment.
        let analytics = appState.productAnalytics
        let prepareTiming = analytics.beginTiming()
        do {
            let requested = demand == .automatic ? item : item.forTranscriptPage
            let data = try await onLoadMedia.data(for: requested, demand: demand)
            guard !Task.isCancelled, imageRequest == request else {
                analytics.recordStage(.mediaPrepare, since: prepareTiming, outcome: .cancelled)
                return nil
            }
            let decoded: UIImage?
            if let cached {
                decoded = cached.image
            } else {
                let decodeTiming = analytics.beginTiming()
                decoded = await MessageMediaThumbnailDecoder.image(data: data, maxPixelSize: maxPixelSize, scale: scale)
                analytics.recordStage(.mediaDecode, since: decodeTiming, outcome: decoded == nil ? .failure : .success)
            }
            analytics.recordStage(.mediaPrepare, since: prepareTiming,
                                  outcome: decoded == nil ? .failure : Task.isCancelled ? .cancelled : .success)
            guard !Task.isCancelled, imageRequest == request else { return nil }
            guard let decoded else {
                image = nil
                gifData = nil
                loadedImageID = item.id
                didFail = demand.failureOffersRetry
                return nil
            }
            image = decoded
            gifData = item.isGIF ? data : nil
            loadedImageID = item.id
            if cached == nil {
                MessageMediaThumbnailDecoder.store(decoded, sourceData: data, for: thumbnailCacheKey, maxPixelSize: maxPixelSize)
            }
            return data
        } catch {
            analytics.recordStage(.mediaPrepare, since: prepareTiming,
                                  outcome: error is CancellationError ? .cancelled : .failure)
            guard !Task.isCancelled, imageRequest == request else { return nil }
            if loadedImageID != item.id {
                image = nil
                gifData = nil
                loadedImageID = item.id
            }
            didFail = demand.failureOffersRetry
            return nil
        }
    }
}

private struct MessageMediaPlaceholderBackground: View {
    let thumbhash: String?
    let fallbackSystemName: String?
    let width: CGFloat
    let height: CGFloat
    var usesSentBubbleColors = false

    @State private var image: UIImage?
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible

    var body: some View {
        ZStack {
            (usesSentBubbleColors
                ? MessageBubblePalette.sentForeground.opacity(MessageBubbleReplyLayout.sentCardOpacity)
                : Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if let fallbackSystemName {
                Image(systemName: fallbackSystemName)
                    .font(.title3)
                    .foregroundStyle(usesSentBubbleColors
                        ? AnyShapeStyle(MessageBubblePalette.sentSecondaryForeground)
                        : AnyShapeStyle(.secondary))
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
                MessageBubblePalette.foreground(isFromMe: isFromMe).opacity(0.10)
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
        .onReceive(NotificationCenter.default.publisher(for: MessageVideoThumbnailDecoder.playedPreviewDidChange)) { update in
            guard isTimelineRowVisible, item.isVideo, item.thumbnail == nil,
                  let key = update.object as? String, key == MessageVideoThumbnailPresentation.cacheKey(for: item),
                  let poster = MessageVideoThumbnailDecoder.cachedThumbnail(for: key, maxPixelSize: MessageVideoThumbnailDecoder.playedPosterPixelSize) else { return }
            image = poster
            loadedItemID = item.id
        }
        .task(id: TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible,
            policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision)) {
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
        let cached = MessageVideoThumbnailDecoder.cachedThumbnail(for: cacheKey, maxPixelSize: maxPixelSize)
            ?? MessageVideoThumbnailDecoder.cachedThumbnail(for: cacheKey, maxPixelSize: MessageVideoThumbnailDecoder.playedPosterPixelSize)
        if let cached {
            image = cached
            loadedItemID = item.id
            return
        }
        guard MediaAutoDownloadStore.shared.shouldAutoDownload(.video) else { return }
        let producerEpoch = MessageMediaCache.currentProducerEpoch()
        let revision = AttachmentPresentationState.shared.revision
        guard let data = try? await onLoadMedia.videoPreviewData(for: item), !Task.isCancelled,
              revision == AttachmentPresentationState.shared.revision else { return }
        guard let url = await MediaPlaybackFileStore.fileURL(
            for: item,
            data: data,
            producerEpoch: producerEpoch
        ), !Task.isCancelled else { return }
        guard let thumbnail = await MessageVideoThumbnailDecoder.thumbnail(
            url: url,
            maxPixelSize: maxPixelSize,
            scale: displayScale
        ), !Task.isCancelled, producerEpoch == MessageMediaCache.currentProducerEpoch(),
           revision == AttachmentPresentationState.shared.revision else { return }
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
        return try? await onLoadMedia.data(for: item, demand: .automatic)
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
    let showsBadges: Bool
    let showsDuration: Bool
    let onLoadMedia: ConversationMediaLoader

    @State private var previewThumbnail: UIImage?
    @State private var localDuration: Double?
    @State private var lastRead: (request: TimelineMediaTaskID, overPreviewLimit: Bool)?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible

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
            ?? playedPoster
    }

    private var playedPoster: UIImage? {
        MessageVideoThumbnailDecoder.cachedThumbnail(for: thumbnailCacheKey,
            maxPixelSize: MessageVideoThumbnailDecoder.playedPosterPixelSize)
    }

    private struct PreviewRequest: Equatable {
        let media: TimelineMediaTaskID
        let showsDuration: Bool
    }

    private var previewRequest: PreviewRequest {
        PreviewRequest(media: TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible,
            policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision, source: AttachmentHandoffSource(item)),
            showsDuration: showsBadges && showsDuration)
    }

    var body: some View {
        ZStack {
            if let thumbnail = displayThumbnail {
                Image(uiImage: thumbnail)
                    .resizable().scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                MessageMediaPlaceholderBackground(thumbhash: item.reference?.thumbhash,
                    fallbackSystemName: "play.rectangle", width: width, height: height, usesSentBubbleColors: isFromMe)
            }
            if showsBadges {
                VideoPreviewPlayOverlay(diameter: 34, style: .transcriptTile)
                if showsDuration, let duration = AudioDurationLabel.optionalLabel(for: item.durationSeconds ?? localDuration ?? MessageVideoThumbnailDecoder.duration(for: thumbnailCacheKey)) {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityLabel("Video attachment")
        .onReceive(NotificationCenter.default.publisher(for: MessageVideoThumbnailDecoder.playedPreviewDidChange)) { update in
            guard update.object as? String == thumbnailCacheKey else { return }
            if let playedPoster { previewThumbnail = playedPoster }
            localDuration = MessageVideoThumbnailDecoder.duration(for: thumbnailCacheKey)
        }
        .task(id: previewRequest) {
            let request = previewRequest.media
            guard request.isVisible, MediaAutoDownloadStore.shared.shouldAutoDownload(.video),
                  lastRead?.request != request || lastRead?.overPreviewLimit != true else { return }
            let needsPoster = displayThumbnail == nil
            let needsDuration = previewRequest.showsDuration && item.durationSeconds == nil
                && localDuration == nil && MessageVideoThumbnailDecoder.duration(for: thumbnailCacheKey) == nil
            guard needsPoster || needsDuration else {
                // Metadata can come from identical bytes in another message. Admit this
                // slot under the Videos preference without decoding the movie again.
                guard lastRead?.request != request, await onLoadMedia.admitAutomaticAttachment(item) != nil, !Task.isCancelled else { return }
                // A local hash overlay can disappear independently of this request.
                if item.localData == nil { lastRead = (request, false) }
                return
            }
            let epoch = MessageMediaCache.currentProducerEpoch()
            let data: Data
            do {
                data = try await onLoadMedia.videoPreviewData(for: item)
            } catch AttachmentReadError.previewLimitExceeded(let size) {
                // An unknown size can become available later. Known oversize files get a poster on playback.
                if size != nil, item.localData == nil, !Task.isCancelled { lastRead = (request, true) }
                return
            } catch { return }
            guard !Task.isCancelled else { return }
            if item.localData == nil { lastRead = (request, false) }
            guard let url = await MediaPlaybackFileStore.fileURL(for: item, data: data, producerEpoch: epoch),
                  !Task.isCancelled else { return }
            if needsDuration {
                let time = try? await AVURLAsset(url: url).load(.duration)
                guard !Task.isCancelled else { return }
                if let seconds = time?.seconds, seconds.isFinite, seconds > 0 {
                    localDuration = seconds
                    MessageVideoThumbnailDecoder.store(duration: seconds, for: thumbnailCacheKey)
                }
            }
            if needsPoster { await loadPreviewThumbnail(from: url, scale: displayScale) }
        }
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
        let result = await MessageVideoThumbnailDecoder.thumbnail(
            url: url,
            maxPixelSize: maxThumbnailPixelSize(scale: scale),
            scale: scale
        )
        guard !Task.isCancelled else { return }
        guard let thumbnail = result else { return }
        previewThumbnail = thumbnail
        MessageVideoThumbnailDecoder.store(
            thumbnail,
            for: thumbnailCacheKey,
            maxPixelSize: maxThumbnailPixelSize(scale: scale)
        )
    }
}

nonisolated enum MessageAudioPlayerPreparer {
    static func fileTypeHint(for item: MessageMediaAttachment) -> String? {
        if let mimeType = UTType(mimeType: item.mediaType)?.identifier {
            return mimeType
        }
        let ext = MediaAttachmentPolicy.fileExtension(for: item.mediaType, fileName: item.fileName)
        return UTType(filenameExtension: ext)?.identifier
    }

    static func preparedPlayer(from data: Data) async throws -> AVAudioPlayer {
        try await detachedPreparedValue(priority: .userInitiated) { () throws -> AVAudioPlayer in
            let next = try AVAudioPlayer(data: data)
            next.enableRate = true
            next.prepareToPlay()
            return next
        }
    }

    static func preparedPlayer(from url: URL, fileTypeHint: String? = nil) async throws -> AVAudioPlayer {
        try await detachedPreparedValue(priority: .userInitiated) { () throws -> AVAudioPlayer in
            let next: AVAudioPlayer
            if let fileTypeHint {
                next = try AVAudioPlayer(contentsOf: url, fileTypeHint: fileTypeHint)
            } else {
                next = try AVAudioPlayer(contentsOf: url)
            }
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

    static func duration(from url: URL, fileTypeHint: String? = nil) async -> Double? {
        await detachedValue(priority: .utility) {
            if let fileTypeHint {
                return try? AVAudioPlayer(contentsOf: url, fileTypeHint: fileTypeHint).duration
            }
            return try? AVAudioPlayer(contentsOf: url).duration
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

private struct MessageAudioAttachmentView: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let isUploading: Bool
    let width: CGFloat
    let onLoadMedia: ConversationMediaLoader

    @State private var player: AVAudioPlayer?
    @State private var playbackFile: AttachmentShareFile?
    @State private var playbackHandoffControl: MediaFileTransferControlFfi?
    @State private var prefetchedAudio: TimelineMediaTaskID?
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
    private var playIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption)
    private var speedBadgeWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .caption)
    private var speedBadgeHeight: CGFloat = 28
    private let speeds: [Float] = [1, 1.5, 2]
    private var metadataCacheKey: String {
        MessageAudioBubblePresentation.cacheKey(for: item)
    }

    private var prefetchID: TimelineMediaTaskID {
        TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible,
                            policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision, source: AttachmentHandoffSource(item))
    }

    init(
        item: MessageMediaAttachment,
        isFromMe: Bool,
        isUploading: Bool,
        width: CGFloat,
        onLoadMedia: ConversationMediaLoader
    ) {
        self.item = item
        self.isFromMe = isFromMe
        self.isUploading = isUploading
        self.width = width
        self.onLoadMedia = onLoadMedia
        _durationSeconds = State(initialValue: item.durationSeconds)
        _waveformSamples = State(initialValue: item.waveformSamples.isEmpty ? MediaWaveformAnalyzer.fallback() : item.waveformSamples)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: togglePlayback) {
                Group {
                    if isLoading || isUploading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: MessageAudioBubblePresentation.playbackIconName(isPlaying: isPlaying, didFail: didFail))
                            .font(.system(size: playIconSize, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isUploading)
            .accessibilityLabel(isUploading ? L10n.string("Sending…") : isPlaying ? L10n.string("Pause audio message") : L10n.string("Play audio message"))

            AudioWaveformView(samples: waveformSamples, progress: progress,
                              barColor: foregroundColor.opacity(0.4), playedColor: foregroundColor, fitsAvailableWidth: true)
                .frame(height: 32)

            if let duration = durationSeconds ?? item.durationSeconds,
               let remaining = MessageAudioBubblePresentation.durationLabel(duration * (1 - Double(progress))) {
                Text(remaining)
                    .font(.caption.monospacedDigit())
                    .fixedSize()
                    .padding(.horizontal, 6)
            }
            Button(action: cycleSpeed) {
                Text(speedLabel)
                    .font(.caption.weight(.bold))
                    .frame(width: speedBadgeWidth, height: speedBadgeHeight)
                    .background(controlFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed")
        }
        .foregroundStyle(foregroundColor)
        .frame(width: width)
        .onDisappear {
            stopPlayback()
        }
        .task(id: prefetchID) {
            let request = prefetchID
            guard request.isVisible, prefetchedAudio != request else { return }
            await prefetchIfNeeded(request)
        }
        .onChange(of: isTimelineRowVisible) { _, isVisible in
            if !isVisible { stopPlayback() }
        }
    }

    /// Prefetches audio only when the Audio auto-download preference allows it.
    private func prefetchIfNeeded(_ request: TimelineMediaTaskID) async {
        let metadata = MessageAudioMetadataCache.metadata(for: metadataCacheKey) ?? embeddedMetadata
        if let metadata { applyMetadata(metadata) }
        // Metadata can come from a different message with the same audio.
        // Automatic acquisition belongs to this row’s original slot.
        guard player == nil, !isLoading, MediaAutoDownloadStore.shared.shouldAutoDownload(.audio),
              let byteCount = await onLoadMedia.admitAutomaticAttachment(item), !Task.isCancelled else { return }
        if metadata == nil, byteCount <= MessageMediaAttachment.audioAnalysisByteLimit {
            var preview = item
            preview.previewByteLimit = MessageMediaAttachment.audioAnalysisByteLimit
            guard let data = try? await onLoadMedia.data(for: preview, demand: .automatic), !Task.isCancelled else { return }
            let analyzed = await audioMetadata(from: data)
            guard !Task.isCancelled else { return }
            applyMetadata(analyzed)
        }
        prefetchedAudio = request
    }

    private var foregroundColor: Color {
        isFromMe ? MessageBubblePalette.sentForeground : Color.primary
    }

    private var controlFill: Color {
        isFromMe ? MessageBubblePalette.sentForeground.opacity(0.18) : Color.primary.opacity(0.08)
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
        let demand = AttachmentDemand.userTap(afterFailure: didFail)
        isLoading = true
        didFail = false
        let control = MediaFileTransferControlFfi()
        playbackHandoffControl?.cancel()
        playbackHandoffControl = control
        defer {
            if playbackHandoffControl === control { playbackHandoffControl = nil }
            isLoading = false
        }
        do {
            let opened = try await onLoadMedia.playbackFile(
                for: item,
                demand: demand,
                initialData: item.localData,
                control: control
            )
            // The view may have disappeared (and `stopPlayback` cancelled this
            // task) while the decrypt/download was in flight. Bail before
            // touching player state or acquiring the audio-session lease so a
            // gone view never starts invisible, uncontrollable playback.
            guard AudioPlaybackLoadOutcome.resolve(isCancelled: Task.isCancelled || control.isCancelled()) == .proceed else {
                opened.finish()
                return
            }
            let fileTypeHint = MessageAudioPlayerPreparer.fileTypeHint(for: item)
            let metadata = await audioMetadata(fromFileURL: opened.url, fileTypeHint: fileTypeHint)
            let next = try await MessageAudioPlayerPreparer.preparedPlayer(from: opened.url, fileTypeHint: fileTypeHint)
            guard AudioPlaybackLoadOutcome.resolve(isCancelled: Task.isCancelled || control.isCancelled()) == .proceed else {
                opened.finish()
                return
            }
            player?.stop()
            playbackFile?.finish()
            playbackFile = opened
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
            if Task.isCancelled || control.isCancelled() || error is CancellationError { return }
            if error as? AttachmentHandoffFailure == .storageFull {
                isPlaying = false
                return
            }
            didFail = true
            isPlaying = false
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
        if let cached = MessageAudioMetadataCache.metadata(for: metadataCacheKey) ?? embeddedMetadata {
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

    private func audioMetadata(fromFileURL url: URL, fileTypeHint: String?) async -> MessageAudioMetadata {
        if let cached = MessageAudioMetadataCache.metadata(for: metadataCacheKey) ?? embeddedMetadata {
            return cached
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let analyzed: MediaWaveformAnalyzer.Metadata
        if fileSize <= MessageMediaAttachment.audioAnalysisByteLimit {
            analyzed = await Task.detached(priority: .utility) {
                MediaWaveformAnalyzer.metadata(fromFileURL: url)
            }.value
        } else {
            analyzed = MediaWaveformAnalyzer.Metadata(durationSeconds: nil, samples: MediaWaveformAnalyzer.fallback())
        }
        let duration: Double?
        if let analyzedDuration = analyzed.durationSeconds {
            duration = analyzedDuration
        } else {
            duration = await MessageAudioPlayerPreparer.duration(from: url, fileTypeHint: fileTypeHint)
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
        playbackHandoffControl?.cancel()
        playbackHandoffControl = nil
        // Cancel any in-flight load+play task. Without this, a load resolving
        // after the view disappeared would start playback (and acquire the
        // `.playback` lease) on a view that is no longer on screen.
        playbackLoadTask?.cancel()
        playbackLoadTask = nil
        let shouldDeactivate = isPlaying || player?.isPlaying == true || audioSessionLease != nil
        player?.stop()
        player = nil
        playbackFile?.finish()
        playbackFile = nil
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

struct LiftedDocumentDetails: Equatable {
    let id: String
    let revision: Int
    let name: String?
    let size: Int?
    let isOpening: Bool
    let didFail: Bool
}

private struct MessageDocumentAttachmentView: View {
    @Environment(AppState.self) private var appState
    let messageID: String
    @Environment(\.liftedDocuments) private var liftedDocuments
    @Environment(\.timelineSearchQuery) private var searchQuery
    @Environment(\.actionRowMeasurementKey) private var measurementKey
    @Environment(\.mediaOpenIntent) private var openIntent
    @Environment(\.timelinePreviewSearch) private var transcriptSearch
    @Environment(\.locale) private var locale
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let onLoadMedia: ConversationMediaLoader

    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: MessageDocumentPreview?
    @State private var openedDraftDigest: String?
    @State private var openingDraft: OpeningDraftDocument?
    @State private var openingID: UUID?
    @State private var openingTask: Task<Void, Never>?
    @State private var contactName: String?
    @State private var byteCount: Int?
    @State private var didFail = false
    @State private var share = DocumentSharePresentation()

    private var displayName: String? {
        liftedDetails?.name ?? contactName ?? transcriptSearch?.displayedContactName(for: item.id)
    }

    private var liftedDetails: LiftedDocumentDetails? {
        guard let details = liftedDocuments?[item.id],
              details.revision == AttachmentPresentationState.shared.revision else { return nil }
        return details
    }

    var body: some View {
        Button {
            guard openingID == nil || (openIntent != nil && openingID != openIntent?.current) else { return }
            let request = openIntent?.begin(cancelPendingOpen: cancelDocumentOpen) ?? UUID()
            openingID = request
            openingDraft = OpeningDraftDocument(item, outgoing: isFromMe)
            openingTask = Task { await openDocument(request) }
        } label: {
            HStack(spacing: 8) {
                if DocumentPreviewFormat(for: item) == .contact {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .background(.quaternary, in: Circle())
                } else {
                    Image(systemName: fileSymbol)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground : Color.accentColor)
                        .frame(width: 24, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 2) {
                    let name = displayName
                    TimelineSearchText(name ?? item.fileName, keepsMatchVisible: true)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    if let name, name != item.fileName, let searchQuery, item.fileName.localizedStandardContains(searchQuery) {
                        TimelineSearchText(item.fileName, keepsMatchVisible: true)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(fileDetail)
                        .font(.caption)
                        .foregroundStyle(isFromMe ? MessageBubblePalette.sentForeground.opacity(0.74) : Color.secondary)
                }
                Spacer(minLength: 0)
                if liftedDetails?.isOpening ?? (openingID != nil) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isFromMe ? MessageBubblePalette.sentForeground : .accentColor)
                } else if liftedDetails?.didFail ?? didFail {
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
            .frame(maxWidth: .infinity)
            .background(documentSurface, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open attachment")
        .background {
            if let key = measurementKey {
                let details = LiftedDocumentDetails(id: item.id, revision: AttachmentPresentationState.shared.revision,
                    name: displayName, size: byteCount, isOpening: openingID != nil, didFail: didFail)
                Color.clear.preference(key: RowFramesKey.self, value: [.init(part: .document(details), key: key)])
            }
        }
        .onChange(of: contactName) { _, name in
            if let name { transcriptSearch?.registerContactName(name, for: item.id, in: messageID) }
        }
        .onChange(of: messageID) { _, confirmedID in
            if let contactName { transcriptSearch?.registerContactName(contactName, for: item.id, in: confirmedID) }
        }
        .sheet(item: $preview) { document in
            MessageDocumentPreviewSheet(preview: document, item: item, loader: onLoadMedia)
                .appAppearance()
        }
        .sheet(item: $share.file) { file in
            ActivityShareSheet(items: [file.url], onComplete: file.finish)
                .onDisappear(perform: file.finish)
        }
        .onDisappear { closeDocument() }
        .onChange(of: DocumentRuntimeScope(appState)) { _, _ in
            // Revoke the old reader and lease. The row's filename, size and search
            // fields follow their existing message/slot lifetime.
            closeDocument()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelDocumentOpen() }
        }
        .onChange(of: DocumentPreviewSource(item)) { previous, current in
            if let openingDraft, share.control == nil, openingDraft.update(to: item) { return }
            if !current.continues(previous, outgoing: isFromMe, openedDraftDigest: preview == nil ? nil : openedDraftDigest) {
                resetDocument()
            }
        }
        .task(id: TimelineMediaTaskID(contentID: item.id, isVisible: isTimelineRowVisible,
            policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision, source: AttachmentHandoffSource(item))) {
            guard liftedDocuments == nil else { return }
            let scope = DocumentRuntimeScope(appState)
            let metadata = await onLoadMedia.prefetchDocument(item, isVisible: isTimelineRowVisible,
                allowed: MediaAutoDownloadStore.shared.shouldAutoDownload(.document), hasContactName: displayName != nil)
            if !Task.isCancelled, DocumentRuntimeScope(appState) == scope, let metadata {
                byteCount = metadata.size
                if let name = metadata.contactName { contactName = name }
            }
        }
    }

    private var fileDetail: String {
        let type = fileExtension.isEmpty ? MediaAttachmentPolicy.canonicalMediaType(item.mediaType) : fileExtension.uppercased()
        guard let count = item.localData?.count ?? liftedDetails?.size ?? byteCount else { return type }
        return "\(type) • \(count.formatted(.byteCount(style: .file).locale(locale)))"
    }

    private var fileExtension: String {
        MediaAttachmentPolicy.fileExtension(for: item.mediaType, fileName: item.fileName).lowercased()
    }

    private var fileSymbol: String {
        switch fileExtension {
        case "pdf": "doc.richtext"
        case "doc", "docx", "txt": "doc.text"
        case "xls", "xlsx": "tablecells"
        case "zip": "archivebox"
        case "vcf", "vcard": "person.crop.circle"
        default: "doc"
        }
    }

    private var documentSurface: Color {
        if isFromMe {
            return MessageBubblePalette.sentForeground.opacity(0.16)
        }
        return MessageBubblePalette.receivedForeground.opacity(0.09)
    }

    private func openDocument(_ request: UUID) async {
        func isCurrent() -> Bool {
            !Task.isCancelled && openingID == request && (openIntent == nil || openIntent?.current == request)
        }
        defer {
            openIntent?.finish(request)
            if openingID == request {
                openingTask = nil
                openingDraft = nil
                openingID = nil
            }
        }
        guard isCurrent() else { return }
        let demand = AttachmentDemand.userTap(afterFailure: didFail)
        didFail = false
        do {
            let draft = openingDraft
            if let draft {
                guard await draft.verify(), isCurrent() else { return }
            }
            if let document = try await share.openDocument(item, using: onLoadMedia, demand: demand,
                isCurrent: isCurrent, handoffItem: { draft?.current ?? item }, didReadSize: { byteCount = $0 }), isCurrent() {
                openedDraftDigest = draft?.digest
                if case .contact(let card) = document.content { contactName = card.name }
                preview = document
            }
        } catch is CancellationError {
            return
        } catch AttachmentHandoffFailure.storageFull {
            // The attachment is held; only the copy needs room, so a Retry would not help.
            return
        } catch {
            if isCurrent() { didFail = true }
        }
    }

    private func resetDocument() {
        closeDocument()
        byteCount = nil
        contactName = nil
        didFail = false
    }

    private func cancelDocumentOpen() {
        guard let request = openingID else { return }
        openIntent?.finish(request)
        // Native handoffs must finish through the transfer control so their lease is released.
        if share.control != nil { share.close() } else { openingTask?.cancel() }
        openingTask = nil
        openingDraft = nil
        openingID = nil
    }

    private func closeDocument() {
        cancelDocumentOpen()
        openedDraftDigest = nil
        preview = nil
        share.close()
    }
}

enum MessageVideoThumbnailDecoder {
    static let playedPosterPixelSize = 768
    static let playedPreviewDidChange = Notification.Name("MessageVideoPlayedPreviewDidChange")

    /// Decode a transcript poster from the playback file the viewer already opened.
    @MainActor static func cachePlayedPreview(for item: MessageMediaAttachment, url: URL, scale: CGFloat) async {
        let key = MessageVideoThumbnailPresentation.cacheKey(for: item)
        let epoch = MessageMediaCache.currentProducerEpoch()
        let revision = AttachmentPresentationState.shared.revision
        let size = playedPosterPixelSize
        let needsPoster = item.thumbnail == nil && cachedThumbnail(for: key, maxPixelSize: size) == nil
        let needsDuration = item.durationSeconds == nil && duration(for: key) == nil
        guard needsPoster || needsDuration else { return }
        let poster = needsPoster ? await thumbnail(url: url, maxPixelSize: size, scale: scale) : nil
        let time = needsDuration ? try? await AVURLAsset(url: url).load(.duration) : nil
        guard !Task.isCancelled, epoch == MessageMediaCache.currentProducerEpoch(),
              revision == AttachmentPresentationState.shared.revision else { return }
        if let poster { store(poster, for: key, maxPixelSize: size) }
        if let time { store(duration: time.seconds, for: key) }
        NotificationCenter.default.post(name: playedPreviewDidChange, object: key)
    }

    private static let durations: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    static func duration(for key: String) -> Double? { durations.object(forKey: key as NSString)?.doubleValue }

    static func store(duration: Double, for key: String) {
        guard duration.isFinite, duration > 0 else { return }
        durations.setObject(NSNumber(value: duration), forKey: key as NSString)
    }

    static func clear() {
        cache.removeAllObjects()
        durations.removeAllObjects()
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = MediaThumbnailCacheBudget.videoPosters
        MediaThumbnailCacheBudget.emptyOnBackground(cache)
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
    static func clear() { cache.removeAllObjects() }
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
        cache.totalCostLimit = MediaThumbnailCacheBudget.images
        MediaThumbnailCacheBudget.emptyOnBackground(cache)
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
        // Only rows on screen decode, so this is work the user is waiting on;
        // utility priority left it queued behind scrolling on a busy device.
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
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

struct MessageMediaGallery: Identifiable {
    let id = UUID()
    let items: [MessageMediaAttachment]
    let initialItemID: String
    let initialMediaData: Data?
    let messageIdByItemID: [String: String]
    struct OutgoingSlot: Equatable {
        let rowID: String
        let index: UInt32
    }

    struct Replacement: Equatable {
        let selectedID: String
        let id: String?
        let reference: MediaAttachmentReferenceFfi?
        let target: AttachmentLocalTargetFfi?
        let hint: AttachmentSourceHint?

        init(selectedID: String, candidate: MessageMediaAttachment?) {
            self.selectedID = selectedID
            id = candidate?.id
            reference = candidate?.reference
            target = candidate?.localTarget
            hint = candidate?.sourceHint
        }
    }

    enum Confirmation {
        case superseded
        case unavailable
        case confirmed(MessageMediaAttachment)
    }

    func finishVerification(_ request: Replacement, pending: PendingSelection, verified: Bool) -> Confirmation {
        let candidate = confirmedItem(for: pending)
        guard request == Replacement(selectedID: pending.id, candidate: candidate) else { return .superseded }
        guard verified, let candidate else { return .unavailable }
        return .confirmed(candidate)
    }

    struct PendingSelection {
        let id: String
        let slot: OutgoingSlot
        let data: Data
    }

    struct Caption: Equatable {
        let sender: String
        let date: Date
        var outgoingSlot: OutgoingSlot? = nil
    }
    let transcriptCaptions: [String: Caption]?

    init?(transcriptItems: [MessageMediaAttachment], openingID: String, initialData: Data?,
          messages: [String: String], captions: [String: Caption], allowsEmptyWindow: Bool = false) {
        guard allowsEmptyWindow || !transcriptItems.isEmpty else { return nil }
        items = transcriptItems
        initialItemID = openingID
        initialMediaData = captions[openingID] == nil ? nil : initialData
        messageIdByItemID = messages
        transcriptCaptions = captions
    }

    init?(
        items: [MessageMediaAttachment],
        initialItem: MessageMediaAttachment,
        initialMediaData: Data? = nil,
        messageIdByItemID: [String: String] = [:]
    ) {
        guard initialItem.isImage || initialItem.isVideo else { return nil }
        let visualItems = items.filter { $0.isImage || $0.isVideo }
        if visualItems.contains(where: { $0.id == initialItem.id }) {
            self.items = visualItems
        } else {
            self.items = [initialItem] + visualItems
        }
        self.initialItemID = initialItem.id
        self.initialMediaData = initialMediaData
        self.messageIdByItemID = messageIdByItemID
        self.transcriptCaptions = nil
    }

    func mayExport(_ item: MessageMediaAttachment, verify: ((MessageMediaAttachment) async throws -> Bool)?) async throws -> Bool {
        guard transcriptCaptions != nil else { return true }
        guard let verify else { throw CancellationError() }
        return try await verify(item)
    }

    /// A handoff can finish after its message was hidden. Validate the selected source
    /// after the lease arrives and release it before returning a failure.
    func shareFile(for item: MessageMediaAttachment, using loader: ConversationMediaLoader,
                   control: MediaFileTransferControlFfi,
                   verify: ((MessageMediaAttachment) async throws -> Bool)?) async throws -> AttachmentShareFile {
        func checkAccess() async throws {
            guard !control.isCancelled(), try await mayExport(item, verify: verify),
                  !control.isCancelled() else { throw AttachmentReadError.unavailable }
        }
        try await checkAccess()
        let file = try await loader.shareFile(for: item, control: control)
        do {
            try await checkAccess()
            return file
        } catch {
            file.finish()
            throw error
        }
    }

    func pendingSelection(for id: String) -> PendingSelection? {
        guard let slot = transcriptCaptions?[id]?.outgoingSlot,
              let item = items.first(where: { $0.id == id }), item.reference == nil,
              let data = item.localData else { return nil }
        return PendingSelection(id: id, slot: slot, data: data)
    }

    func confirmedItem(for pending: PendingSelection) -> MessageMediaAttachment? {
        items.first { $0.reference != nil && transcriptCaptions?[$0.id]?.outgoingSlot == pending.slot }
    }

    func confirmedSelection(for pending: PendingSelection) async -> MessageMediaAttachment? {
        guard let item = confirmedItem(for: pending), let reference = item.reference,
              await MediaPlaintextHash.matches(pending.data, expectedSha256: reference.plaintextSha256) else { return nil }
        return item
    }

    func canRestore(_ opening: MessageMediaAttachment) -> Bool {
        guard let bookmark = TranscriptMediaBookmark(opening),
              items.contains(where: { $0.id == opening.id && TranscriptMediaBookmark($0) == bookmark }) else { return false }
        return opening.isVideo || initialMediaData != nil
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
    enum Payload {
        case data(Data)
        case fileURL(URL)
    }

    let id: String
    let item: MessageMediaAttachment
    let payload: Payload
    let contentType: UTType
    var pendingSelection: MessageMediaGallery.PendingSelection? = nil

    var inlineData: Data? {
        if case .data(let data) = payload { return data }
        return nil
    }
}

struct DecryptedMediaExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    enum Source {
        case data(Data)
        case fileURL(URL)
    }

    let source: Source

    init(data: Data) {
        source = .data(data)
    }

    init(fileURL: URL) {
        source = .fileURL(fileURL)
    }

    init(configuration: ReadConfiguration) throws {
        source = .data(configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.fileWrapper(for: source)
    }

    nonisolated static func fileWrapper(for source: Source) throws -> FileWrapper {
        switch source {
        case .data(let data):
            return FileWrapper(regularFileWithContents: data)
        case .fileURL(let url):
            return try FileWrapper(url: url, options: [])
        }
    }
}

enum MessageMediaFullscreenPresentation {
    /// Leave detail for zooming, with a hard ceiling on peer-controlled bitmap allocation.
    static func fullscreenMaxPixelSize(forLongestScreenEdge longestEdge: CGFloat) -> Int {
        guard longestEdge.isFinite, longestEdge >= 1 else { return 1 }
        return Int(min(4096, longestEdge * 2).rounded(.up))
    }

    /// Decodes attacker-controlled image bytes off the MainActor, bounded to the
    /// fullscreen pixel budget. Mirrors the thumbnail/grid hardening
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
    static func videoDemand(onSelection: AttachmentDemand, waitForPlay: Bool, playRequest: Int,
                            handledRequest: Int, afterFailure: Bool) -> AttachmentDemand? {
        if playRequest != handledRequest { return .userTap(afterFailure: afterFailure) }
        return waitForPlay && playRequest == 0 ? nil : onSelection
    }

    @MainActor static func prepareVideo(_ player: AVPlayer, demand: AttachmentDemand, resumeConfirmed: Bool = false) {
        if demand.isUserInitiated || resumeConfirmed { player.play() } else { player.pause() }
    }

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
}

/// An outgoing slot can confirm while its local video is loading, playing, or paused in the native controls.
@MainActor final class PendingVideoPlayback {
    private weak var player: AVPlayer?
    private var requested: Bool?

    var wantsPlayback: Bool? {
        player.map { $0.rate != 0 || $0.timeControlStatus == .waitingToPlayAtSpecifiedRate } ?? requested
    }

    func request(_ demand: AttachmentDemand) { requested = demand.isUserInitiated }
    func observe(_ player: AVPlayer) { self.player = player }
    func detach(_ player: AVPlayer) {
        guard self.player === player else { return }
        requested = wantsPlayback
        self.player = nil
    }
}

nonisolated struct TranscriptMediaSelection {
    let openingID: String
    private(set) var selectedID: String
    private(set) var resumingVideoID: String?
    private var hasPaged = false

    init(openingID: String) {
        self.openingID = openingID
        selectedID = openingID
    }

    mutating func select(_ id: String) {
        guard selectedID != id else { return }
        hasPaged = true
        selectedID = id
        resumingVideoID = nil
    }

    mutating func confirm(_ id: String, resumeVideo: Bool) {
        select(id)
        resumingVideoID = resumeVideo ? id : nil
    }

    func demand(for id: String, allowsOpeningDemand: Bool) -> AttachmentDemand {
        !hasPaged && id == openingID && allowsOpeningDemand ? .explicit : .automatic
    }
}

struct MessageMediaFullscreenGalleryView: View {
    @Environment(\.transcriptHistoryControls) private var transcriptHistory
    @Environment(AppState.self) private var appState
    let gallery: MessageMediaGallery
    let onLoadMedia: ConversationMediaLoader
    var forwardingContext: MediaForwardingContext?
    var onGoToMessage: ((String) -> Void)?
    let onDismiss: () -> Void

    private let restored: Bool
    private let didDisplay: ((MessageMediaAttachment?) -> Void)?
    private let currentTranscriptGallery: (() -> MessageMediaGallery?)?
    @State private var pendingSelection: MessageMediaGallery.PendingSelection?
    @State private var pendingVideo = PendingVideoPlayback()
    @State private var selection: TranscriptMediaSelection
    private var selectedItemID: String { selection.selectedID }
    @State private var zoomedItemID: String?
    @State private var dismissDragOffset: CGFloat = 0
    @State private var preparedMedia: FullscreenMediaPrepared?
    @State private var mediaShare: AttachmentShareFile?
    @State private var handoffControl: MediaFileTransferControlFfi?
    @State private var exportDocument: DecryptedMediaExportDocument?
    @State private var exportShareFile: AttachmentShareFile?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "Media"
    @State private var exportHandoffControl: MediaFileTransferControlFfi?
    @State private var saveProductTicket: ProductAnalyticsRecorder.Ticket?
    @State private var isExporting = false
    @State private var actionError: String?
    @State private var forwardMedia: FullscreenMediaPrepared?
    @State private var chrome = MediaViewerChrome()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        gallery: MessageMediaGallery,
        openingSelection: MessageMediaGallery.PendingSelection? = nil,
        restored: Bool = false,
        didDisplay: ((MessageMediaAttachment?) -> Void)? = nil,
        currentTranscriptGallery: (() -> MessageMediaGallery?)? = nil,
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
        _selection = State(initialValue: TranscriptMediaSelection(openingID: gallery.initialItemID))
        _pendingSelection = State(initialValue: gallery.pendingSelection(for: gallery.initialItemID) ?? openingSelection)
        self.currentTranscriptGallery = currentTranscriptGallery
        self.didDisplay = didDisplay
        self.restored = restored
    }

    var body: some View {
        let replacementRequest = missingSelectionReplacement
        Group {
            if gallery.transcriptCaptions != nil {
                TranscriptMediaSheet(gallery: gallery, selection: Binding(get: { selectedItemID }, set: select),
                    isZoomed: zoomedItemID != nil, showsChrome: chrome.isVisible, controls: controlState,
                    onClose: onDismiss, onSave: saveSelectedMedia, onShare: shareSelectedMedia,
                    onForward: { forwardMedia = currentPreparedMedia }, onGoToMessage: goToSelectedMessage,
                    page: page)
            } else {
                fullscreenContent
            }
        }
        .task(id: replacementRequest) {
            guard let request = replacementRequest, currentGalleryMissing(request.selectedID) != nil else { return }
            guard let pendingSelection, pendingSelection.id == request.selectedID else {
                onDismiss()
                return
            }
            let verified = await gallery.confirmedSelection(for: pendingSelection)
            guard let latest = currentGalleryMissing(request.selectedID) else { return }
            let replacement: MessageMediaAttachment
            switch latest.finishVerification(request, pending: pendingSelection, verified: verified != nil) {
            case .superseded: return
            case .unavailable: onDismiss(); return
            case .confirmed(let item): replacement = item
            }
            preparedMedia = FullscreenMediaPrepared(id: replacement.id, item: replacement, payload: .data(pendingSelection.data),
                contentType: UTType(mimeType: replacement.mediaType) ?? .data)
            let wasPlaying = pendingVideo.wantsPlayback ?? selection.demand(for: pendingSelection.id,
                allowsOpeningDemand: !restored && transcriptHistory?.allowsOpeningDemand != false).isUserInitiated
            selection.confirm(replacement.id, resumeVideo: replacement.isVideo && wasPlaying)
            self.pendingSelection = nil
            pendingVideo = PendingVideoPlayback()
        }
        .onChange(of: selectedItem?.preparedSource, initial: true) { _, _ in didDisplay?(selectedItem) }
        .onChange(of: selectedItemID) { _, selection in
            if gallery.transcriptCaptions != nil { chrome = MediaViewerChrome() }
            if preparedMedia?.id != selection { preparedMedia = nil }
            handoffControl?.cancel()
            exportHandoffControl?.cancel()
            zoomedItemID = nil
            dismissDragOffset = 0
        }
        .sheet(item: $mediaShare) { share in
            ActivityShareSheet(items: [share.url], onComplete: share.finish)
                .onDisappear(perform: share.finish)
        }
        .onDisappear {
            handoffControl?.cancel()
            exportHandoffControl?.cancel()
            exportShareFile?.finish()
            exportShareFile = nil
        }
        .sheet(item: $forwardMedia) { prepared in
            if let forwardingContext {
                let verify: (MessageMediaAttachment) async throws -> Bool = { item in
                    if let transcriptHistory { return try await transcriptHistory.verifyForward(item, prepared.pendingSelection) }
                    return try await gallery.mayExport(item, verify: nil)
                }
                switch prepared.payload {
                case .data(let data):
                    ForwardMessageSheet(
                        media: prepared.item,
                        data: data,
                        verifySource: verify,
                        viewModel: forwardingContext.viewModel,
                        destinationProvider: forwardingContext.destinationProvider
                    )
                    .appAppearance()
                case .fileURL(let url):
                    ForwardMessageSheet(
                        media: prepared.item,
                        fileURL: url,
                        fallbackData: { try await onLoadMedia.data(for: prepared.item, demand: .explicit) },
                        verifySource: verify,
                        viewModel: forwardingContext.viewModel,
                        destinationProvider: forwardingContext.destinationProvider
                    )
                    .appAppearance()
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            let outcome: ProductOutcome
            switch result {
            case .success: outcome = .success
            case .failure(let error): outcome = (error as NSError).code == NSUserCancelledError ? .cancelled : .failure
            }
            appState.productAnalytics.record(.attachment(.save, outcome), ticket: saveProductTicket)
            saveProductTicket = nil
            exportShareFile?.finish()
            exportShareFile = nil
            exportDocument = nil
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

    private func select(_ id: String) {
        if selectedItemID != id { pendingVideo = PendingVideoPlayback() }
        selection.select(id)
        pendingSelection = gallery.pendingSelection(for: id)
    }

    private func currentGalleryMissing(_ id: String) -> MessageMediaGallery? {
        guard !Task.isCancelled, selectedItemID == id, let visible = currentTranscriptGallery?(),
              visible.transcriptCaptions?[id] == nil else { return nil }
        return visible
    }

    private var missingSelectionReplacement: MessageMediaGallery.Replacement? {
        guard gallery.transcriptCaptions != nil, gallery.transcriptCaptions?[selectedItemID] == nil else { return nil }
        return .init(selectedID: selectedItemID, candidate: pendingSelection.flatMap { gallery.confirmedItem(for: $0) })
    }

    private func page(_ item: MessageMediaAttachment) -> some View {
        let source = gallery.transcriptCaptions == nil ? item : item.forTranscriptPage
        return MessageMediaFullscreenPage(
            item: source,
            isSelected: item.id == selectedItemID,
            initialImageData: preparedMedia.flatMap { item.canUseBytesPrepared(for: $0.item) ? $0.inlineData : nil } ?? gallery.initialData(for: source),
            selectionDemand: gallery.transcriptCaptions == nil ? .explicit
                : selection.demand(for: item.id, allowsOpeningDemand: !restored && transcriptHistory?.allowsOpeningDemand != false),
            waitsForRestoredPlay: restored && item.id == selection.openingID,
            resumeConfirmedVideo: selection.resumingVideoID == item.id,
            pendingVideo: pendingSelection?.id == item.id ? pendingVideo : nil,
            onLoadMedia: onLoadMedia,
            onPrepared: { payload in
                guard selectedItemID == item.id, selectedItem != nil else { return }
                preparedMedia = FullscreenMediaPrepared(id: item.id, item: item, payload: payload,
                    contentType: UTType(mimeType: item.mediaType) ?? .data, pendingSelection: gallery.pendingSelection(for: item.id))
            },
            onToggleChrome: toggleChrome,
            onSourceReplaced: {
                if preparedMedia?.id == item.id { preparedMedia = nil }
                if selectedItemID == item.id, gallery.transcriptCaptions != nil { chrome = MediaViewerChrome() }
            },
            onZoomChanged: { zoomed in
                if zoomed, item.id == selectedItemID { zoomedItemID = item.id }
                else if zoomedItemID == item.id { zoomedItemID = nil }
            }
        )
    }

    private var fullscreenContent: some View {
        ZStack {
            WNMediaSurface().ignoresSafeArea()

            TabView(selection: Binding(get: { selectedItemID }, set: select)) {
                ForEach(gallery.items) { item in
                    page(item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(
                .page(indexDisplayMode: .never)
            )
            .ignoresSafeArea()

            if chrome.isVisible {
                MessageMediaFullscreenGalleryChrome(
                    pageCountLabel: gallery.items.count > 1 ? pageCountLabel : nil,
                    controlState: controlState,
                    onClose: onDismiss,
                    onSave: saveSelectedMedia,
                    onShare: shareSelectedMedia,
                    onForward: { forwardMedia = currentPreparedMedia },
                    onGoToMessage: goToSelectedMessage
                )
                .transition(.opacity)
            }
        }
        .offset(y: dismissDragOffset)
        .opacity(1 - min(dismissDragOffset / 420, 0.35))
        .simultaneousGesture(swipeDownToDismissGesture, including: zoomedItemID == nil ? .all : .subviews)
    }

    private var selectedItem: MessageMediaAttachment? {
        gallery.items.first { $0.id == selectedItemID }
    }

    private var currentPreparedMedia: FullscreenMediaPrepared? {
        guard let selectedItem, let preparedMedia, selectedItem.canUseBytesPrepared(for: preparedMedia.item) else { return nil }
        return FullscreenMediaPrepared(id: selectedItem.id, item: selectedItem, payload: preparedMedia.payload,
            contentType: preparedMedia.contentType, pendingSelection: preparedMedia.pendingSelection)
    }


    private var controlState: MediaViewerControlState {
        return MediaViewerControlState(
            hasPreparedMedia: currentPreparedMedia != nil,
            hasForwardingContext: forwardingContext != nil,
            hasSourceMessage: sourceMessageIdHex != nil
        )
    }

    private var sourceMessageIdHex: String? {
        guard onGoToMessage != nil else { return nil }
        return MediaViewerMessageNavigation.sourceMessageIdHex(
            forItemID: selectedItemID,
            messageIdByItemID: gallery.messageIdByItemID
        )
    }

    /// The viewer closes itself first: the destination may reset the
    /// navigation path out from under the presenting screen.
    private func goToSelectedMessage() {
        guard let sourceMessageIdHex, let onGoToMessage else { return }
        onDismiss()
        onGoToMessage(sourceMessageIdHex)
    }

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            chrome.toggle()
        }
    }

    private func saveSelectedMedia() {
        guard let preparedMedia = currentPreparedMedia, exportHandoffControl == nil, !isExporting else { return }
        switch preparedMedia.payload {
        case .data(let data) where UInt64(data.count) <= RetainedAttachmentReader.mappedReadThresholdBytes:
            saveProductTicket = appState.productAnalytics.ticket()
            exportContentType = preparedMedia.contentType
            exportFilename = preparedMedia.item.fileName
            exportDocument = DecryptedMediaExportDocument(data: data)
            isExporting = true
        case .fileURL(let url) where AttachmentHandoffSource(preparedMedia.item) == .none && gallery.transcriptCaptions == nil:
            saveProductTicket = appState.productAnalytics.ticket()
            exportContentType = preparedMedia.contentType
            exportFilename = preparedMedia.item.fileName
            exportDocument = DecryptedMediaExportDocument(fileURL: url)
            isExporting = true
        case .data, .fileURL:
            let item = preparedMedia.item
            let contentType = preparedMedia.contentType
            let control = MediaFileTransferControlFfi()
            exportHandoffControl = control
            Task {
                defer { if exportHandoffControl === control { exportHandoffControl = nil } }
                do {
                    let file = try await gallery.shareFile(
                        for: item,
                        using: onLoadMedia,
                        control: control,
                        verify: transcriptHistory?.verify
                    )
                    guard !control.isCancelled(), selectedItemID == item.id, selectedItem != nil else {
                        file.finish()
                        return
                    }
                    saveProductTicket = appState.productAnalytics.ticket()
                    exportShareFile?.finish()
                    exportShareFile = file
                    exportContentType = contentType
                    exportFilename = item.fileName
                    exportDocument = DecryptedMediaExportDocument(fileURL: file.url)
                    isExporting = true
                } catch AttachmentHandoffFailure.storageFull {
                    return
                } catch {
                    if !control.isCancelled(), selectedItemID == item.id {
                        actionError = L10n.string("Couldn't save media.")
                    }
                }
            }
        }
    }

    private func shareSelectedMedia() {
        guard let item = currentPreparedMedia?.item, handoffControl == nil else { return }
        let control = MediaFileTransferControlFfi()
        handoffControl = control
        Task {
            defer { if handoffControl === control { handoffControl = nil } }
            do {
                let file = try await gallery.shareFile(for: item, using: onLoadMedia, control: control,
                    verify: transcriptHistory?.verify)
                guard !control.isCancelled(), selectedItemID == item.id, selectedItem != nil else {
                    file.finish()
                    return
                }
                mediaShare = file
            } catch AttachmentHandoffFailure.storageFull {
                // The downloader already explains how to free space for the handoff.
                return
            } catch {
                if !control.isCancelled(), selectedItemID == item.id {
                    actionError = L10n.string("Couldn't prepare media.")
                }
            }
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
            selectedIndex: gallery.items.firstIndex(where: { $0.id == selectedItemID }),
            totalCount: gallery.items.count
        )
    }
}

private struct MessageMediaFullscreenPage: View {
    let item: MessageMediaAttachment
    let isSelected: Bool
    let initialImageData: Data?
    let selectionDemand: AttachmentDemand
    let waitsForRestoredPlay: Bool
    let resumeConfirmedVideo: Bool
    let pendingVideo: PendingVideoPlayback?
    let onLoadMedia: ConversationMediaLoader
    let onPrepared: (FullscreenMediaPrepared.Payload) -> Void
    let onToggleChrome: () -> Void
    let onSourceReplaced: () -> Void
    let onZoomChanged: (Bool) -> Void
    @State private var sourceGeneration = 0

    var body: some View {
        content
            .id(sourceGeneration)
            .onChange(of: item.preparedSource) { previous, current in
                if !current.canContinue(previous) {
                    onSourceReplaced()
                    sourceGeneration &+= 1
                    onZoomChanged(false)
                }
            }
    }

    @ViewBuilder private var content: some View {
        let demand = sourceGeneration == 0 ? selectionDemand : .automatic
        if item.isVideo {
            MessageMediaFullscreenVideoPage(
                item: item,
                isSelected: isSelected,
                initialMediaData: sourceGeneration == 0 ? initialImageData : nil,
                selectionDemand: demand,
                waitsForRestoredPlay: waitsForRestoredPlay,
                resumeConfirmedVideo: sourceGeneration == 0 && resumeConfirmedVideo,
                pendingVideo: pendingVideo,
                onLoadMedia: onLoadMedia,
                onPreparedFile: { onPrepared(.fileURL($0)) },
                onToggleChrome: onToggleChrome
            )
        } else {
            MessageMediaFullscreenImagePage(
                item: item,
                isSelected: isSelected,
                initialImageData: sourceGeneration == 0 ? initialImageData : nil,
                selectionDemand: demand,
                onLoadMedia: onLoadMedia,
                onData: { onPrepared(.data($0)) },
                onToggleChrome: onToggleChrome,
                onZoomChanged: onZoomChanged
            )
        }
    }
}

private struct MessageMediaFullscreenVideoPage: View {
    @Environment(AppState.self) private var appState
    let item: MessageMediaAttachment
    let isSelected: Bool
    let initialMediaData: Data?
    let selectionDemand: AttachmentDemand
    let waitsForRestoredPlay: Bool
    let resumeConfirmedVideo: Bool
    let pendingVideo: PendingVideoPlayback?
    let onLoadMedia: ConversationMediaLoader
    let onPreparedFile: (URL) -> Void
    let onToggleChrome: () -> Void
    @Environment(\.isTranscriptMediaSheet) private var isTranscriptMediaSheet
    @Environment(\.displayScale) private var displayScale

    @State private var videoAspectRatio: CGFloat?
    @State private var playRequest = 0
    @State private var handledPlayRequest = 0
    @State private var player: AVPlayer?
    @State private var playbackFile: AttachmentShareFile?
    @State private var playbackHandoffControl: MediaFileTransferControlFfi?
    @State private var audioSession = ObservableVideoPlaybackAudioSession()
    @State private var isLoading = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            if isTranscriptMediaSheet {
                WNMediaSurface()
                    .contentShape(.rect)
                    .onTapGesture(perform: onToggleChrome)
            } else {
                WNMediaSurface().ignoresSafeArea()
            }

            if let player {
                if isTranscriptMediaSheet, let currentItem = player.currentItem {
                    VideoPlayer(player: player)
                        .simultaneousGesture(TapGesture().onEnded(onToggleChrome))
                        .aspectRatio(videoAspectRatio ?? ComposerMediaDraftLayout.aspectRatio(dim: item.dim) ?? 1,
                                     contentMode: .fit)
                        .clipped()
                        .onReceive(currentItem.publisher(for: \.presentationSize).receive(on: DispatchQueue.main)) { size in
                            guard size.width > 0, size.height > 0 else { return }
                            let ratio = size.width / size.height
                            if ratio.isFinite { videoAspectRatio = ratio }
                        }
                } else {
                    VideoPlayer(player: player).ignoresSafeArea()
                }
            } else if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.5), in: Circle())
                    .allowsHitTesting(false)
            } else if didFail {
                WNMediaRetryButton {
                    playRequest += 1
                }
            } else if player == nil {
                Button {
                    playRequest += 1
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
        .task(id: isSelected ? playRequest : nil) {
            guard isSelected else {
                releasePlayback()
                return
            }
            guard let demand = MessageMediaFullscreenGalleryPresentation.videoDemand(onSelection: selectionDemand,
                waitForPlay: waitsForRestoredPlay, playRequest: playRequest, handledRequest: handledPlayRequest,
                afterFailure: didFail) else { return }
            handledPlayRequest = playRequest
            await loadVideo(demand: demand)
        }
        .onDisappear { releasePlayback() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            if let ended = notification.object as? AVPlayerItem, ended === player?.currentItem {
                player?.seek(to: .zero)
            }
        }
        .accessibilityLabel(L10n.string("Video attachment"))
    }

    private func loadVideo(demand: AttachmentDemand) async {
        guard isSelected else { return }
        pendingVideo?.request(demand)
        if demand == .retry {
            releasePlayback()
        } else if let player {
            MessageMediaFullscreenGalleryPresentation.prepareVideo(player, demand: demand, resumeConfirmed: resumeConfirmedVideo)
            audioSession.attach(to: player)
            return
        }

        let productTicket = appState.productAnalytics.ticket()
        var productOutcome: ProductOutcome = .cancelled
        defer { appState.productAnalytics.record(.attachment(.open, productOutcome), ticket: productTicket) }
        let control = MediaFileTransferControlFfi()
        playbackHandoffControl?.cancel()
        playbackHandoffControl = control
        defer { if playbackHandoffControl === control { playbackHandoffControl = nil } }
        // An automatic read may be waiting on backoff. Play can take over through the same task ID.
        isLoading = demand.isUserInitiated
        didFail = false
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let opened = try await onLoadMedia.playbackFile(
                for: item,
                demand: demand,
                initialData: initialMediaData,
                control: control
            )
            guard !Task.isCancelled, !control.isCancelled(), isSelected else {
                opened.finish()
                return
            }
            onPreparedFile(opened.url)
            let next = AVPlayer(url: opened.url)
            productOutcome = .success
            playbackFile?.finish()
            playbackFile = opened
            player = next
            MessageMediaFullscreenGalleryPresentation.prepareVideo(next, demand: demand, resumeConfirmed: resumeConfirmedVideo)
            pendingVideo?.observe(next)
            audioSession.attach(to: next)
            if isTranscriptMediaSheet {
                isLoading = false
                await MessageVideoThumbnailDecoder.cachePlayedPreview(for: item, url: opened.url, scale: displayScale)
            }
        } catch AttachmentHandoffFailure.storageFull {
            guard !Task.isCancelled, !control.isCancelled(), isSelected else { return }
            productOutcome = .failure
        } catch {
            guard !Task.isCancelled, !control.isCancelled(), !(error is CancellationError), isSelected else { return }
            productOutcome = .failure
            didFail = demand.failureOffersRetry
        }
    }

    private func releasePlayback() {
        isLoading = false
        playbackHandoffControl?.cancel()
        playbackHandoffControl = nil
        if let player { pendingVideo?.detach(player) }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        audioSession.stop()
        player = nil
        playbackFile?.finish()
        playbackFile = nil
    }
}

private struct MessageMediaFullscreenImagePage: View {
    @Environment(AppState.self) private var appState
    let item: MessageMediaAttachment
    let isSelected: Bool
    let initialImageData: Data?
    let selectionDemand: AttachmentDemand
    let onLoadMedia: ConversationMediaLoader
    let onData: (Data) -> Void
    let onZoomChanged: (Bool) -> Void

    @State private var loadRequest = 0
    @State private var handledLoadRequest = 0
    @State private var waitingForTap = false
    @State private var couldNotDecode = false
    @State private var imageData: Data?
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    @Environment(\.displayScale) private var displayScale

    let onToggleChrome: () -> Void

    init(
        item: MessageMediaAttachment,
        isSelected: Bool,
        initialImageData: Data?,
        selectionDemand: AttachmentDemand,
        onLoadMedia: ConversationMediaLoader,
        onData: @escaping (Data) -> Void,
        onToggleChrome: @escaping () -> Void,
        onZoomChanged: @escaping (Bool) -> Void
    ) {
        self.item = item
        self.isSelected = isSelected
        self.selectionDemand = selectionDemand
        self.onLoadMedia = onLoadMedia
        self.onData = onData
        self.onToggleChrome = onToggleChrome
        self.onZoomChanged = onZoomChanged
        self.initialImageData = initialImageData
    }

    private func fullscreenMaxPixelSize(viewSize: CGSize, scale: CGFloat) -> Int {
        let longestPoint = max(viewSize.width, viewSize.height)
        let longestEdge = max(1, longestPoint * scale)
        return MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: longestEdge)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                WNMediaSurface().ignoresSafeArea()

                if let image {
                    AttachmentGIFPlayback(contentID: item.id, data: item.isGIF ? imageData : nil,
                        activity: isSelected ? .active : .inactive) { playback in
                        ZoomableMediaImage(image: image, isSelected: isSelected,
                            onTap: onToggleChrome, onZoomChanged: onZoomChanged,
                            gifData: playback?.data, playbackID: playback?.id, onGIFCompletion: playback?.finish)
                    }
                } else if isLoading, waitingForTap {
                    Button { loadRequest += 1 } label: { ProgressView().padding(8) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(L10n.string("Tap to download"))
                } else if isLoading {
                    ProgressView()
                } else if couldNotDecode {
                    Label("Attachment couldn’t be read", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if didFail {
                    WNMediaRetryButton { loadRequest += 1 }
                } else if waitingForTap {
                    Button { loadRequest += 1 } label: {
                        Label("Tap to download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: isSelected ? loadRequest : nil) {
                guard isSelected else {
                    isLoading = false
                    return
                }
                let demand = loadRequest != handledLoadRequest ? .userTap(afterFailure: didFail) : selectionDemand
                handledLoadRequest = loadRequest
                await loadImageIfNeeded(viewSize: proxy.size, scale: displayScale, demand: demand)
            }
        }
    }

    private func loadImageIfNeeded(viewSize: CGSize, scale: CGFloat, demand: AttachmentDemand) async {
        guard isSelected else { return }
        let force = demand == .retry
        waitingForTap = false
        couldNotDecode = false
        if !force, imageData == nil { imageData = initialImageData }
        if !force, let imageData { onData(imageData) }
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
            } else if !Task.isCancelled {
                productOutcome = .failure
                couldNotDecode = true
            }
            return
        }

        isLoading = true
        waitingForTap = !demand.isUserInitiated
        didFail = false
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            guard let data = try await onLoadMedia.selectedPageData(for: item, isSelected: isSelected,
                demand: demand) else { return }
            guard !Task.isCancelled else { return }
            onData(data)
            guard let decoded = await MessageMediaFullscreenPresentation.decodedImage(
                from: data,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) else {
                guard !Task.isCancelled else { return }
                imageData = nil
                image = nil
                productOutcome = .failure
                couldNotDecode = true
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
            didFail = demand.failureOffersRetry
            waitingForTap = !didFail
        }
    }
}
