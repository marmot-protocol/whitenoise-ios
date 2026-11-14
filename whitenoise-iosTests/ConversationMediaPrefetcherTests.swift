import Foundation
import Testing
@testable import whitenoise_ios

/// Look-ahead requests must stay behind the attachments on screen: bounded,
/// droppable until they start, and never repeated.
@MainActor
@Suite struct ConversationMediaPrefetcherTests {
    /// Holds every load open until the test releases it.
    @MainActor
    private final class Loads {
        private(set) var started: [String] = []
        private(set) var active = 0
        private(set) var peak = 0
        private(set) var cancelled: Set<String> = []
        private var held: [CheckedContinuation<Void, Never>] = []

        func load(_ media: MessageMediaAttachment) async {
            started.append(media.id)
            active += 1
            peak = max(peak, active)
            let id = media.id
            await withTaskCancellationHandler {
                await withCheckedContinuation { held.append($0) }
            } onCancel: {
                Task { @MainActor in self.cancelled.insert(id) }
            }
            active -= 1
        }

        func releaseAll() {
            let releasing = held
            held = []
            releasing.forEach { $0.resume() }
        }
    }

    private func image(_ id: String) -> MessageMediaAttachment {
        MessageMediaAttachment(id: id, reference: nil, fileName: "\(id).jpg", mediaType: "image/jpeg",
                               dim: nil, localData: nil)
    }

    @Test func lookAheadNeverRunsMoreLoadsThanItsShare() async throws {
        let loads = Loads()
        let prefetcher = ConversationMediaPrefetcher { await loads.load($0) }
        let ids = (0..<6).map { "row:\($0)" }

        prefetcher.update(candidates: ids.map(image))
        try await eventually {
            loads.releaseAll()
            return loads.started.count == ids.count && loads.active == 0
        }

        #expect(loads.started == ids)
        #expect(loads.peak <= ConversationMediaPrefetcher.concurrentLoads)
    }

    @Test func rowsScrolledAwayFromAreDroppedBeforeTheyStart() async throws {
        let loads = Loads()
        let prefetcher = ConversationMediaPrefetcher { await loads.load($0) }

        prefetcher.update(candidates: ["a", "b", "c", "d"].map(image))
        try await eventually { loads.active == ConversationMediaPrefetcher.concurrentLoads }
        prefetcher.update(candidates: [image("e")])
        try await eventually {
            loads.releaseAll()
            return loads.started.contains("e") && loads.active == 0
        }

        #expect(loads.started == ["a", "b", "e"])
    }

    @Test func stoppingCancelsLoadsInFlightAndStartsNoMore() async throws {
        let loads = Loads()
        let prefetcher = ConversationMediaPrefetcher { await loads.load($0) }

        prefetcher.update(candidates: ["a", "b", "c"].map(image))
        try await eventually { loads.active == ConversationMediaPrefetcher.concurrentLoads }
        async let stopped: Void = prefetcher.cancelAndDrain()
        try await eventually { loads.cancelled == ["a", "b"] }
        try await eventually {
            loads.releaseAll()
            return loads.active == 0
        }
        await stopped

        #expect(loads.started == ["a", "b"])
    }

    @Test func aClosedConversationCancelsItsLoadsInFlight() async throws {
        let loads = Loads()
        var prefetcher: ConversationMediaPrefetcher? = ConversationMediaPrefetcher { await loads.load($0) }

        prefetcher?.update(candidates: ["a", "b", "c"].map(image))
        try await eventually { loads.active == ConversationMediaPrefetcher.concurrentLoads }
        prefetcher = nil
        try await eventually { loads.cancelled == ["a", "b"] }
        try await eventually {
            loads.releaseAll()
            return loads.active == 0
        }

        #expect(loads.started == ["a", "b"])
    }

    @Test func anAttachmentIsRequestedOnce() async throws {
        let loads = Loads()
        let prefetcher = ConversationMediaPrefetcher { await loads.load($0) }

        prefetcher.update(candidates: [image("a")])
        try await eventually {
            loads.releaseAll()
            return loads.started == ["a"] && loads.active == 0
        }
        prefetcher.update(candidates: [image("a"), image("b")])
        try await eventually {
            loads.releaseAll()
            return loads.started.contains("b") && loads.active == 0
        }

        #expect(loads.started == ["a", "b"])
    }

    @Test func lookAheadTakesTheNearestRowsOutsideTheViewport() {
        let visible = 10...14
        let indices = TimelineMediaLookahead.rowIndices(rowCount: 18, visible: visible, reach: 5)

        #expect(indices.allSatisfy { !visible.contains($0) && (0..<18).contains($0) })
        #expect(Set(indices) == Set(5...9).union(15...17))
        let distances = indices.map { $0 < visible.lowerBound ? visible.lowerBound - $0 : $0 - visible.upperBound }
        #expect(distances == distances.sorted())
    }

    @Test func aBiggerDeviceNeverGetsASmallerThumbnailBudget() {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        let budgets = [1, 2, 4, 8, 16, 64].map { MediaThumbnailCacheBudget.bytes(physicalMemory: $0 * gigabyte) }

        #expect(budgets == budgets.sorted())
        #expect(budgets.first! < budgets.last!)
        // The cache must leave most of a device's memory to the rest of the app.
        #expect(zip([1, 2, 4, 8, 16, 64], budgets).allSatisfy { UInt64($1) <= UInt64($0) * gigabyte / 4 })
    }
}
