import Testing
import Foundation
import UIKit
@testable import whitenoise_ios
@testable import MarmotKit

/// The UIKit background-assertion wrapper used during runtime suspension.
@MainActor
struct BackgroundRuntimeSuspensionTaskTests {
    /// #743: UIKit owns the expiration deadline. Its callback must release the
    /// assertion immediately through the same idempotent helper as normal
    /// completion, even if Marmot teardown is still waiting elsewhere.
    @Test func backgroundTaskExpirationEndsAssertionExactlyOnce() async throws {
        let checkpoint = AsyncTestCheckpoint()
        let taskID = UIBackgroundTaskIdentifier(rawValue: 42)
        let suspensionTask = Task {
            await checkpoint.pause()
        }

        var capturedExpirationHandler: (() -> Void)?
        var endedTaskIDs: [UIBackgroundTaskIdentifier] = []
        var expirationCount = 0
        let backgroundTask = BackgroundRuntimeSuspensionTask(
            name: "Suspend Marmot runtime",
            onExpiration: {
                expirationCount += 1
            },
            beginBackgroundTask: { name, expirationHandler in
                #expect(name == "Suspend Marmot runtime")
                capturedExpirationHandler = expirationHandler
                return taskID
            },
            endBackgroundTask: { endedTaskID in
                endedTaskIDs.append(endedTaskID)
            }
        )
        backgroundTask.endWhenSuspensionCompletes(suspensionTask)
        await checkpoint.waitUntilPaused()

        capturedExpirationHandler?()
        try await eventually {
            expirationCount == 1 && endedTaskIDs == [taskID]
        }

        await checkpoint.release()
        await suspensionTask.value
        await Task.yield()

        #expect(endedTaskIDs == [taskID])
        #expect(expirationCount == 1)
    }
}
