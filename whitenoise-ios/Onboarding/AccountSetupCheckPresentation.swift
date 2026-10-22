import Foundation
import MarmotKit

nonisolated struct AccountSetupCheckPresentation {
    enum Check {
        case device, secureMessaging

        var step: OnboardingStepFfi {
            switch self {
            case .device: .singleDevice
            case .secureMessaging: .keyPackage
            }
        }
    }

    enum Action { case acknowledge, retry }

    let check: Check
    let snapshot: OnboardingSnapshotFfi

    var step: OnboardingStepStateFfi? {
        snapshot.steps.first { $0.step == check.step }
    }

    var primaryAction: Action? {
        if check == .device, step?.actions.contains(.continueAnyway) == true { return .acknowledge }
        return step?.actions.contains(.retry) == true ? .retry : nil
    }

    func command(for action: Action) -> AccountSetupCommand {
        switch action {
        case .acknowledge:
            // Consent belongs to the snapshot displayed in the sheet.
            .acknowledge(snapshot.revision, recoveryEpoch: snapshot.recoveryEpoch)
        case .retry: .retry(check.step)
        }
    }

    func failureMessages(isBusy: Bool, hasConnectionFailure: Bool, operationFailure: AccountSetupFailure?) -> [String] {
        guard !isBusy else { return [] }
        if hasConnectionFailure {
            return [L10n.string("Setup updates stopped. Close this sheet, then tap Try Again on Sign In to reconnect.")]
        }
        if let operationFailure { return [operationFailure.message] }
        guard let step,
              step.status == .retryableFailure || (check == .secureMessaging && step.status == .waitingForSigner)
        else { return [] }
        let messages = AccountSetupPresentation.findingMessages(step.findings)
        return messages.isEmpty ? [L10n.string("Couldn’t finish this step. Try again.")] : messages
    }
}
