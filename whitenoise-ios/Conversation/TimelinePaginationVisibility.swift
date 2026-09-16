import SwiftUI

struct TimelinePaginationVisibility: ViewModifier {
    let isEnabled: Bool
    let requestPage: () -> Void

    @State private var isVisible = false
    @State private var requestedWhileVisible = false

    func body(content: Content) -> some View {
        content
            // An eager timeline mounts both edges, including the offscreen one.
            .onScrollVisibilityChange(threshold: TimelineViewportVisibility.minimumVisibleFraction) { visible in
                isVisible = visible
                if !visible { requestedWhileVisible = false }
                requestIfNeeded()
            }
            .onDisappear {
                isVisible = false
                requestedWhileVisible = false
            }
            .onChange(of: isEnabled) { _, _ in
                requestIfNeeded()
            }
    }

    private func requestIfNeeded() {
        guard isVisible, isEnabled, !requestedWhileVisible else { return }
        requestedWhileVisible = true
        requestPage()
    }
}
