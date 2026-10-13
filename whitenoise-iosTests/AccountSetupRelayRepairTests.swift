import MarmotKit
import Testing
@testable import whitenoise_ios

struct AccountSetupRelayRepairTests {
    @Test func additiveRepairShowsEachChangeInOrderWithTheRestoredCapability() throws {
        let read = tag(["r", "wss://read.example.com", "read"], .read)
        let other = tag(["alt", "relay list"], .other, endpoint: .some(nil))
        let added = tag(["r", "wss://default.example.com", "write"], .write)
        let proposal = relayProposal(mode: .additive, before: [read, other], after: [read, other, added], changes: [
            change(.retained, read, before: 0, after: 0),
            change(.retained, other, before: 1, after: 1),
            change(.added, added, before: nil, after: 2, restores: .write)
        ])
        let repair = try #require(AccountSetupRelayRepairPresentation(proposal: proposal, step: .relays))
        #expect(repair.rows.map(\.change) == [.kept, .kept, .added])
        #expect(repair.added.map(\.host) == ["default.example.com"])
        #expect(repair.added.first?.restores == .write)
        #expect(repair.kept.allSatisfy { $0.restores == .none })
        #expect(repair.kept.map(\.use) == [.read, .other])
        #expect(repair.kept.last?.text == "alt relay list")
        #expect(canApprove(proposal, step(.relays, [.approveRepair, .cancelRepair])))
    }

    @Test func removingARetiredRelayIsShownAndDoesNotBlockApproval() throws {
        let retired = tag(["r", "ws://127.0.0.1"], .unmarked)
        let kept = tag(["r", "wss://kept.example.com"], .unmarked)
        let proposal = relayProposal(mode: .removalOnly, before: [retired, kept], after: [kept], changes: [
            change(.removed, retired, before: 0, after: nil),
            change(.retained, kept, before: 1, after: 0)
        ])
        let repair = try #require(AccountSetupRelayRepairPresentation(proposal: proposal, step: .relays))
        #expect(repair.removed.count == 1)
        #expect(repair.removed.first?.isInvalidPublishedAddress == false)
        #expect(repair.publishesOnlyValidAddresses)
        #expect(canApprove(proposal, step(.relays, [.approveRepair])))
    }

    @Test(arguments: [[OnboardingActionFfi.editRelays, .cancelRepair], [.approveRepair, .editRelays, .cancelRepair]])
    func manualReviewIsNeverApprovable(_ actions: [OnboardingActionFfi]) throws {
        let current = tag(["r", "wss://current.example.com"], .unmarked)
        let proposal = relayProposal(mode: .manualReview, before: [current], after: [current], changes: [
            change(.retained, current, before: 0, after: 0)
        ])
        let repair = try #require(AccountSetupRelayRepairPresentation(proposal: proposal, step: .relays))
        #expect(repair.isManualReview)
        #expect(!canApprove(proposal, step(.relays, actions)))
    }

    @Test func manualReviewPrefillsTheEditorFromTheOriginalTags() throws {
        let before = [
            tag(["r", "wss://both.example.com"], .unmarked),
            tag(["r", "wss://read.example.com", "READ"], .read),
            tag(["r", "WSS://Read.Example.com", "Write", "extra"], .write),
            tag(["r", "ws://onion.example.onion"], .unmarked),
            tag(["r", "wss://unknown.example.com", "maybe"], .other),
            tag(["alt", "relay list"], .other, endpoint: .some(nil))
        ]
        // The preview tags are what an approval would publish; manual review must not use them.
        let proposal = relayProposal(mode: .manualReview, before: before, after: [], changes: [])
        let repair = try #require(AccountSetupRelayRepairPresentation(proposal: proposal, step: .relays))
        let draft = repair.editorDraft
        let entries = draft.entries
        #expect(entries.map(\.address) == ["wss://both.example.com", "wss://read.example.com", "ws://onion.example.onion"])
        #expect(entries.map(\.reads) == [true, true, true])
        #expect(entries.map(\.writes) == [true, true, true])
        // The unsupported address stays visible for correction and blocks the whole draft.
        #expect(throws: AccountSetupRelayDraft.ValidationError.invalidAddress(entries[2].id)) {
            try draft.selection()
        }
    }

    @Test func approvablePreviewPrefillsTheEditorFromTheProposedTags() throws {
        let read = tag(["r", "wss://read.example.com", "read"], .read)
        let added = tag(["r", "wss://write.example.com", "write"], .write)
        let proposal = relayProposal(mode: .additive, before: [read], after: [read, added], changes: [
            change(.retained, read, before: 0, after: 0),
            change(.added, added, before: nil, after: 1, restores: .write)
        ])
        let repair = try #require(AccountSetupRelayRepairPresentation(proposal: proposal, step: .relays))
        let selection = try repair.editorDraft.selection()
        #expect(selection.reads == ["wss://read.example.com"])
        #expect(selection.writes == ["wss://write.example.com"])
    }

    @Test func inboxTagsPrefillAsInboxEntries() throws {
        let inbox = tag(["relay", "wss://inbox.example.com"], .inbox)
        let proposal = relayProposal(step: .inboxRelays, mode: .manualReview, before: [inbox], after: [inbox], changes: [
            change(.retained, inbox, before: 0, after: 0)
        ])
        let repair = try #require(AccountSetupRelayRepairPresentation(proposal: proposal, step: .inboxRelays))
        #expect(try repair.editorDraft.selection(for: .inboxRelays).reads == ["wss://inbox.example.com"])
        #expect(AccountSetupRelayRepairPresentation(proposal: proposal, step: .relays) == nil)
    }

    @Test(arguments: ["wss://127.0.0.1", "ws://relay.example.onion", "wss://relay.example.com/\u{202E}path"])
    func anUnsafePublishedAddressBlocksTheWholePreview(_ address: String) throws {
        let unsafe = tag(["r", address], .unmarked)
        let added = tag(["r", "wss://write.example.com", "write"], .write)
        let proposal = relayProposal(mode: .additive, before: [unsafe], after: [unsafe, added], changes: [
            change(.retained, unsafe, before: 0, after: 0),
            change(.added, added, before: nil, after: 1, restores: .write)
        ])
        let repair = try #require(AccountSetupRelayRepairPresentation(proposal: proposal, step: .relays))
        #expect(repair.kept.first?.isInvalidPublishedAddress == true)
        #expect(!repair.publishesOnlyValidAddresses)
        #expect(!canApprove(proposal, step(.relays, [.approveRepair])))
    }

    @Test func aDiffThatOmitsAPublishedTagIsNotApprovable() {
        let kept = tag(["r", "wss://kept.example.com"], .unmarked)
        let hidden = tag(["r", "wss://hidden.example.com"], .unmarked)
        let proposal = relayProposal(mode: .additive, before: [kept], after: [kept, hidden], changes: [
            change(.retained, kept, before: 0, after: 0)
        ])
        #expect(!canApprove(proposal, step(.relays, [.approveRepair])))
    }

    @Test func aChangedEventContentIsNotApprovable() {
        let kept = tag(["r", "wss://kept.example.com"], .unmarked)
        let added = tag(["r", "wss://added.example.com"], .unmarked)
        var proposal = relayProposal(mode: .additive, before: [kept], after: [kept, added], changes: [
            change(.retained, kept, before: 0, after: 0),
            change(.added, added, before: nil, after: 1, restores: .readAndWrite)
        ])
        #expect(canApprove(proposal, step(.relays, [.approveRepair])))
        proposal.relayRepair?.proposedContent = "changed"
        #expect(!canApprove(proposal, step(.relays, [.approveRepair])))
    }

    @Test func approvalRequiresTheOfferedActionForTheSameStep() {
        let added = tag(["r", "wss://added.example.com"], .unmarked)
        let proposal = relayProposal(mode: .additive, before: [], after: [added], changes: [
            change(.added, added, before: nil, after: 0, restores: .readAndWrite)
        ])
        #expect(!canApprove(proposal, step(.relays, [.cancelRepair])))
        #expect(!canApprove(proposal, step(.inboxRelays, [.approveRepair])))
        #expect(!canApprove(nil, step(.relays, [.approveRepair])))
    }

    @Test func explicitEditOutcomeDistinguishesReviewUnchangedAndFailure() {
        let current = tag(["r", "wss://current.example.com"], .unmarked)
        var value = snapshot(proposal: relayProposal(mode: .manualReview, before: [current], after: [current], changes: [
            change(.retained, current, before: 0, after: 0)
        ]), actions: [.editRelays, .cancelRepair])
        #expect(AccountSetupRelayRepairPresentation.editOutcome(value, step: .relays, errorMessage: nil) == .unchanged)
        #expect(AccountSetupRelayRepairPresentation.editOutcome(value, step: .relays, errorMessage: "Failed") == .failed)
        #expect(AccountSetupRelayRepairPresentation.editOutcome(value, step: .inboxRelays, errorMessage: nil) == .failed)
        value.proposal?.relayRepair?.mode = .additive
        value.steps[0].actions = [.approveRepair, .cancelRepair]
        #expect(AccountSetupRelayRepairPresentation.editOutcome(value, step: .relays, errorMessage: nil) == .review)
        value.steps[0].actions = [.cancelRepair]
        #expect(AccountSetupRelayRepairPresentation.editOutcome(value, step: .relays, errorMessage: nil) == .failed)
    }

    @Test func defaultReplacementIsHiddenWhenTheListAlreadyMatchesTheDefaults() throws {
        let defaults = ["wss://one.example.com", "wss://two.example.com"]
        let matching = [tag(["r", "WSS://ONE.example.com"], .unmarked), tag(["r", "wss://two.example.com"], .unmarked)]
        let same = try #require(AccountSetupRelayRepairPresentation(
            proposal: relayProposal(mode: .manualReview, before: matching, after: matching, changes: []), step: .relays
        ))
        #expect(!same.offersDefaultReplacement(defaults: defaults, step: .relays))
        let different = try #require(AccountSetupRelayRepairPresentation(
            proposal: relayProposal(mode: .manualReview, before: [matching[0]], after: [matching[0]], changes: []), step: .relays
        ))
        #expect(different.offersDefaultReplacement(defaults: defaults, step: .relays))
        // Same addresses, but one is write-only: replacing would make it read and write.
        let writeOnly = [matching[0], tag(["r", "wss://two.example.com", "write"], .write)]
        let roles = try #require(AccountSetupRelayRepairPresentation(
            proposal: relayProposal(mode: .manualReview, before: writeOnly, after: writeOnly, changes: []), step: .relays
        ))
        #expect(roles.offersDefaultReplacement(defaults: defaults, step: .relays))
    }

    @Test func proposalsWithoutATypedPreviewKeepTheLegacyPresentation() {
        let legacy = OnboardingRepairProposalFfi(step: .relays, revision: 1, previousEventId: nil,
                                                 readRelays: ["wss://relay.example.com"], writeRelays: ["wss://relay.example.com"],
                                                 profile: nil, follows: nil, relayRepair: nil)
        #expect(AccountSetupRelayRepairPresentation(proposal: legacy, step: .relays) == nil)
        #expect(canApprove(legacy, step(.relays, [.approveRepair])))
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func manualReviewOffersEditingAndADefaultReplacementWithoutApproval(_ stepKind: OnboardingStepFfi) throws {
        let name = stepKind == .relays ? "r" : "relay"
        let current = tag([name, "wss://current.example.com"], stepKind == .relays ? .unmarked : .inbox)
        let proposal = relayProposal(step: stepKind, mode: .manualReview, before: [current], after: [current], changes: [
            change(.retained, current, before: 0, after: 0)
        ])
        let presentation = AccountSetupRelayStepPresentation(
            step: stepKind, actions: [.editRelays, .cancelRepair], proposal: proposal,
            defaultRelays: ["wss://default.example.com"]
        )
        #expect(presentation.status == .manualReview)
        #expect(!presentation.isInvalid)
        #expect(!presentation.isInterrupted)
        #expect(presentation.primaryAction == .init(action: .edit))
        #expect(presentation.secondaryActions == [.replaceWithDefaults])
        // The preview has nothing to lose, so editing opens the editor without withdrawing it.
        #expect(presentation.editsDirectly)
        #expect(!presentation.needsConfirmation(.edit))
        #expect(!presentation.needsConfirmation(.discard))
        let repair = try #require(presentation.repair)
        #expect(repair.kept.map(\.host) == ["current.example.com"])
        #expect(try repair.editorDraft.selection(for: stepKind).reads == ["wss://current.example.com"])
    }

    @Test func manualReviewHidesTheReplacementWhenTheListAlreadyMatchesTheDefaults() {
        let current = tag(["r", "wss://default.example.com"], .unmarked)
        let proposal = relayProposal(mode: .manualReview, before: [current], after: [current], changes: [
            change(.retained, current, before: 0, after: 0)
        ])
        let presentation = AccountSetupRelayStepPresentation(
            step: .relays, actions: [.editRelays, .cancelRepair], proposal: proposal,
            defaultRelays: ["wss://default.example.com"]
        )
        #expect(presentation.primaryAction?.action == .edit)
        #expect(!presentation.canReplaceWithDefaults)
        #expect(presentation.secondaryActions.isEmpty)
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func approvablePreviewIsReviewedThenSavedOrWithdrawnWithConfirmation(_ stepKind: OnboardingStepFfi) throws {
        let role: OnboardingRelayTagRoleFfi = stepKind == .relays ? .unmarked : .inbox
        let name = stepKind == .relays ? "r" : "relay"
        let kept = tag([name, "wss://kept.example.com"], role)
        let added = tag([name, "wss://added.example.com"], role)
        let proposal = relayProposal(step: stepKind, mode: .additive, before: [kept], after: [kept, added], changes: [
            change(.retained, kept, before: 0, after: 0),
            change(.added, added, before: nil, after: 1, restores: stepKind == .relays ? .readAndWrite : .inbox)
        ])
        let presentation = AccountSetupRelayStepPresentation(step: stepKind, actions: [.approveRepair, .cancelRepair], proposal: proposal)
        #expect(presentation.status == .review)
        #expect(presentation.primaryAction == .init(action: .approve))
        #expect(presentation.secondaryActions == [.edit])
        #expect(!presentation.editsDirectly)
        #expect(presentation.needsConfirmation(.edit))
        #expect(presentation.needsConfirmation(.discard))
        // Editing withdraws the preview and keeps what it would have published.
        let value = snapshot(proposal: proposal, actions: [.approveRepair, .cancelRepair])
        let edit = try #require(AccountSetupRelayStepPresentation.ProposalChange(action: .edit, step: stepKind, snapshot: value))
        #expect(try edit.draft.selection(for: stepKind).reads == ["wss://kept.example.com", "wss://added.example.com"])
    }

    @Test func anUnsafeRetainedAddressAsksForCorrectionInsteadOfSaving() {
        let unsafe = tag(["r", "ws://relay.example.onion"], .unmarked)
        let added = tag(["r", "wss://write.example.com", "write"], .write)
        let proposal = relayProposal(mode: .additive, before: [unsafe], after: [unsafe, added], changes: [
            change(.retained, unsafe, before: 0, after: 0),
            change(.added, added, before: nil, after: 1, restores: .write)
        ])
        let presentation = AccountSetupRelayStepPresentation(step: .relays, actions: [.approveRepair, .cancelRepair], proposal: proposal)
        #expect(presentation.status == .invalid)
        #expect(presentation.primaryAction == .init(action: .edit))
        #expect(!presentation.secondaryActions.contains(.approve))
    }

    // MARK: - Fixtures

    /// Approval as the shared relay step offers it: the primary action for the displayed proposal.
    private func canApprove(_ proposal: OnboardingRepairProposalFfi?, _ state: OnboardingStepStateFfi) -> Bool {
        AccountSetupRelayStepPresentation(step: state.step, actions: state.actions, proposal: proposal).primaryAction?.action == .approve
    }


    private func tag(_ fields: [String], _ role: OnboardingRelayTagRoleFfi, endpoint: String?? = .none) -> OnboardingRelayTagFfi {
        OnboardingRelayTagFfi(fields: fields, endpoint: endpoint ?? fields.dropFirst().first, role: role)
    }

    private func change(
        _ disposition: OnboardingRelayTagDispositionFfi, _ tag: OnboardingRelayTagFfi,
        before: UInt64?, after: UInt64?, restores: OnboardingRelayCapabilityFfi = .none
    ) -> OnboardingRelayTagChangeFfi {
        OnboardingRelayTagChangeFfi(disposition: disposition, beforeIndex: before, afterIndex: after,
                                    fields: tag.fields, endpoint: tag.endpoint, role: tag.role, restores: restores)
    }

    private func relayProposal(
        step: OnboardingStepFfi = .relays, mode: OnboardingRelayRepairModeFfi,
        before: [OnboardingRelayTagFfi], after: [OnboardingRelayTagFfi], changes: [OnboardingRelayTagChangeFfi]
    ) -> OnboardingRepairProposalFfi {
        let repair = OnboardingRelayRepairFfi(mode: mode, originalEventId: "event", originalContent: "",
                                              proposedContent: "", beforeTags: before, afterTags: after, changes: changes)
        return OnboardingRepairProposalFfi(step: step, revision: 4, previousEventId: "event",
                                           readRelays: [], writeRelays: [], profile: nil, follows: nil, relayRepair: repair)
    }

    private func step(_ step: OnboardingStepFfi, _ actions: [OnboardingActionFfi]) -> OnboardingStepStateFfi {
        OnboardingStepStateFfi(step: step, status: .needsInput, findings: [], actions: actions, checkedAt: nil)
    }

    private func snapshot(proposal: OnboardingRepairProposalFfi, actions: [OnboardingActionFfi]) -> OnboardingSnapshotFfi {
        OnboardingSnapshotFfi(
            accountIdHex: String(repeating: "a", count: 64), recoveryEpoch: nil, revision: proposal.revision, ready: false,
            steps: [step(proposal.step, actions)], proposal: proposal, singleDeviceNotice: nil, cancellationPending: false
        )
    }
}
