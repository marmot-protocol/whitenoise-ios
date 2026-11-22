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
    var verifyForward: (MessageMediaAttachment, MessageMediaGallery.PendingSelection?) async throws -> Bool
}

extension EnvironmentValues {
    @Entry var transcriptHistoryControls: TranscriptHistoryControls?
}

struct TranscriptHistoryGalleryView: View {
    let openingItem: MessageMediaAttachment
    let initialData: Data?
    let conversation: ConversationViewModel
    var openingSelection: MessageMediaGallery.PendingSelection? = nil
    var gifRowID: String? = nil
    let onLoadMedia: ConversationMediaLoader
    let forwardingContext: MediaForwardingContext?
    let onGoToMessage: (String) -> Void
    let onDismiss: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var history = TranscriptAttachmentHistory()
    @State private var activeScope: TranscriptAttachmentHistory.Scope?

    // Window projection and history expansion have different inputs. A page read,
    // validation status or swipe must not project every timeline row again.
    private struct WindowRevision: Equatable {
        let timeline: Int
        let snapshot: ConversationWindowRevisionFfi?
        let profiles: Int
        let account: String?
        let debug: Bool
        let language: AppLanguage
    }

    private struct Inputs: Equatable {
        let window: WindowRevision
        let pages: Int
        let selection: String?
        let resume: String?
        let viewer: Int
    }

    private struct Window {
        var gallery: MessageMediaGallery
        let messageIDs, durableIDs: Set<String>
        let atTail: Bool
        let visibility: TimelineStore.AttachmentVisibility
        let identityNames: [String: String?]

        func hasSameMedia(as previous: Self, pages: TranscriptHistoryPages) -> Bool {
            guard atTail == previous.atTail, visibility == previous.visibility, identityNames == previous.identityNames,
                  gallery.messageIdByItemID == previous.gallery.messageIdByItemID,
                  gallery.transcriptCaptions == previous.gallery.transcriptCaptions,
                  gallery.items.count == previous.gallery.items.count,
                  zip(gallery.items, previous.gallery.items).allSatisfy({ item, old in
                      item == old && item.localTarget == old.localTarget && item.sourceHint == old.sourceHint && item.thumbnail === old.thumbnail
                  }) else { return false }
            let changedMessages = messageIDs.symmetricDifference(previous.messageIDs)
            return !changedMessages.contains(where: pages.contains(messageID:))
                && durableIDs == previous.durableIDs
        }
    }

    @State private var window: Window?
    @State private var expanded: MessageMediaGallery?
    @State private var projectedViewer = 0

    private var projectionInputs: Inputs {
        Inputs(window: WindowRevision(timeline: conversation.timelineProjectionGeneration,
            snapshot: conversation.conversationWindow?.revision, profiles: appState.profileRefreshGeneration,
            account: conversation.myAccountId, debug: appState.streamingDebugEnabled, language: AppLanguage.current),
            pages: history.pagesRevision, selection: history.selectedItemID, resume: history.resumeItemID, viewer: history.viewerGeneration)
    }

    private var scope: TranscriptAttachmentHistory.Scope? {
        return .init(appState: appState, group: conversation.group.groupIdHex)
    }

    var body: some View {
        let currentScope = scope
        let scoped = currentScope != nil && currentScope == activeScope
        // The opening draft can disappear briefly while its confirmed slot is being matched.
        let selectedID = history.selectedItemID ?? openingItem.id
        let selectedFromHistory = window?.gallery.transcriptCaptions?[selectedID] == nil
            && (history.resetViewerOnDiscard || history.pages.contains(attachmentID: selectedID))
        Group {
            if scoped && history.validationFailed && selectedFromHistory {
                ContentUnavailableView {
                    Label("Couldn't load shared media.", systemImage: "photo.on.rectangle")
                } actions: {
                    Button("Retry") { validate() }
                    Button("Close", action: onDismiss)
                }
            } else if let gallery = window?.gallery, let expanded {
                let visible = scoped && !history.validationFailed ? expanded : gallery
                MessageMediaFullscreenGalleryView(gallery: visible, openingSelection: openingSelection, onLoadMedia: onLoadMedia,
                    forwardingContext: forwardingContext, onGoToMessage: onGoToMessage, onDismiss: onDismiss)
                    .id(projectedViewer)
                    .environment(\.transcriptHistoryControls, scoped ? controls(for: visible, window: gallery) : nil)
            } else {
                ProgressView()
            }
        }
        .onChange(of: projectionInputs, initial: true) { old, new in
            updateProjection(from: old, to: new)
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

    private func controls(for expanded: MessageMediaGallery, window gallery: MessageMediaGallery) -> TranscriptHistoryControls {
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
                history.select(itemID, inWindow: gallery.transcriptCaptions?[itemID] != nil)
            }, verify: { [activeScope] item in try await self.verify(item, in: activeScope) },
            verifyForward: { [activeScope] item, pending in
                try await self.verifyForward(item, pending: pending, in: activeScope)
            })
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

    private func verifyForward(_ item: MessageMediaAttachment, pending: MessageMediaGallery.PendingSelection?,
                               in scope: TranscriptAttachmentHistory.Scope?) async throws -> Bool {
        if let pending, let window = conversation.transcriptMediaGallery(opening: item.id, initialData: nil,
                                                                            includingGIFsIn: gifRowID, allowsEmptyWindow: true),
           window.transcriptCaptions?[item.id] == nil {
            // The chooser may outlive an optimistic UUID. Use the gallery's original
            // row, slot and plaintext match before verifying the confirmed source.
            guard window.confirmedItem(for: pending) != nil else { throw AttachmentReadError.stale }
            guard let confirmed = await window.confirmedSelection(for: pending) else { return false }
            return try await verify(confirmed, in: scope, allowingConfirmation: true)
        }
        return try await verify(item, in: scope, allowingConfirmation: true)
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
            guard let messageID = window?.gallery.messageIdByItemID[item.id], item.reference != nil else { return false }
            return conversation.timelineStore.hasUnsourcedOwnMessage(messageID)
        }
        let retained = try await history.verifyRetained(target, scope: openingScope, appState: appState)
        try checkScope()
        return try retained && presentedItem()?.localTarget == target
    }

    private func updateProjection(from old: Inputs, to new: Inputs) {
        if old.window != new.window || window == nil {
            guard let gallery = conversation.transcriptMediaGallery(opening: openingItem.id, initialData: initialData, openingItem: openingItem,
                includingGIFsIn: gifRowID, allowsEmptyWindow: true) else { return }
            let ids = Set(conversation.timeline.compactMap { row -> String? in
                guard case .message(let record, _) = row.kind else { return nil }
                return record.messageIdHex
            })
            // Only unsourced window items can move behind a newer retained tail.
            let pending = Set(gallery.items.compactMap { $0.localTarget == nil ? gallery.messageIdByItemID[$0.id] : nil })
            let durable = pending.isEmpty ? [] : pending.intersection(conversation.conversationWindow?.messages.map { $0.timeline.messageIdHex } ?? [])
            let next = Window(gallery: gallery, messageIDs: ids, durableIDs: durable,
                atTail: conversation.conversationWindow?.hasMoreAfter == false, visibility: conversation.timelineStore.attachmentVisibility,
                identityNames: conversation.windowIdentities.mapValues(\.displayName))
            let previous = window
            window = next
            if let previous, old.pages == new.pages, old.selection == new.selection, old.resume == new.resume, old.viewer == new.viewer,
               old.window.profiles == new.window.profiles, old.window.language == new.window.language, old.window.account == new.window.account,
               next.hasSameMedia(as: previous, pages: history.pages) { return }
        }
        if let window {
            expanded = expandedGallery(for: window)
            projectedViewer = new.viewer
        }
    }

    private func expandedGallery(for window: Window) -> MessageMediaGallery {
        let gallery = window.gallery
        guard var captions = gallery.transcriptCaptions else { return gallery }
        let selectedID = history.selectedItemID ?? gallery.initialItemID
        let edges = history.pages.extensions(around: gallery.items, excluding: window.messageIDs,
                                             atLiveTail: window.atTail,
                                             preserving: selectedID)
        guard !edges.older.isEmpty || !edges.newer.isEmpty || history.resumeItemID != nil else { return gallery }
        if !edges.includesWindow { captions.removeAll() }
        var messages = edges.includesWindow ? gallery.messageIdByItemID : [:]
        func include(_ slot: TranscriptHistorySlot) -> MessageMediaAttachment? {
            guard slot.isVisible(in: conversation.timelineStore), captions[slot.attachment.id] == nil else { return nil }
            let name = conversation.gallerySenderName(slot.sender, outgoing: conversation.myAccountId == slot.sender)
            captions[slot.attachment.id] = .init(sender: name, date: Date(timeIntervalSince1970: TimeInterval(slot.timestamp)))
            messages[slot.attachment.id] = slot.target.messageIdHex
            return slot.attachment
        }
        let items = TranscriptHistoryPages.join(older: edges.older.compactMap(include), window: edges.includesWindow ? gallery.items : [],
            newer: edges.newer.compactMap(include)) { item in
                item.localTarget == nil && gallery.messageIdByItemID[item.id].map { !window.durableIDs.contains($0) } != false
            }
        let openingID = history.resumeItemID.flatMap { captions[$0] == nil ? nil : $0 }
            ?? (edges.includesWindow ? gallery.initialItemID : selectedID)
        return MessageMediaGallery(transcriptItems: items, openingID: openingID,
            initialData: openingID == gallery.initialItemID ? gallery.initialMediaData : nil,
            messages: messages, captions: captions) ?? gallery
    }
}
