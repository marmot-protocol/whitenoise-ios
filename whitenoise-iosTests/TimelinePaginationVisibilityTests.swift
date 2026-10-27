import Combine
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

struct TimelinePaginationEdgeStateTests {
    @Test func offscreenEdgeNeverRequests() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.enablementChanged(to: true) == false)
        #expect(edge.visibilityChanged(to: false, isEnabled: true) == false)
    }

    @Test func theVisibleEdgeRequestsOncePerEntry() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == false)
    }

    @Test func leavingTheViewportRearmsTheEdge() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
        #expect(edge.visibilityChanged(to: false, isEnabled: true) == false)
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
    }

    @Test func aDisabledEdgeDefersUntilItIsEnabled() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.visibilityChanged(to: true, isEnabled: false) == false)
        #expect(edge.enablementChanged(to: true) == true)
    }

    @Test func loadingStateChangesDoNotDuplicateTheVisiblePageRequest() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
        #expect(edge.enablementChanged(to: false) == false)
        #expect(edge.enablementChanged(to: true) == false)
    }

    @Test func aRetryTokenRearmsTheEdgeUpToItsLimit() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
        for _ in 0..<TimelinePaginationEdgeState.retryLimit {
            #expect(edge.retryRequested(isEnabled: true) == true)
        }
        #expect(edge.retryRequested(isEnabled: true) == false)
    }

    @Test func leavingTheViewportRestoresTheRetryBudget() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
        for _ in 0..<TimelinePaginationEdgeState.retryLimit {
            _ = edge.retryRequested(isEnabled: true)
        }
        #expect(edge.retryRequested(isEnabled: true) == false)
        _ = edge.visibilityChanged(to: false, isEnabled: true)
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
        #expect(edge.retryRequested(isEnabled: true) == true)
    }

    @Test func aRetryOnAnOffscreenEdgeRequestsNothing() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.retryRequested(isEnabled: true) == false)
    }

    @Test func disappearingRearmsTheEdge() {
        var edge = TimelinePaginationEdgeState()
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
        edge.disappeared()
        #expect(edge.visibilityChanged(to: true, isEnabled: true) == true)
    }
}

@MainActor
private final class PaginationScrollModel: ObservableObject {
    @Published var isEnabled = true
    var olderRequests = 0
    var newerRequests = 0
    /// Opens when the bottom edge reports itself visible and has requested
    /// newer history: the mounted timeline has settled at its initial anchor.
    let bottomSettled = TestLatch()
    var bottomIsVisible = false {
        didSet { signalIfSettled() }
    }

    func requestNewer() {
        newerRequests += 1
        signalIfSettled()
    }

    private func signalIfSettled() {
        if bottomIsVisible, newerRequests > 0 { bottomSettled.signal() }
    }
}

private struct PaginationScrollHarness: View {
    @ObservedObject var model: PaginationScrollModel

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Color.clear.frame(height: 28)
                    .modifier(TimelinePaginationVisibility(isEnabled: model.isEnabled) {
                        model.olderRequests += 1
                    })
                ForEach(0..<100) { index in
                    Text("Message \(index)").frame(height: 80)
                }
                Color.clear.frame(height: 28)
                    .modifier(TimelinePaginationVisibility(isEnabled: model.isEnabled) {
                        model.requestNewer()
                    })
                    .onScrollVisibilityChange(threshold: TimelineViewportVisibility.minimumVisibleFraction) {
                        model.bottomIsVisible = $0
                    }
            }
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
    }
}

@MainActor
@Suite(.serialized)
struct TimelinePaginationVisibilityTests {
    /// The only claim rendering alone can make: `onScrollVisibilityChange`
    /// reports the mounted-but-offscreen edge as invisible, where `onAppear`
    /// would fire. Everything about *when* a request happens is asserted
    /// deterministically in `TimelinePaginationEdgeStateTests`; this waits for
    /// the bottom edge's own visibility and request callbacks, so the top
    /// edge has had the same layout passes to misfire in.
    @Test func mountingAnEagerTimelineNeverPaginatesTheOffscreenEdge() async throws {
        let model = PaginationScrollModel()
        let host = UIHostingController(rootView: PaginationScrollHarness(model: model))
        try await withHostedWindow(host, frame: CGRect(x: 0, y: 0, width: 390, height: 700)) { window in
            try await model.bottomSettled.wait()

            let rendered = descendants(window).contains { $0 is UIScrollView }
            #expect(rendered, "The harness never built a scroll view")
            #expect(model.olderRequests == 0, "Mounting offscreen history must not paginate backwards")
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
