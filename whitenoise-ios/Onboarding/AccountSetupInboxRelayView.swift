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

    private enum Editor: String, Identifiable {
        case relays, discovery
        var id: String { rawValue }
    }
    private enum Action { case defaults, approve, retry, discard, edit, discovery }
    private struct PrimaryAction {
        let action: Action
        let title: LocalizedStringKey
    }

    init(model: AccountSetupModel) {
        self.model = model
        _presentation = State(initialValue: AccountSetupRecoveryPresentation(snapshot: model.snapshot))
    }

    private var step: OnboardingStepStateFfi? { presentation.snapshot.steps.first { $0.step == selectedStep } }
    private var proposal: OnboardingRepairProposalFfi? {
        presentation.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
    }
    private var interrupted: Bool { proposal != nil && !allows(.approveRepair) && !allows(.cancelRepair) }
    private var isBusy: Bool { model.isBusy || activeAction != nil || isDismissing }
    private var relays: [String]? {
        guard let proposal else {
            return MarmotClient.seedRelays
        }
        guard let reads = AccountSetupInput.proposalRelays(proposal.readRelays),
              let writes = AccountSetupInput.proposalRelays(proposal.writeRelays),
              !reads.isEmpty, writes.isEmpty else { return nil }
        return Array(Set(reads)).sorted()
    }
    private var hasError: Bool { model.errorMessage != nil || childFailure != nil || interrupted || relays == nil }
    private var childFailure: AccountSetupRecoveryPresentation.ChildFailure? { presentation.childFailure }
    private var settingsChanged: Bool {
        (model.errorMessage ?? childFailure?.message) == L10n.string("Setup changed. Try again to review the latest options.")
    }

    var body: some View {
        NavigationStack {
            AccountSetupRecoveryLayout(title: AccountSetupPresentation.title(selectedStep), isBusy: isBusy,
                                       onBack: allows(.cancelRepair) && model.isConnected ? { confirmsDiscard = true } : nil) {
                Section {
                    AccountSetupRecoveryCallout(title: statusTitle, symbol: hasError ? "exclamationmark.circle" : "network",
                                                isError: !isDismissing && hasError,
                                                isLoading: isBusy && !isDismissing) {
                        explanation
                        if relays != nil, proposal != nil || allows(.useRecommendedRelays) {
                            Divider()
                            publicationExplanation
                        }
                    }
                }
                if let proposal {
                    addresses(proposal.readRelays, title: "Proposed inbox relays")
                    if !proposal.writeRelays.isEmpty { addresses(proposal.writeRelays, title: "Write relays") }
                } else if allows(.useRecommendedRelays), let relays {
                    addresses(relays, title: "Default relays")
                }
            } actions: {
                VStack(spacing: 8) {
                    if let primary = primaryAction {
                        WNOnboardingButton(title: primary.title, isLoading: isBusy && activeAction == primary.action) {
                            if primary.action == .discard { confirmsDiscard = true } else { perform(primary.action) }
                        }
                    }
                    if !interrupted {
                        if allows(.editRelays), primaryAction?.action != .edit {
                            if primaryAction == nil {
                                WNOnboardingButton(title: "Choose Inbox Relays") { editor = .relays }
                            } else {
                                WNButton(title: "Choose Inbox Relays", emphasis: .secondary) { editor = .relays }
                            }
                        }
                        if allows(.editDiscoveryRelays), primaryAction?.action != .discovery {
                            WNButton(title: "Look on Another Relay", emphasis: .secondary) { editor = .discovery }
                        }
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
        .alert("Discard relay changes?", isPresented: $confirmsDiscard) {
            Button("Discard Changes", role: .destructive) { perform(.discard) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards the proposed relay list without publishing it.")
        }
        .onChange(of: model.snapshot) { updatePresentation() }
        .onChange(of: model.isBusy) { updatePresentation() }
    }

    private var statusTitle: LocalizedStringKey {
        if isBusy { return "Your inbox relays" }
        if settingsChanged { return "Relay settings changed" }
        if childFailure?.source == .relays { return "Couldn’t prepare your relay changes" }
        if childFailure?.source == .discovery { return "Couldn’t find your relay settings" }
        if model.errorMessage != nil, lastAction == .retry, !interrupted { return "Couldn’t check your relays" }
        if model.errorMessage != nil { return lastAction == .discard ? "Couldn’t discard your relay changes" : "Couldn’t update your inbox relays" }
        if relays == nil { return "Your relays need attention" }
        if interrupted { return "Your relay update didn’t finish" }
        return proposal == nil ? "Your inbox relays" : "Review your relay changes"
    }

    @ViewBuilder private var explanation: some View {
        if isDismissing {
            Text("Done")
        } else if isBusy {
            Text(progressMessage)
        } else if settingsChanged {
            Text("Your relay settings changed during this step. Review the current options before continuing.")
        } else if lastAction == .discard, model.errorMessage != nil, allows(.cancelRepair) {
            Text(relays == nil ? "Couldn’t discard your relay changes. Try again." : "Couldn’t discard your relay changes. Use Back to try again.")
        } else if let error = model.errorMessage ?? childFailure?.message {
            if error == L10n.string("Couldn’t finish this step. Try again."), let childFailure {
                Text(childFailure.source == .relays
                     ? "Your relay draft is still available. Review the changes and try again."
                     : "Couldn’t find your settings. Try another relay.")
            } else {
                Text(error)
            }
        } else if relays == nil {
            Text(allows(.cancelRepair)
                 ? "This inbox relay list is invalid. Discard these changes to choose a new list. Nothing will be published."
                 : "A relay address is invalid. Go back and check the settings.")
        } else if interrupted {
            Text("Your previous update hasn’t finished. Try again to finish publishing it.")
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
        case .discovery: return "Searching…"
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

    private var primaryAction: PrimaryAction? {
        if let operationPrimary { return operationPrimary }
        if interrupted { return allows(.retry) ? .init(action: .retry, title: "Try Again") : nil }
        if childFailure?.source == .relays, proposal == nil, allows(.editRelays) {
            return .init(action: .edit, title: "Edit Inbox Relays")
        }
        if childFailure?.source == .discovery, allows(.editDiscoveryRelays) {
            return .init(action: .discovery, title: "Look on Another Relay")
        }
        if proposal != nil, relays == nil, allows(.cancelRepair) {
            return .init(action: .discard, title: "Discard Changes")
        }
        if proposal != nil, allows(.approveRepair), relays != nil {
            return .init(action: .approve, title: model.errorMessage != nil && lastAction == .approve ? "Try Again" : "Use These Relays")
        }
        if allows(.useRecommendedRelays) {
            return .init(action: .defaults, title: model.errorMessage != nil && lastAction == .defaults ? "Try Again" : "Use Default Relays")
        }
        return allows(.retry) ? .init(action: .retry, title: "Try Again") : nil
    }

    private func allows(_ action: OnboardingActionFfi) -> Bool { step?.actions.contains(action) == true }

    private func perform(_ action: Action) {
        guard !isBusy else { return }
        let command: AccountSetupCommand
        switch action {
        case .edit:
            editor = .relays
            return
        case .discovery:
            editor = .discovery
            return
        case .defaults: command = .useDefaults(selectedStep)
        case .approve:
            guard let proposal, relays != nil else { return }
            command = .approve(proposal.revision, recoveryEpoch: presentation.snapshot.recoveryEpoch)
        case .retry: command = .retry(selectedStep)
        case .discard: command = .cancelRepair
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
            updatePresentation()
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
