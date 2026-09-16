import SwiftUI

struct TimelinePaginationVisibility: ViewModifier {
    let isEnabled: Bool
    var retryToken: Int = 0
    let requestPage: () -> Void

    @State private var retries = 0
    @State private var isVisible = false
    @State private var requestedWhileVisible = false

    func body(content: Content) -> some View {
        content
            // An eager timeline mounts both edges, including the offscreen one.
            .onScrollVisibilityChange(threshold: TimelineViewportVisibility.minimumVisibleFraction) { visible in
                isVisible = visible
                if !visible { requestedWhileVisible = false; retries = 0 }
                requestIfNeeded()
            }
            .onDisappear {
                isVisible = false
                requestedWhileVisible = false
            }
            .onChange(of: retryToken) { _, _ in
                guard retries < 2 else { return }
                retries += 1
                requestedWhileVisible = false
                requestIfNeeded()
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
