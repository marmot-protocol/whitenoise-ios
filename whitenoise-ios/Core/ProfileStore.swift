import Foundation
import MarmotKit

struct ProfileProjectionRequest: Equatable, Sendable {
    var accountIdHex: String
    var localAccountLabel: String?
}

struct ProfileDisplayProjection: Equatable {
    var profile: UserProfileMetadataFfi?
    var projectedName: String?
    var localAccountLabel: String?

    var knownDisplayName: String? {
        AppState.resolvedKnownDisplayName(
            profile: profile,
            projectedName: projectedName,
            localAccountLabel: localAccountLabel
        )
    }

    var avatarURL: URL? {
        ProfileSanitizer.imageURL(profile?.picture)
    }

    var hasRemoteIdentity: Bool {
        profile != nil || ProfileSanitizer.displayName(projectedName) != nil
    }

    func updatingLocalAccountLabel(_ label: String?) -> ProfileDisplayProjection {
        var updated = self
        updated.localAccountLabel = label
        return updated
    }
}

/// Owns the app-side profile projection cache and the two queues that hydrate
/// it (off-main Marmot load, then a best-effort relay refresh). Extracted from
/// `AppState` so the god object stays a composition root; this is a dumb-mirror
/// cache over Marmot's profiles plus local account labels — no derivation.
///
/// `profileRefreshGeneration` deliberately stays on `AppState` (the SwiftUI
/// observation token views already track); this store reads and bumps it through
/// `appState`, so the observation behavior is unchanged by the extraction.
@MainActor
final class ProfileStore {
    weak var appState: AppState?

    // Internal (not private) so the existing white-box queue/version tests can
    // drive them via `appState.profileStore.…`; this matches the access level
    // they had as `@ObservationIgnored var` on AppState before the extraction.
    var profileProjectionCache: [String: ProfileDisplayProjection] = [:]
    var profileProjectionLoadTask: Task<Void, Never>?
    var queuedProfileProjectionLoadIDs: [String] = []
    var scheduledProfileProjectionLoadIDs: Set<String> = []
    var profileProjectionRefreshAfterLoadIDs: Set<String> = []
    var profileProjectionLoadVersions: [String: Int] = [:]
    var profileFetchQueueTask: Task<Void, Never>?
    var queuedProfileFetchIDs: [String] = []
    var scheduledProfileFetchIDs: Set<String> = []
    var activeProfileFetchID: String?

    // MARK: - Dependencies (read through AppState; never retained)

    private var canRefreshProfiles: Bool { appState?.canRefreshProfiles ?? false }
    private var accounts: [AccountSummaryFfi] { appState?.accounts ?? [] }
    private var activeAccountRef: String? { appState?.activeAccountRef }

    // MARK: - Public reads

    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.profile
    }

    func knownDisplayName(forAccountIdHex id: String) -> String? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.knownDisplayName
    }

    func avatarURL(forAccountIdHex id: String) -> URL? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.avatarURL
    }

    // MARK: - Warming / labels

    func warmProfileProjection(forAccountIdHex id: String, refreshAfterLoad: Bool = false) {
        scheduleProfileProjectionLoad(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
    }

    func warmLocalAccountProfileProjections() {
        for account in accounts {
            warmProfileProjection(forAccountIdHex: account.accountIdHex)
        }
    }

    func updateProfileProjectionLocalAccountLabels() {
        var localLabelsByID: [String: String] = [:]
        for account in accounts {
            localLabelsByID[account.accountIdHex] = account.label
        }

        var changed = false
        for (id, label) in localLabelsByID {
            let existing = profileProjectionCache[id] ?? ProfileDisplayProjection(
                profile: nil,
                projectedName: nil,
                localAccountLabel: nil
            )
            let updated = existing.updatingLocalAccountLabel(label)
            guard updated != existing else { continue }
            profileProjectionCache[id] = updated
            changed = true
        }

        for (id, projection) in profileProjectionCache where localLabelsByID[id] == nil {
            let updated = projection.updatingLocalAccountLabel(nil)
            guard updated != projection else { continue }
            profileProjectionCache[id] = updated
            changed = true
        }

        if changed {
            appState?.noteProfileRefreshCompleted()
        }
    }

    /// Clears projection state scoped to a local account that was removed while
    /// another account remains active. Unlike `clearForSignOut()`, this cannot
    /// reset the whole version map: profile refresh is still enabled, and a
    /// suspended load for this id may resume after the account switch. If this id
    /// has queued or in-flight projection work, leave a bumped token behind on
    /// purpose so the stale load fails closed without an ABA collision; when no
    /// work exists, avoid creating new per-id version-map residue.
    func clearForAccountRemoval(accountIdHex id: String) {
        guard !id.isEmpty else { return }

        let hadProjectionWork = profileProjectionLoadVersions[id] != nil
            || queuedProfileProjectionLoadIDs.contains(id)
            || scheduledProfileProjectionLoadIDs.contains(id)
            || profileProjectionRefreshAfterLoadIDs.contains(id)
        queuedProfileProjectionLoadIDs.removeAll { $0 == id }
        scheduledProfileProjectionLoadIDs.remove(id)
        profileProjectionRefreshAfterLoadIDs.remove(id)
        if hadProjectionWork {
            profileProjectionLoadVersions[id] = (profileProjectionLoadVersions[id] ?? 0) + 1
        }

        queuedProfileFetchIDs.removeAll { $0 == id }
        scheduledProfileFetchIDs.remove(id)
        if activeProfileFetchID == id {
            let fetchTask = profileFetchQueueTask
            profileFetchQueueTask = nil
            activeProfileFetchID = nil
            fetchTask?.cancel()
        }

        if profileProjectionCache.removeValue(forKey: id) != nil {
            appState?.noteProfileRefreshCompleted()
        }
    }

    @discardableResult
    func reloadProfileProjection(forAccountIdHex id: String) async -> ProfileDisplayProjection? {
        guard !id.isEmpty else { return nil }
        guard canRefreshProfiles else { return profileProjectionCache[id] }

        let version = bumpProfileProjectionLoadVersion(forAccountIdHex: id)
        queuedProfileProjectionLoadIDs.removeAll { $0 == id }
        scheduledProfileProjectionLoadIDs.remove(id)
        profileProjectionRefreshAfterLoadIDs.remove(id)

        let projection = await loadProfileProjection(forAccountIdHex: id)
        guard !Task.isCancelled,
              canRefreshProfiles,
              profileProjectionLoadVersions[id] == version
        else { return projection }

        if let projection {
            applyProfileProjection(projection, forAccountIdHex: id)
        }
        // This guarded load is the current one for `id` (its token still
        // matches). With it complete, prune the version entry if nothing else
        // is pending for `id`, bounding the map without disturbing tokens held
        // by any other in-flight load (#353).
        pruneProfileProjectionLoadVersionIfSettled(forAccountIdHex: id, matching: version)
        return projection
    }

    // MARK: - Projection load queue

    private func cachedProfileProjection(
        forAccountIdHex id: String,
        refreshAfterLoad: Bool
    ) -> ProfileDisplayProjection? {
        _ = appState?.profileRefreshGeneration
        if let projection = profileProjectionCache[id] {
            return projection
        }
        scheduleProfileProjectionLoad(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
        return nil
    }

    private func scheduleProfileProjectionLoad(forAccountIdHex id: String, refreshAfterLoad: Bool) {
        guard !id.isEmpty, canRefreshProfiles else { return }
        if refreshAfterLoad {
            profileProjectionRefreshAfterLoadIDs.insert(id)
        }
        guard !scheduledProfileProjectionLoadIDs.contains(id) else { return }

        bumpProfileProjectionLoadVersion(forAccountIdHex: id)
        scheduledProfileProjectionLoadIDs.insert(id)
        queuedProfileProjectionLoadIDs.append(id)
        startProfileProjectionLoadQueueIfNeeded()
    }

    private func startProfileProjectionLoadQueueIfNeeded() {
        guard profileProjectionLoadTask == nil, !queuedProfileProjectionLoadIDs.isEmpty else { return }
        profileProjectionLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.runProfileProjectionLoadQueue()
        }
    }

    private func runProfileProjectionLoadQueue() async {
        defer {
            profileProjectionLoadTask = nil
            if canRefreshProfiles, !queuedProfileProjectionLoadIDs.isEmpty {
                startProfileProjectionLoadQueueIfNeeded()
            }
        }

        while !Task.isCancelled, canRefreshProfiles, let id = nextQueuedProfileProjectionLoadID() {
            let version = profileProjectionLoadVersions[id] ?? 0
            let projection = await loadProfileProjection(forAccountIdHex: id)
            guard !Task.isCancelled else { break }
            guard canRefreshProfiles else {
                // Gate closed mid-load: `id` was dequeued but is still marked
                // scheduled. Re-arm it (front of the queue) so it isn't orphaned —
                // `resumeProfileFetchQueueIfNeeded()` re-drains it when the gate
                // reopens, instead of a later cache miss being suppressed by the
                // stale scheduled marker.
                queuedProfileProjectionLoadIDs.insert(id, at: 0)
                break
            }
            guard profileProjectionLoadVersions[id] == version else { continue }

            scheduledProfileProjectionLoadIDs.remove(id)
            if let projection {
                applyProfileProjection(projection, forAccountIdHex: id)
            }

            let shouldRefresh = profileProjectionRefreshAfterLoadIDs.remove(id) != nil
            if shouldRefresh, projection?.hasRemoteIdentity != true {
                scheduleProfileRefresh(forAccountIdHex: id)
            }
            // The queued load for `id` is the current one (token still matches)
            // and is now applied. Prune its version entry when no further
            // load/refresh work remains for `id` so the map stays bounded to
            // in-flight work instead of growing per distinct id (#353).
            pruneProfileProjectionLoadVersionIfSettled(forAccountIdHex: id, matching: version)
        }
    }

    private func nextQueuedProfileProjectionLoadID() -> String? {
        guard !queuedProfileProjectionLoadIDs.isEmpty else { return nil }
        return queuedProfileProjectionLoadIDs.removeFirst()
    }

    private func loadProfileProjection(forAccountIdHex id: String) async -> ProfileDisplayProjection? {
        guard let appState, let client = try? appState.currentMarmotClient() else { return nil }
        let request = profileProjectionRequest(forAccountIdHex: id)
        let projections = await client.profileProjections(for: [request])
        guard var projection = projections[id] else { return nil }
        projection.localAccountLabel = localAccountLabel(forAccountIdHex: id)
        return projection
    }

    private func profileProjectionRequest(forAccountIdHex id: String) -> ProfileProjectionRequest {
        ProfileProjectionRequest(accountIdHex: id, localAccountLabel: localAccountLabel(forAccountIdHex: id))
    }

    private func localAccountLabel(forAccountIdHex id: String) -> String? {
        accounts.first(where: { $0.accountIdHex == id })?.label
    }

    private func applyProfileProjection(_ projection: ProfileDisplayProjection, forAccountIdHex id: String) {
        guard profileProjectionCache[id] != projection else { return }
        profileProjectionCache[id] = projection
        appState?.noteProfileRefreshCompleted()
    }

    @discardableResult
    private func bumpProfileProjectionLoadVersion(forAccountIdHex id: String) -> Int {
        let version = (profileProjectionLoadVersions[id] ?? 0) + 1
        profileProjectionLoadVersions[id] = version
        return version
    }

    /// Evict an account id's monotonic load-version token once its current
    /// guarded load has settled (#353).
    ///
    /// The version map is the staleness guard for `reloadProfileProjection` and
    /// `runProfileProjectionLoadQueue`: each load captures the id's token and,
    /// after its `await`, only applies its result if the stored token still
    /// matches — so an older suspended load whose token was superseded fails the
    /// guard and discards its stale projection. That guard's correctness relies
    /// on the token being *monotonic* per id; a whole-map reset would restart
    /// the counter and let a superseded suspended load's captured token collide
    /// with a freshly re-issued one (ABA), applying stale data.
    ///
    /// We therefore prune one id at a time, and only when:
    ///   - `matching` is still the stored token (this is the latest load for the
    ///     id, so removing the entry cannot strip a token a newer load relies
    ///     on), and
    ///   - no queued/scheduled/refresh-after work remains for the id (nothing
    ///     pending will read the token before the next `bump` re-establishes a
    ///     fresh value).
    /// Any other in-flight load for the id has a *different*, higher token; it
    /// never matches `matching`, so its later guard check still fails closed
    /// after the entry is gone (a missing entry reads as `nil`, never equal to a
    /// positive captured token). This bounds the map to ids with pending work
    /// while preserving the monotonic-staleness invariant the guard needs.
    private func pruneProfileProjectionLoadVersionIfSettled(forAccountIdHex id: String, matching version: Int) {
        guard profileProjectionLoadVersions[id] == version,
              !queuedProfileProjectionLoadIDs.contains(id),
              !scheduledProfileProjectionLoadIDs.contains(id),
              !profileProjectionRefreshAfterLoadIDs.contains(id)
        else { return }
        profileProjectionLoadVersions.removeValue(forKey: id)
    }

    // MARK: - Relay refresh queue

    private func scheduleProfileRefresh(forAccountIdHex id: String) {
        guard !id.isEmpty,
              canRefreshProfiles,
              !scheduledProfileFetchIDs.contains(id)
        else { return }
        scheduledProfileFetchIDs.insert(id)
        queuedProfileFetchIDs.append(id)
        startProfileFetchQueueIfNeeded()
    }

    private func startProfileFetchQueueIfNeeded() {
        guard profileFetchQueueTask == nil, !queuedProfileFetchIDs.isEmpty else { return }
        profileFetchQueueTask = Task { [weak self] in
            guard let self else { return }
            await self.runProfileFetchQueue()
        }
    }

    func resumeProfileFetchQueueIfNeeded() {
        guard canRefreshProfiles else { return }
        startProfileProjectionLoadQueueIfNeeded()
        startProfileFetchQueueIfNeeded()
    }

    private func runProfileFetchQueue() async {
        defer {
            profileFetchQueueTask = nil
            activeProfileFetchID = nil
            if canRefreshProfiles, !queuedProfileFetchIDs.isEmpty {
                startProfileFetchQueueIfNeeded()
            }
        }

        while !Task.isCancelled, canRefreshProfiles, let id = nextQueuedProfileFetchID() {
            activeProfileFetchID = id
            await refreshProfile(forAccountIdHex: id)
            activeProfileFetchID = nil
            scheduledProfileFetchIDs.remove(id)
        }
    }

    private func nextQueuedProfileFetchID() -> String? {
        guard !queuedProfileFetchIDs.isEmpty else { return nil }
        return queuedProfileFetchIDs.removeFirst()
    }

    @discardableResult
    func cancelProfileFetchQueue() -> Task<Void, Never>? {
        queuedProfileProjectionLoadIDs.removeAll()
        scheduledProfileProjectionLoadIDs.removeAll()
        profileProjectionRefreshAfterLoadIDs.removeAll()
        // Deliberately do NOT clear `profileProjectionLoadVersions` here. This
        // method runs on every background suspension (via
        // `cancelForegroundMaintenance`), and a direct `reloadProfileProjection`
        // caller can be suspended at its `await` with an already-captured
        // version token. Resetting the whole map would restart the per-id
        // counter; a later load for the same id would re-issue a token that
        // collides with the suspended caller's captured value (ABA), letting it
        // pass the staleness guard and apply stale data. The map is instead kept
        // monotonic and bounded by `pruneProfileProjectionLoadVersionIfSettled`,
        // which evicts an id only after its current guarded load completes with
        // no pending work (#353). Full sign-out, where no in-flight load can
        // race a re-bump, clears the map separately in `AppState.signOut()`.
        let projectionTask = profileProjectionLoadTask
        profileProjectionLoadTask = nil
        projectionTask?.cancel()

        queuedProfileFetchIDs.removeAll()
        scheduledProfileFetchIDs.removeAll()
        activeProfileFetchID = nil
        let fetchTask = profileFetchQueueTask
        profileFetchQueueTask = nil
        fetchTask?.cancel()

        guard projectionTask != nil || fetchTask != nil else { return nil }
        return Task {
            await projectionTask?.value
            await fetchTask?.value
        }
    }

    deinit {
        profileProjectionLoadTask?.cancel()
        profileFetchQueueTask?.cancel()
    }

    /// Clears all cached state on full sign-out (no in-flight load can race a
    /// re-bump here, so the version map is safe to drop).
    func clearForSignOut() {
        profileProjectionCache.removeAll()
        profileProjectionLoadVersions.removeAll()
    }

    private func refreshProfile(forAccountIdHex id: String) async {
        guard !Task.isCancelled,
              canRefreshProfiles,
              let appState
        else { return }

        let relays: [String]
        if let activeAccountRef {
            relays = await appState.relayBootstrapRelays(for: activeAccountRef)
        } else {
            relays = MarmotClient.seedRelays
        }
        do {
            let client = try appState.currentMarmotClient()
            try await client.refreshProfile(accountIdHex: id, relays: relays)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        await reloadProfileProjection(forAccountIdHex: id)
    }

    #if DEBUG
    func runProfileFetchQueueForTesting() async {
        await runProfileFetchQueue()
    }

    /// Test hook for the post-load version-map eviction (#353). Mirrors the call
    /// the guarded load sites make after applying a projection.
    func pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex id: String, matching version: Int) {
        pruneProfileProjectionLoadVersionIfSettled(forAccountIdHex: id, matching: version)
    }
    #endif
}
