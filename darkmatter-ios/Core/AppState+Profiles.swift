import Foundation
import MarmotKit

extension AppState {
    /// Full Nostr profile for an account id, read straight from Marmot's
    /// directory each time. iOS keeps no profile cache of its own — the binding
    /// owns fetching and freshness — so values are never stale here (#17).
    @MainActor
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        (try? marmot.userProfile(accountIdHex: id)) ?? nil
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
        if let localAccountLabel, !localAccountLabel.isEmpty {
            return localAccountLabel
        }
        return nil
    }

    /// Best-effort display name. Prefers the known name, then short-hex.
    @MainActor
    func displayName(forAccountIdHex id: String) -> String {
        knownDisplayName(forAccountIdHex: id) ?? IdentityFormatter.short(id)
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
}
