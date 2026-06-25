import Foundation
import MarmotKit

// Profile projection state + queues live in `ProfileStore` (owned by AppState).
// These are thin forwarders so existing `appState.profile(...)` call sites are
// unchanged; `npub`/`shortNpub` stay here because they read the binding, not the
// projection cache. `profileRefreshGeneration` remains on AppState so SwiftUI
// observation of these reads is unchanged.
extension AppState {
    /// Full Nostr profile for an account id from the app-owned projection
    /// cache. A miss schedules off-main Marmot hydration and one relay refresh
    /// attempt, keeping SwiftUI row reads cheap and deterministic.
    @MainActor
    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        profileStore.profile(forAccountIdHex: id)
    }

    /// A display name we actually *know* for an account: projected kind:0
    /// display_name/name, then a local account's label. `nil` when nothing
    /// better than the raw id is available, so callers can choose their own
    /// fallback (e.g. an npub for a DM peer).
    @MainActor
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        profileStore.knownDisplayName(forAccountIdHex: id)
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
        profileStore.avatarURL(forAccountIdHex: id)
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
        profileStore.warmProfileProjection(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
    }

    @MainActor
    func warmLocalAccountProfileProjections() {
        profileStore.warmLocalAccountProfileProjections()
    }

    @MainActor
    func updateProfileProjectionLocalAccountLabels() {
        profileStore.updateProfileProjectionLocalAccountLabels()
    }

    @MainActor
    @discardableResult
    func reloadProfileProjection(forAccountIdHex id: String) async -> ProfileDisplayProjection? {
        await profileStore.reloadProfileProjection(forAccountIdHex: id)
    }

    @MainActor
    func resumeProfileFetchQueueIfNeeded() {
        profileStore.resumeProfileFetchQueueIfNeeded()
    }

    @MainActor
    @discardableResult
    func cancelProfileFetchQueue() -> Task<Void, Never>? {
        profileStore.cancelProfileFetchQueue()
    }

    #if DEBUG
    @MainActor
    func runProfileFetchQueueForTesting() async {
        await profileStore.runProfileFetchQueueForTesting()
    }

    @MainActor
    func pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex id: String, matching version: Int) {
        profileStore.pruneProfileProjectionLoadVersionIfSettledForTesting(forAccountIdHex: id, matching: version)
    }
    #endif
}
