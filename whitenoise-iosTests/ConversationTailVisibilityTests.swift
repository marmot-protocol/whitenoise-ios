import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

private struct TimelineTailVisibilityHarness: View {
    let rowCount: Int
    let scrollsToTop: Bool
    let onVisibleTargetsChanged: (Set<String>) -> Void
    let onViewportChanged: (TimelineBottomViewport) -> Void
    @State private var didRequestScrollToTop = false

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<rowCount, id: \.self) { index in
                                Text("Row \(index)")
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .id("row-\(index)")
                            }
                            ForEach([TimelineTailVisibilityHarness.bottomSentinelID], id: \.self) { id in
                                Color.clear.frame(height: 1).id(id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, BottomInputChromeLayout.timelineComposerSpacing)
                    .frame(minHeight: max(0, outer.size.height), alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollTargetVisibilityChange(
                    idType: String.self,
                    threshold: TimelineViewportVisibility.minimumVisibleFraction
                ) { visibleIDs in
                    onVisibleTargetsChanged(Set(visibleIDs))
                    // Let the initial bottom anchor settle before moving away from it.
                    guard scrollsToTop, !didRequestScrollToTop,
                          visibleIDs.contains(Self.bottomSentinelID) else { return }
                    didRequestScrollToTop = true
                    proxy.scrollTo("row-0", anchor: .top)
                }
                .onScrollGeometryChange(for: TimelineBottomViewport.self) { geometry in
                    TimelineBottomViewport(
                        contentHeight: geometry.contentSize.height,
                        visibleBottomY: geometry.visibleRect.maxY,
                        bottomContentInset: geometry.contentInsets.bottom
                    )
                } action: { _, viewport in
                    onViewportChanged(viewport)
                }
            }
        }
    }

    static let bottomSentinelID = "conversation-timeline-bottom"
}

@MainActor
@Suite(SharedWindowTestScope())
struct ConversationTailVisibilityTests {
    private static let sentinelID = TimelineTailVisibilityHarness.bottomSentinelID

    private static let settleTimeout = Duration.seconds(20)
    private static let minimumSettleSchedulingOpportunities = 400

    /// Waits for the condition the caller is about to assert, rather than for
    /// the first row to appear. A loaded CI machine can deliver `row-0` and
    /// leave the rest of the layout, and the bottom sentinel with it, a frame
    /// or more behind.
    private func render(
        rowCount: Int,
        scrollsToTop: Bool,
        sourceLocation: SourceLocation = #_sourceLocation,
        until isSettled: (Set<String>, TimelineBottomViewport?) -> Bool
    ) async throws -> (visible: Set<String>, viewport: TimelineBottomViewport?) {
        var visible: Set<String> = []
        var viewport: TimelineBottomViewport?
        let controller = UIHostingController(
            rootView: TimelineTailVisibilityHarness(
                rowCount: rowCount,
                scrollsToTop: scrollsToTop,
                onVisibleTargetsChanged: { visible = $0 },
                onViewportChanged: { viewport = $0 }
            )
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let deadline = ContinuousClock.now.advanced(by: Self.settleTimeout)
        var schedulingOpportunities = 0
        while !isSettled(visible, viewport),
              schedulingOpportunities < Self.minimumSettleSchedulingOpportunities
                || ContinuousClock.now < deadline {
            schedulingOpportunities += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            isSettled(visible, viewport),
            """
            timeline harness never settled within \(Self.settleTimeout) or \
            \(schedulingOpportunities) main-actor scheduling opportunities. \
            Visible: \(visible.sorted()). Viewport: \(String(describing: viewport))
            """,
            sourceLocation: sourceLocation
        )
        return (visible, viewport)
    }

    @Test func timelineShorterThanViewportReportsTailOnScreen() async throws {
        let (visible, _) = try await render(rowCount: 3, scrollsToTop: false) { visible, _ in
            visible.contains(Self.sentinelID)
        }
        #expect(
            visible.contains(Self.sentinelID),
            "A timeline that fits the viewport must report its tail visible. Visible: \(visible)"
        )
        #expect(TimelineTailVisibility.isTailOnScreen(
            visibleTargetIDs: visible,
            bottomSentinelID: Self.sentinelID,
            hasMoreAfter: false
        ))
    }

    @Test func timelineShorterThanViewportLeavesNoDistanceToBottom() async throws {
        let (_, viewport) = try await render(rowCount: 3, scrollsToTop: false) { _, viewport in
            viewport?.distanceToBottom == 0
        }
        let measured = try #require(viewport)
        #expect(
            measured.distanceToBottom == 0,
            "Composer chrome must not leave scrollable distance below a short timeline: \(measured)"
        )
        #expect(measured.isPinned, "Measured: \(measured)")
    }

    @Test func timelineScrolledAwayFromTailDoesNotReportTailOnScreen() async throws {
        let (visible, _) = try await render(rowCount: 60, scrollsToTop: true) { visible, _ in
            visible.contains("row-0") && !visible.contains(Self.sentinelID)
        }
        #expect(visible.contains("row-0"))
        #expect(
            !visible.contains(Self.sentinelID),
            "A timeline scrolled to its head must not report its tail visible. Visible: \(visible)"
        )
        #expect(!TimelineTailVisibility.isTailOnScreen(
            visibleTargetIDs: visible,
            bottomSentinelID: Self.sentinelID,
            hasMoreAfter: false
        ))
    }

    @Test func tailOnScreenRequiresTheSentinelAndAFullyLoadedForwardEdge() {
        #expect(TimelineTailVisibility.isTailOnScreen(
            visibleTargetIDs: ["msg:1", Self.sentinelID],
            bottomSentinelID: Self.sentinelID,
            hasMoreAfter: false
        ))
        #expect(!TimelineTailVisibility.isTailOnScreen(
            visibleTargetIDs: ["msg:1"],
            bottomSentinelID: Self.sentinelID,
            hasMoreAfter: false
        ))
        #expect(!TimelineTailVisibility.isTailOnScreen(
            visibleTargetIDs: ["msg:1", Self.sentinelID],
            bottomSentinelID: Self.sentinelID,
            hasMoreAfter: true
        ))
        #expect(!TimelineTailVisibility.isTailOnScreen(
            visibleTargetIDs: [],
            bottomSentinelID: Self.sentinelID,
            hasMoreAfter: false
        ))
    }

    @Test func visibleTailClearsTheScrollToBottomAffordance() {
        #expect(!TimelineBottom.shouldShowScrollToBottomControl(
            userMovedAwayFromBottom: false,
            hasMoreAfter: false,
            isAtBottom: true
        ))
        #expect(TimelineBottom.shouldShowScrollToBottomControl(
            userMovedAwayFromBottom: true,
            hasMoreAfter: false,
            isAtBottom: false
        ))
        #expect(TimelineBottom.shouldShowScrollToBottomControl(
            userMovedAwayFromBottom: false,
            hasMoreAfter: true,
            isAtBottom: false
        ))
    }
}
