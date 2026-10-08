import MarmotKit
import SwiftUI

struct AccountSetupDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    @State private var isDismissing = false
    @State private var presentation: AccountSetupRecoveryPresentation
    @State private var activeAction: Action?

    private enum Action { case acknowledge, retry }

    init(model: AccountSetupModel) {
        self.model = model
        _presentation = State(initialValue: AccountSetupRecoveryPresentation(snapshot: model.snapshot))
    }

    private var step: OnboardingStepStateFfi? {
        presentation.snapshot.steps.first { $0.step == .singleDevice }
    }
    private var isBusy: Bool { model.isBusy || activeAction != nil || isDismissing }

    var body: some View {
        let failures = failureMessages
        let hasFailure = !failures.isEmpty
        let notice = presentation.snapshot.singleDeviceNotice
        let showsNotice = notice != nil && (!hasFailure || step?.actions.contains(.continueAnyway) == true)

        NavigationStack {
            AccountSetupRecoveryLayout(title: AccountSetupPresentation.title(.singleDevice), isBusy: isBusy) {
                Section {
                    AccountSetupRecoveryCallout(
                        title: hasFailure ? failureTitle : "Using one device",
                        symbol: hasFailure ? "exclamationmark.circle" : "iphone", isError: hasFailure,
                        isLoading: model.isBusy && activeAction == nil && !isDismissing
                    ) {
                        ForEach(failures, id: \.self) { message in
                            Text(verbatim: message)
                        }
                        if showsNotice, let notice {
                            Text(AccountSetupPresentation.deviceNotice(notice.discovery))
                        }
                        if hasFailure || showsNotice { Divider() }
                        Text("White Noise does not yet sync conversations across devices. We recommend using this profile on one device.")
                    }
                }
            } actions: {
                if let step {
                    if step.actions.contains(.continueAnyway) {
                        // Keep the consent label when the action acknowledges this device.
                        WNOnboardingButton(
                            title: LocalizedStringKey(AccountSetupPresentation.deviceAction(presentation.snapshot.singleDeviceNotice?.discovery)),
                            isLoading: isBusy && activeAction == .acknowledge
                        ) { perform(.acknowledge) }
                        .disabled(isBusy || !model.isConnected)
                    } else if step.actions.contains(.retry) {
                        WNOnboardingButton(title: "Try Again", isLoading: isBusy && activeAction == .retry) { perform(.retry) }
                            .disabled(isBusy || !model.isConnected)
                    }
                }
            }
        }
        .onAppear { updatePresentation() }
        .onChange(of: model.isConnected) { updatePresentation() }
        .onChange(of: model.snapshot) { updatePresentation() }
        .onChange(of: model.isBusy) { updatePresentation() }
    }

    private var failureTitle: LocalizedStringKey {
        step?.status == .retryableFailure
            ? "Couldn’t check for other devices" : "Couldn’t continue signing in"
    }

    private var failureMessages: [String] {
        guard !isBusy else { return [] }
        if let error = model.errorMessage { return [error] }
        guard let step, step.status == .retryableFailure else { return [] }
        let messages = AccountSetupPresentation.findingMessages(step.findings)
        return messages.isEmpty ? [L10n.string("Couldn’t finish this step. Try again.")] : messages
    }

    private func perform(_ action: Action) {
        guard !isBusy else { return }
        let command: AccountSetupCommand = action == .acknowledge
            ? .acknowledge(presentation.snapshot.revision, recoveryEpoch: presentation.snapshot.recoveryEpoch)
            : .retry(.singleDevice)
        guard let operation = model.send(command) else { return }
        activeAction = action
        Task {
            await operation.value
            activeAction = nil
            updatePresentation()
        }
    }

    private func updatePresentation() {
        guard !isBusy, model.isConnected else { return }
        if presentation.update(model.snapshot, step: .singleDevice, operationError: model.errorMessage) {
            isDismissing = true
            dismiss()
        }
    }
}
