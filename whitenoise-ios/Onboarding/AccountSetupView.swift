import SwiftUI
import MarmotKit

struct AccountSetupView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: AccountSetupModel
    let onClose: () -> Void
    @State private var decision: SetupDecision?
    @State private var isOpeningChats = false

    var body: some View {
        List {
            Section {
                ForEach(model.snapshot.steps, id: \.step) { step in
                    let state = AccountSetupPresentation.checkState(step)
                    Group {
                        if state.needsAttention {
                            Button {
                                decision = SetupDecision(step: step.step)
                            } label: {
                                stepRow(step, state: state)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Show options for this check")
                        } else {
                            stepRow(step, state: state)
                        }
                    }
                }
            } header: {
                header
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.bottom, 12)
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WNIconButton(title: "Close", systemImage: "xmark", chrome: .container) {
                    Task { if await appState.cancelAccountSetup() { onClose() } }
                }
                .disabled(appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.errorMessage != nil {
                WNOnboardingButton(title: "Try Again") {
                    Task { await appState.connectAccountSetup() }
                }
                .disabled(!appState.canUseRuntimeForLocalForegroundWork || model.isBusy)
                .safeAreaPadding(.horizontal, 16)
                .safeAreaPadding(.bottom)
                .background(Color(uiColor: .systemGroupedBackground))
            } else if model.isDurablyReady || isOpeningChats {
                WNOnboardingButton(title: "Open Chats", isLoading: isOpeningChats) {
                    guard !isOpeningChats else { return }
                    isOpeningChats = true
                    Task {
                        defer { isOpeningChats = false }
                        await appState.finishAccountSetup()
                    }
                }
                .accessibilityValue(isOpeningChats ? "In progress" : "")
                .disabled(!model.canFinish || appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
                .safeAreaPadding(.horizontal, 16)
                .safeAreaPadding(.bottom)
                .background(Color(uiColor: .systemGroupedBackground))
            } else if model.isConnected,
                      let step = AccountSetupPresentation.stepToReview(model.snapshot, isBusy: model.isBusy) {
                WNOnboardingButton(title: "Review and Continue") {
                    decision = SetupDecision(step: step)
                }
                .disabled(appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
                .safeAreaPadding(.horizontal, 16)
                .safeAreaPadding(.bottom)
                .background(Color(uiColor: .systemGroupedBackground))
            }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AccountSetupPresentation.heading(model.snapshot, isBusy: model.isBusy, hasError: model.errorMessage != nil))
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            if model.errorMessage != nil {
                Text("Please try again.")
                    .foregroundStyle(.secondary)
            } else if isOpeningChats {
                Text("Opening your chats…")
                    .foregroundStyle(.secondary)
            } else if model.isDurablyReady {
                Text("Open Chats to start messaging.")
                    .foregroundStyle(.secondary)
            } else {
                if !model.isBusy, model.snapshot.steps.contains(where: { AccountSetupPresentation.checkState($0).needsAttention }) {
                    Text("Review the item below to continue.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("We’re checking your profile and connection.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stepRow(_ step: OnboardingStepStateFfi, state: AccountSetupPresentation.CheckState) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AccountSetupPresentation.title(step.step)).foregroundStyle(.primary)
                    Text(state.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Group {
                    if state == .checking {
                        ProgressView()
                    } else {
                        Image(systemName: state.symbol)
                            .foregroundStyle(iconColor(state))
                    }
                }
                .accessibilityHidden(true)
            }
            .labelStyle(.titleAndIcon)
            Spacer(minLength: 0)
            if state.needsAttention {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func iconColor(_ state: AccountSetupPresentation.CheckState) -> Color {
        switch state {
        case .passed: .green
        case .optionalReview, .acknowledgment: .orange
        case .requiredFix: .red
        default: .secondary
        }
    }
}

private struct SetupDecision: Identifiable {
    let step: OnboardingStepFfi
    var id: OnboardingStepFfi { step }
}
