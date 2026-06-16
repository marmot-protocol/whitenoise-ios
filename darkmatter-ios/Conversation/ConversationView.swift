import SwiftUI
import UIKit
import MarmotKit

enum TimelineBottom {
    static let pinnedThreshold: CGFloat = 44
    static let overscrollRepairThreshold: CGFloat = 8

    static func isPinned(bottomY: CGFloat, viewportBottomY: CGFloat) -> Bool {
        bottomY <= viewportBottomY + pinnedThreshold
    }

    static func distanceToBottom(
        contentHeight: CGFloat,
        visibleBottomY: CGFloat,
        bottomContentInset: CGFloat = 0
    ) -> CGFloat {
        max(0, contentHeight + bottomContentInset - visibleBottomY)
    }

    static func shouldShowScrollToBottomButton(distanceToBottom: CGFloat) -> Bool {
        distanceToBottom > pinnedThreshold
    }

    static func shouldFollowViewportChange(wasPinned: Bool) -> Bool {
        wasPinned
    }

    static func pinnedStateAfterScrollButtonTap(currentIsPinned: Bool) -> Bool {
        true
    }

    static func shouldPreservePinAfterContentGrowth(
        previous: TimelineBottomViewport,
        current: TimelineBottomViewport
    ) -> Bool {
        previous.isPinned && current.contentHeight > previous.contentHeight
    }

    static func overscrollPastBottom(
        contentHeight: CGFloat,
        visibleBottomY: CGFloat,
        bottomContentInset: CGFloat = 0
    ) -> CGFloat {
        max(0, visibleBottomY - (contentHeight + bottomContentInset))
    }

    static func shouldRepairBottomOverscroll(_ viewport: TimelineBottomViewport) -> Bool {
        viewport.overscrollPastBottom > overscrollRepairThreshold
    }
}

struct TimelineBottomViewport: Equatable {
    let contentHeight: CGFloat
    let visibleBottomY: CGFloat
    let bottomContentInset: CGFloat

    var distanceToBottom: CGFloat {
        TimelineBottom.distanceToBottom(
            contentHeight: contentHeight,
            visibleBottomY: visibleBottomY,
            bottomContentInset: bottomContentInset
        )
    }

    var overscrollPastBottom: CGFloat {
        TimelineBottom.overscrollPastBottom(
            contentHeight: contentHeight,
            visibleBottomY: visibleBottomY,
            bottomContentInset: bottomContentInset
        )
    }

    var shouldShowScrollToBottomButton: Bool {
        TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: distanceToBottom)
    }

    var isPinned: Bool {
        !shouldShowScrollToBottomButton
    }
}

enum TimelineBottomScrollReason: Equatable {
    case contentGrowth
    case timelineChange
    case viewportChange
    case buttonTap

    var isUserInitiated: Bool {
        self == .buttonTap
    }
}

struct TimelineBottomScrollRequest: Equatable {
    let animated: Bool
    let reason: TimelineBottomScrollReason
    let targetID: String?

    func coalesced(with next: TimelineBottomScrollRequest) -> TimelineBottomScrollRequest {
        if next.reason.isUserInitiated {
            return next
        }
        if reason.isUserInitiated {
            return self
        }
        return TimelineBottomScrollRequest(
            animated: animated && next.animated,
            reason: next.reason,
            targetID: next.targetID ?? targetID
        )
    }
}

enum TimelineBottomScrollCoordinator {
    static func coalesced(
        _ current: TimelineBottomScrollRequest?,
        with next: TimelineBottomScrollRequest
    ) -> TimelineBottomScrollRequest {
        guard let current else { return next }
        return current.coalesced(with: next)
    }

    static func shouldSkipTimelineChangeScroll(
        lastAutomaticTargetID: String?,
        nextTargetID: String?
    ) -> Bool {
        guard let nextTargetID else { return false }
        return nextTargetID == lastAutomaticTargetID
    }
}

enum TimelinePaginationTrigger {
    static func shouldRequestPage(hasMore: Bool, isTriggerAlreadyVisible: Bool) -> Bool {
        hasMore && !isTriggerAlreadyVisible
    }
}

struct ConversationSendPayload {
    let viewModel: ConversationViewModel
    let text: String
    let attachments: [MediaDraftAttachment]
}

enum ConversationSendPreparation {
    static func prepare(
        draft: inout String,
        mediaDrafts: inout [MediaDraftAttachment],
        viewModel: ConversationViewModel?
    ) -> ConversationSendPayload? {
        guard let viewModel else { return nil }
        let text = draft
        let attachments = mediaDrafts
        guard !attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        draft = ""
        mediaDrafts = []
        return ConversationSendPayload(viewModel: viewModel, text: text, attachments: attachments)
    }
}

enum TimelineInitialScroll {
    static func shouldStartAtBottom(hasItems: Bool, didPerformInitialScroll: Bool) -> Bool {
        destination(
            hasItems: hasItems,
            didPerformInitialScroll: didPerformInitialScroll,
            targetMessageIdHex: nil,
            targetItemId: nil
        ) == .bottom
    }

    static func destination(
        hasItems: Bool,
        didPerformInitialScroll: Bool,
        targetMessageIdHex: String?,
        targetItemId: String?
    ) -> TimelineInitialDestination {
        guard hasItems, !didPerformInitialScroll else { return .none }
        if targetMessageIdHex?.isEmpty == false {
            guard let targetItemId, !targetItemId.isEmpty else { return .none }
            return .item(targetItemId)
        }
        return .bottom
    }

    static func shouldConcealContent(
        hasItems: Bool,
        didFinishInitialPositioning: Bool,
        targetMessageIdHex: String?,
        targetItemId: String?
    ) -> Bool {
        guard hasItems, !didFinishInitialPositioning else { return false }
        if targetMessageIdHex?.isEmpty == false {
            return targetItemId?.isEmpty == false
        }
        return true
    }
}

enum TimelineInitialDestination: Equatable {
    case none
    case bottom
    case item(String)
}

enum ReplyPreviewLayout {
    enum CloseAlignment {
        case trailing

        var swiftUI: Alignment {
            switch self {
            case .trailing: .trailing
            }
        }
    }

    static let leadingContentInset: CGFloat = 14
    static let closeTrailingInset = leadingContentInset
    static let contentTopInset: CGFloat = 5
    static let contentBottomInset = contentTopInset
    static let closeHitSize: CGFloat = 44
    static let closeIconSize: CGFloat = 20
    static let closeAlignment: CloseAlignment = .trailing
    static let outerHorizontalInset: CGFloat = 10
    static let outerTopInset: CGFloat = 2
    static let outerBottomInset: CGFloat = 2
}

nonisolated struct ConversationChromePresentation: Equatable {
    let title: String
    let subtitle: String?

    static func initial(
        chat: AppGroupRecordFfi,
        initialTitle: String?,
        initialMemberCount: Int?
    ) -> ConversationChromePresentation {
        ConversationChromePresentation(
            title: ProfileSanitizer.groupName(initialTitle)
                ?? ProfileSanitizer.groupName(chat.name)
                ?? IdentityFormatter.short(chat.groupIdHex),
            subtitle: initialMemberCount.flatMap(memberSubtitle)
        )
    }

    static func memberSubtitle(for memberCount: Int) -> String? {
        if memberCount == 0 { return L10n.string("Just you") }
        return L10n.plural("%lld members", Int64(memberCount))
    }
}

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    let chat: AppGroupRecordFfi
    let initialTitle: String?
    let initialOtherMember: String?
    let initialMemberCount: Int?
    let initialTargetMessageIdHex: String?
    let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    let onGroupChanged: ((AppGroupRecordFfi) -> Void)?

    @State private var viewModel: ConversationViewModel?
    @State private var draft: String = ""
    @State private var mediaDrafts: [MediaDraftAttachment] = []
    @StateObject private var voiceRecorder = VoiceMessageRecorder()
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var showFileImporter = false
    @State private var showDetails = false
    @State private var actionsTarget: ActionsTarget?
    @State private var emojiPickerTarget: ActionsTarget?
    /// When the long-pressed bubble sits too low for the actions popover to fit
    /// below it, flip the popover above the bubble instead.
    @State private var actionsAbove = false
    /// When a bubble is so tall that neither above nor below has room, drop the
    /// popover and show the menu as a centered overlay over the bubble instead.
    @State private var actionsCentered = false
    @State private var rowFrames = RowFrameStore()
    @State private var composerFocusRequest = 0
    @State private var isAtTimelineBottom = true
    @State private var didPerformInitialBottomScroll = false
    @State private var isInitialTimelinePositionSettled = false
    @State private var initialScrollFollowUpTask: Task<Void, Never>?
    @State private var pendingBottomScrollRequest: TimelineBottomScrollRequest?
    @State private var pendingBottomScrollTask: Task<Void, Never>?
    @State private var isOlderTimelineTriggerVisible = false
    @State private var isNewerTimelineTriggerVisible = false
    @State private var lastAutomaticBottomScrollTargetID: String?
    @State private var pendingKeyboardDismissTask: Task<Void, Never>?
    @State private var visibleChatRoute: VisibleChatRoute?
    /// Global Y bounds of the visible timeline (between nav bar and composer).
    /// The bottom shrinks when the keyboard rises, so placement accounts for it.
    @State private var contentTopY: CGFloat = 0
    @State private var contentBottomY: CGFloat = 0

    private static let timelineBottomID = "conversation-timeline-bottom"

    private struct ActionsTarget: Identifiable {
        let record: AppMessageRecordFfi
        let id = UUID()
    }

    init(
        chat: AppGroupRecordFfi,
        initialTitle: String? = nil,
        initialOtherMember: String? = nil,
        initialMemberCount: Int? = nil,
        initialTargetMessageIdHex: String? = nil,
        initialAppState: AppState? = nil,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)? = nil,
        onGroupChanged: ((AppGroupRecordFfi) -> Void)? = nil
    ) {
        self.chat = chat
        self.initialTitle = initialTitle
        self.initialOtherMember = initialOtherMember
        self.initialMemberCount = initialMemberCount
        self.onChatListRowUpdated = onChatListRowUpdated
        self.onGroupChanged = onGroupChanged
        let targetMessageId = initialTargetMessageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialTargetMessageIdHex = targetMessageId?.isEmpty == false ? targetMessageId : nil
        _viewModel = State(
            initialValue: initialAppState.map {
                ConversationViewModel(
                    appState: $0,
                    group: chat,
                    initialTitle: initialTitle,
                    initialOtherMember: initialOtherMember,
                    initialMemberCount: initialMemberCount,
                    onChatListRowUpdated: onChatListRowUpdated
                )
            }
        )
    }

    /// Binding that's `true` only for the row matching `actionsTarget`, so the
    /// floating actions popover anchors to the long-pressed bubble.
    private func actionsBinding(for record: AppMessageRecordFfi) -> Binding<Bool> {
        Binding(
            get: {
                !actionsCentered
                    && actionsTarget?.record.messageIdHex == record.messageIdHex
                    && !record.messageIdHex.isEmpty
            },
            set: { shown in if !shown { dismissActions() } }
        )
    }

    var body: some View {
        timeline
            .bottomInputChromeAccessory { composerArea }
            .overlay { centeredActionsOverlay }
            .navigationTitle(conversationChrome.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    conversationTitle
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDetails = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Group details")
                }
            }
            .sheet(isPresented: $showDetails) {
                if let viewModel {
                    NavigationStack {
                        GroupDetailsView(
                            viewModel: viewModel,
                            onGroupChanged: { group in
                                onGroupChanged?(group)
                            }
                        )
                    }
                    .appAppearance()
                }
            }
            .sheet(item: $emojiPickerTarget) { target in
                if let viewModel {
                    EmojiPickerSheet(onPick: { emoji in
                        Task { await viewModel.toggleReaction(emoji, on: target.record) }
                        appState.addRecentReaction(emoji)
                    })
                    .appAppearance()
                }
            }
            .sheet(isPresented: $showCameraCapture) {
                CameraCaptureView(
                    onImage: { image in
                        showCameraCapture = false
                        addCameraImage(image)
                    },
                    onCancel: {
                        showCameraCapture = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showPhotoLibraryPicker) {
                PhotoLibraryPickerView(
                    selectionLimit: remainingMediaDraftSlots,
                    onSelection: addPhotoLibrarySelections,
                    onError: { error in
                        appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                    },
                    onDismiss: {
                        showPhotoLibraryPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: MediaAttachmentPolicy.fileImporterAllowedTypes,
                allowsMultipleSelection: true,
                onCompletion: addFileImporterResult
            )
            .task(id: appState.runtimeGeneration) {
                if viewModel == nil {
                    viewModel = ConversationViewModel(
                        appState: appState,
                        group: chat,
                        initialTitle: initialTitle,
                        initialOtherMember: initialOtherMember,
                        initialMemberCount: initialMemberCount,
                        onChatListRowUpdated: onChatListRowUpdated
                    )
                }
                await viewModel?.start()
            }
            .onChange(of: appState.streamingDebugEnabled) { _, _ in
                viewModel?.refreshStreamingDebugPresentation()
            }
            .onChange(of: appState.profileRefreshGeneration) { _, _ in
                viewModel?.refreshProfileDependentTimelineProjections()
            }
            .onAppear {
                visibleChatRoute = appState.beginViewingChat(groupIdHex: chat.groupIdHex)
            }
            .onDisappear {
                if let visibleChatRoute {
                    appState.endViewingChat(visibleChatRoute)
                }
                cancelPendingTimelineFollowUpWork()
                dismissKeyboard()
            }
    }

    // MARK: - Composer + reply

    @ViewBuilder
    private var composerArea: some View {
        VStack(spacing: 0) {
            if let viewModel, let replyingTo = viewModel.replyingTo {
                replyBar(for: replyingTo, viewModel: viewModel)
            }
            let inlineAudioDraft = ComposerMediaDraftPresentation.inlineAudioDraft(in: mediaDrafts)
            let mentionCandidates = inlineAudioDraft == nil ? (viewModel?.mentionCandidates(for: draft) ?? []) : []
            let stripAttachments = ComposerMediaDraftPresentation.stripAttachments(from: mediaDrafts)
            if !stripAttachments.isEmpty {
                MediaDraftStrip(attachments: stripAttachments) { id in
                    removeMediaDraft(id)
                }
            }
            if voiceRecorder.isActive {
                VoiceRecordingBanner(
                    samples: voiceRecorder.waveformSamples,
                    durationSeconds: voiceRecorder.durationSeconds,
                    isLocked: voiceRecorder.isLocked,
                    onCancel: cancelVoiceRecording,
                    onStop: stopLockedVoiceRecording
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ComposerBar(
                draft: $draft,
                isSending: viewModel?.sendInFlight ?? false,
                hasAttachments: !mediaDrafts.isEmpty,
                audioDraft: inlineAudioDraft,
                mediaEnabled: viewModel?.canSendMediaAttachments ?? false,
                voiceRecordingActive: voiceRecorder.isActive,
                focusRequest: composerFocusRequest,
                mentionCandidates: mentionCandidates,
                onTakePhoto: takePhoto,
                onPhotoLibrary: openPhotoLibrary,
                onAttachFile: openFileImporter,
                onRemoveAudioDraft: removeMediaDraft,
                onVoicePressBegan: beginVoicePress,
                onVoiceDragChanged: updateVoiceDrag,
                onVoicePressEnded: endVoicePress,
                onMentionSelect: { candidate in
                    viewModel?.applyMentionSelection(candidate, to: &draft)
                },
                onSend: send
            )
        }
        .keyboardAdaptiveBottomPadding()
    }

    private func replyBar(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.formatted("Replying to %@", appState.displayName(forAccountIdHex: record.sender)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                Text(ProfileSanitizer.singleLine(viewModel.displayBody(of: record), maxLength: 100) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
            }
            Spacer()
            Button {
                viewModel.replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: ReplyPreviewLayout.closeIconSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: ReplyPreviewLayout.closeHitSize,
                        height: ReplyPreviewLayout.closeHitSize,
                        alignment: ReplyPreviewLayout.closeAlignment.swiftUI
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.leading, ReplyPreviewLayout.leadingContentInset)
        .padding(.trailing, ReplyPreviewLayout.closeTrailingInset)
        .padding(.top, ReplyPreviewLayout.contentTopInset)
        .padding(.bottom, ReplyPreviewLayout.contentBottomInset)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.82))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .padding(.horizontal, ReplyPreviewLayout.outerHorizontalInset)
        .padding(.top, ReplyPreviewLayout.outerTopInset)
        .padding(.bottom, ReplyPreviewLayout.outerBottomInset)
    }

    @ViewBuilder
    private var conversationTitle: some View {
        let chrome = conversationChrome
        VStack(spacing: 0) {
            Text(chrome.title)
                .font(.headline)
                .lineLimit(1)
            Text(chrome.subtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(chrome.subtitle == nil ? 0 : 1)
        }
    }

    private var conversationChrome: ConversationChromePresentation {
        if let viewModel {
            return ConversationChromePresentation(
                title: viewModel.displayTitle,
                subtitle: viewModel.displaySubtitle
            )
        }
        return .initial(
            chat: chat,
            initialTitle: initialTitle,
            initialMemberCount: initialMemberCount
        )
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        if let viewModel {
            if viewModel.timeline.isEmpty {
                if let error = viewModel.error {
                    ContentUnavailableView {
                        Label("Couldn't load conversation", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.start() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No messages yet",
                        systemImage: "bubble.middle.bottom",
                        description: Text("Send the first message to get started.")
                    )
                }
            } else {
                let concealInitialTimeline = shouldConcealInitialTimelineContent(viewModel: viewModel)
                ScrollViewReader { proxy in
                    GeometryReader { outer in
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    olderTimelineTrigger(viewModel: viewModel)
                                    ForEach(viewModel.timeline) { item in
                                        row(for: item, viewModel: viewModel)
                                    }
                                    .padding(.bottom, 4)
                                    newerTimelineTrigger(viewModel: viewModel)
                                }
                                timelineBottomSentinel
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            scrollToBottomButton(proxy: proxy, viewModel: viewModel)
                        }
                        .opacity(concealInitialTimeline ? 0 : 1)
                        .allowsHitTesting(!concealInitialTimeline)
                        .accessibilityHidden(concealInitialTimeline)
                        .defaultScrollAnchor(.bottom)
                        .compatibleBottomScrollEdgeEffect()
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(TapGesture().onEnded { scheduleKeyboardDismiss() })
                        .onPreferenceChange(RowFramesKey.self) { rowFrames.frames = $0 }
                        .onScrollGeometryChange(for: TimelineBottomViewport.self) { geometry in
                            TimelineBottomViewport(
                                contentHeight: geometry.contentSize.height,
                                visibleBottomY: geometry.visibleRect.maxY,
                                bottomContentInset: geometry.contentInsets.bottom
                            )
                        } action: { previous, current in
                            if TimelineBottom.shouldRepairBottomOverscroll(current) {
                                isAtTimelineBottom = true
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: false,
                                    reason: .viewportChange,
                                    targetID: viewModel.timeline.last?.id
                                )
                            } else if TimelineBottom.shouldPreservePinAfterContentGrowth(
                                previous: previous,
                                current: current
                            ) {
                                isAtTimelineBottom = true
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: true,
                                    reason: .contentGrowth,
                                    targetID: viewModel.timeline.last?.id
                                )
                            } else {
                                isAtTimelineBottom = current.isPinned
                            }
                        }
                        .onChange(of: viewModel.timeline.last?.id) { _, newId in
                            guard newId != nil else { return }
                            if performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel) {
                                return
                            }
                            settleInitialTimelinePositionIfNoScrollNeeded(viewModel: viewModel)
                            if isAtTimelineBottom {
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: true,
                                    reason: .timelineChange,
                                    targetID: newId
                                )
                            }
                        }
                        .onChange(of: outer.size.height) { _, _ in
                            let wasAtBottom = isAtTimelineBottom
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                            if TimelineBottom.shouldFollowViewportChange(wasPinned: wasAtBottom) {
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: false,
                                    reason: .viewportChange,
                                    targetID: viewModel.timeline.last?.id
                                )
                            }
                        }
                        .onAppear {
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                            if !performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel) {
                                settleInitialTimelinePositionIfNoScrollNeeded(viewModel: viewModel)
                            }
                        }
                        .onDisappear {
                            initialScrollFollowUpTask?.cancel()
                            initialScrollFollowUpTask = nil
                            cancelPendingBottomScroll()
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(for item: TimelineItem, viewModel: ConversationViewModel) -> some View {
        switch item.kind {
        case .message(let record, let status):
            if let groupSystemText = GroupSystemEventPresentation.displayText(
                for: record,
                displayName: { appState.displayName(forAccountIdHex: $0) }
            ) {
                GroupSystemEventRow(text: groupSystemText)
                    .id(item.id)
                    .onAppear {
                        Task { await viewModel.markReadIfVisible(record) }
                    }
            } else if let agentDisplay = AgentEventPresentation.display(for: record) {
                AgentEventRow(
                    senderName: appState.displayName(forAccountIdHex: record.sender),
                    display: agentDisplay,
                    debugStyle: appState.streamingDebugEnabled
                        ? MessageSemantics.debugStyle(for: record)
                        : nil
                )
                .id(item.id)
                .onAppear {
                    Task { await viewModel.markReadIfVisible(record) }
                }
            } else {
                agentMessageBubbleRow(
                    for: item,
                    record: record,
                    status: status,
                    viewModel: viewModel
                )
            }
        case .systemEvent(let event):
            SystemEventRow(event: event)
                .id(item.id)
        case .streamDebugEvent(let event):
            StreamDebugEventRow(event: event)
                .id(item.id)
        }
    }

    @ViewBuilder
    private func agentMessageBubbleRow(
        for item: TimelineItem,
        record: AppMessageRecordFfi,
        status: MessageStatus,
        viewModel: ConversationViewModel
    ) -> some View {
        let debugStyle = appState.streamingDebugEnabled
            ? MessageSemantics.debugStyle(for: record)
            : nil
        let allowsActions = debugStyle?.isUserVisibleBubble ?? true
        MessageBubble(
            record: record,
            status: status,
            debugStyle: debugStyle,
            isDeleted: viewModel.isDeleted(record.messageIdHex),
            replyPreview: viewModel.replyPreview(for: record),
            mediaItems: viewModel.mediaItems(for: item),
            markdownBlocks: viewModel.markdownDisplayBlocks(for: item),
            reactions: viewModel.reactions(for: record.messageIdHex),
            onTapReaction: { emoji in
                Task { await viewModel.toggleReaction(emoji, on: record) }
                appState.addRecentReaction(emoji)
            },
            onLoadMedia: { media in
                try await viewModel.data(for: media)
            }
        )
        .replySwipeToReply(isEnabled: allowsActions && canReply(to: record, viewModel: viewModel)) {
            beginReply(to: record, viewModel: viewModel)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFramesKey.self,
                    value: [item.rowFrameKey: geo.frame(in: .global)]
                )
            }
        )
        .id(item.id)
        .onLongPressGesture {
            guard allowsActions,
                  !record.messageIdHex.isEmpty,
                  !viewModel.isDeleted(record.messageIdHex) else { return }
            Haptics.tap()
            presentActions(for: record, rowFrameKey: item.rowFrameKey)
        }
        .popover(
            isPresented: actionsBinding(for: record),
            attachmentAnchor: .point(actionsAbove ? .top : .bottom),
            arrowEdge: actionsAbove ? .bottom : .top
        ) {
            actionsMenu(for: record, viewModel: viewModel)
        }
        .onAppear {
            guard allowsActions else { return }
            Task { await viewModel.markReadIfVisible(record) }
        }
    }

    private var timelineBottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.timelineBottomID)
    }

    @ViewBuilder
    private func olderTimelineTrigger(viewModel: ConversationViewModel) -> some View {
        if viewModel.hasMoreBefore || viewModel.isLoadingOlder {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(viewModel.isLoadingOlder ? 1 : 0.01)
                Spacer()
            }
            .frame(height: 28)
            .onAppear {
                let shouldRequest = TimelinePaginationTrigger.shouldRequestPage(
                    hasMore: viewModel.hasMoreBefore,
                    isTriggerAlreadyVisible: isOlderTimelineTriggerVisible
                )
                isOlderTimelineTriggerVisible = true
                guard shouldRequest else { return }
                Task { await viewModel.loadOlderTimelinePage() }
            }
            .onDisappear {
                isOlderTimelineTriggerVisible = false
            }
        }
    }

    @ViewBuilder
    private func newerTimelineTrigger(viewModel: ConversationViewModel) -> some View {
        if viewModel.hasMoreAfter || viewModel.isLoadingNewer {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(viewModel.isLoadingNewer ? 1 : 0.01)
                Spacer()
            }
            .frame(height: 28)
            .onAppear {
                let shouldRequest = TimelinePaginationTrigger.shouldRequestPage(
                    hasMore: viewModel.hasMoreAfter,
                    isTriggerAlreadyVisible: isNewerTimelineTriggerVisible
                )
                isNewerTimelineTriggerVisible = true
                guard shouldRequest else { return }
                Task { await viewModel.loadNewerTimelinePage() }
            }
            .onDisappear {
                isNewerTimelineTriggerVisible = false
            }
        }
    }

    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy, viewModel: ConversationViewModel) -> some View {
        if !isAtTimelineBottom || viewModel.hasMoreAfter {
            Button {
                Haptics.tap()
                if viewModel.hasMoreAfter {
                    Task { @MainActor in
                        await viewModel.loadNewerTimelinePage()
                        isAtTimelineBottom = TimelineBottom.pinnedStateAfterScrollButtonTap(
                            currentIsPinned: isAtTimelineBottom
                        )
                        jumpToBottom(proxy: proxy)
                    }
                } else {
                    isAtTimelineBottom = TimelineBottom.pinnedStateAfterScrollButtonTap(
                        currentIsPinned: isAtTimelineBottom
                    )
                    jumpToBottom(proxy: proxy)
                }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background {
                        ZStack {
                            Circle().fill(.regularMaterial)
                            Circle().fill(Color(.secondarySystemBackground).opacity(0.86))
                        }
                    }
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scroll to latest message")
            .padding(.trailing, 9)
            .padding(.bottom, 10)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.smooth(duration: 0.2)) {
                proxy.scrollTo(Self.timelineBottomID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.timelineBottomID, anchor: .bottom)
            }
        }
    }

    private func scheduleScrollToBottom(
        proxy: ScrollViewProxy,
        animated: Bool,
        reason: TimelineBottomScrollReason,
        targetID: String? = nil
    ) {
        if reason == .timelineChange,
           TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
               lastAutomaticTargetID: lastAutomaticBottomScrollTargetID,
               nextTargetID: targetID
           ) {
            return
        }

        let request = TimelineBottomScrollRequest(
            animated: animated,
            reason: reason,
            targetID: targetID
        )
        pendingBottomScrollRequest = TimelineBottomScrollCoordinator.coalesced(
            pendingBottomScrollRequest,
            with: request
        )
        pendingBottomScrollTask?.cancel()
        pendingBottomScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, let request = pendingBottomScrollRequest else { return }
            pendingBottomScrollRequest = nil
            pendingBottomScrollTask = nil
            scrollToBottom(proxy: proxy, animated: request.animated)
            lastAutomaticBottomScrollTargetID = request.targetID
        }
    }

    private func cancelPendingBottomScroll() {
        pendingBottomScrollTask?.cancel()
        pendingBottomScrollTask = nil
        pendingBottomScrollRequest = nil
    }

    private func jumpToBottom(proxy: ScrollViewProxy) {
        // Keep the button as one animated scroll, but defer it through the same
        // coalescer as automatic follow-ups so it doesn't stack in the current
        // SwiftUI transaction (#44, #161).
        cancelPendingBottomScroll()
        scheduleScrollToBottom(
            proxy: proxy,
            animated: true,
            reason: .buttonTap,
            targetID: viewModel?.timeline.last?.id
        )
    }

    private func performInitialScrollIfNeeded(proxy: ScrollViewProxy, viewModel: ConversationViewModel) -> Bool {
        let targetItemId = initialTargetMessageIdHex.flatMap {
            timelineItemId(forMessageIdHex: $0, viewModel: viewModel)
        }
        switch TimelineInitialScroll.destination(
            hasItems: !viewModel.timeline.isEmpty,
            didPerformInitialScroll: didPerformInitialBottomScroll,
            targetMessageIdHex: initialTargetMessageIdHex,
            targetItemId: targetItemId
        ) {
        case .none:
            return false
        case .bottom:
            didPerformInitialBottomScroll = true
            isInitialTimelinePositionSettled = false
            isAtTimelineBottom = true
            scrollToBottom(proxy: proxy, animated: false)
            scheduleInitialScrollFollowUp(.bottom, proxy: proxy)
        case .item(let itemId):
            didPerformInitialBottomScroll = true
            isInitialTimelinePositionSettled = false
            isAtTimelineBottom = false
            scrollTo(itemId, proxy: proxy, anchor: .center)
            scheduleInitialScrollFollowUp(.item(itemId), proxy: proxy)
        }
        return true
    }

    private func scheduleInitialScrollFollowUp(
        _ destination: TimelineInitialDestination,
        proxy: ScrollViewProxy
    ) {
        initialScrollFollowUpTask?.cancel()
        initialScrollFollowUpTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            switch destination {
            case .none:
                break
            case .bottom:
                scrollToBottom(proxy: proxy, animated: false)
            case .item(let itemId):
                scrollTo(itemId, proxy: proxy, anchor: .center)
            }

            await Task.yield()
            guard !Task.isCancelled else { return }
            isInitialTimelinePositionSettled = true
        }
    }

    private func shouldConcealInitialTimelineContent(viewModel: ConversationViewModel) -> Bool {
        TimelineInitialScroll.shouldConcealContent(
            hasItems: !viewModel.timeline.isEmpty,
            didFinishInitialPositioning: isInitialTimelinePositionSettled,
            targetMessageIdHex: initialTargetMessageIdHex,
            targetItemId: initialTargetItemId(viewModel: viewModel)
        )
    }

    private func settleInitialTimelinePositionIfNoScrollNeeded(viewModel: ConversationViewModel) {
        guard !shouldConcealInitialTimelineContent(viewModel: viewModel) else { return }
        isInitialTimelinePositionSettled = true
    }

    private func timelineItemId(forMessageIdHex messageIdHex: String, viewModel: ConversationViewModel) -> String? {
        viewModel.timeline.first { item in
            guard case .message(let record, _) = item.kind else { return false }
            return record.messageIdHex == messageIdHex
        }?.id
    }

    private func initialTargetItemId(viewModel: ConversationViewModel) -> String? {
        initialTargetMessageIdHex.flatMap {
            timelineItemId(forMessageIdHex: $0, viewModel: viewModel)
        }
    }

    private func scrollTo(_ itemId: String, proxy: ScrollViewProxy, anchor: UnitPoint) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(itemId, anchor: anchor)
        }
    }

    private func canReply(to record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> Bool {
        !record.messageIdHex.isEmpty && !viewModel.isDeleted(record.messageIdHex)
    }

    private func beginReply(to record: AppMessageRecordFfi, viewModel: ConversationViewModel) {
        guard canReply(to: record, viewModel: viewModel) else { return }
        viewModel.replyingTo = record
        composerFocusRequest += 1
    }

    private func send() {
        guard let payload = ConversationSendPreparation.prepare(
            draft: &draft,
            mediaDrafts: &mediaDrafts,
            viewModel: viewModel
        ) else { return }
        Task {
            if payload.attachments.isEmpty {
                await payload.viewModel.send(payload.text)
            } else {
                await payload.viewModel.sendMedia(payload.attachments, caption: payload.text)
            }
        }
    }

    private func takePhoto() {
        guard canBeginMediaSelection() else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            appState.present(.warning(L10n.string("Camera is not available on this device")))
            return
        }
        showCameraCapture = true
    }

    private func openPhotoLibrary() {
        guard canBeginMediaSelection() else { return }
        showPhotoLibraryPicker = true
    }

    private func openFileImporter() {
        guard canBeginMediaSelection() else { return }
        showFileImporter = true
    }

    private func addCameraImage(_ image: UIImage) {
        Task { @MainActor in
            do {
                let attachment = try await MediaDraftProcessor.preparedAttachment(from: image, fileName: nil)
                try appendMediaDraft(attachment)
            } catch is CancellationError {
                return
            } catch {
                appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
            }
        }
    }

    private func addPhotoLibrarySelections(_ selections: [PhotoLibrarySelection]) {
        guard let viewModel, viewModel.canSendMediaAttachments else {
            appState.present(.warning(L10n.string("Media is not available in this group")))
            return
        }
        guard remainingMediaDraftSlots > 0 else {
            presentMaxAttachmentWarning()
            return
        }

        let selected = Array(selections.prefix(remainingMediaDraftSlots))
        if selected.count < selections.count {
            presentMaxAttachmentWarning()
        }

        Task { @MainActor in
            for selection in selected {
                do {
                    let attachment = try await MediaDraftProcessor.preparedAttachment(
                        from: selection.data,
                        fileName: selection.fileName,
                        typeIdentifier: selection.typeIdentifier
                    )
                    try appendMediaDraft(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                }
            }
        }
    }

    private func addFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addFileAttachments(urls)
        case .failure(let error):
            appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
        }
    }

    private func addFileAttachments(_ urls: [URL]) {
        guard let viewModel, viewModel.canSendMediaAttachments else {
            appState.present(.warning(L10n.string("Media is not available in this group")))
            return
        }
        guard remainingMediaDraftSlots > 0 else {
            presentMaxAttachmentWarning()
            return
        }
        let selected = Array(urls.prefix(remainingMediaDraftSlots))
        if selected.count < urls.count {
            presentMaxAttachmentWarning()
        }

        Task { @MainActor in
            for url in selected {
                let isSecurityScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isSecurityScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let attachment = try await MediaDraftProcessor.preparedAttachment(fromFileURL: url)
                    try appendMediaDraft(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                }
            }
        }
    }

    private func beginVoicePress() {
        guard canBeginMediaSelection() else { return }
        voiceRecorder.beginPress { error in
            appState.present(.error(L10n.string("Couldn't record audio"), message: error.localizedDescription))
        }
    }

    private func updateVoiceDrag(_ translation: CGSize) {
        voiceRecorder.updateDrag(translation)
    }

    private func endVoicePress() {
        guard let result = voiceRecorder.endPress() else { return }
        addVoiceRecording(result)
    }

    private func stopLockedVoiceRecording() {
        guard let result = voiceRecorder.stopLockedRecording() else { return }
        addVoiceRecording(result)
    }

    private func cancelVoiceRecording() {
        voiceRecorder.cancel()
    }

    private func addVoiceRecording(_ result: VoiceRecordingResult) {
        Task { @MainActor in
            do {
                let attachment = try await MediaDraftProcessor.preparedVoiceAttachment(from: result)
                try appendMediaDraft(attachment)
            } catch is CancellationError {
                return
            } catch {
                appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
            }
        }
    }

    private var remainingMediaDraftSlots: Int {
        max(0, MediaDraftProcessor.maxAttachmentCount - mediaDrafts.count)
    }

    private func canBeginMediaSelection() -> Bool {
        guard let viewModel, viewModel.canSendMediaAttachments else {
            appState.present(.warning(L10n.string("Media is not available in this group")))
            return false
        }
        guard remainingMediaDraftSlots > 0 else {
            presentMaxAttachmentWarning()
            return false
        }
        return true
    }

    private func appendMediaDraft(_ attachment: MediaDraftAttachment) throws {
        if attachment.kind == .audio {
            mediaDrafts.removeAll { $0.kind == .audio }
        }
        guard mediaDrafts.count < MediaDraftProcessor.maxAttachmentCount else {
            presentMaxAttachmentWarning()
            return
        }
        mediaDrafts.append(attachment)
        if attachment.kind == .audio {
            draft = ""
            dismissKeyboard()
            return
        }
        composerFocusRequest += 1
    }

    private func removeMediaDraft(_ id: MediaDraftAttachment.ID) {
        mediaDrafts.removeAll { $0.id == id }
    }

    private func presentMaxAttachmentWarning() {
        appState.present(.warning(L10n.plural("You can send up to %lld attachments at once", Int64(MediaDraftProcessor.maxAttachmentCount))))
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func scheduleKeyboardDismiss() {
        pendingKeyboardDismissTask?.cancel()
        pendingKeyboardDismissTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            pendingKeyboardDismissTask = nil
            dismissKeyboard()
        }
    }

    private func cancelPendingKeyboardDismiss() {
        pendingKeyboardDismissTask?.cancel()
        pendingKeyboardDismissTask = nil
    }

    private func cancelPendingTimelineFollowUpWork() {
        initialScrollFollowUpTask?.cancel()
        initialScrollFollowUpTask = nil
        cancelPendingBottomScroll()
        cancelPendingKeyboardDismiss()
    }

    // MARK: - Message actions placement

    /// Decide where the actions menu opens for the long-pressed bubble: below it
    /// (default), flipped above it (no room below), or centered over it (the
    /// bubble is so tall neither end has room — a popover would land off-screen).
    private func presentActions(for record: AppMessageRecordFfi, rowFrameKey: String) {
        let frame = rowFrames.frames[rowFrameKey]
        let spaceBelow = contentBottomY - (frame?.maxY ?? 0)
        let spaceAbove = (frame?.minY ?? 0) - contentTopY
        let fitsBelow = spaceBelow >= Self.actionsMenuEstimate
        let fitsAbove = spaceAbove >= Self.actionsMenuEstimate

        actionsAbove = !fitsBelow
        if !fitsBelow && !fitsAbove {
            withAnimation(.easeOut(duration: 0.15)) {
                actionsCentered = true
                actionsTarget = ActionsTarget(record: record)
            }
        } else {
            actionsCentered = false
            actionsTarget = ActionsTarget(record: record)
        }
    }

    private func dismissActions() {
        if actionsCentered {
            withAnimation(.easeOut(duration: 0.15)) {
                actionsTarget = nil
                actionsCentered = false
            }
        } else {
            actionsTarget = nil
            actionsCentered = false
        }
    }

    /// The centered, scrim-backed variant shown for over-tall bubbles. A normal
    /// bubble uses the anchored `.popover` in `row(for:)` instead.
    @ViewBuilder
    private var centeredActionsOverlay: some View {
        if actionsCentered, let viewModel, let target = actionsTarget {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { dismissActions() }
                actionsMenu(for: target.record, viewModel: viewModel)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    .shadow(radius: 24, y: 8)
            }
            .transition(.opacity)
        }
    }

    /// The shared actions menu, used both by the anchored popover and the
    /// centered overlay so their buttons stay in sync.
    private func actionsMenu(
        for record: AppMessageRecordFfi,
        viewModel: ConversationViewModel
    ) -> some View {
        MessageActionsMenu(
            isMine: record.direction == "sent",
            quickReactions: appState.quickReactions,
            onReact: { emoji in
                Task { await viewModel.toggleReaction(emoji, on: record) }
                appState.addRecentReaction(emoji)
                dismissActions()
            },
            onReply: {
                dismissActions()
                beginReply(to: record, viewModel: viewModel)
            },
            onCopy: {
                SensitiveClipboard.copy(viewModel.displayBody(of: record))
                Haptics.tap()
                dismissActions()
            },
            onDelete: {
                Task { await viewModel.deleteMessage(record) }
                dismissActions()
            },
            onMoreEmoji: {
                let target = record
                dismissActions()
                emojiPickerTarget = ActionsTarget(record: target)
            }
        )
    }

    /// Approximate height of the actions popover (reaction row + action rows +
    /// arrow). If neither end of the bubble has at least this much room, the
    /// menu is centered over the bubble instead of anchored to it.
    private static let actionsMenuEstimate: CGFloat = 280
}

/// Holds the latest on-screen frame of each message row. A reference type so
/// scroll-driven updates don't churn SwiftUI state; we only read it on demand
/// when a long press needs to decide which way the actions popover should open.
private final class RowFrameStore {
    var frames: [String: CGRect] = [:]
}

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
