import Foundation
import MarmotKit
import OSLog

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
        ContentSanitizer.imageURL(profile?.picture)
    }

    var hasRemoteIdentity: Bool {
        profile != nil || ContentSanitizer.displayName(projectedName) != nil
    }

    func updatingLocalAccountLabel(_ label: String?) -> ProfileDisplayProjection {
        var updated = self
        updated.localAccountLabel = label
        return updated
    }
}

nonisolated enum ProfileRelayDiscovery {
    private static let maximumRouteRelays = 16

    static func allowedRelays(
        from classifications: [RelayEndpointClassificationFfi]
    ) -> [String] {
        var seen = Set<String>()
        var relays: [String] = []
        for classification in classifications where classification.policy == .allowed {
            guard let normalized = classification.normalizedEndpoint,
                  seen.insert(normalized).inserted
            else { continue }
            relays.append(normalized)
        }
        return relays
    }

    static func profileRelays(targetRelays: [String], bootstrapRelays: [String]) -> [String] {
        var seen = Set<String>()
        return (targetRelays + bootstrapRelays).compactMap { relay in
            guard seen.insert(relay).inserted else { return nil }
            return relay
        }.prefix(maximumRouteRelays).map { $0 }
    }

    static func shouldRefreshTargetRelayLists(
        cachedTargetRelays: [String],
        hasRemoteIdentity: Bool
    ) -> Bool {
        cachedTargetRelays.isEmpty || !hasRemoteIdentity
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
    struct NegativeRefreshState: Equatable {
        var failedAttempts: Int
        var retryAfter: ContinuousClock.Instant
    }

    enum RefreshAttemptOutcome: Equatable {
        case completed
        case failed
        case skipped
        case cancelled
    }

    typealias ProjectionLoader = @MainActor (AppState, [ProfileProjectionRequest]) async -> [String: ProfileDisplayProjection]

    struct RelayRefreshTransport {
        var bootstrapRelays: @MainActor (AppState, String?) async -> [String]
        var classifyRelayEndpoints: @MainActor (AppState, [String]) async -> [RelayEndpointClassificationFfi]?
        var cachedTargetRelays: @MainActor (AppState, String) async throws -> [String]
        var refreshProfile: @MainActor (AppState, String, [String]) async throws -> Void
        var refreshTargetRelays: @MainActor (AppState, String, [String]) async throws -> [String]

        static let live = Self(
            bootstrapRelays: { appState, activeAccountRef in
                if let activeAccountRef {
                    return await appState.relayBootstrapRelays(for: activeAccountRef)
                }
                return MarmotClient.seedRelays
            },
            classifyRelayEndpoints: { appState, candidates in
                guard let client = try? appState.currentMarmotClient() else { return nil }
                return await client.classifyRelayEndpoints(candidates)
            },
            cachedTargetRelays: { appState, accountIdHex in
                guard let client = try? appState.currentMarmotClient() else { return [] }
                return try await client.userRelayLists(accountIdHex: accountIdHex).nip65.relays
            },
            refreshProfile: { appState, accountIdHex, relays in
                let client = try appState.currentMarmotClient()
                try await client.refreshProfile(accountIdHex: accountIdHex, relays: relays)
            },
            refreshTargetRelays: { appState, accountIdHex, relays in
                let client = try appState.currentMarmotClient()
                return try await client.refreshUserRelayLists(
                    accountIdHex: accountIdHex,
                    relays: relays
                ).nip65.relays
            }
        )
    }

    static let defaultLoadProjections: ProjectionLoader = { appState, requests in
        guard let client = try? appState.currentMarmotClient() else { return [:] }
        // host_profile_read is per profile, so only single reads are timed.
        let timing = requests.count == 1 ? appState.productAnalytics.beginTiming() : nil
        let projections = await client.profileProjections(for: requests)
        appState.productAnalytics.recordStage(
            .profileRead, since: timing,
            outcome: Task.isCancelled ? .cancelled : projections.isEmpty ? .unavailable : .success
        )
        return projections
    }

    nonisolated static let initialNegativeRefreshCooldown: Duration = .seconds(60)
    nonisolated static let maximumNegativeRefreshCooldown: Duration = .seconds(3_600)
    private nonisolated static let maximumNegativeRefreshCooldownEntries = 1_024

    nonisolated static func negativeRefreshCooldown(forAttempt attempt: Int) -> Duration {
        let shift = min(max(0, attempt - 1), 10)
        let seconds = min(60 * (1 << shift), 3_600)
        return .seconds(seconds)
    }

    weak var appState: AppState?

    private let now: () -> ContinuousClock.Instant
    private let loadProjections: ProjectionLoader
    private let relayTransport: RelayRefreshTransport

    // Internal (not private) so the existing white-box queue/version tests can
    // drive them via `appState.profileStore.…`; this matches the access level
    // they had as `@ObservationIgnored var` on AppState before the extraction.
    var profileProjectionCache: [String: ProfileDisplayProjection] = [:]
    var staleProfileProjectionIDs: Set<String> = []
    var negativeRefreshCooldowns: [String: NegativeRefreshState] = [:]
    var profileProjectionLoadTask: Task<Void, Never>?
    var profileProjectionLoadTaskID: UUID?
    var queuedProfileProjectionLoadIDs: [String] = []
    var scheduledProfileProjectionLoadIDs: Set<String> = []
    var profileProjectionRefreshAfterLoadIDs: Set<String> = []
    var profileProjectionLoadVersions: [String: Int] = [:]
    var profileFetchQueueTask: Task<Void, Never>?
    var profileFetchQueueTaskID: UUID?
    var queuedProfileFetchIDs: [String] = []
    var scheduledProfileFetchIDs: Set<String> = []
    var activeProfileFetchID: String?
    var profileProjectionCacheNeedsReloadOnResume = false
    private static let profileProjectionLoadBatchSize = 64
    private static let hydrationLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "profile-hydration"
    )

    // Contact nicknames: private per-device labels layered over the projection
    // cache. Only the main app writes them, so the snapshot is loaded once and
    // kept in sync by the write path — no cross-process invalidation needed.
    // Injectable defaults keep nickname tests hermetic.
    var contactNicknameDefaults: UserDefaults? = ContactNicknameStore.defaults
    private var contactNicknamesByKey: [String: String]?

    init(
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        loadProjections: @escaping ProjectionLoader = ProfileStore.defaultLoadProjections,
        relayTransport: RelayRefreshTransport = .live
    ) {
        self.now = now
        self.loadProjections = loadProjections
        self.relayTransport = relayTransport
    }

    // MARK: - Dependencies (read through AppState; never retained)

    private var canRefreshProfiles: Bool { appState?.canRefreshProfiles ?? false }
    private var accounts: [AccountSummaryFfi] { appState?.accounts ?? [] }
    private var activeAccountRef: String? { appState?.activeAccountRef }

    // MARK: - Public reads

    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.profile
    }

    /// Cache-only profile read for bounded batch projections. Unlike
    /// `profile(forAccountIdHex:)`, a miss never schedules hydration or relay
    /// refresh work.
    func cachedProfile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        _ = appState?.profileRefreshGeneration
        return profileProjectionCache[id]?.profile
    }

    /// A local nickname wins over the resolved profile projection; this is the
    /// resolution chokepoint every display-name consumer reads through, so the
    /// override applies everywhere at once. The projection is still resolved
    /// first: it registers SwiftUI observation and warms the cache so the real
    /// profile name and avatar stay available alongside the nickname.
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        let resolved = cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.knownDisplayName
        return contactNickname(forAccountIdHex: id) ?? resolved
    }

    /// Cache-only display-name read for bounded batch projections. The
    /// projection's name is already sanitized by `resolvedKnownDisplayName`.
    func cachedKnownDisplayName(forAccountIdHex id: String) -> String? {
        _ = appState?.profileRefreshGeneration
        return contactNickname(forAccountIdHex: id) ?? profileProjectionCache[id]?.knownDisplayName
    }

    /// The resolved profile-directory name, ignoring any local nickname — the
    /// secondary line on the profile screen when a nickname overrides it.
    func knownProfileDisplayName(forAccountIdHex id: String) -> String? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.knownDisplayName
    }

    // MARK: - Contact nicknames

    func contactNickname(forAccountIdHex id: String) -> String? {
        _ = appState?.profileRefreshGeneration
        guard let owner = contactNicknameOwner(forContactAccountIdHex: id) else { return nil }
        return ContactNicknameStore.nickname(
            ownerAccountIdHex: owner,
            contactAccountIdHex: id,
            in: contactNicknameSnapshot()
        )
    }

    func setContactNickname(_ nickname: String?, forAccountIdHex id: String) {
        guard let owner = contactNicknameOwner(forContactAccountIdHex: id) else { return }
        ContactNicknameStore.setNickname(
            nickname,
            ownerAccountIdHex: owner,
            contactAccountIdHex: id,
            defaults: contactNicknameDefaults
        )
        contactNicknamesByKey = ContactNicknameStore.nicknamesByKey(defaults: contactNicknameDefaults)
        appState?.noteProfileRefreshCompleted()
    }

    /// Sign-out cleanup: drops every nickname the departing owner authored and
    /// invalidates the snapshot so a later active account reloads fresh state.
    func clearContactNicknames(ownerAccountIdHex: String) {
        ContactNicknameStore.clearAll(ownerAccountIdHex: ownerAccountIdHex, defaults: contactNicknameDefaults)
        contactNicknamesByKey = nil
        appState?.noteProfileRefreshCompleted()
    }

    private func contactNicknameOwner(forContactAccountIdHex id: String) -> String? {
        guard let appState else { return nil }
        return AppState.contactNicknameOwner(
            activeAccountIdHex: appState.activeAccount?.accountIdHex,
            localAccountIdsHex: appState.accounts.map(\.accountIdHex),
            contactAccountIdHex: id
        )
    }

    private func contactNicknameSnapshot() -> [String: String] {
        if let contactNicknamesByKey { return contactNicknamesByKey }
        let snapshot = ContactNicknameStore.nicknamesByKey(defaults: contactNicknameDefaults)
        contactNicknamesByKey = snapshot
        return snapshot
    }

    func avatarURL(forAccountIdHex id: String) -> URL? {
        cachedProfileProjection(forAccountIdHex: id, refreshAfterLoad: true)?.avatarURL
    }

    // MARK: - Warming / labels

    func warmProfileProjection(forAccountIdHex id: String, refreshAfterLoad: Bool = false) {
        scheduleProfileProjectionLoad(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
    }

    func seedDiscoveredProfile(_ profile: UserProfileMetadataFfi?, forAccountIdHex id: String) {
        guard let profile, !id.isEmpty else { return }

        // Search already completed the remote lookup. Cancel any older local
        // hydration reservation so it cannot overwrite this explicit result
        // with a stale empty projection after its suspension point returns.
        if profileProjectionLoadVersions[id] != nil
            || scheduledProfileProjectionLoadIDs.contains(id)
            || queuedProfileProjectionLoadIDs.contains(id) {
            _ = bumpProfileProjectionLoadVersion(forAccountIdHex: id)
        }
        queuedProfileProjectionLoadIDs.removeAll { $0 == id }
        scheduledProfileProjectionLoadIDs.remove(id)
        profileProjectionRefreshAfterLoadIDs.remove(id)
        staleProfileProjectionIDs.remove(id)
        negativeRefreshCooldowns.removeValue(forKey: id)

        let existing = profileProjectionCache[id]
        applyProfileProjection(
            ProfileDisplayProjection(
                profile: profile,
                projectedName: existing?.projectedName,
                localAccountLabel: existing?.localAccountLabel ?? localAccountLabel(forAccountIdHex: id)
            ),
            forAccountIdHex: id
        )
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

        for id in Array(profileProjectionCache.keys) where localLabelsByID[id] == nil {
            guard let projection = profileProjectionCache[id] else { continue }
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
        staleProfileProjectionIDs.remove(id)
        negativeRefreshCooldowns.removeValue(forKey: id)
        if hadProjectionWork {
            profileProjectionLoadVersions[id] = (profileProjectionLoadVersions[id] ?? 0) + 1
        }

        queuedProfileFetchIDs.removeAll { $0 == id }
        scheduledProfileFetchIDs.remove(id)
        if activeProfileFetchID == id {
            let fetchTask = profileFetchQueueTask
            profileFetchQueueTask = nil
            profileFetchQueueTaskID = nil
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
            if staleProfileProjectionIDs.remove(id) != nil {
                scheduleProfileProjectionLoad(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
            } else if refreshAfterLoad, !projection.hasRemoteIdentity {
                scheduleProfileRefresh(forAccountIdHex: id)
            }
            return projection
        }
        scheduleProfileProjectionLoad(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
        return nil
    }

    private func scheduleProfileProjectionLoad(forAccountIdHex id: String, refreshAfterLoad: Bool) {
        guard !id.isEmpty else { return }
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
        guard canRefreshProfiles,
              profileProjectionLoadTask == nil,
              !queuedProfileProjectionLoadIDs.isEmpty
        else { return }
        let taskID = UUID()
        profileProjectionLoadTaskID = taskID
        profileProjectionLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.runProfileProjectionLoadQueue(taskID: taskID)
        }
    }

    private func runProfileProjectionLoadQueue(taskID: UUID) async {
        defer {
            finishProfileProjectionLoadQueue(taskID: taskID)
        }

        while !Task.isCancelled, canRefreshProfiles {
            let ids = nextQueuedProfileProjectionLoadIDs(limit: Self.profileProjectionLoadBatchSize)
            guard !ids.isEmpty else { break }
            let versions = Dictionary(uniqueKeysWithValues: ids.map {
                ($0, profileProjectionLoadVersions[$0] ?? 0)
            })
            let hydrationStartedAt = ContinuousClock.now
            let projections = await loadProfileProjections(forAccountIdsHex: ids)
            guard !Task.isCancelled else { break }
            guard canRefreshProfiles else {
                // The batch was dequeued but remains marked scheduled. Re-arm it
                // in the same order so foreground resume cannot orphan any id.
                queuedProfileProjectionLoadIDs.insert(contentsOf: ids, at: 0)
                break
            }
            var batchChanged = false
            for id in ids {
                guard let version = versions[id],
                      profileProjectionLoadVersions[id] == version
                else { continue }

                scheduledProfileProjectionLoadIDs.remove(id)
                let projection = projections[id]
                if let projection {
                    batchChanged = storeProfileProjection(projection, forAccountIdHex: id) || batchChanged
                }

                let shouldRefresh = profileProjectionRefreshAfterLoadIDs.remove(id) != nil
                if shouldRefresh, projection?.hasRemoteIdentity != true {
                    scheduleProfileRefresh(forAccountIdHex: id)
                }
                pruneProfileProjectionLoadVersionIfSettled(
                    forAccountIdHex: id,
                    matching: version
                )
            }
            if batchChanged {
                appState?.noteProfileRefreshCompleted()
            }
            Self.hydrationLog.debug(
                "local_batch count=\(ids.count, privacy: .public) duration_ms=\(Self.elapsedMilliseconds(since: hydrationStartedAt), format: .fixed(precision: 0), privacy: .public)"
            )
        }
    }

    private func finishProfileProjectionLoadQueue(taskID: UUID) {
        guard profileProjectionLoadTaskID == taskID else { return }
        profileProjectionLoadTask = nil
        profileProjectionLoadTaskID = nil
        if canRefreshProfiles, !queuedProfileProjectionLoadIDs.isEmpty {
            startProfileProjectionLoadQueueIfNeeded()
        }
    }

    private func nextQueuedProfileProjectionLoadIDs(limit: Int) -> [String] {
        guard limit > 0, !queuedProfileProjectionLoadIDs.isEmpty else { return [] }
        let count = min(limit, queuedProfileProjectionLoadIDs.count)
        let ids = Array(queuedProfileProjectionLoadIDs.prefix(count))
        queuedProfileProjectionLoadIDs.removeFirst(count)
        return ids
    }

    private func loadProfileProjection(forAccountIdHex id: String) async -> ProfileDisplayProjection? {
        await loadProfileProjections(forAccountIdsHex: [id])[id]
    }

    private func loadProfileProjections(
        forAccountIdsHex ids: [String]
    ) async -> [String: ProfileDisplayProjection] {
        guard let appState else { return [:] }
        let requests = ids.map(profileProjectionRequest(forAccountIdHex:))
        var projections = await loadProjections(appState, requests)
        for id in ids {
            guard var projection = projections[id] else { continue }
            projection.localAccountLabel = localAccountLabel(forAccountIdHex: id)
            projections[id] = projection
        }
        return projections
    }

    private func profileProjectionRequest(forAccountIdHex id: String) -> ProfileProjectionRequest {
        ProfileProjectionRequest(accountIdHex: id, localAccountLabel: localAccountLabel(forAccountIdHex: id))
    }

    private func localAccountLabel(forAccountIdHex id: String) -> String? {
        accounts.first(where: { $0.accountIdHex == id })?.label
    }

    @discardableResult
    private func storeProfileProjection(_ projection: ProfileDisplayProjection, forAccountIdHex id: String) -> Bool {
        staleProfileProjectionIDs.remove(id)
        if projection.hasRemoteIdentity {
            negativeRefreshCooldowns.removeValue(forKey: id)
        }
        guard profileProjectionCache[id] != projection else {
            return false
        }
        profileProjectionCache[id] = projection
        return true
    }

    private func applyProfileProjection(_ projection: ProfileDisplayProjection, forAccountIdHex id: String) {
        if storeProfileProjection(projection, forAccountIdHex: id) {
            appState?.noteProfileRefreshCompleted()
        }
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

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }

    // MARK: - Relay refresh queue

    func isInNegativeRefreshCooldown(forAccountIdHex id: String) -> Bool {
        guard let state = negativeRefreshCooldowns[id] else { return false }
        return now() < state.retryAfter
    }

    private func recordNegativeRefreshResult(forAccountIdHex id: String) {
        let currentNow = now()
        let nextAttempts = (negativeRefreshCooldowns[id]?.failedAttempts ?? 0) + 1
        let cooldown = Self.negativeRefreshCooldown(forAttempt: nextAttempts)
        negativeRefreshCooldowns[id] = NegativeRefreshState(
            failedAttempts: nextAttempts,
            retryAfter: currentNow.advanced(by: cooldown)
        )
        pruneNegativeRefreshCooldownsIfNeeded(now: currentNow)
    }

    private func pruneNegativeRefreshCooldownsIfNeeded(now currentNow: ContinuousClock.Instant) {
        let cap = Self.maximumNegativeRefreshCooldownEntries
        guard negativeRefreshCooldowns.count > cap else { return }
        negativeRefreshCooldowns = negativeRefreshCooldowns.filter { $0.value.retryAfter > currentNow }
        guard negativeRefreshCooldowns.count > cap else { return }
        let overflow = negativeRefreshCooldowns.count - cap
        let oldestKeys = negativeRefreshCooldowns
            .sorted { $0.value.retryAfter < $1.value.retryAfter }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys {
            negativeRefreshCooldowns.removeValue(forKey: key)
        }
    }

    private func scheduleProfileRefresh(forAccountIdHex id: String) {
        guard !id.isEmpty,
              !scheduledProfileFetchIDs.contains(id),
              !isInNegativeRefreshCooldown(forAccountIdHex: id)
        else { return }
        scheduledProfileFetchIDs.insert(id)
        queuedProfileFetchIDs.append(id)
        startProfileFetchQueueIfNeeded()
    }

    private func startProfileFetchQueueIfNeeded() {
        guard canRefreshProfiles,
              profileFetchQueueTask == nil,
              !queuedProfileFetchIDs.isEmpty
        else { return }
        let taskID = UUID()
        profileFetchQueueTaskID = taskID
        profileFetchQueueTask = Task { [weak self] in
            guard let self else { return }
            await self.runProfileFetchQueue(taskID: taskID)
        }
    }

    func resumeProfileFetchQueueIfNeeded() {
        guard canRefreshProfiles else { return }
        if profileProjectionCacheNeedsReloadOnResume {
            profileProjectionCacheNeedsReloadOnResume = false
            // Mark cached entries stale lazily instead of eagerly re-enqueueing
            // the whole session cache; bump the observation token once so
            // currently visible views re-read and trigger on-demand hydration.
            staleProfileProjectionIDs.formUnion(profileProjectionCache.keys)
            if !staleProfileProjectionIDs.isEmpty {
                appState?.noteProfileRefreshCompleted()
            }
        }
        startProfileProjectionLoadQueueIfNeeded()
        startProfileFetchQueueIfNeeded()
    }

    private func runProfileFetchQueue(taskID: UUID) async {
        defer {
            finishProfileFetchQueue(taskID: taskID)
        }

        while !Task.isCancelled, canRefreshProfiles, let id = nextQueuedProfileFetchID() {
            activeProfileFetchID = id
            let outcome = await refreshProfile(forAccountIdHex: id)
            guard profileFetchQueueTaskID == taskID else { break }
            activeProfileFetchID = nil
            scheduledProfileFetchIDs.remove(id)
            if outcome == .completed, !Task.isCancelled, canRefreshProfiles {
                if profileProjectionCache[id]?.hasRemoteIdentity == true {
                    negativeRefreshCooldowns.removeValue(forKey: id)
                } else {
                    recordNegativeRefreshResult(forAccountIdHex: id)
                }
            }
        }
    }

    private func finishProfileFetchQueue(taskID: UUID) {
        guard profileFetchQueueTaskID == taskID else { return }
        profileFetchQueueTask = nil
        profileFetchQueueTaskID = nil
        activeProfileFetchID = nil
        if canRefreshProfiles, !queuedProfileFetchIDs.isEmpty {
            startProfileFetchQueueIfNeeded()
        }
    }

    private func nextQueuedProfileFetchID() -> String? {
        guard !queuedProfileFetchIDs.isEmpty else { return nil }
        return queuedProfileFetchIDs.removeFirst()
    }

    /// Pauses profile work for runtime suspension without losing the identities
    /// that still need hydration or relay refresh. Foreground resume rebuilds
    /// the tasks after the runtime is live again and reloads cached projections
    /// that Marmot catch-up may have updated while this process was backgrounded.
    @discardableResult
    func pauseProfileFetchQueue() -> Task<Void, Never>? {
        profileProjectionCacheNeedsReloadOnResume = true

        queuedProfileProjectionLoadIDs = Self.orderedPendingIDs(
            preferred: queuedProfileProjectionLoadIDs,
            including: scheduledProfileProjectionLoadIDs
                .union(profileProjectionRefreshAfterLoadIDs)
        )
        scheduledProfileProjectionLoadIDs.formUnion(queuedProfileProjectionLoadIDs)
        let projectionTask = profileProjectionLoadTask
        profileProjectionLoadTask = nil
        profileProjectionLoadTaskID = nil
        projectionTask?.cancel()

        let activeFetchIDs = activeProfileFetchID.map { [$0] } ?? []
        queuedProfileFetchIDs = Self.orderedPendingIDs(
            preferred: activeFetchIDs + queuedProfileFetchIDs,
            including: scheduledProfileFetchIDs
        )
        scheduledProfileFetchIDs.formUnion(queuedProfileFetchIDs)
        activeProfileFetchID = nil
        let fetchTask = profileFetchQueueTask
        profileFetchQueueTask = nil
        profileFetchQueueTaskID = nil
        fetchTask?.cancel()

        return Self.drainTask(projectionTask, fetchTask)
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
        profileProjectionLoadTaskID = nil
        projectionTask?.cancel()
        profileProjectionCacheNeedsReloadOnResume = false
        staleProfileProjectionIDs.removeAll()

        queuedProfileFetchIDs.removeAll()
        scheduledProfileFetchIDs.removeAll()
        activeProfileFetchID = nil
        let fetchTask = profileFetchQueueTask
        profileFetchQueueTask = nil
        profileFetchQueueTaskID = nil
        fetchTask?.cancel()

        return Self.drainTask(projectionTask, fetchTask)
    }

    private static func orderedPendingIDs(
        preferred: [String],
        including additional: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in preferred + additional.sorted() where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    private static func drainTask(
        _ projectionTask: Task<Void, Never>?,
        _ fetchTask: Task<Void, Never>?
    ) -> Task<Void, Never>? {
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
        staleProfileProjectionIDs.removeAll()
        negativeRefreshCooldowns.removeAll()
        profileProjectionLoadVersions.removeAll()
        profileProjectionCacheNeedsReloadOnResume = false
    }

    private func refreshProfile(forAccountIdHex id: String) async -> RefreshAttemptOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard canRefreshProfiles,
              let appState
        else { return .skipped }

        let bootstrapCandidates = await relayTransport.bootstrapRelays(appState, activeAccountRef)
        guard !Task.isCancelled else { return .cancelled }
        guard let bootstrapClassifications = await relayTransport.classifyRelayEndpoints(appState, bootstrapCandidates)
        else { return .skipped }
        let bootstrapRelays = ProfileRelayDiscovery.allowedRelays(
            from: bootstrapClassifications
        )

        let cachedTargetCandidates = (try? await relayTransport.cachedTargetRelays(appState, id)) ?? []
        guard let cachedTargetClassifications = await relayTransport.classifyRelayEndpoints(
            appState,
            cachedTargetCandidates
        ) else { return .skipped }
        let cachedTargetRelays = ProfileRelayDiscovery.allowedRelays(
            from: cachedTargetClassifications
        )
        let initialRelays = ProfileRelayDiscovery.profileRelays(
            targetRelays: cachedTargetRelays,
            bootstrapRelays: bootstrapRelays
        )
        guard !Task.isCancelled else { return .cancelled }
        guard !initialRelays.isEmpty else { return .skipped }

        var initialProjection: ProfileDisplayProjection?
        var anyRefreshSucceeded = false
        do {
            try await relayTransport.refreshProfile(appState, id, initialRelays)
            anyRefreshSucceeded = true
            guard !Task.isCancelled else { return .cancelled }
            initialProjection = await reloadProfileProjection(forAccountIdHex: id)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // A cached route can be stale or the device may be offline. Continue
            // into target relay-list discovery without counting this error as a
            // confirmed-empty kind:0 lookup.
        }

        guard !Task.isCancelled else { return .cancelled }
        if initialProjection?.hasRemoteIdentity == true {
            return .completed
        }
        guard ProfileRelayDiscovery.shouldRefreshTargetRelayLists(
            cachedTargetRelays: cachedTargetRelays,
            hasRemoteIdentity: false
        ),
              !bootstrapRelays.isEmpty
        else { return anyRefreshSucceeded ? .completed : .failed }

        let refreshedTargetCandidates: [String]
        do {
            refreshedTargetCandidates = try await relayTransport.refreshTargetRelays(
                appState,
                id,
                bootstrapRelays
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            // Discovery did not complete while metadata is still absent; treat
            // as transient rather than a confirmed-empty profile lookup.
            return .failed
        }

        guard !Task.isCancelled else { return .cancelled }
        guard let refreshedClassifications = await relayTransport.classifyRelayEndpoints(
            appState,
            refreshedTargetCandidates
        ) else { return .skipped }
        let retryRelays = ProfileRelayDiscovery.profileRelays(
            targetRelays: ProfileRelayDiscovery.allowedRelays(from: refreshedClassifications),
            bootstrapRelays: bootstrapRelays
        )
        guard !Task.isCancelled else { return .cancelled }
        guard retryRelays != initialRelays else { return anyRefreshSucceeded ? .completed : .failed }

        do {
            try await relayTransport.refreshProfile(appState, id, retryRelays)
            guard !Task.isCancelled else { return .cancelled }
            await reloadProfileProjection(forAccountIdHex: id)
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch {
            // The newly discovered target route failed while metadata is still
            // absent; treat as transient instead of entering negative backoff.
            return .failed
        }
    }
}
