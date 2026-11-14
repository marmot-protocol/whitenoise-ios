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
/// device before the row is. An attachment MDK was asked for is not asked for
/// again until look-ahead is stopped: a failure stays for the row's own load
/// to report, as it would without the look-ahead.
@MainActor
final class ConversationMediaPrefetcher {
    /// Returns false when MDK could not be asked yet.
    typealias Load = @MainActor (MessageMediaAttachment) async -> Bool

    /// Leaves MDK download slots free for the attachments already on screen.
    static let concurrentLoads = 2

    private let load: Load
    private var waiting: [MessageMediaAttachment] = []
    /// Asked of MDK since look-ahead was last stopped.
    private var requested: Set<String> = []
    /// The load that counts for each attachment being asked for.
    private var running: [String: UUID] = [:]
    /// Every load still calling MDK, cancelled ones included.
    private var loads: [UUID: Task<Void, Never>] = [:]

    init(load: @escaping Load) {
        self.load = load
    }

    /// Replaces the waiting list, so rows the reader has scrolled away from are
    /// dropped before their request starts.
    func update(candidates: [MessageMediaAttachment]) {
        waiting = candidates.filter { isUnrequested($0) }
        startWaiting()
    }

    isolated deinit {
        cancel()
    }

    /// Stops look-ahead: nothing waiting starts, and loads in flight, which
    /// wait on MDK, are cancelled. The runtime may be replaced after a stop,
    /// taking its downloads with it, so everything can be asked for again.
    func cancel() {
        waiting = []
        loads.values.forEach { $0.cancel() }
        running = [:]
        requested = []
    }

    /// Cancels, then waits until no load is still calling MDK, including
    /// loads an earlier stop cancelled.
    func cancelAndDrain() async {
        cancel()
        for load in Array(loads.values) { await load.value }
    }

    private func startWaiting() {
        while running.count < Self.concurrentLoads, !waiting.isEmpty {
            let media = waiting.removeFirst()
            guard isUnrequested(media) else { continue }
            let token = UUID()
            running[media.id] = token
            loads[token] = Task { @MainActor [weak self, load] in
                let asked = await load(media)
                guard let self else { return }
                loads[token] = nil
                // A stop has already let go of this load.
                guard running[media.id] == token else { return }
                running[media.id] = nil
                if asked { requested.insert(media.id) }
                startWaiting()
            }
        }
    }

    private func isUnrequested(_ media: MessageMediaAttachment) -> Bool {
        !requested.contains(media.id) && running[media.id] == nil
    }
}
