import MarmotKit
import SwiftUI

struct AccountSetupRelayRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    let selectedStep: OnboardingStepFfi
    @State private var isDismissing = false
    @State private var presentation: AccountSetupRecoveryPresentation
    @State private var editor: Editor?
    @State private var draft = AccountSetupRelayDraft()
    @State private var lastAction: Action?
    @State private var activeAction: Action?
    @State private var operationPrimary: PrimaryAction?
    @State private var failureMessage: String?
    @State private var proposedDraft: AccountSetupRelayDraft
    @State private var confirmsDiscard = false

    private enum Editor: String, Identifiable {
        case relays, discovery
        var id: String { rawValue }
    }
    private enum Action { case defaults, approve, retry, edit, discard, discovery }
    private struct PrimaryAction {
        let action: Action
        let title: LocalizedStringKey
    }

    init(model: AccountSetupModel, selectedStep: OnboardingStepFfi) {
        self.model = model
        self.selectedStep = selectedStep
        _presentation = State(initialValue: AccountSetupRecoveryPresentation(snapshot: model.snapshot))
        _proposedDraft = State(initialValue: AccountSetupRelayDraft(
            proposal: model.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
        ))
    }

    private var step: OnboardingStepStateFfi? { presentation.snapshot.steps.first { $0.step == selectedStep } }
    private var proposal: OnboardingRepairProposalFfi? {
        presentation.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
    }
    private var interrupted: Bool {
        proposal != nil && !allows(.approveRepair) && !allows(.cancelRepair)
    }
    private var invalidProposal: Bool {
        guard let proposal else { return false }
        return AccountSetupInput.proposalRelays(proposal.readRelays) == nil
            || AccountSetupInput.proposalRelays(proposal.writeRelays) == nil
            || (try? proposedDraft.selection()) == nil
    }
    private var isBusy: Bool { model.isBusy || activeAction != nil || isDismissing }
    private var childFailure: AccountSetupRecoveryPresentation.ChildFailure? { presentation.childFailure }
    private var hasFailure: Bool { model.errorMessage != nil || failureMessage != nil || childFailure != nil }
    private var defaults: [String] { AppContainerConfig.accountRelays(runtimeRelays: MarmotClient.seedRelays) }

    var body: some View {
        NavigationStack {
            AccountSetupRecoveryLayout(title: L10n.string("Your relays"), isBusy: isBusy,
                                       onBack: allows(.cancelRepair) && model.isConnected ? { confirmsDiscard = true } : nil) {
                Section {
                    AccountSetupRecoveryCallout(
                        title: statusTitle,
                        symbol: hasFailure || interrupted || invalidProposal ? "exclamationmark.circle" : "network",
                        isError: !isDismissing && (hasFailure || interrupted || invalidProposal), isLoading: isBusy && !isDismissing
                    ) {
                        statusMessage
                        if !isBusy, !hasFailure, proposal == nil, let step {
                            ForEach(AccountSetupPresentation.findingMessages(step.findings), id: \.self) { message in
                                Text(verbatim: message)
                            }
                        }
                        if proposal != nil || allows(.useRecommendedRelays) {
                            Divider()
                            publicationExplanation
                        }
                    }
                }
                if proposal != nil {
                    Section {
                        ForEach(proposedDraft.entries) { entry in
                            AccountSetupRelaySummary(entry: entry)
                        }
                    } header: { Text("Proposed relays") }
                } else if allows(.useRecommendedRelays) {
                    Section {
                        ForEach(defaults, id: \.self) { address in
                            AccountSetupRelaySummary(address: address)
                        }
                    } header: { Text("Default relays") }
                }
            } actions: {
                actions.disabled(isBusy || !model.isConnected)
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
                        AccountSetupRelayEditor(model: model, draft: $draft, onFailure: { message in
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
        .alert("Discard relay changes?", isPresented: $confirmsDiscard) {
            Button("Discard Changes", role: .destructive) { perform(.discard) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards the proposed relay list without publishing it.")
        }
        .onChange(of: model.snapshot) { updatePresentation() }
        .onChange(of: model.isBusy) { updatePresentation() }
    }

    private func updatePresentation() {
        guard !isBusy, model.isConnected else { return }
        let next = model.snapshot
        if model.errorMessage == nil, presentation.snapshot != next {
            failureMessage = nil
        }
        let previousProposal = proposal
        if presentation.update(next, step: selectedStep, operationError: model.errorMessage) {
            isDismissing = true
            dismiss()
            return
        }
        if previousProposal != proposal {
            proposedDraft = AccountSetupRelayDraft(proposal: proposal)
        }
    }

    private var statusTitle: LocalizedStringKey {
        if isBusy { return "Your relays" }
        if settingsChanged { return "Relay settings changed" }
        if hasFailure {
            if childFailure?.source == .relays { return "Couldn’t prepare your relay changes" }
            if childFailure?.source == .discovery { return "Couldn’t find your relay settings" }
            if lastAction == .retry, interrupted { return "Couldn’t save your relays" }
            switch lastAction {
            case .defaults, .approve: return "Couldn’t save your relays"
            case .edit, .discard: return "Couldn’t change your relay draft"
            default: return "Couldn’t check your relays"
            }
        }
        if interrupted { return "Your relay update didn’t finish" }
        if invalidProposal { return "Check your relay addresses" }
        if proposal != nil { return "Review your relay changes" }
        if allows(.useRecommendedRelays) { return "Set up your relays" }
        if allows(.editRelays) { return "Your relays need attention" }
        return "Couldn’t find your relay settings"
    }

    @ViewBuilder private var statusMessage: some View {
        if isDismissing {
            Text("Done")
        } else if isBusy {
            Text(progressMessage)
        } else if settingsChanged {
            Text("Your relay settings changed during this step. Review the current options before continuing.")
        } else if lastAction == .discard, hasFailure, allows(.cancelRepair) {
            Text("Couldn’t discard your relay changes. Use Back to try again.")
        } else if let error = model.errorMessage ?? childFailure?.message ?? failureMessage {
            Text(failureExplanation(error))
        } else if interrupted {
            Text("Your relay changes haven’t finished publishing. Try again to complete the update.")
        } else if invalidProposal {
            Text("This list needs a valid write relay, and every address must be valid. Edit the relays below to continue.")
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

    @ViewBuilder private var publicationExplanation: some View {
        if proposal == nil {
            Text("Using defaults adds any missing addresses below to your public relay list. Existing entries are kept.")
        } else {
            Text("Saving publishes this as your public relay list. It replaces the previous list, removing any entries not included here.")
        }
    }

    private var settingsChanged: Bool {
        (model.errorMessage ?? childFailure?.message ?? failureMessage) == L10n.string("Setup changed. Try again to review the latest options.")
    }

    private var progressMessage: LocalizedStringKey {
        switch activeAction {
        case .defaults, .approve: return "Saving…"
        case .discard: return "Discarding changes…"
        case .edit: return "Preparing changes…"
        case .retry: return interrupted ? "Saving…" : "Checking…"
        case .discovery: return "Searching…"
        case nil: return "Checking…"
        }
    }

    private var primaryAction: PrimaryAction? {
        if let operationPrimary { return operationPrimary }
        if interrupted { return allows(.retry) ? .init(action: .retry, title: "Try Again") : nil }
        if hasFailure, childFailure?.source == .relays, proposal == nil, allows(.editRelays) {
            return .init(action: .edit, title: "Edit Relays")
        }
        if hasFailure, childFailure?.source == .discovery,
           allows(.editDiscoveryRelays), !allows(.useRecommendedRelays) {
            return .init(action: .discovery, title: "Find Existing Relay Settings")
        }
        if hasFailure, lastAction == .edit, allows(.cancelRepair) {
            return .init(action: .edit, title: "Try Again")
        }
        if proposal != nil, allows(.approveRepair), !invalidProposal {
            return .init(action: .approve, title: hasFailure && lastAction == .approve ? "Try Again" : "Save Relay Changes")
        }
        if allows(.useRecommendedRelays) {
            return .init(action: .defaults, title: hasFailure && lastAction == .defaults ? "Try Again" : "Use Default Relays")
        }
        if allows(.retry) { return .init(action: .retry, title: "Try Again") }
        if allows(.editRelays) || allows(.cancelRepair) { return .init(action: .edit, title: "Edit Relays") }
        return nil
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            if let primary = primaryAction {
                WNOnboardingButton(title: primary.title, isLoading: isBusy && activeAction == primary.action) {
                    perform(primary.action)
                }
            }
            if !interrupted {
                if primaryAction?.action != .edit, allows(.editRelays) || allows(.cancelRepair) {
                    WNButton(title: "Edit Relays", emphasis: .secondary, isLoading: isBusy && activeAction == .edit) {
                        perform(.edit)
                    }
                    .environment(\.isEnabled, activeAction == .edit || (!isBusy && model.isConnected))
                    .accessibilityValue(activeAction == .edit ? "In progress" : "")
                }
                if primaryAction?.action != .discovery, allows(.editDiscoveryRelays) {
                    WNButton(title: "Find Existing Relay Settings", emphasis: .secondary) { perform(.discovery) }
                }
            }
        }
    }

    private func allows(_ action: OnboardingActionFfi) -> Bool { step?.actions.contains(action) == true }

    private func perform(_ action: Action) {
        guard !isBusy else { return }
        if action == .edit, proposal == nil {
            editor = .relays
            return
        }
        let command: AccountSetupCommand
        switch action {
        case .discovery:
            editor = .discovery
            return
        case .defaults: command = .useDefaults(selectedStep)
        case .approve:
            guard let proposal, !invalidProposal else { return }
            command = .approve(proposal.revision, recoveryEpoch: presentation.snapshot.recoveryEpoch)
        case .retry: command = .retry(selectedStep)
        case .discard: command = .cancelRepair
        case .edit:
            // Keep the displayed draft while cancelling its immutable MDK proposal.
            draft = AccountSetupRelayDraft(proposal: proposal)
            command = .cancelRepair
        }
        let primary = primaryAction
        let previousError = model.errorMessage ?? childFailure?.message ?? failureMessage
        guard let operation = model.send(command) else { return }
        presentation.clearChildFailure()
        operationPrimary = primary
        activeAction = action
        lastAction = action
        failureMessage = previousError
        Task {
            await operation.value
            failureMessage = model.errorMessage
            activeAction = nil
            operationPrimary = nil
            updatePresentation()
            guard model.errorMessage == nil, model.isConnected, model.snapshot.proposal == nil else { return }
            if action == .discard {
                draft = AccountSetupRelayDraft()
            } else if action == .edit,
                      model.snapshot.steps.first(where: { $0.step == selectedStep })?.actions.contains(.editRelays) == true {
                editor = .relays
            }
        }
    }

    private func failureExplanation(_ error: String) -> String {
        guard error == L10n.string("Couldn’t finish this step. Try again.") else { return error }
        if childFailure?.source == .relays {
            return L10n.string("Your relay draft is still available. Review the changes and try again.")
        }
        if childFailure?.source == .discovery {
            return L10n.string("Couldn’t find your settings. Try another relay.")
        }
        if lastAction == .retry, interrupted {
            return L10n.string("We couldn’t finish saving the relay list below. Try again to complete the update.")
        }
        switch lastAction {
        case .defaults, .approve:
            return L10n.string("We couldn’t finish saving the relay list below. Try again to complete the update.")
        case .edit, .discard:
            return L10n.string("Your relay draft is still available. Review the changes and try again.")
        default:
            return L10n.string("We couldn’t finish checking your relay settings. Try again, or search another relay.")
        }
    }
}
