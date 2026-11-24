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
                    excluding windowMessages: Set<String>, atLiveTail: Bool = false, preserving selectedID: String? = nil,
                    heldGIF: MessageMediaAttachment? = nil) -> Edges {
        let chronological = newestFirst.reversed().flatMap { byMessage[$0] ?? [] }
        // A held GIF can anchor its own window. Other GIFs still play inline.
        func isGalleryPage(_ slot: TranscriptHistorySlot) -> Bool {
            !windowMessages.contains(slot.target.messageIdHex) && (!slot.attachment.isGIF ||
                (heldGIF?.localTarget == slot.target && heldGIF?.reference == slot.attachment.reference))
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
        if let selectedID, contains(attachmentID: selectedID), !window.contains(where: { $0.id == selectedID }),
           let selected = chronological.firstIndex(where: { $0.attachment.id == selectedID && isGalleryPage($0) }),
           firstOverlap.map({ selected < $0 }) != true, lastOverlap.map({ selected > $0 }) != true {
            // Stop at an intervening window message. Otherwise filtering out the
            // window would put two disconnected parts of history next to each other.
            let start = chronological[..<selected].lastIndex { windowMessages.contains($0.target.messageIdHex) }.map { $0 + 1 } ?? 0
            let end = chronological[(selected + 1)...].firstIndex { windowMessages.contains($0.target.messageIdHex) } ?? chronological.endIndex
            return Edges(older: chronological[start..<end].filter(isGalleryPage), includesWindow: false)
        }
        return Edges(older: firstOverlap.map { chronological[..<$0].filter(isGalleryPage) } ?? [],
                     newer: lastOverlap.map { chronological.suffix(from: $0 + 1).filter(isGalleryPage) } ?? [])
    }
}

/// Synchronous gallery decisions. MDK supplies the page and version comparisons.
struct TranscriptHistoryState {
    private enum Collection { case current, additions, unavailable }
    private struct Refresh {
        var prefix = TranscriptHistoryPages()
        let boundary: AttachmentLocalTargetFfi?
        var version: AttachmentHistoryVersion?
    }
    private enum Selection {
        case window(String)
        case history(String, fallback: String?)

        var id: String {
            switch self {
            case .window(let id), .history(let id, _): id
            }
        }

        var windowID: String? {
            switch self {
            case .window(let id): id
            case .history(_, let fallback): fallback
            }
        }
    }

    private(set) var pages = TranscriptHistoryPages()
    private(set) var pagesRevision = 0
    private(set) var pager = AttachmentHistoryPager()
    private var lastScannedSlot: AttachmentLocalTargetFfi?
    private var refresh: Refresh?
    private var coveredAdditions: AttachmentHistoryVersion?
    private var collection = Collection.current
    private(set) var scannedSlots = 0
    var isReconnectingPages: Bool { refresh != nil }
    var validationFailed: Bool { collection == .unavailable }
    var hasAdditions: Bool { collection == .additions }

    private var selection: Selection?
    var selectedItemID: String? { selection?.id }
    var selectedFromHistory: Bool {
        if case .history = selection { return true }
        return false
    }
    private(set) var hasPaged = false
    private(set) var viewerGeneration = 0
    private(set) var resumeItemID: String?

    mutating func select(_ id: String, inWindow: Bool) {
        hasPaged = true
        setLocation(id, inWindow: inWindow)
    }

    /// The window can move past a displayed photo without any swipe. An
    /// unconfirmed draft that briefly disappears has no retained page yet.
    mutating func updateWindow(for id: String, inWindow: Bool) {
        if inWindow || pages.contains(attachmentID: id) { setLocation(id, inWindow: inWindow) }
    }

    private mutating func setLocation(_ id: String, inWindow: Bool) {
        selection = inWindow ? .window(id) : .history(id, fallback: selection?.windowID)
    }

    mutating func discard(changingScope: Bool = false) {
        let restore = changingScope ? nil : selection?.windowID
        let reset = selectedFromHistory
        let nextViewer = viewerGeneration + (reset ? 1 : 0)
        let nextPages = pagesRevision &+ 1
        let paged = !changingScope && hasPaged
        self = Self()
        selection = restore.map(Selection.window)
        resumeItemID = reset ? restore : nil
        viewerGeneration = nextViewer
        pagesRevision = nextPages
        hasPaged = paged
    }

    mutating func startRefresh() -> Bool {
        guard hasAdditions, refresh == nil else { return false }
        // An exhausted snapshot must be rescanned through exhaustion. Otherwise
        // reconnect at the last original slot, including hidden or rejected ones.
        refresh = Refresh(boundary: pager.canLoadMore ? lastScannedSlot : nil)
        pager = pager.fromHead()
        collection = .current
        scannedSlots = 0
        return true
    }

    private func originalSlot(_ entry: AttachmentEntryFfi) -> AttachmentLocalTargetFfi {
        let index: UInt32 = switch entry.attachment {
        case .accepted(let index, _), .rejected(let index, _): index
        }
        return .init(messageIdHex: entry.messageIdHex, sourceMessageIdHex: entry.sourceMessageIdHex, attachmentIndex: index)
    }

    mutating func accept(_ page: AttachmentPageFfi, next: AttachmentHistoryPager) {
        if refresh != nil && pager.cursor == nil { refresh?.version = page.version }
        lastScannedSlot = page.entries.last.map(originalSlot)
        scannedSlots += page.entries.count
        pagesRevision &+= 1
        pager = next
        guard var pending = refresh else { pages.append(page.entries); return }
        pending.prefix.append(page.entries)
        if !next.canLoadMore || pending.boundary.map({ boundary in page.entries.contains { originalSlot($0) == boundary } }) == true {
            pages = pending.prefix
            coveredAdditions = pending.version
            refresh = nil
        } else {
            pages = pending.prefix.includingRetainedTail(pages)
            refresh = pending
        }
    }

    func additionsBaseline(for page: AttachmentPageFfi) -> AttachmentHistoryVersion {
        if refresh != nil && pager.cursor == nil { return page.version }
        return refresh?.version ?? coveredAdditions ?? pager.baseline ?? page.version
    }

    mutating func observeNewerPage() {
        if !validationFailed { collection = .additions }
    }

    mutating func validationFailedForSelection() {
        resumeItemID = selectedItemID
        collection = .unavailable
    }

    var validationAdditionsBaseline: AttachmentHistoryVersion? { refresh?.version ?? coveredAdditions ?? pager.baseline }

    /// A destructive change also invalidates outstanding reads in the owner.
    mutating func validate(_ change: AttachmentHistoryChangeFfi, hasUncoveredAdditions: Bool) {
        switch change {
        case .restartRequired: discard()
        case .unchanged: collection = .current
        case .additions:
            if (refresh == nil || pager.cursor != nil) && hasUncoveredAdditions { collection = .additions }
            else if validationFailed { collection = .current }
        }
    }
}

@MainActor @Observable
final class TranscriptAttachmentHistory {
    typealias Scope = AttachmentHistoryPager.Scope
    private enum PageRead { case idle, loading, failed }
    private var read = PageRead.idle
    private(set) var state = TranscriptHistoryState()
    private var scope: Scope?
    private var generation = 0
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var validationSequence: UInt64 = 0

    var canLoadMore: Bool { state.pager.canLoadMore }
    var isLoading: Bool { read == .loading }
    var pageFailed: Bool { read == .failed }

    func select(_ id: String, inWindow: Bool) { state.select(id, inWindow: inWindow) }
    func updateWindow(for id: String, inWindow: Bool) { state.updateWindow(for: id, inWindow: inWindow) }

    func begin(_ newScope: Scope?) {
        state.discard(changingScope: scope != newScope)
        scope = newScope
        invalidateReads()
    }

    // The existing runtime event stream also reports changes to rows outside the transcript window.
    func observe(_ update: RuntimeProjectionUpdateFfi) {
        guard let scope,
              update.accountIdHex == scope.accountID, update.update.groupIdHex == scope.group else { return }
        if update.update.messages.contains(where: state.pages.conflicts) || update.update.changes.contains(where: { change in
            switch change {
            case .remove(let id, _): state.pages.contains(messageID: id)
            case .upsert(_, let row): state.pages.conflicts(with: row)
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

    private func invalidateReads() {
        generation &+= 1
        read = .idle
    }

    func interruptPageRead() {
        if isLoading { invalidateReads() }
    }

    private func discard() {
        state.discard()
        invalidateReads()
    }

    func refreshAdditions(scope: Scope, appState: AppState) async {
        guard self.scope == scope, scope == Scope(appState: appState, group: scope.group),
              !isLoading, state.startRefresh() else { return }
        invalidateReads()
        await loadPage(scope: scope, appState: appState)
    }

    /// One page per request. A stale native cursor may restart once at the head.
    func loadPage(scope: Scope, appState: AppState) async {
        guard !Task.isCancelled, canLoadMore, !isLoading, self.scope == scope else { return }
        var ticket = generation
        var startingRevision = revision
        read = .loading
        defer { if ticket == generation, isLoading { read = .idle } }
        do {
            let (page, next) = try await state.pager.readNext(in: scope, using: appState,
                isCurrent: { ticket == self.generation }, onRestart: {
                    self.discard()
                    ticket = self.generation
                    startingRevision = self.revision
                    self.read = .loading
                })
            guard ticket == generation, (try? scope.currentClient(in: appState)) != nil else { return }
            if revision != startingRevision {
                let checkedRevision = revision
                let current = try await scope.version(in: appState)
                guard ticket == generation else { return }
                if current.changeSince(previous: state.pager.baseline ?? page.version) == .restartRequired {
                    discard()
                    read = .failed
                    return
                }
                guard checkedRevision == revision else { read = .failed; return }
                if current.changeSince(previous: state.additionsBaseline(for: page)) == .additions { state.observeNewerPage() }
            }
            state.accept(page, next: next)
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
        if let loaded = state.pager.baseline { baseline = loaded }
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
        guard !Task.isCancelled, let baseline = state.pager.baseline, self.scope == scope,
              scope == Scope(appState: appState, group: scope.group) else { return }
        let ticket = generation
        let startingRevision = revision
        validationSequence &+= 1
        let sequence = validationSequence
        func isCurrent() -> Bool {
            ticket == generation && startingRevision == revision && sequence == validationSequence && !Task.isCancelled
                && scope == Scope(appState: appState, group: scope.group)
        }
        do {
            let current = try await scope.version(in: appState)
            guard isCurrent() else { return }
            let change = current.changeSince(previous: baseline)
            let additions = state.validationAdditionsBaseline.map { current.changeSince(previous: $0) == .additions } ?? false
            state.validate(change, hasUncoveredAdditions: additions)
            if change == .restartRequired { invalidateReads() }
        } catch {
            if isCurrent() { state.validationFailedForSelection() }
        }
    }
}
