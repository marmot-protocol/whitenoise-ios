import MarmotKit
import SwiftUI

struct AccountSetupRelayStepView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    let selectedStep: OnboardingStepFfi
    @State private var isDismissing = false
    @State private var presentation: AccountSetupRecoveryPresentation
    @State private var editor: Editor?
    @State private var draft = AccountSetupRelayDraft()
    @State private var proposedDraft: AccountSetupRelayDraft
    @State private var activeAction: Action?
    @State private var lastAction: Action?
    @State private var operationPrimary: PrimaryAction?
    @State private var confirmsDiscard = false
    @State private var discardAction: Action = .discard

    private enum Editor: String, Identifiable {
        case relays, discovery
        var id: String { rawValue }
    }
    private typealias Action = AccountSetupRelayStepPresentation.Action
    private typealias PrimaryAction = AccountSetupRelayStepPresentation.PrimaryAction

    private var recovery: AccountSetupRelayStepPresentation {
        .init(step: selectedStep, actions: step?.actions ?? [], proposal: proposal, childFailureSource: childFailure?.source,
              hasOperationError: model.errorMessage != nil, lastAction: lastAction,
              needsEarlierReview: AccountSetupRelayStepPresentation.needsEarlierReview(in: presentation.snapshot, step: selectedStep))
    }

    init(model: AccountSetupModel, selectedStep: OnboardingStepFfi) {
        self.model = model
        self.selectedStep = selectedStep
        _presentation = State(initialValue: AccountSetupRecoveryPresentation(snapshot: model.snapshot))
        _proposedDraft = State(initialValue: AccountSetupRelayDraft(
            proposal: model.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
        ))
    }

    private var isInbox: Bool { selectedStep == .inboxRelays }
    private var step: OnboardingStepStateFfi? { presentation.snapshot.steps.first { $0.step == selectedStep } }
    private var proposal: OnboardingRepairProposalFfi? {
        presentation.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
    }
    private var interrupted: Bool { recovery.isInterrupted }
    private var isBusy: Bool { model.isBusy || activeAction != nil || isDismissing }
    private var childFailure: AccountSetupRecoveryPresentation.ChildFailure? { presentation.childFailure }
    private var hasFailure: Bool { model.errorMessage != nil || childFailure != nil }
    private var hasError: Bool { hasFailure || interrupted || recovery.isInvalid }
    private var settingsChanged: Bool {
        (model.errorMessage ?? childFailure?.message) == L10n.string("Setup changed. Try again to review the latest options.")
    }
    private var defaultRelays: [String] {
        isInbox ? MarmotClient.seedRelays : AppContainerConfig.accountRelays(runtimeRelays: MarmotClient.seedRelays)
    }

    var body: some View {
        NavigationStack {
            AccountSetupRecoveryLayout(title: AccountSetupPresentation.title(selectedStep), isBusy: isBusy,
                                       onBack: allows(.cancelRepair) && model.isConnected ? { request(.discard) } : nil) {
                Section {
                    AccountSetupRecoveryCallout(title: statusTitle, symbol: hasError ? "exclamationmark.circle" : "network",
                                                isError: !isDismissing && hasError,
                                                isLoading: isBusy && !isDismissing) {
                        explanation
                        if recovery.canSearchDefaults {
                            Divider()
                            Text("Search these relays for your existing settings. This won’t publish changes to your profile.")
                        } else if !recovery.isInvalid, proposal != nil || allows(.useRecommendedRelays) {
                            Divider()
                            publicationExplanation
                        }
                    }
                }
                if let proposal {
                    if isInbox {
                        addresses(proposal.readRelays, title: "Proposed inbox relays")
                        if !proposal.writeRelays.isEmpty { addresses(proposal.writeRelays, title: "Write relays") }
                    } else {
                        Section {
                            ForEach(proposedDraft.entries) { AccountSetupRelaySummary(entry: $0) }
                        } header: { Text("Proposed relays") }
                    }
                } else if recovery.canSearchDefaults || allows(.useRecommendedRelays) {
                    let relays = recovery.canSearchDefaults ? MarmotClient.seedRelays : defaultRelays
                    let header: LocalizedStringKey = recovery.canSearchDefaults ? "Relays to search" : "Default relays"
                    if isInbox {
                        addresses(relays, title: header)
                    } else {
                        Section {
                            ForEach(relays, id: \.self) { AccountSetupRelaySummary(address: $0) }
                        } header: { Text(header) }
                    }
                }
            } actions: {
                VStack(spacing: 8) {
                    if let primary = primaryAction {
                        WNOnboardingButton(title: primaryTitle(primary), isLoading: isBusy && activeAction == primary.action) {
                            request(primary.action)
                        }
                    }
                    ForEach(recovery.secondaryActions, id: \.self) { action in
                        WNButton(title: title(for: action, isPrimary: false), emphasis: .secondary,
                                 isLoading: activeAction == action) { request(action) }
                            .environment(\.isEnabled, activeAction == action || (!isBusy && model.isConnected))
                            .accessibilityValue(activeAction == action ? "In progress" : "")
                    }
                }
                .disabled(isBusy || !model.isConnected)
            }
            .toolbar {
                if allows(.cancelRepair), model.isConnected {
                    ToolbarItem(placement: .confirmationAction) {
                        WNIconButton(title: "Close", systemImage: "xmark", chrome: .container) { dismiss() }
                            .disabled(isBusy)
                    }
                }
            }
            .sheet(item: $editor) { editor in
                NavigationStack {
                    switch editor {
                    case .relays:
                        AccountSetupRelayEditor(model: model, step: selectedStep, draft: $draft, onFailure: { message in
                            presentation.reportChildFailure(source: .relays, message: message, revision: model.snapshot.revision)
                        })
                    case .discovery:
                        AccountSetupDiscoverySheet(model: model, step: selectedStep, onFailure: { message in
                            presentation.reportChildFailure(source: .discovery, message: message, revision: model.snapshot.revision)
                        })
                    }
                }
                .appAppearance()
            }
        }
        .alert(discardAction == .edit ? editTitle : "Discard relay changes?", isPresented: $confirmsDiscard) {
            if discardAction == .edit {
                Button(editTitle) { perform(.edit) }
            } else {
                Button("Discard Changes", role: .destructive) { perform(.discard) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if discardAction == .edit {
                Text("Editing withdraws this proposal and keeps the addresses in your draft. Nothing is published until you review and save again.")
            } else {
                Text("This discards the proposed relay list without publishing it.")
            }
        }
        .onChange(of: model.snapshot) { updatePresentation() }
        .onChange(of: model.isBusy) { updatePresentation() }
    }

    private var statusTitle: LocalizedStringKey {
        if isBusy { return isInbox ? "Your inbox relays" : "Your relays" }
        if settingsChanged { return "Relay settings changed" }
        switch recovery.status {
        case .operationFailure: return "Couldn’t continue signing in"
        case .earlierCheck: return "Review Sign-In Checks"
        case .relays:
            if isInbox { return "Your inbox relays" }
            if allows(.useRecommendedRelays) { return "Set up your relays" }
            return allows(.editRelays) ? "Your relays need attention" : "Couldn’t find your relay settings"
        case .review: return "Review your relay changes"
        case .invalid: return isInbox ? "Your relays need attention" : "Check your relay addresses"
        case .interrupted: return "Your relay update didn’t finish"
        case .draftFailure: return "Couldn’t prepare your relay changes"
        case .discoveryFailure: return "Couldn’t find your relay settings"
        case .checkFailure: return "Couldn’t check your relays"
        case .discardFailure: return "Couldn’t discard your relay changes"
        case .updateFailure: return isInbox ? "Couldn’t update your inbox relays" : "Couldn’t save your relays"
        }
    }

    @ViewBuilder private var explanation: some View {
        if isDismissing {
            Text("Done")
        } else if isBusy {
            Text(progressMessage)
        } else if recovery.needsEarlierReview {
            Text("Another sign-in check needs your attention. Review it before continuing.")
        } else if settingsChanged {
            Text("Your relay settings changed during this step. Review the current options before continuing.")
        } else if lastAction == .discard, model.errorMessage != nil, allows(.cancelRepair) {
            Text("Couldn’t discard your relay changes. Use Back to try again.")
        } else if let error = model.errorMessage ?? childFailure?.message {
            Text(failureExplanation(error))
        } else if interrupted {
            Text(isInbox
                 ? "Your previous update hasn’t finished. Try again to finish publishing it."
                 : "Your relay changes haven’t finished publishing. Try again to complete the update.")
        } else if recovery.isInvalid {
            Text(isInbox
                 ? "This inbox relay list is invalid. Edit the addresses before reviewing it again. Nothing will be published."
                 : "This list needs a valid write relay, and every address must be valid. Edit the relays below to continue.")
        } else {
            readyMessage
            if let step {
                ForEach(AccountSetupPresentation.findingMessages(step.findings), id: \.self) { Text(verbatim: $0) }
            }
        }
    }

    @ViewBuilder private var readyMessage: some View {
        if isInbox {
            Text("Inbox relays receive invitations to new chats and groups.")
        } else if proposal != nil {
            Text("Check the addresses and their uses before saving.")
        } else if allows(.useRecommendedRelays) {
            Text("We couldn’t find a usable relay list for your profile. You can use the defaults below, or search a relay you’ve used before.")
        } else if allows(.editRelays) {
            Text("Your current relay settings don’t let this profile publish information. Edit your relay list, or search another relay for your existing settings.")
        } else {
            Text("We couldn’t finish checking your relay settings. Try again, or search a relay you’ve used with this profile. Searching won’t publish changes.")
        }
    }

    private var progressMessage: LocalizedStringKey {
        switch activeAction {
        case .defaults, .approve: return "Saving…"
        case .discard: return "Discarding changes…"
        case .retry: return interrupted ? "Saving…" : "Checking…"
        case .edit: return "Preparing changes…"
        case .discovery, .searchDefaults: return "Searching…"
        case .reviewChecks, nil: return "Checking…"
        }
    }

    @ViewBuilder private var publicationExplanation: some View {
        switch (isInbox, proposal == nil) {
        case (true, true):
            Text("Continuing adds any of these addresses that are missing to your public profile. Relays already listed there are kept.")
        case (true, false):
            Text("Saving publishes these addresses as your inbox relay list. It replaces the previous list, removing any entries not included here.")
        case (false, true):
            Text("Using defaults adds any missing addresses below to your public relay list. Existing entries are kept.")
        case (false, false):
            Text("Saving publishes this as your public relay list. It replaces the previous list, removing any entries not included here.")
        }
    }

    private func addresses(_ values: [String], title: LocalizedStringKey) -> some View {
        Section {
            ForEach(Array(values.enumerated()), id: \.offset) { index, address in
                Text(verbatim: ContentSanitizer.relayDisplayLine(address, maxLength: 512) ?? L10n.string("Invalid relay address"))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .wnGroupedCardRow(.at(index, of: values.count))
            }
        } header: { Text(title) }
    }

    private var primaryAction: PrimaryAction? { operationPrimary ?? recovery.primaryAction }

    private var editTitle: LocalizedStringKey { isInbox ? "Edit Inbox Relays" : "Edit Relays" }

    private func primaryTitle(_ primary: PrimaryAction) -> LocalizedStringKey {
        primary.isRetry ? "Try Again" : title(for: primary.action, isPrimary: true)
    }

    private func title(for action: Action, isPrimary: Bool) -> LocalizedStringKey {
        switch action {
        case .defaults: return "Use Default Relays"
        case .approve: return isInbox ? "Use These Relays" : "Save Relay Changes"
        case .retry: return "Try Again"
        case .discard: return "Discard Changes"
        case .edit: return isInbox && proposal == nil && !isPrimary ? "Choose Inbox Relays" : editTitle
        case .discovery: return isInbox ? "Look on Another Relay" : "Find Existing Relay Settings"
        case .searchDefaults: return "Search Default Relays"
        case .reviewChecks: return "Review Sign-In Checks"
        }
    }

    private func request(_ action: Action) {
        if action == .discard || (action == .edit && proposal != nil) {
            discardAction = action
            confirmsDiscard = true
        } else {
            perform(action)
        }
    }

    private func allows(_ action: OnboardingActionFfi) -> Bool { step?.actions.contains(action) == true }

    private func perform(_ action: Action) {
        guard !isBusy else { return }
        if action == .edit, proposal == nil {
            editor = .relays
            return
        }
        let proposalChange = AccountSetupRelayStepPresentation.ProposalChange(
            action: action, step: selectedStep, snapshot: presentation.snapshot
        )
        let command: AccountSetupCommand
        switch action {
        case .edit, .discard: command = .cancelRepair
        case .discovery:
            editor = .discovery
            return
        case .searchDefaults: command = .discovery(MarmotClient.seedRelays)
        case .reviewChecks:
            dismiss()
            return
        case .defaults: command = .useDefaults(selectedStep)
        case .approve:
            guard let proposal, recovery.isValidProposal else { return }
            command = .approve(proposal.revision, recoveryEpoch: presentation.snapshot.recoveryEpoch)
        case .retry: command = .retry(selectedStep)
        }
        let primary = primaryAction
        guard let operation = model.send(command) else { return }
        presentation.clearChildFailure()
        operationPrimary = primary
        activeAction = action
        lastAction = action
        Task {
            await operation.value
            activeAction = nil
            operationPrimary = nil
            if action == .searchDefaults, model.errorMessage != nil
                || model.snapshot.steps.first(where: { $0.step == selectedStep })?.status == .retryableFailure {
                presentation.reportChildFailure(source: .discovery,
                                                message: model.errorMessage ?? L10n.string("Couldn’t find your settings. Try another relay."),
                                                revision: model.snapshot.revision)
            }
            updatePresentation()
            guard model.isConnected, let proposalChange,
                  proposalChange.isComplete(in: model.snapshot, hasError: model.errorMessage != nil) else { return }
            draft = proposalChange.draft
            if proposalChange.action == .edit, !isDismissing,
               model.snapshot.steps.first(where: { $0.step == selectedStep })?.actions.contains(.editRelays) == true {
                editor = .relays
            }
        }
    }

    private func updatePresentation() {
        guard !isBusy, model.isConnected else { return }
        let previousProposal = proposal
        if presentation.update(model.snapshot, step: selectedStep, operationError: model.errorMessage) {
            isDismissing = true
            dismiss()
            return
        }
        if previousProposal != proposal {
            proposedDraft = AccountSetupRelayDraft(proposal: proposal)
        }
    }

    private func failureExplanation(_ error: String) -> String {
        guard error == L10n.string("Couldn’t finish this step. Try again.") else { return error }
        switch recovery.status {
        case .operationFailure: return error
        case .draftFailure, .discardFailure: return L10n.string("Your relay draft is still available. Review the changes and try again.")
        case .discoveryFailure: return L10n.string("Couldn’t find your settings. Try another relay.")
        case .checkFailure: return L10n.string("We couldn’t finish checking your relay settings. Try again, or search another relay.")
        default: return L10n.string("We couldn’t finish saving the relay list below. Try again to complete the update.")
        }
    }
}
