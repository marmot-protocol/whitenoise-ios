import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct AccountDevicesActivationOutcomeTests {

    @Test(arguments: [AccountDevicesActivationFfi.eligible, .notAdmin, .alreadyEnabled, .legacyGroup])
    func publishedCommitIsConfirmed(activation: AccountDevicesActivationFfi) {
        #expect(AccountDevicesActivationOutcome(disposition: .published, activation: activation) == .confirmed)
        #expect(AccountDevicesActivationOutcome(disposition: .published, activation: nil) == .confirmed)
    }

    @Test(arguments: [SendAcceptDispositionFfi.acceptedPending, .completionUnknown])
    func unconfirmedCommitStaysPendingWhileGroupIsStillEligible(disposition: SendAcceptDispositionFfi) {
        #expect(AccountDevicesActivationOutcome(disposition: disposition, activation: .eligible) == .pending)
        #expect(AccountDevicesActivationOutcome(disposition: disposition, activation: nil) == .pending)
        #expect(AccountDevicesActivationOutcome(disposition: disposition, activation: .notAdmin) == .pending)
    }

    @Test(arguments: [SendAcceptDispositionFfi.acceptedPending, .completionUnknown])
    func unconfirmedCommitIsConfirmedOnceGroupReportsItEnabled(disposition: SendAcceptDispositionFfi) {
        #expect(AccountDevicesActivationOutcome(disposition: disposition, activation: .alreadyEnabled) == .confirmed)
    }
}
