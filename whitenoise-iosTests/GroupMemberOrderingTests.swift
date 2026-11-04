import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupMemberOrderingTests {
    @Test func lightweightRosterProjectionPreservesMembershipAndLifecycleState() {
        let selfMember = member("self", isSelf: true, isAdmin: true)
        let peer = member("peer")
        let roster = GroupRosterFfi(
            groupIdHex: "group",
            members: [selfMember, peer],
            epoch: 12,
            rosterRevision: 15,
            selfMembership: .removed,
            memberCount: 2,
            lifecycleState: .disbanded
        )

        let projection = ConversationGroupRosterProjection(roster: roster)

        #expect(projection.memberRecords.map(\.memberIdHex) == ["self", "peer"])
        #expect(projection.memberDetails == [selfMember, peer])
        #expect(projection.adminIdsHex == ["self"])
        #expect(projection.selfMembership == .removed)
        #expect(!projection.isUnrecoverable)
        #expect(projection.isDisbanded)
        #expect(projection.revision == 15)
    }

    @Test func ordersSelfThenAdminsThenNamesWithStableTiebreak() {
        let you = member("11", isSelf: true)
        let admin = member("22", isAdmin: true)
        let zoe = member("33")
        let anna = member("44")
        let names = ["11": "Zed", "22": "Boss", "33": "zoe", "44": "Anna"]

        let ordered = GroupMemberOrdering.ordered([zoe, anna, admin, you], namesByMemberId: names)

        #expect(ordered.map(\.memberIdHex) == [you, admin, anna, zoe].map(\.memberIdHex))
    }

    @Test func equalNamesFallBackToMemberIdOrder() {
        let one = member("22")
        let two = member("11")
        let names = ["11": "Same", "22": "Same"]

        let ordered = GroupMemberOrdering.ordered([one, two], namesByMemberId: names)

        #expect(ordered.map(\.memberIdHex) == [two, one].map(\.memberIdHex))
    }

    @Test func filtersByNameCaseInsensitivelyAndByNpubPrefix() {
        let anna = member("11", npub: "npub1anna")
        let zoe = member("22", npub: "npub1zoe")
        let names = ["11": "Anna Ström", "22": "Zoe"]

        let byName = GroupMemberOrdering.filtered([anna, zoe], query: "  ström", namesByMemberId: names)
        let byNpub = GroupMemberOrdering.filtered([anna, zoe], query: "npub1z", namesByMemberId: names)
        let all = GroupMemberOrdering.filtered([anna, zoe], query: "  ", namesByMemberId: names)

        #expect(byName.map(\.memberIdHex) == ["11"])
        #expect(byNpub.map(\.memberIdHex) == ["22"])
        #expect(all.count == 2)
    }

    @Test func previewCollapsesOnlyWhenNotSearchingOrExpanded() {
        let members = (0..<9).map { member("\($0)") }

        let collapsed = GroupMemberOrdering.visible(members, isSearching: false, isExpanded: false)
        let searching = GroupMemberOrdering.visible(members, isSearching: true, isExpanded: false)
        let expanded = GroupMemberOrdering.visible(members, isSearching: false, isExpanded: true)
        let small = GroupMemberOrdering.visible(
            Array(members.prefix(3)),
            isSearching: false,
            isExpanded: false
        )

        #expect(collapsed.count == GroupMemberOrdering.previewCount)
        #expect(searching.count == 9)
        #expect(expanded.count == 9)
        #expect(small.count == 3)
    }

    @MainActor
    @Test func projectionCacheDoesNotResolveAndSortAgainForSearchTextChanges() {
        let members = [member("22"), member("11")]
        let cache = GroupMemberListProjectionCache()
        var resolutionCount = 0
        let resolve: (GroupMemberDetailsFfi) -> String = { member in
            resolutionCount += 1
            return member.memberIdHex == "11" ? "Anna" : "Zoe"
        }

        let first = cache.projection(
            members: members,
            profileGeneration: 3,
            resolveName: resolve
        )
        let filtered = GroupMemberOrdering.filtered(
            first.orderedMembers,
            query: "ann",
            namesByMemberId: first.namesByMemberId
        )
        #expect(filtered.map(\.memberIdHex) == ["11"])
        let second = cache.projection(
            members: members,
            profileGeneration: 3,
            resolveName: resolve
        )

        #expect(second.orderedMembers.map(\.memberIdHex) == ["11", "22"])
        #expect(resolutionCount == members.count)

        _ = cache.projection(
            members: members,
            profileGeneration: 4,
            resolveName: resolve
        )
        #expect(resolutionCount == members.count * 2)
    }

    private func member(
        _ id: String,
        isSelf: Bool = false,
        isAdmin: Bool = false,
        npub: String = "npub1x"
    ) -> GroupMemberDetailsFfi {
        GroupMemberDetailsFfi(
            memberIdHex: id,
            account: nil,
            local: isSelf,
            isAdmin: isAdmin,
            isSelf: isSelf,
            npub: npub,
            displayName: nil
        )
    }
}
