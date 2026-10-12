import MarmotKit
import Testing
@testable import whitenoise_ios

struct AccountSetupRelayStepPresentationTests {
    private typealias Presentation = AccountSetupRelayStepPresentation

    @Test(arguments: [false, true])
    func defaultsRemainAvailableAfterDiscoveryFailure(_ failed: Bool) {
        let presentation = Presentation(
            step: .inboxRelays, actions: [.useRecommendedRelays, .editRelays, .editDiscoveryRelays], proposal: nil,
            childFailureSource: failed ? .discovery : nil, hasOperationError: failed
        )
        #expect(presentation.primaryAction?.action == .defaults)
        #expect(presentation.canDiscover)
        #expect(presentation.canEdit)
        #expect(presentation.status == (failed ? .discoveryFailure : .relays))
    }

    @Test func inconclusiveDiscoveryOffersDefaultSearchBeforePublication() {
        let presentation = Presentation(step: .inboxRelays, actions: [.retry, .editDiscoveryRelays], proposal: nil, childFailureSource: .discovery)
        #expect(presentation.primaryAction?.action == .searchDefaults)
        #expect(presentation.canDiscover)
        #expect(!presentation.canEdit)
        #expect(presentation.status == .discoveryFailure)
        let checked = Presentation(step: .inboxRelays, actions: [.retry, .useRecommendedRelays, .editRelays, .editDiscoveryRelays], proposal: nil)
        #expect(checked.primaryAction?.action == .defaults)
        #expect(!checked.canSearchDefaults)
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func defaultSearchKeepsTheBroaderRecheckAvailable(_ step: OnboardingStepFfi) {
        let presentation = Presentation(step: step, actions: [.retry, .editDiscoveryRelays], proposal: nil)
        #expect(presentation.primaryAction?.action == .searchDefaults)
        #expect(presentation.secondaryActions == [.retry, .discovery])
        let withoutRetry = Presentation(step: step, actions: [.editDiscoveryRelays], proposal: nil)
        #expect(withoutRetry.secondaryActions == [.discovery])
    }

    @Test func failedRelaySearchOffersDefaultSearchInsteadOfRepeatingIt() {
        let presentation = Presentation(
            step: .relays, actions: [.retry, .editDiscoveryRelays], proposal: nil, childFailureSource: .discovery
        )
        #expect(presentation.primaryAction?.action == .searchDefaults)
        #expect(presentation.secondaryActions.contains(.retry))
        #expect(presentation.status == .discoveryFailure)
    }

    @Test func secondaryActionsNeverRepeatThePrimary() {
        let presentation = Presentation(
            step: .relays, actions: [.useRecommendedRelays, .retry, .editRelays, .editDiscoveryRelays], proposal: nil
        )
        #expect(presentation.primaryAction?.action == .defaults)
        #expect(presentation.secondaryActions == [.edit, .discovery])
    }

    @Test func defaultSearchRequiresDiscoveryPermissionAndNoProposal() {
        let interrupted = Presentation(step: .inboxRelays, actions: [.retry], proposal: proposal())
        #expect(!interrupted.canSearchDefaults)
        #expect(interrupted.primaryAction?.action == .retry)
        let unavailable = Presentation(step: .inboxRelays, actions: [], proposal: nil)
        #expect(!unavailable.canSearchDefaults)
        #expect(unavailable.primaryAction == nil)
    }

    @Test(arguments: [OnboardingStepFfi.profile, .relays])
    func restartedEarlierCheckProvidesARouteBackToSignIn(_ earlierStep: OnboardingStepFfi) {
        var updated = snapshot(revision: 2)
        updated.steps[0].status = .pending
        updated.steps[0].actions = []
        updated.steps.insert(.init(step: earlierStep, status: .retryableFailure, findings: [],
                                   actions: [.retry, .editDiscoveryRelays], checkedAt: nil), at: 0)
        let needsReview = Presentation.needsEarlierReview(in: updated, step: .inboxRelays)
        #expect(needsReview)
        let presentation = Presentation(step: .inboxRelays, actions: [], proposal: nil, childFailureSource: .discovery, needsEarlierReview: needsReview)
        #expect(presentation.primaryAction?.action == .reviewChecks)
        #expect(presentation.status == .earlierCheck)
        updated.steps[0].status = .passed
        #expect(!Presentation.needsEarlierReview(in: updated, step: .inboxRelays))
    }

    @Test func validProposalCanBeApprovedOrEdited() {
        let presentation = Presentation(step: .inboxRelays, actions: [.approveRepair, .cancelRepair], proposal: proposal())
        #expect(presentation.primaryAction?.action == .approve)
        #expect(presentation.canEdit)
        #expect(presentation.isValidProposal)
        #expect(presentation.status == .review)
    }

    @Test(arguments: [true, false])
    func invalidProposalOffersCorrectionInsteadOfApproval(_ hasWriteRelay: Bool) {
        let proposal = hasWriteRelay
            ? proposal(writes: ["wss://write.example.com"])
            : proposal(reads: ["wss://inbox.example.com", "ws://127.0.0.1"])
        let presentation = Presentation(step: .inboxRelays, actions: [.approveRepair, .cancelRepair], proposal: proposal)
        #expect(!presentation.isValidProposal)
        #expect(presentation.primaryAction?.action == .edit)
        #expect(presentation.status == .invalid)
    }

    @Test func relayProposalNeedsAWriteRelay() {
        let readOnly = Presentation(
            step: .relays, actions: [.approveRepair, .cancelRepair], proposal: proposal(step: .relays, reads: ["wss://read.example.com"])
        )
        #expect(!readOnly.isValidProposal)
        #expect(readOnly.primaryAction?.action == .edit)
        let writable = Presentation(
            step: .relays, actions: [.approveRepair, .cancelRepair],
            proposal: proposal(step: .relays, reads: [], writes: ["wss://write.example.com"])
        )
        #expect(writable.isValidProposal)
        #expect(writable.primaryAction?.action == .approve)
    }

    @Test(arguments: [false, true])
    func interruptedPublicationNeverOffersEditingOrApproval(_ canRetry: Bool) {
        let presentation = Presentation(step: .inboxRelays, actions: canRetry ? [.retry] : [], proposal: proposal(), childFailureSource: .discovery)
        #expect(presentation.isInterrupted)
        #expect(presentation.primaryAction?.action == (canRetry ? .retry : nil))
        #expect(!presentation.canEdit)
        #expect(!presentation.canDiscover)
        #expect(presentation.secondaryActions.isEmpty)
    }

    @Test func failedWithdrawalOffersAnotherEditAttempt() {
        let presentation = Presentation(
            step: .inboxRelays, actions: [.approveRepair, .cancelRepair], proposal: proposal(), hasOperationError: true, lastAction: .edit
        )
        #expect(presentation.primaryAction == .init(action: .edit, isRetry: true))
        #expect(presentation.status == .draftFailure)
    }

    @Test func reopenedSheetDoesNotDescribeAnUnknownErrorAsASaveFailure() {
        let lookup = Presentation(step: .relays, actions: [.retry], proposal: nil, hasOperationError: true)
        #expect(lookup.status == .operationFailure)
        #expect(lookup.primaryAction?.action == .retry)
        let review = Presentation(
            step: .inboxRelays, actions: [.approveRepair, .cancelRepair], proposal: proposal(), hasOperationError: true
        )
        #expect(review.status == .operationFailure)
        #expect(review.primaryAction == .init(action: .approve))
    }

    @Test func failedApprovalRetriesApprovalRatherThanStartingOver() {
        let presentation = Presentation(
            step: .inboxRelays, actions: [.approveRepair, .cancelRepair], proposal: proposal(), hasOperationError: true, lastAction: .approve
        )
        #expect(presentation.primaryAction == .init(action: .approve, isRetry: true))
        #expect(presentation.status == .updateFailure)
    }

    @Test func editingARestoredProposalKeepsAddressesAndRemovesInboxWriteRoles() throws {
        let reviewed = snapshot(proposal: proposal(writes: ["wss://write.example.com"]))
        let change = try #require(Presentation.ProposalChange(action: .edit, step: .inboxRelays, snapshot: reviewed))
        let selection = try change.draft.selection(for: .inboxRelays)
        #expect(selection.reads == ["wss://inbox.example.com", "wss://write.example.com"])
        #expect(selection.writes.isEmpty)
        #expect(change.isComplete(in: snapshot(revision: 2), hasError: false))
    }

    @Test func editingKeepsInvalidAddressesVisibleForCorrection() throws {
        let change = try #require(Presentation.ProposalChange(
            action: .edit, step: .inboxRelays, snapshot: snapshot(proposal: proposal(reads: ["ws://127.0.0.1"]))
        ))
        let entry = try #require(change.draft.entries.first)
        #expect(entry.address == "ws://127.0.0.1")
        #expect(throws: AccountSetupRelayDraft.ValidationError.invalidAddress(entry.id)) {
            try change.draft.selection(for: .inboxRelays)
        }
    }

    @Test func discardClearsTheDraftOnlyAfterSuccessfulWithdrawal() throws {
        let reviewed = snapshot(proposal: proposal())
        let change = try #require(Presentation.ProposalChange(action: .discard, step: .inboxRelays, snapshot: reviewed))
        #expect(change.draft.entries.isEmpty)
        #expect(!change.isComplete(in: reviewed, hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2), hasError: true))
        #expect(change.isComplete(in: snapshot(revision: 2), hasError: false))
    }

    @Test func unrelatedOrStaleSnapshotsDoNotCompleteAnEdit() throws {
        let change = try #require(Presentation.ProposalChange(action: .edit, step: .inboxRelays, snapshot: snapshot(proposal: proposal())))
        #expect(!change.isComplete(in: snapshot(), hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2, proposal: proposal()), hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2, account: "different"), hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2, epoch: "different"), hasError: false))
    }

    private func proposal(
        step: OnboardingStepFfi = .inboxRelays, reads: [String] = ["wss://inbox.example.com"], writes: [String] = []
    ) -> OnboardingRepairProposalFfi {
        .init(step: step, revision: 1, previousEventId: nil,
              readRelays: reads, writeRelays: writes, profile: nil, follows: nil, relayRepair: nil)
    }

    private func snapshot(
        revision: UInt64 = 1, proposal: OnboardingRepairProposalFfi? = nil, account: String = "account", epoch: String = "epoch"
    ) -> OnboardingSnapshotFfi {
        .init(accountIdHex: account, recoveryEpoch: epoch, revision: revision, ready: false,
              steps: [.init(step: .inboxRelays, status: .needsInput, findings: [], actions: [.editRelays], checkedAt: nil)],
              proposal: proposal, singleDeviceNotice: nil, cancellationPending: false)
    }
}
