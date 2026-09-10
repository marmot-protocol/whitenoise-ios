import Foundation
import MarmotKit

nonisolated enum AddMembersPresentation {
    enum PendingMemberAddResult: Equatable {
        case empty
        case invalid
        case duplicate
        case blocked
        case added([MemberRefFfi], MemberRefFfi)
    }

    /// Outcome of normalizing a raw member reference off the main actor,
    /// before it is staged against the live member list.
    enum NormalizedMemberResult: Equatable {
        case empty
        case invalid
        case normalized(MemberRefFfi)
    }

    static func memberRef(fromScannedPayload raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // MarmotKit 0.9.7 normalizes npub/hex member references but not the
        // nprofile TLV wrapper. Decode a validated nprofile to canonical hex at
        // the app boundary so lookup and group creation share one supported
        // runtime input while still applying relay-hint validation first.
        return NostrProfileReference.memberRef(from: trimmed)
    }

    /// Parses and normalizes a raw member reference. The `normalize` closure
    /// is expected to run the synchronous MarmotKit FFI off the main actor
    /// (#260), so callers can `await` this and only hop back to the MainActor
    /// to stage the result.
    static func normalizedMember(
        _ raw: String,
        normalize: (String) async throws -> MemberRefFfi
    ) async -> NormalizedMemberResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let memberRef = memberRef(fromScannedPayload: trimmed) else {
            return .invalid
        }
        do {
            return .normalized(try await normalize(memberRef))
        } catch {
            return .invalid
        }
    }

    /// Stages a normalized member against the current member list. Pure and
    /// MainActor-cheap: callers run this after awaiting `normalizedMember` so
    /// the dedup check sees the live `members` value rather than a snapshot
    /// captured before the off-main hop.
    static func stage(
        _ normalized: MemberRefFfi,
        existingMembers: [MemberRefFfi],
        excludedAccountIds: Set<String> = []
    ) -> PendingMemberAddResult {
        let accountId = normalizedAccountId(normalized.accountIdHex)
        let blockedAccountIds = Set(excludedAccountIds.map(normalizedAccountId))
        guard !blockedAccountIds.contains(accountId) else {
            return .blocked
        }
        guard !existingMembers.contains(where: { normalizedAccountId($0.accountIdHex) == accountId }) else {
            return .duplicate
        }
        return .added(existingMembers + [normalized], normalized)
    }

    static var selfRecipientMessage: String { L10n.string("You can't add yourself to a chat.") }
    static var existingMemberMessage: String { L10n.string("That profile is already in this group.") }

    static func excludedNewChatAccountIds(activeAccountIdHex: String?) -> Set<String> {
        normalizedAccountSet([activeAccountIdHex])
    }

    static func excludedInviteAccountIds(
        activeAccountIdHex: String?,
        members: [AppGroupMemberRecordFfi],
        groupMemberDetails: [GroupMemberDetailsFfi]
    ) -> Set<String> {
        var accountIds = normalizedAccountSet([activeAccountIdHex])
        accountIds.formUnion(normalizedAccountSet(members.map(\.memberIdHex)))
        accountIds.formUnion(normalizedAccountSet(groupMemberDetails.map(\.memberIdHex)))
        return accountIds
    }

    /// A group may start empty when it has a usable name. Unnamed groups still
    /// need at least one staged peer because an empty unnamed group has no useful
    /// identity in the chat list.
    static func canCreate(
        stagedCount: Int,
        hasUsableName: Bool,
        isCreating: Bool,
        hasActiveAccount: Bool
    ) -> Bool {
        (stagedCount > 0 || hasUsableName) && !isCreating && hasActiveAccount
    }

    /// "Invite" is enabled when no invite is in flight and at least one
    /// person is selected.
    static func canInvite(stagedCount: Int, isInviting: Bool) -> Bool {
        !isInviting && stagedCount > 0
    }

    @MainActor
    static func displayName(for member: MemberRefFfi, appState: AppState) -> String {
        IdentityPresentation.text(
            accountIdHex: member.accountIdHex,
            knownName: appState.knownDisplayName(forAccountIdHex: member.accountIdHex)
        )
    }

    static func secondaryIdentity(for member: MemberRefFfi) -> String {
        IdentityFormatter.short(member.npub)
    }

    private static func normalizedAccountSet(_ values: [String?]) -> Set<String> {
        Set(values.compactMap { value in
            value.map(normalizedAccountId).flatMap { $0.isEmpty ? nil : $0 }
        })
    }

    private static func normalizedAccountId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
