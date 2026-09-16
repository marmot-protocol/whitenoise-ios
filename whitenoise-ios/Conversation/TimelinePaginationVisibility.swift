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
            // An eager timeline mounts both edges, including the offscreen one.
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
