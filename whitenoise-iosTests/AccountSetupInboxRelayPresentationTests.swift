import MarmotKit
import Testing
@testable import whitenoise_ios

struct AccountSetupInboxRelayPresentationTests {
    private typealias Presentation = AccountSetupInboxRelayPresentation

    @Test(arguments: [false, true])
    func defaultsRemainAvailableAfterDiscoveryFailure(_ failed: Bool) {
        let presentation = Presentation(
            actions: [.useRecommendedRelays, .editRelays, .editDiscoveryRelays], proposal: nil,
            childFailureSource: failed ? .discovery : nil, hasOperationError: failed
        )
        #expect(presentation.primaryAction?.action == .defaults)
        #expect(presentation.canDiscover)
        #expect(presentation.canEdit)
        #expect(presentation.status == (failed ? .discoveryFailure : .relays))
    }

    @Test func inconclusiveDiscoveryOffersDefaultSearchBeforePublication() {
        let presentation = Presentation(actions: [.retry, .editDiscoveryRelays], proposal: nil, childFailureSource: .discovery)
        #expect(presentation.primaryAction?.action == .searchDefaults)
        #expect(presentation.canDiscover)
        #expect(!presentation.canEdit)
        #expect(presentation.status == .discoveryFailure)
        let checked = Presentation(actions: [.retry, .useRecommendedRelays, .editRelays, .editDiscoveryRelays], proposal: nil)
        #expect(checked.primaryAction?.action == .defaults)
        #expect(!checked.canSearchDefaults)
    }

    @Test func defaultSearchRequiresDiscoveryPermissionAndNoProposal() {
        let interrupted = Presentation(actions: [.retry], proposal: proposal())
        #expect(!interrupted.canSearchDefaults)
        #expect(interrupted.primaryAction?.action == .retry)
        let unavailable = Presentation(actions: [], proposal: nil)
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
        let needsReview = Presentation.needsEarlierReview(in: updated)
        #expect(needsReview)
        let presentation = Presentation(actions: [], proposal: nil, childFailureSource: .discovery, needsEarlierReview: needsReview)
        #expect(presentation.primaryAction?.action == .reviewChecks)
        #expect(presentation.status == .earlierCheck)
        updated.steps[0].status = .passed
        #expect(!Presentation.needsEarlierReview(in: updated))
    }

    @Test func validProposalCanBeApprovedOrEdited() {
        let presentation = Presentation(actions: [.approveRepair, .cancelRepair], proposal: proposal())
        #expect(presentation.primaryAction?.action == .approve)
        #expect(presentation.canEdit)
        #expect(presentation.relays == ["wss://inbox.example.com"])
        #expect(presentation.status == .review)
    }

    @Test(arguments: [true, false])
    func invalidProposalOffersCorrectionInsteadOfApproval(_ hasWriteRelay: Bool) {
        let proposal = hasWriteRelay
            ? proposal(writes: ["wss://write.example.com"])
            : proposal(reads: ["wss://inbox.example.com", "ws://127.0.0.1"])
        let presentation = Presentation(actions: [.approveRepair, .cancelRepair], proposal: proposal)
        #expect(presentation.relays == nil)
        #expect(presentation.primaryAction?.action == .edit)
        #expect(presentation.status == .invalid)
    }

    @Test(arguments: [false, true])
    func interruptedPublicationNeverOffersEditingOrApproval(_ canRetry: Bool) {
        let presentation = Presentation(actions: canRetry ? [.retry] : [], proposal: proposal(), childFailureSource: .discovery)
        #expect(presentation.isInterrupted)
        #expect(presentation.primaryAction?.action == (canRetry ? .retry : nil))
        #expect(!presentation.canEdit)
        #expect(!presentation.canDiscover)
    }

    @Test func failedWithdrawalOffersAnotherEditAttempt() {
        let presentation = Presentation(
            actions: [.approveRepair, .cancelRepair], proposal: proposal(), hasOperationError: true, lastAction: .edit
        )
        #expect(presentation.primaryAction == .init(action: .edit, isRetry: true))
        #expect(presentation.status == .draftFailure)
    }

    @Test func failedApprovalRetriesApprovalRatherThanStartingOver() {
        let presentation = Presentation(
            actions: [.approveRepair, .cancelRepair], proposal: proposal(), hasOperationError: true, lastAction: .approve
        )
        #expect(presentation.primaryAction == .init(action: .approve, isRetry: true))
        #expect(presentation.status == .updateFailure)
    }

    @Test func editingARestoredProposalKeepsAddressesAndRemovesInboxWriteRoles() throws {
        let reviewed = snapshot(proposal: proposal(writes: ["wss://write.example.com"]))
        let change = try #require(Presentation.ProposalChange(action: .edit, snapshot: reviewed))
        let selection = try change.draft.selection(for: .inboxRelays)
        #expect(selection.reads == ["wss://inbox.example.com", "wss://write.example.com"])
        #expect(selection.writes.isEmpty)
        #expect(change.isComplete(in: snapshot(revision: 2), hasError: false))
    }

    @Test func editingKeepsInvalidAddressesVisibleForCorrection() throws {
        let change = try #require(Presentation.ProposalChange(
            action: .edit, snapshot: snapshot(proposal: proposal(reads: ["ws://127.0.0.1"]))
        ))
        let entry = try #require(change.draft.entries.first)
        #expect(entry.address == "ws://127.0.0.1")
        #expect(throws: AccountSetupRelayDraft.ValidationError.invalidAddress(entry.id)) {
            try change.draft.selection(for: .inboxRelays)
        }
    }

    @Test func discardClearsTheDraftOnlyAfterSuccessfulWithdrawal() throws {
        let reviewed = snapshot(proposal: proposal())
        let change = try #require(Presentation.ProposalChange(action: .discard, snapshot: reviewed))
        #expect(change.draft.entries.isEmpty)
        #expect(!change.isComplete(in: reviewed, hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2), hasError: true))
        #expect(change.isComplete(in: snapshot(revision: 2), hasError: false))
    }

    @Test func unrelatedOrStaleSnapshotsDoNotCompleteAnEdit() throws {
        let change = try #require(Presentation.ProposalChange(action: .edit, snapshot: snapshot(proposal: proposal())))
        #expect(!change.isComplete(in: snapshot(), hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2, proposal: proposal()), hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2, account: "different"), hasError: false))
        #expect(!change.isComplete(in: snapshot(revision: 2, epoch: "different"), hasError: false))
    }

    private func proposal(reads: [String] = ["wss://inbox.example.com"], writes: [String] = []) -> OnboardingRepairProposalFfi {
        .init(step: .inboxRelays, revision: 1, previousEventId: nil,
              readRelays: reads, writeRelays: writes, profile: nil, follows: nil)
    }

    private func snapshot(
        revision: UInt64 = 1, proposal: OnboardingRepairProposalFfi? = nil, account: String = "account", epoch: String = "epoch"
    ) -> OnboardingSnapshotFfi {
        .init(accountIdHex: account, recoveryEpoch: epoch, revision: revision, ready: false,
              steps: [.init(step: .inboxRelays, status: .needsInput, findings: [], actions: [.editRelays], checkedAt: nil)],
              proposal: proposal, singleDeviceNotice: nil, cancellationPending: false)
    }
}
