import MarmotKit
import SwiftUI

struct AccountSetupSecureMessagingView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    @State private var isDismissing = false
    @State private var isRetrying = false
    @State private var presentation: AccountSetupRecoveryPresentation

    init(model: AccountSetupModel) {
        self.model = model
        _presentation = State(initialValue: AccountSetupRecoveryPresentation(snapshot: model.snapshot))
    }

    private var step: OnboardingStepStateFfi? {
        presentation.snapshot.steps.first { $0.step == .keyPackage }
    }

    private var isBusy: Bool { model.isBusy || isRetrying || isDismissing }

    var body: some View {
        let failures = failureMessages
        let hasFailure = !failures.isEmpty

        NavigationStack {
            AccountSetupRecoveryLayout(title: AccountSetupPresentation.title(.keyPackage), isBusy: isBusy) {
                Section {
                    AccountSetupRecoveryCallout(
                        title: hasFailure ? "Couldn’t prepare secure messaging" : "Secure messaging",
                        symbol: hasFailure ? "exclamationmark.circle" : "lock.shield", isError: hasFailure,
                        isLoading: model.isBusy && !isRetrying && !isDismissing
                    ) {
                        if isBusy && !isDismissing {
                            Text("Preparing secure messaging…")
                        }
                        ForEach(failures, id: \.self) { message in
                            Text(verbatim: message)
                        }
                        if hasFailure || (isBusy && !isDismissing) { Divider() }
                        Text("Secure messaging must be ready before you can open Chats.")
                    }
                }
            } actions: {
                if model.hasConnectionFailure {
                    WNOnboardingButton(title: "Close") { dismiss() }
                        .disabled(isBusy)
                } else if step?.actions.contains(.retry) == true {
                    WNOnboardingButton(title: "Try Again", isLoading: isBusy && isRetrying, action: retry)
                        .disabled(isBusy || !model.isConnected)
                }
            }
        }
        .onAppear { updatePresentation() }
        .onChange(of: model.isConnected) { updatePresentation() }
        .onChange(of: model.snapshot) { updatePresentation() }
        .onChange(of: model.isBusy) { updatePresentation() }
    }

    private var failureMessages: [String] {
        guard !isBusy else { return [] }
        if model.hasConnectionFailure {
            return [L10n.string("Setup updates stopped. Close this sheet, then tap Try Again on Sign In to reconnect.")]
        }
        if let error = model.errorMessage { return [error] }
        guard let step, step.status == .retryableFailure || step.status == .waitingForSigner else { return [] }
        let messages = AccountSetupPresentation.findingMessages(step.findings)
        return messages.isEmpty ? [L10n.string("Couldn’t finish this step. Try again.")] : messages
    }

    private func retry() {
        guard !isBusy else { return }
        guard let operation = model.send(.retry(.keyPackage)) else { return }
        isRetrying = true
        Task {
            await operation.value
            isRetrying = false
            updatePresentation()
        }
    }

    private func updatePresentation() {
        guard !isBusy, model.isConnected else { return }
        if presentation.update(model.snapshot, step: .keyPackage, operationError: model.errorMessage) {
            isDismissing = true
            dismiss()
        }
    }
}
