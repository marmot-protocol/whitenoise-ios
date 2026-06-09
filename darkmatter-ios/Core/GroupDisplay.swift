import Foundation
import MarmotKit

/// Shared rules for how a group is titled and avatared across the chats list
/// and the conversation header:
///   1. a named group shows its (sanitized) name;
///   2. an unnamed group with >2 members shows "<count> person group";
///   3. an unnamed 2-member group renders as the other person — their known
///      display name, or their npub when no profile name is known.
enum GroupDisplay {
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

    static func title(
        group: AppGroupRecordFfi,
        otherMember: String?,
        memberCount: Int,
        appState: AppState
    ) -> String {
        if let name = ProfileSanitizer.groupName(group.name) { return name }
        if memberCount > 2 { return L10n.formatted("%lld person group", Int64(memberCount)) }
        if memberCount == 2, let other = otherMember {
            return appState.knownDisplayName(forAccountIdHex: other)
                ?? appState.shortNpub(forAccountIdHex: other)
        }
        return IdentityFormatter.short(group.groupIdHex)
    }

    /// Avatar picture for the row/header: a group avatar URL wins when present,
    /// then unnamed 2-member DMs fall back to the other member's picture.
    static func avatarURL(
        group: AppGroupRecordFfi,
        otherMember: String?,
        memberCount: Int,
        appState: AppState
    ) -> URL? {
        if let groupAvatar = ProfileSanitizer.imageURL(group.avatarUrl) {
            return groupAvatar
        }
        guard isDirectMessage(group: group, memberCount: memberCount),
              let other = otherMember else { return nil }
        return appState.avatarURL(forAccountIdHex: other)
    }

    /// Deterministic color seed — keyed on the other member for an unnamed DM
    /// so their color matches wherever else they appear; otherwise the group.
    static func avatarSeed(
        group: AppGroupRecordFfi,
        otherMember: String?,
        memberCount: Int
    ) -> String {
        if isDirectMessage(group: group, memberCount: memberCount), let other = otherMember {
            return other
        }
        return group.groupIdHex
    }

    /// An unnamed group with exactly two members renders as a 1:1 DM.
    private static func isDirectMessage(group: AppGroupRecordFfi, memberCount: Int) -> Bool {
        ProfileSanitizer.groupName(group.name) == nil && memberCount == 2
    }
}
