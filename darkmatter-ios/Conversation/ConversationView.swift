import SwiftUI
import UIKit
import MarmotKit

enum TimelineBottom {
    static let pinnedThreshold: CGFloat = 44

    static func isPinned(bottomY: CGFloat, viewportBottomY: CGFloat) -> Bool {
        bottomY <= viewportBottomY + pinnedThreshold
    }

    static func distanceToBottom(contentHeight: CGFloat, visibleBottomY: CGFloat) -> CGFloat {
        max(0, contentHeight - visibleBottomY)
    }

    static func shouldShowScrollToBottomButton(distanceToBottom: CGFloat) -> Bool {
        distanceToBottom > pinnedThreshold
    }

    static func shouldFollowViewportChange(wasPinned: Bool) -> Bool {
        wasPinned
    }

    static func pinnedStateAfterScrollButtonTap(currentIsPinned: Bool) -> Bool {
        currentIsPinned
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

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    let chat: AppGroupRecordFfi
    let initialTitle: String?
    let initialOtherMember: String?
    let initialMemberCount: Int?
    let initialTargetMessageIdHex: String?
    let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?

    @State private var viewModel: ConversationViewModel?
    @State private var draft: String = ""
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
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)? = nil
    ) {
        self.chat = chat
        self.initialTitle = initialTitle
        self.initialOtherMember = initialOtherMember
        self.initialMemberCount = initialMemberCount
        self.onChatListRowUpdated = onChatListRowUpdated
        let targetMessageId = initialTargetMessageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialTargetMessageIdHex = targetMessageId?.isEmpty == false ? targetMessageId : nil
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
            .safeAreaInset(edge: .bottom, spacing: 0) { composerArea }
            .overlay { centeredActionsOverlay }
            .navigationTitle(viewModel?.displayTitle ?? chat.name)
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
                        GroupDetailsView(viewModel: viewModel)
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
            .onAppear {
                visibleChatRoute = appState.beginViewingChat(groupIdHex: chat.groupIdHex)
            }
            .onDisappear {
                if let visibleChatRoute {
                    appState.endViewingChat(visibleChatRoute)
                }
            }
    }

    // MARK: - Composer + reply

    @ViewBuilder
    private var composerArea: some View {
        VStack(spacing: 0) {
            if let viewModel, let replyingTo = viewModel.replyingTo {
                replyBar(for: replyingTo, viewModel: viewModel)
            }
            ComposerBar(
                draft: $draft,
                isSending: viewModel?.sendInFlight ?? false,
                focusRequest: composerFocusRequest,
                onSend: send
            )
        }
    }

    private func replyBar(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(appState.displayName(forAccountIdHex: record.sender))")
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
        if let viewModel {
            VStack(spacing: 0) {
                Text(viewModel.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.displaySubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(chat.name)
                .font(.headline)
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        if let viewModel {
            if viewModel.timeline.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.middle.bottom",
                    description: Text("Send the first message to get started.")
                )
            } else {
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
                                }
                                timelineBottomSentinel
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            scrollToBottomButton(proxy: proxy)
                        }
                        .defaultScrollAnchor(.bottom)
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                        .onPreferenceChange(RowFramesKey.self) { rowFrames.frames = $0 }
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            TimelineBottom.shouldShowScrollToBottomButton(
                                distanceToBottom: TimelineBottom.distanceToBottom(
                                    contentHeight: geometry.contentSize.height,
                                    visibleBottomY: geometry.visibleRect.maxY
                                )
                            )
                        } action: { _, shouldShowButton in
                            isAtTimelineBottom = !shouldShowButton
                        }
                        .onChange(of: viewModel.timeline.last?.id) { _, newId in
                            guard newId != nil else { return }
                            if performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel) {
                                return
                            }
                            if isAtTimelineBottom {
                                scrollToBottom(proxy: proxy, animated: true)
                            }
                        }
                        .onChange(of: outer.size.height) { _, _ in
                            let wasAtBottom = isAtTimelineBottom
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                            if TimelineBottom.shouldFollowViewportChange(wasPinned: wasAtBottom) {
                                scrollToBottom(proxy: proxy, animated: false)
                            }
                        }
                        .onAppear {
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                            _ = performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel)
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
            MessageBubble(
                record: record,
                status: status,
                isDeleted: viewModel.isDeleted(record.messageIdHex),
                replyPreview: viewModel.replyPreview(for: record),
                reactions: viewModel.reactions(for: record.messageIdHex),
                onTapReaction: { emoji in
                    Task { await viewModel.toggleReaction(emoji, on: record) }
                    appState.addRecentReaction(emoji)
                }
            )
            .replySwipeToReply(isEnabled: canReply(to: record, viewModel: viewModel)) {
                beginReply(to: record, viewModel: viewModel)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowFramesKey.self,
                        value: [record.messageIdHex: geo.frame(in: .global)]
                    )
                }
            )
            .id(item.id)
            .onLongPressGesture {
                guard !record.messageIdHex.isEmpty,
                      !viewModel.isDeleted(record.messageIdHex) else { return }
                Haptics.tap()
                presentActions(for: record)
            }
            .popover(
                isPresented: actionsBinding(for: record),
                attachmentAnchor: .point(actionsAbove ? .top : .bottom),
                arrowEdge: actionsAbove ? .bottom : .top
            ) {
                actionsMenu(for: record, viewModel: viewModel)
            }
            .onAppear {
                Task { await viewModel.markReadIfVisible(record) }
            }
        case .systemEvent(let event):
            SystemEventRow(event: event)
                .id(item.id)
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
                guard viewModel.hasMoreBefore else { return }
                Task { await viewModel.loadOlderTimelinePage() }
            }
        }
    }

    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        if !isAtTimelineBottom {
            Button {
                Haptics.tap()
                isAtTimelineBottom = TimelineBottom.pinnedStateAfterScrollButtonTap(currentIsPinned: isAtTimelineBottom)
                jumpToBottom(proxy: proxy)
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

    private func jumpToBottom(proxy: ScrollViewProxy) {
        scrollToBottom(proxy: proxy, animated: false)
        DispatchQueue.main.async {
            scrollToBottom(proxy: proxy, animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            scrollToBottom(proxy: proxy, animated: false)
        }
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
            isAtTimelineBottom = true
            scrollToBottom(proxy: proxy, animated: false)
            DispatchQueue.main.async {
                scrollToBottom(proxy: proxy, animated: false)
            }
        case .item(let itemId):
            didPerformInitialBottomScroll = true
            isAtTimelineBottom = false
            scrollTo(itemId, proxy: proxy, anchor: .center)
            DispatchQueue.main.async {
                scrollTo(itemId, proxy: proxy, anchor: .center)
            }
        }
        return true
    }

    private func timelineItemId(forMessageIdHex messageIdHex: String, viewModel: ConversationViewModel) -> String? {
        viewModel.timeline.first { item in
            guard case .message(let record, _) = item.kind else { return false }
            return record.messageIdHex == messageIdHex
        }?.id
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
        let text = draft
        draft = ""
        Task {
            await viewModel?.send(text)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - Message actions placement

    /// Decide where the actions menu opens for the long-pressed bubble: below it
    /// (default), flipped above it (no room below), or centered over it (the
    /// bubble is so tall neither end has room — a popover would land off-screen).
    private func presentActions(for record: AppMessageRecordFfi) {
        let frame = rowFrames.frames[record.messageIdHex]
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
                UIPasteboard.general.string = viewModel.displayBody(of: record)
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
