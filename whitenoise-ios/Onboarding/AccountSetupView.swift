import SwiftUI
import MarmotKit

struct AccountSetupView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: AccountSetupModel
    let onClose: () -> Void
    @State private var decision: SetupDecision?

    var body: some View {
        List {
            Section {
                ForEach(model.snapshot.steps, id: \.step) { step in
                    if Self.needsAttention(step.status) {
                        Button {
                            decision = SetupDecision(step: step.step)
                        } label: {
                            stepRow(step)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Show options for this check")
                    } else {
                        stepRow(step)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.snapshot.ready ? "You’re ready" : "Getting you ready")
                        .font(.title.bold()).foregroundStyle(Color.primary)
                    if !model.snapshot.ready {
                        Text("Checking your profile before you start chatting.")
                            .font(.body)
                    }
                }
                .textCase(nil)
                .padding(.bottom)
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.orange)
                    Button("Reconnect") { Task { await appState.connectAccountSetup() } }
                        .disabled(!appState.canUseRuntimeForLocalForegroundWork || model.isBusy)
                }
            }
        }
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    Task { if await appState.cancelAccountSetup() { onClose() } }
                } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close")
                .disabled(appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
            }
        }
        .safeAreaInset(edge: .bottom) {
            WNButton(title: "Open Chats") {
                Task { await appState.finishAccountSetup() }
            }
            .disabled(!model.canFinish || appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.bottom)
            .background(.background)
        }
        .interactiveDismissDisabled()
        .task(id: "\(appState.runtimeGeneration):\(appState.canUseRuntimeForLocalForegroundWork)") {
            if appState.canUseRuntimeForLocalForegroundWork { await appState.connectAccountSetup() }
        }
        .onDisappear { model.suspend() }
        .sheet(item: $decision) { decision in
            AccountSetupActions(model: model, selectedStep: decision.step)
                .appAppearance()
        }
    }

    static func needsAttention(_ status: OnboardingStatusFfi) -> Bool {
        status == .needsInput || status == .retryableFailure || status == .waitingForSigner
    }

    private func stepRow(_ step: OnboardingStepStateFfi) -> some View {
        HStack(spacing: 12) {
            Group {
                if step.step == model.snapshot.steps.first(where: { $0.status == .checking })?.step && !model.snapshot.ready {
                    ProgressView()
                } else {
                    Image(systemName: AccountSetupPresentation.symbol(step.status))
                        .foregroundStyle(step.status == .passed ? .green : Self.needsAttention(step.status) ? .orange : .secondary)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AccountSetupPresentation.title(step.step)).foregroundStyle(Color.primary)
                Text(AccountSetupPresentation.status(step.status)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if Self.needsAttention(step.status) {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct SetupDecision: Identifiable {
    let step: OnboardingStepFfi
    var id: OnboardingStepFfi { step }
}
