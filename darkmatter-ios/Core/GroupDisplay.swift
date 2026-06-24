import Foundation
import MarmotKit

/// Shared rules for how a group is titled and avatared across the chats list
/// and the conversation header:
///   1. a named group shows its (sanitized) name;
///   2. an unnamed group with >2 members shows "<count> person group";
///   3. an unnamed 2-member group renders as the other person — their known
///      display name, or their npub when no profile name is known.
enum GroupDisplay {
    /// Cached display inputs for one group render. `ProfileSanitizer.groupName`
    /// walks peer/admin-controlled Unicode scalars, so resolve once and thread
    /// the sanitized result through title/avatar helpers.
    struct Resolved {
        let group: AppGroupRecordFfi
        let otherMember: String?
        let memberCount: Int
        let sanitizedName: String?
        let isDirectMessage: Bool
    }

    /// Account id for the peer in an unnamed 2-person group. `memberIdHex` is
    /// the Nostr pubkey; `account` is only a local label for known accounts.
    static func otherMemberAccount(
        in members: [AppGroupMemberRecordFfi],
        myAccountId: String?
    ) -> String? {
        if let myAccountId {
            return members.first { $0.memberIdHex != myAccountId }?.memberIdHex
        }
        return members.first { !$0.local }?.memberIdHex ?? members.first?.memberIdHex
    }

    static func resolve(
        group: AppGroupRecordFfi,
        otherMember: String?,
        memberCount: Int
    ) -> Resolved {
        resolve(
            group: group,
            otherMember: otherMember,
            memberCount: memberCount,
            sanitizeGroupName: ProfileSanitizer.groupName
        )
    }

    static func resolve(
        group: AppGroupRecordFfi,
        otherMember: String?,
        memberCount: Int,
        sanitizeGroupName: (String?) -> String?
    ) -> Resolved {
        let sanitizedName = sanitizeGroupName(group.name)
        return Resolved(
            group: group,
            otherMember: otherMember,
            memberCount: memberCount,
            sanitizedName: sanitizedName,
            isDirectMessage: sanitizedName == nil && memberCount == 2
        )
    }

    static func title(
        for display: Resolved,
        appState: AppState
    ) -> String {
        if let name = display.sanitizedName { return name }
        if display.memberCount > 2 {
            return L10n.plural("%lld person group", Int64(display.memberCount))
        }
        if display.isDirectMessage, let other = display.otherMember {
            return appState.knownDisplayName(forAccountIdHex: other)
                ?? appState.shortNpub(forAccountIdHex: other)
        }
        return IdentityFormatter.short(display.group.groupIdHex)
    }

    /// Avatar picture for the row/header: a group avatar URL wins when present,
    /// then unnamed 2-member DMs fall back to the other member's picture.
    static func avatarURL(
        for display: Resolved,
        appState: AppState
    ) -> URL? {
        if let groupAvatar = ProfileSanitizer.imageURL(display.group.avatarUrl) {
            return groupAvatar
        }
        guard display.isDirectMessage,
              let other = display.otherMember else { return nil }
        return appState.avatarURL(forAccountIdHex: other)
    }

    /// Deterministic color seed — keyed on the other member for an unnamed DM
    /// so their color matches wherever else they appear; otherwise the group.
    static func avatarSeed(for display: Resolved) -> String {
        if display.isDirectMessage, let other = display.otherMember {
            return other
        }
        return display.group.groupIdHex
    }
}
