import Foundation
import Testing
@testable import whitenoise_ios

struct NotificationAvatarBudgetTests {
    @Test func dnsSlotsFailFastAtTheCap() {
        // Pure claim logic on a local counter — the process-wide counter is
        // shared with parallel suites doing real fetches.
        var inFlight = 0
        #expect(PinnedHTTPSFetcher.claimDnsSlot(&inFlight, limit: 2))
        #expect(PinnedHTTPSFetcher.claimDnsSlot(&inFlight, limit: 2))
        #expect(!PinnedHTTPSFetcher.claimDnsSlot(&inFlight, limit: 2))
        inFlight -= 1
        #expect(PinnedHTTPSFetcher.claimDnsSlot(&inFlight, limit: 2))
    }

    @Test func avatarDataReturnsNilWithoutNetworkEgress() async {
        let result = await NotificationCommunicationDecorator.avatarData(
            for: "https://example.com/sender-avatar.png"
        )
        #expect(result == nil)
    }
}
