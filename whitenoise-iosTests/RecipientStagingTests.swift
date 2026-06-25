import Testing
@testable import whitenoise_ios
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

    @Test func pendingInputDeduplicatesAgainstMembersAddedDuringNormalizeAwait() async {
        let staging = RecipientStagingModel()
        let account = hex("44")
        let concurrentAdd = stagedMember(memberRef: "npub1concurrent", accountIdHex: account)
        let normalized = stagedMember(memberRef: hex("55"), accountIdHex: account)
        let gate = NormalizeGate()
        staging.pending = normalized.memberRef
        var warmedAccounts: [String] = []

        let addTask = Task { @MainActor in
            await staging.addPending(
                normalize: { _ in
                    await gate.markStartedAndWait()
                    return normalized
                },
                warmProfile: { warmedAccounts.append($0) }
            )
        }

        await gate.waitUntilStarted()
        staging.members = [concurrentAdd]
        await gate.resume()
        let result = await addTask.value

        #expect(result)
        #expect(staging.members == [concurrentAdd])
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
            "\(DeepLink.scheme)://profile/\(npub)",
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

private actor NormalizeGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func markStartedAndWait() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
