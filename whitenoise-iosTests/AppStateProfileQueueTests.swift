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

    @Test func negativeRefreshCooldownBackoffsAndStopsInfiniteRefetchForUnknownPeer() async throws {
        #expect(ProfileStore.negativeRefreshCooldown(forAttempt: 1) == .seconds(60))
        #expect(ProfileStore.negativeRefreshCooldown(forAttempt: 2) == .seconds(120))
        #expect(ProfileStore.negativeRefreshCooldown(forAttempt: 3) == .seconds(240))
        #expect(ProfileStore.negativeRefreshCooldown(forAttempt: 20) == .seconds(3_600))

        try await withTestClient { client in
            let appState = AppState.test(client: client)
            var currentNow = ContinuousClock.now
            let peer = hex("71")
            var refreshCalls = 0
            let store = ProfileStore(
                now: { currentNow },
                performRelayRefresh: { _ in
                    refreshCalls += 1
                    return .completed
                }
            )
            store.appState = appState
            store.profileProjectionCache[peer] = ProfileDisplayProjection(
                profile: nil,
                projectedName: nil,
                localAccountLabel: nil
            )

            // First visible read triggers one relay refresh attempt.
            #expect(store.knownDisplayName(forAccountIdHex: peer) == nil)
            try await eventually { refreshCalls == 1 && store.profileFetchQueueTask == nil }
            #expect(store.isInNegativeRefreshCooldown(forAccountIdHex: peer))
            #expect(store.negativeRefreshCooldowns[peer]?.failedAttempts == 1)

            // Repeated reads during the 60s cooldown must not re-enqueue the peer.
            for _ in 0..<5 {
                #expect(store.knownDisplayName(forAccountIdHex: peer) == nil)
            }
            #expect(store.queuedProfileFetchIDs.isEmpty)
            #expect(store.profileFetchQueueTask == nil)
            #expect(refreshCalls == 1)

            // Once cooldown expires, a read triggers attempt 2 with 120s backoff.
            currentNow = currentNow.advanced(by: .seconds(60))
            #expect(store.knownDisplayName(forAccountIdHex: peer) == nil)
            try await eventually { refreshCalls == 2 && store.profileFetchQueueTask == nil }
            #expect(store.negativeRefreshCooldowns[peer]?.failedAttempts == 2)

            // At +60s into the 120s backoff, it is still suppressed.
            currentNow = currentNow.advanced(by: .seconds(60))
            #expect(store.knownDisplayName(forAccountIdHex: peer) == nil)
            #expect(store.queuedProfileFetchIDs.isEmpty)
            #expect(refreshCalls == 2)

            // Seeding a discovered profile clears negative cooldown immediately.
            store.seedDiscoveredProfile(
                UserProfileMetadataFfi(
                    name: "Alice",
                    displayName: "Alice",
                    about: nil,
                    picture: nil,
                    banner: nil,
                    nip05: nil,
                    lud16: nil
                ),
                forAccountIdHex: peer
            )
            #expect(store.negativeRefreshCooldowns[peer] == nil)
            #expect(store.knownDisplayName(forAccountIdHex: peer) == "Alice")
        }
    }

    @Test func profileProjectionCacheEnforcesBoundedLRUEviction() async throws {
        try await withTestClient { client in
            let appState = AppState.test(client: client)
            let idA = hex("81")
            let idB = hex("82")
            let idC = hex("83")
            let idD = hex("84")
            let store = ProfileStore(
                maxCachedProjections: 3,
                loadProjections: { requests in
                    Dictionary(uniqueKeysWithValues: requests.map { req in
                        (
                            req.accountIdHex,
                            ProfileDisplayProjection(profile: nil, projectedName: "User \(req.accountIdHex.prefix(2))", localAccountLabel: nil)
                        )
                    })
                }
            )
            store.appState = appState

            _ = await store.reloadProfileProjection(forAccountIdHex: idA)
            _ = await store.reloadProfileProjection(forAccountIdHex: idB)
            _ = await store.reloadProfileProjection(forAccountIdHex: idC)
            #expect(store.profileProjectionCache.count == 3)

            // Reading idA refreshes its recency, making idB the least recently used entry.
            #expect(store.cachedKnownDisplayName(forAccountIdHex: idA) == "User 81")

            _ = await store.reloadProfileProjection(forAccountIdHex: idD)
            #expect(store.profileProjectionCache.count == 3)
            #expect(store.profileProjectionCache[idB] == nil)
            #expect(store.profileProjectionCache[idA] != nil)
            #expect(store.profileProjectionCache[idC] != nil)
            #expect(store.profileProjectionCache[idD] != nil)
        }
    }

    @Test func resumeMarksCachedProjectionsStaleLazilyWithoutEagerRequeueStorm() async throws {
        try await withTestClient { client in
            let appState = AppState.test(client: client)
            let store = ProfileStore(loadProjections: { requests in
                Dictionary(uniqueKeysWithValues: requests.map { req in
                    (
                        req.accountIdHex,
                        ProfileDisplayProjection(profile: nil, projectedName: "Refreshed \(req.accountIdHex.prefix(2))", localAccountLabel: nil)
                    )
                })
            })
            store.appState = appState

            let peers = (1...20).map { String(format: "%064x", $0) }
            for peer in peers {
                store.profileProjectionCache[peer] = ProfileDisplayProjection(
                    profile: nil,
                    projectedName: "Warm \(peer.prefix(2))",
                    localAccountLabel: nil
                )
            }

            _ = store.pauseProfileFetchQueue()
            store.resumeProfileFetchQueueIfNeeded()

            // Resuming must NOT eagerly enqueue all 20 cached peers.
            #expect(store.queuedProfileProjectionLoadIDs.isEmpty)
            #expect(store.profileProjectionLoadTask == nil)
            #expect(store.staleProfileProjectionIDs.count == 20)

            // Reading one visible peer returns warm cached data immediately and
            // lazily queues a refresh for ONLY that peer.
            let target = peers[0]
            appState.setAppSceneActive(false)
            #expect(store.knownDisplayName(forAccountIdHex: target) == "Warm 00")
            #expect(store.queuedProfileProjectionLoadIDs == [target])
            #expect(store.staleProfileProjectionIDs.count == 19)
            _ = store.cancelProfileFetchQueue()
        }
    }

    @Test func batchProjectionLoadNotifiesProfileRefreshGenerationOncePerBatch() async throws {
        try await withTestClient { client in
            let appState = AppState.test(client: client)
            let store = ProfileStore(loadProjections: { requests in
                Dictionary(uniqueKeysWithValues: requests.map { req in
                    (
                        req.accountIdHex,
                        ProfileDisplayProjection(
                            profile: nil,
                            projectedName: "Batch \(req.accountIdHex.suffix(2))",
                            localAccountLabel: nil
                        )
                    )
                })
            })
            store.appState = appState

            let peers = (1...12).map { String(format: "%064x", $0) }
            let generationBefore = appState.profileRefreshGeneration

            // Queue all 12 peers while inactive so they run together in a single batch.
            appState.setAppSceneActive(false)
            for peer in peers {
                store.warmProfileProjection(forAccountIdHex: peer)
            }
            #expect(store.queuedProfileProjectionLoadIDs.count == 12)

            appState.setAppSceneActive(true)
            store.resumeProfileFetchQueueIfNeeded()
            try await eventually {
                store.profileProjectionLoadTask == nil && store.profileProjectionCache.count == 12
            }

            // All 12 changed entries in one batch must emit a single generation bump.
            #expect(appState.profileRefreshGeneration == generationBefore + 1)
        }
    }
}
