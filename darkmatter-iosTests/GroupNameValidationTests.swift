import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// #80 — a group rename must reject an empty/whitespace name so the shared group
/// name can't be silently blanked.
@MainActor
struct GroupNameValidationTests {

    @Test func rejectsEmptyOrWhitespaceDraft() {
        #expect(GroupDetailsView.validatedGroupName("") == nil)
        #expect(GroupDetailsView.validatedGroupName("   \n\t ") == nil)
    }

    @Test func trimsAndAcceptsNonEmptyName() {
        #expect(GroupDetailsView.validatedGroupName("  Team Rocket  ") == "Team Rocket")
    }

    @Test func renameDraftSanitizesAndCapsGroupName() throws {
        let hostile = "\u{202E}Team\nRocket" + String(repeating: "x", count: 150)
        let sanitized = try #require(GroupDetailsView.validatedGroupName(hostile))

        #expect(sanitized.hasPrefix("Team Rocket"))
        #expect(!sanitized.contains("\u{202E}"))
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.count == ProfileSanitizer.maxGroupNameLength)
    }

    @Test func newChatGroupNameUsesSanitizedEmptyStringSentinel() {
        #expect(NewChatSheet.normalizedGroupName("") == "")
        #expect(NewChatSheet.normalizedGroupName(" \n\t ") == "")
        #expect(NewChatSheet.normalizedGroupName(" \u{202E}Research\nLab ") == "Research Lab")
    }

    @Test func newChatGroupDescriptionSanitizesCapsAndDropsBlankValues() {
        #expect(NewChatSheet.normalizedGroupDescription("") == nil)
        #expect(NewChatSheet.normalizedGroupDescription(" \n\t ") == nil)
        let description = NewChatSheet.normalizedGroupDescription("  Mission\u{202E}\n\n\nnotes  ")
        #expect(description == "Mission\n\nnotes")

        let oversized = NewChatSheet.normalizedGroupDescription(String(repeating: "x", count: 500))
        #expect(oversized?.count == ProfileSanitizer.maxGroupDescriptionLength)
    }

    @Test func newChatPendingRecipientRejectsInvalidInputWithoutChangingMembers() {
        let existing = stagedMember(accountIdHex: String(repeating: "a", count: 64))
        let result = NewChatSheet.pendingMemberAddResult(
            "not a profile",
            existingMembers: [existing],
            normalize: { stagedMember(accountIdHex: $0) }
        )

        #expect(result == .invalid)
    }

    @Test func newChatPendingRecipientAppendsValidInput() {
        let existing = stagedMember(accountIdHex: String(repeating: "a", count: 64))
        let typed = String(repeating: "b", count: 64)
        let added = stagedMember(accountIdHex: typed)
        let result = NewChatSheet.pendingMemberAddResult(
            "  \(typed)\n",
            existingMembers: [existing],
            normalize: { stagedMember(accountIdHex: $0) }
        )

        #expect(result == .added([existing, added], added))
    }

    @Test func newChatPendingRecipientDeduplicatesNormalizedAccountId() {
        let existingAccount = String(repeating: "a", count: 64)
        let aliasRef = String(repeating: "b", count: 64)
        let existing = stagedMember(memberRef: "npub1existing", accountIdHex: existingAccount)
        let result = NewChatSheet.pendingMemberAddResult(
            aliasRef,
            existingMembers: [existing],
            normalize: { stagedMember(memberRef: $0, accountIdHex: existingAccount) }
        )

        #expect(result == .duplicate)
    }

    @Test func newChatPendingRecipientAcceptsScannedProfileLinks() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let accountId = String(repeating: "c", count: 64)
        let added = stagedMember(memberRef: npub, accountIdHex: accountId)
        let result = NewChatSheet.pendingMemberAddResult(
            "darkmatter://profile/\(npub)",
            existingMembers: [],
            normalize: { stagedMember(memberRef: $0, accountIdHex: accountId) }
        )

        #expect(result == .added([added], added))
    }

    private func stagedMember(
        memberRef: String? = nil,
        accountIdHex: String
    ) -> MemberRefFfi {
        MemberRefFfi(
            memberRef: memberRef ?? accountIdHex,
            accountIdHex: accountIdHex,
            npub: "npub1\(accountIdHex.prefix(8))"
        )
    }
}
