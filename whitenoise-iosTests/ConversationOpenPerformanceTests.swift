import Foundation
import Synchronization
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct ConversationOpenPerformanceTests {
    private nonisolated struct Sample: Equatable, Sendable {
        let operation: HostPerformanceOperationFfi
        let milliseconds: UInt64
        let outcome: HostPerformanceOutcomeFfi
    }

    private nonisolated final class Samples: Sendable {
        private let values = Mutex<[Sample]>([])
        // Concrete accessors rather than a forwarded generic closure: `Mutex`
        // takes `(inout sending Value) -> sending Result`, which a generic
        // closure value cannot be converted to.
        func append(_ sample: Sample) { values.withLock { $0.append(sample) } }
        var snapshot: [Sample] { values.withLock { $0 } }
    }

    private func recorder(_ samples: Samples) -> ProductAnalyticsRecorder {
        let recorder = ProductAnalyticsRecorder()
        recorder.activateSink(performance: { operation, milliseconds, outcome in
            samples.append(Sample(operation: operation, milliseconds: milliseconds, outcome: outcome))
        }) { _ in }
        return recorder
    }

    @Test func localContentPrecedesAuthorityAndBothUseNavigationStart() {
        let samples = Samples()
        let recorder = recorder(samples)
        let start = ContinuousClock.now
        var now = start.advanced(by: .milliseconds(450))
        let attempt = ConversationOpenPerformance(start: start, ticket: recorder.ticket(), now: { now })
        attempt.rendered(local: true, composer: nil, recorder: recorder)
        #expect(ConversationOpenPerformance.composerOutcome(epoch: nil, canSend: false,
            blocked: false, composerPresented: true, enabled: false) == nil)
        now = start.advanced(by: .seconds(45))
        let ready = ConversationOpenPerformance.composerOutcome(epoch: 0, canSend: true,
            blocked: false, composerPresented: true, enabled: true)
        attempt.rendered(local: true, composer: ready, recorder: recorder)
        attempt.rendered(local: true, composer: ready, recorder: recorder)
        #expect(samples.snapshot == [
            Sample(operation: .conversationLocalVisible, milliseconds: 450, outcome: .success),
            Sample(operation: .conversationComposerReady, milliseconds: 45000, outcome: .success)
        ])
    }

    @Test func emptyContentCountsButLoadingAndUnsettledContentDoNot() {
        #expect(ConversationOpenPerformance.localContentVisible(height: 200, hasWindow: true,
            loading: false, empty: true, positionSettled: false))
        #expect(!ConversationOpenPerformance.localContentVisible(height: 200, hasWindow: false,
            loading: false, empty: true, positionSettled: false))
        #expect(!ConversationOpenPerformance.localContentVisible(height: 200, hasWindow: true,
            loading: true, empty: true, positionSettled: false))
        #expect(!ConversationOpenPerformance.localContentVisible(height: 200, hasWindow: true,
            loading: false, empty: false, positionSettled: false))
    }

    @Test func authoritativeUnavailableIsTerminalAndHiddenComposerWaits() {
        #expect(ConversationOpenPerformance.composerOutcome(epoch: 1, canSend: false,
            blocked: false, composerPresented: true, enabled: false) == false)
        #expect(ConversationOpenPerformance.composerOutcome(epoch: 1, canSend: true,
            blocked: false, composerPresented: false, enabled: true) == nil)
        let samples = Samples()
        let recorder = recorder(samples)
        let attempt = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        attempt.rendered(local: false, composer: false, recorder: recorder)
        attempt.rendered(local: true, composer: true, recorder: recorder)
        #expect(samples.snapshot.filter { $0.operation == .conversationComposerReady }.map(\.outcome) == [.unavailable])
    }

    @Test(arguments: [HostPerformanceOutcomeFfi.failure, .cancelled, .timeout])
    func terminalOutcomesOnlyFinishUnfinishedMilestones(outcome: HostPerformanceOutcomeFfi) {
        let samples = Samples()
        let recorder = recorder(samples)
        let attempt = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        attempt.rendered(local: true, composer: nil, recorder: recorder)
        attempt.finish(outcome, recorder: recorder)
        attempt.finish(.cancelled, recorder: recorder)
        attempt.rendered(local: true, composer: true, recorder: recorder)
        #expect(samples.snapshot.map(\.outcome) == [.success, outcome])
    }

    @Test func replacementAndLateCallbacksCannotCompleteNewAttempt() {
        let state = AppState(client: nil, notifications: .shared)
        let samples = Samples()
        state.productAnalytics.activateSink(performance: { op, ms, outcome in
            samples.append(Sample(operation: op, milliseconds: ms, outcome: outcome))
        }) { _ in }
        let old = state.beginConversationOpenPerformance()
        let next = state.beginConversationOpenPerformance()
        old.rendered(local: true, composer: true, recorder: state.productAnalytics)
        next.rendered(local: true, composer: true, recorder: state.productAnalytics)
        #expect(samples.snapshot.map(\.outcome) == [.cancelled, .cancelled, .success, .success])
    }

    @Test func navigationRetriesReuseAttemptAndExplicitRetryGetsNewOne() {
        let recorder = ProductAnalyticsRecorder()
        let navigation = NavigationState()
        let attempt = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        _ = navigation.presentChat(groupIdHex: "group", performance: attempt)
        let first = ChatsListView.ChatNavigationTarget(groupIdHex: "group", performance: navigation.pendingChatPerformance)
        let retry = ChatsListView.ChatNavigationTarget(groupIdHex: "group", performance: navigation.pendingChatPerformance)
        #expect(first == retry)
        navigation.clearPendingChat()
        #expect(first.performance === attempt)
        let explicit = ChatsListView.ChatNavigationTarget(groupIdHex: "group",
            performance: ConversationOpenPerformance(start: .now, ticket: recorder.ticket()))
        #expect(first != explicit)
    }

    @Test func cancellationBeforeRuntimeInvalidationIsRecordedAndLateCallbacksAreIgnored() {
        let samples = Samples()
        let recorder = recorder(samples)
        let attempt = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        attempt.finish(.cancelled, recorder: recorder)
        recorder.replaceSink(nil)
        recorder.activateSink(performance: { op, ms, outcome in
            samples.append(Sample(operation: op, milliseconds: ms, outcome: outcome))
        }) { _ in }
        attempt.rendered(local: true, composer: true, recorder: recorder)
        #expect(samples.snapshot.map(\.outcome) == [.cancelled, .cancelled])
    }

    @Test func disabledOrRevokedConsentNeverReports() {
        let samples = Samples()
        let recorder = ProductAnalyticsRecorder()
        let disabled = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        recorder.activateSink(performance: { op, ms, outcome in
            samples.append(Sample(operation: op, milliseconds: ms, outcome: outcome))
        }) { _ in }
        disabled.rendered(local: true, composer: true, recorder: recorder)
        let revoked = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        recorder.replaceSink(nil)
        revoked.finish(.cancelled, recorder: recorder)
        #expect(samples.snapshot.isEmpty)
    }
    @Test func accountContextRotationKeepsElapsedTimeAndDoesNotDuplicate() {
        let samples = Samples()
        let recorder = recorder(samples)
        let start = ContinuousClock.now
        let attempt = ConversationOpenPerformance(start: start, ticket: recorder.ticket(),
            now: { start.advanced(by: .milliseconds(900)) })
        attempt.accountContextWillChange()
        recorder.replaceSink(nil)
        attempt.rendered(local: true, composer: true, recorder: recorder)
        #expect(samples.snapshot.isEmpty)
        recorder.activateSink(performance: { op, ms, outcome in
            samples.append(Sample(operation: op, milliseconds: ms, outcome: outcome))
        }) { _ in }
        attempt.accountContextReady(ticket: recorder.ticket(), recorder: recorder)
        attempt.accountContextReady(ticket: recorder.ticket(), recorder: recorder)
        #expect(samples.snapshot.map(\.milliseconds) == [900, 900])
    }

    @Test func consentChangeDiscardsDeferredSamples() {
        let samples = Samples()
        let recorder = recorder(samples)
        let attempt = ConversationOpenPerformance(start: .now, ticket: recorder.ticket())
        attempt.accountContextWillChange()
        attempt.rendered(local: true, composer: true, recorder: recorder)
        attempt.discardForConsentChange()
        attempt.accountContextReady(ticket: recorder.ticket(), recorder: recorder)
        #expect(samples.snapshot.isEmpty)
    }

    @Test func inboundAppendExcludesHistoryReplacementAndOlderPaging() {
        #expect(ConversationLiveAppend.ids(previous: ["a", "b"], next: ["a", "b", "c"],
            wasAtTail: true, isAtTail: true) == ["c"])
        #expect(ConversationLiveAppend.ids(previous: ["a", "b"], next: ["older", "a", "b"],
            wasAtTail: true, isAtTail: true).isEmpty)
        #expect(ConversationLiveAppend.ids(previous: ["a"], next: ["a", "b"],
            wasAtTail: false, isAtTail: true).isEmpty)
        #expect(ConversationLiveAppend.ids(previous: ["a"], next: ["b", "c"],
            wasAtTail: true, isAtTail: true).isEmpty)
    }

}
