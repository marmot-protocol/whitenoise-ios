import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// #431 — streaming-debug rows must be bounded to a recent window so a
/// long-lived stream can't accumulate `streamDebugTimelineItems` (and re-walk
/// them on every MainActor rebuild) for the conversation's lifetime.
@MainActor
struct StreamDebugTimelineWindowTests {
    private func debugRow(sequence: UInt64, timestamp: UInt64) -> TimelineItem {
        TimelineItem.streamDebugEvent(
            id: "dbg:stream:s1:\(timestamp):\(String(format: "%010llu", sequence))",
            streamId: "s1",
            eventKind: "chunk",
            detail: "n=\(sequence)",
            timestamp: timestamp
        )
    }

    @Test func retainEvictsOldestBeyondLimit() {
        var items: [String: TimelineItem] = [:]
        var evictedAll: [String] = []
        for index in 0..<5 {
            let row = debugRow(sequence: UInt64(index), timestamp: UInt64(index))
            evictedAll += TimelineStore.retainStreamDebugTimelineItems(&items, appending: row, limit: 3)
        }

        #expect(items.count == 3)
        let retainedSequences = items.values
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.timestamp)
        #expect(retainedSequences == [2, 3, 4])
        // The two oldest rows are evicted in order.
        #expect(evictedAll == [
            debugRow(sequence: 0, timestamp: 0).id,
            debugRow(sequence: 1, timestamp: 1).id,
        ])
    }

    @Test func retainKeepsAllWithinLimit() {
        var items: [String: TimelineItem] = [:]
        for index in 0..<3 {
            let evicted = TimelineStore.retainStreamDebugTimelineItems(
                &items,
                appending: debugRow(sequence: UInt64(index), timestamp: UInt64(index)),
                limit: 8
            )
            #expect(evicted.isEmpty)
        }
        #expect(items.count == 3)
    }

    @Test func retainBreaksSameTimestampTiesByMonotonicId() {
        var items: [String: TimelineItem] = [:]
        // All in the same wall-clock second; the zero-padded sequence in the id
        // is the tiebreaker, so the lowest sequence is evicted first.
        for sequence in 0..<4 {
            _ = TimelineStore.retainStreamDebugTimelineItems(
                &items,
                appending: debugRow(sequence: UInt64(sequence), timestamp: 7),
                limit: 2
            )
        }
        #expect(Set(items.keys) == Set([
            debugRow(sequence: 2, timestamp: 7).id,
            debugRow(sequence: 3, timestamp: 7).id,
        ]))
    }

    @Test func retainWithZeroLimitEvictsEverything() {
        var items: [String: TimelineItem] = [
            debugRow(sequence: 0, timestamp: 0).id: debugRow(sequence: 0, timestamp: 0)
        ]
        let evicted = TimelineStore.retainStreamDebugTimelineItems(
            &items,
            appending: debugRow(sequence: 1, timestamp: 1),
            limit: 0
        )
        #expect(items.isEmpty)
        #expect(Set(evicted) == Set([
            debugRow(sequence: 0, timestamp: 0).id,
            debugRow(sequence: 1, timestamp: 1).id,
        ]))
    }

    @Test func appendingDebugRowsBoundsBackingMapAndPublishedTimeline() throws {
        let store = TimelineStore(
            appState: AppState(client: try MarmotClient.testClient()),
            groupIdHex: String(repeating: "bb", count: 32)
        )
        let cap = TimelineStore.maxStreamDebugTimelineItems

        for index in 0..<(cap + 50) {
            store.streamAppendDebugRow(debugRow(sequence: UInt64(index), timestamp: UInt64(index)))
        }

        #expect(store.streamDebugTimelineItemCountForTesting == cap)
        let debugRowCount = store.timeline.filter { item in
            if case .streamDebugEvent = item.kind { return true }
            return false
        }.count
        #expect(debugRowCount == cap)
        // The earliest debug row is no longer in the published timeline.
        let firstId = debugRow(sequence: 0, timestamp: 0).id
        #expect(!store.timeline.contains { $0.id == firstId })
    }
}
