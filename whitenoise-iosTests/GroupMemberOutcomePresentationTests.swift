import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct GroupMemberOutcomePresentationTests {
    private func outcome(_ seed: Character, _ status: MemberResolutionStatusFfi) -> MemberResolutionOutcomeFfi {
        MemberResolutionOutcomeFfi(accountIdHex: String(repeating: seed, count: 64), status: status,
                                   selectedDeviceCount: status == .selected ? 1 : 0)
    }

    @Test func onlyAccountsMDKDidNotSelectAreReported() {
        let outcomes = [outcome("a", .selected), outcome("b", .missingKeyPackage), outcome("c", .incomplete)]
        #expect(GroupMemberOutcomePresentation.skipped(outcomes).map(\.status) == [.missingKeyPackage, .incomplete])
        #expect(GroupMemberOutcomePresentation.selectedCount(outcomes) == 1)
        #expect(GroupMemberOutcomePresentation.notice(for: [], knownName: { _ in "Alex" }) == nil)
    }

    @Test func aNamedPersonIsNamedAndAnUnknownOneNeverShowsTheirKey() {
        let missing = outcome("b", .missingKeyPackage)
        let named = GroupMemberOutcomePresentation.notice(for: [missing], knownName: { _ in "Alex" })
        #expect(named?.title == "Couldn't add this person")
        #expect(named?.message == "Alex isn't on White Noise yet.")

        for status in [MemberResolutionStatusFfi.missingKeyPackage, .obsoleteKeyPackage, .invalidKeyPackage,
                       .incompatibleKeyPackage, .missingInboxRoute, .incomplete] {
            let skipped = outcome("d", status)
            let message = GroupMemberOutcomePresentation.message(for: [skipped], knownName: { _ in nil })
            #expect(!message.isEmpty)
            #expect(!message.contains(skipped.accountIdHex))
        }
    }

    @Test func outdatedAndIncompatibleAppsAreAskedToUpdateNotInstall() {
        for status in [MemberResolutionStatusFfi.obsoleteKeyPackage, .incompatibleKeyPackage] {
            #expect(GroupMemberOutcomePresentation.message(
                accountIdHex: String(repeating: "b", count: 64), status: status, knownName: "Alex"
            ) == "Alex needs to update their app before they can be invited.")
        }
    }

    @Test func longListsNameAFewPeopleAndCountTheRest() throws {
        let seeds: [Character] = ["b", "c", "d", "e", "f"]
        let skipped = seeds.map { outcome($0, .missingKeyPackage) }
        let notice = try #require(GroupMemberOutcomePresentation.notice(for: skipped, knownName: { _ in "Alex" }))
        let lines = notice.message.split(separator: "\n")
        #expect(lines.count == GroupMemberOutcomePresentation.maxListedNames + 1)
        #expect(lines.last == "2 more couldn't be added.")
        #expect(notice.title == "Couldn't add 5 people")
    }

    @Test func aResultWithoutAnOperationThrowsWithOnlyTheSkippedAccounts() throws {
        let outcomes = [outcome("b", .missingInboxRoute)]
        #expect(throws: GroupMembersUnavailableError(skipped: outcomes)) {
            try DetailedGroupCreationResultFfi(created: nil, memberOutcomes: outcomes).requireCreated()
        }
        #expect(throws: GroupMembersUnavailableError(skipped: outcomes)) {
            try InviteMembersResultFfi(summary: nil, memberOutcomes: outcomes).requireSummary()
        }
        // An empty request still creates a creator-only group.
        let created = CreatedGroupFfi(groupIdHex: "group", chatListRow: chatListRow(groupIdHex: "group", title: "Group"))
        #expect(try DetailedGroupCreationResultFfi(created: created, memberOutcomes: []).requireCreated() == created)
    }
}
