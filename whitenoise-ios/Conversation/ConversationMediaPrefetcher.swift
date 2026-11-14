import Foundation

/// Which rows just outside the viewport have their images requested early.
nonisolated enum TimelineMediaLookahead {
    /// Rows on each side of the visible range.
    static let reach = 12

    /// Row indices beyond the visible range, nearest first.
    static func rowIndices(rowCount: Int, visible: ClosedRange<Int>, reach: Int = reach) -> [Int] {
        guard rowCount > 0, reach > 0 else { return [] }
        var indices: [Int] = []
        for distance in 1...reach {
            let before = visible.lowerBound - distance
            let after = visible.upperBound + distance
            if before >= 0, before < rowCount { indices.append(before) }
            if after >= 0, after < rowCount { indices.append(after) }
        }
        return indices
    }
}

/// Requests attachments the reader is about to reach, so their bytes are on the
/// device before the row is. Each attachment is requested once: a failure stays
/// for the row's own load to report, as it would without the look-ahead.
@MainActor
final class ConversationMediaPrefetcher {
    typealias Load = @MainActor (MessageMediaAttachment) async -> Void

    /// Leaves MDK download slots free for the attachments already on screen.
    static let concurrentLoads = 2

    private let load: Load
    private var waiting: [MessageMediaAttachment] = []
    private var requested: Set<String> = []
    private var running: [String: Task<Void, Never>] = [:]

    init(load: @escaping Load) {
        self.load = load
    }

    /// Replaces the waiting list, so rows the reader has scrolled away from are
    /// dropped before their request starts.
    func update(candidates: [MessageMediaAttachment]) {
        waiting = candidates.filter { !requested.contains($0.id) }
        startWaiting()
    }

    /// A load in flight waits on MDK, so stopping cancels it and waits for it to end.
    func cancelAndDrain() async {
        waiting = []
        let loads = Array(running.values)
        loads.forEach { $0.cancel() }
        for load in loads { await load.value }
    }

    private func startWaiting() {
        while running.count < Self.concurrentLoads, !waiting.isEmpty {
            let media = waiting.removeFirst()
            guard requested.insert(media.id).inserted else { continue }
            running[media.id] = Task { @MainActor [weak self, load] in
                await load(media)
                self?.running[media.id] = nil
                self?.startWaiting()
            }
        }
    }
}
