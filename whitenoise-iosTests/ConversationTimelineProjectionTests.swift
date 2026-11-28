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
        client: MarmotClient?,
        invalidationStatus: String? = nil,
        isOnline: @escaping @MainActor () -> Bool = { true },
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
        let appState = AppState.test(client: client)
        appState.activeAccountRef = "account-ref"
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "", id: groupIdHex),
            durableRetryOperations: ConversationViewModel.DurableRetryOperations(
                isOnline: isOnline,
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

    /// Puts an optimistic delete and an optimistic reaction into the view
    /// model's timeline store, as a local delete and react do before Marmot
    /// confirms them.
    private func seedOptimisticState(
        in viewModel: ConversationViewModel,
        deletedMessageIdHex: String,
        reactionTargetMessageIdHex: String,
        emoji: String,
        sender: String
    ) {
        let store = viewModel.timelineStore
        store.deletedProjections.insertOptimistic(deletedMessageIdHex)
        let reactionId = "optimistic-\(reactionTargetMessageIdHex)-\(emoji)"
        store.reactionProjections.setRecord(
            AppMessageRecordFfi(
                messageIdHex: reactionId,
                direction: "sent",
                groupIdHex: viewModel.group.groupIdHex,
                sender: sender,
                plaintext: emoji,
                kind: MessageSemantics.kindReaction,
                tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, reactionTargetMessageIdHex])],
                recordedAt: 1,
                receivedAt: 1
            ),
            forKey: reactionId
        )
        _ = store.deletedProjections.rebuild()
        _ = store.recomputeReactions()
    }

    private func unpublishedRetrySummary() -> SendSummaryFfi {
        SendSummaryFfi(
            published: 0,
            messageIds: [],
            acceptDisposition: .acceptedPending,
            maintenanceDisposition: .ready
        )
    }

    @Test func peerConfirmedSendWithoutASourceIsNotAwaitingDelivery() {
        var unresolved = timelineRecord(
            messageIdHex: hex("d2"), sourceMessageIdHex: .some(nil), direction: "sent", timelineAt: 1
        )
        #expect(TimelineStore.ownSendAwaitsDelivery(unresolved))

        unresolved.recipientConfirmed = true
        #expect(!TimelineStore.ownSendAwaitsDelivery(unresolved))

        let sourced = timelineRecord(messageIdHex: hex("d3"), direction: "sent", timelineAt: 1)
        let received = timelineRecord(messageIdHex: hex("d4"), sourceMessageIdHex: .some(nil), timelineAt: 1)
        #expect(!TimelineStore.ownSendAwaitsDelivery(sourced))
        #expect(!TimelineStore.ownSendAwaitsDelivery(received))
    }

    @MainActor
    private func readMarkerAppState(client: MarmotClient) -> AppState {
        AppState.test(
            client: client,
            notifications: AppNotifications(
                deliveredNotificationDescriptorsProvider: { [] },
                pendingNotificationRequestsRemover: { _ in },
                deliveredNotificationIdentifiersRemover: { _ in }
            )
        )
    }

    private func orderKey(
        _ messageIdHex: String,
        epoch: UInt64 = 1,
        timelineAt: UInt64,
        kind: UInt64 = MessageSemantics.kindChat
    ) -> TimelineHistoryOrderKey {
        TimelineHistoryOrderKey(
            sourceMessageIdHex: messageIdHex,
            sourceEpoch: epoch,
            kind: kind,
            timelineAt: timelineAt,
            messageIdHex: messageIdHex
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
        let failed = ConversationReadMarker.Watermark(
            messageIdHex: "aa",
            orderKey: orderKey("aa", timelineAt: 7)
        )
        // Marmot rejects a mark for a message it has no durable row for yet,
        // which is the window right after a send. Nothing else produces a later
        // frame there, so the candidate has to survive the failed flush.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedWatermark: failed,
            pendingWatermark: nil,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == failed)
    }

    @Test func rejectedReadMarkDefersToANewerQueuedCandidate() {
        let failed = ConversationReadMarker.Watermark(
            messageIdHex: "aa",
            orderKey: orderKey("aa", timelineAt: 7)
        )
        let newer = ConversationReadMarker.Watermark(
            messageIdHex: "bb",
            orderKey: orderKey("bb", timelineAt: 8)
        )
        let older = ConversationReadMarker.Watermark(
            messageIdHex: "00",
            orderKey: orderKey("00", timelineAt: 6)
        )
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedWatermark: failed,
            pendingWatermark: newer,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == nil)
        // Same row and an older row are both non-advances, so the failed
        // candidate stays queued rather than regressing the watermark.
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedWatermark: failed,
            pendingWatermark: failed,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == failed)
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedWatermark: failed,
            pendingWatermark: older,
            attempts: 1,
            maximumAttempts: ConversationReadMarker.maximumFailedFlushAttempts
        ) == failed)
    }

    @Test func rejectedReadMarkStopsRetryingAtItsAttemptCap() {
        let cap = ConversationReadMarker.maximumFailedFlushAttempts
        let failed = ConversationReadMarker.Watermark(
            messageIdHex: "aa",
            orderKey: orderKey("aa", timelineAt: 7)
        )
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedWatermark: failed,
            pendingWatermark: nil,
            attempts: cap - 1,
            maximumAttempts: cap
        ) == failed)
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedWatermark: failed,
            pendingWatermark: nil,
            attempts: cap,
            maximumAttempts: cap
        ) == nil)
        #expect(ConversationReadMarker.retryStateAfterFailedFlush(
            failedWatermark: failed,
            pendingWatermark: nil,
            attempts: cap + 1,
            maximumAttempts: cap
        ) == nil)
    }

    @Test func readWatermarkAdvancesOnlyForStrictlyNewerCandidates() {
        let key4 = orderKey("04", timelineAt: 4)
        let key11 = orderKey("11", timelineAt: 11)
        let key12 = orderKey("12", timelineAt: 12)
        let key13 = orderKey("13", timelineAt: 13)
        // Marmot's read marker is one moving pointer, so the guard has to be
        // monotonic: scrolling back up must not regress it.
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key12,
            pendingKey: nil,
            flushedKey: nil,
            kind: MessageSemantics.kindChat,
            tags: [],
            isDeleted: false
        ) == key12)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key12,
            pendingKey: nil,
            flushedKey: key12,
            kind: MessageSemantics.kindChat,
            tags: [],
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key4,
            pendingKey: nil,
            flushedKey: key12,
            kind: MessageSemantics.kindChat,
            tags: [],
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key13,
            pendingKey: key12,
            flushedKey: nil,
            kind: MessageSemantics.kindChat,
            tags: [],
            isDeleted: false
        ) == key13)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key11,
            pendingKey: key12,
            flushedKey: nil,
            kind: MessageSemantics.kindChat,
            tags: [],
            isDeleted: false
        ) == nil)
    }

    @Test func readWatermarkRejectsIneligibleCandidates() {
        let key3 = orderKey("03", timelineAt: 3)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key3,
            pendingKey: nil,
            flushedKey: nil,
            kind: MessageSemantics.kindReaction,
            tags: [],
            isDeleted: false
        ) == nil)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key3,
            pendingKey: nil,
            flushedKey: nil,
            kind: MessageSemantics.kindChat,
            tags: [],
            isDeleted: true
        ) == nil)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: nil,
            pendingKey: nil,
            flushedKey: nil,
            kind: MessageSemantics.kindChat,
            tags: [],
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
        let key4 = orderKey("04", timelineAt: 4)
        let key5 = orderKey("05", timelineAt: 5, kind: MessageSemantics.kindGroupSystem)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key5,
            pendingKey: nil,
            flushedKey: key4,
            kind: MessageSemantics.kindGroupSystem,
            tags: [],
            isDeleted: false
        ) == key5)
        #expect(ConversationReadMarker.nextWatermark(
            candidateKey: key5,
            pendingKey: nil,
            flushedKey: key4,
            kind: MessageSemantics.kindGroupSystem,
            tags: [],
            isDeleted: true
        ) == nil)
    }

    @Test func readWatermarkAcceptsOnlyUserVisibleRowKinds() {
        func canAdvance(_ kind: UInt64, _ tags: [[String]] = []) -> Bool {
            ConversationReadMarker.canAdvanceWatermark(kind: kind, tags: tags.map { MessageTagFfi(values: $0) })
        }
        #expect(canAdvance(MessageSemantics.kindChat))
        #expect(canAdvance(MessageSemantics.kindPoll))
        #expect(canAdvance(MessageSemantics.kindGroupSystem))
        // A thread message carries the marker; MDK refuses a kind 1111 without a parent.
        #expect(canAdvance(MessageSemantics.kindComment, [["e", hex("02")], ["k", "9"]]))
        #expect(!canAdvance(MessageSemantics.kindComment, [["k", "9"]]))
        #expect(!canAdvance(MessageSemantics.kindReaction))
        #expect(!canAdvance(MessageSemantics.kindDelete))
        #expect(!canAdvance(MessageSemantics.kindEdit))
        #expect(!canAdvance(MessageSemantics.kindAgentActivity))
    }

    @Test func newestVisibleWatermarkCandidateTakesGroupSystemTail() {
        let readChat = message(id: hex("11"), kind: MessageSemantics.kindChat)
        let memberAdded = message(id: hex("22"), kind: MessageSemantics.kindGroupSystem)
        let memberRemoved = message(id: hex("33"), kind: MessageSemantics.kindGroupSystem)
        let keys = [
            hex("11"): orderKey(hex("11"), timelineAt: 7),
            hex("22"): orderKey(hex("22"), timelineAt: 8, kind: MessageSemantics.kindGroupSystem),
            hex("33"): orderKey(hex("33"), timelineAt: 9, kind: MessageSemantics.kindGroupSystem),
        ]

        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [readChat, memberAdded, memberRemoved],
            isDeleted: { _ in false },
            orderKey: { keys[$0] }
        )

        #expect(candidate?.messageIdHex == memberRemoved.messageIdHex)
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func readWatermarkRemainsMonotonicAfterFlushedMessageIsEvictedFromWindow() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let sleeper = ControlledSleeper()
            let older = message(id: hex("10"), kind: MessageSemantics.kindChat)
            let newer = message(id: hex("20"), kind: MessageSemantics.kindChat)
            let future = message(id: hex("30"), kind: MessageSemantics.kindChat)
            var loadedKeys: [String: TimelineHistoryOrderKey] = [
                older.messageIdHex: orderKey(older.messageIdHex, epoch: 1, timelineAt: 100),
                newer.messageIdHex: orderKey(newer.messageIdHex, epoch: 2, timelineAt: 200),
                future.messageIdHex: orderKey(future.messageIdHex, epoch: 2, timelineAt: 300),
            ]
            var markedIds: [String] = []
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { loadedKeys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            // Flush the newer watermark while it is in the loaded window.
            marker.advanceWatermark(to: newer, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [newer.messageIdHex] && sleeper.sleepingCount == 0 }

            // Evict the flushed message from the bounded window (user scrolled far up).
            loadedKeys.removeValue(forKey: newer.messageIdHex)
            marker.advanceWatermark(to: older, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.count == 1)
            #expect(markedIds == [newer.messageIdHex])

            // A strictly newer message still advances the watermark.
            marker.advanceWatermark(to: future, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [newer.messageIdHex, future.messageIdHex] && sleeper.sleepingCount == 0 }
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func seedFlushedWatermarkRatchetsForwardWhenAnotherDeviceReadsAhead() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let older = message(id: hex("11"), kind: MessageSemantics.kindChat)
            let mid = message(id: hex("22"), kind: MessageSemantics.kindChat)
            let ahead = message(id: hex("33"), kind: MessageSemantics.kindChat)
            let newest = message(id: hex("44"), kind: MessageSemantics.kindChat)
            let keys: [String: TimelineHistoryOrderKey] = [
                older.messageIdHex: orderKey(older.messageIdHex, epoch: 1, timelineAt: 10),
                mid.messageIdHex: orderKey(mid.messageIdHex, epoch: 1, timelineAt: 20),
                ahead.messageIdHex: orderKey(ahead.messageIdHex, epoch: 2, timelineAt: 30),
                newest.messageIdHex: orderKey(newest.messageIdHex, epoch: 2, timelineAt: 40),
            ]
            let sleeper = ControlledSleeper()
            var markedIds: [String] = []
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            marker.seedFlushedWatermark(messageIdHex: mid.messageIdHex)
            // Seeding an older id never regresses the watermark: mid stays rejected.
            marker.seedFlushedWatermark(messageIdHex: older.messageIdHex)
            marker.advanceWatermark(to: mid, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.isEmpty)

            // Seeding a strictly newer id (linked device read ahead) ratchets forward.
            marker.seedFlushedWatermark(messageIdHex: ahead.messageIdHex)

            // Messages at or behind the ratcheted watermark are rejected.
            marker.advanceWatermark(to: mid, isDeleted: false)
            marker.advanceWatermark(to: ahead, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.isEmpty)
            #expect(markedIds.isEmpty)

            // A message strictly newer than the ratcheted watermark still flushes.
            marker.advanceWatermark(to: newest, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [newest.messageIdHex] }
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func offWindowSavedMarkerArrivingDuringCoalescingBlocksQueuedCandidate() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let msgA = message(id: hex("d1"), kind: MessageSemantics.kindChat)
            let msgB = message(id: hex("d2"), kind: MessageSemantics.kindChat)
            let msgC = message(id: hex("d3"), kind: MessageSemantics.kindChat)
            let msgD = message(id: hex("d4"), kind: MessageSemantics.kindChat)
            var keys: [String: TimelineHistoryOrderKey] = [
                msgA.messageIdHex: orderKey(msgA.messageIdHex, epoch: 1, timelineAt: 10),
                msgB.messageIdHex: orderKey(msgB.messageIdHex, epoch: 1, timelineAt: 20),
            ]
            let sleeper = ControlledSleeper()
            var markedIds: [String] = []
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            // Session marks A, establishing a resolved floor.
            marker.advanceWatermark(to: msgA, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [msgA.messageIdHex] && sleeper.sleepingCount == 0 }

            // Queue B during coalescing, then a linked device advances the
            // saved marker to off-window C before B flushes.
            marker.advanceWatermark(to: msgB, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            marker.seedFlushedWatermark(
                messageIdHex: msgC.messageIdHex,
                unreadCount: 0,
                firstUnreadMessageIdHex: nil,
                hasMoreAfter: true
            )
            sleeper.releaseAll()
            await Task.yield()
            await Task.yield()

            // B must NOT be flushed over the newer off-window marker C.
            #expect(markedIds == [msgA.messageIdHex])
            let delaysAfterDrop = sleeper.requestedDelays.count
            marker.advanceWatermark(to: msgB, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.count == delaysAfterDrop)

            // Once C and newer D enter the window, C promotes to the durable
            // floor and D is admitted normally.
            keys[msgC.messageIdHex] = orderKey(msgC.messageIdHex, epoch: 2, timelineAt: 30)
            keys[msgD.messageIdHex] = orderKey(msgD.messageIdHex, epoch: 2, timelineAt: 40)
            marker.seedFlushedWatermark(
                messageIdHex: msgC.messageIdHex,
                unreadCount: 1,
                firstUnreadMessageIdHex: msgD.messageIdHex,
                hasMoreAfter: false
            )
            marker.advanceWatermark(to: msgD, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [msgA.messageIdHex, msgD.messageIdHex] }
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func inFlightReadMarkPreservesOffWindowSavedMarkerReportedOnCompletion() async throws {
        try await withTestClient { client in
            let reconcileCount = Mutex(0)
            let notifications = AppNotifications(
                deliveredNotificationDescriptorsProvider: {
                    reconcileCount.withLock { $0 += 1 }
                    return []
                }
            )
            let appState = AppState.test(client: client, notifications: notifications)
            appState.activeAccountRef = "acct-1"
            let msgB = message(id: hex("f1"), kind: MessageSemantics.kindChat)
            let msgB2 = message(id: hex("f2"), kind: MessageSemantics.kindChat)
            let msgB3 = message(id: hex("f3"), kind: MessageSemantics.kindChat)
            let offWindowC = hex("f9")
            let offWindowFirstUnread = hex("fa")
            let keys: [String: TimelineHistoryOrderKey] = [
                msgB.messageIdHex: orderKey(msgB.messageIdHex, epoch: 1, timelineAt: 10),
                msgB2.messageIdHex: orderKey(msgB2.messageIdHex, epoch: 1, timelineAt: 20),
                msgB3.messageIdHex: orderKey(msgB3.messageIdHex, epoch: 1, timelineAt: 30),
            ]
            let sleeper = ControlledSleeper()
            let writeEntered = TestLatch()
            let writeRelease = TestLatch()
            var markedIds: [String] = []
            var returnedRow: ChatListRowFfi?
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    writeEntered.signal()
                    try await writeRelease.wait()
                    return ids.map {
                        TimelineReadMarkResult(messageIdHex: $0, row: returnedRow, succeeded: true)
                    }
                }
            )

            // Case 1: MDK returns success for B, but its returned row reports
            // that the durable cursor is at off-window C with unread messages
            // still beyond the current historical page. Completion must retain
            // off-window C fail-closed (`hasMoreAfter = true`) and block B2.
            var rowAtC = chatListRow(groupIdHex: hex("aa"), title: "Chat")
            rowAtC.lastReadMessageIdHex = offWindowC
            rowAtC.unreadCount = 2
            rowAtC.firstUnreadMessageIdHex = offWindowFirstUnread
            returnedRow = rowAtC
            marker.advanceWatermark(to: msgB, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await writeEntered.wait()
            writeRelease.signal()
            // Waiting for notification reconciliation proves `settleSuccessfulFlush` completed.
            try await eventually { reconcileCount.withLock { $0 } >= 1 }

            let delaysAfterB = sleeper.requestedDelays.count
            marker.advanceWatermark(to: msgB2, isDeleted: false)
            #expect(sleeper.requestedDelays.count == delaysAfterB)
            #expect(markedIds == [msgB.messageIdHex])

            // Case 2: Another off-window marker arrives via seedFlushedWatermark
            // AFTER an in-flight write starts (and the write returns row == nil).
            // Completion must preserve the newer off-window floor instead of clearing it.
            let write2Entered = TestLatch()
            let write2Release = TestLatch()
            var marked2: [String] = []
            let marker2 = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    marked2.append(contentsOf: ids)
                    write2Entered.signal()
                    try await write2Release.wait()
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )
            marker2.advanceWatermark(to: msgB, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await write2Entered.wait()

            marker2.seedFlushedWatermark(
                messageIdHex: offWindowC,
                unreadCount: 0,
                firstUnreadMessageIdHex: nil,
                hasMoreAfter: true
            )
            let reconcilesBeforeRelease = reconcileCount.withLock { $0 }
            write2Release.signal()
            try await eventually { reconcileCount.withLock { $0 } > reconcilesBeforeRelease }

            let delaysAfterSeed = sleeper.requestedDelays.count
            marker2.advanceWatermark(to: msgB3, isDeleted: false)
            #expect(sleeper.requestedDelays.count == delaysAfterSeed)
            #expect(marked2 == [msgB.messageIdHex])
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func reconcileDeliveredNotificationsSkipsRemovalWhenFlushSuspendedDuringLookup() async throws {
        try await withTestClient { client in
            let groupIdHex = hex("aa")
            let msg1 = message(id: hex("e7"), kind: MessageSemantics.kindChat)
            let msg2 = message(id: hex("e8"), kind: MessageSemantics.kindChat)
            let keys: [String: TimelineHistoryOrderKey] = [
                msg1.messageIdHex: orderKey(msg1.messageIdHex, epoch: 1, timelineAt: 100),
                msg2.messageIdHex: orderKey(msg2.messageIdHex, epoch: 1, timelineAt: 200),
            ]
            let lookup2Entered = TestLatch()
            let lookup2Release = TestLatch()
            let lookup2Returned = TestLatch()
            let lookupCalls = Mutex(0)
            let removedIdentifiers = Mutex<[String]>([])
            let descriptor1 = DeliveredNotificationDescriptor(
                identifier: "notif-1",
                route: LocalNotificationRoute(
                    accountRef: "acct-1",
                    groupIdHex: groupIdHex,
                    notificationKey: "notif-1",
                    messageIdHex: msg1.messageIdHex
                ),
                isMessageNotification: true,
                isActionFailure: false
            )
            let descriptor2 = DeliveredNotificationDescriptor(
                identifier: "notif-2",
                route: LocalNotificationRoute(
                    accountRef: "acct-1",
                    groupIdHex: groupIdHex,
                    notificationKey: "notif-2",
                    messageIdHex: msg2.messageIdHex
                ),
                isMessageNotification: true,
                isActionFailure: false
            )
            let notifications = AppNotifications(
                deliveredNotificationDescriptorsProvider: {
                    let call = lookupCalls.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    if call == 1 {
                        return [descriptor1]
                    }
                    lookup2Entered.signal()
                    try? await lookup2Release.wait()
                    defer { lookup2Returned.signal() }
                    return [descriptor2]
                },
                deliveredNotificationIdentifiersRemover: { ids in
                    removedIdentifiers.withLock { $0.append(contentsOf: ids) }
                }
            )
            let appState = AppState.test(client: client, notifications: notifications)
            appState.activeAccountRef = "acct-1"

            let sleeper = ControlledSleeper()
            var fullyReadRow = chatListRow(groupIdHex: groupIdHex, title: "Chat")
            fullyReadRow.hasUnread = false
            fullyReadRow.unreadCount = 0
            let marker = ConversationReadMarker(
                groupIdHex: groupIdHex,
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    ids.map { TimelineReadMarkResult(messageIdHex: $0, row: fullyReadRow, succeeded: true) }
                }
            )

            // Positive control: unsuspended flush removes delivered notifications.
            marker.advanceWatermark(to: msg1, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { removedIdentifiers.withLock { $0 } == ["notif-1"] }

            // Suspended case: suspend while delivered-notification lookup is in flight;
            // once lookup completes after suspension, stale removal must be skipped.
            marker.advanceWatermark(to: msg2, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await lookup2Entered.wait()

            marker.suspendPendingReadMarks()
            lookup2Release.signal()
            try await lookup2Returned.wait()
            // Drain any already-enqueued centerMutationQueue work via a second no-op reconcile barrier.
            await notifications.reconcileDeliveredNotificationsAfterRead(
                accountRef: "acct-1",
                groupIdHex: groupIdHex,
                readMessageIdHexes: [hex("e9")],
                conversationStillHasUnread: true,
                shouldRemoveDeliveredNotifications: { false }
            )

            #expect(removedIdentifiers.withLock { $0 } == ["notif-1"])
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func readMarkerExitsSleepLoopWhenBackgroundedAndFlushesOnResume() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let first = message(id: hex("11"), kind: MessageSemantics.kindChat)
            let second = message(id: hex("22"), kind: MessageSemantics.kindChat)
            let keys: [String: TimelineHistoryOrderKey] = [
                first.messageIdHex: orderKey(first.messageIdHex, epoch: 1, timelineAt: 10),
                second.messageIdHex: orderKey(second.messageIdHex, epoch: 1, timelineAt: 20),
            ]
            let sleeper = ControlledSleeper()
            var markedIds: [String] = []
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            marker.advanceWatermark(to: first, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }

            // Background before the coalesced flush fires: the task must exit cleanly
            // without scheduling another 100 ms poll, while keeping the pending watermark.
            appState.setAppSceneActive(false)
            sleeper.releaseAll()
            try await eventually { sleeper.sleepingCount == 0 }
            await Task.yield()
            #expect(sleeper.requestedDelays.count == 1)
            #expect(markedIds.isEmpty)

            // Advancing while backgrounded updates the parked candidate without starting a timer.
            marker.advanceWatermark(to: second, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.count == 1)

            // Returning to foreground resumes via flushIfNeeded() and marks the newest watermark once.
            appState.setAppSceneActive(true)
            marker.flushIfNeeded()
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [second.messageIdHex] && sleeper.sleepingCount == 0 }
            #expect(sleeper.requestedDelays.count == 2)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func exhaustedReadMarkFailuresDoNotPresentUserFacingToast() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let candidate = message(id: hex("55"), kind: MessageSemantics.kindChat)
            let key = orderKey(candidate.messageIdHex, epoch: 1, timelineAt: 50)
            let sleeper = ControlledSleeper()
            var attempts = 0
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { $0 == candidate.messageIdHex ? key : nil },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    attempts += 1
                    return ids.map {
                        TimelineReadMarkResult(
                            messageIdHex: $0,
                            row: nil,
                            succeeded: false,
                            failureCategory: "marmot_error"
                        )
                    }
                }
            )

            marker.advanceWatermark(to: candidate, isDeleted: false)
            for expectedAttempt in 1...ConversationReadMarker.maximumFailedFlushAttempts {
                try await eventually { sleeper.sleepingCount == 1 }
                sleeper.releaseAll()
                try await eventually { attempts == expectedAttempt }
            }
            await Task.yield()
            await Task.yield()
            #expect(sleeper.sleepingCount == 0)
            #expect(sleeper.requestedDelays.count == ConversationReadMarker.maximumFailedFlushAttempts)
            #expect(appState.activeToast == nil)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func optimisticUnresolvedOwnSendDoesNotBlockNewerInboundReadMarks() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let ownSend = message(id: hex("a1"), kind: MessageSemantics.kindChat)
            let inboundReply = message(id: hex("a2"), kind: MessageSemantics.kindChat)
            // Keep ownSend unresolved (rank 2: sourceEpoch == nil, sourceMessageIdHex == nil).
            var keys: [String: TimelineHistoryOrderKey] = [
                ownSend.messageIdHex: TimelineHistoryOrderKey(
                    sourceMessageIdHex: nil,
                    sourceEpoch: nil,
                    kind: ownSend.kind,
                    timelineAt: 100,
                    messageIdHex: ownSend.messageIdHex
                ),
                inboundReply.messageIdHex: orderKey(inboundReply.messageIdHex, epoch: 5, timelineAt: 110),
            ]

            // Both viewport selection and single-row eligibility (used by the
            // tail path in ConversationViewModel.newestTailWatermarkCandidate)
            // exclude unresolved rank-2 optimistic sends so Marmot never
            // persists a class-2 cursor ahead of authenticated rows.
            #expect(
                ConversationReadMarker.nextWatermark(
                    candidateKey: keys[ownSend.messageIdHex],
                    pendingKey: nil,
                    flushedKey: nil,
                    kind: ownSend.kind,
                    tags: ownSend.tags,
                    isDeleted: false
                ) == nil
            )
            #expect(
                ConversationReadMarker.newestWatermarkCandidate(
                    in: [ownSend],
                    isDeleted: { _ in false },
                    orderKey: { keys[$0] }
                ) == nil
            )
            #expect(
                ConversationReadMarker.newestWatermarkCandidate(
                    in: [ownSend, inboundReply],
                    isDeleted: { _ in false },
                    orderKey: { keys[$0] }
                )?.messageIdHex == inboundReply.messageIdHex
            )
            #expect(
                ConversationReadMarker.newestWatermarkCandidate(
                    in: [inboundReply, ownSend],
                    isDeleted: { _ in false },
                    orderKey: { keys[$0] }
                )?.messageIdHex == inboundReply.messageIdHex
            )

            let sleeper = ControlledSleeper()
            var markedIds: [String] = []
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            // Advancing to the unresolved optimistic own send is ignored.
            marker.advanceWatermark(to: ownSend, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.isEmpty)

            // A durable inbound reply flushes cleanly.
            marker.advanceWatermark(to: inboundReply, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [inboundReply.messageIdHex] && sleeper.sleepingCount == 0 }

            // Once the own send settles to a newer durable epoch row, it becomes eligible.
            keys[ownSend.messageIdHex] = orderKey(ownSend.messageIdHex, epoch: 5, timelineAt: 120)
            marker.advanceWatermark(to: ownSend, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually {
                markedIds == [inboundReply.messageIdHex, ownSend.messageIdHex] && sleeper.sleepingCount == 0
            }
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func inFlightReadMarkBlocksOlderRowsFromQueuingDuringFlush() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let older = message(id: hex("b1"), kind: MessageSemantics.kindChat)
            let newer = message(id: hex("b2"), kind: MessageSemantics.kindChat)
            let keys: [String: TimelineHistoryOrderKey] = [
                older.messageIdHex: orderKey(older.messageIdHex, epoch: 2, timelineAt: 100),
                newer.messageIdHex: orderKey(newer.messageIdHex, epoch: 2, timelineAt: 200),
            ]
            let sleeper = ControlledSleeper()
            let markEntered = TestLatch()
            let markRelease = TestLatch()
            var markedIds: [String] = []
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    markEntered.signal()
                    try await markRelease.wait()
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            marker.advanceWatermark(to: newer, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await markEntered.wait()

            // Scrolling up to an older row while the newer mark is in flight must
            // not enqueue or flush the older row.
            marker.advanceWatermark(to: older, isDeleted: false)
            markRelease.signal()
            await Task.yield()
            await Task.yield()
            #expect(sleeper.requestedDelays.count == 1)
            #expect(markedIds == [newer.messageIdHex])
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func retiredFlushAfterSuspensionCannotClobberResumedFlushState() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let older = message(id: hex("e1"), kind: MessageSemantics.kindChat)
            let first = message(id: hex("e2"), kind: MessageSemantics.kindChat)
            let second = message(id: hex("e3"), kind: MessageSemantics.kindChat)
            let keys: [String: TimelineHistoryOrderKey] = [
                older.messageIdHex: orderKey(older.messageIdHex, epoch: 1, timelineAt: 100),
                first.messageIdHex: orderKey(first.messageIdHex, epoch: 1, timelineAt: 200),
                second.messageIdHex: orderKey(second.messageIdHex, epoch: 1, timelineAt: 300),
            ]
            let sleeper = ControlledSleeper()
            let flush1Entered = TestLatch()
            let flush1Release = TestLatch()
            let flush2Entered = TestLatch()
            let flush2Release = TestLatch()
            var markedIds: [String] = []
            var callCount = 0
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    callCount += 1
                    let currentCall = callCount
                    markedIds.append(contentsOf: ids)
                    if currentCall == 1 {
                        flush1Entered.signal()
                        try? await flush1Release.wait()
                        return ids.map {
                            TimelineReadMarkResult(
                                messageIdHex: $0,
                                row: nil,
                                succeeded: false,
                                failureCategory: "storage_closed"
                            )
                        }
                    }
                    flush2Entered.signal()
                    try? await flush2Release.wait()
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            // Start flush #1 and hold it in flight.
            marker.advanceWatermark(to: first, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await flush1Entered.wait()

            // Suspend mid-flight, then resume with a newer candidate starting flush #2.
            marker.suspendPendingReadMarks()
            marker.advanceWatermark(to: second, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await flush2Entered.wait()

            // Retired flush #1 finishes with a failure while flush #2 is still in flight.
            // It must neither clear flush #2's in-flight floor nor requeue `first`.
            flush1Release.signal()
            await Task.yield()
            await Task.yield()

            marker.advanceWatermark(to: older, isDeleted: false)
            flush2Release.signal()
            await Task.yield()
            await Task.yield()

            #expect(markedIds == [first.messageIdHex, second.messageIdHex])
            #expect(sleeper.requestedDelays.count == 2)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func historicalPageExcludingPersistedMarkerDoesNotRegressReadMark() async throws {
        try await withTestClient { client in
            let appState = readMarkerAppState(client: client)
            appState.activeAccountRef = "acct-1"
            let older = message(id: hex("c1"), kind: MessageSemantics.kindChat)
            let firstUnread = message(id: hex("c3"), kind: MessageSemantics.kindChat)
            let liveTail = message(id: hex("c4"), kind: MessageSemantics.kindChat)
            var keys: [String: TimelineHistoryOrderKey] = [
                older.messageIdHex: orderKey(older.messageIdHex, epoch: 1, timelineAt: 50),
            ]
            let sleeper = ControlledSleeper()
            var markedIds: [String] = []
            let marker = ConversationReadMarker(
                groupIdHex: hex("aa"),
                appState: appState,
                orderKey: { keys[$0] },
                onChatListRowUpdated: nil,
                sleep: { try await sleeper.sleep($0) },
                markRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            // Open directly into an older historical page (`hasMoreAfter: true`)
            // that excludes both the persisted marker (`c2`) and `firstUnread`.
            marker.seedFlushedWatermark(
                messageIdHex: hex("c2"),
                unreadCount: 2,
                firstUnreadMessageIdHex: firstUnread.messageIdHex,
                hasMoreAfter: true
            )
            marker.advanceWatermark(to: older, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.isEmpty)
            #expect(markedIds.isEmpty)

            // When the live tail loads with `firstUnread` in the window, rows
            // before `firstUnread` remain blocked while `firstUnread` and newer
            // live-tail rows are canonically admitted.
            keys[firstUnread.messageIdHex] = orderKey(firstUnread.messageIdHex, epoch: 3, timelineAt: 250)
            keys[liveTail.messageIdHex] = orderKey(liveTail.messageIdHex, epoch: 3, timelineAt: 300)
            marker.seedFlushedWatermark(
                messageIdHex: hex("c2"),
                unreadCount: 2,
                firstUnreadMessageIdHex: firstUnread.messageIdHex,
                hasMoreAfter: false
            )
            marker.advanceWatermark(to: older, isDeleted: false)
            await Task.yield()
            #expect(sleeper.requestedDelays.isEmpty)

            marker.advanceWatermark(to: liveTail, isDeleted: false)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [liveTail.messageIdHex] && sleeper.sleepingCount == 0 }
        }
    }

    @Test func newestVisibleWatermarkCandidateIgnoresVisibilityOrder() {
        let older = message(id: hex("11"), kind: MessageSemantics.kindChat)
        let newest = message(id: hex("22"), kind: MessageSemantics.kindChat)
        let reactionTail = message(id: hex("33"), kind: MessageSemantics.kindReaction)
        let deletedTail = message(id: hex("44"), kind: MessageSemantics.kindChat)
        let keys = [
            hex("11"): orderKey(hex("11"), timelineAt: 7),
            hex("22"): orderKey(hex("22"), timelineAt: 8),
            hex("33"): orderKey(hex("33"), timelineAt: 9),
            hex("44"): orderKey(hex("44"), timelineAt: 10),
        ]

        // Row keys arrive in viewport order, not timeline order, and the tail
        // of the window can be a reaction or a deleted row.
        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [reactionTail, deletedTail, newest, older],
            isDeleted: { $0 == hex("44") },
            orderKey: { keys[$0] }
        )

        #expect(candidate?.messageIdHex == newest.messageIdHex)
    }

    @Test func newestVisibleWatermarkCandidateIsNilWithoutAnEligibleRow() {
        let reaction = message(id: hex("11"), kind: MessageSemantics.kindReaction)
        let outsideWindow = message(id: hex("22"), kind: MessageSemantics.kindChat)
        let reactionKey = orderKey(hex("11"), timelineAt: 1)

        let candidate = ConversationReadMarker.newestWatermarkCandidate(
            in: [reaction, outsideWindow],
            isDeleted: { _ in false },
            orderKey: { $0 == hex("11") ? reactionKey : nil }
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
            appState: AppState.test(),
            group: group(name: "")
        )
        let message = timelineRecord(messageIdHex: hex("44"), timelineAt: 1)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [message], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        seedOptimisticState(
            in: viewModel,
            deletedMessageIdHex: message.messageIdHex,
            reactionTargetMessageIdHex: message.messageIdHex,
            emoji: "🔥",
            sender: hex("22")
        )
        #expect(viewModel.isDeleted(message.messageIdHex))
        #expect(viewModel.reactions(for: message.messageIdHex) == [
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 1, mine: false)
        ])

        viewModel.timelineStore.resetOptimisticState()
        #expect(!viewModel.isDeleted(message.messageIdHex))
        #expect(viewModel.reactions(for: message.messageIdHex).isEmpty)
    }

    @Test func changingTimeZoneRegroupsTheSameMessagesAroundMidnight() throws {
        let model = ConversationViewModel(appState: AppState.test(), group: group(name: ""))
        let records = [82_740, 82_860].enumerated().map { index, time in
            timelineRecord(messageIdHex: hex(index == 0 ? "11" : "22"), timelineAt: UInt64(time))
        }
        model.applyTimelinePage(.init(messages: records, hasMoreBefore: false, hasMoreAfter: false), placement: .window)
        let first = try #require(model.timeline.first)
        let last = try #require(model.timeline.last)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(!model.timelineStore.messageClusterPresentation(for: first, calendar: calendar).endsCluster)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        #expect(model.timelineStore.messageClusterPresentation(for: first, calendar: calendar).endsCluster)
        #expect(model.timelineStore.messageClusterPresentation(for: last, calendar: calendar).startsCluster)
    }

    @Test func timelinePageHydratesReplyPreviewReactionsAndDeletedState() throws {
        let appState = AppState.test()
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

    @Test func deletionProvenanceChangesWithoutChangingTombstone() {
        let projection = ConversationDeletedMessageProjection()
        projection.setProjected(deleted: true, source: .unknown, forMessageId: "message")
        #expect(projection.rebuild())
        projection.setProjected(deleted: true, source: .admin, forMessageId: "message")
        #expect(projection.rebuild())
        #expect(projection.source(for: "message") == .admin)
        projection.removeProjected(forMessageId: "message")
        #expect(projection.rebuild())
        #expect(projection.source(for: "message") == .unknown)
        projection.insertOptimistic("pending")
        projection.rebuild()
        #expect(projection.source(for: "pending") == .unknown)
    }

    @Test func convergenceRetryPolicyRefreshesAmbiguousResultsAndStopsUnrecoverableGroups() {
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.AccountWorkerBusy
        ) == .retry)
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.AccountWorkerResponseTimedOut
        ) == .refreshBeforeRetry)
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: "group")
        ) == .stop)
    }

    @Test func replyResponseStaysBelowParentWhenSameTimestampWouldSortByIdFirst() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
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
            appState: AppState.test(),
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
            appState: AppState.test(),
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
            appState: AppState.test(),
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

    @Test func defaultTimingsReachTheAppAnalyticsRecorder() async throws {
        let appState = AppState.test()
        let stages = Mutex<[ProductTimingStage]>([])
        appState.productAnalytics.activateSink(timing: { stage, _, _ in stages.withLock { $0.append(stage) } }) { _ in }
        defer { appState.productAnalytics.replaceSink(nil) }
        let groupIdHex = hex("aa")
        // Built the way the app builds it, so the view model's default counts too.
        let viewModel = ConversationViewModel(appState: appState, group: group(name: "", id: groupIdHex))

        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [timelineRecord(messageIdHex: hex("e1"), groupIdHex: groupIdHex, timelineAt: 10)],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        try await eventually {
            stages.withLock { Set($0).isSuperset(of: [.timelineWindow, .timelineRebuild]) }
        }
    }

    @Test func liveProjectionUpdateMaintainsTimelineWithoutFullRebuild() throws {
        let groupIdHex = hex("aa")
        let stages = TimelineStageRecorder()
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "", id: groupIdHex),
            timelineTimings: stages.timings
        )
        let first = timelineRecord(messageIdHex: hex("e1"), groupIdHex: groupIdHex, timelineAt: 10)
        let second = timelineRecord(messageIdHex: hex("e2"), groupIdHex: groupIdHex, timelineAt: 20)
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [first], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let rebuildCount = stages.count(.timelineRebuild)
        #expect(rebuildCount > 0)

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
        #expect(stages.count(.timelineRebuild) == rebuildCount)
    }

    @Test func projectedOutgoingMessageReplacesMatchingPendingBubble() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
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
            appState: AppState.test(),
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
        // unresolved, so it keeps the sending indicator and convergence-retry path.
        #expect(status() == .sending)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).accessibilityLabel == L10n.string("Sending…"))
        #expect(viewModel.canRetryFailedSend(rowId: rowId))
        #expect(viewModel.canDiscardFailedSend(rowId: rowId))

        // Repeating the same nil-source projection must not reinterpret the
        // durable unresolved state as failure after reconciliation is complete.
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [durablyPending], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(status() == .sending)
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).accessibilityLabel == L10n.string("Sending…"))

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
        #expect(MessageFooterPresentation.value(for: try #require(status()), isFromMe: true).accessibilityLabel == L10n.string("Sent"))
        #expect(!viewModel.canRetryFailedSend(rowId: rowId))
    }

    @Test func definitivelyInvalidatedOwnRowRendersFailed() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
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

    @Test(.marmotRuntimeConcurrencyLimit)
    func unsuccessfulDurableRetryRestoresInvalidatedFailureOutsideRefreshedTail() async throws {
        var attempts = 0
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
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
    }

    @Test func durableRetryReportsUnavailableRuntime() async throws {
        let fixture = try durableRetryFixture(
            client: nil,
            invalidationStatus: "local_publish_failed",
            converge: { _, _, _ in unpublishedRetrySummary() }
        )

        await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

        #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
        #expect(fixture.viewModel.error == L10n.string("Send failed"))
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func offlineDurableRetryReportsOfflineWithoutRetrying() async throws {
        var retryCalls = 0
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
                invalidationStatus: "local_publish_failed",
                isOnline: { false },
                catchUp: { _ in retryCalls += 1 },
                converge: { _, _, _ in
                    retryCalls += 1
                    return unpublishedRetrySummary()
                }
            )

            await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)

            #expect(retryCalls == 0)
            #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
            #expect(fixture.viewModel.error == L10n.string("You're offline. Try again once you're connected."))
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func exhaustedDurableRetryKeepsNonInvalidatedRowSending() async throws {
        var attempts = 0
        var sleeps = 0
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
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
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func publishedDurableRetryMarksRowSentWhenRefreshedTailOmitsIt() async throws {
        let messageIdHex = hex("d1")
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
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
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func cancelledDurableRetryRestoresPriorFailure() async throws {
        var enteredRetrySleep = false
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
                invalidationStatus: "local_publish_failed",
                converge: { _, _, _ in
                    return unpublishedRetrySummary()
                },
                sleep: { _ in
                    enteredRetrySleep = true
                    try await parkUntilCancelled()
                }
            )
            let retryTask = Task { @MainActor in
                await fixture.viewModel.retryFailedSend(rowId: fixture.rowId)
            }
            try await eventually {
                enteredRetrySleep
            }

            retryTask.cancel()
            await retryTask.value

            #expect(status(of: fixture.rowId, in: fixture.viewModel) == .failed)
            #expect(fixture.viewModel.error == nil)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func cancelledDuringFinalRefreshRestoresPriorFailureWithoutError() async throws {
        var enteredFinalRefresh = false
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
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
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func authoritativeDeliveryDuringRetryIsNotOverwrittenByCleanup() async throws {
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
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
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
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func authoritativePendingRefreshDuringRetryIsNotOverwrittenByCleanup() async throws {
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
        try await withTestClient { client in
            let fixture = try durableRetryFixture(
                client: client,
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
    }

    @Test func successfulSendAckDoesNotFlashFailedWhileDeliveredProjectionCatchesUp() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let messageId = hex("b8")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
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
            appState: AppState.test(),
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
        viewModel.timelineStore.markFailed(tempId: tempId)

        // A failed text row is retryable and discardable.
        #expect(viewModel.canRetryFailedSend(rowId: rowId))

        // A legacy media row (the pending-media marker with no staged bytes)
        // can't be retried, but can still be discarded.
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
        viewModel.timelineStore.markFailed(tempId: mediaTempId)
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

    @Test func failedMediaSendRetriesWhileItsStagedBytesRemain() {
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "", id: groupIdHex)
        )
        let tempId = "retry-staged-media"
        let rowId = "msg:\(tempId)"
        let record = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: hex("11"),
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let draft = MediaDraftAttachment(fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([1, 2, 3]), dim: "1x1")
        viewModel.timelineStore.mediaProjections.setPending([draft.displayItem], forRowId: rowId)
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: record)
        viewModel.timelineStore.markFailed(tempId: tempId)

        #expect(viewModel.canRetryFailedSend(rowId: rowId))
        #expect(viewModel.canDiscardFailedSend(rowId: rowId))

        // Once the staged bytes are gone the row degrades to discard-only.
        viewModel.timelineStore.mediaProjections.removePending(forRowId: rowId)
        #expect(!viewModel.canRetryFailedSend(rowId: rowId))
        #expect(viewModel.canDiscardFailedSend(rowId: rowId))
    }

    @Test func failedMediaRetryResendsTheStagedAttachmentsWithTheirCaption() throws {
        let record = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: 10,
            receivedAt: 10
        )
        let photo = MediaDraftAttachment(
            fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([1, 2, 3]), dim: "4x3", thumbhash: "thumb"
        )
        let note = MediaDraftAttachment(
            fileName: "note.m4a", mediaType: "audio/mp4", data: Data([4, 5]), dim: nil,
            durationSeconds: 2, waveformSamples: [0.25, 0.5]
        )

        let retry = try #require(FailedSendRetry.payload(record: record, staged: [photo.displayItem, note.displayItem]))
        guard case .media(let attachments, let caption) = retry else {
            Issue.record("expected a media retry")
            return
        }
        #expect(caption == record.plaintext)
        #expect(attachments == [photo, note])
        #expect(attachments.map(\.data) == [photo.data, note.data])
        #expect(attachments.first?.thumbhash == photo.thumbhash)

        // An attachment whose bytes were dropped makes the whole send discard-only,
        // never a partial re-send.
        let evicted = MessageMediaAttachment(
            id: UUID().uuidString, reference: nil, fileName: "gone.jpg", mediaType: "image/jpeg", dim: nil, localData: nil
        )
        #expect(FailedSendRetry.payload(record: record, staged: [note.displayItem, evicted]) == nil)
    }

    @Test func projectedOutgoingMessageReplacesMatchingFailedPendingBubble() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
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
        viewModel.timelineStore.markFailed(tempId: tempId)

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
            appState: AppState.test(),
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
            appState: AppState.test(),
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
        viewModel.timelineStore.mediaProjections.setPending([attachment], forRowId: tempRowId)
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)

        // uploadMedia succeeded but returned no message id.
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: nil)

        // The transient row is recreated under the same id (no server id), and the
        // just-sent attachment must still resolve instead of vanishing.
        #expect(viewModel.timelineStore.mediaProjections.pending(forRowId: tempRowId) == [attachment])

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
            appState: AppState.test(),
            group: group(name: "", id: groupIdHex)
        )

        viewModel.timelineStore.mediaProjections.setPending([localAttachment], forRowId: tempRowId)
        viewModel.applyPendingOutgoingMessage(tempId: tempId, record: pending)
        viewModel.confirmSent(tempId: tempId, record: pending, messageId: messageId)
        #expect(viewModel.timelineStore.mediaProjections.pending(forRowId: realRowId) == [localAttachment])

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

        #expect(viewModel.timelineStore.mediaProjections.pending(forRowId: realRowId) == nil)
        let mediaRow = try #require(viewModel.timeline.first { $0.id == realRowId })
        #expect(viewModel.mediaItems(for: mediaRow).map(\.fileName) == ["canonical.jpg"])
    }

    @Test func projectedOutgoingMessageUsesExactTokenForIdenticalContent() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
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
            appState: AppState.test(),
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
        viewModel.timelineStore.mediaProjections.setPending([attachment], forRowId: mediaRowId)
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
        #expect(viewModel.timelineStore.mediaProjections.pending(forRowId: mediaRowId) == [attachment])
    }

    @MainActor
    @Test func projectedMediaSendReconcilesMediaPendingNotTextWithSameCaption() throws {
        let sender = hex("11")
        let groupIdHex = hex("aa")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
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
        viewModel.timelineStore.mediaProjections.setPending([attachment], forRowId: mediaRowId)
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
        #expect(viewModel.timelineStore.mediaProjections.pending(forRowId: mediaRowId) == nil)
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
