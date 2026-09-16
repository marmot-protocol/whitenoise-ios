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

    /// Cache-only profile read for batch projections that must not enqueue
    /// unbounded hydration work.
    @MainActor
    func cachedProfile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        profileStore.cachedProfile(forAccountIdHex: id)
    }

    /// A display name we actually *know* for an account: the user's private
    /// contact nickname first, then projected kind:0 display_name/name, then a
    /// local account's label. `nil` when nothing better than the raw id is
    /// available, so callers can choose their own fallback (e.g. an npub for a
    /// DM peer).
    @MainActor
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        profileStore.knownDisplayName(forAccountIdHex: id)
    }

    /// Cache-only display-name read for batch projections that must not enqueue
    /// unbounded hydration work.
    @MainActor
    func cachedKnownDisplayName(forAccountIdHex id: String) -> String? {
        profileStore.cachedKnownDisplayName(forAccountIdHex: id)
    }

    /// The resolved profile-directory name with any local nickname ignored —
    /// what the contact publicly calls themselves. Shown as secondary text on
    /// the profile screen when a nickname overrides it.
    @MainActor
    func knownProfileDisplayName(forAccountIdHex id: String) -> String? {
        profileStore.knownProfileDisplayName(forAccountIdHex: id)
    }

    /// The private, device-local nickname for a contact, if the active account
    /// has set one. Never published; stored in the shared App Group defaults so
    /// the Notification Service Extension resolves the same override.
    @MainActor
    func contactNickname(forAccountIdHex id: String) -> String? {
        profileStore.contactNickname(forAccountIdHex: id)
    }

    /// Sets or clears the active account's private nickname for a contact.
    /// The value is sanitized with the display-name rules; a blank value clears.
    @MainActor
    func setContactNickname(_ nickname: String?, forAccountIdHex id: String) {
        profileStore.setContactNickname(nickname, forAccountIdHex: id)
    }

    /// Pure gate for whether a contact nickname applies: there must be an
    /// active owner account, and the contact must not be one of this device's
    /// own accounts (their local label wins). Extracted so the decision is
    /// unit testable without a profile store.
    static func contactNicknameOwner(
        activeAccountIdHex: String?,
        localAccountIdsHex: [String],
        contactAccountIdHex: String
    ) -> String? {
        guard let activeAccountIdHex, !activeAccountIdHex.isEmpty else { return nil }
        let contact = contactAccountIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !contact.isEmpty else { return nil }
        let contactIsLocalAccount = localAccountIdsHex.contains { $0.lowercased() == contact }
        return contactIsLocalAccount ? nil : activeAccountIdHex
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
        if let profile, let name = ContentSanitizer.displayName(profile.displayName ?? profile.name) {
            return name
        }
        if let name = ContentSanitizer.displayName(projectedName) {
            return name
        }
        // Sanitize the local label too: a whitespace/control-only label would
        // otherwise render blank and suppress the npub fallback.
        if let label = ContentSanitizer.displayName(localAccountLabel) {
            return label
        }
        return nil
    }

    /// Best-effort display name. Prefers the known name, then canonical npub.
    @MainActor
    func displayName(forAccountIdHex id: String) -> String {
        IdentityPresentation.text(
            accountIdHex: id,
            knownName: knownDisplayName(forAccountIdHex: id)
        )
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

    /// The canonical `npub...` form of an account id hex, or nil when the value
    /// isn't a 32-byte public key. Optional on purpose: a caller that needs a
    /// copyable or shareable npub must hide the affordance rather than fall
    /// back to the hex it was handed.
    @MainActor
    func npub(forAccountIdHex id: String) -> String? {
        // Pure bech32 encode: the runtime accessor rebuilds the released
        // client (reopening on-disk storage) and traps if that throws —
        // callers here are SwiftUI body paths that may render while the
        // runtime is suspended.
        IdentityPresentation.canonicalNpub(accountIdHex: id)
    }

    /// Truncated npub for compact UI (e.g. `npub1abc…wxyz`), or localized
    /// generic copy for a malformed key.
    @MainActor
    func shortNpub(forAccountIdHex id: String) -> String {
        IdentityPresentation.text(accountIdHex: id)
    }

    @MainActor
    func warmProfileProjection(forAccountIdHex id: String, refreshAfterLoad: Bool = false) {
        profileStore.warmProfileProjection(forAccountIdHex: id, refreshAfterLoad: refreshAfterLoad)
    }

    /// Promotes profile metadata that was already resolved by recipient search
    /// into the shared projection cache when the user acts on that result.
    @MainActor
    func seedDiscoveredProfile(_ profile: UserProfileMetadataFfi?, forAccountIdHex id: String) {
        profileStore.seedDiscoveredProfile(profile, forAccountIdHex: id)
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
    func pauseProfileFetchQueue() -> Task<Void, Never>? {
        profileStore.pauseProfileFetchQueue()
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
