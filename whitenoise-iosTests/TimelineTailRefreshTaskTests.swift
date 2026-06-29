import Foundation
import Synchronization
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct TimelineTailRefreshTaskLifetimeTests {
    @Test func staleCompletionCannotClearReplacementGeneration() {
        let first = TimelineTailRefreshTaskLifetime.nextGeneration(after: 0)
        let replacement = TimelineTailRefreshTaskLifetime.nextGeneration(after: first)

        #expect(!TimelineTailRefreshTaskLifetime.shouldClearStoredTask(
            currentGeneration: replacement,
            completedGeneration: first
        ))
        #expect(TimelineTailRefreshTaskLifetime.shouldClearStoredTask(
            currentGeneration: replacement,
            completedGeneration: replacement
        ))
    }

    @MainActor
    @Test func schedulingTailRefreshCancelsPreviousTaskAndClearsLatestOnCompletion() async throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let probe = TailRefreshTaskProbe()

        viewModel.scheduleTimelineTailRefreshForTesting {
            probe.markFirstStarted()
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            } onCancel: {
                probe.markFirstCancelled()
            }
        }
        await waitUntil { probe.firstStarted }

        #expect(probe.firstStarted)
        #expect(viewModel.hasTimelineTailRefreshTaskForTesting)

        viewModel.scheduleTimelineTailRefreshForTesting {
            probe.markSecondRan()
        }
        await waitUntil {
            probe.firstCancelled && probe.secondRan && !viewModel.hasTimelineTailRefreshTaskForTesting
        }

        #expect(probe.firstCancelled)
        #expect(probe.secondRan)
        #expect(!viewModel.hasTimelineTailRefreshTaskForTesting)
    }

    @MainActor
    @Test func cancellingTailRefreshDropsStoredTask() async throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )

        viewModel.scheduleTimelineTailRefreshForTesting {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(viewModel.hasTimelineTailRefreshTaskForTesting)

        viewModel.cancelTimelineTailRefreshForTesting()
        #expect(!viewModel.hasTimelineTailRefreshTaskForTesting)
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 10_000_000_000,
    pollIntervalNanoseconds: UInt64 = 5_000_000,
    _ condition: () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

private final class TailRefreshTaskProbe: Sendable {
    private struct State {
        var firstStarted = false
        var firstCancelled = false
        var secondRan = false
    }

    private let state = Mutex(State())

    var firstStarted: Bool { state.withLock { $0.firstStarted } }
    var firstCancelled: Bool { state.withLock { $0.firstCancelled } }
    var secondRan: Bool { state.withLock { $0.secondRan } }

    func markFirstStarted() { state.withLock { $0.firstStarted = true } }
    func markFirstCancelled() { state.withLock { $0.firstCancelled = true } }
    func markSecondRan() { state.withLock { $0.secondRan = true } }
}

private func testGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: String(repeating: "bb", count: 32),
        endpoint: "",
        name: "Test Group",
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: "",
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: MessageSemantics.encryptedMediaVersion,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
            ]
        ),
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}
