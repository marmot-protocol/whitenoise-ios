import Foundation
import Testing
@testable import whitenoise_ios

struct NotificationActionBackgroundBudgetTests {
    @Test func foregroundAndLargeFiniteBudgetsReturnRequestedWithoutTrapping() {
        let requested: Duration = .seconds(20)
        // Foreground UIApplication.backgroundTimeRemaining returns
        // `.greatestFiniteMagnitude` — must never overflow `Duration.seconds`.
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: .greatestFiniteMagnitude,
            context: .foreground
        ) == requested)
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: .greatestFiniteMagnitude,
            context: .background
        ) == requested)
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: .infinity,
            context: .background
        ) == requested)
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: -.infinity,
            context: .background
        ) == nil)
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: .nan,
            context: .background
        ) == nil)
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: .zero,
            backgroundTimeRemaining: 30,
            context: .background
        ) == nil)
    }

    @Test func backgroundBudgetAlwaysReservesStorageCloseMarginAndEnforcesMinimumWork() throws {
        let reserve = NotificationActionBackgroundBudget.storageCloseReserveSeconds
        let minWork = NotificationActionBackgroundBudget.minimumWorkSeconds
        let requested: Duration = .seconds(30)

        // Plenty of remaining time honors the full requested deadline.
        let ampleRemaining = 30 + reserve + 5
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: ampleRemaining,
            context: .background
        ) == requested)

        // Tighter window clamps so work + storageCloseReserve <= remaining.
        let tightRemaining = reserve + minWork + 4
        let tight = try #require(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: tightRemaining,
            context: .background
        ))
        let tightSeconds = TimeInterval(tight.components.seconds)
            + TimeInterval(tight.components.attoseconds) / 1e18
        #expect(tightSeconds >= minWork)
        #expect(tightSeconds + reserve <= tightRemaining)
        #expect(tight < requested)

        // Exactly reserve + minimumWork is the lowest admissible window.
        let boundary = try #require(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: reserve + minWork,
            context: .background
        ))
        let boundarySeconds = TimeInterval(boundary.components.seconds)
            + TimeInterval(boundary.components.attoseconds) / 1e18
        #expect(boundarySeconds >= minWork)
        #expect(boundarySeconds + reserve <= reserve + minWork)

        // Anything below reserve + minimumWork refuses to open storage.
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: reserve + minWork - 0.25,
            context: .background
        ) == nil)
        #expect(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: 0,
            context: .background
        ) == nil)
    }

    @Test func coldBackgroundLaunchAppliesConservativeCapEvenWhenRemainingIsGreatestFiniteMagnitude() throws {
        let cap = NotificationActionBackgroundBudget.coldLaunchMaximumWorkSeconds
        let reserve = NotificationActionBackgroundBudget.storageCloseReserveSeconds
        let requested: Duration = .seconds(cap + 10)

        // UIKit does not guarantee a finite countdown on cold UI-less launches,
        // so `.coldBackgroundLaunch` caps work conservatively.
        let capped = try #require(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: .greatestFiniteMagnitude,
            context: .coldBackgroundLaunch
        ))
        let cappedSeconds = TimeInterval(capped.components.seconds)
            + TimeInterval(capped.components.attoseconds) / 1e18
        #expect(cappedSeconds <= cap)
        #expect(capped < requested)

        // If UIKit does report a tighter finite window, that tighter window wins.
        let tighter = try #require(NotificationActionBackgroundBudget.effectiveDeadline(
            requested: requested,
            backgroundTimeRemaining: reserve + 3,
            context: .coldBackgroundLaunch
        ))
        let tighterSeconds = TimeInterval(tighter.components.seconds)
            + TimeInterval(tighter.components.attoseconds) / 1e18
        #expect(tighterSeconds + reserve <= reserve + 3)
        #expect(tighterSeconds < cap)
    }

    @Test func remainingBackgroundBatchWorkDeadlineAndUnboundedDetection() {
        let cap = NotificationActionBackgroundBudget.coldLaunchMaximumWorkSeconds
        let base = ContinuousClock.now
        let cutoff = base.advanced(by: .seconds(cap))

        #expect(NotificationActionBackgroundBudget.isUnboundedBackgroundTimeRemaining(.greatestFiniteMagnitude))
        #expect(NotificationActionBackgroundBudget.isUnboundedBackgroundTimeRemaining(.infinity))
        #expect(!NotificationActionBackgroundBudget.isUnboundedBackgroundTimeRemaining(30))
        #expect(!NotificationActionBackgroundBudget.isUnboundedBackgroundTimeRemaining(-.infinity))
        #expect(!NotificationActionBackgroundBudget.isUnboundedBackgroundTimeRemaining(.nan))

        #expect(NotificationActionBackgroundBudget.remainingBackgroundBatchWorkDeadline(
            requested: .seconds(cap + 5),
            now: base,
            cutoff: cutoff
        ) == .seconds(cap))
        #expect(NotificationActionBackgroundBudget.remainingBackgroundBatchWorkDeadline(
            requested: .seconds(cap + 5),
            now: base.advanced(by: .seconds(12)),
            cutoff: cutoff
        ) == .seconds(cap - 12))
        #expect(NotificationActionBackgroundBudget.remainingBackgroundBatchWorkDeadline(
            requested: .seconds(cap + 5),
            now: base.advanced(by: .milliseconds(17_500)),
            cutoff: cutoff
        ) == nil)
    }
}
