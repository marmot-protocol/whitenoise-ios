import Foundation

/// Truncation for long opaque identifiers — group ids, MLS member ids, message
/// ids, hashes, lightning addresses, and already-encoded bech32 values.
///
/// This is not the contract for naming a Nostr account: use
/// `IdentityPresentation`, which never yields raw hex. Passing a raw account id
/// hex here would put a shortened public key into ordinary UI text.
nonisolated enum IdentityFormatter {

    /// Truncates a long hex/bech32 string with an ellipsis in the middle.
    static func short(_ value: String, head: Int = 8, tail: Int = 6) -> String {
        guard value.count > head + tail + 3 else { return value }
        let prefix = value.prefix(head)
        let suffix = value.suffix(tail)
        return "\(prefix)…\(suffix)"
    }
}
