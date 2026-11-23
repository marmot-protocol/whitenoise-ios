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

/// Keeps the explicitly opened GIF in history if its draft confirms and the live row moves away.
struct TranscriptHeldGIF {
    private(set) var confirmed: MessageMediaAttachment?

    mutating func didSelect(_ id: String, in gallery: MessageMediaGallery,
                            opening: MessageMediaAttachment, pending: MessageMediaGallery.PendingSelection?) {
        guard opening.isGIF, opening.localTarget == nil, confirmed == nil, let pending,
              gallery.transcriptCaptions?[id]?.outgoingSlot == pending.slot,
              let item = gallery.items.first(where: { $0.id == id && $0.isGIF && $0.reference != nil }) else { return }
        confirmed = item
    }

    mutating func updateSource(in gallery: MessageMediaGallery, opening: MessageMediaAttachment) {
        let held = confirmed ?? opening
        guard held.isGIF, held.localTarget == nil,
              let sourced = gallery.items.first(where: { $0.isGIF && $0.localTarget != nil && $0.canUseBytesPrepared(for: held) }) else { return }
        confirmed = sourced
    }
}

struct TranscriptHistoryGalleryView: View {
    let openingItem: MessageMediaAttachment
    let initialData: Data?
    let conversation: ConversationViewModel
    var openingSelection: MessageMediaGallery.PendingSelection? = nil
    var gifRowID: String? = nil
    var restored = false
    var didDisplay: ((MessageMediaAttachment?) -> Void)?
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
        let hasOpeningBytes: Bool
        let profiles: Int
        let account: String?
        let debug: Bool
        let language: AppLanguage
    }

    private struct Inputs: Equatable {
        let window: WindowRevision
        let pages: Int
        let resume: String?
        let viewer: Int
    }

    struct Window {
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
    @State private var heldGIF = TranscriptHeldGIF()

    private var projectionInputs: Inputs {
        Inputs(window: WindowRevision(timeline: conversation.timelineProjectionGeneration,
            snapshot: conversation.conversationWindow?.revision, hasOpeningBytes: initialData != nil, profiles: appState.profileRefreshGeneration,
            account: conversation.myAccountId, debug: appState.streamingDebugEnabled, language: AppLanguage.current),
            pages: history.state.pagesRevision, resume: history.state.resumeItemID, viewer: history.state.viewerGeneration)
    }

    private var scope: TranscriptAttachmentHistory.Scope? {
        return .init(appState: appState, group: conversation.group.groupIdHex)
    }

    private var owner: TranscriptAttachmentHistory.Scope? {
        .init(ownerOf: appState, group: conversation.group.groupIdHex)
    }

    private var visibleGallery: MessageMediaGallery? {
        guard let window, let expanded else { return nil }
        if let owner, owner == activeScope, !history.state.validationFailed { return expanded }
        return window.gallery
    }

    var body: some View {
        let availability = AttachmentHistoryPager.Availability(appState, group: conversation.group.groupIdHex)
        let currentScope = availability.readable
        let scoped = availability.owner != nil && availability.owner == activeScope
        Group {
            if scoped && history.state.validationFailed && history.state.selectedFromHistory {
                ContentUnavailableView {
                    Label("Couldn't load shared media.", systemImage: "photo.on.rectangle")
                } actions: {
                    Button("Retry") { validate() }
                    Button("Close", action: onDismiss)
                }
            } else if restored && !history.state.hasPaged, let window, !window.gallery.canRestore(openingItem) {
                // Its source changed between the retained read and this projection.
                // Never mount the restored page with a loader that could admit a transfer.
                Color.clear.onAppear(perform: onDismiss)
            } else if let gallery = window?.gallery, let visible = visibleGallery {
                MessageMediaFullscreenGalleryView(gallery: visible, openingSelection: openingSelection, restored: restored, didDisplay: didDisplay,
                    currentTranscriptGallery: { self.visibleGallery }, onLoadMedia: onLoadMedia,
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
        .task(id: availability) {
            if activeScope != availability.owner {
                history.begin(availability.owner)
                activeScope = availability.owner
            }
            guard let currentScope else { return }
            if history.state.pager.baseline == nil {
                await history.loadPage(scope: currentScope, appState: appState)
            } else {
                await history.validate(scope: currentScope, appState: appState)
            }
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
        let progress: Int? = history.canLoadMore && history.state.scannedSlots > 0
            && (history.state.isReconnectingPages || expanded.items.count == gallery.items.count) ? history.state.scannedSlots : nil
        let load: (() -> Void)?
        if history.state.validationFailed { load = { self.validate() } }
        else if history.canLoadMore { load = { self.loadMore() } }
        else { load = nil }
        let refresh: (() -> Void)?
        if let scope = activeScope, history.state.hasAdditions && !history.state.isReconnectingPages && !history.isLoading && !history.state.validationFailed {
            refresh = {
                Task { await history.refreshAdditions(scope: scope, appState: appState) }
            }
        } else { refresh = nil }
        return TranscriptHistoryControls(refresh: refresh, loadMore: load, isLoading: history.isLoading,
            checkedWithoutOverlap: progress, pageFailed: history.pageFailed || history.state.validationFailed,
            allowsOpeningDemand: !history.state.hasPaged, didSelect: { itemID in
                history.select(itemID, inWindow: gallery.transcriptCaptions?[itemID] != nil)
                heldGIF.didSelect(itemID, in: gallery, opening: openingItem, pending: openingSelection)
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
            guard let slot = history.state.pages.slot(for: item) else { throw AttachmentReadError.stale }
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
            heldGIF.updateSource(in: gallery, opening: openingItem)
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
            let selected = history.state.selectedItemID ?? openingItem.id
            history.updateWindow(for: selected, inWindow: gallery.transcriptCaptions?[selected] != nil)
            if let previous, old.pages == new.pages, old.resume == new.resume, old.viewer == new.viewer,
               old.window.hasOpeningBytes == new.window.hasOpeningBytes, old.window.profiles == new.window.profiles, old.window.language == new.window.language, old.window.account == new.window.account,
               next.hasSameMedia(as: previous, pages: history.state.pages) { return }
        }
        if let window {
            let selected = history.state.selectedItemID ?? openingItem.id
            history.updateWindow(for: selected, inWindow: window.gallery.transcriptCaptions?[selected] != nil)
            expanded = expandedGallery(for: window)
            projectedViewer = new.viewer
        }
    }

    private func expandedGallery(for window: Window) -> MessageMediaGallery {
        let gallery = window.gallery
        guard var captions = gallery.transcriptCaptions else { return gallery }
        let selectedID = history.state.selectedItemID ?? gallery.initialItemID
        let edges = history.state.pages.extensions(around: gallery.items, excluding: window.messageIDs,
                                             atLiveTail: window.atTail,
                                             preserving: selectedID, heldGIF: self.heldGIF.confirmed ?? (openingItem.isGIF ? openingItem : nil))
        guard !edges.older.isEmpty || !edges.newer.isEmpty || history.state.resumeItemID != nil else { return gallery }
        if !edges.includesWindow { captions.removeAll() }
        var messages = edges.includesWindow ? gallery.messageIdByItemID : [:]
        func include(_ slot: TranscriptHistorySlot) -> MessageMediaAttachment? {
            guard slot.isVisible(in: conversation.timelineStore), captions[slot.attachment.id] == nil else { return nil }
            let name = conversation.gallerySenderName(slot.sender)
            captions[slot.attachment.id] = .init(sender: name, date: Date(timeIntervalSince1970: TimeInterval(slot.timestamp)))
            messages[slot.attachment.id] = slot.target.messageIdHex
            return slot.attachment
        }
        let items = TranscriptHistoryPages.join(older: edges.older.compactMap(include), window: edges.includesWindow ? gallery.items : [],
            newer: edges.newer.compactMap(include)) { item in
                item.localTarget == nil && gallery.messageIdByItemID[item.id].map { !window.durableIDs.contains($0) } != false
            }
        let openingID = history.state.resumeItemID.flatMap { captions[$0] == nil ? nil : $0 }
            ?? (edges.includesWindow ? gallery.initialItemID : selectedID)
        return MessageMediaGallery(transcriptItems: items, openingID: openingID,
            initialData: openingID == gallery.initialItemID ? gallery.initialMediaData : nil,
            messages: messages, captions: captions) ?? gallery
    }
}
