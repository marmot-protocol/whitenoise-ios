import SwiftUI
import MarmotKit

struct AccountSetupView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: AccountSetupModel
    let isOpeningChats: Bool
    let onClose: () -> Void
    let onOpenChats: () -> Void
    @State private var decision: SetupDecision?
    @State private var autoOpenedProfileAttempt: ObjectIdentifier?

    var body: some View {
        List {
            Section {
                ForEach(AccountSetupPresentation.visibleSteps(
                    model.snapshot.steps,
                    acknowledgesSingleDevice: model.acknowledgesSingleDevice,
                    reviewStep: reviewStep
                ), id: \.step) { step in
                    let state = AccountSetupPresentation.checkState(step)
                    Group {
                        if state.needsAttention, reviewStep == step.step {
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
        .modifier(WNOnboardingActionBar(
            isPresented: model.errorMessage != nil || (!model.cancelled && (model.isDurablyReady || isOpeningChats || reviewStep != nil))
                || needsCheckAgain
        ) {
            bottomAction
                .safeAreaPadding(.horizontal, 16)
                .safeAreaPadding(.bottom)
        })
        .interactiveDismissDisabled()
        .task(id: "\(appState.runtimeGeneration):\(appState.canUseRuntimeForLocalForegroundWork)") {
            if appState.canUseRuntimeForLocalForegroundWork { await appState.connectAccountSetup() }
        }
        .onDisappear { model.suspend() }
        // Whichever sheet is open, a stalled run continues from Check Again here, not from that sheet.
        .onChange(of: needsCheckAgain) { if needsCheckAgain { decision = nil } }
        .onChange(of: shouldAutoOpenProfile, initial: true) {
            guard shouldAutoOpenProfile else { return }
            autoOpenedProfileAttempt = ObjectIdentifier(model)
            decision = SetupDecision(step: .profile)
        }
        .sheet(item: $decision) { decision in
            AccountSetupActions(model: model, selectedStep: decision.step) {
                self.decision = nil
                Task { await close() }
            }
                .appAppearance()
        }
    }

    private var reviewStep: OnboardingStepFfi? {
        guard !model.cancelled else { return nil }
        return AccountSetupPresentation.stepToReview(model.snapshot, isBusy: model.isBusy, isConnected: model.isConnected)
    }

    private var shouldAutoOpenProfile: Bool {
        guard !model.cancelled, decision == nil, autoOpenedProfileAttempt != ObjectIdentifier(model),
              !appState.isFinishingAccountSetup, appState.canUseRuntimeForLocalForegroundWork else { return false }
        return AccountSetupPresentation.opensProfileAutomatically(
            model.snapshot, isBusy: model.isBusy, isConnected: model.isConnected
        )
    }

    private var needsCheckAgain: Bool {
        AccountSetupWayForward.needsCheckAgain(
            model.snapshot, isBusy: model.isBusy, isConnected: model.isConnected,
            hasFailure: model.failure != nil, isCancelled: model.cancelled
        )
    }

    private var closeFailed: Bool {
        model.failure == .closeSignIn
    }

    private func close() async {
        if await appState.cancelAccountSetup() {
            onClose()
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
        } else if needsCheckAgain {
            WNOnboardingButton(title: "Check Again") { model.send(.run) }
                .disabled(appState.isFinishingAccountSetup || !appState.canUseRuntimeForLocalForegroundWork)
        }
    }

    private var header: some View {
        let content = needsCheckAgain ? AccountSetupWayForward.checkAgainHeader : AccountSetupPresentation.header(
            model.snapshot, reviewStep: reviewStep, errorMessage: model.errorMessage,
            isOpeningChats: isOpeningChats, closeFailed: closeFailed, isCancelled: model.cancelled
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
                    if state == .checking, !needsCheckAgain {
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
            if state.needsAttention, reviewStep == step.step {
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
