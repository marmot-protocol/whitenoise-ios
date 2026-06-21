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

extension AppState {
    /// Full Nostr profile for an account id from the app-owned projection
    /// cache. A miss schedules off-main Marmot hydration and one relay refresh
    /// attempt, keeping SwiftUI row reads cheap and deterministic.
    @MainActor
    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.profile
    }

    /// A display name we actually *know* for an account: projected kind:0
    /// display_name/name, then a local account's label. `nil` when nothing
    /// better than the raw id is available, so callers can choose their own
    /// fallback (e.g. an npub for a DM peer).
    @MainActor
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.knownDisplayName
    }

    /// Pure resolution of the best known display name from its three sources, in
    /// priority order: the fetched kind:0 profile, the runtime's projected name,
    /// then a local account's own label. Extracted so the precedence is unit
    /// testable without a profile store.
    static func resolvedKnownDisplayName(
        profile: UserProfileMetadataFfi?,
        projectedName: String?,
        localAccountLabel: String?
    ) -> String? {
        if let profile, let name = ProfileSanitizer.displayName(profile.displayName ?? profile.name) {
            return name
        }
        if let name = ProfileSanitizer.displayName(projectedName) {
            return name
        }
        // Sanitize the local label too: a whitespace/control-only label would
        // otherwise render blank and suppress the npub fallback.
        if let label = ProfileSanitizer.displayName(localAccountLabel) {
            return label
        }
        return nil
    }

    /// Best-effort display name. Prefers the known name, then short-hex.
    @MainActor
    func displayName(forAccountIdHex id: String) -> String {
        knownDisplayName(forAccountIdHex: id) ?? IdentityFormatter.short(id)
    }

    /// Display name for a markdown mention entity (npub/nprofile). nil when
    /// the reference is invalid or the profile is unknown, so the caller
    /// keeps its truncated-bech32 fallback. A miss schedules a relay profile
    /// fetch, and the resulting refresh re-renders observers with the name.
    @MainActor
    func mentionDisplayName(for entity: MarkdownNostrEntityFfi) -> String? {
        guard let pubkeyHex = NostrProfileReference.pubkeyHex(fromBech32: entity.bech32) else {
            return nil
        }
        return knownDisplayName(forAccountIdHex: pubkeyHex)
    }

    /// Picture URL for an account id, if its profile has a *safe* one.
    /// Untrusted: only http(s) URLs with a host pass the sanitizer.
    @MainActor
    func avatarURL(forAccountIdHex id: String) -> URL? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.avatarURL
    }

    /// The `npub...` bech32 form of an account id hex, read from the binding.
    /// Falls back to the hex if conversion fails (shouldn't, for a valid pubkey).
    @MainActor
    func npub(forAccountIdHex id: String) -> String {
        marmot.npub(accountIdHex: id) ?? id
    }

    /// Truncated npub for compact UI (e.g. `npub1abc...wxyz`).
    @MainActor
    func shortNpub(forAccountIdHex id: String) -> String {
        IdentityFormatter.short(npub(forAccountIdHex: id))
    }

    @MainActor
    func warmProfileProjection(forAccountIdHex id: String, refreshAfterLoad: Bool = false) {
        scheduleProfileProjectionLoad(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
    }

    @MainActor
    func warmLocalAccountProfileProjections() {
        for account in accounts {
            warmProfileProjection(forAccountIdHex: account.accountIdHex)
        }
    }

    @MainActor
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
            noteProfileRefreshCompleted()
        }
    }

    @MainActor
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

    @MainActor
    private func cachedProfileProjection(
        forAccountIdHex id: String,
        refreshAfterLoad: Bool
    ) -> ProfileDisplayProjection? {
        _ = profileRefreshGeneration
        if let projection = profileProjectionCache[id] {
            return projection
        }
        scheduleProfileProjectionLoad(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
        return nil
    }

    @MainActor
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

    @MainActor
    private func startProfileProjectionLoadQueueIfNeeded() {
        guard profileProjectionLoadTask == nil, !queuedProfileProjectionLoadIDs.isEmpty else { return }
        profileProjectionLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.runProfileProjectionLoadQueue()
        }
    }

    @MainActor
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
            guard !Task.isCancelled, canRefreshProfiles else { break }
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

    @MainActor
    private func nextQueuedProfileProjectionLoadID() -> String? {
        guard !queuedProfileProjectionLoadIDs.isEmpty else { return nil }
        return queuedProfileProjectionLoadIDs.removeFirst()
    }

    @MainActor
    private func loadProfileProjection(forAccountIdHex id: String) async -> ProfileDisplayProjection? {
        let request = profileProjectionRequest(forAccountIdHex: id)
        let projections = await MarmotClient.profileProjections(for: [request], marmot: marmot)
        guard var projection = projections[id] else { return nil }
        projection.localAccountLabel = localAccountLabel(forAccountIdHex: id)
        return projection
    }

    @MainActor
    private func profileProjectionRequest(forAccountIdHex id: String) -> ProfileProjectionRequest {
        ProfileProjectionRequest(accountIdHex: id, localAccountLabel: localAccountLabel(forAccountIdHex: id))
    }

    @MainActor
    private func localAccountLabel(forAccountIdHex id: String) -> String? {
        accounts.first(where: { $0.accountIdHex == id })?.label
    }

    @MainActor
    private func applyProfileProjection(_ projection: ProfileDisplayProjection, forAccountIdHex id: String) {
        guard profileProjectionCache[id] != projection else { return }
        profileProjectionCache[id] = projection
        noteProfileRefreshCompleted()
    }

    @MainActor
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
    @MainActor
    private func pruneProfileProjectionLoadVersionIfSettled(forAccountIdHex id: String, matching version: Int) {
        guard profileProjectionLoadVersions[id] == version,
              !queuedProfileProjectionLoadIDs.contains(id),
              !scheduledProfileProjectionLoadIDs.contains(id),
              !profileProjectionRefreshAfterLoadIDs.contains(id)
        else { return }
        profileProjectionLoadVersions.removeValue(forKey: id)
    }

    @MainActor
    private func scheduleProfileRefresh(forAccountIdHex id: String) {
        guard !id.isEmpty,
              canRefreshProfiles,
              !scheduledProfileFetchIDs.contains(id)
        else { return }
        scheduledProfileFetchIDs.insert(id)
        queuedProfileFetchIDs.append(id)
        startProfileFetchQueueIfNeeded()
    }

    @MainActor
    private func startProfileFetchQueueIfNeeded() {
        guard profileFetchQueueTask == nil, !queuedProfileFetchIDs.isEmpty else { return }
        profileFetchQueueTask = Task { [weak self] in
            guard let self else { return }
            await self.runProfileFetchQueue()
        }
    }

    @MainActor
    func resumeProfileFetchQueueIfNeeded() {
        guard canRefreshProfiles else { return }
        startProfileProjectionLoadQueueIfNeeded()
        startProfileFetchQueueIfNeeded()
    }

    @MainActor
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

    @MainActor
    private func nextQueuedProfileFetchID() -> String? {
        guard !queuedProfileFetchIDs.isEmpty else { return nil }
        return queuedProfileFetchIDs.removeFirst()
    }

    @MainActor
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
        // race a re-bump, clears the map separately in `signOut()`.
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

    @MainActor
    private func refreshProfile(forAccountIdHex id: String) async {
        guard !Task.isCancelled,
              canRefreshProfiles
        else { return }

        let relays: [String]
        if let activeAccountRef {
            relays = await relayBootstrapRelays(for: activeAccountRef)
        } else {
            relays = MarmotClient.seedRelays
        }
        do {
            try await marmot.refreshProfile(accountIdHex: id, relays: relays)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        await reloadProfileProjection(forAccountIdHex: id)
    }

    #if DEBUG
    @MainActor
    func runProfileFetchQueueForTesting() async {
        await runProfileFetchQueue()
    }

    /// Test hook for the post-load version-map eviction (#353). Mirrors the call
    /// the guarded load sites make after applying a projection.
    @MainActor
    func pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex id: String, matching version: Int) {
        pruneProfileProjectionLoadVersionIfSettled(forAccountIdHex: id, matching: version)
    }
    #endif
}
