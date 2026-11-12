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
}
