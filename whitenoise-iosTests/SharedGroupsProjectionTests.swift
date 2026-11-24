import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct SharedGroupsProjectionTests {
    private let me = String(repeating: "aa", count: 32)
    private let alice = String(repeating: "bb", count: 32)
    private let bob = String(repeating: "cc", count: 32)

    @Test func includesEveryGroupContainingBothPartiesAndClassifiesDirectMessages() {
        let shared = snapshot("g1", name: "Team", members: [me, alice, bob], activity: 5)
        let namedPair = snapshot("g6", name: "Us two", members: [me, alice], activity: 7)
        let directChat = snapshot("g2", name: nil, members: [me, alice], activity: 9)
        let unnamed = snapshot("g3", name: nil, members: [me, alice, bob], activity: 9)
        let withoutTarget = snapshot("g4", name: "Others", members: [me, bob, String(repeating: "dd", count: 32)], activity: 9)
        let withoutMe = snapshot("g5", name: "Their group", members: [alice, bob, String(repeating: "ee", count: 32)], activity: 9)

        let result = SharedGroupsProjection.sharedGroups(
            snapshots: [shared, namedPair, directChat, unnamed, withoutTarget, withoutMe],
            targetAccountIdHex: alice,
            myAccountIdHex: me
        )

        #expect(result.map(\.groupIdHex) == ["g2", "g3", "g6", "g1"])
        #expect(result.map(\.isDirectMessage) == [true, false, false, false])
        #expect(result[0].memberCount == 2)
        #expect(result[1].memberCount == 3)
        #expect(result[2].title == "Us two")
        #expect(result[3].title == "Team")
    }

    @Test func ordersByMostRecentActivity() {
        let older = snapshot("g-old", name: "Old", members: [me, alice, bob], activity: 2)
        let newer = snapshot("g-new", name: "New", members: [me, alice, bob], activity: 8)

        let result = SharedGroupsProjection.sharedGroups(
            snapshots: [older, newer],
            targetAccountIdHex: alice,
            myAccountIdHex: me
        )

        #expect(result.map(\.groupIdHex) == ["g-new", "g-old"])
    }

    @Test func hiddenForSelfUnresolvedOrLeftGroups() {
        let left = snapshot("g1", name: "Team", members: [me, alice, bob], isSelfMember: false, activity: 5)

        #expect(
            SharedGroupsProjection.sharedGroups(
                snapshots: [left],
                targetAccountIdHex: alice,
                myAccountIdHex: me
            ).isEmpty
        )
        #expect(
            SharedGroupsProjection.sharedGroups(
                snapshots: [snapshot("g2", name: "Team", members: [me, alice, bob], activity: 1)],
                targetAccountIdHex: me,
                myAccountIdHex: me
            ).isEmpty
        )
        #expect(
            SharedGroupsProjection.sharedGroups(
                snapshots: [snapshot("g3", name: "Team", members: [me, alice, bob], activity: 1)],
                targetAccountIdHex: nil,
                myAccountIdHex: me
            ).isEmpty
        )
    }

    @Test func matchesRosterEntriesCaseInsensitively() {
        let shared = snapshot("g1", name: "Team", members: [me.uppercased(), alice.uppercased(), bob], activity: 5)

        let result = SharedGroupsProjection.sharedGroups(
            snapshots: [shared],
            targetAccountIdHex: alice,
            myAccountIdHex: " \(me.uppercased()) "
        )

        #expect(result.map(\.groupIdHex) == ["g1"])
    }

    @Test func excludesPendingConfirmationInvitesFromSharedAndAddableGroupsAndSuppressesAvatars() {
        let pendingRow = chatListRow(
            groupIdHex: "pending-group",
            pendingConfirmation: true,
            title: "Unaccepted Invite",
            avatar: ChatListAvatarFfi(
                imageHashHex: hex("dd"),
                imageKeyHex: hex("11"),
                imageNonceHex: String(repeating: "22", count: 12),
                imageUploadKeyHex: hex("33"),
                mediaType: "image/jpeg"
            ),
            avatarUrl: "https://attacker.example/group.png",
            updatedAt: 20
        )
        let pendingSnapshot = RecipientGroupSnapshot(
            row: pendingRow,
            memberIdsHex: [me, alice, bob],
            adminIdsHex: [me]
        )
        #expect(pendingSnapshot.pendingConfirmation)
        #expect(pendingSnapshot.avatarUrl == nil)
        #expect(pendingSnapshot.imageHashHex == nil)

        let acceptedShared = snapshot(
            "accepted-shared",
            name: "Accepted Team",
            members: [me, alice, bob],
            activity: 10
        )
        let acceptedAddable = RecipientGroupSnapshot(
            groupIdHex: "accepted-addable",
            sanitizedName: "Admin Room",
            title: "Admin Room",
            avatarUrl: "https://cdn.example/room.png",
            imageHashHex: hex("ee"),
            isSelfMember: true,
            lastActivityAt: 15,
            memberIdsHex: [me, bob],
            lastSenderIdHex: nil,
            welcomerIdHex: nil,
            adminIdsHex: [me]
        )
        let pendingAddable = RecipientGroupSnapshot(
            groupIdHex: "pending-addable",
            sanitizedName: "Pending Admin Room",
            title: "Pending Admin Room",
            avatarUrl: "https://attacker.example/admin-room.png",
            imageHashHex: hex("ff"),
            isSelfMember: true,
            lastActivityAt: 25,
            memberIdsHex: [me, bob],
            lastSenderIdHex: nil,
            welcomerIdHex: nil,
            adminIdsHex: [me],
            pendingConfirmation: true
        )
        #expect(pendingAddable.avatarUrl == nil)
        #expect(pendingAddable.imageHashHex == nil)

        let shared = SharedGroupsProjection.sharedGroups(
            snapshots: [pendingSnapshot, acceptedShared],
            targetAccountIdHex: alice,
            myAccountIdHex: me
        )
        #expect(shared.map(\.groupIdHex) == ["accepted-shared"])

        let addable = SharedGroupsProjection.addableGroups(
            snapshots: [pendingAddable, acceptedAddable],
            targetAccountIdHex: alice,
            myAccountIdHex: me
        )
        #expect(addable.map(\.groupIdHex) == ["accepted-addable"])
    }

    private func snapshot(
        _ groupIdHex: String,
        name: String?,
        members: [String],
        isSelfMember: Bool = true,
        activity: UInt64
    ) -> RecipientGroupSnapshot {
        RecipientGroupSnapshot(
            groupIdHex: groupIdHex,
            sanitizedName: name,
            title: name ?? groupIdHex,
            avatarUrl: nil,
            isSelfMember: isSelfMember,
            lastActivityAt: activity,
            memberIdsHex: members,
            lastSenderIdHex: nil,
            welcomerIdHex: nil
        )
    }
}
