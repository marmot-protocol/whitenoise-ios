import Foundation

/// The single contract for naming a Nostr account in ordinary user-facing text.
///
/// Callers supply the account id and whatever name they already resolved; they
/// never choose between hex and bech32 themselves. A valid 32-byte key that has
/// no name becomes a syntactically valid lowercase npub; an absent or malformed
/// key becomes localized generic copy. Raw hex is not a possible output, so a
/// first frame rendered before profile hydration cannot leak one.
///
/// Lives in `Shared/` because the Notification Service Extension renders sender
/// names without the main app's in-memory profile projection.
nonisolated enum IdentityPresentation {

    /// How much of the npub to show. Group ids, MLS member ids, message ids and
    /// hashes are not identities and keep using `IdentityFormatter.short`.
    enum Abbreviation {
        case short
        case wide
        case full

        fileprivate func apply(_ npub: String) -> String {
            switch self {
            case .short: IdentityFormatter.short(npub)
            case .wide: IdentityFormatter.short(npub, head: 12, tail: 10)
            case .full: npub
            }
        }
    }

    /// Which localized non-identity string stands in for an unusable key.
    /// `.sender` reads as a person in a sentence ("Someone sent a message");
    /// `.user` reads as a label in a list.
    enum UnknownFallback {
        case user
        case sender

        fileprivate var text: String {
            switch self {
            case .user: L10n.string("Unknown user")
            case .sender: L10n.string("Someone")
            }
        }
    }

    enum Source: Equatable {
        case name
        case npub
        case unknown
    }

    struct Resolved: Equatable {
        let text: String
        let source: Source
    }

    /// The canonical lowercase npub for an account id, or nil when the value is
    /// not a 32-byte Nostr public key. Never returns the input.
    static func canonicalNpub(accountIdHex: String?) -> String? {
        guard let normalized = Hex.normalized32Bytes(accountIdHex) else { return nil }
        return NostrProfileReference.npub(fromAccountIdHex: normalized)
    }

    static func resolve(
        accountIdHex: String?,
        knownName: String? = nil,
        abbreviation: Abbreviation = .short,
        unknown: UnknownFallback = .user
    ) -> Resolved {
        // The name is re-sanitized here even when a store already did it: a
        // whitespace- or control-only name would otherwise render blank and
        // suppress the npub.
        if let name = ContentSanitizer.displayName(knownName) {
            return Resolved(text: name, source: .name)
        }
        if let npub = canonicalNpub(accountIdHex: accountIdHex) {
            return Resolved(text: abbreviation.apply(npub), source: .npub)
        }
        return Resolved(text: unknown.text, source: .unknown)
    }

    static func text(
        accountIdHex: String?,
        knownName: String? = nil,
        abbreviation: Abbreviation = .short,
        unknown: UnknownFallback = .user
    ) -> String {
        resolve(
            accountIdHex: accountIdHex,
            knownName: knownName,
            abbreviation: abbreviation,
            unknown: unknown
        ).text
    }
}
