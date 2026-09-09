import Foundation
import MarmotKit

/// Only live observations awaiting layout, never a delivery queue or session store.
@MainActor
final class MessageVisibilityPerformance {
    struct Sample {
        let operation: HostPerformanceOperationFfi
        let milliseconds: UInt64
        let ticket: ProductAnalyticsRecorder.Ticket
    }
    private struct Pending {
        let operation: HostPerformanceOperationFfi
        let start: UInt64
        let ticket: ProductAnalyticsRecorder.Ticket
    }
    private let now: () -> UInt64
    private let capacity: Int
    private let maximumAgeNanoseconds: UInt64
    private var pending: [String: Pending] = [:]

    init(capacity: Int = 128, maximumAgeNanoseconds: UInt64 = 5_000_000_000,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.capacity = max(1, capacity)
        self.maximumAgeNanoseconds = maximumAgeNanoseconds
        self.now = now
    }

    func begin(rowID: String, operation: HostPerformanceOperationFfi, ticket: ProductAnalyticsRecorder.Ticket?) {
        guard let ticket else { return }
        let start = now()
        pruneExpired(at: start)
        guard pending[rowID] == nil else { return }
        if pending.count >= capacity, let oldest = pending.min(by: { $0.value.start < $1.value.start })?.key {
            pending.removeValue(forKey: oldest)
        }
        pending[rowID] = Pending(operation: operation, start: start, ticket: ticket)
    }

    func move(from oldID: String, to newID: String) {
        guard oldID != newID, let value = pending.removeValue(forKey: oldID) else { return }
        if pending[newID] == nil { pending[newID] = value }
    }

    func takeVisible(_ rowIDs: Set<String>) -> [Sample] {
        let end = now()
        pruneExpired(at: end)
        return rowIDs.compactMap { rowID in
            guard let value = pending.removeValue(forKey: rowID), end >= value.start else { return nil }
            return Sample(operation: value.operation, milliseconds: (end - value.start) / 1_000_000, ticket: value.ticket)
        }
    }

    func reset() { pending.removeAll() }

    private func pruneExpired(at time: UInt64) {
        pending = pending.filter { time >= $0.value.start && time - $0.value.start <= maximumAgeNanoseconds }
    }
}
