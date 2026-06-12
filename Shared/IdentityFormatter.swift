import Foundation

/// Static helpers for rendering Nostr identities (npub) and group ids in a
/// way that's human-recognizable without overwhelming the UI.
nonisolated enum IdentityFormatter {

    /// Truncates a long hex/bech32 string with an ellipsis in the middle.
    /// Used in chat rows, member rows, and the identity card.
    static func short(_ value: String, head: Int = 8, tail: Int = 6) -> String {
        guard value.count > head + tail + 3 else { return value }
        let prefix = value.prefix(head)
        let suffix = value.suffix(tail)
        return "\(prefix)…\(suffix)"
    }

    /// Returns the best human-facing display name for a chat-row title in the
    /// absence of a Nostr kind:0 lookup.
    static func displayName(label: String, accountIdHex: String) -> String {
        if !label.isEmpty { return label }
        return short(accountIdHex)
    }
}
