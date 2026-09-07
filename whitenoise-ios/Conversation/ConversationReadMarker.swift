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
    private var readMarkTask: Task<Void, Never>?
    private var readMarkTaskID: UUID?

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

    /// The accepted watermark position, or nil when the candidate is ineligible
    /// (not a kind-9 chat message, deleted, outside the loaded window) or is not
    /// strictly newer than both the pending and the already-flushed watermark.
    nonisolated static func nextWatermarkIndex(
        candidateIndex: Int?,
        pendingIndex: Int?,
        flushedIndex: Int?,
        kind: UInt64,
        isDeleted: Bool
    ) -> Int? {
        guard !isDeleted,
              kind == MessageSemantics.kindChat,
              let candidateIndex
        else { return nil }
        if let pendingIndex, candidateIndex <= pendingIndex { return nil }
        if let flushedIndex, candidateIndex <= flushedIndex { return nil }
        return candidateIndex
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

        do {
            let client = try appState.currentMarmotClient()
            let results = await client.markTimelineMessagesRead(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                messageIdHexes: [messageIdHex]
            )
            let latestRow = results.compactMap(\.row).last
            if let latestRow {
                onChatListRowUpdated?(latestRow)
            }
            if results.contains(where: \.succeeded) {
                flushedWatermarkMessageIdHex = messageIdHex
                await appState.notifications.reconcileDeliveredNotificationsAfterRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    readMessageIdHexes: [messageIdHex],
                    conversationStillHasUnread: latestRow?.hasUnread
                )
            }
        } catch {
            // Leave the flushed watermark where it was so a later frame retries.
        }

        return pendingWatermarkMessageIdHex != nil && appState.activeAccountRef == accountRef
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
    }
}
