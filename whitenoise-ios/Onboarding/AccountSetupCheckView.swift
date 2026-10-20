import MarmotKit
import SwiftUI

struct AccountSetupCheckView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    let check: AccountSetupCheckPresentation.Check
    @State private var isDismissing = false
    @State private var presentation: AccountSetupRecoveryPresentation
    @State private var activeAction: AccountSetupCheckPresentation.Action?

    init(model: AccountSetupModel, check: AccountSetupCheckPresentation.Check) {
        self.model = model
        self.check = check
        _presentation = State(initialValue: AccountSetupRecoveryPresentation(snapshot: model.snapshot))
    }

    private var recovery: AccountSetupCheckPresentation {
        .init(check: check, snapshot: presentation.snapshot)
    }

    private var isBusy: Bool { model.isBusy || activeAction != nil || isDismissing }

    var body: some View {
        let failures = recovery.failureMessages(
            isBusy: isBusy, hasConnectionFailure: model.hasConnectionFailure, operationFailure: model.failure
        )
        let hasFailure = !failures.isEmpty

        NavigationStack {
            AccountSetupRecoveryLayout(title: AccountSetupPresentation.title(check.step), isBusy: isBusy) {
                Section {
                    AccountSetupRecoveryCallout(
                        title: calloutTitle(hasFailure: hasFailure),
                        symbol: hasFailure ? "exclamationmark.circle" : (check == .device ? "iphone" : "lock.shield"),
                        isError: hasFailure,
                        isLoading: model.isBusy && activeAction == nil && !isDismissing
                    ) {
                        switch check {
                        case .device: deviceExplanation(failures: failures)
                        case .secureMessaging: secureMessagingExplanation(failures: failures)
                        }
                    }
                }
            } actions: {
                if model.hasConnectionFailure && activeAction == nil {
                    WNOnboardingButton(title: "Close") { dismiss() }
                        .disabled(isBusy)
                } else if let action = recovery.primaryAction {
                    WNOnboardingButton(
                        title: action == .acknowledge
                            ? LocalizedStringKey(AccountSetupPresentation.deviceAction(presentation.snapshot.singleDeviceNotice?.discovery))
                            : "Try Again",
                        isLoading: isBusy && activeAction == action
                    ) { perform(action) }
                    .disabled(isBusy || !model.isConnected)
                }
            }
        }
        .onAppear { updatePresentation() }
        .onChange(of: model.isConnected) { updatePresentation() }
        .onChange(of: model.snapshot) { updatePresentation() }
        .onChange(of: model.isBusy) { updatePresentation() }
    }

    private func calloutTitle(hasFailure: Bool) -> LocalizedStringKey {
        switch check {
        case .device:
            guard hasFailure else { return "Using one device" }
            return recovery.step?.status == .retryableFailure
                ? "Couldn’t check for other devices" : "Couldn’t continue signing in"
        case .secureMessaging:
            return hasFailure ? "Couldn’t prepare secure messaging" : "Secure messaging"
        }
    }

    @ViewBuilder private func deviceExplanation(failures: [String]) -> some View {
        let notice = presentation.snapshot.singleDeviceNotice
        let showsNotice = notice != nil && (failures.isEmpty || recovery.primaryAction == .acknowledge)
        ForEach(failures, id: \.self) { Text(verbatim: $0) }
        if showsNotice, let notice {
            Text(AccountSetupPresentation.deviceNotice(notice.discovery))
        }
        if !failures.isEmpty || showsNotice { Divider() }
        Text("White Noise does not yet sync conversations across devices. We recommend using this profile on one device.")
    }

    @ViewBuilder private func secureMessagingExplanation(failures: [String]) -> some View {
        let showsProgress = isBusy && !isDismissing
        if showsProgress { Text("Preparing secure messaging…") }
        ForEach(failures, id: \.self) { Text(verbatim: $0) }
        if !failures.isEmpty || showsProgress { Divider() }
        Text("Secure messaging must be ready before you can open Chats.")
    }

    private func perform(_ action: AccountSetupCheckPresentation.Action) {
        guard !isBusy, let operation = model.send(recovery.command(for: action)) else { return }
        activeAction = action
        Task {
            await operation.value
            activeAction = nil
            updatePresentation()
        }
    }

    private func updatePresentation() {
        guard !isBusy, model.isConnected else { return }
        if presentation.update(model.snapshot, step: check.step, operationFailure: model.failure) {
            isDismissing = true
            dismiss()
        }
    }
}
