import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct OnboardingRecoveryPresentationTests {
    @Test func signedOutProfilesRemainVisibleWithoutSessionState() {
        let account = profile("reset")
        #expect(ready([account]) == [account])
    }

    @Test func latestAccountStateOverridesAConfirmedReset() {
        let reset = profile("reset")
        let signedIn = profile("reset", signedOut: false)
        #expect(ready([signedIn], recovered: [reset]).isEmpty)
        #expect(ready([reset], recovered: [reset]) == [reset])
    }

    @Test func failedRefreshDoesNotHideAConfirmedReset() {
        let reset = profile("reset")
        #expect(ready([], recovered: [reset]) == [reset])
    }

    @Test func brokenUnfinishedAndExternalProfilesAreNotOfferedAsReady() {
        let accounts = [profile("broken"), profile("unfinished"), profile("external", localSigning: false)]
        #expect(OnboardingRecoveryPresentation.readyProfiles(
            accounts: accounts,
            recoveredInSession: [],
            recoveryIDs: ["broken"],
            unfinishedIDs: ["unfinished"]
        ).isEmpty)
    }

    private func ready(_ accounts: [AccountSummaryFfi], recovered: [AccountSummaryFfi] = []) -> [AccountSummaryFfi] {
        OnboardingRecoveryPresentation.readyProfiles(
            accounts: accounts, recoveredInSession: recovered, recoveryIDs: [], unfinishedIDs: []
        )
    }

    private func profile(_ id: String, signedOut: Bool = true, localSigning: Bool = true) -> AccountSummaryFfi {
        AccountSummaryFfi(
            label: id, accountIdHex: id, localSigning: localSigning,
            externalSigning: !localSigning, signedOut: signedOut, running: false
        )
    }
}
