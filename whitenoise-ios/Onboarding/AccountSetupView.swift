import SwiftUI
import MarmotKit

struct AccountSetupView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: AccountSetupModel
    let isOpeningChats: Bool
    let onClose: () -> Void
    let onOpenChats: () -> Void
    @State private var decision: SetupDecision?
    @State private var failedCloseError: String?

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
                    Task { await close() }
                }
                .disabled(isOpeningChats || appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.errorMessage != nil || model.isDurablyReady || isOpeningChats || reviewStep != nil {
                bottomAction
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
        .onChange(of: model.errorMessage) {
            if model.errorMessage != failedCloseError { failedCloseError = nil }
        }
        .sheet(item: $decision) { decision in
            AccountSetupActions(model: model, selectedStep: decision.step)
                .appAppearance()
        }
    }

    private var reviewStep: OnboardingStepFfi? {
        AccountSetupPresentation.stepToReview(model.snapshot, isBusy: model.isBusy, isConnected: model.isConnected)
    }

    private var closeFailed: Bool {
        failedCloseError != nil && model.errorMessage == failedCloseError
    }

    private func close() async {
        if await appState.cancelAccountSetup() {
            onClose()
        } else {
            failedCloseError = model.errorMessage
        }
    }

    @ViewBuilder private var bottomAction: some View {
        if model.errorMessage != nil {
            WNOnboardingButton(title: "Try Again") {
                Task {
                    if closeFailed { await close() } else { await appState.connectAccountSetup() }
                }
            }
            .disabled(!appState.canUseRuntimeForLocalForegroundWork || model.isBusy || appState.isFinishingAccountSetup)
        } else if model.isDurablyReady || isOpeningChats {
            WNOnboardingButton(title: "Open Chats", isLoading: isOpeningChats, action: onOpenChats)
                .disabled(isOpeningChats || !model.canFinish || appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
        } else if let step = reviewStep {
            WNOnboardingButton(title: "Review and Continue") {
                decision = SetupDecision(step: step)
            }
            .disabled(appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
        }
    }

    private var header: some View {
        let content = AccountSetupPresentation.header(
            model.snapshot, reviewStep: reviewStep, errorMessage: model.errorMessage,
            isOpeningChats: isOpeningChats, closeFailed: closeFailed
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(content.title)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: content.subtitle)
                .foregroundStyle(.secondary)
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
        case .pending, .checking, .skipped: .secondary
        }
    }
}

private struct SetupDecision: Identifiable {
    let step: OnboardingStepFfi
    var id: OnboardingStepFfi { step }
}
