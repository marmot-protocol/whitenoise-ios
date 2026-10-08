import SwiftUI
import MarmotKit

struct AccountSetupActions: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountSetupModel
    let selectedStep: OnboardingStepFfi
    @State private var editor: SetupEditor?
    @State private var activePrimaryTitle: LocalizedStringKey?

    private var step: OnboardingStepStateFfi? {
        model.snapshot.steps.first { $0.step == selectedStep }
    }

    private var proposal: OnboardingRepairProposalFfi? {
        model.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
    }

    private var relays: [String]? {
        guard let proposal else {
            return selectedStep == .relays
                ? AppContainerConfig.accountRelays(runtimeRelays: MarmotClient.seedRelays)
                : MarmotClient.seedRelays
        }
        guard let reads = AccountSetupInput.proposalRelays(proposal.readRelays),
              let writes = AccountSetupInput.proposalRelays(proposal.writeRelays),
              !reads.isEmpty || !writes.isEmpty,
              selectedStep != .inboxRelays || writes.isEmpty else { return nil }
        return Array(Set(reads + writes)).sorted()
    }

    var body: some View {
        if selectedStep == .profile {
            AccountSetupProfileView(model: model)
        } else if selectedStep == .inboxRelays {
            AccountSetupInboxRelayView(model: model)
        } else if selectedStep == .relays {
            AccountSetupRelayRecoveryView(model: model, selectedStep: selectedStep)
        } else {
            decisionContent
        }
    }

    private var decisionContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explanation
                    if let step, selectedStep != .singleDevice {
                        ForEach(AccountSetupPresentation.findingMessages(step.findings), id: \.self) { message in
                            Text(verbatim: message)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let error = model.errorMessage { Text(error).foregroundStyle(.orange) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .safeAreaPadding()
            }
            .navigationTitle(AccountSetupPresentation.title(selectedStep))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .modifier(WNOnboardingActionBar {
                VStack(spacing: 8) { actions }
                    .disabled(model.isBusy || !model.isConnected)
                    .safeAreaPadding(.horizontal)
                    .safeAreaPadding(.bottom)
            })
            .sheet(item: $editor) { editor in
                NavigationStack {
                    switch editor {
                    case .discovery:
                        AccountSetupDiscoverySheet(model: model, step: selectedStep)
                    case .relays:
                        AccountSetupRelaySheet(model: model, step: selectedStep)
                    }
                }
                .appAppearance()
            }
            .onChange(of: model.snapshot.revision) {
                if let step, step.status == .passed || step.status == .skipped { dismiss() }
            }
        }
    }

    @ViewBuilder private var explanation: some View {
        if proposal != nil, step?.actions.contains(.approveRepair) != true,
           step?.actions.contains(.cancelRepair) != true {
            Text("Your previous update hasn’t finished. Try again to finish publishing it.")
        } else {
            switch selectedStep {
            case .relays, .inboxRelays:
                if step?.actions.contains(.useRecommendedRelays) == true || proposal != nil {
                    Text("Relays let your profile publish information, receive chat invitations, and deliver messages.")
                    if let relays {
                        if let proposal {
                            if selectedStep == .relays {
                                Text("Read relays").font(.headline)
                            }
                            ForEach(proposal.readRelays, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                            if selectedStep == .relays {
                                Text("Write relays").font(.headline)
                                ForEach(proposal.writeRelays, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                            }
                        } else {
                            ForEach(relays, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                        }
                        if proposal == nil {
                            // MDK appends missing defaults to an existing list rather than replacing it.
                            Text("Continuing adds any of these addresses that are missing to your public profile. Relays already listed there are kept.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Continuing publishes these addresses to your public profile.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("A relay address is invalid. Go back and check the settings.").foregroundStyle(.orange)
                    }
                } else if step?.actions.contains(.editRelays) == true {
                    Text("Your current relay roles cannot provide a working write route. Choose relays to review a replacement list.")
                } else {
                    Text("We couldn’t complete the lookup. Try another relay or check again before replacing any settings.")
                }
            case .singleDevice:
                Text("White Noise does not yet sync conversations across devices. We recommend using this profile on one device.")
                if let notice = model.snapshot.singleDeviceNotice {
                    Text(AccountSetupPresentation.deviceNotice(notice.discovery)).foregroundStyle(.secondary)
                }
            case .keyPackage:
                Text("Secure messaging must be ready before you can open Chats. Try this check again.")
            case .follows:
                Text("You can continue without changing the people you follow.")
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let step {
            if proposal != nil, !step.actions.contains(.approveRepair), !step.actions.contains(.cancelRepair) {
                if step.actions.contains(.retry) { action("Try Again", .retry(selectedStep)) }
            } else if selectedStep == .relays || selectedStep == .inboxRelays {
                if let proposal, step.actions.contains(.approveRepair) {
                    action("Use These Relays", .approve(proposal.revision, recoveryEpoch: model.snapshot.recoveryEpoch)).disabled(relays == nil)
                } else if step.actions.contains(.useRecommendedRelays) {
                    action("Use Default Relays", .useDefaults(selectedStep))
                } else if step.actions.contains(.retry) { action("Try Again", .retry(selectedStep)) }
                if step.actions.contains(.editRelays) {
                    WNButton(title: "Choose Relays", emphasis: .secondary) { editor = .relays }
                }
                if step.actions.contains(.editDiscoveryRelays) {
                    WNButton(title: "Look on Another Relay", emphasis: .secondary) { editor = .discovery }
                }
            } else if step.actions.contains(.continueAnyway) {
                action(LocalizedStringKey(AccountSetupPresentation.deviceAction(model.snapshot.singleDeviceNotice?.discovery)),
                       .acknowledge(model.snapshot.revision, recoveryEpoch: model.snapshot.recoveryEpoch))
            } else if step.actions.contains(.retry) { action("Try Again", .retry(selectedStep)) }
            if step.actions.contains(.cancelRepair) { action("Back", .cancelRepair, secondary: true) }
            if selectedStep == .follows, step.actions.contains(.continueWithout) { action("Continue", .skip(.follows)) }
        }
    }

    @ViewBuilder private func action(_ title: LocalizedStringKey, _ command: AccountSetupCommand, secondary: Bool = false) -> some View {
        if secondary {
            WNButton(title: title, emphasis: .secondary) { model.send(command) }
        } else {
            WNOnboardingButton(title: title, isLoading: activePrimaryTitle == title) {
                guard activePrimaryTitle == nil, let operation = model.send(command) else { return }
                activePrimaryTitle = title
                Task {
                    await operation.value
                    activePrimaryTitle = nil
                }
            }
        }
    }
}

private enum SetupEditor: String, Identifiable {
    case discovery, relays
    var id: String { rawValue }
}
