import Foundation

/// Classifies what the person typed or pasted into the recipient search
/// field: a plain name (browse the known-people list), a profile reference
/// (npub / nprofile / hex / nostr: URI / profile link), a Namecoin `.bit` /
/// `d/` / `id/` identifier, or a NIP-05 address. Profile references win over
/// NIP-05 when both could apply; Namecoin identifiers win over NIP-05 because
/// a `.bit` domain is resolved through ElectrumX, not DNS.
nonisolated enum RecipientIdentifierQuery: Equatable {
    case none
    case profileReference(String)
    /// A Namecoin identifier (`alice@example.bit`, `example.bit`, `d/example`,
    /// `id/alice`) to route through `NamecoinResolver`. The payload is the
    /// trimmed raw input; the resolver owns parsing.
    case namecoin(String)
    case nip05(name: String, domain: String)

    static func classify(_ raw: String) -> RecipientIdentifierQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if let reference = AddMembersPresentation.memberRef(fromScannedPayload: trimmed) {
            return .profileReference(reference)
        }
        if NamecoinResolver.isBitIdentifier(trimmed) {
            return .namecoin(trimmed)
        }
        if let address = nip05Address(trimmed) {
            return .nip05(name: address.name, domain: address.domain)
        }
        return .none
    }

    /// Splits a shape-valid NIP-05 address into its local part and domain.
    /// The sanitizer owns shape validation; the split lowercases both halves
    /// because NIP-05 identifiers are matched case-insensitively.
    static func nip05Address(_ raw: String) -> (name: String, domain: String)? {
        guard let sanitized = ContentSanitizer.profileAddress(raw), sanitized.contains("@") else {
            return nil
        }
        let parts = sanitized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (name: parts[0].lowercased(), domain: parts[1].lowercased())
    }

    /// A validated public-key reference already identifies its recipient; it
    /// does not need a running Marmot client or a relay profile lookup to
    /// become selectable. Profile metadata can enrich the row independently.
    static func resolvedProfileReference(_ reference: String) -> ResolvedRecipient? {
        guard let memberRef = NostrProfileReference.memberRef(fromReference: reference) else {
            return nil
        }
        let accountIdHex = Hex.normalized32Bytes(memberRef)
            ?? NostrProfileReference.pubkeyHex(fromBech32: memberRef)
        guard let accountIdHex else { return nil }
        return ResolvedRecipient(
            accountIdHex: accountIdHex,
            memberRef: memberRef,
            queriedNip05: nil
        )
    }
}

/// A person an identifier-shaped query resolved to. `memberRef` is normalized
/// to a form the current MarmotKit runtime accepts (npub or canonical hex);
/// NIP-05 and nprofile resolutions submit the resolved pubkey.
nonisolated struct ResolvedRecipient: Equatable {
    let accountIdHex: String
    let memberRef: String
    /// The NIP-05 address the query resolved through, when applicable. The
    /// row shows a verified state only when the resolved profile declares
    /// this same address.
    let queriedNip05: String?
}

/// Progress of resolving an identifier-shaped query to an account, driving
/// the resolved-person row states in the recipient search results.
nonisolated enum RecipientResolutionState: Equatable {
    case idle
    case resolving
    case resolved(ResolvedRecipient)
    /// The lookup completed but no profile maps to the query.
    case noProfile
    /// The lookup itself failed (network, malformed document).
    case failed
    /// The query is identifier-shaped but can't be resolved safely.
    case invalid
}
