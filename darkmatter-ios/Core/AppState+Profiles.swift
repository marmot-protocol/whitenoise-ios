import Foundation
import MarmotKit

extension AppState {
    /// Full Nostr profile for an account id, read straight from Marmot's
    /// directory each time. iOS keeps no profile cache of its own; on a miss it
    /// asks Marmot to refresh that account's kind:0 metadata from relays so
    /// later reads can hydrate names and avatars.
    @MainActor
    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        _ = profileRefreshGeneration
        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            return local
        }
        scheduleProfileRefresh(forAccountIdHex: id)
        return nil
    }

    /// A display name we actually *know* for an account: projected kind:0
    /// display_name/name, then a local account's label. `nil` when nothing
    /// better than the raw id is available, so callers can choose their own
    /// fallback (e.g. an npub for a DM peer).
    @MainActor
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        Self.resolvedKnownDisplayName(
            profile: profile(forAccountIdHex: id),
            projectedName: marmot.displayName(accountIdHex: id),
            localAccountLabel: accounts.first(where: { $0.accountIdHex == id })?.label
        )
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
        ProfileSanitizer.imageURL(profile(forAccountIdHex: id)?.picture)
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
    private func runProfileFetchQueue() async {
        defer {
            profileFetchQueueTask = nil
            activeProfileFetchID = nil
            if !queuedProfileFetchIDs.isEmpty {
                startProfileFetchQueueIfNeeded()
            }
        }

        while !Task.isCancelled, let id = nextQueuedProfileFetchID() {
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
        queuedProfileFetchIDs.removeAll()
        scheduledProfileFetchIDs.removeAll()
        activeProfileFetchID = nil
        let task = profileFetchQueueTask
        profileFetchQueueTask = nil
        task?.cancel()
        return task
    }

    @MainActor
    private func refreshProfile(forAccountIdHex id: String) async {
        guard !Task.isCancelled,
              canRefreshProfiles
        else { return }

        let relays = activeAccountRef.map(relayBootstrapRelays(for:)) ?? MarmotClient.seedRelays
        do {
            try await marmot.refreshProfile(accountIdHex: id, relays: relays)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        if ((try? marmot.userProfile(accountIdHex: id)) ?? nil) != nil ||
            ProfileSanitizer.displayName(marmot.displayName(accountIdHex: id)) != nil {
            noteProfileRefreshCompleted()
        }
    }
}
