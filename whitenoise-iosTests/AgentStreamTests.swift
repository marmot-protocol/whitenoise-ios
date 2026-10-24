import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct AgentStreamTests {

    @Test func streamIdIsDecodedFromStartTags() {
        let streamId = hex("ab")
        let start = ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId.uppercased()]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
                MessageTagFfi(values: [MessageSemantics.streamBrokerTag, AppState.agentTextStreamQuicBrokerCandidate]),
            ],
            recordedAt: 1
        )

        #expect(ConversationViewModel.agentStreamId(from: start) == streamId)
    }

    @Test func malformedStreamStartsAreIgnored() {
        let invalidId = ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, "abcd"]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ],
            recordedAt: 1
        )
        let audioProfile = ReceivedMessageFfi(
            messageIdHex: hex("dd"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: ["stream-type", "audio"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ],
            recordedAt: 1
        )
        let missingRoute = ReceivedMessageFfi(
            messageIdHex: hex("ee"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
            ],
            recordedAt: 1
        )
        let websocketProfile = ReceivedMessageFfi(
            messageIdHex: hex("ff"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "websocket"]),
            ],
            recordedAt: 1
        )

        #expect(ConversationViewModel.agentStreamId(from: invalidId) == nil)
        #expect(ConversationViewModel.agentStreamId(from: audioProfile) == nil)
        #expect(ConversationViewModel.agentStreamId(from: missingRoute) == nil)
        #expect(ConversationViewModel.agentStreamId(from: websocketProfile) == nil)
    }

    @Test func agentStreamStartUsesProductionBrokerCandidate() {
        #expect(AppState.agentTextStreamQuicCandidates == ["quic://quic-broker.ipf.dev:4450"])
    }

    @Test func agentStreamStartsAreWatchedOnlyUntilFinalAnchorArrives() {
        let streamId = hex("ab")
        let start = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ]
        )

        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [],
            trigger: .agentStreamStarted
        ) == streamId)
        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [streamId],
            trigger: .agentStreamStarted
        ) == nil)
        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [],
            trigger: nil
        ) == nil)
        #expect(ConversationViewModel.agentStreamStartIdToWatch(
            from: start,
            finalizedStreamIds: [],
            trigger: .snapshotRefresh
        ) == nil)
    }

    @Test func streamPreviewTimestampPrefersStartRecordTime() {
        #expect(ConversationViewModel.streamPreviewTimestamp(startedAt: 42, fallback: 99) == 42)
        #expect(ConversationViewModel.streamPreviewTimestamp(startedAt: 0, fallback: 99) == 99)
        #expect(ConversationViewModel.streamPreviewTimestamp(startedAt: nil, fallback: 99) == 99)
    }

    @MainActor
    @Test func historicalStreamStartsRenderNoBlankBubble() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let start = timelineRecord(
            messageIdHex: hex("cc"),
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: streamStartTags(streamId),
            timelineAt: 1,
            agentTextStreamJson: #"{"stream_id_hex":"\#(streamId)","status":"started"}"#
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [start], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.isEmpty)
    }

    @MainActor
    @Test func finalizedStreamProjectionRemovesSyntheticPreview() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "partial")
        )
        let final = timelineRecord(
            messageIdHex: hex("ef"),
            sender: hex("11"),
            plaintext: "complete",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: [MessageSemantics.streamStartTag, hex("cc")]),
            ],
            timelineAt: 2,
            agentTextStreamJson: #"{"stream_id_hex":"\#(streamId)","status":"finalized","start_event_id":"\#(hex("cc"))"}"#
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [final], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.count == 1)
        #expect(viewModel.timeline.first?.id == "msg:\(hex("ef"))")
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected the finalized timeline message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "complete")
    }

    @MainActor
    @Test func recordFinalizedStreamsSkipsAlreadyScannedRecordsAcrossPages() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let final = timelineRecord(
            messageIdHex: hex("ef"),
            sender: hex("11"),
            plaintext: "complete",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: [MessageSemantics.streamStartTag, hex("cc")]),
            ],
            timelineAt: 2,
            agentTextStreamJson: #"{"stream_id_hex":"\#(streamId)","status":"finalized","start_event_id":"\#(hex("cc"))"}"#
        )
        let page = TimelinePageFfi(messages: [final], hasMoreBefore: false, hasMoreAfter: false)

        // Apply the same window page repeatedly, as heavy pagination would.
        viewModel.applyTimelinePage(page, placement: .window)
        viewModel.applyTimelinePage(page, placement: .window)
        viewModel.applyTimelinePage(page, placement: .window)

        // The record is scanned at most once per distinct message id, and the
        // finalized-stream guard is populated exactly once.
        #expect(viewModel.scannedFinalizedMessageIdCountForTesting == 1)
        #expect(viewModel.finalizedStreamIdCountForTesting == 1)
    }

    @MainActor
    @Test func scannedFinalizedCacheIsBoundedToLoadedWindowButGuardPersists() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let final = timelineRecord(
            messageIdHex: hex("ef"),
            sender: hex("11"),
            plaintext: "complete",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: [MessageSemantics.streamStartTag, hex("cc")]),
            ],
            timelineAt: 2,
            agentTextStreamJson: #"{"stream_id_hex":"\#(streamId)","status":"finalized","start_event_id":"\#(hex("cc"))"}"#
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [final], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.scannedFinalizedMessageIdCountForTesting == 1)
        #expect(viewModel.finalizedStreamIdCountForTesting == 1)

        // A later window scrolls the finalized anchor out of the loaded set.
        let other = timelineRecord(
            messageIdHex: hex("dd"),
            sender: hex("11"),
            plaintext: "later",
            timelineAt: 3
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [other], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )

        // The scan cache is bounded to records still in the window, but the
        // finalized-stream guard is never pruned (re-watch suppression must
        // survive the anchor leaving the window).
        #expect(viewModel.scannedFinalizedMessageIdCountForTesting == 1)
        #expect(viewModel.finalizedStreamIdCountForTesting == 1)
    }

    @MainActor
    @Test func streamChunksRenderIntoOnePreviewBubble() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "Hel")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: "lo")
        )

        #expect(viewModel.timeline.count == 1)
        #expect(viewModel.timeline.first?.id == "msg:stream:\(streamId)")
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext == "Hello")
        #expect(MessagePreview.body(record) == "Hello")
    }

    @MainActor
    @Test func streamStatusAndProgressDoNotChangePreviewText() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .status(seq: 1, status: "thinking")
        )
        #expect(viewModel.timeline.isEmpty)

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: "answer")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .progress(seq: 3, text: "searched 3 sources")
        )

        #expect(viewModel.timeline.count == 1)
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext == "answer")
    }

    @MainActor
    @Test func checkpointRecordReplacesPreviewText() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .record(seq: 2, recordType: 0x04, text: "replacement")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 3, text: " continued")
        )

        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext == "replacement continued")
    }

    @MainActor
    @Test func finishedUpdateKeepsCheckpointPreviewWhenBrokerTextIsDeltaOnly() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "hello")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .record(seq: 2, recordType: 0x04, text: "hello world")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .finished(text: "hello", transcriptHashHex: hex("55"), chunkCount: 2)
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 3, text: " late")
        )

        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a finalized stream message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "hello world")
    }

    private func streamStartTags(_ streamId: String) -> [MessageTagFfi] {
        [
            MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
            MessageTagFfi(values: ["stream-type", "text"]),
            MessageTagFfi(values: ["final-kind", "9"]),
            MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
        ]
    }

    @MainActor
    @Test func streamChunksAreCappedToMessageBodyLimit() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let almostFull = String(repeating: "a", count: ContentSanitizer.maxMessageLength - 1)

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: almostFull)
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: "bcdef")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 3, text: "late")
        )

        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a capped stream preview message")
            return
        }
        #expect(status == .streaming)
        #expect(record.plaintext.count == ContentSanitizer.maxMessageLength)
        #expect(record.plaintext.hasSuffix("ab"))
        #expect(!record.plaintext.contains("c"))
        #expect(!record.plaintext.contains("late"))
        #expect(viewModel.streamTextLengthEntryCountForTesting == 1)
    }

    @MainActor
    @Test func finishedUpdateReplacesPreviewAndIgnoresLateChunks() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .finished(text: "complete", transcriptHashHex: hex("55"), chunkCount: 1)
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 2, text: " late")
        )

        #expect(viewModel.timeline.count == 1)
        guard case .message(let record, let status) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a finalized stream message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "complete")
        #expect(MessagePreview.body(record) == "complete")
        #expect(viewModel.streamTextEntryCountForTesting == 0)
        #expect(viewModel.streamTextLengthEntryCountForTesting == 0)
    }

    @MainActor
    @Test func normalMessageAfterFinishedStreamKeepsFinalizedTranscript() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")
        let sender = hex("11")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: sender,
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: sender,
            update: .finished(text: "complete", transcriptHashHex: hex("55"), chunkCount: 1)
        )

        let nextMessage = timelineRecord(
            messageIdHex: hex("ef"),
            sender: sender,
            plaintext: "next message",
            kind: MessageSemantics.kindChat,
            tags: [],
            timelineAt: 2
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [nextMessage], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let ids = Set(viewModel.timeline.map(\.id))
        #expect(ids.contains("msg:stream:\(streamId)"))
        #expect(ids.contains("msg:\(hex("ef"))"))

        let streamItem = try #require(viewModel.timeline.first { $0.id == "msg:stream:\(streamId)" })
        guard case .message(let record, let status) = streamItem.kind else {
            Issue.record("Expected a finalized stream message")
            return
        }
        #expect(status == .received)
        #expect(record.plaintext == "complete")
    }

    @MainActor
    @Test func emptyFinishedUpdateDoesNotCreateBlankBubble() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .status(seq: 1, status: "thinking")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .progress(seq: 2, text: "tool started")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .finished(text: "", transcriptHashHex: hex("55"), chunkCount: 2)
        )

        #expect(viewModel.timeline.isEmpty)
    }

    @MainActor
    @Test func abortRecordDropsLivePreview() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .record(seq: 2, recordType: 0x05, text: "")
        )

        #expect(viewModel.timeline.isEmpty)
    }

    @MainActor
    @Test func failedUpdateDropsEmptyLivePreview() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "")
        )
        let streamId = hex("ab")

        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .chunk(seq: 1, text: "partial")
        )
        viewModel.applyStreamUpdate(
            streamId: streamId,
            sender: hex("11"),
            update: .failed(message: "broker closed")
        )

        #expect(viewModel.timeline.isEmpty)
    }

    /// Regression for #230: when an agent-stream watch task exits naturally
    /// (the broker returns nil from `next()` without any finished/failed/abort
    /// update), it must clear its own `streamWatchTasks` entry so the admission
    /// guard doesn't treat the stale dead key as "already watching" and lock
    /// out re-subscription. The clear is generation-guarded: the owning task
    /// (matching generation) clears; a stale task whose key was reused by a
    /// later re-watch (mismatched generation) must not tear the re-watch down.
    @Test func streamWatchClearsOwnEntryOnNaturalCompletion() {
        let owning = UUID()
        // Same generation still stored -> the completing task owns the key.
        #expect(ConversationViewModel.shouldClearCompletedStreamWatch(
            storedGeneration: owning,
            taskGeneration: owning
        ))
        // Key was reused by a re-watch (new generation stored) -> the stale
        // task must not clear the live re-watch.
        #expect(!ConversationViewModel.shouldClearCompletedStreamWatch(
            storedGeneration: UUID(),
            taskGeneration: owning
        ))
        // Key already cleared (no stored generation) -> nothing to clear.
        #expect(!ConversationViewModel.shouldClearCompletedStreamWatch(
            storedGeneration: nil,
            taskGeneration: owning
        ))
    }
}
