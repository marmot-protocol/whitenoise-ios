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
    private var pendingAccountRef: String?
    private var flushedWatermark: Watermark?
    /// A persisted watermark seeded from MDK while its message sat outside the
    /// bounded window. Upgraded to `flushedWatermark` once its row enters the
    /// window, or superseded as soon as a newer watermark flushes.
    private var unplacedSeededFlushedMessageIdHex: String?
    private var lastFlushFailureDescription: String?
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
        guard let candidateKey = Self.nextWatermark(
            candidateKey: orderKey(record.messageIdHex),
            pendingKey: pendingWatermark?.orderKey,
            flushedKey: flushedWatermark?.orderKey,
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
        orderKey providedOrderKey: TimelineHistoryOrderKey? = nil
    ) {
        promoteUnplacedSeededFlushedIfPossible()
        guard let messageIdHex, !messageIdHex.isEmpty else { return }
        if let resolvedKey = providedOrderKey ?? orderKey(messageIdHex) {
            let incoming = Watermark(messageIdHex: messageIdHex, orderKey: resolvedKey)
            flushedWatermark = Self.ratchetedFlushedWatermark(current: flushedWatermark, incoming: incoming)
            if unplacedSeededFlushedMessageIdHex == messageIdHex {
                unplacedSeededFlushedMessageIdHex = nil
            }
            if let pending = pendingWatermark, let flushed = flushedWatermark,
               pending.orderKey <= flushed.orderKey {
                pendingWatermark = nil
                pendingAccountRef = nil
                failedFlushAttempts = 0
            }
        } else if flushedWatermark == nil {
            unplacedSeededFlushedMessageIdHex = messageIdHex
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

    private func promoteUnplacedSeededFlushedIfPossible() {
        guard let unplaced = unplacedSeededFlushedMessageIdHex,
              let resolvedKey = orderKey(unplaced)
        else { return }
        flushedWatermark = Self.ratchetedFlushedWatermark(
            current: flushedWatermark,
            incoming: Watermark(messageIdHex: unplaced, orderKey: resolvedKey)
        )
        unplacedSeededFlushedMessageIdHex = nil
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
        guard let appState, let watermark = pendingWatermark else { return false }
        // Drained before the await so a newer candidate arriving mid-flight
        // stays queued for the next pass, and so a failed mark is retried by a
        // later frame rather than silently held.
        pendingWatermark = nil

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
            lastFlushFailureDescription = results.compactMap(\.failureDescription).last
            let latestRow = results.compactMap(\.row).last
            if let latestRow {
                onChatListRowUpdated?(latestRow)
            }
            if results.contains(where: \.succeeded) {
                didMarkRead = true
                flushedWatermark = Self.ratchetedFlushedWatermark(current: flushedWatermark, incoming: watermark)
                unplacedSeededFlushedMessageIdHex = nil
                await appState.notifications.reconcileDeliveredNotificationsAfterRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    readMessageIdHexes: [watermark.messageIdHex],
                    conversationStillHasUnread: latestRow?.hasUnread
                )
            }
        } catch {
            lastFlushFailureDescription = error.localizedDescription
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
        let retryWatermark = Self.retryStateAfterFailedFlush(
            failedWatermark: watermark,
            pendingWatermark: pendingWatermark,
            attempts: nextAttempts,
            maximumAttempts: Self.maximumFailedFlushAttempts
        )
        guard let retryWatermark else {
            if nextAttempts >= Self.maximumFailedFlushAttempts {
                Self.log.error(
                    "Read mark exhausted retries group=\(self.groupIdHex, privacy: .private(mask: .hash)) message=\(watermark.messageIdHex, privacy: .private(mask: .hash)) attempts=\(nextAttempts, privacy: .public) error=\(self.lastFlushFailureDescription ?? "none", privacy: .public)"
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
