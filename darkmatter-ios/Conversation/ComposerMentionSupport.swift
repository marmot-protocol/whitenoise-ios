import Foundation
import MarmotKit

struct ComposerMentionCandidate: Identifiable, Equatable {
    let id: String
    let memberIdHex: String
    let displayName: String
    let npub: String
    let avatarPictureURL: URL?

    // Lowercased forms of the stable match fields, precomputed once at
    // construction. `filter` runs on every keystroke while composing a
    // mention; caching these avoids re-lowercasing/re-allocating per
    // candidate on the MainActor typing hot path (see issue #300).
    let displayNameLowercased: String
    let npubLowercased: String
    let memberIdHexLowercased: String

    init(details: GroupMemberDetailsFfi, appState: AppState) {
        memberIdHex = details.memberIdHex
        npub = details.npub
        let accountIdHex = GroupMemberDetailsPresentation.profileAccountIdHex(for: details)
        displayName =
            ProfileSanitizer.displayName(details.displayName)
            ?? appState.knownDisplayName(forAccountIdHex: accountIdHex)
            ?? IdentityFormatter.short(accountIdHex)
        avatarPictureURL = appState.avatarURL(forAccountIdHex: accountIdHex)
        id = memberIdHex
        displayNameLowercased = displayName.lowercased()
        npubLowercased = npub.lowercased()
        memberIdHexLowercased = memberIdHex.lowercased()
    }

    init?(member: AppGroupMemberRecordFfi, appState: AppState) {
        guard !member.local else { return nil }
        let accountHex = member.account ?? member.memberIdHex
        guard let npub = appState.marmot.npub(accountIdHex: accountHex),
            npub.hasPrefix("npub1")
        else { return nil }
        memberIdHex = member.memberIdHex
        self.npub = npub
        displayName = appState.displayName(forAccountIdHex: accountHex)
        avatarPictureURL = appState.avatarURL(forAccountIdHex: accountHex)
        id = memberIdHex
        displayNameLowercased = displayName.lowercased()
        npubLowercased = self.npub.lowercased()
        memberIdHexLowercased = memberIdHex.lowercased()
    }
}

enum ComposerMentionQuery {
    struct Session: Equatable {
        let atIndex: String.Index
        let query: String

        func replacementRange(in draft: String) -> Range<String.Index> {
            atIndex..<draft.endIndex
        }
    }

    static let maxVisibleCandidates = 8
    private static let completeNpubBodyLength = 58

    static func active(in draft: String) -> Session? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let queryStart = draft.index(after: atIndex)
        guard queryStart <= draft.endIndex else { return nil }
        let query = String(draft[queryStart...])
        guard !query.contains(where: \.isWhitespace) else { return nil }
        guard !query.contains(where: \.isNewline) else { return nil }
        return Session(atIndex: atIndex, query: query)
    }

    static func looksLikeCompleteNpub(_ query: String) -> Bool {
        query.hasPrefix("npub1") && query.count >= 5 + completeNpubBodyLength
    }

    static func filter(_ candidates: [ComposerMentionCandidate], matching query: String)
        -> [ComposerMentionCandidate]
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [ComposerMentionCandidate]
        if trimmed.isEmpty {
            filtered = candidates
        } else {
            let needle = trimmed.lowercased()
            filtered = candidates.filter { candidate in
                candidate.displayNameLowercased.contains(needle)
                    || candidate.npubLowercased.contains(needle)
                    || candidate.memberIdHexLowercased.contains(needle)
            }
        }
        return Array(filtered.prefix(maxVisibleCandidates))
    }

    static func replacing(
        session: Session,
        in draft: String,
        with npub: String
    ) -> String {
        var updated = draft
        updated.replaceSubrange(session.replacementRange(in: draft), with: "@\(npub) ")
        return updated
    }
}
