import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

/// Profile fetch and projection-load queue bookkeeping with no runtime
/// client. Tests where the inactive scene is what blocks refresh need a client
/// and live in AppStateBootstrapTests.
@MainActor
struct AppStateProfileQueueTests {
    @Test func foregroundMaintenancePausePreservesPendingProfileWork() async throws {
        let appState = AppState.test()
        let loading = hex("36")
        let refreshing = hex("37")
        appState.profileStore.queuedProfileProjectionLoadIDs = [loading]
        appState.profileStore.scheduledProfileProjectionLoadIDs = [loading]
        appState.profileStore.profileProjectionRefreshAfterLoadIDs = [loading]
        appState.profileStore.queuedProfileFetchIDs = [refreshing]
        appState.profileStore.scheduledProfileFetchIDs = [refreshing]

        _ = appState.pauseProfileFetchQueue()

        #expect(appState.profileStore.queuedProfileProjectionLoadIDs == [loading])
        #expect(appState.profileStore.scheduledProfileProjectionLoadIDs == [loading])
        #expect(appState.profileStore.profileProjectionRefreshAfterLoadIDs == [loading])
        #expect(appState.profileStore.queuedProfileFetchIDs == [refreshing])
        #expect(appState.profileStore.scheduledProfileFetchIDs == [refreshing])
        #expect(appState.profileStore.profileProjectionCacheNeedsReloadOnResume)
    }

    @Test func staleProfileFetchQueueCompletionDoesNotClearNewerRunner() async throws {
        let appState = AppState.test()
        let oldTaskID = UUID()
        let newTaskID = UUID()
        let newTask = Task<Void, Never> {}

        appState.profileStore.profileFetchQueueTask = newTask
        appState.profileStore.profileFetchQueueTaskID = newTaskID
        appState.profileStore.activeProfileFetchID = hex("44")

        appState.profileStore.finishProfileFetchQueueForTesting(taskID: oldTaskID)

        #expect(appState.profileStore.profileFetchQueueTask != nil)
        #expect(appState.profileStore.profileFetchQueueTaskID == newTaskID)
        #expect(appState.profileStore.activeProfileFetchID == hex("44"))

        newTask.cancel()
    }

    @Test func staleProfileProjectionQueueCompletionDoesNotClearNewerRunner() async throws {
        let appState = AppState.test()
        let oldTaskID = UUID()
        let newTaskID = UUID()
        let newTask = Task<Void, Never> {}

        appState.profileStore.profileProjectionLoadTask = newTask
        appState.profileStore.profileProjectionLoadTaskID = newTaskID

        appState.profileStore.finishProfileProjectionLoadQueueForTesting(taskID: oldTaskID)

        #expect(appState.profileStore.profileProjectionLoadTask != nil)
        #expect(appState.profileStore.profileProjectionLoadTaskID == newTaskID)

        newTask.cancel()
    }

    @Test func cancelProfileFetchQueuePreservesProfileProjectionLoadVersions() async throws {
        // Regression for #353 (corrected per adversarial review of PR #357):
        // `cancelProfileFetchQueue()` runs on every background suspension (via
        // `cancelForegroundMaintenance`). A direct `reloadProfileProjection`
        // caller can be suspended at its `await` holding an already-captured
        // version token. If this method reset the whole version map, a later
        // load for the same id would restart the per-id counter and re-issue a
        // token that COLLIDES with the suspended caller's captured value (ABA),
        // letting stale data pass the staleness guard. So it must clear the
        // sibling queues (bounded to in-flight work) while PRESERVING the
        // monotonic version map. Eviction happens instead via post-load pruning
        // and full sign-out — covered by the tests below.
        let appState = AppState.test()
        appState.profileStore.queuedProfileProjectionLoadIDs = [hex("44")]
        appState.profileStore.scheduledProfileProjectionLoadIDs = [hex("44"), hex("55")]
        appState.profileStore.profileProjectionRefreshAfterLoadIDs = [hex("55")]
        appState.profileStore.profileProjectionLoadVersions = [hex("44"): 3, hex("55"): 1]

        _ = appState.cancelProfileFetchQueue()

        // Sibling queues are cleared...
        #expect(appState.profileStore.queuedProfileProjectionLoadIDs.isEmpty)
        #expect(appState.profileStore.scheduledProfileProjectionLoadIDs.isEmpty)
        #expect(appState.profileStore.profileProjectionRefreshAfterLoadIDs.isEmpty)
        // ...but the monotonic version map survives, so a suspended direct
        // reload's captured token cannot be reused by a re-bump after resume.
        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("44"): 3, hex("55"): 1])
    }

    @Test func settledProfileProjectionLoadPrunesItsVersionEntry() async throws {
        // After a guarded load completes for an id with no pending
        // queued/scheduled/refresh work, its version entry is evicted so the map
        // stays bounded to in-flight work rather than growing per distinct id
        // ever seen (#353).
        let appState = AppState.test()
        appState.profileStore.profileProjectionLoadVersions = [hex("66"): 7, hex("77"): 2]

        // id 66 settled at its current token, nothing pending -> evicted.
        appState.pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex: hex("66"), matching: 7)

        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("77"): 2])
    }

    @Test func prunePreservesVersionEntryWhenTokenSupersededOrWorkPending() async throws {
        // The prune must fail closed in exactly the cases that protect the
        // staleness guard's monotonic invariant (#353):
        //   (a) the stored token has been superseded by a newer load (the value
        //       no longer matches the settled token) -> keep the live token, and
        //   (b) queued/scheduled/refresh work still pending for the id -> keep
        //       the token a pending load will read.
        let appState = AppState.test()

        // (a) superseded token: a newer load bumped 88 from 4 to 5; an older
        // load settling with token 4 must NOT evict the live token 5.
        appState.profileStore.profileProjectionLoadVersions = [hex("88"): 5]
        appState.pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex: hex("88"), matching: 4)
        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("88"): 5])

        // (b) work still pending: matching token but the id is still queued.
        appState.profileStore.profileProjectionLoadVersions = [hex("99"): 1]
        appState.profileStore.queuedProfileProjectionLoadIDs = [hex("99")]
        appState.pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex: hex("99"), matching: 1)
        #expect(appState.profileStore.profileProjectionLoadVersions == [hex("99"): 1])
    }
}
