import Foundation
import Testing
@testable import whitenoise_ios

struct NotificationAvatarBudgetTests {
    @Test func perFetchDeadlineIsClampedToTheRemainingBudget() {
        // Fresh budget: the per-fetch deadline applies unclamped.
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .zero,
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == .seconds(3))
        // Near-exhausted budget: a fetch may start but only gets the
        // remainder — the overshoot the loop-entry check allowed.
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .milliseconds(5_800),
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == .milliseconds(200))
        // Exhausted budget: no fetch starts.
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .seconds(6),
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == nil)
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .seconds(7),
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == nil)
    }

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

    /// One wake resolves each sender picture once, in arrival order, and no more
    /// than the per-wake cap. Arrival order keeps the primary sender, which the
    /// extension puts first, inside the cap.
    @Test func avatarURLsAreDistinctInArrivalOrderAndCapped() {
        // Deliberately not in sorted order, so sorting would fail the order checks.
        let arrivals = ["https://z/primary", nil, "https://m/2", "https://z/primary", "https://a/3",
                        "https://c/4", "https://b/5"]
        let presentations = arrivals.map { notificationPresentation(senderPictureUrl: $0) }
        let distinct = ["https://z/primary", "https://m/2", "https://a/3", "https://c/4", "https://b/5"]

        // The production default caps a busy wake at the per-wake limit.
        let capped = NotificationCommunicationDecorator.avatarURLs(for: presentations)
        let cap = NotificationCommunicationDecorator.maxAvatarFetchesPerWake
        #expect(cap < distinct.count)
        #expect(capped.first == "https://z/primary")
        #expect(capped == Array(distinct.prefix(cap)))

        #expect(NotificationCommunicationDecorator.avatarURLs(for: presentations, limit: distinct.count + 1)
            == distinct)
        #expect(NotificationCommunicationDecorator.avatarURLs(
            for: [notificationPresentation(senderPictureUrl: nil)]).isEmpty)
    }

    @Test func avatarDataReturnsNilWithoutNetworkEgress() async {
        let result = await NotificationCommunicationDecorator.avatarData(
            for: "https://example.com/sender-avatar.png"
        )
        #expect(result == nil)
    }
}
