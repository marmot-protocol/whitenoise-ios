import Testing
@testable import darkmatter_ios
@testable import MarmotKit

@MainActor
struct RecipientStagingTests {

    @Test func emptyPendingInputIsIgnoredWithoutNormalizing() async {
        let staging = RecipientStagingModel()
        staging.pending = "  \n\t  "

        let result = await staging.addPending(normalize: { _ in throw TestError.unexpectedNormalize })

        #expect(result)
        #expect(staging.members.isEmpty)
        #expect(staging.pending == "  \n\t  ")
        #expect(staging.error == nil)
    }

    @Test func invalidPendingInputSetsValidationErrorAndKeepsState() async {
        let staging = RecipientStagingModel()
        staging.pending = "not a profile"
        staging.members = [stagedMember(accountIdHex: hex("11"))]

        let result = await staging.addPending(invalidMessage: "invalid recipient", normalize: { memberRef in
            stagedMember(accountIdHex: memberRef)
        })

        #expect(!result)
        #expect(staging.members == [stagedMember(accountIdHex: hex("11"))])
        #expect(staging.pending == "not a profile")
        #expect(staging.error == "invalid recipient")
    }

    @Test func validPendingInputAppendsClearsAndWarmsProfile() async {
        let staging = RecipientStagingModel()
        let existing = stagedMember(accountIdHex: hex("11"))
        let candidate = stagedMember(accountIdHex: hex("22"))
        staging.members = [existing]
        staging.pending = "  \(candidate.accountIdHex)\n"
        var warmedAccounts: [String] = []

        let result = await staging.addPending(
            normalize: { stagedMember(accountIdHex: $0) },
            warmProfile: { warmedAccounts.append($0) }
        )

        #expect(result)
        #expect(staging.members == [existing, candidate])
        #expect(staging.pending.isEmpty)
        #expect(staging.error == nil)
        #expect(warmedAccounts == [candidate.accountIdHex])
    }

    @Test func duplicatePendingInputDeduplicatesByNormalizedAccountId() async {
        let staging = RecipientStagingModel()
        let account = hex("33")
        let existing = stagedMember(memberRef: "npub1existing", accountIdHex: account)
        staging.members = [existing]
        staging.pending = hex("44")
        var warmedAccounts: [String] = []

        let result = await staging.addPending(
            normalize: { stagedMember(memberRef: $0, accountIdHex: account) },
            warmProfile: { warmedAccounts.append($0) }
        )

        #expect(result)
        #expect(staging.members == [existing])
        #expect(staging.pending.isEmpty)
        #expect(staging.error == nil)
        #expect(warmedAccounts.isEmpty)
    }

    @Test func scannedProfileLinkStagesMember() async {
        let staging = RecipientStagingModel()
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let account = hex("55")
        let added = stagedMember(memberRef: npub, accountIdHex: account)

        let result = await staging.addScanned(
            "darkmatter://profile/\(npub)",
            normalize: { stagedMember(memberRef: $0, accountIdHex: account) }
        )

        #expect(result)
        #expect(staging.members == [added])
        #expect(staging.error == nil)
    }

    @Test func olderAddDoesNotClearNewerPendingText() {
        let staging = RecipientStagingModel()
        staging.pending = "newer text"

        staging.clearPendingIfUnchanged("older text")

        #expect(staging.pending == "newer text")
    }

    private enum TestError: Error {
        case unexpectedNormalize
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

    private func hex(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }
}
