import Foundation
import OSLog
import MarmotKit

/// Owns the conversation's read watermark. Marmot's read marker is one moving
/// pointer per conversation — marking message *N* read clears every earlier
/// unread message — so this tracks a single high-water candidate and issues one
/// coalesced Marmot round-trip per burst (#read-mark coalescing) instead of one
/// call per visible row. Monotonicity is enforced with MDK's canonical
/// `TimelineHistoryOrderKey` so evicting the flushed message from the bounded
/// timeline window can never reset the floor and regress the watermark.
@MainActor
final class ConversationReadMarker {
    struct Watermark: Equatable, Sendable {
        let messageIdHex: String
        let orderKey: TimelineHistoryOrderKey
    }

    private struct UnplacedSavedMarker: Equatable {
        let messageIdHex: String
        let unreadCount: UInt64?
        let firstUnreadMessageIdHex: String?
        let hasMoreAfter: Bool
    }

    enum PendingFlushDecision: Equatable {
        case stop
        case retryWhenRuntimeReturns
        case flush
    }

    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "Performance"
    )

    private static let log = Logger(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "read-state"
    )

    static let readMarkCoalescingDelay: Duration = .milliseconds(100)

    /// Marmot has no durable row to mark for a short window after a send, so
    /// the first mark can be rejected with no later frame to re-trigger it.
    /// Bounded because the read marker is best-effort and must not spin.
    static let maximumFailedFlushAttempts = 5

    typealias MarkReadHandler = @MainActor (AppState, String, String, [String]) async throws -> [TimelineReadMarkResult]

    static let defaultMarkRead: MarkReadHandler = { appState, accountRef, groupIdHex, messageIdHexes in
        let client = try appState.currentMarmotClient()
        return await client.markTimelineMessagesRead(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            messageIdHexes: messageIdHexes
        )
    }

    private let groupIdHex: String
    private weak var appState: AppState?
    /// Canonical order key of a message id currently in the loaded timeline window.
    /// Watermarks store their resolved order key directly so window eviction never
    /// drops the monotonic floor.
    private let orderKey: (String) -> TimelineHistoryOrderKey?
    private let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let markRead: MarkReadHandler

    private var pendingWatermark: Watermark?
    private var inFlightFlush: (taskID: UUID, watermark: Watermark)?
    private var pendingAccountRef: String?
    private var flushedWatermark: Watermark?
    /// Tracks an unresolved optimistic own send that succeeded while still
    /// lacking a durable epoch so we avoid re-sending the exact same id without
    /// letting it block durable inbound replies.
    private var lastFlushedOptimisticMessageIdHex: String?
    /// A persisted watermark reported by MDK whose message sits outside the
    /// loaded timeline window (for example after another linked device read
    /// ahead, or when opening directly into an older historical page). Retained
    /// alongside any earlier `flushedWatermark` until it enters the window or
    /// an authoritative unread boundary allows a newer live-tail row to flush.
    private var unplacedSavedMarker: UnplacedSavedMarker?
    private var lastFlushFailureCategory: String?
    private var readMarkTask: Task<Void, Never>?
    private var readMarkTaskID: UUID?
    private var failedFlushAttempts = 0

    init(
        groupIdHex: String,
        appState: AppState?,
        orderKey: @escaping (String) -> TimelineHistoryOrderKey?,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        markRead: @escaping MarkReadHandler = ConversationReadMarker.defaultMarkRead
    ) {
        self.groupIdHex = groupIdHex
        self.appState = appState
        self.orderKey = orderKey
        self.onChatListRowUpdated = onChatListRowUpdated
        self.sleep = sleep
        self.markRead = markRead
    }

    func advanceWatermark(to record: AppMessageRecordFfi, isDeleted: Bool) {
        promoteUnplacedSavedMarkerIfPossible()
        guard let appState,
              let accountRef = appState.activeAccountRef
        else { return }
        guard let candidateOrderKey = orderKey(record.messageIdHex) else { return }
        if candidateOrderKey.isUnresolvedOptimistic,
           lastFlushedOptimisticMessageIdHex == record.messageIdHex {
            return
        }
        guard allowsCandidateAgainstUnplacedSavedMarker(candidateOrderKey) else { return }
        let effectiveFlushedKey = maxDurableKey(
            flushedWatermark.map(resolvedOrderKey(for:)),
            inFlightFlush.map { resolvedOrderKey(for: $0.watermark) }
        )
        guard let candidateKey = Self.nextWatermark(
            candidateKey: candidateOrderKey,
            pendingKey: pendingWatermark.map(resolvedOrderKey(for:)),
            flushedKey: effectiveFlushedKey,
            kind: record.kind,
            tags: record.tags,
            isDeleted: isDeleted
        ) else { return }

        pendingWatermark = Watermark(messageIdHex: record.messageIdHex, orderKey: candidateKey)
        pendingAccountRef = accountRef
        failedFlushAttempts = 0
        if appState.canUseRuntimeForForegroundWork {
            scheduleReadMarkFlush(accountRef: accountRef)
        }
    }

    /// Mirrors the watermark Marmot persisted for this conversation, so a scroll
    /// back through history can't mark an older message and resurrect unread rows,
    /// and a linked device advancing the watermark ratchets this session's floor
    /// forward monotonically. Never lowers a watermark this session already moved.
    func seedFlushedWatermark(
        messageIdHex: String?,
        orderKey providedOrderKey: TimelineHistoryOrderKey? = nil,
        unreadCount: UInt64? = nil,
        firstUnreadMessageIdHex: String? = nil,
        hasMoreAfter: Bool = false
    ) {
        promoteUnplacedSavedMarkerIfPossible()
        guard let messageIdHex, !messageIdHex.isEmpty else { return }
        if let resolvedKey = providedOrderKey ?? orderKey(messageIdHex),
           !resolvedKey.isUnresolvedOptimistic {
            let incoming = Watermark(messageIdHex: messageIdHex, orderKey: resolvedKey)
            flushedWatermark = Self.ratchetedFlushedWatermark(
                current: refreshedFlushedWatermark(),
                incoming: incoming
            )
            unplacedSavedMarker = nil
            pruneSupersededPendingWatermark()
        } else if flushedWatermark?.messageIdHex == messageIdHex {
            unplacedSavedMarker = nil
            pruneSupersededPendingWatermark()
        } else {
            unplacedSavedMarker = UnplacedSavedMarker(
                messageIdHex: messageIdHex,
                unreadCount: unreadCount,
                firstUnreadMessageIdHex: firstUnreadMessageIdHex,
                hasMoreAfter: hasMoreAfter
            )
            pruneSupersededPendingWatermark()
        }
    }

    /// Resumes flushing a parked pending watermark when foreground runtime
    /// availability returns, without polling while suspended.
    func flushIfNeeded() {
        guard pendingWatermark != nil,
              let appState,
              appState.canUseRuntimeForForegroundWork,
              let accountRef = appState.activeAccountRef
        else { return }
        if let pendingAccountRef, pendingAccountRef != accountRef {
            pendingWatermark = nil
            self.pendingAccountRef = nil
            failedFlushAttempts = 0
            return
        }
        pendingAccountRef = accountRef
        scheduleReadMarkFlush(accountRef: accountRef)
    }

    /// Rows that can carry the read watermark: MDK's chat activity (chat,
    /// polls, thread messages) and group-system rows. Reactions, deletes and
    /// edits mutate another row rather than occupying one, and MDK refuses a
    /// kind 1111 without a parent.
    nonisolated static func canAdvanceWatermark(kind: UInt64, tags: [MessageTagFfi]) -> Bool {
        MessageSemantics.isChatActivity(kind: kind, tags: tags) || kind == MessageSemantics.kindGroupSystem
    }

    /// The accepted watermark order key, or nil when the candidate is ineligible
    /// (not a user-visible row kind, deleted, outside the loaded window) or is
    /// not strictly newer than both the pending and the already-flushed
    /// watermark. Durable candidates always take precedence over unresolved
    /// optimistic candidates so a pending own send can never starve or displace
    /// a durable inbound reply.
    nonisolated static func nextWatermark(
        candidateKey: TimelineHistoryOrderKey?,
        pendingKey: TimelineHistoryOrderKey?,
        flushedKey: TimelineHistoryOrderKey?,
        kind: UInt64,
        tags: [MessageTagFfi],
        isDeleted: Bool
    ) -> TimelineHistoryOrderKey? {
        guard !isDeleted,
              canAdvanceWatermark(kind: kind, tags: tags),
              let candidateKey
        else { return nil }
        if let flushedKey, !flushedKey.isUnresolvedOptimistic {
            if !candidateKey.isUnresolvedOptimistic, candidateKey <= flushedKey {
                return nil
            }
        }
        if let pendingKey {
            switch (candidateKey.isUnresolvedOptimistic, pendingKey.isUnresolvedOptimistic) {
            case (false, true):
                // A durable candidate replaces an unresolved optimistic entry
                // rather than being blocked by its temporary rank-2 order key.
                break
            case (true, false):
                // Do not let an unresolved optimistic entry displace a durable
                // pending candidate that MDK can persist immediately.
                return nil
            case (false, false), (true, true):
                if candidateKey <= pendingKey { return nil }
            }
        }
        return candidateKey
    }

    /// Advances the persisted flushed watermark monotonically when an incoming
    /// watermark (e.g. from another linked device) is strictly newer.
    nonisolated static func ratchetedFlushedWatermark(
        current: Watermark?,
        incoming: Watermark?
    ) -> Watermark? {
        guard let incoming else { return current }
        guard let current else { return incoming }
        return incoming.orderKey > current.orderKey ? incoming : current
    }

    /// The candidate to leave queued after Marmot rejected a flush, or nil to
    /// drop it. Retries the same watermark while it is still the newest thing we
    /// know about, defers to a strictly newer candidate that arrived during the
    /// await, and gives up at the attempt cap. Monotonicity is delegated to
    /// `nextWatermark` so there is one rule, not two.
    nonisolated static func retryStateAfterFailedFlush(
        failedWatermark: Watermark,
        pendingWatermark: Watermark?,
        attempts: Int,
        maximumAttempts: Int
    ) -> Watermark? {
        guard attempts < maximumAttempts else { return nil }
        let newerCandidateIsQueued = nextWatermark(
            candidateKey: pendingWatermark?.orderKey,
            pendingKey: failedWatermark.orderKey,
            flushedKey: nil,
            kind: MessageSemantics.kindChat,
            tags: [],
            isDeleted: false
        ) != nil
        return newerCandidateIsQueued ? nil : failedWatermark
    }

    /// The newest eligible record of an unordered set, by canonical history
    /// order key. Callers hand over a whole viewport; only its newest row is
    /// worth a Marmot call.
    nonisolated static func newestWatermarkCandidate(
        in records: [AppMessageRecordFfi],
        isDeleted: (String) -> Bool,
        orderKey: (String) -> TimelineHistoryOrderKey?
    ) -> AppMessageRecordFfi? {
        var newest: (record: AppMessageRecordFfi, key: TimelineHistoryOrderKey)?
        for record in records {
            guard let key = nextWatermark(
                candidateKey: orderKey(record.messageIdHex),
                pendingKey: newest?.key,
                flushedKey: nil,
                kind: record.kind,
                tags: record.tags,
                isDeleted: isDeleted(record.messageIdHex)
            ) else { continue }
            newest = (record, key)
        }
        return newest?.record
    }

    private func resolvedOrderKey(for watermark: Watermark) -> TimelineHistoryOrderKey {
        orderKey(watermark.messageIdHex) ?? watermark.orderKey
    }

    private func refreshedFlushedWatermark() -> Watermark? {
        guard let flushedWatermark else { return nil }
        let liveKey = resolvedOrderKey(for: flushedWatermark)
        guard !liveKey.isUnresolvedOptimistic else { return nil }
        let refreshed = Watermark(messageIdHex: flushedWatermark.messageIdHex, orderKey: liveKey)
        self.flushedWatermark = refreshed
        return refreshed
    }

    private func maxDurableKey(
        _ lhs: TimelineHistoryOrderKey?,
        _ rhs: TimelineHistoryOrderKey?
    ) -> TimelineHistoryOrderKey? {
        let validLhs = lhs.flatMap { $0.isUnresolvedOptimistic ? nil : $0 }
        let validRhs = rhs.flatMap { $0.isUnresolvedOptimistic ? nil : $0 }
        switch (validLhs, validRhs) {
        case (let left?, let right?): return max(left, right)
        case (let left?, nil): return left
        case (nil, let right?): return right
        case (nil, nil): return nil
        }
    }

    private func allowsCandidateAgainstUnplacedSavedMarker(
        _ candidateKey: TimelineHistoryOrderKey
    ) -> Bool {
        promoteUnplacedSavedMarkerIfPossible()
        guard let marker = unplacedSavedMarker else { return true }
        if marker.messageIdHex == flushedWatermark?.messageIdHex {
            unplacedSavedMarker = nil
            return true
        }
        // When MDK's authoritative first-unread row is in the loaded window,
        // canonical comparison against it cleanly separates read and unread
        // rows without comparing timestamps across epochs.
        if let firstUnreadID = marker.firstUnreadMessageIdHex,
           let firstUnreadKey = orderKey(firstUnreadID),
           !firstUnreadKey.isUnresolvedOptimistic {
            if candidateKey.isUnresolvedOptimistic {
                return !marker.hasMoreAfter
            }
            return candidateKey >= firstUnreadKey
        }
        // At the live tail (`!hasMoreAfter`) with an authoritative positive
        // unread count whose `firstUnreadMessageIdHex` sits before the loaded
        // window, every row in this tail slice is strictly unread.
        if !marker.hasMoreAfter,
           let unreadCount = marker.unreadCount,
           unreadCount > 0,
           marker.firstUnreadMessageIdHex != nil {
            return true
        }
        // Otherwise (historical page, zero unread, or unknown off-window marker
        // placement) fail closed rather than regressing a newer saved marker.
        return false
    }

    private func pruneSupersededPendingWatermark() {
        guard let pending = pendingWatermark else { return }
        let pendingKey = resolvedOrderKey(for: pending)
        if !allowsCandidateAgainstUnplacedSavedMarker(pendingKey) {
            pendingWatermark = nil
            pendingAccountRef = nil
            failedFlushAttempts = 0
            return
        }
        if let flushed = refreshedFlushedWatermark(),
           !pendingKey.isUnresolvedOptimistic,
           pendingKey <= flushed.orderKey {
            pendingWatermark = nil
            pendingAccountRef = nil
            failedFlushAttempts = 0
        }
    }

    private func promoteUnplacedSavedMarkerIfPossible() {
        guard let marker = unplacedSavedMarker else { return }
        if marker.messageIdHex == flushedWatermark?.messageIdHex {
            unplacedSavedMarker = nil
            return
        }
        guard let resolvedKey = orderKey(marker.messageIdHex),
              !resolvedKey.isUnresolvedOptimistic
        else { return }
        flushedWatermark = Self.ratchetedFlushedWatermark(
            current: refreshedFlushedWatermark(),
            incoming: Watermark(messageIdHex: marker.messageIdHex, orderKey: resolvedKey)
        )
        unplacedSavedMarker = nil
    }

    private func scheduleReadMarkFlush(accountRef: String) {
        guard readMarkTask == nil else { return }
        let taskID = UUID()
        readMarkTaskID = taskID
        let sleep = self.sleep
        readMarkTask = Task { @MainActor [weak self] in
            defer {
                if self?.readMarkTaskID == taskID {
                    self?.readMarkTask = nil
                    self?.readMarkTaskID = nil
                }
            }
            while !Task.isCancelled {
                do {
                    try await sleep(Self.readMarkCoalescingDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard await self?.flushPendingReadMarks(accountRef: accountRef, taskID: taskID) == true else {
                    return
                }
            }
        }
    }

    private func flushPendingReadMarks(accountRef: String, taskID: UUID) async -> Bool {
        guard readMarkTaskID == taskID, !Task.isCancelled else { return false }
        promoteUnplacedSavedMarkerIfPossible()
        pruneSupersededPendingWatermark()
        let appState = appState
        switch Self.pendingFlushDecision(
            hasPendingMessages: pendingWatermark != nil,
            canUseRuntime: appState?.canUseRuntimeForForegroundWork == true,
            activeAccountMatches: appState?.activeAccountRef == accountRef
        ) {
        case .stop:
            pendingWatermark = nil
            pendingAccountRef = nil
            return false
        case .retryWhenRuntimeReturns:
            // Exit the loop instead of polling while backgrounded; the pending
            // watermark stays parked until `flushIfNeeded()` is called when
            // foreground runtime availability returns.
            return false
        case .flush:
            break
        }
        guard let appState, let rawWatermark = pendingWatermark else { return false }
        let watermark = Watermark(
            messageIdHex: rawWatermark.messageIdHex,
            orderKey: resolvedOrderKey(for: rawWatermark)
        )
        // Re-check against both the off-window saved marker and the durable
        // flushed floor right before calling MDK so a stale pending entry can
        // never regress a newer mark.
        guard allowsCandidateAgainstUnplacedSavedMarker(watermark.orderKey) else {
            pendingWatermark = nil
            pendingAccountRef = nil
            failedFlushAttempts = 0
            return false
        }
        if let flushed = refreshedFlushedWatermark(),
           !watermark.orderKey.isUnresolvedOptimistic,
           watermark.orderKey <= flushed.orderKey {
            pendingWatermark = nil
            pendingAccountRef = nil
            failedFlushAttempts = 0
            return false
        }
        let startedRuntimeGeneration = appState.runtimeGeneration
        // Drained before the await so a newer candidate arriving mid-flight
        // stays queued for the next pass, while `inFlightFlush` acts as an
        // admission floor scoped to this `taskID`.
        pendingWatermark = nil
        inFlightFlush = (taskID: taskID, watermark: watermark)
        defer {
            if inFlightFlush?.taskID == taskID {
                inFlightFlush = nil
            }
        }

        let signpost = Self.performanceSignposter.beginInterval("ConversationReadMarker.flushPendingReadMarks")
        defer { Self.performanceSignposter.endInterval("ConversationReadMarker.flushPendingReadMarks", signpost) }

        var didMarkRead = false
        do {
            let results = try await markRead(appState, accountRef, groupIdHex, [watermark.messageIdHex])
            guard readMarkTaskID == taskID,
                  !Task.isCancelled,
                  appState.runtimeGeneration == startedRuntimeGeneration
            else { return false }

            lastFlushFailureCategory = results.compactMap(\.failureCategory).last
            let latestRow = results.compactMap(\.row).last
            if let latestRow {
                onChatListRowUpdated?(latestRow)
            }
            if results.contains(where: \.succeeded) {
                didMarkRead = true
                let settledKey = resolvedOrderKey(for: watermark)
                if settledKey.isUnresolvedOptimistic {
                    // Track the id to avoid re-sending the exact same
                    // unresolved optimistic send without blocking durable rows.
                    lastFlushedOptimisticMessageIdHex = watermark.messageIdHex
                } else {
                    let settled = Watermark(messageIdHex: watermark.messageIdHex, orderKey: settledKey)
                    flushedWatermark = Self.ratchetedFlushedWatermark(
                        current: refreshedFlushedWatermark(),
                        incoming: settled
                    )
                    unplacedSavedMarker = nil
                    lastFlushedOptimisticMessageIdHex = nil
                    pruneSupersededPendingWatermark()
                }
                await appState.notifications.reconcileDeliveredNotificationsAfterRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    readMessageIdHexes: [watermark.messageIdHex],
                    conversationStillHasUnread: latestRow?.hasUnread
                )
                guard readMarkTaskID == taskID,
                      !Task.isCancelled,
                      appState.runtimeGeneration == startedRuntimeGeneration
                else { return false }
            }
        } catch {
            guard readMarkTaskID == taskID,
                  !Task.isCancelled,
                  appState.runtimeGeneration == startedRuntimeGeneration
            else { return false }
            lastFlushFailureCategory = MarmotClient.readMarkFailureCategory(for: error)
            // Handled below: a thrown client lookup and a rejected mark are the
            // same outcome to the caller, and both need the retry.
        }

        if didMarkRead {
            failedFlushAttempts = 0
            if pendingWatermark == nil {
                pendingAccountRef = nil
            }
        } else {
            requeueFailedFlush(watermark: watermark, accountRef: accountRef)
        }

        return pendingWatermark != nil
            && appState.canUseRuntimeForForegroundWork
            && appState.activeAccountRef == accountRef
    }

    /// Marmot rejects a mark for a message it has no durable row for, and
    /// `markTimelineMessagesRead` reports that as an unsuccessful result rather
    /// than a throw. Requeue so the marker's own coalescing pass retries it;
    /// after a send there is no scroll, no visibility edge, and no inbound row
    /// to produce a later frame.
    private func requeueFailedFlush(watermark: Watermark, accountRef: String) {
        let nextAttempts = failedFlushAttempts + 1
        let liveFailed = Watermark(
            messageIdHex: watermark.messageIdHex,
            orderKey: resolvedOrderKey(for: watermark)
        )
        let livePending = pendingWatermark.map {
            Watermark(messageIdHex: $0.messageIdHex, orderKey: resolvedOrderKey(for: $0))
        }
        let retryWatermark = Self.retryStateAfterFailedFlush(
            failedWatermark: liveFailed,
            pendingWatermark: livePending,
            attempts: nextAttempts,
            maximumAttempts: Self.maximumFailedFlushAttempts
        )
        guard let retryWatermark else {
            if nextAttempts >= Self.maximumFailedFlushAttempts {
                Self.log.error(
                    "Read mark exhausted retries group=\(self.groupIdHex, privacy: .private(mask: .hash)) message=\(watermark.messageIdHex, privacy: .private(mask: .hash)) attempts=\(nextAttempts, privacy: .public) category=\(self.lastFlushFailureCategory ?? "unknown", privacy: .public)"
                )
            }
            failedFlushAttempts = 0
            if pendingWatermark == nil {
                pendingAccountRef = nil
            }
            return
        }
        pendingWatermark = retryWatermark
        pendingAccountRef = accountRef
        failedFlushAttempts = nextAttempts
    }

    nonisolated static func pendingFlushDecision(
        hasPendingMessages: Bool,
        canUseRuntime: Bool,
        activeAccountMatches: Bool
    ) -> PendingFlushDecision {
        guard hasPendingMessages, activeAccountMatches else { return .stop }
        return canUseRuntime ? .flush : .retryWhenRuntimeReturns
    }

    /// Cancels any scheduled flush task without dropping the parked watermark,
    /// so a foreground resume can flush it through `flushIfNeeded()`.
    func suspendPendingReadMarks() {
        if let interrupted = inFlightFlush?.watermark {
            let liveInterrupted = Watermark(
                messageIdHex: interrupted.messageIdHex,
                orderKey: resolvedOrderKey(for: interrupted)
            )
            let livePendingKey = pendingWatermark.map(resolvedOrderKey(for:))
            let keepInterrupted = livePendingKey == nil || Self.nextWatermark(
                candidateKey: liveInterrupted.orderKey,
                pendingKey: livePendingKey,
                flushedKey: nil,
                kind: MessageSemantics.kindChat,
                tags: [],
                isDeleted: false
            ) != nil
            if keepInterrupted {
                pendingWatermark = liveInterrupted
            }
        }
        inFlightFlush = nil
        readMarkTask?.cancel()
        readMarkTask = nil
        readMarkTaskID = nil
    }

    func cancelPendingReadMarks() {
        inFlightFlush = nil
        readMarkTask?.cancel()
        readMarkTask = nil
        readMarkTaskID = nil
        pendingWatermark = nil
        pendingAccountRef = nil
        failedFlushAttempts = 0
    }
}
