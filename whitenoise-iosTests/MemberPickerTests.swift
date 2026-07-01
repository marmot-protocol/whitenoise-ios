import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct MemberPickerTests {

    @Test func emptyPendingInputIsIgnoredWithoutNormalizing() async {
        let picker = MemberPickerViewModel()
        picker.pending = "  \n\t  "

        let result = await picker.addPending(normalize: { _ in throw TestError.unexpectedNormalize })

        #expect(result)
        #expect(picker.members.isEmpty)
        #expect(picker.pending == "  \n\t  ")
        #expect(picker.error == nil)
    }

    @Test func invalidPendingInputSetsValidationErrorAndKeepsState() async {
        let picker = MemberPickerViewModel()
        picker.pending = "not a profile"
        picker.members = [stagedMember(accountIdHex: hex("11"))]

        let result = await picker.addPending(invalidMessage: "invalid member", normalize: { memberRef in
            stagedMember(accountIdHex: memberRef)
        })

        #expect(!result)
        #expect(picker.members == [stagedMember(accountIdHex: hex("11"))])
        #expect(picker.pending == "not a profile")
        #expect(picker.error == "invalid member")
    }

    @Test func validPendingInputAppendsClearsAndWarmsProfile() async {
        let picker = MemberPickerViewModel()
        let existing = stagedMember(accountIdHex: hex("11"))
        let candidate = stagedMember(accountIdHex: hex("22"))
        picker.members = [existing]
        picker.pending = "  \(candidate.accountIdHex)\n"
        var warmedAccounts: [String] = []

        let result = await picker.addPending(
            normalize: { stagedMember(accountIdHex: $0) },
            warmProfile: { warmedAccounts.append($0) }
        )

        #expect(result)
        #expect(picker.members == [existing, candidate])
        #expect(picker.pending.isEmpty)
        #expect(picker.error == nil)
        #expect(warmedAccounts == [candidate.accountIdHex])
    }

    @Test func duplicatePendingInputDeduplicatesByNormalizedAccountId() async {
        let picker = MemberPickerViewModel()
        let account = hex("33")
        let existing = stagedMember(memberRef: "npub1existing", accountIdHex: account)
        picker.members = [existing]
        picker.pending = hex("44")
        var warmedAccounts: [String] = []

        let result = await picker.addPending(
            normalize: { stagedMember(memberRef: $0, accountIdHex: account) },
            warmProfile: { warmedAccounts.append($0) }
        )

        #expect(result)
        #expect(picker.members == [existing])
        #expect(picker.pending.isEmpty)
        #expect(picker.error == nil)
        #expect(warmedAccounts.isEmpty)
    }

    @Test func pendingInputDeduplicatesAgainstMembersAddedDuringNormalizeAwait() async {
        let picker = MemberPickerViewModel()
        let account = hex("44")
        let concurrentAdd = stagedMember(memberRef: "npub1concurrent", accountIdHex: account)
        let normalized = stagedMember(memberRef: hex("55"), accountIdHex: account)
        let gate = NormalizeGate()
        picker.pending = normalized.memberRef
        var warmedAccounts: [String] = []

        let addTask = Task { @MainActor in
            await picker.addPending(
                normalize: { _ in
                    await gate.markStartedAndWait()
                    return normalized
                },
                warmProfile: { warmedAccounts.append($0) }
            )
        }

        await gate.waitUntilStarted()
        picker.members = [concurrentAdd]
        await gate.resume()
        let result = await addTask.value

        #expect(result)
        #expect(picker.members == [concurrentAdd])
        #expect(picker.pending.isEmpty)
        #expect(picker.error == nil)
        #expect(warmedAccounts.isEmpty)
    }

    @Test func scannedProfileLinkStagesMember() async {
        let picker = MemberPickerViewModel()
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let account = hex("55")
        let added = stagedMember(memberRef: npub, accountIdHex: account)

        let result = await picker.addScanned(
            "\(DeepLink.scheme)://profile/\(npub)",
            normalize: { stagedMember(memberRef: $0, accountIdHex: account) }
        )

        #expect(result)
        #expect(picker.members == [added])
        #expect(picker.error == nil)
    }

    @Test func olderAddDoesNotClearNewerPendingText() {
        let picker = MemberPickerViewModel()
        picker.pending = "newer text"

        picker.clearPendingIfUnchanged("older text")

        #expect(picker.pending == "newer text")
    }

    @Test func removeUnstagesMatchingMemberByAccountIdAndKeepsOthers() {
        let picker = MemberPickerViewModel()
        let first = stagedMember(accountIdHex: hex("11"))
        let second = stagedMember(accountIdHex: hex("22"))
        picker.members = [first, second]
        picker.remove(stagedMember(memberRef: "npub1other", accountIdHex: hex("11")))
        #expect(picker.members == [second])
    }

    @Test func removeIgnoresMemberThatIsNotStaged() {
        let picker = MemberPickerViewModel()
        let staged = stagedMember(accountIdHex: hex("11"))
        picker.members = [staged]

        picker.remove(stagedMember(accountIdHex: hex("99")))

        #expect(picker.members == [staged])
    }

    @Test func canCreateRequiresStagedMemberIdleStateAndActiveAccount() {
        #expect(AddMembersPresentation.canCreate(stagedCount: 1, isCreating: false, hasActiveAccount: true))
        #expect(!AddMembersPresentation.canCreate(stagedCount: 0, isCreating: false, hasActiveAccount: true))
        #expect(!AddMembersPresentation.canCreate(stagedCount: 1, isCreating: true, hasActiveAccount: true))
        #expect(!AddMembersPresentation.canCreate(stagedCount: 1, isCreating: false, hasActiveAccount: false))
    }

    @Test func canInviteAllowsPendingTextWithNoStagedMembers() {
        // The distinguishing rule: unstaged text alone enables Invite, because
        // invite folds the pending field in before submitting.
        #expect(AddMembersPresentation.canInvite(stagedCount: 0, hasPendingText: true, isInviting: false))
        #expect(AddMembersPresentation.canInvite(stagedCount: 1, hasPendingText: false, isInviting: false))
        #expect(!AddMembersPresentation.canInvite(stagedCount: 0, hasPendingText: false, isInviting: false))
        #expect(!AddMembersPresentation.canInvite(stagedCount: 1, hasPendingText: true, isInviting: true))
    }

    @Test func isCompleteReferenceRecognizesFinishedReferences() {
        #expect(AddMembersPresentation.isCompleteReference(hex("ab")))
        #expect(AddMembersPresentation.isCompleteReference(
            "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        ))
    }

    @Test func isCompleteReferenceRejectsPartialOrInvalidInput() {
        #expect(!AddMembersPresentation.isCompleteReference(""))
        #expect(!AddMembersPresentation.isCompleteReference("npub1"))
        #expect(!AddMembersPresentation.isCompleteReference("npub1partialnotchecksummed"))
        #expect(!AddMembersPresentation.isCompleteReference("not a profile"))
        #expect(!AddMembersPresentation.isCompleteReference(String(repeating: "a", count: 63)))
    }

    @Test func autoStageStagesCompleteReferenceWithoutExplicitTap() async {
        let picker = MemberPickerViewModel()
        let candidate = stagedMember(accountIdHex: hex("66"))
        picker.pending = candidate.accountIdHex
        var warmedAccounts: [String] = []

        await picker.autoStagePendingIfComplete(
            normalize: { stagedMember(accountIdHex: $0) },
            warmProfile: { warmedAccounts.append($0) }
        )

        #expect(picker.members == [candidate])
        #expect(picker.pending.isEmpty)
        #expect(picker.error == nil)
        #expect(warmedAccounts == [candidate.accountIdHex])
    }

    @Test func autoStageIgnoresPartialInputWithoutErrorOrNormalize() async {
        let picker = MemberPickerViewModel()
        picker.pending = "npub1partial"

        await picker.autoStagePendingIfComplete(normalize: { _ in throw TestError.unexpectedNormalize })

        #expect(picker.members.isEmpty)
        #expect(picker.pending == "npub1partial")
        #expect(picker.error == nil)
    }

    @Test func autoStageStaysSilentWhenNormalizeFailsOnCompleteReference() async {
        let picker = MemberPickerViewModel()
        picker.pending = hex("77")

        await picker.autoStagePendingIfComplete(normalize: { _ in throw TestError.unexpectedNormalize })

        #expect(picker.members.isEmpty)
        #expect(picker.pending == hex("77"))
        #expect(picker.error == nil)
    }

    @Test func autoStageStagesConcurrentDistinctReferencesWithoutDropping() async {
        let picker = MemberPickerViewModel()
        let first = stagedMember(accountIdHex: hex("aa"))
        let second = stagedMember(accountIdHex: hex("bb"))
        let gate = NormalizeGate()
        picker.pending = first.accountIdHex

        let firstTask = Task { @MainActor in
            await picker.autoStagePendingIfComplete(normalize: { memberRef in
                await gate.markStartedAndWait()
                return stagedMember(accountIdHex: memberRef)
            })
        }

        await gate.waitUntilStarted()
        picker.pending = second.accountIdHex
        let secondTask = Task { @MainActor in
            await picker.autoStagePendingIfComplete(normalize: { stagedMember(accountIdHex: $0) })
        }
        await secondTask.value
        await gate.resume()
        await firstTask.value

        #expect(picker.members.count == 2)
        #expect(picker.members.contains(first))
        #expect(picker.members.contains(second))
        #expect(picker.error == nil)
    }

    @Test func autoStageLeavesExistingErrorIntactWhenNormalizeFails() async {
        let picker = MemberPickerViewModel()
        picker.error = "invalid member"
        picker.pending = hex("88")

        await picker.autoStagePendingIfComplete(normalize: { _ in throw TestError.unexpectedNormalize })

        #expect(picker.members.isEmpty)
        #expect(picker.pending == hex("88"))
        #expect(picker.error == "invalid member")
    }

    @Test func createDoesNotReachClientWhenNoMembersStagedAfterFoldingEmptyPending() async throws {
        // Empty pending makes addPending return true without staging anyone, so
        // create must re-check members before touching the client — otherwise it
        // reaches createGroup with an empty member list (and here, a client call
        // that fails and surfaces an error). Mirrors AddMembersSheetViewModel.invite.
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account"
        let viewModel = NewChatSheetViewModel()
        var dismissed = false

        await viewModel.create(using: appState, dismiss: { dismissed = true })

        #expect(viewModel.memberPicker.members.isEmpty)
        // Bailed before the client call, so no error was surfaced. Without the
        // guard, create reaches currentMarmotClient()/createGroup and this fails.
        #expect(viewModel.memberPicker.error == nil)
        #expect(!viewModel.isCreating)
        #expect(!dismissed)
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
