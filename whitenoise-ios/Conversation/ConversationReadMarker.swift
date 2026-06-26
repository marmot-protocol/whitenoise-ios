import Foundation
import MarmotKit

/// Owns the conversation's read-marking pipeline: an optimistic "already marked"
/// set, a coalesced pending-flush queue (one debounced Marmot round-trip per
/// burst, #read-mark coalescing), and the bound-window pruning that keeps the
/// marked set from growing without limit. Extracted from `ConversationViewModel`;
/// the live conversation context (account/runtime, the loaded-window message ids,
/// and the chat-list-row callback) is injected so the async flush sees current
/// state, while the marked-set bookkeeping stays self-contained.
@MainActor
final class ConversationReadMarker {
    private static let readMarkCoalescingDelayNanoseconds: UInt64 = 100_000_000

    private let groupIdHex: String
    private let maxMarkedReadMessageIds: Int
    private weak var appState: AppState?
    /// The message ids currently in the loaded timeline window — used to bound
    /// the marked set to what can still be re-displayed. Evaluated lazily so the
    /// async flush prunes against the live window.
    private let loadedMessageIds: () -> Set<String>
    private let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?

    private var markedReadMessageIds: Set<String> = []
    private var pendingReadMessageIds: [String] = []
    private var pendingReadMessageIdSet: Set<String> = []
    private var readMarkTask: Task<Void, Never>?

    init(
        groupIdHex: String,
        maxMarkedReadMessageIds: Int,
        appState: AppState?,
        loadedMessageIds: @escaping () -> Set<String>,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    ) {
        self.groupIdHex = groupIdHex
        self.maxMarkedReadMessageIds = maxMarkedReadMessageIds
        self.appState = appState
        self.loadedMessageIds = loadedMessageIds
        self.onChatListRowUpdated = onChatListRowUpdated
    }

    func markReadIfVisible(_ record: AppMessageRecordFfi, isDeleted: Bool) async {
        guard Self.shouldMarkRead(
            record,
            isDeleted: isDeleted,
            alreadyMarked: markedReadMessageIds.contains(record.messageIdHex)
        ),
            let appState,
            let accountRef = appState.activeAccountRef
        else { return }

        markedReadMessageIds.insert(record.messageIdHex)
        enqueueReadMark(messageIdHex: record.messageIdHex, accountRef: accountRef)
        pruneMarkedReadMessageIds()
    }

    static func shouldMarkRead(_ record: AppMessageRecordFfi, isDeleted: Bool, alreadyMarked: Bool) -> Bool {
        !alreadyMarked
            && !isDeleted
            && !record.messageIdHex.isEmpty
            && record.kind == MessageSemantics.kindChat
    }

    nonisolated static func retainedMarkedReadMessageIds(
        _ current: Set<String>,
        loadedMessageIds: Set<String>,
        pendingMessageIds: Set<String>,
        limit: Int
    ) -> Set<String> {
        let pending = current.intersection(pendingMessageIds)
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return pending }

        let loaded = current.intersection(loadedMessageIds)
        let retainedCandidates = loaded.union(pending)
        guard retainedCandidates.count > boundedLimit else {
            return retainedCandidates
        }

        var retained = pending
        let remainingCapacity = max(0, boundedLimit - retained.count)
        if remainingCapacity > 0 {
            for messageId in loaded.subtracting(retained).prefix(remainingCapacity) {
                retained.insert(messageId)
            }
        }
        return retained
    }

    func pruneMarkedReadMessageIds(force: Bool = false) {
        guard force || markedReadMessageIds.count > maxMarkedReadMessageIds else { return }
        markedReadMessageIds = Self.retainedMarkedReadMessageIds(
            markedReadMessageIds,
            loadedMessageIds: loadedMessageIds(),
            pendingMessageIds: pendingReadMessageIdSet,
            limit: maxMarkedReadMessageIds
        )
    }

    /// On re-receipt of a record the projection may have re-anchored it; drop it
    /// from the marked set (unless still pending flush) so it can be re-marked.
    func forgetMarkIfNotPending(_ messageIdHex: String) {
        if !pendingReadMessageIdSet.contains(messageIdHex) {
            markedReadMessageIds.remove(messageIdHex)
        }
    }

    private func enqueueReadMark(messageIdHex: String, accountRef: String) {
        guard pendingReadMessageIdSet.insert(messageIdHex).inserted else { return }
        pendingReadMessageIds.append(messageIdHex)
        scheduleReadMarkFlush(accountRef: accountRef)
    }

    private func scheduleReadMarkFlush(accountRef: String) {
        guard readMarkTask == nil else { return }
        readMarkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.readMarkCoalescingDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.flushPendingReadMarks(accountRef: accountRef)
        }
    }

    private func flushPendingReadMarks(accountRef: String) async {
        // Keep `readMarkTask` non-nil for the whole round-trip so read marks
        // enqueued during the awaited FFI cannot schedule an overlapping flush.
        // Clearing it (and re-arming any follow-up) only happens at flush exit.
        let messageIds = pendingReadMessageIds
        pendingReadMessageIds = []
        guard !messageIds.isEmpty else {
            pendingReadMessageIdSet = []
            pruneMarkedReadMessageIds(force: true)
            finishFlush(accountRef: accountRef)
            return
        }
        defer {
            pendingReadMessageIdSet.subtract(messageIds)
            pruneMarkedReadMessageIds(force: true)
            finishFlush(accountRef: accountRef)
        }
        guard let appState, appState.canUseRuntimeForForegroundWork else {
            markedReadMessageIds.subtract(messageIds)
            return
        }
        guard appState.activeAccountRef == accountRef else {
            markedReadMessageIds.subtract(messageIds)
            return
        }

        do {
            let client = try appState.currentMarmotClient()
            let results = await client.markTimelineMessagesRead(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                messageIdHexes: messageIds
            )
            for result in results where !result.succeeded {
                markedReadMessageIds.remove(result.messageIdHex)
            }
            if let row = results.compactMap(\.row).last {
                onChatListRowUpdated?(row)
            }
        } catch {
            markedReadMessageIds.subtract(messageIds)
        }
    }

    /// Clears the in-flight task, then re-arms a follow-up flush for any ids
    /// enqueued during the round-trip. Clearing must come first so
    /// `scheduleReadMarkFlush`'s `guard readMarkTask == nil` can pass.
    private func finishFlush(accountRef: String) {
        readMarkTask = nil
        guard !pendingReadMessageIds.isEmpty, appState?.activeAccountRef == accountRef else { return }
        scheduleReadMarkFlush(accountRef: accountRef)
    }

    func cancelPendingReadMarks() {
        readMarkTask?.cancel()
        readMarkTask = nil
        if !pendingReadMessageIdSet.isEmpty {
            markedReadMessageIds.subtract(pendingReadMessageIdSet)
        }
        pendingReadMessageIds = []
        pendingReadMessageIdSet = []
        pruneMarkedReadMessageIds(force: true)
    }

    func clearMarks() {
        markedReadMessageIds.removeAll()
    }

#if DEBUG
    var markedReadMessageIdsForTesting: Set<String> { markedReadMessageIds }

    func insertMarkedReadMessageIdsForTesting(_ messageIds: Set<String>) {
        markedReadMessageIds.formUnion(messageIds)
        pruneMarkedReadMessageIds(force: true)
    }

    func insertPendingReadMessageIdsForTesting(_ messageIds: [String]) {
        for messageId in messageIds {
            guard pendingReadMessageIdSet.insert(messageId).inserted else { continue }
            pendingReadMessageIds.append(messageId)
        }
    }
#endif
}
