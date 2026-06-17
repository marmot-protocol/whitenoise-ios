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

    @Test func newChatPendingRecipientRejectsInvalidInputWithoutChangingMembers() async {
        let result = await NewChatSheet.normalizedMember(
            "not a profile",
            normalize: { stagedMember(accountIdHex: $0) }
        )

        #expect(result == .invalid)
    }

    @Test func newChatPendingRecipientAppendsValidInput() async {
        let existing = stagedMember(accountIdHex: String(repeating: "a", count: 64))
        let typed = String(repeating: "b", count: 64)
        let added = stagedMember(accountIdHex: typed)
        let normalized = await NewChatSheet.normalizedMember(
            "  \(typed)\n",
            normalize: { stagedMember(accountIdHex: $0) }
        )
        guard case .normalized(let member) = normalized else {
            Issue.record("expected normalized member")
            return
        }
        let result = NewChatSheet.stage(member, existingMembers: [existing])

        #expect(result == .added([existing, added], added))
    }

    @Test func newChatPendingRecipientDeduplicatesNormalizedAccountId() async {
        let existingAccount = String(repeating: "a", count: 64)
        let aliasRef = String(repeating: "b", count: 64)
        let existing = stagedMember(memberRef: "npub1existing", accountIdHex: existingAccount)
        let normalized = await NewChatSheet.normalizedMember(
            aliasRef,
            normalize: { stagedMember(memberRef: $0, accountIdHex: existingAccount) }
        )
        guard case .normalized(let member) = normalized else {
            Issue.record("expected normalized member")
            return
        }
        let result = NewChatSheet.stage(member, existingMembers: [existing])

        #expect(result == .duplicate)
    }

    @Test func newChatPendingRecipientAcceptsScannedProfileLinks() async {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let accountId = String(repeating: "c", count: 64)
        let added = stagedMember(memberRef: npub, accountIdHex: accountId)
        let normalized = await NewChatSheet.normalizedMember(
            "darkmatter://profile/\(npub)",
            normalize: { stagedMember(memberRef: $0, accountIdHex: accountId) }
        )
        guard case .normalized(let member) = normalized else {
            Issue.record("expected normalized member")
            return
        }
        let result = NewChatSheet.stage(member, existingMembers: [])

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
