import Foundation
import OSLog
import MarmotKit

/// Owns the conversation's read watermark. Marmot's read marker is one moving
/// pointer per conversation — marking message *N* read clears every earlier
/// unread message — so this tracks a single high-water candidate and issues one
/// coalesced Marmot round-trip per burst (#read-mark coalescing) instead of one
/// call per visible row. The live conversation context (account/runtime, the
/// loaded-window position of a message id, and the chat-list-row callback) is
/// injected so the async flush sees current state.
@MainActor
final class ConversationReadMarker {
    enum PendingFlushDecision: Equatable {
        case stop
        case retryWhenRuntimeReturns
        case flush
    }

    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "Performance"
    )

    private static let readMarkCoalescingDelay: Duration = .milliseconds(100)

    /// Marmot has no durable row to mark for a short window after a send, so
    /// the first mark can be rejected with no later frame to re-trigger it.
    /// Bounded because the read marker is best-effort and must not spin.
    static let maximumFailedFlushAttempts = 5

    private let groupIdHex: String
    private weak var appState: AppState?
    /// Position of a message id in the loaded timeline window, oldest → newest.
    /// Both watermarks are stored as ids and re-resolved through this at
    /// decision time, so pagination shifting every row's ordinal can never
    /// leave a stale position behind as the monotonic floor.
    private let timelineIndex: (String) -> Int?
    private let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?

    private var pendingWatermarkMessageIdHex: String?
    private var flushedWatermarkMessageIdHex: String?
    private var lastFlushFailureDescription: String?
    private var readMarkTask: Task<Void, Never>?
    private var readMarkTaskID: UUID?
    private var failedFlushAttempts = 0

    init(
        groupIdHex: String,
        appState: AppState?,
        timelineIndex: @escaping (String) -> Int?,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    ) {
        self.groupIdHex = groupIdHex
        self.appState = appState
        self.timelineIndex = timelineIndex
        self.onChatListRowUpdated = onChatListRowUpdated
    }

    func advanceWatermark(to record: AppMessageRecordFfi, isDeleted: Bool) {
        guard let appState,
              let accountRef = appState.activeAccountRef,
              Self.nextWatermarkIndex(
                  candidateIndex: timelineIndex(record.messageIdHex),
                  pendingIndex: pendingWatermarkMessageIdHex.flatMap(timelineIndex),
                  flushedIndex: flushedWatermarkMessageIdHex.flatMap(timelineIndex),
                  kind: record.kind,
                  isDeleted: isDeleted
              ) != nil
        else { return }

        pendingWatermarkMessageIdHex = record.messageIdHex
        failedFlushAttempts = 0
        scheduleReadMarkFlush(accountRef: accountRef)
    }

    /// The watermark Marmot already persisted for this conversation, so a
    /// scroll back through history can't mark an older message and resurrect
    /// unread rows the user has read in an earlier session. Never lowers a
    /// watermark this session already moved.
    func seedFlushedWatermark(messageIdHex: String?) {
        guard let messageIdHex,
              !messageIdHex.isEmpty,
              pendingWatermarkMessageIdHex == nil,
              flushedWatermarkMessageIdHex == nil
        else { return }
        flushedWatermarkMessageIdHex = messageIdHex
    }

    /// Kinds that render as their own user-visible timeline row and can
    /// therefore carry the read watermark. Reactions, deletes and edits mutate
    /// another row rather than occupying one, and agent stream events are
    /// developer-mode only.
    nonisolated static func canAdvanceWatermark(kind: UInt64) -> Bool {
        kind == MessageSemantics.kindChat || kind == MessageSemantics.kindGroupSystem
    }

    /// The accepted watermark position, or nil when the candidate is ineligible
    /// (not a user-visible row kind, deleted, outside the loaded window) or is
    /// not strictly newer than both the pending and the already-flushed
    /// watermark.
    nonisolated static func nextWatermarkIndex(
        candidateIndex: Int?,
        pendingIndex: Int?,
        flushedIndex: Int?,
        kind: UInt64,
        isDeleted: Bool
    ) -> Int? {
        guard !isDeleted,
              canAdvanceWatermark(kind: kind),
              let candidateIndex
        else { return nil }
        if let pendingIndex, candidateIndex <= pendingIndex { return nil }
        if let flushedIndex, candidateIndex <= flushedIndex { return nil }
        return candidateIndex
    }

    /// The candidate to leave queued after Marmot rejected a flush, or nil to
    /// drop it. Retries the same id while it is still the newest thing we know
    /// about, defers to a strictly newer candidate that arrived during the
    /// await, and gives up at the attempt cap. Monotonicity is delegated to
    /// `nextWatermarkIndex` so there is one rule, not two.
    nonisolated static func retryStateAfterFailedFlush(
        failedMessageIdHex: String,
        failedIndex: Int?,
        pendingIndex: Int?,
        attempts: Int,
        maximumAttempts: Int
    ) -> String? {
        guard attempts < maximumAttempts else { return nil }
        let newerCandidateIsQueued = nextWatermarkIndex(
            candidateIndex: pendingIndex,
            pendingIndex: failedIndex,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) != nil
        return newerCandidateIsQueued ? nil : failedMessageIdHex
    }

    /// The newest eligible record of an unordered set, by loaded-window
    /// position. Callers hand over a whole viewport; only its newest row is
    /// worth a Marmot call.
    nonisolated static func newestWatermarkCandidate(
        in records: [AppMessageRecordFfi],
        isDeleted: (String) -> Bool,
        timelineIndex: (String) -> Int?
    ) -> AppMessageRecordFfi? {
        var newest: (record: AppMessageRecordFfi, index: Int)?
        for record in records {
            guard let index = nextWatermarkIndex(
                candidateIndex: timelineIndex(record.messageIdHex),
                pendingIndex: newest?.index,
                flushedIndex: nil,
                kind: record.kind,
                isDeleted: isDeleted(record.messageIdHex)
            ) else { continue }
            newest = (record, index)
        }
        return newest?.record
    }

    private func scheduleReadMarkFlush(accountRef: String) {
        guard readMarkTask == nil else { return }
        let taskID = UUID()
        readMarkTaskID = taskID
        readMarkTask = Task { @MainActor [weak self] in
            defer {
                if self?.readMarkTaskID == taskID {
                    self?.readMarkTask = nil
                    self?.readMarkTaskID = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.readMarkCoalescingDelay)
                guard !Task.isCancelled else { return }
                guard await self?.flushPendingReadMarks(accountRef: accountRef) == true else { return }
            }
        }
    }

    private func flushPendingReadMarks(accountRef: String) async -> Bool {
        let appState = appState
        switch Self.pendingFlushDecision(
            hasPendingMessages: pendingWatermarkMessageIdHex != nil,
            canUseRuntime: appState?.canUseRuntimeForForegroundWork == true,
            activeAccountMatches: appState?.activeAccountRef == accountRef
        ) {
        case .stop:
            pendingWatermarkMessageIdHex = nil
            return false
        case .retryWhenRuntimeReturns:
            // Keep the task and candidate alive while the app is backgrounded.
            // The task resumes its coalesced retry loop when the runtime is
            // available again, even if the viewport never emits another frame.
            return true
        case .flush:
            break
        }
        guard let appState, let messageIdHex = pendingWatermarkMessageIdHex else { return false }
        // Drained before the await so a newer candidate arriving mid-flight
        // stays queued for the next pass, and so a failed mark is retried by a
        // later frame rather than silently held.
        pendingWatermarkMessageIdHex = nil

        let signpost = Self.performanceSignposter.beginInterval("ConversationReadMarker.flushPendingReadMarks")
        defer { Self.performanceSignposter.endInterval("ConversationReadMarker.flushPendingReadMarks", signpost) }

        var didMarkRead = false
        do {
            let client = try appState.currentMarmotClient()
            let results = await client.markTimelineMessagesRead(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                messageIdHexes: [messageIdHex]
            )
            lastFlushFailureDescription = results.compactMap(\.failureDescription).last
            let latestRow = results.compactMap(\.row).last
            if let latestRow {
                onChatListRowUpdated?(latestRow)
            }
            if results.contains(where: \.succeeded) {
                didMarkRead = true
                flushedWatermarkMessageIdHex = messageIdHex
                await appState.notifications.reconcileDeliveredNotificationsAfterRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    readMessageIdHexes: [messageIdHex],
                    conversationStillHasUnread: latestRow?.hasUnread
                )
            }
        } catch {
            // Handled below: a thrown client lookup and a rejected mark are the
            // same outcome to the caller, and both need the retry.
        }

        if didMarkRead {
            failedFlushAttempts = 0
        } else {
            requeueFailedFlush(messageIdHex: messageIdHex)
        }

        return pendingWatermarkMessageIdHex != nil && appState.activeAccountRef == accountRef
    }

    /// Marmot rejects a mark for a message it has no durable row for, and
    /// `markTimelineMessagesRead` reports that as an unsuccessful result rather
    /// than a throw. Requeue so the marker's own coalescing pass retries it;
    /// after a send there is no scroll, no visibility edge, and no inbound row
    /// to produce a later frame.
    private func requeueFailedFlush(messageIdHex: String) {
        let nextAttempts = failedFlushAttempts + 1
        let retryMessageIdHex = Self.retryStateAfterFailedFlush(
            failedMessageIdHex: messageIdHex,
            failedIndex: timelineIndex(messageIdHex),
            pendingIndex: pendingWatermarkMessageIdHex.flatMap(timelineIndex),
            attempts: nextAttempts,
            maximumAttempts: Self.maximumFailedFlushAttempts
        )
        if Self.shouldSurfaceExhaustedFailure(
            retryMessageIdHex: retryMessageIdHex,
            attempts: nextAttempts,
            maximumAttempts: Self.maximumFailedFlushAttempts
        ) {
            presentExhaustedFailureBanner(messageIdHex: messageIdHex)
        }
        guard let retryMessageIdHex else {
            failedFlushAttempts = 0
            return
        }
        pendingWatermarkMessageIdHex = retryMessageIdHex
        failedFlushAttempts = nextAttempts
    }

    /// Whether a failed flush has run out of retries, as opposed to standing
    /// aside for a newer candidate. Only an exhausted candidate is worth
    /// telling the user about; the retry path resolves itself.
    nonisolated static func shouldSurfaceExhaustedFailure(
        retryMessageIdHex: String?,
        attempts: Int,
        maximumAttempts: Int
    ) -> Bool {
        retryMessageIdHex == nil && attempts >= maximumAttempts
    }

    // TEMPORARY diagnostic surface: remove once kind-1210 read marking is
    // confirmed working against MDK.
    private func presentExhaustedFailureBanner(messageIdHex: String) {
        let diagnostic = [
            "message=\(messageIdHex)",
            "group=\(groupIdHex)",
            lastFlushFailureDescription.map { "error=\($0)" } ?? "error=none"
        ].joined(separator: "\n")
        appState?.present(.error(
            "Couldn't mark as read",
            message: "Marmot rejected the read marker.",
            diagnostic: diagnostic
        ))
    }

    nonisolated static func pendingFlushDecision(
        hasPendingMessages: Bool,
        canUseRuntime: Bool,
        activeAccountMatches: Bool
    ) -> PendingFlushDecision {
        guard hasPendingMessages, activeAccountMatches else { return .stop }
        return canUseRuntime ? .flush : .retryWhenRuntimeReturns
    }

    func cancelPendingReadMarks() {
        readMarkTask?.cancel()
        readMarkTask = nil
        readMarkTaskID = nil
        pendingWatermarkMessageIdHex = nil
        failedFlushAttempts = 0
    }
}
