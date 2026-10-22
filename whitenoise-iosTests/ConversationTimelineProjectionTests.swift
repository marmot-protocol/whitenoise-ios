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
struct ConversationTimelineProjectionTests {

    private func durableRetryFixture(
        invalidationStatus: String? = nil,
        catchUp: @escaping @MainActor (MarmotClient) async throws -> Void = { _ in },
        converge: @escaping @MainActor (MarmotClient, String, String) async throws -> SendSummaryFfi,
        sleep: @escaping @MainActor (UInt64) async throws -> Void = { _ in },
        refresh: @escaping @MainActor (ConversationViewModel) async -> Void = { _ in }
    ) throws -> (
        appState: AppState,
        viewModel: ConversationViewModel,
        record: TimelineMessageRecordFfi,
        rowId: String
    ) {
        let groupIdHex = hex("aa")
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "", id: groupIdHex),
            durableRetryOperations: ConversationViewModel.DurableRetryOperations(
                catchUp: catchUp,
                converge: converge,
                sleep: sleep,
                refresh: refresh
            )
        )
        let record = timelineRecord(
            messageIdHex: hex("d1"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20,
            invalidationStatus: invalidationStatus
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )
        return (appState, viewModel, record, "msg:\(record.messageIdHex)")
    }

    private func status(
        of rowId: String,
        in viewModel: ConversationViewModel
    ) -> MessageStatus? {
        viewModel.timeline.compactMap { item -> MessageStatus? in
            guard item.id == rowId, case .message(_, let status) = item.kind else { return nil }
            return status
        }.first
    }

    private func unpublishedRetrySummary() -> SendSummaryFfi {
        SendSummaryFfi(
            published: 0,
            messageIds: [],
            acceptDisposition: .acceptedPending,
            maintenanceDisposition: .ready
        )
    }

    @Test func pendingReadMarksRetryWhenRuntimeReturnsWithoutAnotherViewportUpdate() {
        #expect(
            ConversationReadMarker.pendingFlushDecision(
                hasPendingMessages: true,
                canUseRuntime: false,
                activeAccountMatches: true
            ) == .retryWhenRuntimeReturns
        )
        #expect(
            ConversationReadMarker.pendingFlushDecision(
                hasPendingMessages: true,
                canUseRuntime: true,
                activeAccountMatches: true
            ) == .flush
        )
        #expect(
            ConversationReadMarker.pendingFlushDecision(
                hasPendingMessages: true,
                canUseRuntime: false,
                activeAccountMatches: false
            ) == .stop
        )
    }

    @Test func rejectedReadMarkRequeuesTheSameWatermarkCandidate() {
        // Marmot rejects a mark for a message it has no durable row for yet,
        // which is the window right after a send. Nothing else produces a later
        // frame there, so the candidate has to survive the failed flush.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
        // A just-sent row can still be outside the loaded window's index; the
        // id is what Marmot marks, so retry it anyway.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: nil,
            pendingIndex: nil,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
    }

    @Test func rejectedReadMarkDefersToANewerQueuedCandidate() {
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: 8,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == nil)
        // Same row and an older row are both non-advances, so the failed
        // candidate stays queued rather than regressing the watermark.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: 7,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: 6,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == "aa")
    }

    @Test func rejectedReadMarkStopsRetryingAtItsAttemptCap() {
        let cap = ConversationReadMarker.maximumFailedFlushAttempts
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: cap - 1,
            maximumAttempts: cap
        ) == "aa")
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: cap,
            maximumAttempts: cap
        ) == nil)
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedMessageIdHex: "aa",
            failedIndex: 7,
            pendingIndex: nil,
            attempts: cap + 1,
            maximumAttempts: cap
        ) == nil)
    }

    @Test func readWatermarkAdvancesOnlyForStrictlyNewerCandidates() {
        // Marmot's read marker is one moving pointer, so the guard has to be
        // monotonic: scrolling back up must not regress it.
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 12,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == 12)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 12,
            pendingIndex: nil,
            flushedIndex: 12,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 4,
            pendingIndex: nil,
            flushedIndex: 12,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 13,
            pendingIndex: 12,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == 13)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 11,
            pendingIndex: 12,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
    }

    @Test func readWatermarkRejectsIneligibleCandidates() {
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 3,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindReaction,
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 3,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: true
        ) == nil)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: nil,
            pendingIndex: nil,
            flushedIndex: nil,
            kind: MessageSemantics.kindChat,
            isDeleted: false
        ) == nil)
    }

    @Test func tailRefreshNarrowsAStaleForwardEdge() {
        #expect(ConversationPaginationPolicy.forwardEdgeAfterTailRefresh(
            currentHasMoreAfter: true,
            pageHasMoreAfter: false,
            droppedNewerRecords: false
        ) == false)
        #expect(ConversationPaginationPolicy.forwardEdgeAfterTailRefresh(
            currentHasMoreAfter: true,
            pageHasMoreAfter: false,
            droppedNewerRecords: true
        ) == true)
        #expect(ConversationPaginationPolicy.forwardEdgeAfterTailRefresh(
            currentHasMoreAfter: true,
            pageHasMoreAfter: true,
            droppedNewerRecords: false
        ) == true)
        #expect(ConversationPaginationPolicy.forwardEdgeAfterTailRefresh(
            currentHasMoreAfter: false,
            pageHasMoreAfter: true,
            droppedNewerRecords: false
        ) == true)
    }

    @Test func scrollToBottomControlStaysHiddenWhenAlreadyPinned() {
        #expect(!TimelineBottom.shouldShowScrollToBottomControl(
            userMovedAwayFromBottom: false,
            hasMoreAfter: true,
            isAtBottom: true
        ))
        #expect(TimelineBottom.shouldShowScrollToBottomControl(
            userMovedAwayFromBottom: false,
            hasMoreAfter: true,
            isAtBottom: false
        ))
        #expect(TimelineBottom.shouldShowScrollToBottomControl(
            userMovedAwayFromBottom: true,
            hasMoreAfter: false,
            isAtBottom: true
        ))
        #expect(!TimelineBottom.shouldShowScrollToBottomControl(
            userMovedAwayFromBottom: false,
            hasMoreAfter: false,
            isAtBottom: true
        ))
    }

    @Test func unreadDividerHidesWhenFirstUnreadRowNeedsNoScroll() {
        #expect(TimelineUnreadDivider.shouldSuppressForVisibleFirstUnread(
            firstUnreadRowKey: "msg:aa",
            visibleRowKeys: ["msg:99", "msg:aa"],
            didScrollToUnreadTarget: false
        ))
        #expect(!TimelineUnreadDivider.shouldSuppressForVisibleFirstUnread(
            firstUnreadRowKey: "msg:aa",
            visibleRowKeys: ["msg:99"],
            didScrollToUnreadTarget: false
        ))
        #expect(!TimelineUnreadDivider.shouldSuppressForVisibleFirstUnread(
            firstUnreadRowKey: "msg:aa",
            visibleRowKeys: ["msg:aa"],
            didScrollToUnreadTarget: true
        ))
        #expect(!TimelineUnreadDivider.shouldSuppressForVisibleFirstUnread(
            firstUnreadRowKey: nil,
            visibleRowKeys: ["msg:aa"],
            didScrollToUnreadTarget: false
        ))
    }

    @Test func readWatermarkAdvancesForGroupSystemRows() {
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 5,
            pendingIndex: nil,
            flushedIndex: 4,
            kind: MessageSemantics.kindGroupSystem,
            isDeleted: false
        ) == 5)
        #expect(ConversationReadMarker.nextWatermarkIndex(
            candidateIndex: 5,
            pendingIndex: nil,
            flushedIndex: 4,
            kind: MessageSemantics.kindGroupSystem,
            isDeleted: true
        ) == nil)
    }

    @Test func readWatermarkAcceptsOnlyUserVisibleRowKinds() {
        #expect(ConversationReadMarker.canAdvanceWatermark(kind: MessageSemantics.kindChat))
        #expect(ConversationReadMarker.canAdvanceWatermark(kind: MessageSemantics.kindPoll))
        #expect(ConversationReadMarker.canAdvanceWatermark(kind: MessageSemantics.kindGroupSystem))
        #expect(!ConversationReadMarker.canAdvanceWatermark(kind: MessageSemantics.kindReaction))
        #expect(!ConversationReadMarker.canAdvanceWatermark(kind: MessageSemantics.kindDelete))
        #expect(!ConversationReadMarker.canAdvanceWatermark(kind: MessageSemantics.kindEdit))
        #expect(!ConversationReadMarker.canAdvanceWatermark(kind: MessageSemantics.kindAgentActivity))
    }

    @Test func newestVisibleWatermarkCandidateTakesGroupSystemTail() {
        let readChat = message(id: hex("11"), kind: MessageSemantics.kindChat)
        let memberAdded = message(id: hex("22"), kind: MessageSemantics.kindGroupSystem)
        let memberRemoved = message(id: hex("33"), kind: MessageSemantics.kindGroupSystem)
        let indexes = [hex("11"): 7, hex("22"): 8, hex("33"): 9]

        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [readChat, memberAdded, memberRemoved],
            isDeleted: { _ in false },
            timelineIndex: { indexes[$0] }
        )

        #expect(candidate?.messageIdHex == memberRemoved.messageIdHex)
    }

    @Test func exhaustedReadMarkFailureSurfacesOnceAtTheAttemptCap() {
        let cap = ConversationReadMarker.maximumFailedFlushAttempts
        #expect(ConversationReadMarker.shouldSurfaceExhaustedFailure(
            retryMessageIdHex: nil,
            attempts: cap,
            maximumAttempts: cap
        ))
        #expect(!ConversationReadMarker.shouldSurfaceExhaustedFailure(
            retryMessageIdHex: hex("11"),
            attempts: cap - 1,
            maximumAttempts: cap
        ))
        #expect(!ConversationReadMarker.shouldSurfaceExhaustedFailure(
            retryMessageIdHex: nil,
            attempts: 1,
            maximumAttempts: cap
        ))
    }

    @Test func newestVisibleWatermarkCandidateIgnoresVisibilityOrder() {
        let older = message(id: hex("11"), kind: MessageSemantics.kindChat)
        let newest = message(id: hex("22"), kind: MessageSemantics.kindChat)
        let reactionTail = message(id: hex("33"), kind: MessageSemantics.kindReaction)
        let deletedTail = message(id: hex("44"), kind: MessageSemantics.kindChat)
        let indexes = [hex("11"): 7, hex("22"): 8, hex("33"): 9, hex("44"): 10]

        // Row keys arrive in viewport order, not timeline order, and the tail
        // of the window can be a reaction or a deleted row.
        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [reactionTail, deletedTail, newest, older],
            isDeleted: { $0 == hex("44") },
            timelineIndex: { indexes[$0] }
        )

        #expect(candidate?.messageIdHex == newest.messageIdHex)
    }

    @Test func newestVisibleWatermarkCandidateIsNilWithoutAnEligibleRow() {
        let reaction = message(id: hex("11"), kind: MessageSemantics.kindReaction)
        let outsideWindow = message(id: hex("22"), kind: MessageSemantics.kindChat)

        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [reaction, outsideWindow],
            isDeleted: { _ in false },
            timelineIndex: { $0 == hex("11") ? 1 : nil }
        )

        #expect(candidate?.messageIdHex == nil)
    }

    @Test func liveSubscriptionRetryDelayDoublesUntilCapped() {
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 500_000_000) == 1_000_000_000)
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 4_000_000_000) == 8_000_000_000)
        #expect(ConversationViewModel.nextLiveSubscriptionRetryDelay(after: 8_000_000_000) == 8_000_000_000)
    }

    @Test func startClearsOptimisticOverlaysBeforeRebindingSubscriptions() throws {
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: false,
            canStartLiveWork: true
        ) == .loadLocalSnapshot(startLiveWork: true))
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: false,
            canStartLiveWork: false
        ) == .skipForegroundWork)
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: true,
            canStartLiveWork: false
        ) == .loadLocalSnapshot(startLiveWork: false))
        #expect(ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: true,
            canStartLiveWork: true
        ) == .loadLocalSnapshot(startLiveWork: true))

        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let message = timelineRecord(messageIdHex: hex("44"), timelineAt: 1)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [message], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        viewModel.seedOptimisticStateForTesting(
            deletedMessageIdHex: message.messageIdHex,
            reactionTargetMessageIdHex: message.messageIdHex,
            emoji: "🔥",
            sender: hex("22")
        )
        #expect(viewModel.isDeleted(message.messageIdHex))
        #expect(viewModel.reactions(for: message.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 1, mine: false)
        ])

        viewModel.resetOptimisticStateForTesting()
        #expect(!viewModel.isDeleted(message.messageIdHex))
        #expect(viewModel.reactions(for: message.messageIdHex).isEmpty)
    }

    @Test func timelinePageHydratesReplyPreviewReactionsAndDeletedState() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let parentSender = hex("11")
        let viewModel = ConversationViewModel(appState: appState, group: group(name: ""))
        let parent = timelineRecord(
            messageIdHex: hex("a1"),
            sender: parentSender,
            plaintext: "the parent text",
            timelineAt: 1
        )
        let reply = timelineRecord(
            messageIdHex: hex("b2"),
            sender: hex("22"),
            plaintext: "replying",
            timelineAt: 2,
            replyToMessageIdHex: parent.messageIdHex,
            replyPreview: TimelineReplyPreviewFfi(
                messageIdHex: parent.messageIdHex,
                sender: parent.sender,
                plaintext: parent.plaintext,
                kind: MessageSemantics.kindChat,
                mediaJson: nil,
                media: [],
                agentTextStreamJson: nil,
                deleted: false
            ),
            reactions: TimelineReactionSummaryFfi(
                byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", count: 2, senders: [hex("33"), hex("44")])],
                userReactions: []
            )
        )
        let deleted = timelineRecord(
            messageIdHex: hex("c3"),
            sender: hex("33"),
            plaintext: "",
            timelineAt: 3,
            deleted: true
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [parent, reply, deleted], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.count == 3)
        #expect(viewModel.reactions(for: reply.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "👍", count: 2, mine: false)
        ])
        #expect(viewModel.isDeleted(deleted.messageIdHex))
        let replyRecord = try #require(viewModel.record(for: reply.messageIdHex))
        // The reply preview's resolved name now comes from the binding (covered by
        // ResolvedDisplayNameTests); here we assert the hydrated preview text.
        #expect(viewModel.replyPreview(for: replyRecord)?.text == "the parent text")
    }

    @Test func replyResponseStaysBelowParentWhenSameTimestampWouldSortByIdFirst() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let approve = timelineRecord(
            messageIdHex: hex("ff"),
            direction: "sent",
            sender: hex("22"),
            plaintext: "/approve",
            timelineAt: 1
        )
        let response = timelineRecord(
            messageIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "Command approved.",
            timelineAt: 1,
            replyToMessageIdHex: approve.messageIdHex,
            replyPreview: TimelineReplyPreviewFfi(
                messageIdHex: approve.messageIdHex,
                sender: approve.sender,
                plaintext: approve.plaintext,
                kind: MessageSemantics.kindChat,
                mediaJson: nil,
                media: [],
                agentTextStreamJson: nil,
                deleted: false
            )
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [response, approve], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let ids = viewModel.timeline.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
        #expect(ids == [approve.messageIdHex, response.messageIdHex])
    }

    @Test func windowReplyResponseStaysBelowParentWhenSameTimestampWouldInsertAbove() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let approve = timelineRecord(
            messageIdHex: hex("ff"),
            direction: "sent",
            sender: hex("22"),
            plaintext: "/approve",
            timelineAt: 1
        )
        let response = timelineRecord(
            messageIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "Command approved.",
            timelineAt: 1,
            replyToMessageIdHex: approve.messageIdHex
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [approve], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [approve, response], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let ids = viewModel.timeline.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
        #expect(ids == [approve.messageIdHex, response.messageIdHex])
    }

    @Test func normalizedReplyOrderingMovesNestedRepliesAfterParents() {
        let parent = timelineRecord(messageIdHex: hex("ff"), timelineAt: 1)
        let middle = timelineRecord(
            messageIdHex: hex("bb"),
            timelineAt: 1,
            replyToMessageIdHex: parent.messageIdHex
        )
        let leaf = timelineRecord(
            messageIdHex: hex("aa"),
            timelineAt: 1,
            replyToMessageIdHex: middle.messageIdHex
        )
        let unrelated = timelineRecord(messageIdHex: hex("cc"), timelineAt: 1)
        let targetById = [
            middle.messageIdHex: parent.messageIdHex,
            leaf.messageIdHex: middle.messageIdHex,
        ]
        let items = [leaf, middle, unrelated, parent].map {
            TimelineItem.message(ConversationViewModel.appMessageRecord(from: $0))
        }

        let ordered = ConversationViewModel.normalizedReplyOrdering(items) {
            targetById[$0.messageIdHex]
        }

        #expect(messageIds(in: ordered) == [
            unrelated.messageIdHex,
            parent.messageIdHex,
            middle.messageIdHex,
            leaf.messageIdHex,
        ])
    }

    @Test func normalizedReplyOrderingPreservesEarlySiblingReplyOrder() {
        let parent = timelineRecord(messageIdHex: hex("ff"), timelineAt: 1)
        let firstReply = timelineRecord(
            messageIdHex: hex("aa"),
            timelineAt: 1,
            replyToMessageIdHex: parent.messageIdHex
        )
        let secondReply = timelineRecord(
            messageIdHex: hex("bb"),
            timelineAt: 1,
            replyToMessageIdHex: parent.messageIdHex
        )
        let targetById = [
            firstReply.messageIdHex: parent.messageIdHex,
            secondReply.messageIdHex: parent.messageIdHex,
        ]
        let items = [firstReply, secondReply, parent].map {
            TimelineItem.message(ConversationViewModel.appMessageRecord(from: $0))
        }

        let ordered = ConversationViewModel.normalizedReplyOrdering(items) {
            targetById[$0.messageIdHex]
        }

        #expect(messageIds(in: ordered) == [
            parent.messageIdHex,
            firstReply.messageIdHex,
            secondReply.messageIdHex,
        ])
    }

    @Test func timelineWindowPageReplacesRowsOutsideAuthoritativeWindow() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let latest = timelineRecord(messageIdHex: hex("f2"), plaintext: "latest", timelineAt: 20)
        let older = timelineRecord(messageIdHex: hex("e1"), plaintext: "older", timelineAt: 10)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [latest], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [older], hasMoreBefore: false, hasMoreAfter: true),
            placement: .window
        )

        #expect(messageIds(in: viewModel.timeline) == [older.messageIdHex])
        #expect(viewModel.record(for: latest.messageIdHex) == nil)
        #expect(!viewModel.hasMoreBefore)
        #expect(viewModel.hasMoreAfter)
    }

    @Test func tailRefreshWhileDetachedOnlyUpdatesLoadedRows() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        let loaded = timelineRecord(messageIdHex: hex("e1"), plaintext: "loaded", timelineAt: 10)
        let loadedWithReaction = timelineRecord(
            messageIdHex: loaded.messageIdHex,
            plaintext: loaded.plaintext,
            timelineAt: loaded.timelineAt,
            reactions: TimelineReactionSummaryFfi(
                byEmoji: [TimelineReactionEmojiFfi(emoji: "🔥", count: 1, senders: [hex("33")])],
                userReactions: []
            )
        )
        let newHead = timelineRecord(messageIdHex: hex("f2"), plaintext: "new head", timelineAt: 20)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [loaded], hasMoreBefore: false, hasMoreAfter: true),
            placement: .window
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [loadedWithReaction, newHead], hasMoreBefore: true, hasMoreAfter: false),
            placement: .tailRefresh
        )

        #expect(messageIds(in: viewModel.timeline) == [loaded.messageIdHex])
        #expect(viewModel.reactions(for: loaded.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 1, mine: false)
        ])
        #expect(!viewModel.hasMoreBefore)
        #expect(viewModel.hasMoreAfter)
    }

    @Test func liveProjectionUpdateMaintainsTimelineWithoutFullRebuild() throws {
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let first = timelineRecord(messageIdHex: hex("e1"), groupIdHex: groupIdHex, timelineAt: 10)
        let second = timelineRecord(messageIdHex: hex("e2"), groupIdHex: groupIdHex, timelineAt: 20)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [first], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let rebuildCount = viewModel.timelineRebuildCountForTesting

        viewModel.applyTimelineSubscriptionUpdate(.projection(update: RuntimeProjectionUpdateFfi(
            accountIdHex: hex("01"),
            accountLabel: "account",
            update: TimelineProjectionUpdateFfi(
                groupIdHex: groupIdHex,
                messages: [],
                changes: [.upsert(trigger: .newMessage, message: second)],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            )
        )))

        #expect(messageIds(in: viewModel.timeline) == [first.messageIdHex, second.messageIdHex])
        #expect(viewModel.timelineRebuildCountForTesting == rebuildCount)
    }

    @Test func projectedOutgoingMessageReplacesMatchingPendingBubble() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "hello from me",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        var projected = timelineRecord(
            messageIdHex: hex("b2"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 20
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-1", record: pending)
        projected.clientToken = "pending-1"
        viewModel.timelineStore.markLocalSendSubmitted(tempId: "pending-1")
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projected], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (String, MessageStatus, UInt64)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.timestamp)
        }

        #expect(messages.count == 1)
        #expect(messages.first?.0 == projected.messageIdHex)
        #expect(messages.first?.1 == .sent)
        #expect(messages.first?.2 == projected.timelineAt)
    }

    @Test func durablyPendingOwnRowStaysPendingUntilDeliveredUpsert() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "stuck offline",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let durablyPending = timelineRecord(
            messageIdHex: hex("b7"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 20
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-durable", record: pending)

        #expect(viewModel.timeline.compactMap { item -> MessageStatus? in
            guard item.id == "msg:pending-durable", case .message(_, let status) = item.kind else { return nil }
            return status
        }.first == .sending)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [durablyPending], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let rowId = "msg:\(durablyPending.messageIdHex)"
        func status() -> MessageStatus? {
            viewModel.timeline.compactMap { item -> MessageStatus? in
                guard item.id == rowId, case .message(_, let status) = item.kind else { return nil }
                return status
            }.first
        }

        // The first durable projection consumes the optimistic row but remains
        // unresolved, so it keeps the clock and convergence-retry path.
        #expect(status() == .sending)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).systemImage == "clock")
        #expect(viewModel.canRetryFailedSend(rowId: rowId))
        #expect(viewModel.canDiscardFailedSend(rowId: rowId))

        // Repeating the same nil-source projection must not reinterpret the
        // durable unresolved state as failure after reconciliation is complete.
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [durablyPending], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sending)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).systemImage == "clock")

        // Delivery upsert (same row, source id now present) flips it to sent.
        let delivered = timelineRecord(
            messageIdHex: durablyPending.messageIdHex,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: durablyPending.plaintext,
            timelineAt: 20
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [delivered], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sent)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).systemImage == "checkmark")
        #expect(!viewModel.canRetryFailedSend(rowId: rowId))
    }

    @Test func definitivelyInvalidatedOwnRowRendersFailed() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let invalidated = timelineRecord(
            messageIdHex: hex("b9"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "rejected durably",
            timelineAt: 20,
            invalidationStatus: "local_publish_failed"
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [invalidated], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let status = viewModel.timeline.compactMap { item -> MessageStatus? in
            guard item.id == "msg:\(invalidated.messageIdHex)", case .message(_, let status) = item.kind else {
                return nil
            }
            return status
        }.first
        #expect(status == .failed)
        #expect(MessageFooterPresentation.value(for: try #require(status), isFromMe: true).isFailure)
    }

    @Test func unsuccessfulDurableRetryRestoresInvalidatedFailureOutsideRefreshedTail() async throws {
        var attempts = 0
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, groupIdHex in
                attempts += 1
                throw MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: groupIdHex)
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(attempts == 1)
        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
        #expect(fixture.viewModel.error != nil)
    }

    @Test func durableRetryReportsUnavailableRuntime() async throws {
        let groupIdHex = hex("aa")
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "", id: groupIdHex)
        )
        let record = timelineRecord(
            messageIdHex: hex("d1"),
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20,
            invalidationStatus: "local_publish_failed"
        )
        let rowId = "msg:\(record.messageIdHex)"
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: true, hasMoreAfter: false),
            placement: .window
        )

        await viewModel.retryFailedSend(rowId: rowId)

        #expect(status(of: rowId, in: viewModel) == .failed)
        #expect(viewModel.error == L10n.string("Send failed"))
    }

    @Test func exhaustedDurableRetryKeepsNonInvalidatedRowSending() async throws {
        var attempts = 0
        var sleeps = 0
        let fixture = try durableRetryFixture(
            converge: { _, _, _ in
                attempts += 1
                return unpublishedRetrySummary()
            },
            sleep: { _ in sleeps += 1 }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(attempts == 6)
        #expect(sleeps == 5)
        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sending)
        #expect(fixture.viewModel.error != nil)
    }

    @Test func publishedDurableRetryMarksRowSentWhenRefreshedTailOmitsIt() async throws {
        let messageIdHex = hex("d1")
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, _ in
                SendSummaryFfi(
                    published: 1,
                    messageIds: [messageIdHex],
                    acceptDisposition: .published,
                    maintenanceDisposition: .ready
                )
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sent)
        #expect(!fixture.viewModel.canRetryFailedSend(rowId: fixture.rowId))
        #expect(fixture.viewModel.error == nil)
    }

    @Test func cancelledDurableRetryRestoresPriorFailure() async throws {
        var enteredRetrySleep = false
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, _ in
                return unpublishedRetrySummary()
            },
            sleep: { _ in
                enteredRetrySleep = true
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let retryTask = Task { @MainActor in
            await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)
        }
        try await waitForExpectation {
            enteredRetrySleep
        }

        retryTask.cancel()
        await retryTask.value

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
        #expect(fixture.viewModel.error == nil)
    }

    @Test func cancelledDuringFinalRefreshRestoresPriorFailureWithoutError() async throws {
        var enteredFinalRefresh = false
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, _ in unpublishedRetrySummary() },
            refresh: { _ in
                enteredFinalRefresh = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        let retryTask = Task { @MainActor in
            await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)
        }

        await retryTask.value

        #expect(enteredFinalRefresh)
        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
        #expect(fixture.viewModel.error == nil)
    }

    @Test func authoritativeDeliveryDuringRetryIsNotOverwrittenByCleanup() async throws {
        let groupIdHex = hex("aa")
        let messageIdHex = hex("d1")
        let delivered = timelineRecord(
            messageIdHex: messageIdHex,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20
        )
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, groupIdHex in
                throw MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: groupIdHex)
            },
            refresh: { viewModel in
                viewModel.applyTimelinePage(
                    TimelinePageFfi(messages: [delivered], hasMoreBefore: true, hasMoreAfter: false),
                    placement: .tailRefresh
                )
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sent)
        #expect(!fixture.viewModel.canRetryFailedSend(rowId: fixture.rowId))
        #expect(fixture.viewModel.error == nil)
    }

    @Test func authoritativePendingRefreshDuringRetryIsNotOverwrittenByCleanup() async throws {
        let groupIdHex = hex("aa")
        let messageIdHex = hex("d1")
        let revalidatedPending = timelineRecord(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "durable retry",
            timelineAt: 20
        )
        let fixture = try durableRetryFixture(
            invalidationStatus: "local_publish_failed",
            converge: { _, _, groupIdHex in
                throw MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: groupIdHex)
            },
            refresh: { viewModel in
                viewModel.applyTimelinePage(
                    TimelinePageFfi(messages: [revalidatedPending], hasMoreBefore: true, hasMoreAfter: false),
                    placement: .tailRefresh
                )
            }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .sending)
        #expect(fixture.viewModel.canRetryFailedSend(rowId: fixture.rowId))
        #expect(fixture.viewModel.error != nil)
    }

    @Test func successfulSendAckDoesNotFlashFailedWhileDeliveredProjectionCatchesUp() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let messageId = hex("b8")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "published",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-ack", record: pending)
        viewModel.confirmSent(tempId: "pending-ack", record: pending, messageId: messageId)

        let localProjection = timelineRecord(
            messageIdHex: messageId,
            sourceMessageIdHex: .some(nil),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 10
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [localProjection], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let rowId = viewModel.displayID(for: messageId)
        func status() -> MessageStatus? {
            viewModel.timeline.compactMap { item -> MessageStatus? in
                guard item.id == rowId, case .message(_, let status) = item.kind else { return nil }
                return status
            }.first
        }

        #expect(status() == .sent)
        #expect(!viewModel.canRetryFailedSend(rowId: rowId))

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [localProjection], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sent)

        let deliveredProjection = timelineRecord(
            messageIdHex: messageId,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 10
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [deliveredProjection], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sent)
    }

    @Test func failedSendRowSupportsRetryGatingAndDiscard() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let tempId = "retry-1"
        let rowId = "msg:\(tempId)"
        let text = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "retry me",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: text)
        viewModel.markFailedForTesting(tempId: tempId)

        // A failed text row is retryable and discardable.
        #expect(viewModel.canRetryFailedSend(rowId: rowId))

        // A failed media row (carrying the pending-media marker) is NOT
        // retryable here — its compressed bytes aren't retained — but can
        // still be discarded.
        let mediaTempId = "retry-media"
        let mediaRowId = "msg:\(mediaTempId)"
        let media = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [MessageTagFfi(values: ["_media_pending"])],
            recordedAt: 11,
            receivedAt: 11
        )
        viewModel.applyPendingOutgoingMessage(tempId: mediaTempId, record: media)
        viewModel.markFailedForTesting(tempId: mediaTempId)
        #expect(!viewModel.canRetryFailedSend(rowId: mediaRowId))

        // Discard removes the failed row from the timeline.
        viewModel.discardFailedSend(rowId: rowId)
        let remaining = viewModel.timeline.compactMap { item -> String? in
            guard case .message = item.kind else { return nil }
            return item.id
        }
        #expect(!remaining.contains(rowId))
        #expect(remaining.contains(mediaRowId))
    }

    @Test func projectedOutgoingMessageReplacesMatchingFailedPendingBubble() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let tempId = "pending-1"
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "hello from me",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        var projected = timelineRecord(
            messageIdHex: hex("b2"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 20
        )

        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)
        viewModel.markFailedForTesting(tempId: tempId)

        let failedMessages = viewModel.timeline.compactMap { item -> (String, MessageStatus)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status)
        }
        #expect(failedMessages.count == 1)
        #expect(failedMessages[0].0 == "")
        #expect(failedMessages[0].1 == .failed)

        projected.clientToken = tempId
        viewModel.timelineStore.markLocalSendSubmitted(tempId: tempId)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projected], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (String, MessageStatus, UInt64)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.timestamp)
        }

        #expect(messages.count == 1)
        #expect(messages.first?.0 == projected.messageIdHex)
        #expect(messages.first?.1 == .sent)
        #expect(messages.first?.2 == projected.timelineAt)
    }

    @Test func projectedOutgoingMessageReplacesConfirmedTransientWithoutServerId() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "confirmed without id",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        var projected = timelineRecord(
            messageIdHex: hex("b2"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: pending.plaintext,
            timelineAt: 20
        )

        viewModel.applyPendingOutgoingMessage(tempId: "pending-1", record: pending)
        viewModel.confirmSent(tempId: "pending-1", record: pending, messageId: nil)
        projected.clientToken = "pending-1"
        viewModel.timelineStore.markLocalSendSubmitted(tempId: "pending-1")
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projected], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (String, MessageStatus, UInt64)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.timestamp)
        }

        #expect(messages.count == 1)
        #expect(messages.first?.0 == projected.messageIdHex)
        #expect(messages.first?.1 == .sent)
        #expect(messages.first?.2 == projected.timelineAt)
    }

    @MainActor
    @Test func confirmSentWithoutServerIdPreservesPendingMediaOnRecreatedRow() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let tempId = "pending-media-1"
        let tempRowId = "msg:\(tempId)"
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let attachment = MessageMediaAttachment(
            id: "\(tempRowId):0",
            reference: nil,
            fileName: "a.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        // Mirror sendMedia's optimistic setup: stage the local attachment bytes
        // under the temp row, then add the transient bubble.
        viewModel.installPendingMediaForTesting(rowId: tempRowId, items: [attachment])
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)

        // uploadMedia succeeded but returned no message id.
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: nil)

        // The transient row is recreated under the same id (no server id), and the
        // just-sent attachment must still resolve instead of vanishing.
        #expect(viewModel.pendingMediaForTesting(rowId: tempRowId) == [attachment])

        let mediaRow = try #require(viewModel.timeline.first { $0.id == tempRowId })
        #expect(viewModel.mediaItems(for: mediaRow) == [attachment])
    }

    @MainActor
    @Test func authoritativeMediaRowReleasesConfirmedPendingBytes() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let messageId = hex("b2")
        let tempId = "pending-media-real-id"
        let tempRowId = "msg:\(tempId)"
        let realRowId = tempRowId
        let reference = encryptedMediaReference(
            fileName: "canonical.jpg",
            plaintextByte: "31",
            ciphertextByte: "41",
            sourceEpoch: 42
        )
        let pending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [MessageSemantics.imetaTag(for: reference)],
            recordedAt: 10,
            receivedAt: 10
        )
        let localAttachment = MessageMediaAttachment(
            id: "local",
            reference: nil,
            fileName: "local.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )

        viewModel.installPendingMediaForTesting(rowId: tempRowId, items: [localAttachment])
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: messageId)
        #expect(viewModel.pendingMediaForTesting(rowId: realRowId) == [localAttachment])

        let authoritative = timelineRecord(
            messageIdHex: messageId,
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: "",
            tags: pending.tags,
            timelineAt: 20,
            media: [reference]
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [authoritative], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.pendingMediaForTesting(rowId: realRowId) == nil)
        let mediaRow = try #require(viewModel.timeline.first { $0.id == realRowId })
        #expect(viewModel.mediaItems(for: mediaRow).map(\.fileName) == ["canonical.jpg"])
    }

    @Test func projectedOutgoingMessageUsesExactTokenForIdenticalContent() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let plaintext = "same text twice"
        let olderPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let newerPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 20,
            receivedAt: 20
        )
        let tempIds = try #require(
            tempIdsWhereTransientTimelinePrefersNewerPendingFirst(older: olderPending, newer: newerPending)
        )
        var projectedOlder = timelineRecord(
            messageIdHex: hex("c3"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            timelineAt: olderPending.recordedAt
        )

        viewModel.applyPendingOutgoingMessage(tempId: tempIds.older, record: olderPending)
        viewModel.applyPendingOutgoingMessage(tempId: tempIds.newer, record: newerPending)
        projectedOlder.clientToken = tempIds.older
        viewModel.timelineStore.markLocalSendSubmitted(tempId: tempIds.older)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projectedOlder], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (id: String, status: MessageStatus, timestamp: UInt64)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.timestamp)
        }

        #expect(messages.count == 2)
        #expect(messages.first?.id == projectedOlder.messageIdHex)
        #expect(messages.first?.status == .sent)
        #expect(messages.first?.timestamp == projectedOlder.timelineAt)
        #expect(messages.last?.id == "")
        #expect(messages.last?.status == .sending)
        #expect(messages.last?.timestamp == newerPending.recordedAt)
    }

    @MainActor
    @Test func projectedTextSendDoesNotReconcileMediaPendingWithSameCaption() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let caption = "hi"

        // A media send: optimistic record carries `tags: []` and `plaintext`
        // equal to the caption, with the local attachment staged under its row.
        let mediaTempId = "pending-media"
        let mediaRowId = "msg:\(mediaTempId)"
        let mediaPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let attachment = MessageMediaAttachment(
            id: "\(mediaRowId):0",
            reference: nil,
            fileName: "a.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        viewModel.installPendingMediaForTesting(rowId: mediaRowId, items: [attachment])
        viewModel.applyPendingOutgoingMessage(tempId: mediaTempId, record: mediaPending)

        // A plain text send with the same text, no staged media.
        let textTempId = "pending-text"
        let textPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 11,
            receivedAt: 11
        )
        viewModel.applyPendingOutgoingMessage(tempId: textTempId, record: textPending)

        // The incoming confirmation is the plain text send (no `imeta` tags).
        // It must reconcile the text pending and leave the media bubble alone.
        var projectedText = timelineRecord(
            messageIdHex: hex("b2"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            timelineAt: 20
        )
        projectedText.clientToken = textTempId
        viewModel.timelineStore.markLocalSendSubmitted(tempId: textTempId)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projectedText], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (id: String, status: MessageStatus, rowId: String)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.id)
        }

        #expect(messages.count == 2)
        // The confirmed text send replaced the text pending.
        #expect(messages.contains { $0.id == projectedText.messageIdHex && $0.status == .sent })
        // The media pending bubble survived, still pending under its temp row.
        #expect(messages.contains { $0.rowId == mediaRowId && $0.status == .sending })
        // Its staged attachment is still resolvable.
        #expect(viewModel.pendingMediaForTesting(rowId: mediaRowId) == [attachment])
    }

    @MainActor
    @Test func projectedMediaSendReconcilesMediaPendingNotTextWithSameCaption() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: groupIdHex)
        )
        let caption = "hi"

        let mediaTempId = "pending-media"
        let mediaRowId = "msg:\(mediaTempId)"
        let mediaPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let attachment = MessageMediaAttachment(
            id: "\(mediaRowId):0",
            reference: nil,
            fileName: "a.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        viewModel.installPendingMediaForTesting(rowId: mediaRowId, items: [attachment])
        viewModel.applyPendingOutgoingMessage(tempId: mediaTempId, record: mediaPending)

        let textTempId = "pending-text"
        let textRowId = "msg:\(textTempId)"
        let textPending = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 11,
            receivedAt: 11
        )
        viewModel.applyPendingOutgoingMessage(tempId: textTempId, record: textPending)

        // The incoming confirmation is the media send: kind-9 with an `imeta`
        // tag. It must reconcile the media pending, not the text pending.
        let reference = encryptedMediaReference(sourceEpoch: 0)
        var projectedMedia = timelineRecord(
            messageIdHex: hex("b3"),
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: caption,
            tags: [MessageSemantics.imetaTag(for: reference)],
            timelineAt: 20
        )
        projectedMedia.clientToken = mediaTempId
        viewModel.timelineStore.markLocalSendSubmitted(tempId: mediaTempId)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [projectedMedia], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let messages = viewModel.timeline.compactMap { item -> (id: String, status: MessageStatus, rowId: String)? in
            guard case .message(let record, let status) = item.kind else { return nil }
            return (record.messageIdHex, status, item.id)
        }

        #expect(messages.count == 2)
        // The confirmed media send replaced the media pending.
        #expect(messages.contains { $0.id == projectedMedia.messageIdHex && $0.status == .sent })
        // The text pending bubble survived.
        #expect(messages.contains { $0.rowId == textRowId && $0.status == .sending })
        // The media pending row was removed (reconciled away).
        #expect(viewModel.pendingMediaForTesting(rowId: mediaRowId) == nil)
    }

    @Test func paginationProgressRequiresWindowEdgeMovement() {
        #expect(ConversationPaginationPolicy.movedOlder(
            previousOldestMessageId: "message-b",
            nextMessageIds: ["message-a", "message-b"]
        ))
        #expect(!ConversationPaginationPolicy.movedOlder(
            previousOldestMessageId: "message-b",
            nextMessageIds: ["message-b", "message-c"]
        ))
        #expect(!ConversationPaginationPolicy.movedOlder(
            previousOldestMessageId: "message-b",
            nextMessageIds: []
        ))
        #expect(ConversationPaginationPolicy.movedNewer(
            previousNewestMessageId: "message-b",
            nextMessageIds: ["message-b", "message-c"]
        ))
        #expect(!ConversationPaginationPolicy.movedNewer(
            previousNewestMessageId: "message-b",
            nextMessageIds: ["message-a", "message-b"]
        ))
        #expect(!ConversationPaginationPolicy.movedNewer(
            previousNewestMessageId: "message-b",
            nextMessageIds: []
        ))
    }

    private func messageIds(in items: [TimelineItem]) -> [String] {
        items.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        }
    }

    private func tempIdsWhereTransientTimelinePrefersNewerPendingFirst(
        older olderRecord: AppMessageRecordFfi,
        newer newerRecord: AppMessageRecordFfi
    ) -> (older: String, newer: String)? {
        for olderIndex in 0..<256 {
            for newerIndex in 0..<256 where newerIndex != olderIndex {
                let older = "duplicate-older-\(olderIndex)"
                let newer = "duplicate-newer-\(newerIndex)"
                let olderItem = TimelineItem.pendingMessage(tempId: older, record: olderRecord)
                let newerItem = TimelineItem.pendingMessage(tempId: newer, record: newerRecord)
                var values: [String: TimelineItem] = [:]
                values[olderItem.id] = olderItem
                values[newerItem.id] = newerItem
                if values.first?.key == newerItem.id {
                    return (older, newer)
                }
            }
        }
        return nil
    }
}
