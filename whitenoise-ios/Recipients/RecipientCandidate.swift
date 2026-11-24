import Foundation
import MarmotKit

/// One person reachable from the active account's current Marmot-backed chat
/// state. Derived on demand — never persisted — so Marmot stays the only
/// durable store of who the user talks to.
nonisolated struct RecipientCandidate: Equatable, Identifiable {
    let accountIdHex: String
    let npub: String
    /// Newest activity timestamp across every group this person appears in.
    let lastActivityAt: UInt64
    /// Group id of the most recent open unnamed two-person chat with this
    /// person, when one exists. Canonical single-chat surfaces can reuse it.
    let directChatGroupIdHex: String?
    /// How many chats this person appears in (identity context).
    let sharedChatCount: Int
    /// Search-only profile metadata returned by Marmot. It stays ephemeral:
    /// showing a result must not promote a stranger into the local directory.
    let searchProfile: UserProfileMetadataFfi?
    /// Social distance from the active account. `nil` identifies a candidate
    /// derived from existing chat state rather than live discovery.
    let searchRadius: UInt8?
    /// Direct follow relationship reported by Marmot search. Radius 1 alone
    /// is not enough because it also includes shared-group peers.
    let isFollowedBySearcher: Bool

    init(
        accountIdHex: String,
        npub: String,
        lastActivityAt: UInt64,
        directChatGroupIdHex: String?,
        sharedChatCount: Int,
        searchProfile: UserProfileMetadataFfi? = nil,
        searchRadius: UInt8? = nil,
        isFollowedBySearcher: Bool = false
    ) {
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.lastActivityAt = lastActivityAt
        self.directChatGroupIdHex = directChatGroupIdHex
        self.sharedChatCount = sharedChatCount
        self.searchProfile = searchProfile
        self.searchRadius = searchRadius
        self.isFollowedBySearcher = isFollowedBySearcher
    }

    var id: String { accountIdHex }
}

/// Screen-lifetime projection of one chat-list row plus its member roster,
/// the minimal inputs candidate derivation and shared-group projection need.
nonisolated struct RecipientGroupSnapshot: Equatable {
    let groupIdHex: String
    /// Sanitized group name; `nil` means unnamed. The row `title` is not a
    /// fallback here — for a direct message it carries the peer's name, which
    /// would make every unnamed two-person chat look like a named group.
    let sanitizedName: String?
    let title: String
    let avatarUrl: String?
    let imageHashHex: String?
    let isArchived: Bool
    let isSelfMember: Bool
    let pendingConfirmation: Bool
    let conversationKind: ChatConversationKindFfi
    let lastActivityAt: UInt64
    let memberIdsHex: [String]
    let lastSenderIdHex: String?
    let welcomerIdHex: String?
    /// Group admins, for "can I add someone to this group" projections.
    let adminIdsHex: [String]

    init(row: ChatListRowFfi, details: GroupDetailsFfi?) {
        self.init(
            row: row,
            memberIdsHex: details?.members.map(GroupMemberDetailsPresentation.profileAccountIdHex) ?? [],
            adminIdsHex: details?.group.admins ?? [],
            groupName: details?.group.name,
            avatarUrl: details?.group.avatarUrl,
            imageHashHex: details?.group.imageHashHex,
            welcomerIdHex: details?.group.welcomerAccountIdHex,
            pendingConfirmation: row.pendingConfirmation || details?.group.pendingConfirmation == true
        )
    }

    init(
        row: ChatListRowFfi,
        memberIdsHex: [String],
        adminIdsHex: [String] = [],
        groupName: String? = nil,
        avatarUrl: String? = nil,
        imageHashHex: String? = nil,
        welcomerIdHex: String? = nil,
        pendingConfirmation: Bool? = nil
    ) {
        let isPending = pendingConfirmation ?? row.pendingConfirmation
        self.init(
            groupIdHex: row.groupIdHex,
            sanitizedName: ContentSanitizer.groupName(groupName ?? row.groupName),
            title: ContentSanitizer.groupName(row.groupName)
                ?? ContentSanitizer.groupName(row.title)
                ?? IdentityFormatter.short(row.groupIdHex),
            avatarUrl: isPending ? nil : (avatarUrl ?? row.avatarUrl),
            imageHashHex: isPending ? nil : (imageHashHex ?? row.avatar?.imageHashHex),
            isArchived: row.archived,
            isSelfMember: GroupManagementPresentation.isActiveChatListMember(row.selfMembership),
            conversationKind: row.conversationKind,
            lastActivityAt: row.lastMessage?.timelineAt ?? row.updatedAt,
            memberIdsHex: memberIdsHex,
            lastSenderIdHex: row.lastMessage?.sender,
            welcomerIdHex: welcomerIdHex,
            adminIdsHex: adminIdsHex,
            pendingConfirmation: isPending
        )
    }

    init(
        groupIdHex: String,
        sanitizedName: String?,
        title: String,
        avatarUrl: String?,
        imageHashHex: String? = nil,
        isArchived: Bool = false,
        isSelfMember: Bool,
        conversationKind: ChatConversationKindFfi = .unknown,
        lastActivityAt: UInt64,
        memberIdsHex: [String],
        lastSenderIdHex: String?,
        welcomerIdHex: String?,
        adminIdsHex: [String] = [],
        pendingConfirmation: Bool = false
    ) {
        self.groupIdHex = groupIdHex
        self.sanitizedName = sanitizedName
        self.title = title
        self.avatarUrl = pendingConfirmation ? nil : avatarUrl
        self.imageHashHex = pendingConfirmation ? nil : imageHashHex
        self.isArchived = isArchived
        self.isSelfMember = isSelfMember
        self.pendingConfirmation = pendingConfirmation
        self.conversationKind = conversationKind
        self.lastActivityAt = lastActivityAt
        self.memberIdsHex = memberIdsHex
        self.lastSenderIdHex = lastSenderIdHex
        self.welcomerIdHex = welcomerIdHex
        self.adminIdsHex = adminIdsHex
    }

    /// An open, unnamed two-person chat — the only kind a person-tap may
    /// reuse. Renamed or left conversations don't count, matching how the
    /// chats list renders direct messages.
    func isDirectChat(withMember targetIdHex: String, myAccountIdHex: String) -> Bool {
        guard conversationKind != .group,
              sanitizedName == nil,
              isSelfMember,
              memberIdsHex.count == 2
        else { return false }
        let normalized = Set(memberIdsHex.map { $0.lowercased() })
        return normalized == [targetIdHex.lowercased(), myAccountIdHex.lowercased()]
    }
}

/// One existing two-person conversation offered when starting a chat with a
/// person. The match intentionally ignores MDK's derived conversation kind so
/// named two-person groups remain reachable while direct/group semantics are
/// still tied to the group name.
nonisolated struct ConversationChoice: Equatable, Identifiable {
    let groupIdHex: String
    let name: String?
    let avatarUrl: String?
    let imageHashHex: String?
    let isArchived: Bool
    let lastActivityAt: UInt64
    var pendingConfirmation: Bool = false

    var id: String { groupIdHex }
}

nonisolated struct ConversationChooserPresentation: Equatable, Identifiable {
    let targetAccountIdHex: String
    let memberRef: String
    let recipientName: String
    let choices: [ConversationChoice]

    var id: String { targetAccountIdHex }
}

nonisolated enum ConversationChoiceProjection {
    static func choices(
        in snapshots: [RecipientGroupSnapshot],
        targetAccountIdHex: String,
        myAccountIdHex: String
    ) -> [ConversationChoice] {
        let expectedMembers = Set([
            targetAccountIdHex.lowercased(),
            myAccountIdHex.lowercased()
        ])

        return snapshots
            .filter { snapshot in
                guard snapshot.isSelfMember, snapshot.memberIdsHex.count == 2 else {
                    return false
                }
                return Set(snapshot.memberIdsHex.map { $0.lowercased() }) == expectedMembers
            }
            .map { snapshot in
                ConversationChoice(
                    groupIdHex: snapshot.groupIdHex,
                    name: snapshot.sanitizedName,
                    avatarUrl: snapshot.pendingConfirmation ? nil : snapshot.avatarUrl,
                    imageHashHex: snapshot.pendingConfirmation ? nil : snapshot.imageHashHex,
                    isArchived: snapshot.isArchived,
                    lastActivityAt: snapshot.lastActivityAt,
                    pendingConfirmation: snapshot.pendingConfirmation
                )
            }
            .sorted {
                if $0.lastActivityAt != $1.lastActivityAt {
                    return $0.lastActivityAt > $1.lastActivityAt
                }
                return $0.groupIdHex < $1.groupIdHex
            }
    }
}

nonisolated enum DirectChatReuseLookup {
    static func shouldInspect(
        conversationKind: ChatConversationKindFfi,
        selfMembership: SelfMembershipFfi
    ) -> Bool {
        GroupManagementPresentation.isActiveChatListMember(selfMembership)
            && conversationKind != .group
    }

    static func existingGroupId(
        in snapshots: [RecipientGroupSnapshot],
        targetAccountIdHex: String,
        myAccountIdHex: String
    ) -> String? {
        snapshots
            .filter {
                $0.isDirectChat(
                    withMember: targetAccountIdHex,
                    myAccountIdHex: myAccountIdHex
                )
            }
            .max { $0.lastActivityAt < $1.lastActivityAt }?
            .groupIdHex
    }
}

nonisolated enum RecipientCandidateDerivation {
    /// Derives people from chat snapshots, newest conversation activity first.
    /// Every roster member, last-message sender, and group welcomer is a
    /// source; the active account is excluded and the first (most recent)
    /// appearance fixes a person's position.
    static func candidates(
        from snapshots: [RecipientGroupSnapshot],
        myAccountIdHex: String?
    ) -> [RecipientCandidate] {
        let myHex = myAccountIdHex?.lowercased()
        let recencyOrdered = snapshots.sorted { $0.lastActivityAt > $1.lastActivityAt }

        var order: [String] = []
        var lastActivity: [String: UInt64] = [:]
        var directChat: [String: String] = [:]
        var sharedCount: [String: Int] = [:]
        var npubs: [String: String] = [:]

        for snapshot in recencyOrdered {
            var seenInThisGroup: Set<String> = []
            let note = { (rawHex: String?) in
                guard let rawHex else { return }
                let hex = rawHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard Hex.is32Bytes(hex), hex != myHex else { return }
                guard let npub = npubs[hex] ?? NostrProfileReference.npub(fromAccountIdHex: hex) else { return }
                npubs[hex] = npub
                if lastActivity[hex] == nil {
                    order.append(hex)
                    lastActivity[hex] = snapshot.lastActivityAt
                }
                if seenInThisGroup.insert(hex).inserted {
                    sharedCount[hex, default: 0] += 1
                }
                if directChat[hex] == nil, let myHex,
                   snapshot.isDirectChat(withMember: hex, myAccountIdHex: myHex) {
                    directChat[hex] = snapshot.groupIdHex
                }
            }

            for member in snapshot.memberIdsHex {
                note(member)
            }
            note(snapshot.lastSenderIdHex)
            note(snapshot.welcomerIdHex)
        }

        return order.map { hex in
            RecipientCandidate(
                accountIdHex: hex,
                npub: npubs[hex] ?? hex,
                lastActivityAt: lastActivity[hex] ?? 0,
                directChatGroupIdHex: directChat[hex],
                sharedChatCount: sharedCount[hex] ?? 0
            )
        }
    }
}
