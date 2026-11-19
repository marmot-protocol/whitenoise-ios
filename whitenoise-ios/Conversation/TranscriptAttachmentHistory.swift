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
    private var chronological: [TranscriptHistorySlot] = []

    mutating func append(_ entries: [AttachmentEntryFfi]) {
        for entry in entries {
            if let slot = TranscriptHistorySlot(entry) { insert(slot) }
        }
        rebuildOrder()
    }

    private mutating func insert(_ slot: TranscriptHistorySlot) {
        guard targets.insert(slot.target).inserted else { return }
        let id = slot.target.messageIdHex
        if byMessage[id] == nil { newestFirst.append(id) }
        byMessage[id, default: []].append(slot)
    }

    var isEmpty: Bool { targets.isEmpty }

    func reaches(_ retained: Self) -> Bool {
        retained.targets.isEmpty || !targets.isDisjoint(with: retained.targets)
    }

    func includingRetainedTail(_ retained: Self) -> Self {
        guard reaches(retained) else { return retained }
        var joined = self
        for id in retained.newestFirst {
            for slot in retained.byMessage[id] ?? [] { joined.insert(slot) }
        }
        joined.rebuildOrder()
        return joined
    }

    private mutating func rebuildOrder() {
        chronological = newestFirst.reversed().flatMap { id in
            (byMessage[id] ?? []).sorted { $0.target.attachmentIndex < $1.target.attachmentIndex }
        }
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

    /// Extend each edge only once the native cursor has reached that exact slot. In particular, a
    /// recent page cannot appear adjacent to an old search result while intervening pages are missing.
    func extensions(around window: [MessageMediaAttachment],
                    excluding windowMessages: Set<String>, atLiveTail: Bool = false) -> (older: [TranscriptHistorySlot], newer: [TranscriptHistorySlot]) {
        // A held GIF can anchor its own window. Other GIFs still play inline.
        func isGalleryPage(_ slot: TranscriptHistorySlot) -> Bool {
            !windowMessages.contains(slot.target.messageIdHex) && !slot.attachment.isGIF
        }
        guard let first = window.first(where: { $0.localTarget != nil }),
              let last = window.last(where: { $0.localTarget != nil }) else {
            // In an MDK-confirmed tail containing only local photos, every native slot
            // outside the window precedes the pending sends. A historical jump has no such guarantee.
            guard atLiveTail, !window.isEmpty else { return ([], []) }
            return (chronological.filter(isGalleryPage), [])
        }
        func matches(_ slot: TranscriptHistorySlot, _ item: MessageMediaAttachment) -> Bool {
            slot.target == item.localTarget && slot.attachment.reference == item.reference
        }
        let older = chronological.firstIndex { matches($0, first) }.map { index in
            chronological[..<index].filter(isGalleryPage)
        } ?? []
        let newer = chronological.lastIndex { matches($0, last) }.map { index in
            chronological.suffix(from: index + 1).filter(isGalleryPage)
        } ?? []
        return (older, newer)
    }
}

@MainActor @Observable
final class TranscriptAttachmentHistory {
    private(set) var pages = TranscriptHistoryPages()
    private(set) var canLoadMore = true
    private(set) var isLoading = false
    private(set) var pageFailed = false
    private(set) var validationFailed = false
    private(set) var hasAdditions = false
    private(set) var scannedSlots = 0
    private(set) var revision: UInt64 = 0
    @ObservationIgnored var hasPaged = false
    var selectedItemID: String?
    @ObservationIgnored var resetViewerOnDiscard = false
    private(set) var viewerGeneration = 0
    private(set) var resumeItemID: String?
    private var scope: Scope?
    private var cursor: AttachmentHistoryCursor?
    private(set) var isReconnectingPages = false
    private var olderContinuation: (cursor: AttachmentHistoryCursor?, canLoadMore: Bool)?
    private var refreshedPrefix: TranscriptHistoryPages?
    private var additionsVersion: AttachmentHistoryVersion?
    private var baseline: AttachmentHistoryVersion?
    private var generation = 0
    @ObservationIgnored private var validationSequence: UInt64 = 0

    struct Scope: Equatable {
        let account: String
        let accountID: String
        let group: String
        let runtimeGeneration: Int
        private let clientID: ObjectIdentifier

        init?(appState: AppState, group: String) {
            guard let account = appState.activeAccountRef, let accountID = appState.activeAccount?.accountIdHex,
                  let client = appState.client, let generation = appState.runtimeEventsGeneration else { return nil }
            self.accountID = accountID
            self.account = account
            self.group = group
            runtimeGeneration = generation
            clientID = ObjectIdentifier(client)
        }
    }

    func begin(_ newScope: Scope?) {
        if scope != newScope {
            hasPaged = false
            selectedItemID = nil
        }
        scope = newScope
        discard()
    }

    // The existing runtime event stream also reports changes to rows outside the transcript window.
    func observe(_ event: MarmotEventFfi) {
        guard let scope, case .projectionUpdated(let update) = event,
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

    func retentionChanged(groups: Set<String>) {
        guard let scope, groups.contains(scope.group) else { return }
        revision &+= 1
    }

    private func discard() {
        if resetViewerOnDiscard {
            viewerGeneration &+= 1
            selectedItemID = nil
        }
        resetViewerOnDiscard = false
        generation &+= 1
        pages = .init()
        resumeItemID = nil
        scannedSlots = 0
        pageFailed = false
        validationFailed = false
        hasAdditions = false
        cursor = nil
        baseline = nil
        refreshedPrefix = nil
        olderContinuation = nil
        isReconnectingPages = false
        additionsVersion = nil
        canLoadMore = true
        isLoading = false
    }

    func refreshAdditions(scope: Scope, appState: AppState) async {
        guard self.scope == scope, scope == Scope(appState: appState, group: scope.group),
              hasAdditions, !isLoading, !validationFailed else { return }
        generation &+= 1
        olderContinuation = (cursor, canLoadMore)
        refreshedPrefix = .init()
        isReconnectingPages = true
        cursor = nil
        canLoadMore = true
        hasAdditions = false
        scannedSlots = 0
        await loadPage(scope: scope, appState: appState)
    }

    /// One page per request. A stale native cursor may restart once at the head.
    func loadPage(scope: Scope, appState: AppState, mayRestart: Bool = true) async {
        guard !Task.isCancelled, canLoadMore, !isLoading, self.scope == scope, scope == Scope(appState: appState, group: scope.group),
              let client = appState.client else { return }
        let ticket = generation
        let startingRevision = revision
        pageFailed = false
        isLoading = true
        defer { if ticket == generation { isLoading = false } }
        do {
            let result = try await client.marmot.attachmentHistoryPage(accountRef: scope.account,
                groupIdHex: scope.group, limit: 100, cursor: cursor)
            guard ticket == generation, !Task.isCancelled, scope == Scope(appState: appState, group: scope.group) else { return }
            let mustRestart: Bool
            switch result {
            case .restartRequired, .cursorMismatch: mustRestart = true
            case .page(let page): mustRestart = baseline.map { page.version.changeSince(previous: $0) == .restartRequired } ?? false
            case .invalidLimit: mustRestart = false
            }
            if mustRestart {
                discard()
                if mayRestart { await loadPage(scope: scope, appState: appState, mayRestart: false) }
                else { pageFailed = true }
                return
            }
            if case .page(let page) = result {
                let firstRefreshPage = refreshedPrefix != nil && cursor == nil
                let additionsBase = firstRefreshPage ? page.version : (additionsVersion ?? baseline ?? page.version)
                // An off-window change can arrive while the first page has no installed baseline.
                if revision != startingRevision {
                    let checkedRevision = revision
                    let current = try await client.marmot.attachmentHistoryVersion(accountRef: scope.account, groupIdHex: scope.group)
                    guard ticket == generation, !Task.isCancelled,
                          scope == Scope(appState: appState, group: scope.group) else { return }
                    let change = current.changeSince(previous: baseline ?? page.version)
                    if change == .restartRequired {
                        discard()
                        pageFailed = true
                        return
                    }
                    guard checkedRevision == revision else { pageFailed = true; return }
                    if current.changeSince(previous: additionsBase) == .additions { hasAdditions = true }
                }
                if baseline == nil { baseline = page.version }
                scannedSlots += page.entries.count
                if firstRefreshPage { additionsVersion = page.version }
                cursor = page.nextCursor
                canLoadMore = page.hasMore && page.nextCursor != nil
                if var prefix = refreshedPrefix {
                    prefix.append(page.entries)
                    if !canLoadMore || prefix.reaches(pages) {
                        if canLoadMore, !pages.isEmpty, let olderContinuation {
                            pages = prefix.includingRetainedTail(pages)
                            cursor = olderContinuation.cursor
                            canLoadMore = olderContinuation.canLoadMore
                        } else {
                            pages = prefix
                        }
                        refreshedPrefix = nil
                        olderContinuation = nil
                        isReconnectingPages = false
                    } else {
                        refreshedPrefix = prefix
                    }
                } else {
                    pages.append(page.entries)
                }
            } else {
                pageFailed = true
            }
        } catch {
            if ticket == generation, !Task.isCancelled { pageFailed = true }
        }
    }

    /// Save and Forward use already prepared bytes. Confirm that the original slot remains
    /// readable, without requesting a download, before releasing those bytes to another view.
    func verifyRetained(_ target: AttachmentLocalTargetFfi, scope: Scope, appState: AppState) async -> Bool {
        guard self.scope == scope, let client = appState.client else { return false }
        let originalBaseline = baseline
        let ticket = generation
        do {
            let assets = try await client.marmot.attachmentLocalAssets(accountRef: scope.account,
                groupIdHex: scope.group, targets: [target])
            guard assets.first?.reference != nil else { return false }
            if let originalBaseline {
                let current = try await client.marmot.attachmentHistoryVersion(accountRef: scope.account, groupIdHex: scope.group)
                guard !Task.isCancelled, ticket == generation else { return false }
                if current.changeSince(previous: originalBaseline) == .restartRequired { discard(); return false }
            }
            return !Task.isCancelled && ticket == generation && scope == Scope(appState: appState, group: scope.group)
        } catch {
            return false
        }
    }

    /// The collection version invalidates removed, expired, or newly hidden entries outside the
    /// current message window. Additions preserve the native pagination baseline.
    func validate(scope: Scope, appState: AppState) async {
        guard !Task.isCancelled, let baseline, self.scope == scope,
              scope == Scope(appState: appState, group: scope.group), let client = appState.client else { return }
        let ticket = generation
        validationSequence &+= 1
        let sequence = validationSequence
        func isCurrent() -> Bool {
            ticket == generation && sequence == validationSequence && !Task.isCancelled
                && scope == Scope(appState: appState, group: scope.group)
        }
        do {
            let current = try await client.marmot.attachmentHistoryVersion(accountRef: scope.account, groupIdHex: scope.group)
            guard isCurrent() else { return }
            switch current.changeSince(previous: baseline) {
            case .restartRequired: discard()
            case .additions:
                // The first refreshed page establishes which additions it covers.
                // Later pages may take several taps to reconnect to the retained
                // gallery. Keep any newer arrivals available for the next refresh.
                if (!isReconnectingPages || cursor != nil),
                   current.changeSince(previous: additionsVersion ?? baseline) == .additions {
                    hasAdditions = true
                }
                validationFailed = false
            case .unchanged: validationFailed = false
            }
        } catch {
            if isCurrent() {
                resumeItemID = selectedItemID
                validationFailed = true
            }
        }
    }
}
