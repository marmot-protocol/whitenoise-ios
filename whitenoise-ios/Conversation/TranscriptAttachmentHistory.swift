import Foundation
import MarmotKit
import Observation

/// Metadata only. The selected page continues to load through the conversation's media loader.
struct TranscriptHistorySlot {
    let target: AttachmentLocalTargetFfi
    let attachment: MessageMediaAttachment
    let sender: String
    let timestamp: UInt64

    func isVisible(in store: TimelineStore) -> Bool {
        !store.isHidden(target.messageIdHex) && !store.isDeleted(target.messageIdHex) && !store.isBlockedAuthor(sender)
    }

    init?(_ entry: AttachmentEntryFfi) {
        guard entry.role == .shared, !entry.messageIdHex.isEmpty, !entry.sourceMessageIdHex.isEmpty,
              !entry.sender.isEmpty, case .accepted = entry.attachment,
              let attachment = MessageMediaAttachment.displayItems(fromOutcomes: [entry.attachment],
                  ownerId: TimelineItem.messageRowId(forMessageIdHex: entry.messageIdHex),
                  messageId: entry.messageIdHex, sourceMessageId: entry.sourceMessageIdHex).first,
              let target = attachment.localTarget, attachment.isTranscriptGalleryMedia || attachment.isGIF else { return nil }
        self.target = target
        self.attachment = attachment
        sender = entry.sender
        timestamp = entry.receivedAt == 0 ? entry.timelineAt : min(entry.timelineAt, entry.receivedAt)
    }
}

struct TranscriptHistoryPages {
    // Native pages visit newest messages first. An album can straddle a cursor.
    private var newestFirst: [String] = []
    private var byMessage: [String: [TranscriptHistorySlot]] = [:]
    private var targets: Set<AttachmentLocalTargetFfi> = []
    private var attachmentIDs: Set<String> = []

    mutating func append(_ entries: [AttachmentEntryFfi]) {
        for entry in entries {
            if let slot = TranscriptHistorySlot(entry) { insert(slot) }
        }
    }

    private mutating func insert(_ slot: TranscriptHistorySlot) {
        guard targets.insert(slot.target).inserted else { return }
        attachmentIDs.insert(slot.attachment.id)
        let id = slot.target.messageIdHex
        if byMessage[id] == nil { newestFirst.append(id) }
        // A single album can span cursors. Only its slots need ordering when a page arrives.
        if let index = byMessage[id]?.firstIndex(where: { $0.target.attachmentIndex > slot.target.attachmentIndex }) {
            byMessage[id, default: []].insert(slot, at: index)
        } else {
            byMessage[id, default: []].append(slot)
        }
    }

    func reaches(_ retained: Self) -> Bool {
        retained.targets.isEmpty || !targets.isDisjoint(with: retained.targets)
    }

    func includingRetainedTail(_ retained: Self) -> Self {
        guard reaches(retained) else { return retained }
        var joined = self
        for id in retained.newestFirst {
            for slot in retained.byMessage[id] ?? [] { joined.insert(slot) }
        }
        return joined
    }

    func conflicts(with record: TimelineMessageRecordFfi) -> Bool {
        guard let slots = byMessage[record.messageIdHex] else { return false }
        return record.deleted || slots.contains { slot in
            record.sender != slot.sender || record.sourceMessageIdHex != slot.target.sourceMessageIdHex
                || !record.media.contains { outcome in
                    guard case let .accepted(index, reference) = outcome else { return false }
                    return index == slot.target.attachmentIndex && reference == slot.attachment.reference
                }
        }
    }

    func slot(for item: MessageMediaAttachment) -> TranscriptHistorySlot? {
        guard let target = item.localTarget else { return nil }
        return byMessage[target.messageIdHex]?.first { $0.target == target && $0.attachment.reference == item.reference }
    }

    /// Optimistic local sends follow the entire retained transcript, even when their sheet
    /// was opened from a historical search window that has more durable pages after it.
    static func join(older: [MessageMediaAttachment], window: [MessageMediaAttachment],
                     newer: [MessageMediaAttachment], isOverlay: (MessageMediaAttachment) -> Bool) -> [MessageMediaAttachment] {
        let overlayStart = window.firstIndex(where: isOverlay) ?? window.endIndex
        return older + window[..<overlayStart] + newer + window[overlayStart...]
    }

    func contains(messageID: String) -> Bool { byMessage[messageID] != nil }

    func contains(attachmentID: String) -> Bool {
        attachmentIDs.contains(attachmentID)
    }

    struct Edges {
        var older: [TranscriptHistorySlot] = []
        var newer: [TranscriptHistorySlot] = []
        var includesWindow = true
    }

    /// Extend each edge only once the native cursor has reached that exact slot. In particular, a
    /// recent page cannot appear adjacent to an old search result while intervening pages are missing.
    func extensions(around window: [MessageMediaAttachment],
                    excluding windowMessages: Set<String>, atLiveTail: Bool = false, preserving selectedID: String? = nil) -> Edges {
        let chronological = newestFirst.reversed().flatMap { byMessage[$0] ?? [] }
        // A held GIF can anchor its own window. Other GIFs still play inline.
        func isGalleryPage(_ slot: TranscriptHistorySlot) -> Bool {
            !windowMessages.contains(slot.target.messageIdHex) && !slot.attachment.isGIF
        }
        let first = window.first { $0.localTarget != nil }
        let last = window.last { $0.localTarget != nil }
        func matches(_ slot: TranscriptHistorySlot, _ item: MessageMediaAttachment) -> Bool {
            slot.target == item.localTarget && slot.attachment.reference == item.reference
        }
        let firstOverlap = first.flatMap { item in chronological.firstIndex { matches($0, item) } }
        let lastOverlap = last.flatMap { item in chronological.lastIndex { matches($0, item) } }
        if first == nil, atLiveTail, !window.isEmpty {
            // Pending sends in a confirmed live tail follow the native sequence.
            return Edges(older: chronological.filter(isGalleryPage))
        }
        if firstOverlap == nil, lastOverlap == nil, let selectedID,
           chronological.contains(where: { $0.attachment.id == selectedID && isGalleryPage($0) }) {
            // The selected retained segment is still contiguous. A replacement window
            // belongs in it only after one of its edges reaches a matching source slot.
            return Edges(older: chronological.filter(isGalleryPage), includesWindow: false)
        }
        return Edges(older: firstOverlap.map { chronological[..<$0].filter(isGalleryPage) } ?? [],
                     newer: lastOverlap.map { chronological.suffix(from: $0 + 1).filter(isGalleryPage) } ?? [])
    }
}

@MainActor @Observable
final class TranscriptAttachmentHistory {
    private enum PageRead { case idle, loading, failed }
    private enum CollectionState { case current, additions, unavailable }
    private struct Refresh {
        var prefix = TranscriptHistoryPages()
        let boundary: AttachmentLocalTargetFfi?
        var version: AttachmentHistoryVersion?
    }

    private var read = PageRead.idle
    private var collection = CollectionState.current
    private(set) var pagesRevision = 0
    private(set) var pages = TranscriptHistoryPages() { didSet { pagesRevision &+= 1 } }
    var canLoadMore: Bool { pager.canLoadMore }
    var isLoading: Bool { read == .loading }
    var pageFailed: Bool { read == .failed }
    var validationFailed: Bool { collection == .unavailable }
    var hasAdditions: Bool { collection == .additions }
    private(set) var scannedSlots = 0
    private(set) var revision: UInt64 = 0
    private(set) var hasPaged = false
    // Selection belongs to the pager. Sample it when the collection or validation changes.
    private(set) var selectedItemID: String?
    @ObservationIgnored private var lastWindowItemID: String?
    @ObservationIgnored var resetViewerOnDiscard = false
    private(set) var viewerGeneration = 0
    private(set) var resumeItemID: String?
    private var scope: Scope?
    private var pager = AttachmentHistoryPager()
    var isReconnectingPages: Bool { refresh != nil }
    private var lastScannedSlot: AttachmentLocalTargetFfi?
    private var refresh: Refresh?
    private var additionsVersion: AttachmentHistoryVersion?
    private var generation = 0
    @ObservationIgnored private var validationSequence: UInt64 = 0

    typealias Scope = AttachmentHistoryPager.Scope

    func select(_ itemID: String, inWindow: Bool) {
        hasPaged = true
        selectedItemID = itemID
        resetViewerOnDiscard = !inWindow
        if inWindow { lastWindowItemID = itemID }
    }

    func begin(_ newScope: Scope?) {
        if scope != newScope {
            hasPaged = false
            selectedItemID = nil
            lastWindowItemID = nil
        }
        scope = newScope
        discard()
    }

    // The existing runtime event stream also reports changes to rows outside the transcript window.
    func observe(_ update: RuntimeProjectionUpdateFfi) {
        guard let scope,
              update.accountIdHex == scope.accountID, update.update.groupIdHex == scope.group else { return }
        if update.update.messages.contains(where: pages.conflicts) || update.update.changes.contains(where: { change in
            switch change {
            case .remove(let id, _): pages.contains(messageID: id)
            case .upsert(_, let row): pages.conflicts(with: row)
            }
        }) {
            discard()
        }
        // New text, receipts and reactions cannot revoke an existing slot. A change with
        // only message records has no trigger, so validate it conservatively.
        let destructive = update.update.changes.contains { change in
            switch change {
            case .remove: true
            case .upsert(let trigger, let row):
                row.deleted || [.messageDeleted, .messageEditedOrReprojected, .snapshotRefresh].contains(trigger)
                    || (!row.media.isEmpty && [.newMessage, .deliveryOrSendStateChanged].contains(trigger))
            }
        }
        if destructive || (update.update.changes.isEmpty && !update.update.messages.isEmpty) { revision &+= 1 }
    }

    func retentionChanged() {
        guard scope != nil else { return }
        revision &+= 1
    }

    private func discard() {
        resumeItemID = resetViewerOnDiscard ? lastWindowItemID : nil
        if resetViewerOnDiscard {
            viewerGeneration &+= 1
            selectedItemID = nil
        }
        resetViewerOnDiscard = false
        generation &+= 1
        pages = .init()
        scannedSlots = 0
        read = .idle
        collection = .current
        pager = .init()
        refresh = nil
        lastScannedSlot = nil
        additionsVersion = nil
    }

    func refreshAdditions(scope: Scope, appState: AppState) async {
        guard self.scope == scope, scope == Scope(appState: appState, group: scope.group),
              hasAdditions, refresh == nil, !isLoading else { return }
        generation &+= 1
        // An exhausted collection must be rescanned through exhaustion. A native page
        // can also end without visible media, so use its original, unfiltered last slot.
        refresh = Refresh(boundary: pager.canLoadMore ? lastScannedSlot : nil)
        pager = pager.fromHead()
        collection = .current
        scannedSlots = 0
        await loadPage(scope: scope, appState: appState)
    }

    private func originalSlot(_ entry: AttachmentEntryFfi) -> AttachmentLocalTargetFfi {
        let index: UInt32 = switch entry.attachment {
        case .accepted(let index, _), .rejected(let index, _): index
        }
        return .init(messageIdHex: entry.messageIdHex, sourceMessageIdHex: entry.sourceMessageIdHex, attachmentIndex: index)
    }

    /// One page per request. A stale native cursor may restart once at the head.
    func loadPage(scope: Scope, appState: AppState) async {
        guard !Task.isCancelled, canLoadMore, !isLoading, self.scope == scope else { return }
        var ticket = generation
        var startingRevision = revision
        read = .loading
        defer { if ticket == generation, isLoading { read = .idle } }
        do {
            let (page, next) = try await pager.readNext(in: scope, using: appState,
                isCurrent: { ticket == self.generation }, onRestart: {
                    self.discard()
                    ticket = self.generation
                    startingRevision = self.revision
                    self.read = .loading
                })
            guard ticket == generation, (try? scope.currentClient(in: appState)) != nil else { return }
            let firstRefreshPage = refresh != nil && pager.cursor == nil
            let additionsBase = firstRefreshPage ? page.version : (refresh?.version ?? additionsVersion ?? pager.baseline ?? page.version)
            if revision != startingRevision {
                let checkedRevision = revision
                let current = try await scope.version(in: appState)
                guard ticket == generation else { return }
                if current.changeSince(previous: pager.baseline ?? page.version) == .restartRequired {
                    discard()
                    read = .failed
                    return
                }
                guard checkedRevision == revision else { read = .failed; return }
                if !validationFailed, current.changeSince(previous: additionsBase) == .additions { collection = .additions }
            }
            if firstRefreshPage { refresh?.version = page.version }
            lastScannedSlot = page.entries.last.map(originalSlot)
            scannedSlots += page.entries.count
            pager = next
            if var current = refresh {
                current.prefix.append(page.entries)
                let covered = current.boundary.map { boundary in page.entries.contains { originalSlot($0) == boundary } } ?? false
                if !canLoadMore || covered {
                    pages = current.prefix
                    additionsVersion = current.version
                    refresh = nil
                } else {
                    pages = current.prefix.includingRetainedTail(pages)
                    refresh = current
                }
            } else {
                pages.append(page.entries)
            }
        } catch is CancellationError {
            return
        } catch {
            if ticket == generation { read = .failed }
        }
    }

    /// Save and Forward use already prepared bytes. Confirm that the original slot remains
    /// readable, without requesting a download, before releasing those bytes to another view.
    func verifyRetained(_ target: AttachmentLocalTargetFfi, scope: Scope, appState: AppState) async throws -> Bool {
        guard self.scope == scope else { throw CancellationError() }
        let client = try scope.currentClient(in: appState)
        let startingRevision = revision
        let ticket = generation
        func checkRead() throws {
            guard ticket == generation else { throw CancellationError() }
            guard startingRevision == revision else { throw AttachmentReadError.stale }
        }
        let baseline: AttachmentHistoryVersion
        if let loaded = pager.baseline { baseline = loaded }
        else {
            baseline = try await scope.version(in: appState)
            try checkRead()
        }
        let assets = try await client.marmot.attachmentLocalAssets(accountRef: scope.account,
            groupIdHex: scope.group, targets: [target])
        _ = try scope.currentClient(in: appState)
        try checkRead()
        guard assets.first?.reference != nil else { return false }
        let current = try await scope.version(in: appState)
        try checkRead()
        if current.changeSince(previous: baseline) == .restartRequired {
            discard()
            throw AttachmentReadError.stale
        }
        return true
    }

    /// The collection version invalidates removed, expired, or newly hidden entries outside the
    /// current message window. Additions preserve the native pagination baseline.
    func validate(scope: Scope, appState: AppState) async {
        guard !Task.isCancelled, let baseline = pager.baseline, self.scope == scope,
              scope == Scope(appState: appState, group: scope.group) else { return }
        let ticket = generation
        validationSequence &+= 1
        let sequence = validationSequence
        func isCurrent() -> Bool {
            ticket == generation && sequence == validationSequence && !Task.isCancelled
                && scope == Scope(appState: appState, group: scope.group)
        }
        do {
            let current = try await scope.version(in: appState)
            guard isCurrent() else { return }
            switch current.changeSince(previous: baseline) {
            case .restartRequired: discard()
            case .additions:
                // The first refreshed page establishes which additions it covers.
                // Later pages may take several taps to reconnect to the retained
                // gallery. Keep any newer arrivals available for the next refresh.
                if (!isReconnectingPages || pager.cursor != nil),
                   current.changeSince(previous: refresh?.version ?? additionsVersion ?? baseline) == .additions {
                    collection = .additions
                } else if validationFailed { collection = .current }
            case .unchanged: collection = .current
            }
        } catch {
            if isCurrent() {
                resumeItemID = selectedItemID
                collection = .unavailable
            }
        }
    }
}
