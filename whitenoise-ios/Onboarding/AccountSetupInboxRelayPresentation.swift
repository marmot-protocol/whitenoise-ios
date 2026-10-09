import MarmotKit

nonisolated struct AccountSetupInboxRelayPresentation {
    enum Action { case defaults, approve, retry, discard, edit, discovery }
    enum Status { case relays, review, invalid, interrupted, draftFailure, discoveryFailure, checkFailure, discardFailure, updateFailure }
    struct PrimaryAction: Equatable {
        let action: Action
        var isRetry = false
    }

    let actions: [OnboardingActionFfi]
    let proposal: OnboardingRepairProposalFfi?
    var childFailureSource: AccountSetupRecoveryPresentation.ChildFailure.Source?
    var hasOperationError = false
    var lastAction: Action?

    var relays: [String]? {
        guard let proposal else { return nil }
        guard let reads = AccountSetupInput.proposalRelays(proposal.readRelays),
              let writes = AccountSetupInput.proposalRelays(proposal.writeRelays),
              !reads.isEmpty, writes.isEmpty else { return nil }
        return Array(Set(reads)).sorted()
    }

    var isInvalid: Bool { proposal != nil && relays == nil }
    var isInterrupted: Bool { proposal != nil && !allows(.approveRepair) && !allows(.cancelRepair) }
    var canEdit: Bool { !isInterrupted && (proposal == nil ? allows(.editRelays) : allows(.cancelRepair)) }
    var canDiscover: Bool { !isInterrupted && allows(.editDiscoveryRelays) }

    var primaryAction: PrimaryAction? {
        if isInterrupted { return allows(.retry) ? .init(action: .retry) : nil }
        if hasOperationError, lastAction == .edit, canEdit { return .init(action: .edit, isRetry: true) }
        if isInvalid, canEdit { return .init(action: .edit) }
        if childFailureSource == .relays, proposal == nil, canEdit { return .init(action: .edit) }
        if childFailureSource == .discovery, canDiscover, !allows(.useRecommendedRelays) {
            return .init(action: .discovery)
        }
        if proposal != nil, allows(.approveRepair), !isInvalid {
            return .init(action: .approve, isRetry: hasOperationError && lastAction == .approve)
        }
        if allows(.useRecommendedRelays) {
            return .init(action: .defaults, isRetry: hasOperationError && lastAction == .defaults)
        }
        if allows(.retry) { return .init(action: .retry) }
        return canEdit ? .init(action: .edit) : nil
    }

    var status: Status {
        if childFailureSource == .relays { return .draftFailure }
        if childFailureSource == .discovery { return .discoveryFailure }
        if hasOperationError {
            if lastAction == .retry, !isInterrupted { return .checkFailure }
            if lastAction == .discard { return .discardFailure }
            if lastAction == .edit { return .draftFailure }
            return .updateFailure
        }
        if isInterrupted { return .interrupted }
        if isInvalid { return .invalid }
        return proposal == nil ? .relays : .review
    }

    private func allows(_ action: OnboardingActionFfi) -> Bool { actions.contains(action) }

    struct ProposalChange {
        let action: Action
        let draft: AccountSetupRelayDraft
        private let accountID: String
        private let recoveryEpoch: String?
        private let revision: UInt64

        init?(action: Action, snapshot: OnboardingSnapshotFfi) {
            guard action == .edit || action == .discard,
                  let proposal = snapshot.proposal, proposal.step == .inboxRelays else { return nil }
            self.action = action
            draft = action == .edit ? AccountSetupRelayDraft(proposal: proposal) : AccountSetupRelayDraft()
            accountID = snapshot.accountIdHex
            recoveryEpoch = snapshot.recoveryEpoch
            revision = snapshot.revision
        }

        func isComplete(in snapshot: OnboardingSnapshotFfi, hasError: Bool) -> Bool {
            !hasError && snapshot.accountIdHex == accountID && snapshot.recoveryEpoch == recoveryEpoch
                && snapshot.revision > revision && snapshot.proposal == nil
        }
    }
}
