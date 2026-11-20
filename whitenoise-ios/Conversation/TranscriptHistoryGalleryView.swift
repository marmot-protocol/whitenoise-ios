import SwiftUI
import MarmotKit

struct TranscriptHistoryControls {
    var refresh: (() -> Void)?
    var loadMore: (() -> Void)?
    var isLoading: Bool
    var checkedWithoutOverlap: Int?
    var pageFailed: Bool
    var allowsOpeningDemand: Bool
    var didSelect: (String) -> Void
    var verify: (MessageMediaAttachment) async throws -> Bool
    var verifyForward: (MessageMediaAttachment) async throws -> Bool
}

extension EnvironmentValues {
    @Entry var transcriptHistoryControls: TranscriptHistoryControls?
}

struct TranscriptHistoryGalleryView: View {
    let gallery: MessageMediaGallery
    let conversation: ConversationViewModel
    var gifRowID: String? = nil
    let onLoadMedia: ConversationMediaLoader
    let forwardingContext: MediaForwardingContext?
    let onGoToMessage: (String) -> Void
    let onDismiss: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var history = TranscriptAttachmentHistory()
    @State private var activeScope: TranscriptAttachmentHistory.Scope?

    private var scope: TranscriptAttachmentHistory.Scope? {
        return .init(appState: appState, group: conversation.group.groupIdHex)
    }

    var body: some View {
        let currentScope = scope
        let scoped = currentScope != nil && currentScope == activeScope
        // The opening draft can disappear briefly while its confirmed slot is being matched.
        let selectedFromHistory = history.selectedItemID.map { gallery.transcriptCaptions?[$0] == nil } ?? false
        Group {
            if scoped && history.validationFailed && selectedFromHistory {
                ContentUnavailableView {
                    Label("Couldn't load shared media.", systemImage: "photo.on.rectangle")
                } actions: {
                    Button("Retry") { validate() }
                    Button("Close", action: onDismiss)
                }
            } else {
                let expanded = scoped && !history.validationFailed ? expandedGallery : gallery
                MessageMediaFullscreenGalleryView(gallery: expanded, onLoadMedia: onLoadMedia,
                    forwardingContext: forwardingContext, onGoToMessage: onGoToMessage, onDismiss: onDismiss)
                    .id(history.viewerGeneration)
                    .environment(\.transcriptHistoryControls, scoped ? controls(for: expanded) : nil)
            }
        }
        .onChange(of: selectedFromHistory, initial: true) { _, historyOnly in
            history.resetViewerOnDiscard = historyOnly
        }
        .task(id: currentScope) {
            history.begin(currentScope)
            activeScope = currentScope
            guard let currentScope else { return }
            await history.loadPage(scope: currentScope, appState: appState)
        }
        .task(id: history.revision) {
            guard let currentScope, scenePhase == .active else { return }
            await history.validate(scope: currentScope, appState: appState)
        }
        .onReceive(appState.attachmentProjectionUpdates) { update in
            guard currentScope == activeScope else { return }
            history.observe(update)
        }
        .onChange(of: appState.retentionSweepGeneration) { _, _ in
            history.retentionChanged()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { validate() }
        }
        .onDisappear {
            activeScope = nil
            history.begin(nil)
        }
    }

    private func controls(for expanded: MessageMediaGallery) -> TranscriptHistoryControls {
        let progress: Int? = history.canLoadMore && history.scannedSlots > 0
            && (history.isReconnectingPages || expanded.items.count == gallery.items.count) ? history.scannedSlots : nil
        let load: (() -> Void)?
        if history.validationFailed { load = { self.validate() } }
        else if history.canLoadMore { load = { self.loadMore() } }
        else { load = nil }
        let refresh: (() -> Void)?
        if let scope = activeScope, history.hasAdditions && !history.isReconnectingPages && !history.isLoading && !history.validationFailed {
            refresh = {
                Task { await history.refreshAdditions(scope: scope, appState: appState) }
            }
        } else { refresh = nil }
        return TranscriptHistoryControls(refresh: refresh, loadMore: load, isLoading: history.isLoading,
            checkedWithoutOverlap: progress, pageFailed: history.pageFailed || history.validationFailed,
            allowsOpeningDemand: !history.hasPaged, didSelect: { itemID in
                history.hasPaged = true
                history.selectedItemID = itemID
                history.resetViewerOnDiscard = gallery.transcriptCaptions?[itemID] == nil
                if !history.resetViewerOnDiscard { history.lastWindowItemID = itemID }
            }, verify: { [activeScope] item in try await self.verify(item, in: activeScope) },
            verifyForward: { [activeScope] item in try await self.verify(item, in: activeScope, allowingConfirmation: true) })
    }

    private func validate() {
        guard let scope, scope == activeScope else { return }
        Task { await history.validate(scope: scope, appState: appState) }
    }

    private func loadMore() {
        guard let scope, scope == activeScope, history.canLoadMore, !history.isLoading else { return }
        Task {
            guard activeScope == scope, scenePhase == .active else { return }
            await history.loadPage(scope: scope, appState: appState)
        }
    }

    private func verify(_ item: MessageMediaAttachment, in openingScope: TranscriptAttachmentHistory.Scope?,
                        allowingConfirmation: Bool = false) async throws -> Bool {
        guard let openingScope else { throw CancellationError() }
        func checkScope() throws {
            try Task.checkCancellation()
            guard self.scope == openingScope, activeScope == openingScope,
                  appState.isAppSceneActive, scenePhase == .active else { throw CancellationError() }
        }
        try checkScope()
        func presentedItem() throws -> MessageMediaAttachment? {
            if let window = conversation.transcriptMediaGallery(opening: item.id, initialData: nil, includingGIFsIn: gifRowID),
               let visible = window.items.first(where: { $0.id == item.id }) {
                guard visible.canUseBytesPrepared(for: item),
                      allowingConfirmation || visible.localTarget == item.localTarget else { return nil }
                return visible
            }
            guard let target = item.localTarget else { return nil }
            let store = conversation.timelineStore
            guard !store.isHidden(target.messageIdHex), !store.isDeleted(target.messageIdHex),
                  !conversation.timeline.contains(where: { row in
                      guard case .message(let record, _) = row.kind else { return false }
                      return record.messageIdHex == target.messageIdHex
                  }) else { return nil }
            // An invalidated history page cannot establish whether the slot was removed.
            guard let slot = history.pages.slot(for: item) else { throw AttachmentReadError.stale }
            return slot.isVisible(in: store) ? slot.attachment : nil
        }
        guard let presented = try presentedItem() else { return false }
        guard let target = presented.localTarget else {
            if item.localData != nil { return true }
            guard let messageID = gallery.messageIdByItemID[item.id], item.reference != nil else { return false }
            return conversation.timelineStore.hasUnsourcedOwnMessage(messageID)
        }
        let retained = try await history.verifyRetained(target, scope: openingScope, appState: appState)
        try checkScope()
        return try retained && presentedItem()?.localTarget == target
    }

    private var expandedGallery: MessageMediaGallery {
        guard var captions = gallery.transcriptCaptions else { return gallery }
        let windowMessages = Set(conversation.timeline.compactMap { row -> String? in
            guard case .message(let record, _) = row.kind else { return nil }
            return record.messageIdHex
        })
        let edges = history.pages.extensions(around: gallery.items, excluding: windowMessages,
                                             atLiveTail: conversation.conversationWindow?.hasMoreAfter == false,
                                             preserving: history.selectedItemID ?? gallery.initialItemID)
        guard !edges.older.isEmpty || !edges.newer.isEmpty || history.resumeItemID != nil else { return gallery }
        var messages = gallery.messageIdByItemID
        func include(_ slot: TranscriptHistorySlot) -> MessageMediaAttachment? {
            guard slot.isVisible(in: conversation.timelineStore), captions[slot.attachment.id] == nil else { return nil }
            let knownName = conversation.windowIdentities[slot.sender]?.displayName ?? appState.cachedKnownDisplayName(forAccountIdHex: slot.sender)
            let name = conversation.myAccountId == slot.sender ? L10n.string("You")
                : IdentityPresentation.resolve(accountIdHex: slot.sender, knownName: knownName).text
            captions[slot.attachment.id] = .init(sender: name, date: Date(timeIntervalSince1970: TimeInterval(slot.timestamp)))
            messages[slot.attachment.id] = slot.target.messageIdHex
            return slot.attachment
        }
        let durable = Set(conversation.conversationWindow?.messages.map { $0.timeline.messageIdHex } ?? [])
        let items = TranscriptHistoryPages.join(older: edges.older.compactMap(include), window: gallery.items,
            newer: edges.newer.compactMap(include)) { item in
                item.localTarget == nil && gallery.messageIdByItemID[item.id].map { !durable.contains($0) } != false
            }
        let openingID = history.resumeItemID.flatMap { captions[$0] == nil ? nil : $0 } ?? gallery.initialItemID
        return MessageMediaGallery(transcriptItems: items, openingID: openingID,
            initialData: openingID == gallery.initialItemID ? gallery.initialMediaData : nil,
            messages: messages, captions: captions) ?? gallery
    }
}
