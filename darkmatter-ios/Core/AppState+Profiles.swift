import Foundation
import MarmotKit

extension AppState {
    /// Full Nostr profile for an account id. Returns the cached value
    /// immediately if known; otherwise does a fast synchronous read from the
    /// runtime's directory cache, and on a miss schedules a background relay
    /// fetch so a later call hydrates. `nil` until something is known.
    @MainActor
    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        if let cached = profileCache.cachedProfile(forAccountIdHex: id) { return cached }
        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return local
        }
        Task { await refreshProfile(forAccountIdHex: id) }
        return nil
    }

    /// A display name we actually *know* for an account: projected kind:0
    /// display_name/name, then a cached name, then a local account's label.
    /// `nil` when nothing better than the raw id is available, so callers can
    /// choose their own fallback (e.g. an npub for a DM peer).
    @MainActor
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        profileCache.knownDisplayName(
            forAccountIdHex: id,
            profile: profile(forAccountIdHex: id),
            projectedName: marmot.displayName(accountIdHex: id),
            localAccountLabel: accounts.first(where: { $0.accountIdHex == id })?.label
        )
    }

    /// Best-effort display name. Prefers the projected kind:0 display_name /
    /// name, then a local account's label, then short-hex.
    @MainActor
    func displayName(forAccountIdHex id: String) -> String {
        profileCache.displayName(forAccountIdHex: id, knownName: knownDisplayName(forAccountIdHex: id))
    }

    /// Picture URL for an account id, if its profile has a *safe* one.
    /// Untrusted: only http(s) URLs with a host pass the sanitizer.
    @MainActor
    func avatarURL(forAccountIdHex id: String) -> URL? {
        profileCache.avatarURL(for: profile(forAccountIdHex: id))
    }

    /// Store a profile in the cache and derive its display name. Called after
    /// a successful publish so the editor and chrome update immediately.
    @MainActor
    func cacheProfile(_ profile: UserProfileMetadataFfi, for id: String) {
        profileCache.cacheProfile(profile, for: id)
    }

    /// The `npub...` bech32 form of an account id hex. Falls back to the hex
    /// if conversion fails (shouldn't, for a valid pubkey).
    @MainActor
    func npub(forAccountIdHex id: String) -> String {
        profileCache.npub(forAccountIdHex: id, projected: marmot.npub(accountIdHex: id))
    }

    /// Truncated npub for compact UI (e.g. `npub1abc...wxyz`).
    @MainActor
    func shortNpub(forAccountIdHex id: String) -> String {
        IdentityFormatter.short(npub(forAccountIdHex: id))
    }

    @MainActor
    private func refreshProfile(forAccountIdHex id: String) async {
        guard profileCache.beginDirectoryFetch(for: id) else { return }
        defer { profileCache.finishDirectoryFetch(for: id) }

        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return
        }

        // Fetch this account's OWN kind:0 through the active account's relay
        // lists. Marmot owns those lists; iOS only asks for the current view.
        let relays = activeAccountRef.map(relayBootstrapRelays(for:)) ?? MarmotClient.seedRelays
        try? await marmot.refreshProfile(accountIdHex: id, relays: relays)

        if let fetched = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(fetched, for: id)
        } else if let name = marmot.displayName(accountIdHex: id), !name.isEmpty {
            profileCache.cacheProjectedDisplayName(name, for: id)
        }
    }
}
