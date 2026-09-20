import Foundation
import MarmotKit

@MainActor
final class ConversationOpenPerformance: Hashable {
    nonisolated let id = UUID()
    nonisolated static func == (lhs: ConversationOpenPerformance, rhs: ConversationOpenPerformance) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private let now: () -> ContinuousClock.Instant
    private let start: ContinuousClock.Instant
    private var ticket: ProductAnalyticsRecorder.Ticket?
    private var awaitingAccountConsent = false
    private var deferredSamples: [(HostPerformanceOperationFfi, UInt64, HostPerformanceOutcomeFfi)] = []
    private var localPending = true
    private var composerPending = true

    init(start: ContinuousClock.Instant, ticket: ProductAnalyticsRecorder.Ticket?,
         now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        self.start = start
        self.ticket = ticket
    }

    func rendered(local: Bool, composer: Bool?, recorder: ProductAnalyticsRecorder) {
        if local, localPending {
            localPending = false
            record(.conversationLocalVisible, .success, recorder)
        }
        if let composer, composerPending {
            composerPending = false
            record(.conversationComposerReady, composer ? .success : .unavailable, recorder)
        }
    }

    func finish(_ outcome: HostPerformanceOutcomeFfi, recorder: ProductAnalyticsRecorder) {
        if localPending { record(.conversationLocalVisible, outcome, recorder) }
        if composerPending { record(.conversationComposerReady, outcome, recorder) }
        localPending = false
        composerPending = false
    }

    // Account changes rotate product context, but diagnostics consent is device-wide.
    // Keep at most these two completed samples until that same consent is re-read.
    func accountContextWillChange() { awaitingAccountConsent = true }

    func accountContextReady(ticket nextTicket: ProductAnalyticsRecorder.Ticket?, recorder: ProductAnalyticsRecorder) {
        guard awaitingAccountConsent else { return }
        awaitingAccountConsent = false
        if ticket != nil { ticket = nextTicket }
        for (operation, milliseconds, outcome) in deferredSamples {
            recorder.recordImmediatePerformance(operation, milliseconds: milliseconds, ticket: ticket, outcome: outcome)
        }
        deferredSamples = []
    }

    func discardForConsentChange() {
        ticket = nil
        deferredSamples = []
        awaitingAccountConsent = false
        localPending = false
        composerPending = false
    }

    private func record(_ operation: HostPerformanceOperationFfi, _ outcome: HostPerformanceOutcomeFfi,
                        _ recorder: ProductAnalyticsRecorder) {
        let elapsed = start.duration(to: now()).components
        let milliseconds = max(0, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        if awaitingAccountConsent {
            deferredSamples.append((operation, UInt64(milliseconds), outcome))
        } else {
            recorder.recordImmediatePerformance(operation, milliseconds: UInt64(milliseconds), ticket: ticket, outcome: outcome)
        }
    }
}

// A local-only window deliberately has canSend=false until epoch/authority arrives.
extension ConversationOpenPerformance {
    static func localContentVisible(height: CGFloat, hasWindow: Bool, loading: Bool,
                                    empty: Bool, positionSettled: Bool) -> Bool {
        height > 0 && hasWindow && (empty ? !loading : positionSettled)
    }

    static func composerOutcome(epoch: UInt64?, canSend: Bool?, blocked: Bool,
                                composerPresented: Bool, enabled: Bool) -> Bool? {
        guard composerPresented, let canSend else { return nil }
        if blocked { return false }
        guard epoch != nil else { return nil }
        if !canSend { return false }
        return enabled ? true : nil
    }
}

nonisolated enum ConversationLiveAppend {
    // No sender timestamps: only a new suffix of an already loaded live tail.
    static func ids(previous: [String], next: [String], wasAtTail: Bool, isAtTail: Bool) -> Set<String> {
        guard wasAtTail, isAtTail else { return [] }
        if previous.isEmpty { return Set(next) }
        guard let last = previous.last, let index = next.lastIndex(of: last) else { return [] }
        return Set(next.dropFirst(index + 1)).subtracting(previous)
    }
}
