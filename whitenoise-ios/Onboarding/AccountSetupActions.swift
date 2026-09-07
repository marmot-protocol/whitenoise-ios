import SwiftUI
import MarmotKit

struct AccountSetupActions: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AccountSetupModel
    let selectedStep: OnboardingStepFfi
    @State private var editor: SetupEditor?

    private var step: OnboardingStepStateFfi? {
        model.snapshot.steps.first { $0.step == selectedStep }
    }

    private var proposal: OnboardingRepairProposalFfi? {
        model.snapshot.proposal.flatMap { $0.step == selectedStep ? $0 : nil }
    }

    private var relays: [String]? {
        guard let proposal else { return MarmotClient.seedRelays }
        guard let reads = AccountSetupInput.proposalRelays(proposal.readRelays),
              let writes = AccountSetupInput.proposalRelays(proposal.writeRelays),
              !reads.isEmpty || !writes.isEmpty,
              selectedStep != .inboxRelays || writes.isEmpty else { return nil }
        return Array(Set(reads + writes)).sorted()
    }

    var body: some View {
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) { actions }
                    .disabled(model.isBusy || !model.isConnected)
                    .safeAreaPadding(.horizontal)
                    .safeAreaPadding(.bottom)
                    .background(.background)
            }
            .sheet(item: $editor) { editor in
                NavigationStack {
                    switch editor {
                    case .profile:
                        IdentityProfileSetupView(showsCloseButton: true, accountSetup: model)
                    case .discovery:
                        AccountSetupDiscoverySheet(model: model, step: selectedStep)
                    }
                }
                .appAppearance()
            }
            .onChange(of: model.snapshot.revision) {
                if let step, step.status == .passed || step.status == .skipped { dismiss() }
            }
        }
    }

    private var title: String {
        if selectedStep == .profile {
            return step?.status == .retryableFailure
                ? L10n.string("Couldn’t load your profile") : L10n.string("Your profile")
        }
        return AccountSetupPresentation.title(selectedStep)
    }

    @ViewBuilder private var explanation: some View {
        if proposal != nil, step?.actions.contains(.approveRepair) != true,
           step?.actions.contains(.cancelRepair) != true {
            Text("Your previous update hasn’t finished. Try again to finish publishing it.")
        } else {
            switch selectedStep {
            case .profile:
                Text(step?.status == .retryableFailure
                     ? "Try again to load your profile, or continue without changing it."
                     : "A name and photo help people recognize you. You can also do this later.")
            case .relays, .inboxRelays:
                if step?.actions.contains(.useRecommendedRelays) == true || proposal != nil {
                    Text("Relays let your profile publish information, receive chat invitations, and deliver messages.")
                    if let relays {
                        ForEach(relays, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                        Text("Continuing publishes these addresses to your public profile.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("A relay address is invalid. Go back and check the settings.").foregroundStyle(.orange)
                    }
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
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let step {
            if proposal != nil, !step.actions.contains(.approveRepair), !step.actions.contains(.cancelRepair) {
                if step.actions.contains(.retry) { action("Try again", .retry(selectedStep)) }
            } else if selectedStep == .profile {
                if step.actions.contains(.editProfile) || step.actions.contains(.approveRepair) {
                    WNButton(title: "Edit Profile") { editor = .profile }
                } else if step.actions.contains(.retry) { action("Try again", .retry(.profile)) }
                if step.actions.contains(.continueWithout) { action("Not Now", .skip(.profile), secondary: true) }
            } else if selectedStep == .relays || selectedStep == .inboxRelays {
                if let proposal, step.actions.contains(.approveRepair) {
                    action("Use These Relays", .approve(proposal.revision)).disabled(relays == nil)
                } else if step.actions.contains(.useRecommendedRelays) {
                    action("Use Default Relays", .useDefaults(selectedStep))
                } else if step.actions.contains(.retry) { action("Try again", .retry(selectedStep)) }
                if step.actions.contains(.editDiscoveryRelays) {
                    WNButton(title: "Look on Another Relay", emphasis: .secondary) { editor = .discovery }
                }
            } else if step.actions.contains(.continueAnyway) {
                action(LocalizedStringKey(AccountSetupPresentation.deviceAction(model.snapshot.singleDeviceNotice?.discovery)),
                       .acknowledge(model.snapshot.revision))
            } else if step.actions.contains(.retry) { action("Try again", .retry(selectedStep)) }
            if step.actions.contains(.cancelRepair) { action("Back", .cancelRepair, secondary: true) }
            if selectedStep == .follows, step.actions.contains(.continueWithout) { action("Continue", .skip(.follows)) }
        }
    }

    private func action(_ title: LocalizedStringKey, _ command: AccountSetupCommand, secondary: Bool = false) -> some View {
        WNButton(title: title, emphasis: secondary ? .secondary : .primary) { model.send(command) }
    }
}

private enum SetupEditor: String, Identifiable {
    case profile, discovery
    var id: String { rawValue }
}

private struct AccountSetupDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    let step: OnboardingStepFfi
    @State private var relay = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("wss://relay.example.com", text: $relay)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Relay URL")
            } footer: {
                Text("Choose a relay you’ve used with this profile. We’ll look there for your existing settings without publishing anything.")
            }
            if let error { Text(error).foregroundStyle(.orange) }
        }
        .navigationTitle("Find Your Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
            }
        }
        .safeAreaInset(edge: .bottom) {
            WNButton(title: "Look for My Settings", isLoading: model.isBusy) {
                guard let values = AccountSetupInput.relays(relay), values.count == 1 else {
                    error = L10n.string("Enter a valid relay URL, like wss://relay.example.com.")
                    return
                }
                guard let operation = model.send(.discovery(values)) else { return }
                error = nil
                Task {
                    await operation.value
                    if model.errorMessage == nil,
                       model.snapshot.steps.first(where: { $0.step == step })?.status != .retryableFailure {
                        dismiss()
                    } else {
                        error = model.errorMessage ?? L10n.string("Couldn’t find your settings. Try another relay.")
                    }
                }
            }
            .disabled(model.isBusy || !model.isConnected)
            .safeAreaPadding()
            .background(.background)
        }
    }
}
