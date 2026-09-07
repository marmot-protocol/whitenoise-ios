import SwiftUI
import MarmotKit

struct AccountSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: AccountSetupModel
    @State private var editor: SetupEditor?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.snapshot.ready ? L10n.string("You’re ready") : L10n.string("Getting you ready"))
                        .font(.largeTitle.bold())
                    Text("Checking your account before you start chatting.")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 20) {
                    ForEach(model.snapshot.steps, id: \.step) { step in
                        stepRow(step)
                        if step.step == (model.snapshot.proposal?.step ?? model.currentStep?.step) {
                            AccountSetupActions(model: model,
                                                editProfile: { editor = .profile },
                                                chooseDiscovery: { editor = .discovery })
                        }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
                    Button("Reconnect") { Task { await appState.connectAccountSetup() } }
                        .disabled(!appState.canUseRuntimeForLocalForegroundWork || model.isBusy)
                } else if !model.isConnected && !model.snapshot.ready {
                    ProgressView("Connecting to account setup…")
                }
                if model.snapshot.cancellationPending {
                    Text("Finishing cancellation. Your saved identity and completed changes will be kept.")
                        .foregroundStyle(.secondary)
                }
                if model.snapshot.ready || model.cancelled {
                    WNButton(title: model.cancelled ? "Done" : "Open Chats") {
                        Task { await appState.finishAccountSetup() }
                    }
                    .disabled(
                        !model.canFinish || appState.isFinishingAccountSetup
                            || !appState.canUseRuntimeForLocalForegroundWork
                    )
                }
            }
            .padding(24)
        }
        .background(.background)
        .navigationTitle("Account setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.offeredActions.contains(.cancelOnboarding), !model.cancelled {
                    Button("Cancel") { model.send(.cancel) }
                        .disabled(model.isBusy || !model.isConnected)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Later") {
                    model.suspend()
                    appState.isAccountSetupPresented = false
                }
                .disabled(model.isBusy || model.snapshot.cancellationPending)
            }
        }
        .onChange(of: model.cancelled) {
            if model.cancelled { Task { await appState.finishAccountSetup() } }
        }
        .sheet(item: $editor) { editor in
            NavigationStack {
                switch editor {
                case .profile:
                    IdentityProfileSetupView(showsCloseButton: true, accountSetup: model)
                case .discovery:
                    AccountSetupDiscoverySheet(model: model)
                }
            }
            .appAppearance()
        }
    }

    private func stepRow(_ step: OnboardingStepStateFfi) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if step.status == .checking {
                    ProgressView()
                } else {
                    Image(systemName: AccountSetupPresentation.symbol(step.status))
                        .foregroundStyle(statusColor(step.status))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .font(.title3)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AccountSetupPresentation.title(step.step)).font(.headline)
                Text(AccountSetupPresentation.status(step.status)).foregroundStyle(.secondary)
                if !step.findings.isEmpty && step.step != .singleDevice {
                    ForEach(Array(step.findings.enumerated()), id: \.offset) { _, finding in
                        Text(AccountSetupPresentation.issue(finding.issue))
                            .font(.footnote).foregroundStyle(.secondary)
                        if let endpoint = finding.endpoint,
                           let normalized = RelayURL.normalized(endpoint) {
                            Text(normalized).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: step.status)
        .accessibilityElement(children: .combine)
    }

    private func statusColor(_ status: OnboardingStatusFfi) -> Color {
        switch status {
        case .passed: .green
        case .needsInput, .retryableFailure: .orange
        default: .secondary
        }
    }

}

private enum SetupEditor: String, Identifiable {
    case profile, discovery
    var id: String { rawValue }
}

private struct AccountSetupDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    @State private var relay = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("wss://relay.example.com", text: $relay)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Relay URL")
            } header: {
                Text("Relay URL")
            } footer: {
                Text("Choose a relay you’ve used with this account. We’ll look there for your existing settings without publishing anything.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Find your settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .safeAreaInset(edge: .bottom) {
            WNButton(title: "Look for my settings") {
                guard let values = AccountSetupInput.relays(relay), values.count == 1 else {
                    error = L10n.string("Enter a valid relay URL, like wss://relay.example.com.")
                    return
                }
                guard model.send(.discovery(values)) != nil else { return }
                dismiss()
            }
            .disabled(model.isBusy || !model.isConnected)
            .padding()
            .background(.background)
        }
    }
}
