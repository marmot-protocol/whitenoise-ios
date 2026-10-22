import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct AccountSetupCheckPresentationTests {
    @Test func deviceConsentTakesPriorityOverRetryAndUsesTheDisplayedRevision() throws {
        let presentation = AccountSetupCheckPresentation(
            check: .device, snapshot: snapshot(deviceActions: [.retry, .continueAnyway])
        )
        #expect(presentation.primaryAction == .acknowledge)
        let command = presentation.command(for: try #require(presentation.primaryAction))
        guard case .acknowledge(let revision, let recoveryEpoch) = command else {
            Issue.record("Device consent must acknowledge the displayed check")
            return
        }
        #expect(revision == 7)
        #expect(recoveryEpoch == "reviewed-device-check")
    }

    @Test func retryTargetsTheSelectedCheckWithoutAcknowledgingTheDevice() throws {
        let reviewed = snapshot(deviceActions: [.retry], messagingActions: [.retry])
        for check in [AccountSetupCheckPresentation.Check.device, .secureMessaging] {
            let presentation = AccountSetupCheckPresentation(check: check, snapshot: reviewed)
            let command = presentation.command(for: try #require(presentation.primaryAction))
            guard case .retry(let step) = command else {
                Issue.record("Retry must not acknowledge device consent")
                return
            }
            #expect(step == (check == .device ? .singleDevice : .keyPackage))
        }
        let messaging = AccountSetupCheckPresentation(
            check: .secureMessaging, snapshot: snapshot(deviceActions: [.continueAnyway])
        )
        #expect(messaging.primaryAction == nil)
    }

    @Test func busyChecksHideErrorsAndConnectionFailureTakesPrecedence() {
        let presentation = AccountSetupCheckPresentation(
            check: .device, snapshot: snapshot(status: .retryableFailure, findings: [.init(issue: .unreachable, endpoint: nil)])
        )
        #expect(presentation.failureMessages(isBusy: true, hasConnectionFailure: true, operationFailure: .settingsChanged).isEmpty)
        #expect(presentation.failureMessages(isBusy: false, hasConnectionFailure: true, operationFailure: .settingsChanged) == [
            L10n.string("Setup updates stopped. Close this sheet, then tap Try Again on Sign In to reconnect.")
        ])
        #expect(presentation.failureMessages(isBusy: false, hasConnectionFailure: false, operationFailure: .settingsChanged) == [
            AccountSetupFailure.settingsChanged.message
        ])
    }

    @Test func waitingForSignerShowsFindingsOnlyForSecureMessaging() {
        let reviewed = snapshot(status: .waitingForSigner, findings: [.init(issue: .unreachable, endpoint: nil)])
        let device = AccountSetupCheckPresentation(check: .device, snapshot: reviewed)
        let messaging = AccountSetupCheckPresentation(check: .secureMessaging, snapshot: reviewed)
        #expect(device.failureMessages(isBusy: false, hasConnectionFailure: false, operationFailure: nil).isEmpty)
        #expect(messaging.failureMessages(isBusy: false, hasConnectionFailure: false, operationFailure: nil) == [
            AccountSetupPresentation.issue(.unreachable)
        ])
    }

    @Test func retryableFailureWithoutFindingsStillExplainsTheFailure() {
        let reviewed = snapshot(status: .retryableFailure)
        for check in [AccountSetupCheckPresentation.Check.device, .secureMessaging] {
            let presentation = AccountSetupCheckPresentation(check: check, snapshot: reviewed)
            #expect(presentation.failureMessages(isBusy: false, hasConnectionFailure: false, operationFailure: nil) == [
                L10n.string("Couldn’t finish this step. Try again.")
            ])
        }
    }

    private func snapshot(
        status: OnboardingStatusFfi = .needsInput,
        deviceActions: [OnboardingActionFfi] = [],
        messagingActions: [OnboardingActionFfi] = [],
        findings: [OnboardingFindingFfi] = []
    ) -> OnboardingSnapshotFfi {
        OnboardingSnapshotFfi(
            accountIdHex: String(repeating: "a", count: 64), recoveryEpoch: "reviewed-device-check", revision: 7, ready: false,
            steps: [
                .init(step: .singleDevice, status: status, findings: findings, actions: deviceActions, checkedAt: nil),
                .init(step: .keyPackage, status: status, findings: findings, actions: messagingActions, checkedAt: nil)
            ],
            proposal: nil, singleDeviceNotice: nil, cancellationPending: false
        )
    }
}
