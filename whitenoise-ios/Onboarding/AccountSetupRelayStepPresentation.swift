import MarmotKit

nonisolated struct AccountSetupRelayStepPresentation {
    enum Action {
        case defaults, approve, retry, discard, edit, discovery, searchDefaults, reviewChecks, suggest, replaceWithDefaults
    }
    enum Status {
        case relays, review, manualReview, invalid, interrupted, draftFailure, previewFailure, discoveryFailure, checkFailure
        case discardFailure, updateFailure, operationFailure, earlierCheck
    }
    struct PrimaryAction: Equatable {
        let action: Action
        var isRetry = false
    }

    let step: OnboardingStepFfi
    let actions: [OnboardingActionFfi]
    let proposal: OnboardingRepairProposalFfi?
    let childFailureSource: AccountSetupRecoveryPresentation.ChildFailure.Source?
    let hasOperationError: Bool
    let lastAction: Action?
    let needsEarlierReview: Bool
    let lookupFailed: Bool
    /// The list Replace With Default Relays would propose for this step.
    let defaultRelays: [String]
    /// MDK's typed relay-list diff for this step's proposal, when it has one.
    let repair: AccountSetupRelayRepairPresentation?

    init(
        step: OnboardingStepFfi, actions: [OnboardingActionFfi], proposal: OnboardingRepairProposalFfi?,
        childFailureSource: AccountSetupRecoveryPresentation.ChildFailure.Source? = nil, hasOperationError: Bool = false,
        lastAction: Action? = nil, needsEarlierReview: Bool = false, lookupFailed: Bool = false, defaultRelays: [String] = []
    ) {
        self.step = step
        self.actions = actions
        self.proposal = proposal
        self.childFailureSource = childFailureSource
        self.hasOperationError = hasOperationError
        self.lastAction = lastAction
        self.needsEarlierReview = needsEarlierReview
        self.lookupFailed = lookupFailed
        self.defaultRelays = defaultRelays
        repair = AccountSetupRelayRepairPresentation(proposal: proposal, step: step)
    }

    var isManualReview: Bool { repair?.isManualReview == true }

    var isValidProposal: Bool {
        guard let proposal,
              AccountSetupInput.proposalRelays(proposal.readRelays) != nil,
              let writes = AccountSetupInput.proposalRelays(proposal.writeRelays) else { return false }
        // Inbox relays have no write role; a proposal carrying one is not what the user reviewed.
        if step == .inboxRelays, !writes.isEmpty { return false }
        // A typed preview publishes its diff, so every published tag must check out.
        if proposal.relayRepair != nil { return repair?.isApprovable == true }
        return (try? AccountSetupRelayDraft(proposal: proposal).selection(for: step)) != nil
    }

    /// A manual-review preview has nothing to approve, so it is never invalid or interrupted.
    var isInvalid: Bool { proposal != nil && !isManualReview && !isValidProposal }
    var isInterrupted: Bool { proposal != nil && !isManualReview && !allows(.approveRepair) && !allows(.cancelRepair) }
    var canEdit: Bool {
        guard !isInterrupted else { return false }
        if proposal == nil { return allows(.editRelays) }
        return allows(.cancelRepair) || (isManualReview && allows(.editRelays))
    }
    var canDiscover: Bool { !isInterrupted && allows(.editDiscoveryRelays) }

    var canSearchDefaults: Bool { proposal == nil && canDiscover && !allows(.useRecommendedRelays) }

    /// Suggest a Fix only ever runs on an explicit tap, while no proposal is pending.
    var offersSuggestion: Bool { proposal == nil && !isInterrupted && allows(.editRelays) }
    /// A ready-made minimal fix is easier than a blank editor or a bare retry, so it
    /// leads unless Use Default Relays is on offer.
    var suggestionLeads: Bool { offersSuggestion && !allows(.useRecommendedRelays) }

    /// Replacing with the defaults is an explicit edit offered from manual review,
    /// hidden when the current list already declares exactly the defaults.
    var canReplaceWithDefaults: Bool {
        if isManualReview {
            return allows(.editRelays) && repair?.offersDefaultReplacement(defaults: defaultRelays, step: step) == true
        }
        return replacesUncheckedInbox
    }

    var replacesUncheckedInbox: Bool {
        step == .inboxRelays && lookupFailed && proposal == nil && !isInterrupted
            && allows(.editRelays) && !allows(.useRecommendedRelays)
    }

    /// Editing opens the editor without withdrawing anything first.
    var editsDirectly: Bool { proposal == nil || (isManualReview && allows(.editRelays)) }

    /// Withdrawing a reviewable proposal loses it; a manual-review preview has no change to lose.
    func needsConfirmation(_ action: Action) -> Bool {
        !isManualReview && (action == .discard || (action == .edit && proposal != nil) || action == .replaceWithDefaults)
    }

    static func needsEarlierReview(in snapshot: OnboardingSnapshotFfi, step: OnboardingStepFfi) -> Bool {
        guard snapshot.steps.first(where: { $0.step == step })?.status == .pending,
              let current = snapshot.steps.first(where: { $0.status != .passed && $0.status != .skipped }) else { return false }
        return current.step != step && !current.actions.isEmpty
    }

    var primaryAction: PrimaryAction? {
        if needsEarlierReview { return .init(action: .reviewChecks) }
        if isInterrupted { return allows(.retry) ? .init(action: .retry) : nil }
        if hasOperationError, lastAction == .edit, canEdit { return .init(action: .edit, isRetry: true) }
        // Manual review has no approval; the user edits the original list instead.
        if isManualReview { return canEdit ? .init(action: .edit) : nil }
        if isInvalid, canEdit { return .init(action: .edit) }
        if childFailureSource == .relays, proposal == nil, canEdit { return .init(action: .edit) }
        if proposal != nil, allows(.approveRepair), !isInvalid {
            return .init(action: .approve, isRetry: hasOperationError && lastAction == .approve)
        }
        if allows(.useRecommendedRelays) {
            return .init(action: .defaults, isRetry: hasOperationError && lastAction == .defaults)
        }
        if suggestionLeads { return .init(action: .suggest) }
        if canSearchDefaults { return .init(action: .searchDefaults) }
        if allows(.retry) { return .init(action: .retry) }
        return canEdit ? .init(action: .edit) : nil
    }

    var secondaryActions: [Action] {
        let primary = primaryAction?.action
        var result: [Action] = []
        // Searching only the defaults drops MDK's public indexers for the rest of the
        // attempt. Until then, Try Again repeats the broader lookup. A leading
        // suggestion must not hide a retry the step still offers either.
        if primary == .searchDefaults || primary == .suggest, allows(.retry) { result.append(.retry) }
        if primary == .suggest, canSearchDefaults { result.append(.searchDefaults) }
        if offersSuggestion, primary != .suggest { result.append(.suggest) }
        if canReplaceWithDefaults { result.append(.replaceWithDefaults) }
        if canEdit, primary != .edit { result.append(.edit) }
        if canDiscover, primary != .discovery { result.append(.discovery) }
        return result
    }

    var status: Status {
        if needsEarlierReview { return .earlierCheck }
        if hasOperationError, lastAction == .searchDefaults { return .discoveryFailure }
        if childFailureSource == .relays { return .draftFailure }
        if childFailureSource == .discovery { return .discoveryFailure }
        if hasOperationError {
            if lastAction == nil { return .operationFailure }
            if lastAction == .retry, !isInterrupted { return .checkFailure }
            if lastAction == .discard { return .discardFailure }
            if lastAction == .edit { return .draftFailure }
            if lastAction == .suggest || lastAction == .replaceWithDefaults { return .previewFailure }
            return .updateFailure
        }
        if isInterrupted { return .interrupted }
        if isManualReview { return .manualReview }
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

        init?(action: Action, step: OnboardingStepFfi, snapshot: OnboardingSnapshotFfi) {
            guard action == .edit || action == .discard,
                  let proposal = snapshot.proposal, proposal.step == step else { return nil }
            self.action = action
            // Keep the displayed list in the draft while withdrawing its immutable MDK proposal.
            draft = action == .edit
                ? AccountSetupRelayRepairPresentation(proposal: proposal, step: step)?.editorDraft
                    ?? AccountSetupRelayDraft(proposal: proposal)
                : AccountSetupRelayDraft()
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
