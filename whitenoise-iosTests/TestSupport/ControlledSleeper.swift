@testable import whitenoise_ios
import Foundation

/// Stands in for `Task.sleep`: each sleep waits until the test releases it or
/// its task is cancelled, and the double records what happened.
@MainActor
final class ControlledSleeper {
    private(set) var requestedDelays: [Duration] = []
    private(set) var cancelledCount = 0
    private(set) var completedCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ duration: Duration) async throws {
        requestedDelays.append(duration)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancelled before parking: the handler has already run.
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resume(id) }
        }
        if Task.isCancelled {
            cancelledCount += 1
            throw CancellationError()
        }
        completedCount += 1
    }

    /// Wakes every sleep that is waiting now.
    func releaseAll() {
        let parked = waiters
        waiters = [:]
        for continuation in parked.values { continuation.resume() }
    }

    private func resume(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
