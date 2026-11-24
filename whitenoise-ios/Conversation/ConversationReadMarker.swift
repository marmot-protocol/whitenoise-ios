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

    typealias MarkReadHandler = @MainActor (String, String, [String]) async throws -> [TimelineReadMarkResult]

    private let groupIdHex: String
    private weak var appState: AppState?
    /// Canonical order key of a message id currently in the loaded timeline window.
    /// Watermarks store their resolved order key directly so window eviction never
    /// drops the monotonic floor.
    private let orderKey: (String) -> TimelineHistoryOrderKey?
    private let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let markReadHandler: MarkReadHandler?

    private var pendingWatermark: Watermark?
    private var inFlightWatermark: Watermark?
    private var pendingAccountRef: String?
    private var flushedWatermark: Watermark?
    /// A persisted watermark seeded from MDK while its message sat outside the
    /// bounded window (or while an optimistic own send lacked durable epoch
    /// order). Upgraded to `flushedWatermark` once its durable row enters the
    /// window, or superseded once a newer live-tail watermark flushes.
    private var unplacedSeededFlushedMessageIdHex: String?
    private var unplacedSeededFlushedTimelineAt: UInt64?
    private var windowHasMoreAfter = false
    private var lastFlushFailureCategory: String?
    private var readMarkTask: Task<Void, Never>?
    private var readMarkTaskID: UUID?
    private var failedFlushAttempts = 0

    var hasScheduledFlushTask: Bool { readMarkTask != nil }
    var pendingWatermarkMessageIdHex: String? { pendingWatermark?.messageIdHex }
    var flushedWatermarkMessageIdHex: String? {
        flushedWatermark?.messageIdHex ?? unplacedSeededFlushedMessageIdHex
    }

    init(
        groupIdHex: String,
        appState: AppState?,
        orderKey: @escaping (String) -> TimelineHistoryOrderKey?,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        markRead: MarkReadHandler? = nil
    ) {
        self.groupIdHex = groupIdHex
        self.appState = appState
        self.orderKey = orderKey
        self.onChatListRowUpdated = onChatListRowUpdated
        self.sleep = sleep
        self.markReadHandler = markRead
    }

    func advanceWatermark(to record: AppMessageRecordFfi, isDeleted: Bool) {
        promoteUnplacedSeededFlushedIfPossible()
        guard let appState,
              let accountRef = appState.activeAccountRef
        else { return }
        if unplacedSeededFlushedMessageIdHex == record.messageIdHex {
            return
        }
        // When opening directly into an older historical page (`hasMoreAfter`)
        // that excludes MDK's persisted `lastReadMessageIdHex`, or when the
        // row's timestamp is at or behind the unplaced persisted marker, do not
        // admit an older row and regress the read marker.
        guard let candidateOrderKey = orderKey(record.messageIdHex) else { return }
        if unplacedSeededFlushedMessageIdHex != nil, flushedWatermark == nil {
            if windowHasMoreAfter {
                return
            }
            if let seededTimelineAt = unplacedSeededFlushedTimelineAt,
               candidateOrderKey.timelineAt <= seededTimelineAt {
                return
            }
        }
        let effectiveFlushedKey = maxDurableKey(
            flushedWatermark.map(resolvedOrderKey(for:)),
            inFlightWatermark.map(resolvedOrderKey(for:))
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
        timelineAt: UInt64? = nil,
        hasMoreAfter: Bool = false
    ) {
        windowHasMoreAfter = hasMoreAfter
        promoteUnplacedSeededFlushedIfPossible()
        guard let messageIdHex, !messageIdHex.isEmpty else { return }
        if let resolvedKey = providedOrderKey ?? orderKey(messageIdHex),
           !resolvedKey.isUnresolvedOptimistic {
            let incoming = Watermark(messageIdHex: messageIdHex, orderKey: resolvedKey)
            flushedWatermark = Self.ratchetedFlushedWatermark(
                current: refreshedFlushedWatermark(),
                incoming: incoming
            )
            if unplacedSeededFlushedMessageIdHex == messageIdHex {
                unplacedSeededFlushedMessageIdHex = nil
                unplacedSeededFlushedTimelineAt = nil
            }
            pruneSupersededPendingWatermark()
        } else if flushedWatermark == nil {
            unplacedSeededFlushedMessageIdHex = messageIdHex
            if let timelineAt {
                unplacedSeededFlushedTimelineAt = max(unplacedSeededFlushedTimelineAt ?? 0, timelineAt)
            }
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
    /// watermark.
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
        if let pendingKey, candidateKey <= pendingKey { return nil }
        if let flushedKey, candidateKey <= flushedKey { return nil }
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

    private func pruneSupersededPendingWatermark() {
        guard let pending = pendingWatermark,
              let flushed = refreshedFlushedWatermark()
        else { return }
        let pendingKey = resolvedOrderKey(for: pending)
        if !pendingKey.isUnresolvedOptimistic, pendingKey <= flushed.orderKey {
            pendingWatermark = nil
            pendingAccountRef = nil
            failedFlushAttempts = 0
        }
    }

    private func promoteUnplacedSeededFlushedIfPossible() {
        guard let unplaced = unplacedSeededFlushedMessageIdHex,
              let resolvedKey = orderKey(unplaced),
              !resolvedKey.isUnresolvedOptimistic
        else { return }
        flushedWatermark = Self.ratchetedFlushedWatermark(
            current: refreshedFlushedWatermark(),
            incoming: Watermark(messageIdHex: unplaced, orderKey: resolvedKey)
        )
        unplacedSeededFlushedMessageIdHex = nil
        unplacedSeededFlushedTimelineAt = nil
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
                guard await self?.flushPendingReadMarks(accountRef: accountRef) == true else { return }
            }
        }
    }

    private func flushPendingReadMarks(accountRef: String) async -> Bool {
        promoteUnplacedSeededFlushedIfPossible()
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
        // Re-check against the current durable flushed floor right before calling
        // MDK so a stale pending entry can never regress a newer mark.
        if let flushed = refreshedFlushedWatermark(),
           !watermark.orderKey.isUnresolvedOptimistic,
           watermark.orderKey <= flushed.orderKey {
            pendingWatermark = nil
            pendingAccountRef = nil
            failedFlushAttempts = 0
            return false
        }
        // Drained before the await so a newer candidate arriving mid-flight
        // stays queued for the next pass, while `inFlightWatermark` acts as an
        // admission floor so scrolling up mid-flight cannot enqueue an older row.
        pendingWatermark = nil
        inFlightWatermark = watermark
        defer { inFlightWatermark = nil }

        let signpost = Self.performanceSignposter.beginInterval("ConversationReadMarker.flushPendingReadMarks")
        defer { Self.performanceSignposter.endInterval("ConversationReadMarker.flushPendingReadMarks", signpost) }

        var didMarkRead = false
        do {
            let results: [TimelineReadMarkResult]
            if let markReadHandler {
                results = try await markReadHandler(accountRef, groupIdHex, [watermark.messageIdHex])
            } else {
                let client = try appState.currentMarmotClient()
                results = await client.markTimelineMessagesRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    messageIdHexes: [watermark.messageIdHex]
                )
            }
            lastFlushFailureCategory = results.compactMap(\.failureCategory).last
            let latestRow = results.compactMap(\.row).last
            if let latestRow {
                onChatListRowUpdated?(latestRow)
            }
            if results.contains(where: \.succeeded) {
                didMarkRead = true
                let settledKey = resolvedOrderKey(for: watermark)
                if settledKey.isUnresolvedOptimistic {
                    // Never persist a rank-2 optimistic key as the permanent
                    // floor; track the id until its durable epoch resolves so
                    // newer rank-1 inbound replies are never blocked.
                    if flushedWatermark == nil {
                        unplacedSeededFlushedMessageIdHex = watermark.messageIdHex
                    }
                } else {
                    let settled = Watermark(messageIdHex: watermark.messageIdHex, orderKey: settledKey)
                    flushedWatermark = Self.ratchetedFlushedWatermark(
                        current: refreshedFlushedWatermark(),
                        incoming: settled
                    )
                    unplacedSeededFlushedMessageIdHex = nil
                    unplacedSeededFlushedTimelineAt = nil
                    pruneSupersededPendingWatermark()
                }
                await appState.notifications.reconcileDeliveredNotificationsAfterRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    readMessageIdHexes: [watermark.messageIdHex],
                    conversationStillHasUnread: latestRow?.hasUnread
                )
            }
        } catch {
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
        readMarkTask?.cancel()
        readMarkTask = nil
        readMarkTaskID = nil
    }

    func cancelPendingReadMarks() {
        readMarkTask?.cancel()
        readMarkTask = nil
        readMarkTaskID = nil
        pendingWatermark = nil
        pendingAccountRef = nil
        failedFlushAttempts = 0
    }
}
