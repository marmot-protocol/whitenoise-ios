import MarmotKit
import SwiftUI

struct AccountSetupInboxRelayView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    private let selectedStep: OnboardingStepFfi = .inboxRelays
    @State private var isDismissing = false
    @State private var presentation: AccountSetupRecoveryPresentation
    @State private var editor: Editor?
    @State private var draft = AccountSetupRelayDraft()
    @State private var activeAction: Action?
    @State private var lastAction: Action?
    @State private var operationPrimary: PrimaryAction?
    @State private var confirmsDiscard = false
    @State private var discardAction: Action = .discard

    private enum Editor: String, Identifiable {
        case relays, discovery
        var id: String { rawValue }
    }
    private typealias Action = AccountSetupInboxRelayPresentation.Action
    private typealias PrimaryAction = AccountSetupInboxRelayPresentation.PrimaryAction

    private var recovery: AccountSetupInboxRelayPresentation {
        .init(actions: step?.actions ?? [], proposal: proposal, childFailureSource: childFailure?.source,
              hasOperationError: model.errorMessage != nil, lastAction: lastAction,
              needsEarlierReview: AccountSetupInboxRelayPresentation.needsEarlierReview(in: presentation.snapshot))
    }

    init(model: AccountSetupModel) {
        self.model = model
        _presentation = State(initialValue: AccountSetupRecoveryPresentation(snapshot: model.snapshot))
    }

    private var step: OnboardingStepStateFfi? { presentation.snapshot.steps.first { $0.step == selectedStep } }
    private var proposal: OnboardingRepairProposalFfi? {
        presentation.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
    }
    private var interrupted: Bool { recovery.isInterrupted }
    private var isBusy: Bool { model.isBusy || activeAction != nil || isDismissing }
    private var relays: [String]? { proposal == nil ? MarmotClient.seedRelays : recovery.relays }
    private var hasError: Bool { model.errorMessage != nil || childFailure != nil || interrupted || relays == nil }
    private var childFailure: AccountSetupRecoveryPresentation.ChildFailure? { presentation.childFailure }
    private var settingsChanged: Bool {
        (model.errorMessage ?? childFailure?.message) == L10n.string("Setup changed. Try again to review the latest options.")
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
                        } else if relays != nil, proposal != nil || allows(.useRecommendedRelays) {
                            Divider()
                            publicationExplanation
                        }
                    }
                }
                if let proposal {
                    addresses(proposal.readRelays, title: "Proposed inbox relays")
                    if !proposal.writeRelays.isEmpty { addresses(proposal.writeRelays, title: "Write relays") }
                } else if allows(.useRecommendedRelays) || recovery.canSearchDefaults, let relays {
                    addresses(relays, title: "Default relays")
                }
            } actions: {
                VStack(spacing: 8) {
                    if let primary = primaryAction {
                        WNOnboardingButton(title: title(for: primary), isLoading: isBusy && activeAction == primary.action) {
                            request(primary.action)
                        }
                    }
                    if recovery.canEdit, primaryAction?.action != .edit {
                        WNButton(title: proposal == nil ? "Choose Inbox Relays" : "Edit Inbox Relays",
                                 emphasis: .secondary, isLoading: activeAction == .edit) { request(.edit) }
                            .environment(\.isEnabled, activeAction == .edit || (!isBusy && model.isConnected))
                    }
                    if recovery.canDiscover, primaryAction?.action != .discovery {
                        WNButton(title: "Look on Another Relay", emphasis: .secondary) { perform(.discovery) }
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
        .alert(discardAction == .edit ? "Edit Inbox Relays" : "Discard relay changes?", isPresented: $confirmsDiscard) {
            if discardAction == .edit {
                Button("Edit Inbox Relays") { perform(.edit) }
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
        if isBusy { return "Your inbox relays" }
        if settingsChanged { return "Relay settings changed" }
        switch recovery.status {
        case .earlierCheck: return "Review Sign-In Checks"
        case .relays: return "Your inbox relays"
        case .review: return "Review your relay changes"
        case .invalid: return "Your relays need attention"
        case .interrupted: return "Your relay update didn’t finish"
        case .draftFailure: return "Couldn’t prepare your relay changes"
        case .discoveryFailure: return "Couldn’t find your relay settings"
        case .checkFailure: return "Couldn’t check your relays"
        case .discardFailure: return "Couldn’t discard your relay changes"
        case .updateFailure: return "Couldn’t update your inbox relays"
        }
    }

    @ViewBuilder private var explanation: some View {
        if isDismissing {
            Text("Done")
        } else if isBusy {
            Text(progressMessage)
        } else if recovery.needsEarlierReview {
            Text("Another sign-in check needs your attention. Review it before continuing with your inbox relays.")
        } else if settingsChanged {
            Text("Your relay settings changed during this step. Review the current options before continuing.")
        } else if lastAction == .discard, model.errorMessage != nil, allows(.cancelRepair) {
            Text("Couldn’t discard your relay changes. Use Back to try again.")
        } else if lastAction == .edit, model.errorMessage != nil, allows(.cancelRepair) {
            Text("Your relay draft is still available. Review the changes and try again.")
        } else if let error = model.errorMessage ?? childFailure?.message {
            if error == L10n.string("Couldn’t finish this step. Try again."), let childFailure {
                Text(childFailure.source == .relays
                     ? "Your relay draft is still available. Review the changes and try again."
                     : "Couldn’t find your settings. Try another relay.")
            } else {
                Text(error)
            }
        } else if interrupted {
            Text("Your previous update hasn’t finished. Try again to finish publishing it.")
        } else if relays == nil {
            Text("This inbox relay list is invalid. Edit the addresses before reviewing it again. Nothing will be published.")
        } else {
            Text("Inbox relays receive invitations to new chats and groups.")
            if let step {
                ForEach(AccountSetupPresentation.findingMessages(step.findings), id: \.self) { Text(verbatim: $0) }
            }
        }
    }

    private var progressMessage: LocalizedStringKey {
        switch activeAction {
        case .defaults, .approve: return "Saving…"
        case .discard: return "Discarding changes…"
        case .retry: return interrupted ? "Saving…" : "Checking…"
        case .edit: return "Preparing changes…"
        case .discovery, .searchDefaults: return "Searching…"
        case .reviewChecks: return "Checking…"
        case nil: return "Checking…"
        }
    }

    @ViewBuilder private var publicationExplanation: some View {
        if proposal == nil {
            Text("Continuing adds any of these addresses that are missing to your public profile. Relays already listed there are kept.")
        } else {
            Text("Saving publishes these addresses as your inbox relay list. It replaces the previous list, removing any entries not included here.")
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

    private func title(for primary: PrimaryAction) -> LocalizedStringKey {
        if primary.isRetry { return "Try Again" }
        switch primary.action {
        case .defaults: return "Use Default Relays"
        case .approve: return "Use These Relays"
        case .retry: return "Try Again"
        case .discard: return "Discard Changes"
        case .edit: return "Edit Inbox Relays"
        case .discovery: return "Look on Another Relay"
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
        let proposalChange = AccountSetupInboxRelayPresentation.ProposalChange(action: action, snapshot: presentation.snapshot)
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
            guard let proposal, relays != nil else { return }
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
        if presentation.update(model.snapshot, step: selectedStep, operationError: model.errorMessage) {
            isDismissing = true
            dismiss()
        }
    }
}
