import MarmotKit
import Testing
@testable import whitenoise_ios

struct AccountSetupRecoveryPresentationTests {
    @Test(arguments: [OnboardingStatusFfi.passed, .skipped], [OnboardingStepFfi.relays, .singleDevice, .keyPackage])
    func completionKeepsReviewedContentUntilDismissal(_ status: OnboardingStatusFfi, step: OnboardingStepFfi) {
        let reviewed = snapshot(status: .needsInput, revision: 1, step: step)
        var presentation = AccountSetupRecoveryPresentation(snapshot: reviewed)
        let shouldDismiss = presentation.update(snapshot(status: status, revision: 2, step: step), step: step)
        #expect(shouldDismiss)
        #expect(presentation.snapshot == reviewed)
    }

    @Test func failedRetryUpdatesTheVisibleRecoveryOptions() {
        var presentation = AccountSetupRecoveryPresentation(snapshot: snapshot(status: .needsInput, revision: 1))
        let failed = snapshot(status: .retryableFailure, revision: 2)
        let shouldDismiss = presentation.update(failed, step: .relays)
        #expect(!shouldDismiss)
        #expect(presentation.snapshot == failed)
    }

    @Test func anotherCompletedStepDoesNotDismissThisReview() {
        var presentation = AccountSetupRecoveryPresentation(snapshot: snapshot(status: .needsInput, revision: 1))
        let updated = snapshot(status: .passed, revision: 2)
        let shouldDismiss = presentation.update(updated, step: .inboxRelays)
        #expect(!shouldDismiss)
        #expect(presentation.snapshot == updated)
    }

    @Test(arguments: [false, true], [AccountSetupFailure.discovery, .settingsChanged])
    func childFailureSurvivesItsSnapshotRegardlessOfCallbackOrder(_ reportBeforeUpdate: Bool, failure: AccountSetupFailure) {
        var presentation = AccountSetupRecoveryPresentation(snapshot: snapshot(status: .needsInput, revision: 1))
        let failed = snapshot(status: .retryableFailure, revision: 2)
        if reportBeforeUpdate {
            presentation.reportChildFailure(source: .discovery, failure: failure, revision: 2)
        }
        let shouldDismiss = presentation.update(failed, step: .relays)
        if !reportBeforeUpdate {
            presentation.reportChildFailure(source: .discovery, failure: failure, revision: 2)
        }
        #expect(!shouldDismiss)
        #expect(presentation.snapshot == failed)
        #expect(presentation.childFailure?.source == .discovery)
        #expect(presentation.childFailure?.failure == failure)
    }

    @Test func newerSuccessfulCheckClearsAnEarlierChildFailure() {
        var presentation = AccountSetupRecoveryPresentation(snapshot: snapshot(status: .retryableFailure, revision: 2))
        presentation.reportChildFailure(source: .relays, failure: .operation, revision: 2)
        let failedUpdate = snapshot(status: .retryableFailure, revision: 3)
        _ = presentation.update(failedUpdate, step: .relays, operationFailure: .operation)
        #expect(presentation.childFailure != nil)
        let refreshed = snapshot(status: .needsInput, revision: 4)
        _ = presentation.update(refreshed, step: .relays)
        #expect(presentation.childFailure == nil)
        #expect(presentation.snapshot == refreshed)
    }

    private func snapshot(status: OnboardingStatusFfi, revision: UInt64, step: OnboardingStepFfi = .relays) -> OnboardingSnapshotFfi {
        let actions: [OnboardingActionFfi]
        switch status {
        case .needsInput:
            switch step {
            case .singleDevice: actions = [.continueAnyway]
            case .keyPackage: actions = [.retry]
            default: actions = [.editRelays]
            }
        case .retryableFailure: actions = [.retry]
        default: actions = []
        }
        return OnboardingSnapshotFfi(
            accountIdHex: String(repeating: "a", count: 64), recoveryEpoch: "review", revision: revision, ready: false,
            steps: [
                .init(step: step, status: status, findings: [], actions: actions, checkedAt: nil),
                .init(step: .inboxRelays, status: .needsInput, findings: [], actions: [.editRelays], checkedAt: nil)
            ],
            proposal: nil, singleDeviceNotice: nil, cancellationPending: false
        )
    }
}
