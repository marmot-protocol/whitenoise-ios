import Foundation

/// Pure matching rules for the people list in New Message, New Group, and Add
/// Members. Matches resolved display names (private nicknames fold in through
/// the resolved name), NIP-05 addresses, and npub/hex prefixes; name-prefix
/// matches rank before contained matches, identity matches last.
nonisolated enum RecipientSearch {
    enum ResultContext: Equatable {
        case youFollow
        case searchResult
    }

    struct MatchFields: Equatable {
        let displayName: String?
        let nickname: String?
        let nip05: String?

        init(displayName: String? = nil, nickname: String? = nil, nip05: String? = nil) {
            self.displayName = displayName
            self.nickname = nickname
            self.nip05 = nip05
        }
    }

    static func browse(
        _ candidates: [RecipientCandidate],
        query: String,
        excludedAccountIds: Set<String> = [],
        fields: (RecipientCandidate) -> MatchFields
    ) -> [RecipientCandidate] {
        let excluded = Set(excludedAccountIds.map { normalized($0) })
        var seen: Set<String> = []
        var eligible: [RecipientCandidate] = []
        for candidate in candidates {
            let hex = normalized(candidate.accountIdHex)
            guard !excluded.contains(hex), seen.insert(hex).inserted else { continue }
            eligible.append(candidate)
        }

        let needle = folded(query)
        guard !needle.isEmpty else { return eligible }

        var namePrefix: [RecipientCandidate] = []
        var nameContained: [RecipientCandidate] = []
        var identity: [RecipientCandidate] = []
        for candidate in eligible {
            let matchFields = fields(candidate)
            let names = [matchFields.displayName, matchFields.nickname]
                .compactMap { $0 }
                .map { folded($0) }
            if names.contains(where: { $0.hasPrefix(needle) }) {
                namePrefix.append(candidate)
            } else if names.contains(where: { $0.contains(needle) }) {
                nameContained.append(candidate)
            } else if matchesIdentity(candidate, fields: matchFields, needle: needle) {
                identity.append(candidate)
            }
        }
        return namePrefix + nameContained + identity
    }

    /// Direct follows stay first. A streamed duplicate enriches the known
    /// candidate with search relationship/profile data while preserving its
    /// existing chat context.
    static func merge(
        known: [RecipientCandidate],
        discovered: [RecipientCandidate],
        excludedAccountIds: Set<String> = []
    ) -> [RecipientCandidate] {
        let excluded = Set(excludedAccountIds.map(normalized))
        let discoveredByID = Dictionary(
            discovered.map { (normalized($0.accountIdHex), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        let enrichedKnown = known.map { candidate in
            guard let result = discoveredByID[normalized(candidate.accountIdHex)] else {
                return candidate
            }
            return RecipientCandidate(
                accountIdHex: candidate.accountIdHex,
                npub: candidate.npub,
                lastActivityAt: candidate.lastActivityAt,
                directChatGroupIdHex: candidate.directChatGroupIdHex,
                sharedChatCount: candidate.sharedChatCount,
                searchProfile: result.searchProfile ?? candidate.searchProfile,
                searchRadius: result.searchRadius,
                isFollowedBySearcher: result.isFollowedBySearcher
            )
        }
        let merged = (enrichedKnown + discovered).filter { candidate in
            let accountIdHex = normalized(candidate.accountIdHex)
            return !excluded.contains(accountIdHex) && seen.insert(accountIdHex).inserted
        }
        return merged.enumerated().sorted { lhs, rhs in
            if lhs.element.isFollowedBySearcher != rhs.element.isFollowedBySearcher {
                return lhs.element.isFollowedBySearcher
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func resultContext(
        for candidate: RecipientCandidate,
        query: String
    ) -> ResultContext? {
        guard !folded(query).isEmpty else { return nil }
        return candidate.isFollowedBySearcher ? .youFollow : .searchResult
    }

    private static func matchesIdentity(
        _ candidate: RecipientCandidate,
        fields: MatchFields,
        needle: String
    ) -> Bool {
        if let nip05 = fields.nip05, folded(nip05).contains(needle) {
            return true
        }
        let bare = needle.trimmingCharacters(in: .whitespaces)
        guard bare.count >= 4 else { return false }
        return candidate.npub.lowercased().hasPrefix(bare)
            || candidate.accountIdHex.lowercased().hasPrefix(bare)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func folded(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
