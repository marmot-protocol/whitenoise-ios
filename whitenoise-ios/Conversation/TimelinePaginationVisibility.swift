import SwiftUI

struct TimelinePaginationEdgeState {
    static let retryLimit = 2

    private var isVisible = false
    private var didRequestWhileVisible = false
    private var retries = 0

    mutating func visibilityChanged(to visible: Bool, isEnabled: Bool) -> Bool {
        isVisible = visible
        if !visible {
            didRequestWhileVisible = false
            retries = 0
        }
        return takeRequest(isEnabled: isEnabled)
    }

    mutating func retryRequested(isEnabled: Bool) -> Bool {
        guard retries < Self.retryLimit else { return false }
        retries += 1
        didRequestWhileVisible = false
        return takeRequest(isEnabled: isEnabled)
    }

    mutating func enablementChanged(to isEnabled: Bool) -> Bool {
        takeRequest(isEnabled: isEnabled)
    }

    mutating func disappeared() {
        isVisible = false
        didRequestWhileVisible = false
    }

    private mutating func takeRequest(isEnabled: Bool) -> Bool {
        guard isVisible, isEnabled, !didRequestWhileVisible else { return false }
        didRequestWhileVisible = true
        return true
    }
}

struct TimelinePaginationVisibility: ViewModifier {
    let isEnabled: Bool
    var retryToken: Int = 0
    let requestPage: () -> Void

    @State private var edge = TimelinePaginationEdgeState()

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: TimelineViewportVisibility.minimumVisibleFraction) { visible in
                if edge.visibilityChanged(to: visible, isEnabled: isEnabled) { requestPage() }
            }
            .onDisappear {
                edge.disappeared()
            }
            .onChange(of: retryToken) { _, _ in
                if edge.retryRequested(isEnabled: isEnabled) { requestPage() }
            }
            .onChange(of: isEnabled) { _, newValue in
                if edge.enablementChanged(to: newValue) { requestPage() }
            }
    }
}

/// How close to an edge of the loaded rows the reader has to be for the next
/// page to be requested ahead of them.
nonisolated enum TimelinePaginationReach {
    /// Viewport heights of loaded rows left before the edge.
    static let viewports: CGFloat = 3

    static func isWithinReach(distanceToEdge: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard distanceToEdge.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return false }
        return distanceToEdge < viewportHeight * viewports
    }
}

/// Requests a page while its edge is still a few screens away, so the rows land
/// before the reader runs into the end of what is loaded. The edge's own
/// `TimelinePaginationVisibility` stays as the request of last resort.
struct TimelinePaginationApproach: ViewModifier {
    enum Edge { case older, newer }

    let edge: Edge
    let isEnabled: Bool
    var retryToken: Int = 0
    let requestPage: () -> Void

    @State private var state = TimelinePaginationEdgeState()

    func body(content: Content) -> some View {
        let edge = edge
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distance = switch edge {
                case .older: geometry.visibleRect.minY
                case .newer: geometry.contentSize.height - geometry.visibleRect.maxY
                }
                return TimelinePaginationReach.isWithinReach(
                    distanceToEdge: distance, viewportHeight: geometry.containerSize.height)
            } action: { _, isNear in
                if state.visibilityChanged(to: isNear, isEnabled: isEnabled) { requestPage() }
            }
            .onChange(of: retryToken) { _, _ in
                if state.retryRequested(isEnabled: isEnabled) { requestPage() }
            }
            .onChange(of: isEnabled) { _, newValue in
                if state.enablementChanged(to: newValue) { requestPage() }
            }
    }
}
