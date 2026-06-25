import Foundation
import MarmotKit
import os

/// Timeline-row writes the `StreamWatcher` performs, implemented by the
/// conversation view model (which still owns the merged timeline). Keeps the
/// watcher free of the timeline mirror: it produces/removes stream bubble + debug
/// rows through this narrow sink and never touches `messageById`/`timeline`.
@MainActor
protocol StreamWatcherTimelineSink: AnyObject {
    var streamingDebugEnabled: Bool { get }
    @discardableResult func streamUpsertTimelineItem(_ item: TimelineItem) -> Bool
    @discardableResult func streamRemoveTimelineItem(id: String) -> Bool
    func streamTransientItem(id: String) -> TimelineItem?
    func streamSetTransientItem(_ item: TimelineItem)
    @discardableResult func streamRemoveTransientItem(id: String) -> Bool
    @discardableResult func streamAppendDebugRow(_ item: TimelineItem) -> Bool
    func streamNoteProjectionChanged()
}

/// Owns the agent-text-stream (QUIC) watch subsystem for one conversation: the
/// live watch tasks, the accumulated preview text, the finalized-stream cursor,
/// and the synthetic stream/debug timeline rows. Carved out of
/// `ConversationViewModel` (Phase 5b) — the watcher is invoked from the timeline
/// ingest (the view model calls `watchStartIfNeeded`/`dropMatchingStreamPreview`/
/// `resolveFinalizedStream`/`recordFinalizedStreams`) and writes its rows back
/// through `StreamWatcherTimelineSink`, so the timeline mirror stays in the view
/// model while the stream machinery lives here.
@MainActor
final class StreamWatcher {
    weak var sink: StreamWatcherTimelineSink?
    private weak var appState: AppState?
    private let groupIdHex: String

    private var streamWatchTasks: [String: Task<Void, Never>] = [:]
    /// Generation token per stream watch; a naturally-exiting task only clears
    /// its own entry when the stored generation still matches (re-watch guard).
    private var streamWatchGenerations: [String: UUID] = [:]
    private var latestStreamWatchInFlight = false
    private var streamText: [String: String] = [:]
    private var streamTextLengthById: [String: Int] = [:]
    private var streamStartedAtById: [String: UInt64] = [:]
    private var streamSenderById: [String: String] = [:]
    private var streamsWithCheckpointPreview: Set<String> = []
    /// Finalized stream ids. Includes ids resolved live (no anchor record in the
    /// window to re-derive from), so it is intentionally never pruned; bounded by
    /// the conversation's distinct stream count.
    private var finalizedStreamIds: Set<String> = []
    /// Anchor message ids already scanned by `recordFinalizedStreams`; bounded to
    /// the loaded window via `pruneScannedFinalizedMessageIds`.
    private var scannedFinalizedMessageIds: Set<String> = []
    private var streamDebugEventSequence: UInt64 = 0

    private static let streamLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "agent-stream"
    )

    private struct AgentTextStreamProjection: Decodable {
        var streamIdHex: String?
        var status: String?

        enum CodingKeys: String, CodingKey {
            case streamIdHex = "stream_id_hex"
            case status
        }
    }

    private enum AgentTextStreamRecordType {
        static let checkpoint: UInt8 = 0x04
        static let abort: UInt8 = 0x05
        static let finalNotice: UInt8 = 0x06
    }

    init(appState: AppState?, groupIdHex: String) {
        self.appState = appState
        self.groupIdHex = groupIdHex
    }

    private var streamingDebugEnabled: Bool { sink?.streamingDebugEnabled == true }

#if DEBUG
    var streamTextEntryCountForTesting: Int { streamText.count }
    var streamTextLengthEntryCountForTesting: Int { streamTextLengthById.count }
    var scannedFinalizedMessageIdCountForTesting: Int { scannedFinalizedMessageIds.count }
    var finalizedStreamIdCountForTesting: Int { finalizedStreamIds.count }
#endif

    func isFinalized(_ streamId: String) -> Bool {
        finalizedStreamIds.contains(streamId)
    }

    func cancelAll() {
        for task in streamWatchTasks.values { task.cancel() }
        streamWatchTasks.removeAll()
        streamWatchGenerations.removeAll()
    }

    func resetDebugSequence() {
        streamDebugEventSequence = 0
    }

    func forgetScannedFinalized(_ messageIdHex: String) {
        scannedFinalizedMessageIds.remove(messageIdHex)
    }

    // MARK: - Ingest hooks (called from the timeline apply path)

    func watchStartIfNeeded(_ record: AppMessageRecordFfi, trigger: TimelineUpdateTriggerFfi?) {
        guard let streamIdHex = Self.agentStreamStartIdToWatch(
            from: record,
            finalizedStreamIds: finalizedStreamIds,
            trigger: trigger
        ) else { return }
        Task { [weak self] in
            await self?.startWatching(
                sender: record.sender,
                streamIdHex: streamIdHex,
                startedAt: record.recordedAt
            )
        }
    }

    static func agentStreamStartIdToWatch(
        from record: AppMessageRecordFfi,
        finalizedStreamIds: Set<String>,
        trigger: TimelineUpdateTriggerFfi?
    ) -> String? {
        guard trigger == .agentStreamStarted,
              case .agentStreamStart(let start) = MessageSemantics.classify(record),
              let streamIdHex = MessageSemantics.normalizedStreamId(start.streamId),
              !finalizedStreamIds.contains(streamIdHex)
        else { return nil }
        return streamIdHex
    }

    func recordFinalizedStreams(in records: [TimelineMessageRecordFfi]) {
        for record in records {
            // Anchor records are immutable for a given message id, so once a
            // record has been scanned its finalized-stream classification can't
            // change. Skip the JSON decode + classification on later pages.
            let messageId = record.messageIdHex
            if !messageId.isEmpty {
                guard scannedFinalizedMessageIds.insert(messageId).inserted else { continue }
            }
            let appRecord = ConversationViewModel.appMessageRecord(from: record)
            if let streamId = Self.finalizedStreamId(from: record, appRecord: appRecord) {
                finalizedStreamIds.insert(streamId)
            }
        }
    }

    /// Bound `scannedFinalizedMessageIds` to the records still represented in the
    /// loaded window. Re-scanning an evicted record on a later page is idempotent
    /// (it only re-inserts into `finalizedStreamIds`, which is never pruned), so
    /// dropping its scan marker is safe and keeps the cache bounded.
    func pruneScannedFinalizedMessageIds(keeping loadedMessageIds: Set<String>) {
        guard !scannedFinalizedMessageIds.isEmpty else { return }
        scannedFinalizedMessageIds.formIntersection(loadedMessageIds)
    }

    static func finalizedStreamId(
        from record: TimelineMessageRecordFfi,
        appRecord: AppMessageRecordFfi
    ) -> String? {
        if let projection = agentTextStreamProjection(from: record),
           projection.status == "finalized",
           let streamId = MessageSemantics.normalizedStreamId(projection.streamIdHex) {
            return streamId
        }
        if case .streamFinal(let streamId) = MessageSemantics.classify(appRecord) {
            return streamId
        }
        return nil
    }

    private static func agentTextStreamProjection(from record: TimelineMessageRecordFfi) -> AgentTextStreamProjection? {
        guard let json = record.agentTextStreamJson,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(AgentTextStreamProjection.self, from: data)
    }

    func dropMatchingStreamPreviewIfNeeded(
        for record: AppMessageRecordFfi,
        semantics: MessageSemantics.Kind,
        trigger: TimelineUpdateTriggerFfi?
    ) {
        guard trigger != nil,
              record.direction == "received"
        else { return }
        switch semantics {
        case .chat, .reply, .media:
            let streamIds = streamSenderById
                .filter { $0.value == record.sender }
                .map(\.key)
            for streamId in streamIds {
                endStream(streamId: streamId)
            }
        case .streamFinal, .reaction, .delete, .agentStreamStart, .agentActivity, .agentOperation, .groupSystem, .unknown:
            return
        }
    }

    // MARK: - Watch lifecycle

    func startWatching(sender: String, streamIdHex: String?, startedAt: UInt64? = nil) async {
        guard let appState,
              appState.canUseRuntimeForForegroundWork,
              let accountRef = appState.activeAccountRef
        else { return }
        guard AgentStreamWatchAdmission.canStart(
            streamIdHex: streamIdHex,
            activeStreamIds: Set(streamWatchTasks.keys),
            latestStreamWatchInFlight: latestStreamWatchInFlight
        ) else { return }
        if streamIdHex == nil { latestStreamWatchInFlight = true }
        defer { if streamIdHex == nil { latestStreamWatchInFlight = false } }
        do {
            let client = try appState.currentMarmotClient()
            let insecureLocal = AgentStreamSecurity.insecureLocalEnabled(
                developerMode: appState.developerMode
            )
            let subscription = try await client.watchAgentTextStream(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                streamIdHex: streamIdHex,
                serverCertDer: nil,
                // Release builds always pass false here regardless of the
                // developer-mode toggle, so a Settings switch can't disable
                // TLS verification in production. See AgentStreamSecurity.
                insecureLocal: insecureLocal
            )
            let streamId = subscription.streamIdHex()
            if streamWatchTasks[streamId] != nil { return }
            if finalizedStreamIds.contains(streamId) { return }
            if let startedAt, startedAt > 0 {
                streamStartedAtById[streamId] = startedAt
            }
            resetStreamPreviewText(streamId: streamId)
            streamSenderById[streamId] = sender
            Self.streamLog.info("watch opened: streamId=\(streamId, privacy: .public) developerMode=\(appState.developerMode, privacy: .public); waiting for text preview")
            let generation = UUID()
            let task = Task { [weak self] in
                while !Task.isCancelled, let update = await subscription.next() {
                    self?.applyStreamUpdate(streamId: streamId, sender: sender, update: update)
                }
                // The broker can close a stream silently by returning nil from
                // next() without a .finished/.failed/abort update ever flowing
                // through endStream/finalizeStreamBubble/resolveFinalizedStream.
                // Clear our own entry on that natural exit so the admission
                // guard doesn't treat the dead key as "already watching" and
                // lock out re-subscription. Generation-guarded so a re-watch
                // that reused the key isn't torn down by this stale exit.
                self?.clearCompletedStreamWatch(streamId: streamId, generation: generation)
            }
            streamWatchTasks[streamId] = task
            streamWatchGenerations[streamId] = generation
        } catch {
            // No resolvable start payload yet, or the broker is unreachable.
            Self.streamLog.error("watch failed to open: streamId=\(streamIdHex ?? "<latest>", privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func applyStreamUpdate(streamId: String, sender: String, update: AgentStreamUpdateFfi) {
        // The final anchor already supplied the authoritative transcript.
        if finalizedStreamIds.contains(streamId) { return }
        switch update {
        case .chunk(_, let text):
            appendStreamDebugEvent(streamId: streamId, eventKind: "chunk", detail: streamDebugTextSummary(text))
            appendStreamChunk(text, to: streamId)
            upsertStreamBubbleIfNeeded(streamId: streamId, sender: sender, status: .streaming)
        case .status(let seq, let status):
            appendStreamDebugEvent(streamId: streamId, eventKind: "status", detail: "seq=\(seq) \(status)")
        case .progress(let seq, let text):
            appendStreamDebugEvent(streamId: streamId, eventKind: "progress", detail: "seq=\(seq) \(streamDebugTextSummary(text))")
        case .record(_, let recordType, let text):
            appendStreamDebugEvent(
                streamId: streamId,
                eventKind: "record(\(recordType))",
                detail: streamDebugTextSummary(text)
            )
            switch recordType {
            case AgentTextStreamRecordType.checkpoint:
                streamsWithCheckpointPreview.insert(streamId)
                replaceStreamPreviewText(text, to: streamId)
                upsertStreamBubbleIfNeeded(streamId: streamId, sender: sender, status: .streaming)
            case AgentTextStreamRecordType.abort:
                endStream(streamId: streamId)
            case AgentTextStreamRecordType.finalNotice:
                break
            default:
                break
            }
        case .finished(let text, let transcriptHashHex, let chunkCount):
            appendStreamDebugEvent(
                streamId: streamId,
                eventKind: "finished",
                detail: "chunks=\(chunkCount) textLen=\(text.count)B hashLen=\(transcriptHashHex.count)"
            )
            // QUIC stream closed. Promote the preview to a permanent bubble using
            // the streamed transcript; the authoritative MLS Final anchor will
            // overwrite the same row if it arrives afterwards.
            Self.streamLog.info("finished: streamId=\(streamId, privacy: .public) chunkCount=\(chunkCount) textLen=\(text.count)B hashLen=\(transcriptHashHex.count) — promoting preview to permanent bubble")
            finalizeStreamBubble(
                streamId: streamId,
                sender: sender,
                text: finishedPreviewText(streamId: streamId, text: text)
            )
        case .failed(let message):
            appendStreamDebugEvent(streamId: streamId, eventKind: "failed", detail: message)
            let previewLength = streamTextLengthById[streamId] ?? streamText[streamId]?.count ?? 0
            Self.streamLog.error("failed: streamId=\(streamId, privacy: .public) gotText=\(previewLength)B reasonLen=\(message.count, privacy: .public)B — dropping live preview")
            endStream(streamId: streamId)
        }
    }

    private func clearCompletedStreamWatch(streamId: String, generation: UUID) {
        guard ConversationViewModel.shouldClearCompletedStreamWatch(
            storedGeneration: streamWatchGenerations[streamId],
            taskGeneration: generation
        ) else { return }
        streamWatchTasks[streamId] = nil
        streamWatchGenerations[streamId] = nil
    }

    // MARK: - Preview text

    private func appendStreamDebugEvent(streamId: String, eventKind: String, detail: String) {
        guard streamingDebugEnabled else { return }
        streamDebugEventSequence += 1
        let sequence = streamDebugEventSequence
        let now = UInt64(Date().timeIntervalSince1970)
        let item = TimelineItem.streamDebugEvent(
            id: "dbg:stream:\(streamId):\(now):\(String(format: "%010llu", sequence))",
            streamId: streamId,
            eventKind: eventKind,
            detail: detail,
            timestamp: now
        )
        if sink?.streamAppendDebugRow(item) == true {
            sink?.streamNoteProjectionChanged()
        }
    }

    private func streamDebugTextSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(empty)" }
        if trimmed.count <= 120 { return trimmed }
        return "\(trimmed.prefix(120))… (\(trimmed.count) chars)"
    }

    private func appendStreamChunk(_ text: String, to streamId: String) {
        let currentLength = streamTextLengthById[streamId] ?? streamText[streamId]?.count ?? 0
        let remaining = ProfileSanitizer.maxMessageLength - currentLength
        guard remaining > 0 else { return }
        let cappedChunk = text.prefix(remaining)
        guard !cappedChunk.isEmpty else { return }
        var current = streamText[streamId] ?? ""
        current.append(contentsOf: cappedChunk)
        streamText[streamId] = current
        streamTextLengthById[streamId] = currentLength + cappedChunk.count
    }

    private func replaceStreamPreviewText(_ text: String, to streamId: String) {
        let capped = Self.cappedStreamText(text)
        streamText[streamId] = capped.text
        streamTextLengthById[streamId] = capped.length
    }

    private func resetStreamPreviewText(streamId: String) {
        streamText[streamId] = ""
        streamTextLengthById[streamId] = 0
    }

    private func clearStreamPreviewText(streamId: String) {
        streamText[streamId] = nil
        streamTextLengthById[streamId] = nil
    }

    private func hasStreamPreviewText(streamId: String) -> Bool {
        guard let text = streamText[streamId] else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func finishedPreviewText(streamId: String, text: String) -> String {
        guard streamsWithCheckpointPreview.contains(streamId),
              let preview = streamText[streamId],
              !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return text
        }
        return preview
    }

    static func cappedStreamText(_ text: String) -> (text: String, length: Int) {
        let length = text.count
        if length <= ProfileSanitizer.maxMessageLength {
            return (text, length)
        }
        let capped = String(text.prefix(ProfileSanitizer.maxMessageLength))
        return (capped, ProfileSanitizer.maxMessageLength)
    }

    nonisolated static func streamPreviewTimestamp(startedAt: UInt64?, fallback: UInt64) -> UInt64 {
        guard let startedAt, startedAt > 0 else { return fallback }
        return startedAt
    }

    private func streamPreviewTimestamp(for streamId: String) -> UInt64 {
        let now = UInt64(Date().timeIntervalSince1970)
        let timestamp = Self.streamPreviewTimestamp(
            startedAt: streamStartedAtById[streamId],
            fallback: now
        )
        streamStartedAtById[streamId] = timestamp
        return timestamp
    }

    // MARK: - Stream bubble rows

    /// Create or update the synthetic bubble for a live stream (keyed by id).
    private func upsertStreamBubbleIfNeeded(streamId: String, sender: String, status: MessageStatus) {
        guard hasStreamPreviewText(streamId: streamId) else { return }
        upsertStreamBubble(streamId: streamId, sender: sender, status: status)
    }

    private func upsertStreamBubble(streamId: String, sender: String, status: MessageStatus) {
        let rowId = "msg:stream:\(streamId)"
        streamSenderById[streamId] = sender
        let timestamp = streamPreviewTimestamp(for: streamId)
        let itemTimestamp = sink?.streamTransientItem(id: rowId)?.timestamp ?? timestamp
        let record = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "received",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: streamText[streamId] ?? "",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: timestamp,
            receivedAt: timestamp
        )
        let item = TimelineItem(
            id: rowId,
            kind: .message(record: record, status: status),
            timestamp: itemTimestamp
        )
        sink?.streamSetTransientItem(item)
        if sink?.streamUpsertTimelineItem(item) == true {
            sink?.streamNoteProjectionChanged()
        }
    }

    /// Tear down a live preview that produced no usable transcript (the stream
    /// failed). agentnoise falls back to a plain chat reply in that case, which
    /// arrives as a normal message — so drop the preview and mark the stream
    /// finalized so trailing updates can't recreate it.
    private func endStream(streamId: String) {
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
        streamWatchGenerations[streamId] = nil
        clearStreamPreviewText(streamId: streamId)
        streamsWithCheckpointPreview.remove(streamId)
        streamStartedAtById[streamId] = nil
        streamSenderById[streamId] = nil
        if removeStreamBubble(streamId: streamId) {
            sink?.streamNoteProjectionChanged()
        }
    }

    /// Promote the transient live preview into a permanent received bubble
    /// carrying the final transcript. The Final MLS anchor is authoritative; the
    /// QUIC `.finished` transcript is a provisional fill if it lands first. Both
    /// key the same `msg:stream:<id>` row, so whichever arrives later wins.
    private func finalizeStreamBubble(streamId: String, sender: String, text: String) {
        replaceStreamPreviewText(text, to: streamId)
        guard hasStreamPreviewText(streamId: streamId) else {
            endStream(streamId: streamId)
            return
        }
        streamSenderById[streamId] = sender
        upsertStreamBubble(streamId: streamId, sender: sender, status: .received)
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
        streamWatchGenerations[streamId] = nil
        streamsWithCheckpointPreview.remove(streamId)
        streamStartedAtById[streamId] = nil
        streamSenderById[streamId] = nil
        clearStreamPreviewText(streamId: streamId)
    }

    @discardableResult
    func resolveFinalizedStream(streamId: String) -> Bool {
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
        streamWatchGenerations[streamId] = nil
        clearStreamPreviewText(streamId: streamId)
        streamsWithCheckpointPreview.remove(streamId)
        streamStartedAtById[streamId] = nil
        streamSenderById[streamId] = nil
        return removeStreamBubble(streamId: streamId)
    }

    @discardableResult
    private func removeStreamBubble(streamId: String) -> Bool {
        let rowId = "msg:stream:\(streamId)"
        let backingChanged = sink?.streamRemoveTransientItem(id: rowId) == true
        return (sink?.streamRemoveTimelineItem(id: rowId) == true) || backingChanged
    }
}
