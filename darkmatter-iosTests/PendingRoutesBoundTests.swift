import Testing
@testable import darkmatter_ios

/// #18 — the pre-launch notification-route buffer must stay bounded so a
/// notification flood during startup can't grow memory unboundedly.
struct PendingRoutesBoundTests {

    @Test func keepsOnlyTheMostRecentRoutesWithinLimit() {
        var routes: [Int] = []
        for i in 0..<100 {
            routes = AppNotifications.appendingBounded(i, to: routes, limit: AppNotifications.maxPendingRoutes)
        }
        #expect(routes.count == AppNotifications.maxPendingRoutes)
        #expect(routes.last == 99)
        #expect(routes.first == 100 - AppNotifications.maxPendingRoutes)
    }

    @Test func leavesShortBuffersUntouched() {
        let routes = AppNotifications.appendingBounded(2, to: [0, 1], limit: 32)
        #expect(routes == [0, 1, 2])
    }
}
