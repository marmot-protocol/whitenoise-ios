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

    @Test func deadlineWinCancelsTheAbandonedFetch() async throws {
        // The work never finishes on its own: it returns only once its
        // cancellation handler opens the latch, which the test then awaits.
        let cancelled = TestLatch()
        let result = await NotificationCommunicationDecorator.withDeadline(.milliseconds(50)) {
            await withTaskCancellationHandler {
                try? await cancelled.wait()
                return nil
            } onCancel: {
                cancelled.signal()
            }
        }
        #expect(result == nil)
        // A starved runner may schedule the detached work task (and its
        // cancellation handler) late; the latch waits for it, bounded.
        try await cancelled.wait()
    }

    @Test func callerCancellationResumesTheDeadlineWaitAndCancelsWork() async throws {
        // The deadline is effectively infinite and the work returns only once
        // cancelled, so the await below can only ever return through the
        // caller-cancellation racer — completion itself is the assertion,
        // with no wall-clock comparison to flake on a saturated test runner.
        let started = TestLatch()
        let cancelled = TestLatch()
        let waiter = Task {
            await NotificationCommunicationDecorator.withDeadline(.seconds(100_000)) {
                await withTaskCancellationHandler {
                    started.signal()
                    try? await cancelled.wait()
                    return nil
                } onCancel: {
                    cancelled.signal()
                }
            }
        }
        try await started.wait()
        waiter.cancel()
        let result = await waiter.value
        #expect(result == nil)
        try await cancelled.wait()
    }

    @Test func warmSlotsDeduplicatePerUrlAndCapConcurrency() {
        var inFlight: Set<String> = []
        #expect(NotificationCommunicationDecorator.claimWarmSlot("a", in: &inFlight, limit: 2))
        // Same URL never claims a second slot.
        #expect(!NotificationCommunicationDecorator.claimWarmSlot("a", in: &inFlight, limit: 2))
        #expect(NotificationCommunicationDecorator.claimWarmSlot("b", in: &inFlight, limit: 2))
        // The cap bounds distinct peer-controlled hosts, not just duplicates.
        #expect(!NotificationCommunicationDecorator.claimWarmSlot("c", in: &inFlight, limit: 2))
        inFlight.remove("a")
        #expect(NotificationCommunicationDecorator.claimWarmSlot("c", in: &inFlight, limit: 2))
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

    @Test func workWinReturnsItsValueBeforeTheDeadline() async {
        let result = await NotificationCommunicationDecorator.withDeadline(.seconds(30)) {
            Data([0x1])
        }
        #expect(result == Data([0x1]))
    }

    /// One wake fetches each sender picture once, in arrival order, and no more
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
}
