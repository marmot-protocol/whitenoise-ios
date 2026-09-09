import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@MainActor
struct Marmot0920IntegrationTests {
    @Test func presentationCursorAcceptsUnreadUpdatesWithoutTitleRevisionChanges() {
        let initial = update(generation: "one", sequence: 0)
        var cursor = PresentedChatListCursor(initial: initial)
        let accepted1 = cursor.accept(update(generation: "one", sequence: 1))
        #expect(accepted1)
        let accepted2 = !cursor.accept(update(generation: "one", sequence: 1))
        #expect(accepted2)
        let accepted3 = !cursor.accept(update(generation: "old", sequence: 50))
        #expect(accepted3)
        #expect(cursor.requiresReopen(update(generation: "old", sequence: 50)))
        #expect(cursor.requiresReopen(update(generation: "old", sequence: 50, epoch: 2)))
        let replacedStore = update(generation: "one", sequence: 2, epoch: 2)
        #expect(cursor.requiresReopen(replacedStore))
        let accepted4 = !cursor.accept(replacedStore)
        #expect(accepted4)
    }

    @Test func rejoinDecisionIsBoundToTheExactDisplayedInvitation() {
        let offer = GroupRejoinInvitationFfi(welcomeIdHex: "welcome", welcomerAccountIdHex: "author", epoch: 7, localStateToken: "state")
        let status = GroupRecoveryStatusFfi(groupIdHex: "group", automaticRecoveryFailed: true, pendingReinvites: 1,
                                            failedReinvites: 0, rejoinInvitations: [offer])
        #expect(GroupRecoveryModel.containsDisplayedOffer(offer, in: status))
        var changed = offer
        changed.localStateToken = "new state"
        #expect(!GroupRecoveryModel.containsDisplayedOffer(changed, in: status))
        changed = offer; changed.welcomerAccountIdHex = "other author"
        #expect(!GroupRecoveryModel.containsDisplayedOffer(changed, in: status))
        changed = offer; changed.welcomeIdHex = "other welcome"
        #expect(!GroupRecoveryModel.containsDisplayedOffer(changed, in: status))
        changed = offer; changed.epoch += 1
        #expect(!GroupRecoveryModel.containsDisplayedOffer(changed, in: status))
    }

    @Test func visibilityTimingNeedsConsentAndLayoutAndSurvivesLocalIDReplacement() async throws {
        var now: UInt64 = 1_000_000
        let tracker = MessageVisibilityPerformance(capacity: 2, now: { now })
        let recorder = ProductAnalyticsRecorder()
        tracker.begin(rowID: "before-consent", operation: .outboundMessageVisible, ticket: recorder.ticket())
        let durations = Mutex<[UInt64]>([])
        recorder.activateSink(performance: { _, duration in durations.withLock { $0.append(duration) } }) { _ in }
        #expect(tracker.takeVisible(["before-consent", "history"]).isEmpty)
        tracker.begin(rowID: "local", operation: .outboundMessageVisible, ticket: recorder.ticket())
        now += 5_000_000
        tracker.begin(rowID: "local", operation: .outboundMessageVisible, ticket: recorder.ticket())
        tracker.move(from: "local", to: "durable")
        let sample = try #require(tracker.takeVisible(["durable"]).first)
        #expect(sample.milliseconds == 5)
        #expect(tracker.takeVisible(["durable"]).isEmpty)
        await recorder.recordPerformance(sample.operation, milliseconds: sample.milliseconds, ticket: sample.ticket)?.value
        #expect(durations.withLock { $0 } == [5])
        tracker.begin(rowID: "late", operation: .inboundMessageVisible, ticket: recorder.ticket())
        recorder.replaceSink(nil)
        recorder.activateSink(performance: { _, duration in durations.withLock { $0.append(duration) } }) { _ in }
        let stale = try #require(tracker.takeVisible(["late"]).first)
        #expect(recorder.recordPerformance(stale.operation, milliseconds: stale.milliseconds, ticket: stale.ticket) == nil)
        #expect(durations.withLock { $0 } == [5])
    }

    @Test func visibilityObservationsStayBoundedAndResetWithTheConversation() {
        var now: UInt64 = 0
        let tracker = MessageVisibilityPerformance(capacity: 2, now: { now })
        let recorder = ProductAnalyticsRecorder()
        recorder.activateSink { _ in }
        for row in ["one", "two", "three"] {
            now += 1
            tracker.begin(rowID: row, operation: .inboundMessageVisible, ticket: recorder.ticket())
        }
        #expect(tracker.takeVisible(["one"]).isEmpty)
        #expect(tracker.takeVisible(["two"]).count == 1)
        tracker.reset()
        #expect(tracker.takeVisible(["three"]).isEmpty)
    }

    @Test func visibilitySamplesExpireBeforeScrollBackCanRecordThem() {
        var now: UInt64 = 0
        let tracker = MessageVisibilityPerformance(now: { now })
        let recorder = ProductAnalyticsRecorder()
        recorder.activateSink { _ in }
        tracker.begin(rowID: "expired", operation: .inboundMessageVisible, ticket: recorder.ticket())
        now = 5_000_000_001
        #expect(tracker.takeVisible(["expired"]).isEmpty)
        tracker.begin(rowID: "visible", operation: .outboundMessageVisible, ticket: recorder.ticket())
        now += 5_000_000_000
        #expect(tracker.takeVisible(["visible"]).first?.milliseconds == 5_000)
        tracker.begin(rowID: "reused", operation: .inboundMessageVisible, ticket: recorder.ticket())
        now += 5_000_000_001
        tracker.begin(rowID: "reused", operation: .inboundMessageVisible, ticket: recorder.ticket())
        #expect(tracker.takeVisible(["reused"]).first?.milliseconds == 0)
    }

    private func update(generation: String, sequence: UInt64, epoch: UInt8 = 1) -> PresentedChatListUpdateFfi {
        PresentedChatListUpdateFfi(subscriptionGeneration: generation, sequence: sequence,
            snapshot: PresentedChatListSnapshotFfi(rows: [],
                presentationVersion: PresentationVersionFfi(accountStoreEpoch: Data([epoch]), revision: 10)))
    }
}
