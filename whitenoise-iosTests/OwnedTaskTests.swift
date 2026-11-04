import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct OwnedTaskTests {
    @Test func aFinishingTaskClearsTheSlotOnlyWhileItOwnsIt() {
        var slot = OwnedTask()
        let stale = UUID()
        let current = UUID()

        slot.install(stale, Task {})
        slot.install(current, Task {})
        slot.finish(stale)

        #expect(slot.isActive)
        #expect(slot.owns(current))
        #expect(!slot.owns(stale))

        slot.finish(current)

        #expect(!slot.isActive)
        #expect(!slot.owns(current))
    }

    @Test func installingATaskCancelsTheOneItReplaces() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let replaced = Task { for await _ in stream {} }
        var slot = OwnedTask()

        slot.install(UUID(), replaced)
        #expect(!replaced.isCancelled)
        slot.install(UUID(), Task {})

        #expect(replaced.isCancelled)
    }

    @Test func cancelStopsTheTaskAndEmptiesTheSlot() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let task = Task { for await _ in stream {} }
        let id = UUID()
        var slot = OwnedTask()

        slot.install(id, task)
        slot.cancel()

        #expect(task.isCancelled)
        #expect(!slot.isActive)
        #expect(!slot.owns(id))
    }
}
