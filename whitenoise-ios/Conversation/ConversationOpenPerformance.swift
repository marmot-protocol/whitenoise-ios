import Foundation
import MarmotKit

@MainActor
final class ConversationOpenPerformance {
    private let start: ContinuousClock.Instant
    private let ticket: ProductAnalyticsRecorder.Ticket?
    private var localPending = true
    private var composerPending = true

    init(start: ContinuousClock.Instant, ticket: ProductAnalyticsRecorder.Ticket?) {
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

    private func record(_ operation: HostPerformanceOperationFfi, _ outcome: HostPerformanceOutcomeFfi,
                        _ recorder: ProductAnalyticsRecorder) {
        let elapsed = start.duration(to: .now).components
        let milliseconds = max(0, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        recorder.recordPerformance(operation, milliseconds: UInt64(milliseconds), ticket: ticket, outcome: outcome)
    }
}
